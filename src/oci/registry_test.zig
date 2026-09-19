const std = @import("std");
const oci = @import("wabt").oci;
const auth = oci.auth;
const content = oci.content;
const model = oci.model;
const reference = oci.reference;
const registry = oci.registry;
const registry_http = oci.registry_http;
const transport = oci.transport;
const wasm = oci.wasm;

const Allocator = std.mem.Allocator;

const FakeRuntime = struct {
    now_ns: i128 = 0,
    sleep_count: usize = 0,

    fn clock(self: *FakeRuntime) registry_http.Clock {
        return registry_http.Clock.initWithUnixSeconds(self);
    }

    fn sleeper(self: *FakeRuntime) registry_http.Sleeper {
        return registry_http.Sleeper.init(self);
    }

    pub fn now(self: *FakeRuntime) i128 {
        return self.now_ns;
    }

    pub fn unixSeconds(_: *FakeRuntime) i64 {
        return 0;
    }

    pub fn sleep(
        self: *FakeRuntime,
        duration_ns: u64,
    ) registry_http.SleepError!void {
        self.sleep_count += 1;
        self.now_ns += duration_ns;
    }
};

const FileProbe = struct {
    calls: usize = 0,

    fn reader(self: *FileProbe) auth.FileReader {
        return .{ .context = self, .read = read };
    }

    fn read(
        context: ?*anyopaque,
        _: Allocator,
        _: std.Io,
        _: []const u8,
        _: usize,
    ) auth.FileReadError![]u8 {
        const self: *FileProbe = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return error.FileNotFound;
    }
};

const Step = struct {
    method: std.http.Method = .GET,
    path_suffix: []const u8,
    class: registry_http.RequestClass,
    status: u16 = 200,
    headers: []const registry_http.Header = &.{},
    body: []const u8 = "",
    failure: ?registry_http.BackendError = null,
    stream_failure_after: ?usize = null,
    advance_ns: u64 = 0,
};

const ScriptedBackend = struct {
    runtime: *FakeRuntime,
    steps: []const Step,
    index: usize = 0,
    urls: [64][2048]u8 = undefined,
    url_lengths: [64]usize = @splat(0),
    authorizations: [64][1024]u8 = undefined,
    authorization_lengths: [64]usize = @splat(0),

    fn backend(self: *ScriptedBackend) registry_http.Backend {
        return registry_http.Backend.init(self, .{
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
        allocator: Allocator,
        options: registry_http.BackendRequest,
    ) registry_http.BackendError!registry_http.Response {
        if (self.index >= self.steps.len or self.index >= self.urls.len) {
            return error.ProtocolFailure;
        }
        const current = self.index;
        const step = self.steps[current];
        self.index += 1;
        self.runtime.now_ns += step.advance_ns;
        if (options.method != step.method or
            !std.mem.endsWith(u8, options.url, step.path_suffix) or
            options.class != step.class or options.url.len > self.urls[current].len)
        {
            return error.ProtocolFailure;
        }
        @memcpy(self.urls[current][0..options.url.len], options.url);
        self.url_lengths[current] = options.url.len;
        if (options.authorization) |value| {
            if (value.len > self.authorizations[current].len) {
                return error.ProtocolFailure;
            }
            @memcpy(self.authorizations[current][0..value.len], value);
            self.authorization_lengths[current] = value.len;
        }
        if (step.failure) |failure| return failure;

        if (options.body_sink) |sink| {
            if (step.status >= 200 and step.status < 300) {
                const declared_length = headerU64(step.headers, "Content-Length");
                sink.begin(declared_length) catch return error.BodySinkFailed;
                if (step.stream_failure_after) |limit| {
                    const count = @min(limit, step.body.len);
                    if (count != 0) {
                        sink.write(step.body[0..count]) catch
                            return error.BodySinkFailed;
                    }
                    return error.ReadFailed;
                }
                var offset: usize = 0;
                while (offset < step.body.len) {
                    const end = @min(offset + 7, step.body.len);
                    sink.write(step.body[offset..end]) catch
                        return error.BodySinkFailed;
                    offset = end;
                }
                sink.finish() catch return error.BodySinkFailed;
                return registry_http.Response.initCopy(
                    allocator,
                    step.status,
                    step.headers,
                    "",
                ) catch error.OutOfMemory;
            }
        }
        return registry_http.Response.initCopy(
            allocator,
            step.status,
            step.headers,
            step.body,
        ) catch error.OutOfMemory;
    }

    fn url(self: *const ScriptedBackend, index: usize) []const u8 {
        return self.urls[index][0..self.url_lengths[index]];
    }

    fn authorization(
        self: *const ScriptedBackend,
        index: usize,
    ) ?[]const u8 {
        const length = self.authorization_lengths[index];
        return if (length == 0)
            null
        else
            self.authorizations[index][0..length];
    }
};

const LoopbackFixture = struct {
    listener: *std.Io.net.Server,
    manifest: []const u8,
    manifest_digest: []const u8,
    blob: []const u8,
    blob_digest: []const u8,
    failure: ?anyerror = null,
    saw_manifest_accept: bool = false,

    fn serve(self: *LoopbackFixture) std.Io.Cancelable!void {
        self.serveInner() catch |err| {
            self.failure = err;
        };
    }

    fn serveInner(self: *LoopbackFixture) !void {
        for (0..2) |_| {
            const stream = try self.listener.accept(std.testing.io);
            defer stream.close(std.testing.io);
            var receive_buffer: [4096]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var connection_reader = stream.reader(std.testing.io, &receive_buffer);
            var connection_writer = stream.writer(std.testing.io, &send_buffer);
            var server = std.http.Server.init(
                &connection_reader.interface,
                &connection_writer.interface,
            );
            var request = try server.receiveHead();
            if (std.mem.eql(u8, request.head.target, "/v2/repo/manifests/latest")) {
                var iterator = request.iterateHeaders();
                while (iterator.next()) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "Accept") and
                        std.mem.indexOf(u8, header.value, model.media_type_oci_manifest) != null and
                        std.mem.indexOf(u8, header.value, model.media_type_docker_manifest_list) != null)
                    {
                        self.saw_manifest_accept = true;
                    }
                }
                const headers = [_]std.http.Header{
                    .{ .name = "Content-Type", .value = model.media_type_oci_manifest },
                    .{ .name = "Docker-Content-Digest", .value = self.manifest_digest },
                };
                try request.respond(self.manifest, .{
                    .keep_alive = false,
                    .extra_headers = &headers,
                });
            } else {
                const expected_blob_path = try std.fmt.allocPrint(
                    std.testing.allocator,
                    "/v2/repo/blobs/{s}",
                    .{self.blob_digest},
                );
                defer std.testing.allocator.free(expected_blob_path);
                if (!std.mem.eql(u8, request.head.target, expected_blob_path)) {
                    return error.UnexpectedRequest;
                }
                const headers = [_]std.http.Header{
                    .{ .name = "Content-Type", .value = "application/octet-stream" },
                    .{ .name = "Docker-Content-Digest", .value = self.blob_digest },
                };
                try request.respond(self.blob, .{
                    .keep_alive = false,
                    .extra_headers = &headers,
                });
            }
        }
    }
};

fn headerU64(
    headers: []const registry_http.Header,
    name: []const u8,
) ?u64 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return std.fmt.parseInt(u64, header.value, 10) catch null;
        }
    }
    return null;
}

fn initSource(
    backend: *ScriptedBackend,
    runtime: *FakeRuntime,
    selection: ?reference.Selection,
    credential_policy: auth.CredentialPolicy,
    limits: registry.Limits,
) !registry.Source {
    return registry.Source.initWithBackend(
        std.testing.io,
        std.testing.allocator,
        .{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = selection,
        },
        backend.backend(),
        runtime.clock(),
        runtime.sleeper(),
        .{
            .plain_http = true,
            .credential_policy = credential_policy,
            .auth_context = .{ .io = std.testing.io },
            .limits = limits,
            .deadline = .after(runtime.clock(), 60 * std.time.ns_per_s),
            .auth_context_id = 17,
            .credential_generation = 3,
        },
    );
}

const DestinationConfig = struct {
    authority: []const u8 = "localhost:5000",
    repository: []const u8 = "dest",
    selection: ?reference.Selection = .{ .tag = "latest" },
    credential_policy: auth.CredentialPolicy = .none,
    limits: registry.Limits = .{},
    graph_limits: oci.graph.Limits = .{},
    http_limits: registry_http.Limits = .{},
    mount_policy: registry.MountPolicy = .same_origin,
    deadline_ns: i128 = 60 * std.time.ns_per_s,
};

fn initDestination(
    backend: *ScriptedBackend,
    runtime: *FakeRuntime,
    config: DestinationConfig,
) !registry.Destination {
    return registry.Destination.initWithBackend(
        std.testing.io,
        std.testing.allocator,
        .{
            .authority = config.authority,
            .repository = config.repository,
            .selection = config.selection,
        },
        backend.backend(),
        runtime.clock(),
        runtime.sleeper(),
        .{
            .plain_http = std.mem.startsWith(u8, config.authority, "localhost") or
                std.mem.startsWith(u8, config.authority, "127."),
            .credential_policy = config.credential_policy,
            .auth_context = .{ .io = std.testing.io },
            .limits = config.limits,
            .graph_limits = config.graph_limits,
            .http_limits = config.http_limits,
            .deadline = .{ .at_ns = config.deadline_ns },
            .auth_context_id = 29,
            .credential_generation = 7,
            .mount_policy = config.mount_policy,
        },
    );
}

fn initRegistrySourceAt(
    backend: *ScriptedBackend,
    runtime: *FakeRuntime,
    authority: []const u8,
    repository: []const u8,
    credential_policy: auth.CredentialPolicy,
) !registry.Source {
    return registry.Source.initWithBackend(
        std.testing.io,
        std.testing.allocator,
        .{
            .authority = authority,
            .repository = repository,
            .selection = null,
        },
        backend.backend(),
        runtime.clock(),
        runtime.sleeper(),
        .{
            .plain_http = std.mem.startsWith(u8, authority, "localhost") or
                std.mem.startsWith(u8, authority, "127."),
            .credential_policy = credential_policy,
            .auth_context = .{ .io = std.testing.io },
            .deadline = .after(runtime.clock(), 60 * std.time.ns_per_s),
            .auth_context_id = 11,
            .credential_generation = 2,
        },
    );
}

const NoReadSource = struct {
    reads: usize = 0,

    pub fn readMetadata(
        self: *NoReadSource,
        _: Allocator,
        _: model.Descriptor,
        _: u64,
    ) !transport.Metadata {
        self.reads += 1;
        return error.UnexpectedSourceRead;
    }

    pub fn copyVerifiedTo(
        self: *NoReadSource,
        _: model.Descriptor,
        _: std.Io.File,
    ) !void {
        self.reads += 1;
        return error.UnexpectedSourceRead;
    }
};

fn blobTransfer(
    source: transport.Source,
    value: model.Descriptor,
) transport.DescriptorTransfer {
    return .{
        .descriptor = value,
        .roles = transport.DescriptorRoles.init(.layer),
        .data = .{ .opaque_blob = source },
    };
}

const TestDescriptor = struct {
    digest: content.Digest,
    digest_text: [content.digest_text_size]u8,
    media_type: []const u8,
    size: u64,

    fn value(self: *const TestDescriptor) model.Descriptor {
        return .{
            .mediaType = self.media_type,
            .digest = &self.digest_text,
            .size = self.size,
        };
    }
};

fn descriptor(
    bytes: []const u8,
    media_type: []const u8,
) TestDescriptor {
    const digest = content.digestBytes(bytes);
    return .{
        .digest = digest,
        .digest_text = digest.format(),
        .media_type = media_type,
        .size = bytes.len,
    };
}

fn makeManifest(
    allocator: Allocator,
    config: model.Descriptor,
    layers: []const model.Descriptor,
    include_media_type: bool,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("{\"schemaVersion\":2");
    if (include_media_type) {
        try output.writer.print(
            ",\"mediaType\":\"{s}\"",
            .{model.media_type_oci_manifest},
        );
    }
    try output.writer.print(
        ",\"config\":{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[",
        .{ config.mediaType, config.digest, config.size },
    );
    for (layers, 0..) |layer, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print(
            "{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}",
            .{ layer.mediaType, layer.digest, layer.size },
        );
    }
    try output.writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn makeIndex(
    allocator: Allocator,
    child: model.Descriptor,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{
            model.media_type_oci_index,
            child.mediaType,
            child.digest,
            child.size,
        },
    );
}

fn headersFor(
    allocator: Allocator,
    media_type: ?[]const u8,
    body: []const u8,
    digest_value: ?[]const u8,
    extra: []const registry_http.Header,
) !struct {
    length: []u8,
    values: []registry_http.Header,
} {
    const length = try std.fmt.allocPrint(allocator, "{d}", .{body.len});
    errdefer allocator.free(length);
    const count: usize = 1 +
        @as(usize, @intFromBool(media_type != null)) +
        @as(usize, @intFromBool(digest_value != null)) +
        extra.len;
    const values = try allocator.alloc(registry_http.Header, count);
    var index: usize = 0;
    values[index] = .{ .name = "Content-Length", .value = length };
    index += 1;
    if (media_type) |value| {
        values[index] = .{ .name = "Content-Type", .value = value };
        index += 1;
    }
    if (digest_value) |value| {
        values[index] = .{ .name = "Docker-Content-Digest", .value = value };
        index += 1;
    }
    @memcpy(values[index..], extra);
    return .{ .length = length, .values = values };
}

fn freeHeaders(
    allocator: Allocator,
    owned: anytype,
) void {
    allocator.free(owned.values);
    allocator.free(owned.length);
}

test "production source initialization is explicit and loopback HTTP only" {
    var source = try registry.Source.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .authority = "LOCALHOST:5000",
            .repository = "repo",
            .selection = null,
        },
        .{
            .plain_http = true,
            .credential_policy = .none,
            .auth_context = .{ .io = std.testing.io },
            .deadline = .{ .at_ns = std.math.maxInt(i128) },
        },
    );
    try std.testing.expectEqualStrings("localhost:5000", source.authority);
    try std.testing.expectError(
        error.InvalidReference,
        source.resolve(.{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = .{ .tag = "../latest" },
        }),
    );
    source.deinit();

    try std.testing.expectError(
        error.InsecureTransport,
        registry.Source.init(
            std.testing.io,
            std.testing.allocator,
            .{
                .authority = "registry.example",
                .repository = "repo",
                .selection = null,
            },
            .{
                .plain_http = true,
                .credential_policy = .none,
                .auth_context = .{ .io = std.testing.io },
                .deadline = .{ .at_ns = std.math.maxInt(i128) },
            },
        ),
    );
    try std.testing.expectError(
        error.InvalidReference,
        registry.Source.init(
            std.testing.io,
            std.testing.allocator,
            .{
                .authority = "localhost:5000",
                .repository = "../escape",
                .selection = null,
            },
            .{
                .plain_http = true,
                .credential_policy = .none,
                .auth_context = .{ .io = std.testing.io },
                .deadline = .{ .at_ns = std.math.maxInt(i128) },
            },
        ),
    );

    var runtime: FakeRuntime = .{};
    const no_steps = [_]Step{};
    var backend: ScriptedBackend = .{
        .runtime = &runtime,
        .steps = &no_steps,
    };
    var files: FileProbe = .{};
    try std.testing.expectError(
        error.InsecureTransport,
        registry.Source.initWithBackend(
            std.testing.io,
            std.testing.allocator,
            .{
                .authority = "registry.example",
                .repository = "repo",
                .selection = null,
            },
            backend.backend(),
            runtime.clock(),
            runtime.sleeper(),
            .{
                .plain_http = true,
                .credential_policy = .{ .auth_file = "must-not-read.json" },
                .auth_context = .{
                    .io = std.testing.io,
                    .files = files.reader(),
                },
                .deadline = .after(runtime.clock(), 60 * std.time.ns_per_s),
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), files.calls);
}

test "credential helpers consume only the remaining source deadline" {
    const DelayedFiles = struct {
        runtime: *FakeRuntime,
        advance_ns: u64,

        fn reader(self: *@This()) auth.FileReader {
            return .{ .context = self, .read = read };
        }

        fn read(
            context: ?*anyopaque,
            allocator: Allocator,
            _: std.Io,
            path: []const u8,
            limit: usize,
        ) auth.FileReadError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.runtime.now_ns += self.advance_ns;
            if (!std.mem.eql(u8, path, "auth.json")) return error.FileNotFound;
            const document = "{\"credsStore\":\"test\"}";
            if (document.len > limit) return error.InputTooLarge;
            return allocator.dupe(u8, document);
        }
    };
    const Helper = struct {
        runtime: *FakeRuntime,
        fail_on_deadline: bool = false,
        calls: usize = 0,
        timeout_ns: u64 = 0,
        valid: bool = true,

        fn runner(self: *@This()) auth.ProcessRunner {
            return .{ .context = self, .run = run };
        }

        fn run(
            context: ?*anyopaque,
            allocator: Allocator,
            _: std.Io,
            argv: []const []const u8,
            stdin_data: []const u8,
            _: usize,
            timeout_ns: u64,
        ) auth.ProcessError!auth.ProcessResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.timeout_ns = timeout_ns;
            if (argv.len != 2 or
                !std.mem.eql(u8, argv[0], "docker-credential-test") or
                !std.mem.eql(u8, argv[1], "get") or
                !std.mem.eql(u8, stdin_data, "localhost:5000\n"))
            {
                self.valid = false;
            }
            if (self.fail_on_deadline) {
                self.runtime.now_ns += timeout_ns;
                return error.DeadlineExceeded;
            }
            return .{ .stdout = try allocator.dupe(
                u8,
                "{\"Username\":\"reader\",\"Secret\":\"secret\"}",
            ) };
        }
    };

    const no_steps = [_]Step{};
    var runtime: FakeRuntime = .{};
    var backend: ScriptedBackend = .{
        .runtime = &runtime,
        .steps = &no_steps,
    };
    var files: DelayedFiles = .{
        .runtime = &runtime,
        .advance_ns = 9 * std.time.ns_per_s,
    };
    var helper: Helper = .{ .runtime = &runtime };
    var source = try registry.Source.initWithBackend(
        std.testing.io,
        std.testing.allocator,
        .{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = null,
        },
        backend.backend(),
        runtime.clock(),
        runtime.sleeper(),
        .{
            .plain_http = true,
            .credential_policy = .{ .auth_file = "auth.json" },
            .auth_context = .{
                .io = std.testing.io,
                .files = files.reader(),
                .process = helper.runner(),
            },
            .deadline = .after(runtime.clock(), 10 * std.time.ns_per_s),
        },
    );
    source.deinit();
    try std.testing.expect(helper.valid);
    try std.testing.expectEqual(@as(usize, 1), helper.calls);
    try std.testing.expectEqual(std.time.ns_per_s, helper.timeout_ns);

    var deadline_runtime: FakeRuntime = .{};
    var deadline_backend: ScriptedBackend = .{
        .runtime = &deadline_runtime,
        .steps = &no_steps,
    };
    var deadline_files: DelayedFiles = .{
        .runtime = &deadline_runtime,
        .advance_ns = 9 * std.time.ns_per_s,
    };
    var deadline_helper: Helper = .{
        .runtime = &deadline_runtime,
        .fail_on_deadline = true,
    };
    try std.testing.expectError(
        error.DeadlineExceeded,
        registry.Source.initWithBackend(
            std.testing.io,
            std.testing.allocator,
            .{
                .authority = "localhost:5000",
                .repository = "repo",
                .selection = null,
            },
            deadline_backend.backend(),
            deadline_runtime.clock(),
            deadline_runtime.sleeper(),
            .{
                .plain_http = true,
                .credential_policy = .{ .auth_file = "auth.json" },
                .auth_context = .{
                    .io = std.testing.io,
                    .files = deadline_files.reader(),
                    .process = deadline_helper.runner(),
                },
                .deadline = .after(
                    deadline_runtime.clock(),
                    10 * std.time.ns_per_s,
                ),
            },
        ),
    );
    try std.testing.expect(deadline_helper.valid);
    try std.testing.expectEqual(@as(usize, 1), deadline_helper.calls);
    try std.testing.expectEqual(std.time.ns_per_s, deadline_helper.timeout_ns);
}

test "production loopback backend negotiates manifests and streams verified blobs" {
    const allocator = std.testing.allocator;
    const blob_bytes = "wire-streamed-blob";
    const blob_value = descriptor(blob_bytes, "application/octet-stream");
    const config_value = descriptor("{}", model.media_type_oci_empty_config);
    const layers = [_]model.Descriptor{blob_value.value()};
    const manifest = try makeManifest(
        allocator,
        config_value.value(),
        &layers,
        true,
    );
    defer allocator.free(manifest);
    const root_value = descriptor(manifest, model.media_type_oci_manifest);

    const address = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var listener = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);
    const authority = try std.fmt.allocPrint(
        allocator,
        "127.0.0.1:{d}",
        .{listener.socket.address.getPort()},
    );
    defer allocator.free(authority);
    var fixture: LoopbackFixture = .{
        .listener = &listener,
        .manifest = manifest,
        .manifest_digest = &root_value.digest_text,
        .blob = blob_bytes,
        .blob_digest = &blob_value.digest_text,
    };
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    group.async(std.testing.io, LoopbackFixture.serve, .{&fixture});

    var source = try registry.Source.init(
        std.testing.io,
        allocator,
        .{
            .authority = authority,
            .repository = "repo",
            .selection = .{ .tag = "latest" },
        },
        .{
            .plain_http = true,
            .credential_policy = .none,
            .auth_context = .{ .io = std.testing.io },
            .deadline = .{ .at_ns = std.math.maxInt(i128) },
        },
    );
    defer source.deinit();
    var resolved = try source.resolve(.{
        .authority = authority,
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer resolved.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "wire-blob", .{ .read = true });
    defer output.close(std.testing.io);
    try source.copyVerifiedTo(blob_value.value(), output);
    try group.await(std.testing.io);
    try std.testing.expect(fixture.failure == null);
    try std.testing.expect(fixture.saw_manifest_accept);
    const copied = try allocator.alloc(u8, blob_bytes.len);
    defer allocator.free(copied);
    try std.testing.expectEqual(
        blob_bytes.len,
        try output.readPositionalAll(std.testing.io, copied, 0),
    );
    try std.testing.expectEqualSlices(u8, blob_bytes, copied);
}

test "resolve pins a moved tag once and all later reads use exact digest paths" {
    const allocator = std.testing.allocator;
    const config_bytes = "{}";
    const layer_bytes = "payload bytes";
    const config_value = descriptor(config_bytes, model.media_type_oci_empty_config);
    const layer_value = descriptor(layer_bytes, "application/wasm");
    const layers = [_]model.Descriptor{layer_value.value()};
    const manifest = try makeManifest(
        allocator,
        config_value.value(),
        &layers,
        true,
    );
    defer allocator.free(manifest);
    const root_value = descriptor(manifest, model.media_type_oci_manifest);
    const moved_config = descriptor(
        "{\"moved\":true}",
        model.media_type_oci_empty_config,
    );
    const moved_manifest = try makeManifest(
        allocator,
        moved_config.value(),
        &.{},
        true,
    );
    defer allocator.free(moved_manifest);
    const moved_root = descriptor(moved_manifest, model.media_type_oci_manifest);
    const manifest_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        manifest,
        &root_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, manifest_headers);
    const moved_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        moved_manifest,
        &moved_root.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, moved_headers);
    const layer_headers = try headersFor(
        allocator,
        "application/octet-stream",
        layer_bytes,
        &layer_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, layer_headers);
    const layer_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&layer_value.digest_text},
    );
    defer allocator.free(layer_path);
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = manifest_headers.values,
            .body = manifest,
        },
        .{
            .path_suffix = layer_path,
            .class = .blob,
            .headers = layer_headers.values,
            .body = layer_bytes,
        },
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = moved_headers.values,
            .body = moved_manifest,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        .{ .tag = "latest" },
        .none,
        .{},
    );
    defer source.deinit();

    var resolved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer resolved.deinit();
    try std.testing.expectEqualStrings("latest", resolved.requested_tag.?);
    try std.testing.expectEqualSlices(u8, manifest, resolved.bytes);
    try std.testing.expect(std.mem.endsWith(
        u8,
        resolved.canonical_reference,
        &root_value.digest_text,
    ));

    try std.testing.expectError(
        error.LimitExceeded,
        source.inspectResolved(&resolved, .{
            .limits = .{ .max_nodes = 0 },
        }),
    );
    try std.testing.expectEqual(
        registry.Category.limit,
        source.lastDiagnostic().?.category,
    );
    try std.testing.expectEqual(
        registry.Operation.inspect,
        source.lastDiagnostic().?.operation,
    );

    var inspected = try source.inspectResolved(&resolved, .{});
    defer inspected.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.index);
    try std.testing.expectEqualSlices(u8, manifest, inspected.plan.rootNode().exact_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "blob", .{ .read = true });
    defer output.close(std.testing.io);
    try source.copyVerifiedTo(layer_value.value(), output);
    try std.testing.expectEqual(@as(usize, 2), fake.index);
    const copied = try allocator.alloc(u8, layer_bytes.len);
    defer allocator.free(copied);
    try std.testing.expectEqual(
        layer_bytes.len,
        try output.readPositionalAll(std.testing.io, copied, 0),
    );
    try std.testing.expectEqualSlices(u8, layer_bytes, copied);
    try std.testing.expect(std.mem.endsWith(u8, fake.url(0), "/manifests/latest"));
    try std.testing.expect(std.mem.endsWith(u8, fake.url(1), layer_path));

    var moved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer moved.deinit();
    try std.testing.expectEqualStrings(&moved_root.digest_text, moved.descriptor.digest);
    try std.testing.expect(!std.mem.eql(
        u8,
        resolved.descriptor.digest,
        moved.descriptor.digest,
    ));
    try std.testing.expectEqual(@as(usize, 3), fake.index);
}

test "registry extraction resolves once before a tag moves" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x03, 0x61, 0x62, 0x63,
    };
    var package = try wasm.prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:00Z",
        .source_name = "registry.wasm",
    });
    defer package.deinit();
    var moved_package = try wasm.prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:01Z",
        .source_name = "registry.wasm",
    });
    defer moved_package.deinit();

    const manifest_headers = try headersFor(
        allocator,
        wasm.media_type_manifest,
        package.manifest_bytes,
        package.root_descriptor.digest,
        &.{},
    );
    defer freeHeaders(allocator, manifest_headers);
    const moved_headers = try headersFor(
        allocator,
        wasm.media_type_manifest,
        moved_package.manifest_bytes,
        moved_package.root_descriptor.digest,
        &.{},
    );
    defer freeHeaders(allocator, moved_headers);
    const config_headers = try headersFor(
        allocator,
        "application/octet-stream",
        package.config_bytes,
        package.config_descriptor.digest,
        &.{},
    );
    defer freeHeaders(allocator, config_headers);
    const layer_headers = try headersFor(
        allocator,
        "application/octet-stream",
        package.payload_bytes,
        package.layer_descriptor.digest,
        &.{},
    );
    defer freeHeaders(allocator, layer_headers);
    const config_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{package.config_descriptor.digest},
    );
    defer allocator.free(config_path);
    const layer_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{package.layer_descriptor.digest},
    );
    defer allocator.free(layer_path);
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = manifest_headers.values,
            .body = package.manifest_bytes,
        },
        .{
            .path_suffix = config_path,
            .class = .blob,
            .headers = config_headers.values,
            .body = package.config_bytes,
        },
        .{
            .path_suffix = layer_path,
            .class = .blob,
            .headers = layer_headers.values,
            .body = package.payload_bytes,
        },
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = moved_headers.values,
            .body = moved_package.manifest_bytes,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        .{ .tag = "latest" },
        .none,
        .{},
    );
    defer source.deinit();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const output = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/registry-extracted.wasm",
        .{tmp.sub_path},
    );
    defer allocator.free(output);
    const result = try oci.extractRegistrySource(
        allocator,
        &source,
        .{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = .{ .tag = "latest" },
        },
        output,
        .{},
    );
    try std.testing.expectEqual(wasm.DirectManifestProfile.oci_1_1, result.profile);
    try std.testing.expectEqual(wasm.WasmKind.core_module, result.kind);
    try std.testing.expectEqual(@as(usize, 3), fake.index);
    try std.testing.expect(std.mem.endsWith(
        u8,
        fake.url(0),
        "/v2/repo/manifests/latest",
    ));
    try std.testing.expect(std.mem.endsWith(u8, fake.url(1), config_path));
    try std.testing.expect(std.mem.endsWith(u8, fake.url(2), layer_path));
    const extracted = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        output,
        allocator,
        .limited(wasm.max_payload_bytes),
    );
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &payload, extracted);

    var moved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer moved.deinit();
    try std.testing.expectEqualStrings(
        moved_package.root_descriptor.digest,
        moved.descriptor.digest,
    );
    try std.testing.expectEqual(@as(usize, 4), fake.index);
}

test "digest resolution verifies bytes and conflicting digest headers are never trusted" {
    const allocator = std.testing.allocator;
    const config_value = descriptor("{}", model.media_type_oci_empty_config);
    const manifest = try makeManifest(allocator, config_value.value(), &.{}, true);
    defer allocator.free(manifest);
    const root_value = descriptor(manifest, model.media_type_oci_manifest);
    const good_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        manifest,
        null,
        &.{},
    );
    defer freeHeaders(allocator, good_headers);
    const path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/manifests/{s}",
        .{&root_value.digest_text},
    );
    defer allocator.free(path);
    const steps = [_]Step{.{
        .path_suffix = path,
        .class = .registry,
        .headers = good_headers.values,
        .body = manifest,
    }};
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        .{ .digest = root_value.digest },
        .none,
        .{},
    );
    defer source.deinit();
    var resolved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .digest = root_value.digest },
    });
    defer resolved.deinit();
    try std.testing.expect(resolved.requested_tag == null);

    const corrupt_manifest = try allocator.dupe(u8, manifest);
    defer allocator.free(corrupt_manifest);
    corrupt_manifest[corrupt_manifest.len - 1] = ' ';
    const corrupt_steps = [_]Step{.{
        .path_suffix = path,
        .class = .registry,
        .headers = good_headers.values,
        .body = corrupt_manifest,
    }};
    var corrupt_runtime: FakeRuntime = .{};
    var corrupt_fake: ScriptedBackend = .{
        .runtime = &corrupt_runtime,
        .steps = &corrupt_steps,
    };
    var corrupt_source = try initSource(
        &corrupt_fake,
        &corrupt_runtime,
        .{ .digest = root_value.digest },
        .none,
        .{},
    );
    defer corrupt_source.deinit();
    try std.testing.expectError(error.InvalidContent, corrupt_source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .digest = root_value.digest },
    }));

    var bad_runtime: FakeRuntime = .{};
    const wrong_digest = content.digestBytes("wrong").format();
    const bad_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        manifest,
        &wrong_digest,
        &.{},
    );
    defer freeHeaders(allocator, bad_headers);
    const bad_steps = [_]Step{.{
        .path_suffix = path,
        .class = .registry,
        .headers = bad_headers.values,
        .body = manifest,
    }};
    var bad_fake: ScriptedBackend = .{
        .runtime = &bad_runtime,
        .steps = &bad_steps,
    };
    var bad_source = try initSource(
        &bad_fake,
        &bad_runtime,
        .{ .digest = root_value.digest },
        .none,
        .{},
    );
    defer bad_source.deinit();
    try std.testing.expectError(error.InvalidContent, bad_source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .digest = root_value.digest },
    }));

    const duplicate_headers = [_]registry_http.Header{
        .{ .name = "Content-Length", .value = good_headers.length },
        .{ .name = "Content-Type", .value = model.media_type_oci_manifest },
        .{ .name = "Docker-Content-Digest", .value = &root_value.digest_text },
        .{ .name = "Docker-Content-Digest", .value = &root_value.digest_text },
    };
    const duplicate_steps = [_]Step{.{
        .path_suffix = path,
        .class = .registry,
        .headers = &duplicate_headers,
        .body = manifest,
    }};
    var duplicate_runtime: FakeRuntime = .{};
    var duplicate_fake: ScriptedBackend = .{
        .runtime = &duplicate_runtime,
        .steps = &duplicate_steps,
    };
    var duplicate_source = try initSource(
        &duplicate_fake,
        &duplicate_runtime,
        .{ .digest = root_value.digest },
        .none,
        .{},
    );
    defer duplicate_source.deinit();
    try std.testing.expectError(error.InvalidContent, duplicate_source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .digest = root_value.digest },
    }));
}

test "metadata uses descriptor endpoints with exact length digest and media checks" {
    const allocator = std.testing.allocator;
    const bytes = "{\"x\":1}";
    const value = descriptor(bytes, "application/vnd.example.config+json");
    const good_headers = try headersFor(
        allocator,
        "application/octet-stream",
        bytes,
        &value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, good_headers);
    const path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&value.digest_text},
    );
    defer allocator.free(path);
    const steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .headers = good_headers.values,
        .body = bytes,
    }};
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(&fake, &runtime, null, .none, .{});
    defer source.deinit();
    var metadata = try source.readMetadata(allocator, value.value(), bytes.len);
    defer metadata.deinit();
    try std.testing.expectEqualSlices(u8, bytes, metadata.bytes);

    const no_length_headers = [_]registry_http.Header{
        .{ .name = "Docker-Content-Digest", .value = &value.digest_text },
    };
    const no_length_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .headers = &no_length_headers,
        .body = bytes,
    }};
    var no_length_runtime: FakeRuntime = .{};
    var no_length_fake: ScriptedBackend = .{
        .runtime = &no_length_runtime,
        .steps = &no_length_steps,
    };
    var no_length_source = try initSource(
        &no_length_fake,
        &no_length_runtime,
        null,
        .none,
        .{},
    );
    defer no_length_source.deinit();
    var no_length_metadata = try no_length_source.readMetadata(
        allocator,
        value.value(),
        bytes.len,
    );
    defer no_length_metadata.deinit();
    try std.testing.expectEqualSlices(u8, bytes, no_length_metadata.bytes);

    const encoded_headers = [_]registry_http.Header{
        .{ .name = "Content-Length", .value = good_headers.length },
        .{ .name = "Content-Encoding", .value = "gzip" },
    };
    const encoded_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .headers = &encoded_headers,
        .body = bytes,
    }};
    var encoded_runtime: FakeRuntime = .{};
    var encoded_fake: ScriptedBackend = .{
        .runtime = &encoded_runtime,
        .steps = &encoded_steps,
    };
    var encoded_source = try initSource(
        &encoded_fake,
        &encoded_runtime,
        null,
        .none,
        .{},
    );
    defer encoded_source.deinit();
    try std.testing.expectError(
        error.InvalidContent,
        encoded_source.readMetadata(allocator, value.value(), bytes.len),
    );
    try std.testing.expectEqual(
        registry.Category.invalid_content,
        encoded_source.lastDiagnostic().?.category,
    );

    var bad_runtime: FakeRuntime = .{};
    const bad_length = "999";
    const bad_headers = [_]registry_http.Header{
        .{ .name = "Content-Length", .value = bad_length },
    };
    const bad_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .headers = &bad_headers,
        .body = bytes,
    }};
    var bad_fake: ScriptedBackend = .{
        .runtime = &bad_runtime,
        .steps = &bad_steps,
    };
    var bad_source = try initSource(&bad_fake, &bad_runtime, null, .none, .{});
    defer bad_source.deinit();
    try std.testing.expectError(
        error.InvalidContent,
        bad_source.readMetadata(allocator, value.value(), bytes.len),
    );

    const empty = descriptor("", "application/octet-stream");
    const empty_headers = try headersFor(
        allocator,
        "application/octet-stream",
        "",
        &empty.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, empty_headers);
    const empty_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&empty.digest_text},
    );
    defer allocator.free(empty_path);
    const empty_steps = [_]Step{.{
        .path_suffix = empty_path,
        .class = .blob,
        .headers = empty_headers.values,
    }};
    var empty_runtime: FakeRuntime = .{};
    var empty_fake: ScriptedBackend = .{
        .runtime = &empty_runtime,
        .steps = &empty_steps,
    };
    var empty_source = try initSource(
        &empty_fake,
        &empty_runtime,
        null,
        .none,
        .{},
    );
    defer empty_source.deinit();
    var empty_metadata = try empty_source.readMetadata(
        allocator,
        empty.value(),
        0,
    );
    defer empty_metadata.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_metadata.bytes.len);
}

test "bearer token acquisition is scope exact cached and secret safe" {
    const allocator = std.testing.allocator;
    const config_bytes = "{}";
    const config_value = descriptor(config_bytes, model.media_type_oci_empty_config);
    const manifest = try makeManifest(allocator, config_value.value(), &.{}, true);
    defer allocator.free(manifest);
    const root_value = descriptor(manifest, model.media_type_oci_manifest);
    const challenge =
        "Bearer realm=\"http://localhost:5000/token\",service=\"registry.local\",scope=\"repository:repo:pull\"";
    const challenge_headers = [_]registry_http.Header{
        .{ .name = "WWW-Authenticate", .value = challenge },
    };
    const token_body = "{\"token\":\"scope-token\",\"expires_in\":300}";
    const token_headers = try headersFor(
        allocator,
        "application/json",
        token_body,
        null,
        &.{},
    );
    defer freeHeaders(allocator, token_headers);
    const manifest_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        manifest,
        &root_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, manifest_headers);
    const config_headers = try headersFor(
        allocator,
        "application/octet-stream",
        config_bytes,
        &config_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, config_headers);
    const config_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&config_value.digest_text},
    );
    defer allocator.free(config_path);
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .status = 401,
            .headers = &challenge_headers,
        },
        .{
            .path_suffix = "/token?service=registry.local&scope=repository%3Arepo%3Apull",
            .class = .token,
            .headers = token_headers.values,
            .body = token_body,
        },
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = manifest_headers.values,
            .body = manifest,
        },
        .{
            .path_suffix = config_path,
            .class = .blob,
            .status = 401,
            .headers = &challenge_headers,
        },
        .{
            .path_suffix = config_path,
            .class = .blob,
            .headers = config_headers.values,
            .body = config_bytes,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        .{ .tag = "latest" },
        .none,
        .{},
    );
    defer source.deinit();
    var resolved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer resolved.deinit();
    var metadata = try source.readMetadata(
        allocator,
        config_value.value(),
        config_bytes.len,
    );
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 5), fake.index);
    try std.testing.expect(fake.authorization(0) == null);
    try std.testing.expect(fake.authorization(1) == null);
    try std.testing.expectEqualStrings(
        "Bearer scope-token",
        fake.authorization(2).?,
    );
    try std.testing.expect(fake.authorization(3) == null);
    try std.testing.expectEqualStrings(
        "Bearer scope-token",
        fake.authorization(4).?,
    );

    const duplicate_token_headers = [_]registry_http.Header{
        .{ .name = "Content-Length", .value = token_headers.length },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Content-Type", .value = "text/plain" },
    };
    const duplicate_token_steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .status = 401,
            .headers = &challenge_headers,
        },
        .{
            .path_suffix = "/token?service=registry.local&scope=repository%3Arepo%3Apull",
            .class = .token,
            .headers = &duplicate_token_headers,
            .body = token_body,
        },
    };
    var duplicate_token_runtime: FakeRuntime = .{};
    var duplicate_token_fake: ScriptedBackend = .{
        .runtime = &duplicate_token_runtime,
        .steps = &duplicate_token_steps,
    };
    var duplicate_token_source = try initSource(
        &duplicate_token_fake,
        &duplicate_token_runtime,
        .{ .tag = "latest" },
        .none,
        .{},
    );
    defer duplicate_token_source.deinit();
    try std.testing.expectError(
        error.AuthenticationFailed,
        duplicate_token_source.resolve(.{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = .{ .tag = "latest" },
        }),
    );
}

test "paginated tags deduplicate sort and reject loops and hostile origins" {
    const first = "{\"name\":\"repo\",\"tags\":[\"z\",\"a\",\"a\"]}";
    const second = "{\"name\":\"repo\",\"tags\":[\"b\"]}";
    const link_headers = [_]registry_http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Link", .value = "</v2/repo/tags/list?n=2&last=a>; rel=\"next\"" },
    };
    const json_headers = [_]registry_http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/tags/list",
            .class = .registry,
            .headers = &link_headers,
            .body = first,
        },
        .{
            .path_suffix = "/v2/repo/tags/list?n=2&last=a",
            .class = .registry,
            .headers = &json_headers,
            .body = second,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(&fake, &runtime, null, .none, .{});
    defer source.deinit();
    var tags = try source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    });
    defer tags.deinit();
    try std.testing.expectEqual(@as(usize, 3), tags.tags.len);
    try std.testing.expectEqualStrings("a", tags.tags[0]);
    try std.testing.expectEqualStrings("b", tags.tags[1]);
    try std.testing.expectEqualStrings("z", tags.tags[2]);

    const hostile_headers = [_]registry_http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Link", .value = "<https://evil.example/v2/repo/tags/list>; rel=next" },
    };
    const hostile_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .headers = &hostile_headers,
        .body = second,
    }};
    var hostile_runtime: FakeRuntime = .{};
    var hostile_fake: ScriptedBackend = .{
        .runtime = &hostile_runtime,
        .steps = &hostile_steps,
    };
    var hostile_source = try initSource(
        &hostile_fake,
        &hostile_runtime,
        null,
        .none,
        .{},
    );
    defer hostile_source.deinit();
    try std.testing.expectError(error.PaginationFailed, hostile_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));

    const loop_headers = [_]registry_http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Link", .value = "</v2/repo/tags/list>; rel=next" },
    };
    const loop_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .headers = &loop_headers,
        .body = second,
    }};
    var loop_runtime: FakeRuntime = .{};
    var loop_fake: ScriptedBackend = .{
        .runtime = &loop_runtime,
        .steps = &loop_steps,
    };
    var loop_source = try initSource(
        &loop_fake,
        &loop_runtime,
        null,
        .none,
        .{},
    );
    defer loop_source.deinit();
    try std.testing.expectError(error.PaginationFailed, loop_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));

    const limited_body = "{\"name\":\"repo\",\"tags\":[\"a\",\"b\"]}";
    const limited_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .headers = &json_headers,
        .body = limited_body,
    }};
    var limited_runtime: FakeRuntime = .{};
    var limited_fake: ScriptedBackend = .{
        .runtime = &limited_runtime,
        .steps = &limited_steps,
    };
    var limited_source = try initSource(
        &limited_fake,
        &limited_runtime,
        null,
        .none,
        .{ .max_tags = 1 },
    );
    defer limited_source.deinit();
    try std.testing.expectError(error.LimitExceeded, limited_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));

    const duplicate_json_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .headers = &json_headers,
        .body = "{\"name\":\"repo\",\"tags\":[],\"tags\":[\"hidden\"]}",
    }};
    var duplicate_json_runtime: FakeRuntime = .{};
    var duplicate_json_fake: ScriptedBackend = .{
        .runtime = &duplicate_json_runtime,
        .steps = &duplicate_json_steps,
    };
    var duplicate_json_source = try initSource(
        &duplicate_json_fake,
        &duplicate_json_runtime,
        null,
        .none,
        .{},
    );
    defer duplicate_json_source.deinit();
    try std.testing.expectError(
        error.InvalidContent,
        duplicate_json_source.listTags(.{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = null,
        }),
    );

    const ambiguous_link_headers = [_]registry_http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Link", .value = "</v2/repo/tags/list?n=2>; rel=next; rel=prev" },
    };
    const ambiguous_link_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .headers = &ambiguous_link_headers,
        .body = second,
    }};
    var ambiguous_link_runtime: FakeRuntime = .{};
    var ambiguous_link_fake: ScriptedBackend = .{
        .runtime = &ambiguous_link_runtime,
        .steps = &ambiguous_link_steps,
    };
    var ambiguous_link_source = try initSource(
        &ambiguous_link_fake,
        &ambiguous_link_runtime,
        null,
        .none,
        .{},
    );
    defer ambiguous_link_source.deinit();
    try std.testing.expectError(
        error.PaginationFailed,
        ambiguous_link_source.listTags(.{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = null,
        }),
    );
    try std.testing.expectEqual(
        registry.Category.pagination,
        ambiguous_link_source.lastDiagnostic().?.category,
    );

    var page_limit_runtime: FakeRuntime = .{};
    const page_limit_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .headers = &link_headers,
        .body = first,
    }};
    var page_limit_fake: ScriptedBackend = .{
        .runtime = &page_limit_runtime,
        .steps = &page_limit_steps,
    };
    var page_limit_source = try initSource(
        &page_limit_fake,
        &page_limit_runtime,
        null,
        .none,
        .{ .max_tag_pages = 1 },
    );
    defer page_limit_source.deinit();
    try std.testing.expectError(
        error.LimitExceeded,
        page_limit_source.listTags(.{
            .authority = "localhost:5000",
            .repository = "repo",
            .selection = null,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), page_limit_fake.index);
}

test "stream retries rewind destination and final failures remove partial output" {
    const allocator = std.testing.allocator;
    const bytes = "streamed-payload";
    const value = descriptor(bytes, "application/octet-stream");
    const headers = try headersFor(
        allocator,
        "application/octet-stream",
        bytes,
        &value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, headers);
    const path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&value.digest_text},
    );
    defer allocator.free(path);
    const steps = [_]Step{
        .{
            .path_suffix = path,
            .class = .blob,
            .headers = headers.values,
            .body = bytes,
            .stream_failure_after = 5,
        },
        .{
            .path_suffix = path,
            .class = .blob,
            .headers = headers.values,
            .body = bytes,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(&fake, &runtime, null, .none, .{});
    defer source.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "retry", .{ .read = true });
    defer output.close(std.testing.io);
    try output.writeStreamingAll(std.testing.io, "stale bytes");
    try source.copyVerifiedTo(value.value(), output);
    try std.testing.expectEqual(@as(u64, bytes.len), try output.length(std.testing.io));
    const copied = try allocator.alloc(u8, bytes.len);
    defer allocator.free(copied);
    try std.testing.expectEqual(
        bytes.len,
        try output.readPositionalAll(std.testing.io, copied, 0),
    );
    try std.testing.expectEqualSlices(u8, bytes, copied);

    const corrupt = "streamed-payloae";
    var corrupt_runtime: FakeRuntime = .{};
    const corrupt_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .headers = headers.values,
        .body = corrupt,
    }};
    var corrupt_fake: ScriptedBackend = .{
        .runtime = &corrupt_runtime,
        .steps = &corrupt_steps,
    };
    var corrupt_source = try initSource(
        &corrupt_fake,
        &corrupt_runtime,
        null,
        .none,
        .{},
    );
    defer corrupt_source.deinit();
    try std.testing.expectError(
        error.InvalidContent,
        corrupt_source.copyVerifiedTo(value.value(), output),
    );
    try std.testing.expectEqual(@as(u64, 0), try output.length(std.testing.io));

    const opaque_document_bytes = "opaque-document-media";
    const opaque_document = descriptor(
        opaque_document_bytes,
        model.media_type_oci_manifest,
    );
    const opaque_document_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&opaque_document.digest_text},
    );
    defer allocator.free(opaque_document_path);
    const no_length_headers = [_]registry_http.Header{
        .{
            .name = "Docker-Content-Digest",
            .value = &opaque_document.digest_text,
        },
    };
    const no_length_steps = [_]Step{.{
        .path_suffix = opaque_document_path,
        .class = .blob,
        .headers = &no_length_headers,
        .body = opaque_document_bytes,
    }};
    var no_length_runtime: FakeRuntime = .{};
    var no_length_fake: ScriptedBackend = .{
        .runtime = &no_length_runtime,
        .steps = &no_length_steps,
    };
    var no_length_source = try initSource(
        &no_length_fake,
        &no_length_runtime,
        null,
        .none,
        .{},
    );
    defer no_length_source.deinit();
    try no_length_source.copyVerifiedTo(opaque_document.value(), output);
    try std.testing.expectEqual(
        @as(u64, opaque_document_bytes.len),
        try output.length(std.testing.io),
    );

    const duplicate_digest_headers = [_]registry_http.Header{
        .{
            .name = "Docker-Content-Digest",
            .value = &opaque_document.digest_text,
        },
        .{
            .name = "Docker-Content-Digest",
            .value = &opaque_document.digest_text,
        },
    };
    const duplicate_digest_steps = [_]Step{.{
        .path_suffix = opaque_document_path,
        .class = .blob,
        .headers = &duplicate_digest_headers,
        .body = opaque_document_bytes,
    }};
    var duplicate_digest_runtime: FakeRuntime = .{};
    var duplicate_digest_fake: ScriptedBackend = .{
        .runtime = &duplicate_digest_runtime,
        .steps = &duplicate_digest_steps,
    };
    var duplicate_digest_source = try initSource(
        &duplicate_digest_fake,
        &duplicate_digest_runtime,
        null,
        .none,
        .{},
    );
    defer duplicate_digest_source.deinit();
    try std.testing.expectError(
        error.InvalidContent,
        duplicate_digest_source.copyVerifiedTo(
            opaque_document.value(),
            output,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), try output.length(std.testing.io));

    const retry_limit_steps = [_]Step{
        .{
            .path_suffix = path,
            .class = .blob,
            .headers = headers.values,
            .body = bytes,
            .stream_failure_after = 5,
        },
        .{
            .path_suffix = path,
            .class = .blob,
            .headers = headers.values,
            .body = bytes,
            .stream_failure_after = 5,
        },
        .{
            .path_suffix = path,
            .class = .blob,
            .headers = headers.values,
            .body = bytes,
            .stream_failure_after = 5,
        },
    };
    var retry_limit_runtime: FakeRuntime = .{};
    var retry_limit_fake: ScriptedBackend = .{
        .runtime = &retry_limit_runtime,
        .steps = &retry_limit_steps,
    };
    var retry_limit_source = try initSource(
        &retry_limit_fake,
        &retry_limit_runtime,
        null,
        .none,
        .{},
    );
    defer retry_limit_source.deinit();
    try output.writePositionalAll(std.testing.io, "stale", 0);
    try std.testing.expectError(
        error.RetryLimitExceeded,
        retry_limit_source.copyVerifiedTo(value.value(), output),
    );
    try std.testing.expectEqual(@as(usize, 3), retry_limit_fake.index);
    try std.testing.expectEqual(
        registry.Category.retry_limit,
        retry_limit_source.lastDiagnostic().?.category,
    );
    try std.testing.expectEqual(@as(u64, 0), try output.length(std.testing.io));

    const deadline_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .headers = headers.values,
        .body = bytes,
        .stream_failure_after = 5,
        .advance_ns = 61 * std.time.ns_per_s,
    }};
    var deadline_runtime: FakeRuntime = .{};
    var deadline_fake: ScriptedBackend = .{
        .runtime = &deadline_runtime,
        .steps = &deadline_steps,
    };
    var deadline_source = try initSource(
        &deadline_fake,
        &deadline_runtime,
        null,
        .none,
        .{},
    );
    defer deadline_source.deinit();
    try output.writePositionalAll(std.testing.io, "stale", 0);
    try std.testing.expectError(
        error.DeadlineExceeded,
        deadline_source.copyVerifiedTo(value.value(), output),
    );
    try std.testing.expectEqual(
        registry.Category.deadline,
        deadline_source.lastDiagnostic().?.category,
    );
    try std.testing.expectEqual(@as(u64, 0), try output.length(std.testing.io));

    const missing_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .status = 404,
        .body = "{\"errors\":[{\"code\":\"BLOB_UNKNOWN\"}]}",
    }};
    var missing_runtime: FakeRuntime = .{};
    var missing_fake: ScriptedBackend = .{
        .runtime = &missing_runtime,
        .steps = &missing_steps,
    };
    var missing_source = try initSource(
        &missing_fake,
        &missing_runtime,
        null,
        .none,
        .{},
    );
    defer missing_source.deinit();
    try output.writePositionalAll(std.testing.io, "stale", 0);
    try std.testing.expectError(
        error.ContentNotFound,
        missing_source.copyVerifiedTo(value.value(), output),
    );
    try std.testing.expectEqual(
        registry.Category.not_found,
        missing_source.lastDiagnostic().?.category,
    );
    try std.testing.expectEqual(@as(u64, 0), try output.length(std.testing.io));

    const transport_steps = [_]Step{.{
        .path_suffix = path,
        .class = .blob,
        .failure = error.DnsFailure,
    }};
    var transport_runtime: FakeRuntime = .{};
    var transport_fake: ScriptedBackend = .{
        .runtime = &transport_runtime,
        .steps = &transport_steps,
    };
    var transport_source = try initSource(
        &transport_fake,
        &transport_runtime,
        null,
        .none,
        .{},
    );
    defer transport_source.deinit();
    try output.writePositionalAll(std.testing.io, "stale", 0);
    try std.testing.expectError(
        error.TransportFailed,
        transport_source.copyVerifiedTo(value.value(), output),
    );
    try std.testing.expectEqual(
        registry.Category.transport,
        transport_source.lastDiagnostic().?.category,
    );
    try std.testing.expectEqual(@as(u64, 0), try output.length(std.testing.io));
}

test "unknown index children use manifest endpoints and status diagnostics are sanitized" {
    const allocator = std.testing.allocator;
    const config_value = descriptor("{}", model.media_type_oci_empty_config);
    const child_manifest = try makeManifest(
        allocator,
        config_value.value(),
        &.{},
        false,
    );
    defer allocator.free(child_manifest);
    const child_value = descriptor(
        child_manifest,
        "application/vnd.example.manifest+json",
    );
    const index = try makeIndex(allocator, child_value.value());
    defer allocator.free(index);
    const root_value = descriptor(index, model.media_type_oci_index);
    const root_headers = try headersFor(
        allocator,
        model.media_type_oci_index,
        index,
        &root_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, root_headers);
    const child_headers = try headersFor(
        allocator,
        child_value.value().mediaType,
        child_manifest,
        &child_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, child_headers);
    const child_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/manifests/{s}",
        .{&child_value.digest_text},
    );
    defer allocator.free(child_path);
    const steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = root_headers.values,
            .body = index,
        },
        .{
            .path_suffix = child_path,
            .class = .registry,
            .headers = child_headers.values,
            .body = child_manifest,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        .{ .tag = "latest" },
        .none,
        .{},
    );
    defer source.deinit();
    var resolved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer resolved.deinit();
    var inspected = try source.inspectResolved(&resolved, .{});
    defer inspected.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.index);
    try std.testing.expect(std.mem.endsWith(u8, fake.url(1), child_path));

    const malformed_child_bytes = "{}";
    const malformed_child = descriptor(
        malformed_child_bytes,
        model.media_type_oci_manifest,
    );
    const malformed_index = try makeIndex(
        allocator,
        malformed_child.value(),
    );
    defer allocator.free(malformed_index);
    const malformed_root = descriptor(
        malformed_index,
        model.media_type_oci_index,
    );
    const malformed_root_headers = try headersFor(
        allocator,
        model.media_type_oci_index,
        malformed_index,
        &malformed_root.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, malformed_root_headers);
    const malformed_child_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        malformed_child_bytes,
        &malformed_child.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, malformed_child_headers);
    const malformed_child_path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/manifests/{s}",
        .{&malformed_child.digest_text},
    );
    defer allocator.free(malformed_child_path);
    const malformed_steps = [_]Step{
        .{
            .path_suffix = "/v2/repo/manifests/latest",
            .class = .registry,
            .headers = malformed_root_headers.values,
            .body = malformed_index,
        },
        .{
            .path_suffix = malformed_child_path,
            .class = .registry,
            .headers = malformed_child_headers.values,
            .body = malformed_child_bytes,
        },
    };
    var malformed_runtime: FakeRuntime = .{};
    var malformed_fake: ScriptedBackend = .{
        .runtime = &malformed_runtime,
        .steps = &malformed_steps,
    };
    var malformed_source = try initSource(
        &malformed_fake,
        &malformed_runtime,
        .{ .tag = "latest" },
        .none,
        .{},
    );
    defer malformed_source.deinit();
    var malformed_resolved = try malformed_source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer malformed_resolved.deinit();
    try std.testing.expectError(
        error.InvalidContent,
        malformed_source.inspectResolved(&malformed_resolved, .{}),
    );
    try std.testing.expectEqual(
        registry.Category.invalid_content,
        malformed_source.lastDiagnostic().?.category,
    );

    const denied_body =
        "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"no\",\"detail\":\"secret-token signed=abc\"}]}";
    const denied_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .status = 403,
        .body = denied_body,
    }};
    var denied_runtime: FakeRuntime = .{};
    var denied_fake: ScriptedBackend = .{
        .runtime = &denied_runtime,
        .steps = &denied_steps,
    };
    var denied_source = try initSource(
        &denied_fake,
        &denied_runtime,
        null,
        .none,
        .{},
    );
    defer denied_source.deinit();
    try std.testing.expectError(error.AuthorizationDenied, denied_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));
    const diagnostic = denied_source.lastDiagnostic().?;
    try std.testing.expectEqual(registry.Category.authorization, diagnostic.category);
    try std.testing.expectEqualStrings("DENIED", diagnostic.distributionCode().?);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{diagnostic.*});
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "secret-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "signed=abc") == null);
}

test "Basic credentials are isolated and registry status categories remain distinct" {
    const allocator = std.testing.allocator;
    const config_value = descriptor("{}", model.media_type_oci_empty_config);
    const manifest = try makeManifest(allocator, config_value.value(), &.{}, true);
    defer allocator.free(manifest);
    const root_value = descriptor(manifest, model.media_type_oci_manifest);
    const manifest_headers = try headersFor(
        allocator,
        model.media_type_oci_manifest,
        manifest,
        &root_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, manifest_headers);
    const steps = [_]Step{.{
        .path_suffix = "/v2/repo/manifests/latest",
        .class = .registry,
        .headers = manifest_headers.values,
        .body = manifest,
    }};
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        .{ .tag = "latest" },
        .{ .supplied = .{ .basic = .{
            .username = "reader",
            .secret = "source-secret",
        } } },
        .{},
    );
    defer source.deinit();
    var resolved = try source.resolve(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = .{ .tag = "latest" },
    });
    defer resolved.deinit();
    try std.testing.expectEqualStrings(
        "Basic cmVhZGVyOnNvdXJjZS1zZWNyZXQ=",
        fake.authorization(0).?,
    );

    const missing_body =
        "{\"errors\":[{\"code\":\"NAME_UNKNOWN\",\"message\":\"missing\"}]}";
    const missing_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .status = 404,
        .body = missing_body,
    }};
    var missing_runtime: FakeRuntime = .{};
    var missing_fake: ScriptedBackend = .{
        .runtime = &missing_runtime,
        .steps = &missing_steps,
    };
    var missing_source = try initSource(
        &missing_fake,
        &missing_runtime,
        null,
        .none,
        .{},
    );
    defer missing_source.deinit();
    try std.testing.expectError(error.ContentNotFound, missing_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));

    const auth_headers = [_]registry_http.Header{
        .{ .name = "WWW-Authenticate", .value = "Basic realm=\"registry\"" },
    };
    const auth_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .status = 401,
        .headers = &auth_headers,
    }};
    var auth_runtime: FakeRuntime = .{};
    var auth_fake: ScriptedBackend = .{
        .runtime = &auth_runtime,
        .steps = &auth_steps,
    };
    var auth_source = try initSource(
        &auth_fake,
        &auth_runtime,
        null,
        .none,
        .{},
    );
    defer auth_source.deinit();
    try std.testing.expectError(error.AuthenticationFailed, auth_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));
}

test "blob redirects strip authorization and deadlines and limits do not accept partial success" {
    const allocator = std.testing.allocator;
    const bytes = "redirected-blob";
    const value = descriptor(bytes, "application/octet-stream");
    const blob_headers = try headersFor(
        allocator,
        "application/octet-stream",
        bytes,
        &value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, blob_headers);
    const path = try std.fmt.allocPrint(
        allocator,
        "/v2/repo/blobs/{s}",
        .{&value.digest_text},
    );
    defer allocator.free(path);
    const redirect_headers = [_]registry_http.Header{
        .{ .name = "Location", .value = "https://cdn.example/download?sig=secret" },
    };
    const steps = [_]Step{
        .{
            .path_suffix = path,
            .class = .blob,
            .status = 307,
            .headers = &redirect_headers,
        },
        .{
            .path_suffix = "/download?sig=secret",
            .class = .blob,
            .headers = blob_headers.values,
            .body = bytes,
        },
    };
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var source = try initSource(
        &fake,
        &runtime,
        null,
        .{ .supplied = .{ .basic = .{
            .username = "reader",
            .secret = "redirect-secret",
        } } },
        .{},
    );
    defer source.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var output = try tmp.dir.createFile(std.testing.io, "redirect", .{ .read = true });
    defer output.close(std.testing.io);
    try source.copyVerifiedTo(value.value(), output);
    try std.testing.expect(fake.authorization(0) != null);
    try std.testing.expect(fake.authorization(1) == null);

    const deadline_steps = [_]Step{.{
        .path_suffix = "/v2/repo/tags/list",
        .class = .registry,
        .status = 200,
        .body = "{\"name\":\"repo\",\"tags\":null}",
        .advance_ns = 61 * std.time.ns_per_s,
    }};
    var deadline_runtime: FakeRuntime = .{};
    var deadline_fake: ScriptedBackend = .{
        .runtime = &deadline_runtime,
        .steps = &deadline_steps,
    };
    var deadline_source = try initSource(
        &deadline_fake,
        &deadline_runtime,
        null,
        .none,
        .{},
    );
    defer deadline_source.deinit();
    try std.testing.expectError(error.DeadlineExceeded, deadline_source.listTags(.{
        .authority = "localhost:5000",
        .repository = "repo",
        .selection = null,
    }));

    var limited_runtime: FakeRuntime = .{};
    const no_steps = [_]Step{};
    var limited_fake: ScriptedBackend = .{
        .runtime = &limited_runtime,
        .steps = &no_steps,
    };
    var limited_source = try initSource(
        &limited_fake,
        &limited_runtime,
        null,
        .none,
        .{ .max_metadata_bytes = 8 },
    );
    defer limited_source.deinit();
    var oversized = value.value();
    oversized.size = 9;
    try std.testing.expectError(
        error.LimitExceeded,
        limited_source.readMetadata(allocator, oversized, 9),
    );
    try std.testing.expectEqual(@as(usize, 0), limited_fake.index);
}

test "destination requires a tag and preflights before descriptor transfer" {
    const no_steps = [_]Step{};
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &no_steps };
    var files: FileProbe = .{};
    try std.testing.expectError(
        error.TagRequired,
        registry.Destination.initWithBackend(
            std.testing.io,
            std.testing.allocator,
            .{
                .authority = "localhost:5000",
                .repository = "dest",
                .selection = null,
            },
            fake.backend(),
            runtime.clock(),
            runtime.sleeper(),
            .{
                .plain_http = true,
                .credential_policy = .{ .auth_file = "must-not-read.json" },
                .auth_context = .{
                    .io = std.testing.io,
                    .files = files.reader(),
                },
                .deadline = .after(runtime.clock(), 60 * std.time.ns_per_s),
            },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), files.calls);
    try std.testing.expectEqual(@as(usize, 0), fake.index);

    const root_value = descriptor("{}", model.media_type_oci_manifest);
    try std.testing.expectError(
        error.TagRequired,
        initDestination(&fake, &runtime, .{
            .selection = .{ .digest = root_value.digest },
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.index);

    const preflight_steps = [_]Step{.{
        .path_suffix = "/v2/",
        .class = .registry,
    }};
    var preflight_runtime: FakeRuntime = .{};
    var preflight_fake: ScriptedBackend = .{
        .runtime = &preflight_runtime,
        .steps = &preflight_steps,
    };
    var destination = try initDestination(
        &preflight_fake,
        &preflight_runtime,
        .{},
    );
    defer destination.deinit();
    var source_impl: NoReadSource = .{};
    try std.testing.expectError(
        error.DestinationNotPrepared,
        destination.ensureDescriptor(blobTransfer(
            transport.Source.init(&source_impl),
            descriptor("blob", "application/octet-stream").value(),
        )),
    );
    try std.testing.expectEqual(@as(usize, 0), preflight_fake.index);

    try destination.prepareRoot(
        root_value.value(),
        .{ .tag = "latest" },
    );
    try std.testing.expectEqual(
        registry.DestinationState.prepared,
        destination.state(),
    );
    try std.testing.expectEqual(@as(usize, 1), preflight_fake.index);
    try std.testing.expectError(
        error.DestinationStateConflict,
        destination.prepareRoot(
            root_value.value(),
            .{ .tag = "latest" },
        ),
    );

    const child_bytes = "{\"schemaVersion\":2}";
    const child_value = descriptor(
        child_bytes,
        model.media_type_oci_manifest,
    );
    try std.testing.expectError(
        error.ManifestPublicationNotImplemented,
        destination.ensureDescriptor(.{
            .descriptor = child_value.value(),
            .roles = transport.DescriptorRoles.init(.index_child),
            .data = .{ .exact_metadata = child_bytes },
        }),
    );
    try std.testing.expectEqual(
        registry.DestinationState.failed,
        destination.state(),
    );
    try std.testing.expect(!destination.committed());
    try std.testing.expectEqual(@as(usize, 1), preflight_fake.index);

    var limited_runtime: FakeRuntime = .{};
    var limited_fake: ScriptedBackend = .{
        .runtime = &limited_runtime,
        .steps = &no_steps,
    };
    var limited = try initDestination(&limited_fake, &limited_runtime, .{
        .graph_limits = .{
            .max_depth = 1,
            .max_nodes = 1,
            .max_total_bytes = 1,
            .max_metadata_bytes = 1,
        },
    });
    defer limited.deinit();
    try std.testing.expectError(
        error.LimitExceeded,
        limited.prepareRoot(root_value.value(), .{ .tag = "latest" }),
    );
    try std.testing.expectEqual(@as(usize, 0), limited_fake.index);
}

test "destination blob reuse verifies HEAD and bounded GET" {
    const allocator = std.testing.allocator;
    const root_value = descriptor("{}", model.media_type_oci_manifest);
    const bytes = "destination-blob";
    const blob_value = descriptor(bytes, "application/octet-stream");
    const blob_path = try std.fmt.allocPrint(
        allocator,
        "/v2/dest/blobs/{s}",
        .{&blob_value.digest_text},
    );
    defer allocator.free(blob_path);
    const verified_headers = try headersFor(
        allocator,
        "application/octet-stream",
        bytes,
        &blob_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, verified_headers);

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
            },
            .{
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
                .body = bytes,
            },
        };
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        var source_impl: NoReadSource = .{};
        try std.testing.expectEqual(
            transport.DescriptorResult.reused,
            try destination.ensureDescriptor(blobTransfer(
                transport.Source.init(&source_impl),
                blob_value.value(),
            )),
        );
        try std.testing.expectEqual(@as(usize, 0), source_impl.reads);
        try std.testing.expectEqual(@as(usize, 3), fake.index);
    }

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 405,
            },
            .{
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
                .body = bytes,
            },
        };
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        var source_impl: NoReadSource = .{};
        try std.testing.expectEqual(
            transport.DescriptorResult.reused,
            try destination.ensureDescriptor(blobTransfer(
                transport.Source.init(&source_impl),
                blob_value.value(),
            )),
        );
    }

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
        };
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        var source_impl: NoReadSource = .{};
        try std.testing.expectError(
            error.UploadRequired,
            destination.ensureDescriptor(blobTransfer(
                transport.Source.init(&source_impl),
                blob_value.value(),
            )),
        );
        const handoff = destination.pendingUpload().?;
        try std.testing.expectEqual(
            registry.UploadReason.blob_missing,
            handoff.reason,
        );
        try std.testing.expect(!handoff.replay.non_idempotent_replay_allowed);
        try std.testing.expect(handoff.replay.probe_before_retry);
        try std.testing.expect(!destination.committed());
        try std.testing.expectEqual(@as(usize, 2), fake.index);
    }

    {
        const bad_head_headers = [_]registry_http.Header{
            .{ .name = "Content-Length", .value = "999" },
            .{
                .name = "Docker-Content-Digest",
                .value = &blob_value.digest_text,
            },
        };
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .headers = &bad_head_headers,
            },
        };
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        var source_impl: NoReadSource = .{};
        try std.testing.expectError(
            error.InvalidContent,
            destination.ensureDescriptor(blobTransfer(
                transport.Source.init(&source_impl),
                blob_value.value(),
            )),
        );
        try std.testing.expect(destination.pendingUpload() == null);
        try std.testing.expectEqual(@as(usize, 2), fake.index);
    }

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
            },
            .{
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
                .body = "xxxxxxxxxxxxxxxx",
            },
        };
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        var source_impl: NoReadSource = .{};
        try std.testing.expectError(
            error.InvalidContent,
            destination.ensureDescriptor(blobTransfer(
                transport.Source.init(&source_impl),
                blob_value.value(),
            )),
        );
        try std.testing.expect(destination.pendingUpload() == null);
        try std.testing.expect(!destination.committed());
    }
}

test "same-origin mount uses destination credentials and returns safe handoff" {
    const allocator = std.testing.allocator;
    const root_value = descriptor("{}", model.media_type_oci_manifest);
    const bytes = "mountable-blob";
    const blob_value = descriptor(bytes, "application/octet-stream");
    const blob_path = try std.fmt.allocPrint(
        allocator,
        "/v2/dest/team/blobs/{s}",
        .{&blob_value.digest_text},
    );
    defer allocator.free(blob_path);
    const mount_path = try std.fmt.allocPrint(
        allocator,
        "/v2/dest/team/blobs/uploads/?mount=sha256%3A{s}&from=source%2Fteam",
        .{blob_value.digest_text["sha256:".len..]},
    );
    defer allocator.free(mount_path);
    const verified_headers = try headersFor(
        allocator,
        "application/octet-stream",
        bytes,
        &blob_value.digest_text,
        &.{},
    );
    defer freeHeaders(allocator, verified_headers);
    const mounted_headers = [_]registry_http.Header{
        .{
            .name = "Docker-Content-Digest",
            .value = &blob_value.digest_text,
        },
        .{ .name = "Location", .value = "/v2/dest/team/blobs/mounted" },
    };

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .status = 201,
                .headers = &mounted_headers,
            },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
            },
            .{
                .path_suffix = blob_path,
                .class = .blob,
                .headers = verified_headers.values,
                .body = bytes,
            },
        };
        const source_steps = [_]Step{};
        var source_runtime: FakeRuntime = .{};
        var source_fake: ScriptedBackend = .{
            .runtime = &source_runtime,
            .steps = &source_steps,
        };
        var source = try initRegistrySourceAt(
            &source_fake,
            &source_runtime,
            "localhost:5000",
            "source/team",
            .{ .supplied = .{ .basic = .{
                .username = "reader",
                .secret = "source-secret",
            } } },
        );
        defer source.deinit();

        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .repository = "dest/team",
            .credential_policy = .{ .supplied = .{ .basic = .{
                .username = "writer",
                .secret = "dest-secret",
            } } },
        });
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectEqual(
            transport.DescriptorResult.mounted,
            try destination.ensureDescriptor(blobTransfer(
                source.asTransport(),
                blob_value.value(),
            )),
        );
        try std.testing.expectEqual(@as(usize, 0), source_fake.index);
        try std.testing.expectEqualStrings(
            "Basic d3JpdGVyOmRlc3Qtc2VjcmV0",
            fake.authorization(2).?,
        );
        try std.testing.expect(!std.mem.eql(
            u8,
            fake.authorization(2).?,
            "Basic cmVhZGVyOnNvdXJjZS1zZWNyZXQ=",
        ));
        try std.testing.expect(destination.pendingUpload() == null);
    }

    {
        const declined_headers = [_]registry_http.Header{
            .{
                .name = "Location",
                .value = "https://uploads.example/session?ticket=signed-secret",
            },
        };
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .status = 202,
                .headers = &declined_headers,
            },
        };
        var source_impl: NoReadSource = .{};
        const identity: transport.RegistryIdentity = .{
            .origin = "http://localhost:5000",
            .authority = "localhost:5000",
            .repository = "source/team",
            .plain_http = true,
        };
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            identity,
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .repository = "dest/team",
        });
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.UploadRequired,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        const handoff = destination.pendingUpload().?;
        try std.testing.expectEqual(
            registry.UploadReason.mount_declined,
            handoff.reason,
        );
        try std.testing.expect(handoff.session.?.authorization_stripped);
        try std.testing.expectEqualStrings(
            "https://uploads.example/session?ticket=signed-secret",
            handoff.session.?.url,
        );
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try output.writer.print("{f}", .{handoff.*});
        try std.testing.expect(
            std.mem.indexOf(u8, output.written(), "signed-secret") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, output.written(), "/session") == null,
        );
        try std.testing.expectEqual(@as(usize, 0), source_impl.reads);
        try std.testing.expect(!destination.committed());
    }

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
        };
        var source_impl: NoReadSource = .{};
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            .{
                .origin = "https://other.example:443",
                .authority = "other.example",
                .repository = "source/team",
                .plain_http = false,
            },
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .repository = "dest/team",
        });
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.UploadRequired,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        try std.testing.expectEqual(
            registry.UploadReason.mount_not_permitted,
            destination.pendingUpload().?.reason,
        );
        try std.testing.expectEqual(@as(usize, 2), fake.index);
    }
}

test "mount failures redirects deadlines and limits never report success" {
    const allocator = std.testing.allocator;
    const root_value = descriptor("{}", model.media_type_oci_manifest);
    const bytes = "mountable-blob";
    const blob_value = descriptor(bytes, "application/octet-stream");
    const blob_path = try std.fmt.allocPrint(
        allocator,
        "/v2/dest/blobs/{s}",
        .{&blob_value.digest_text},
    );
    defer allocator.free(blob_path);
    const mount_path = try std.fmt.allocPrint(
        allocator,
        "/v2/dest/blobs/uploads/?mount=sha256%3A{s}&from=source",
        .{blob_value.digest_text["sha256:".len..]},
    );
    defer allocator.free(mount_path);
    const identity: transport.RegistryIdentity = .{
        .origin = "http://localhost:5000",
        .authority = "localhost:5000",
        .repository = "source",
        .plain_http = true,
    };

    {
        const auth_headers = [_]registry_http.Header{
            .{ .name = "WWW-Authenticate", .value = "Basic realm=\"push\"" },
        };
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .status = 401,
                .headers = &auth_headers,
            },
        };
        var source_impl: NoReadSource = .{};
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            identity,
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .credential_policy = .{ .supplied = .{ .basic = .{
                .username = "writer",
                .secret = "private-destination-secret",
            } } },
        });
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.AuthenticationFailed,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        try std.testing.expectEqual(@as(usize, 3), fake.index);
        try std.testing.expect(destination.pendingUpload() == null);
        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();
        try output.writer.print("{f}", .{destination.lastDiagnostic().?.*});
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                output.written(),
                "private-destination-secret",
            ) == null,
        );
    }

    {
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .failure = error.ConnectionReset,
            },
        };
        var source_impl: NoReadSource = .{};
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            identity,
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.TransportFailed,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        try std.testing.expectEqual(@as(usize, 3), fake.index);
        try std.testing.expect(destination.pendingUpload() == null);
        try std.testing.expect(!destination.committed());
    }

    {
        const malformed_headers = [_]registry_http.Header{
            .{
                .name = "Location",
                .value = "http://upload.example/session?secret=value",
            },
        };
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .status = 202,
                .headers = &malformed_headers,
            },
        };
        var source_impl: NoReadSource = .{};
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            identity,
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.RedirectRejected,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        try std.testing.expect(destination.pendingUpload() == null);
        try std.testing.expect(!destination.committed());
    }

    {
        const created_headers = [_]registry_http.Header{
            .{
                .name = "Docker-Content-Digest",
                .value = &blob_value.digest_text,
            },
        };
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .status = 201,
                .headers = &created_headers,
            },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
        };
        var source_impl: NoReadSource = .{};
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            identity,
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{});
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.InvalidContent,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        try std.testing.expect(destination.pendingUpload() == null);
        try std.testing.expect(!destination.committed());
    }

    {
        const redirect_headers = [_]registry_http.Header{
            .{
                .name = "Location",
                .value = "http://registry.example/download",
            },
        };
        const https_blob_path = try std.fmt.allocPrint(
            allocator,
            "/v2/dest/blobs/{s}",
            .{&blob_value.digest_text},
        );
        defer allocator.free(https_blob_path);
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = https_blob_path,
                .class = .blob,
                .status = 405,
            },
            .{
                .path_suffix = https_blob_path,
                .class = .blob,
                .status = 307,
                .headers = &redirect_headers,
            },
        };
        var source_impl: NoReadSource = .{};
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .authority = "registry.example",
        });
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.RedirectRejected,
            destination.ensureDescriptor(blobTransfer(
                transport.Source.init(&source_impl),
                blob_value.value(),
            )),
        );
        try std.testing.expect(!destination.committed());
    }

    {
        const steps = [_]Step{.{
            .path_suffix = "/v2/",
            .class = .registry,
            .advance_ns = 2 * std.time.ns_per_s,
        }};
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .deadline_ns = std.time.ns_per_s,
        });
        defer destination.deinit();
        try std.testing.expectError(
            error.DeadlineExceeded,
            destination.prepareRoot(root_value.value(), .{ .tag = "latest" }),
        );
        try std.testing.expect(!destination.committed());
    }

    {
        const long_location_headers = [_]registry_http.Header{
            .{
                .name = "Location",
                .value = "/v2/dest/blobs/uploads/session-that-is-too-long",
            },
        };
        const steps = [_]Step{
            .{ .path_suffix = "/v2/", .class = .registry },
            .{
                .method = .HEAD,
                .path_suffix = blob_path,
                .class = .blob,
                .status = 404,
            },
            .{
                .method = .POST,
                .path_suffix = mount_path,
                .class = .registry,
                .status = 202,
                .headers = &long_location_headers,
            },
        };
        var source_impl: NoReadSource = .{};
        const source = transport.Source.initWithRegistryIdentity(
            &source_impl,
            identity,
        );
        var runtime: FakeRuntime = .{};
        var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
        var destination = try initDestination(&fake, &runtime, .{
            .http_limits = .{ .max_location_bytes = 16 },
        });
        defer destination.deinit();
        try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
        try std.testing.expectError(
            error.RedirectRejected,
            destination.ensureDescriptor(blobTransfer(
                source,
                blob_value.value(),
            )),
        );
        try std.testing.expect(destination.pendingUpload() == null);
    }
}

test "registry destination cannot stage commit finish or report success" {
    const root_bytes = "{}";
    const root_value = descriptor(root_bytes, model.media_type_oci_manifest);
    const steps = [_]Step{.{
        .path_suffix = "/v2/",
        .class = .registry,
    }};
    var runtime: FakeRuntime = .{};
    var fake: ScriptedBackend = .{ .runtime = &runtime, .steps = &steps };
    var destination = try initDestination(&fake, &runtime, .{});
    defer destination.deinit();
    try destination.prepareRoot(root_value.value(), .{ .tag = "latest" });
    const publication: transport.RootPublication = .{
        .descriptor = root_value.value(),
        .descriptor_json = null,
        .exact_bytes = root_bytes,
    };
    try std.testing.expectError(
        error.RootPublicationNotImplemented,
        destination.stageRoot(publication),
    );
    try std.testing.expect(!destination.committed());
    try std.testing.expectError(
        error.DestinationNotCommitted,
        destination.finish(),
    );
    try std.testing.expect(!destination.committed());
    try std.testing.expectEqual(@as(usize, 1), fake.index);

    var commit_runtime: FakeRuntime = .{};
    var commit_fake: ScriptedBackend = .{
        .runtime = &commit_runtime,
        .steps = &steps,
    };
    var commit_destination = try initDestination(
        &commit_fake,
        &commit_runtime,
        .{},
    );
    defer commit_destination.deinit();
    try commit_destination.prepareRoot(
        root_value.value(),
        .{ .tag = "latest" },
    );
    try std.testing.expectError(
        error.RootPublicationNotImplemented,
        commit_destination.commitRoot(
            publication,
            .{ .tag = "latest" },
        ),
    );
    try std.testing.expect(!commit_destination.committed());
    try std.testing.expectEqual(@as(usize, 1), commit_fake.index);
}
