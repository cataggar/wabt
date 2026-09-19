const std = @import("std");
const wabt = @import("wabt");
const inspect_cmd = @import("oci_inspect.zig");
const list_tags_cmd = @import("oci_list_tags.zig");
const output = @import("oci_output.zig");
const pull_cmd = @import("oci_pull.zig");
const resolve_cmd = @import("oci_resolve.zig");
const runtime_mod = @import("oci_runtime.zig");

const http = wabt.oci.registry_http;

const FakeClock = struct {
    now_ns: i128 = 1_000,

    fn clock(self: *FakeClock) http.Clock {
        return http.Clock.initWithUnixSeconds(self);
    }

    fn sleeper(self: *FakeClock) http.Sleeper {
        return http.Sleeper.init(self);
    }

    pub fn now(self: *FakeClock) i128 {
        return self.now_ns;
    }

    pub fn unixSeconds(_: *FakeClock) i64 {
        return 0;
    }

    pub fn sleep(
        self: *FakeClock,
        duration_ns: u64,
    ) http.SleepError!void {
        self.now_ns += duration_ns;
    }
};

const Step = struct {
    method: std.http.Method = .GET,
    path_suffix: []const u8,
    class: http.RequestClass = .registry,
    status: u16 = 200,
    headers: []const http.Header = &.{},
    body: []const u8 = "",
    failure: ?http.BackendError = null,
};

const ScriptedBackend = struct {
    steps: []const Step,
    index: usize = 0,

    fn backend(self: *ScriptedBackend) http.Backend {
        return http.Backend.init(self, .{
            .absolute_deadline = true,
            .dns_timeout = true,
            .connect_timeout = true,
            .tls_handshake_timeout = true,
            .write_timeout = true,
            .response_head_timeout = true,
            .body_idle_timeout = true,
        });
    }

    pub fn request(
        self: *ScriptedBackend,
        allocator: std.mem.Allocator,
        request_options: http.BackendRequest,
    ) http.BackendError!http.Response {
        if (self.index >= self.steps.len) return error.ProtocolFailure;
        const step = self.steps[self.index];
        self.index += 1;
        if (request_options.method != step.method or
            request_options.class != step.class or
            !std.mem.endsWith(
                u8,
                request_options.url,
                step.path_suffix,
            ))
        {
            return error.ProtocolFailure;
        }
        if (step.failure) |failure| return failure;
        if (request_options.body_sink) |sink| {
            if (step.status >= 200 and step.status < 300) {
                sink.begin(step.body.len) catch return error.BodySinkFailed;
                sink.write(step.body) catch return error.BodySinkFailed;
                sink.finish() catch return error.BodySinkFailed;
                return http.Response.initCopy(
                    allocator,
                    step.status,
                    step.headers,
                    "",
                ) catch error.OutOfMemory;
            }
        }
        return http.Response.initCopy(
            allocator,
            step.status,
            step.headers,
            step.body,
        ) catch error.OutOfMemory;
    }
};

const Factory = struct {
    backend: *ScriptedBackend,
    clock: *FakeClock,

    fn create(
        context: ?*anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        reference: wabt.oci.RegistryReference,
        source_options: wabt.oci.RegistryOptions,
    ) !wabt.oci.RegistrySource {
        const self: *Factory = @ptrCast(@alignCast(context.?));
        return wabt.oci.RegistrySource.initWithBackend(
            io,
            allocator,
            reference,
            self.backend.backend(),
            self.clock.clock(),
            self.clock.sleeper(),
            source_options,
        );
    }
};

const Capture = struct {
    stdout_buffer: [16 * 1024]u8 = undefined,
    stderr_buffer: [4096]u8 = undefined,
    stdout_writer: std.Io.Writer = undefined,
    stderr_writer: std.Io.Writer = undefined,

    fn reset(self: *Capture) void {
        self.stdout_writer = std.Io.Writer.fixed(&self.stdout_buffer);
        self.stderr_writer = std.Io.Writer.fixed(&self.stderr_buffer);
    }

    fn attach(self: *Capture, runtime: *runtime_mod.Runtime) void {
        runtime.stdout = runtime_mod.OutputSink.fromWriter(
            &self.stdout_writer,
        );
        runtime.stderr = runtime_mod.OutputSink.fromWriter(
            &self.stderr_writer,
        );
    }

    fn stdout(self: *const Capture) []const u8 {
        return self.stdout_buffer[0..self.stdout_writer.end];
    }

    fn stderr(self: *const Capture) []const u8 {
        return self.stderr_buffer[0..self.stderr_writer.end];
    }
};

fn initRuntime(
    counters: *runtime_mod.Counters,
    factory: *Factory,
    clock: *FakeClock,
    capture: *Capture,
) runtime_mod.Runtime {
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        counters,
    );
    runtime.registry_factory = .{
        .context = factory,
        .create_fn = Factory.create,
    };
    runtime.clock = runtime_mod.Clock.init(clock);
    capture.attach(&runtime);
    return runtime;
}

fn manifestHeaders(media_type: []const u8) [1]http.Header {
    return .{.{ .name = "Content-Type", .value = media_type }};
}

fn blobPath(
    buffer: []u8,
    digest: []const u8,
) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "/v2/team/app/blobs/{s}",
        .{digest},
    ) catch unreachable;
}

test "resolve tag and digest emit immutable v1 fields exactly once" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try wabt.oci.prepareWasmArtifact(allocator, payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:00Z",
    });
    defer package.deinit();
    const headers = manifestHeaders(package.root_descriptor.mediaType);
    const steps = [_]Step{.{
        .path_suffix = "/v2/team/app/manifests/latest",
        .headers = &headers,
        .body = package.manifest_bytes,
    }};
    var backend: ScriptedBackend = .{ .steps = &steps };
    var clock: FakeClock = .{};
    var factory: Factory = .{ .backend = &backend, .clock = &clock };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &factory, &clock, &capture);

    try resolve_cmd.execute(&.{
        "registry.example/team/app:latest",
        "--json",
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expectEqual(@as(usize, 1), backend.index);
    try std.testing.expectEqual(@as(usize, 1), counters.network_clients);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"schema\":\"wabt.oci.resolve\",\"schemaVersion\":1",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        package.root_descriptor.digest,
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"manifestDigest\":\"sha256:",
    ) != null);
    try std.testing.expectEqualStrings("", capture.stderr());

    const digest_steps = [_]Step{.{
        .path_suffix = package.root_descriptor.digest,
        .headers = &headers,
        .body = package.manifest_bytes,
    }};
    var digest_backend: ScriptedBackend = .{ .steps = &digest_steps };
    var digest_factory: Factory = .{
        .backend = &digest_backend,
        .clock = &clock,
    };
    counters = .{};
    capture.reset();
    runtime = initRuntime(
        &counters,
        &digest_factory,
        &clock,
        &capture,
    );
    const digest_reference = try std.fmt.allocPrint(
        allocator,
        "registry.example/team/app@{s}",
        .{package.root_descriptor.digest},
    );
    defer allocator.free(digest_reference);
    try resolve_cmd.execute(&.{
        digest_reference,
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expectEqual(@as(usize, 1), digest_backend.index);
    const expected = try std.fmt.allocPrint(
        allocator,
        "{s}\n",
        .{digest_reference},
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, capture.stdout());
}

test "inspect direct index and subject metadata without extraction" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try wabt.oci.prepareWasmArtifact(allocator, payload, .{
        .profile = .wasm_v0,
        .created = "2026-09-19T00:00:00Z",
        .author = "WABT",
    });
    defer package.deinit();

    var config_path_buffer: [256]u8 = undefined;
    var payload_path_buffer: [256]u8 = undefined;
    const headers = manifestHeaders(package.root_descriptor.mediaType);
    const direct_steps = [_]Step{
        .{
            .path_suffix = "/v2/team/app/manifests/latest",
            .headers = &headers,
            .body = package.manifest_bytes,
        },
        .{
            .path_suffix = blobPath(
                &config_path_buffer,
                package.config_descriptor.digest,
            ),
            .class = .blob,
            .body = package.config_bytes,
        },
        .{
            .path_suffix = blobPath(
                &payload_path_buffer,
                package.layer_descriptor.digest,
            ),
            .class = .blob,
            .body = package.payload_bytes,
        },
    };
    var direct_backend: ScriptedBackend = .{ .steps = &direct_steps };
    var clock: FakeClock = .{};
    var direct_factory: Factory = .{
        .backend = &direct_backend,
        .clock = &clock,
    };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(
        &counters,
        &direct_factory,
        &clock,
        &capture,
    );
    try inspect_cmd.execute(&.{
        "registry.example/team/app:latest",
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expectEqual(@as(usize, 3), direct_backend.index);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"documentKind\":\"manifest\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"profile\":\"wasm-v0\"",
    ) != null);

    const index_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        wabt.oci.Index{
            .schemaVersion = 2,
            .mediaType = wabt.oci.model.media_type_oci_index,
            .manifests = &.{package.root_descriptor},
        },
        .{},
    );
    defer allocator.free(index_bytes);
    const index_description = try wabt.oci.content.describeBytes(index_bytes);
    const index_digest = index_description.digest.format();
    const index_headers = manifestHeaders(
        wabt.oci.model.media_type_oci_index,
    );
    const index_steps = [_]Step{
        .{
            .path_suffix = "/v2/team/app/manifests/multi",
            .headers = &index_headers,
            .body = index_bytes,
        },
        .{
            .path_suffix = package.root_descriptor.digest,
            .headers = &headers,
            .body = package.manifest_bytes,
        },
    };
    var index_backend: ScriptedBackend = .{ .steps = &index_steps };
    var index_factory: Factory = .{
        .backend = &index_backend,
        .clock = &clock,
    };
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &index_factory, &clock, &capture);
    try inspect_cmd.execute(&.{
        "registry.example/team/app:multi",
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expectEqual(@as(usize, 2), index_backend.index);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"documentKind\":\"index\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        &index_digest,
    ) != null);

    const generic_config = try ownedDescriptor(
        allocator,
        "application/example.config",
        "{}",
    );
    defer generic_config.deinit(allocator);
    const generic_layer = try ownedDescriptor(
        allocator,
        "application/example.data",
        "data",
    );
    defer generic_layer.deinit(allocator);
    const subject_manifest = wabt.oci.Manifest{
        .schemaVersion = 2,
        .mediaType = wabt.oci.model.media_type_oci_manifest,
        .config = generic_config.descriptor,
        .layers = &.{generic_layer.descriptor},
        .artifactType = "application/example",
        .subject = package.root_descriptor,
    };
    const subject_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        subject_manifest,
        .{},
    );
    defer allocator.free(subject_bytes);
    const subject_headers = manifestHeaders(
        wabt.oci.model.media_type_oci_manifest,
    );
    const subject_steps = [_]Step{.{
        .path_suffix = "/v2/team/app/manifests/subject",
        .headers = &subject_headers,
        .body = subject_bytes,
    }};
    var subject_backend: ScriptedBackend = .{ .steps = &subject_steps };
    var subject_factory: Factory = .{
        .backend = &subject_backend,
        .clock = &clock,
    };
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &subject_factory, &clock, &capture);
    try inspect_cmd.execute(&.{
        "registry.example/team/app:subject",
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"artifactType\":\"application/example\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"subject\":{\"mediaType\":",
    ) != null);
}

test "inspect preserves explicit unsupported and corrupt failures" {
    const allocator = std.testing.allocator;
    const config = try ownedDescriptor(
        allocator,
        wabt.oci.wasm.media_type_empty_config,
        "{}",
    );
    defer config.deinit(allocator);
    const layer = try ownedDescriptor(
        allocator,
        "application/example",
        "data",
    );
    defer layer.deinit(allocator);
    const unsupported_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        wabt.oci.Manifest{
            .schemaVersion = 2,
            .mediaType = wabt.oci.model.media_type_oci_manifest,
            .config = config.descriptor,
            .layers = &.{layer.descriptor},
            .artifactType = wabt.oci.wasm.artifact_type_wasm,
        },
        .{},
    );
    defer allocator.free(unsupported_bytes);
    const headers = manifestHeaders(
        wabt.oci.model.media_type_oci_manifest,
    );
    const unsupported_steps = [_]Step{.{
        .path_suffix = "/v2/team/app/manifests/unsupported",
        .headers = &headers,
        .body = unsupported_bytes,
    }};
    var backend: ScriptedBackend = .{ .steps = &unsupported_steps };
    var clock: FakeClock = .{};
    var factory: Factory = .{ .backend = &backend, .clock = &clock };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &factory, &clock, &capture);
    try std.testing.expectError(
        error.UnsupportedContent,
        inspect_cmd.execute(&.{
            "registry.example/team/app:unsupported",
            "--no-credential-discovery",
        }, &runtime),
    );
    try std.testing.expectEqual(@as(usize, 1), backend.index);
    try std.testing.expectEqualStrings("", capture.stdout());

    const corrupt_steps = [_]Step{.{
        .path_suffix = "/v2/team/app/manifests/corrupt",
        .headers = &headers,
        .body = "{}",
    }};
    backend = .{ .steps = &corrupt_steps };
    factory.backend = &backend;
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &factory, &clock, &capture);
    try std.testing.expectError(
        error.InvalidContent,
        inspect_cmd.execute(&.{
            "registry.example/team/app:corrupt",
            "--no-credential-discovery",
        }, &runtime),
    );
    try std.testing.expectEqualStrings("", capture.stdout());
}

const OwnedDescriptor = struct {
    digest: []u8,
    descriptor: wabt.oci.Descriptor,

    fn deinit(self: OwnedDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
    }
};

fn ownedDescriptor(
    allocator: std.mem.Allocator,
    media_type: []const u8,
    bytes: []const u8,
) !OwnedDescriptor {
    const description = try wabt.oci.content.describeBytes(bytes);
    const digest_array = description.digest.format();
    const digest = try allocator.dupe(u8, &digest_array);
    return .{
        .digest = digest,
        .descriptor = .{
            .mediaType = media_type,
            .digest = digest,
            .size = description.size,
        },
    };
}

test "list-tags follows bounded pagination and sorts deterministically" {
    const content_type = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Link", .value = "</v2/team/app/tags/list?n=2&last=z>; rel=\"next\"" },
    };
    const final_content_type = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/team/app/tags/list",
            .headers = &content_type,
            .body = "{\"name\":\"team/app\",\"tags\":[\"z\",\"a\"]}",
        },
        .{
            .path_suffix = "/v2/team/app/tags/list?n=2&last=z",
            .headers = &final_content_type,
            .body = "{\"name\":\"team/app\",\"tags\":[\"m\",\"a\"]}",
        },
    };
    var backend: ScriptedBackend = .{ .steps = &steps };
    var clock: FakeClock = .{};
    var factory: Factory = .{ .backend = &backend, .clock = &clock };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &factory, &clock, &capture);
    try list_tags_cmd.execute(&.{
        "registry.example/team/app",
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expectEqual(@as(usize, 2), backend.index);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"wabt.oci.list-tags\",\"schemaVersion\":1,\"repository\":\"registry.example/team/app\",\"tags\":[\"a\",\"m\",\"z\"]}\n",
        capture.stdout(),
    );
}

test "pull resolves tag once supports profiles and atomically replaces only with force" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    inline for ([_]wabt.oci.WasmProfile{ .wasm_v0, .oci }) |profile| {
        var package = try wabt.oci.prepareWasmArtifact(allocator, payload, .{
            .profile = profile,
            .created = "2026-09-19T00:00:00Z",
            .author = if (profile == .wasm_v0) "WABT" else null,
        });
        defer package.deinit();
        const headers = manifestHeaders(package.root_descriptor.mediaType);
        var config_path_buffer: [256]u8 = undefined;
        var payload_path_buffer: [256]u8 = undefined;
        const steps = [_]Step{
            .{
                .path_suffix = "/v2/team/app/manifests/latest",
                .headers = &headers,
                .body = package.manifest_bytes,
            },
            .{
                .path_suffix = blobPath(
                    &config_path_buffer,
                    package.config_descriptor.digest,
                ),
                .class = .blob,
                .body = package.config_bytes,
            },
            .{
                .path_suffix = blobPath(
                    &payload_path_buffer,
                    package.layer_descriptor.digest,
                ),
                .class = .blob,
                .body = package.payload_bytes,
            },
        };
        var backend: ScriptedBackend = .{ .steps = &steps };
        var clock: FakeClock = .{};
        var factory: Factory = .{ .backend = &backend, .clock = &clock };
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &factory, &clock, &capture);

        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const output_path = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/tmp/{s}/module.wasm",
            .{temporary.sub_path},
        );
        defer allocator.free(output_path);
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "module.wasm",
            .data = "old",
        });

        try std.testing.expectError(
            error.OutputExists,
            pull_cmd.execute(&.{
                "registry.example/team/app:latest",
                "-o",
                output_path,
                "--json",
                "--no-credential-discovery",
            }, &runtime),
        );
        try std.testing.expectEqual(@as(usize, 0), backend.index);
        try std.testing.expect(counters.isZero());

        try pull_cmd.execute(&.{
            "registry.example/team/app:latest",
            "-o",
            output_path,
            "--force",
            "--json",
            "--no-credential-discovery",
        }, &runtime);
        try std.testing.expectEqual(@as(usize, 3), backend.index);
        const actual = try temporary.dir.readFileAlloc(
            std.testing.io,
            "module.wasm",
            allocator,
            .limited(64),
        );
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(payload, actual);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"schema\":\"wabt.oci.pull\",\"schemaVersion\":1",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"config\":{\"mediaType\":",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"payload\":{\"mediaType\":\"application/wasm\"",
        ) != null);
    }
}

test "pull accepts the OCI 1.0 compatibility shape" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    const config = try ownedDescriptor(
        allocator,
        wabt.oci.wasm.media_type_wasm,
        "{}",
    );
    defer config.deinit(allocator);
    const layer = try ownedDescriptor(
        allocator,
        wabt.oci.wasm.media_type_wasm,
        payload,
    );
    defer layer.deinit(allocator);
    const manifest_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        struct {
            schemaVersion: u32,
            mediaType: []const u8,
            config: wabt.oci.Descriptor,
            layers: []const wabt.oci.Descriptor,
        }{
            .schemaVersion = 2,
            .mediaType = wabt.oci.model.media_type_oci_manifest,
            .config = config.descriptor,
            .layers = &.{layer.descriptor},
        },
        .{},
    );
    defer allocator.free(manifest_bytes);
    const root = try ownedDescriptor(
        allocator,
        wabt.oci.model.media_type_oci_manifest,
        manifest_bytes,
    );
    defer root.deinit(allocator);
    const headers = manifestHeaders(root.descriptor.mediaType);
    var config_path_buffer: [256]u8 = undefined;
    var payload_path_buffer: [256]u8 = undefined;
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/team/app/manifests/compat",
            .headers = &headers,
            .body = manifest_bytes,
        },
        .{
            .path_suffix = blobPath(
                &config_path_buffer,
                config.descriptor.digest,
            ),
            .class = .blob,
            .body = "{}",
        },
        .{
            .path_suffix = blobPath(
                &payload_path_buffer,
                layer.descriptor.digest,
            ),
            .class = .blob,
            .body = payload,
        },
    };
    var backend: ScriptedBackend = .{ .steps = &steps };
    var clock: FakeClock = .{};
    var factory: Factory = .{ .backend = &backend, .clock = &clock };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &factory, &clock, &capture);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const output_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/compat.wasm",
        .{temporary.sub_path},
    );
    defer allocator.free(output_path);
    try pull_cmd.execute(&.{
        "registry.example/team/app:compat",
        "-o",
        output_path,
        "--json",
        "--no-credential-discovery",
    }, &runtime);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"profile\":\"oci-1.0\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 3), backend.index);
}

test "pull rejects descriptor-valid non-Wasm payload without publication" {
    const allocator = std.testing.allocator;
    const config = try ownedDescriptor(
        allocator,
        wabt.oci.wasm.media_type_empty_config,
        "{}",
    );
    defer config.deinit(allocator);
    const layer = try ownedDescriptor(
        allocator,
        wabt.oci.wasm.media_type_wasm,
        "not-wasm",
    );
    defer layer.deinit(allocator);
    const manifest_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        struct {
            schemaVersion: u32,
            mediaType: []const u8,
            artifactType: []const u8,
            config: wabt.oci.Descriptor,
            layers: []const wabt.oci.Descriptor,
        }{
            .schemaVersion = 2,
            .mediaType = wabt.oci.model.media_type_oci_manifest,
            .artifactType = wabt.oci.wasm.artifact_type_wasm,
            .config = config.descriptor,
            .layers = &.{layer.descriptor},
        },
        .{},
    );
    defer allocator.free(manifest_bytes);
    const root = try ownedDescriptor(
        allocator,
        wabt.oci.model.media_type_oci_manifest,
        manifest_bytes,
    );
    defer root.deinit(allocator);
    const headers = manifestHeaders(root.descriptor.mediaType);
    var config_path_buffer: [256]u8 = undefined;
    var payload_path_buffer: [256]u8 = undefined;
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/team/app/manifests/invalid-wasm",
            .headers = &headers,
            .body = manifest_bytes,
        },
        .{
            .path_suffix = blobPath(
                &config_path_buffer,
                config.descriptor.digest,
            ),
            .class = .blob,
            .body = "{}",
        },
        .{
            .path_suffix = blobPath(
                &payload_path_buffer,
                layer.descriptor.digest,
            ),
            .class = .blob,
            .body = "not-wasm",
        },
    };
    var backend: ScriptedBackend = .{ .steps = &steps };
    var clock: FakeClock = .{};
    var factory: Factory = .{ .backend = &backend, .clock = &clock };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &factory, &clock, &capture);
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const output_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/invalid.wasm",
        .{temporary.sub_path},
    );
    defer allocator.free(output_path);
    try std.testing.expectError(
        error.InvalidContent,
        pull_cmd.execute(&.{
            "registry.example/team/app:invalid-wasm",
            "-o",
            output_path,
            "--no-credential-discovery",
        }, &runtime),
    );
    try std.testing.expectEqual(@as(usize, 3), backend.index);
    var iterator = temporary.dir.iterate();
    try std.testing.expect((try iterator.next(std.testing.io)) == null);
    try std.testing.expectEqualStrings("", capture.stdout());
}

test "pull corruption cleans staging and stdout failure remains nonzero after commit" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try wabt.oci.prepareWasmArtifact(allocator, payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:00Z",
    });
    defer package.deinit();
    const headers = manifestHeaders(package.root_descriptor.mediaType);
    var config_path_buffer: [256]u8 = undefined;
    var payload_path_buffer: [256]u8 = undefined;
    const corrupt_steps = [_]Step{
        .{
            .path_suffix = "/v2/team/app/manifests/latest",
            .headers = &headers,
            .body = package.manifest_bytes,
        },
        .{
            .path_suffix = blobPath(
                &config_path_buffer,
                package.config_descriptor.digest,
            ),
            .class = .blob,
            .body = package.config_bytes,
        },
        .{
            .path_suffix = blobPath(
                &payload_path_buffer,
                package.layer_descriptor.digest,
            ),
            .class = .blob,
            .body = "\x00asm\x01\x00\x00\x01",
        },
    };
    var backend: ScriptedBackend = .{ .steps = &corrupt_steps };
    var clock: FakeClock = .{};
    var factory: Factory = .{ .backend = &backend, .clock = &clock };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &factory, &clock, &capture);
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const output_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/module.wasm",
        .{temporary.sub_path},
    );
    defer allocator.free(output_path);
    try std.testing.expectError(
        error.InvalidContent,
        pull_cmd.execute(&.{
            "registry.example/team/app:latest",
            "-o",
            output_path,
            "--no-credential-discovery",
        }, &runtime),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "module.wasm", .{}),
    );
    var iterator = temporary.dir.iterate();
    try std.testing.expect((try iterator.next(std.testing.io)) == null);

    const wrong_size_steps = [_]Step{
        corrupt_steps[0],
        corrupt_steps[1],
        .{
            .path_suffix = blobPath(
                &payload_path_buffer,
                package.layer_descriptor.digest,
            ),
            .class = .blob,
            .body = package.payload_bytes[0 .. package.payload_bytes.len - 1],
        },
    };
    backend = .{ .steps = &wrong_size_steps };
    factory.backend = &backend;
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &factory, &clock, &capture);
    try std.testing.expectError(
        error.InvalidContent,
        pull_cmd.execute(&.{
            "registry.example/team/app:latest",
            "-o",
            output_path,
            "--no-credential-discovery",
        }, &runtime),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "module.wasm", .{}),
    );

    const bad_config = try allocator.dupe(u8, package.config_bytes);
    defer allocator.free(bad_config);
    bad_config[bad_config.len - 1] ^= 1;
    const wrong_config_steps = [_]Step{
        corrupt_steps[0],
        .{
            .path_suffix = blobPath(
                &config_path_buffer,
                package.config_descriptor.digest,
            ),
            .class = .blob,
            .body = bad_config,
        },
    };
    backend = .{ .steps = &wrong_config_steps };
    factory.backend = &backend;
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &factory, &clock, &capture);
    try std.testing.expectError(
        error.InvalidContent,
        pull_cmd.execute(&.{
            "registry.example/team/app:latest",
            "-o",
            output_path,
            "--no-credential-discovery",
        }, &runtime),
    );
    try std.testing.expectEqual(@as(usize, 2), backend.index);

    const valid_steps = [_]Step{
        corrupt_steps[0],
        corrupt_steps[1],
        .{
            .path_suffix = blobPath(
                &payload_path_buffer,
                package.layer_descriptor.digest,
            ),
            .class = .blob,
            .body = package.payload_bytes,
        },
    };
    backend = .{ .steps = &valid_steps };
    factory.backend = &backend;
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &factory, &clock, &capture);
    var failing = std.Io.Writer.failing;
    runtime.stdout = runtime_mod.OutputSink.fromWriter(&failing);
    try std.testing.expectError(
        error.StdoutWriteFailed,
        pull_cmd.execute(&.{
            "registry.example/team/app:latest",
            "-o",
            output_path,
            "--no-credential-discovery",
        }, &runtime),
    );
    const committed = try temporary.dir.readFileAlloc(
        std.testing.io,
        "module.wasm",
        allocator,
        .limited(64),
    );
    defer allocator.free(committed);
    try std.testing.expectEqualStrings(payload, committed);
}

test "layout-only read commands never construct registry or read secrets" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try wabt.oci.prepareWasmArtifact(allocator, payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:00Z",
    });
    defer package.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const layout_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/layout",
        .{temporary.sub_path},
    );
    defer allocator.free(layout_path);
    _ = try wabt.oci.copyPackageToLayout(
        std.testing.io,
        allocator,
        &package,
        .{ .path = layout_path, .selection = .{ .tag = "root" } },
        .{},
    );
    const reference = try std.fmt.allocPrint(
        allocator,
        "oci:{s}:root",
        .{layout_path},
    );
    defer allocator.free(reference);

    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = runtime_mod.Runtime.initForTest(
        allocator,
        std.testing.io,
        &counters,
    );
    capture.attach(&runtime);
    try resolve_cmd.execute(&.{reference}, &runtime);
    capture.reset();
    capture.attach(&runtime);
    try inspect_cmd.execute(&.{reference}, &runtime);
    capture.reset();
    capture.attach(&runtime);
    const output_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/layout.wasm",
        .{temporary.sub_path},
    );
    defer allocator.free(output_path);
    try pull_cmd.execute(&.{ reference, "-o", output_path }, &runtime);
    const actual = try temporary.dir.readFileAlloc(
        std.testing.io,
        "layout.wasm",
        allocator,
        .limited(64),
    );
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(payload, actual);
    try std.testing.expect(counters.isZero());
}

test "sanitized diagnostics never contain supplied secrets" {
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    capture.attach(&runtime);
    try output.writeDiagnostic(
        &runtime,
        "resolve",
        error.AuthenticationFailed,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stderr(),
        "authentication failed",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stderr(),
        "TOP_SECRET",
    ) == null);
}

const MappingFactory = struct {
    saw_basic: bool = false,
    saw_auth_file: bool = false,
    saw_none: bool = false,
    saw_discover: bool = false,
    saw_ca: bool = false,
    deadline: i128 = 0,

    fn create(
        context: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: wabt.oci.RegistryReference,
        source_options: wabt.oci.RegistryOptions,
    ) !wabt.oci.RegistrySource {
        const self: *MappingFactory = @ptrCast(@alignCast(context.?));
        self.deadline = source_options.deadline.at_ns;
        self.saw_ca = if (source_options.additional_ca) |ca| switch (ca) {
            .file_path => |path| std.mem.eql(u8, path, "ca.pem"),
            .pem_data => false,
        } else false;
        switch (source_options.credential_policy) {
            .supplied => |credential| switch (credential) {
                .basic => |basic| {
                    self.saw_basic =
                        std.mem.eql(u8, basic.username, "alice") and
                        std.mem.eql(u8, basic.secret, "secret");
                },
                .bearer_token => {},
            },
            .auth_file => |path| {
                self.saw_auth_file = std.mem.eql(u8, path, "auth.json");
            },
            .none => self.saw_none = true,
            .discover => self.saw_discover = true,
        }
        return error.MappingStop;
    }
};

const TestSecretProvider = struct {
    reads: usize = 0,

    pub fn readSecret(
        self: *TestSecretProvider,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: usize,
    ) ![]u8 {
        self.reads += 1;
        return allocator.dupe(u8, "secret\n");
    }
};

test "runtime maps credentials CA and one absolute deadline after secret input" {
    var mapping: MappingFactory = .{};
    var provider: TestSecretProvider = .{};
    var clock: FakeClock = .{ .now_ns = 40 };
    var counters: runtime_mod.Counters = .{};
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    runtime.registry_factory = .{
        .context = &mapping,
        .create_fn = MappingFactory.create,
    };
    runtime.secret_provider = runtime_mod.SecretProvider.init(&provider);
    runtime.clock = runtime_mod.Clock.init(&clock);
    const reference = (try wabt.oci.parseReference(
        "registry.example/team/app:tag",
        .source,
    )).registry;
    try std.testing.expectError(
        error.MappingStop,
        runtime.openRegistrySource(reference, .{
            .credentials = .{ .basic = .{
                .username = "alice",
                .secret = .stdin,
            } },
            .additional_ca_file = "ca.pem",
            .deadline = .{ .relative_ns = 2 * std.time.ns_per_s },
        }),
    );
    try std.testing.expect(mapping.saw_basic);
    try std.testing.expect(mapping.saw_ca);
    try std.testing.expectEqual(
        @as(i128, 40 + 2 * std.time.ns_per_s),
        mapping.deadline,
    );
    try std.testing.expectEqual(@as(usize, 1), provider.reads);
    try std.testing.expectEqual(@as(usize, 1), counters.stdin_reads);
    try std.testing.expectEqual(@as(usize, 1), counters.network_clients);

    mapping = .{};
    try std.testing.expectError(
        error.MappingStop,
        runtime.openRegistrySource(reference, .{
            .credentials = .{ .auth_file = "auth.json" },
        }),
    );
    try std.testing.expect(mapping.saw_auth_file);

    mapping = .{};
    try std.testing.expectError(
        error.MappingStop,
        runtime.openRegistrySource(reference, .{
            .credentials = .none,
        }),
    );
    try std.testing.expect(mapping.saw_none);

    mapping = .{};
    try std.testing.expectError(
        error.MappingStop,
        runtime.openRegistrySource(reference, .{}),
    );
    try std.testing.expect(mapping.saw_discover);
    try std.testing.expectEqual(
        @as(usize, 1),
        counters.credential_discoveries,
    );
}
