const std = @import("std");
const wabt = @import("wabt");
const copy_cmd = @import("oci_copy.zig");
const output = @import("oci_output.zig");
const push_cmd = @import("oci_push.zig");
const runtime_mod = @import("oci_runtime.zig");

const http = wabt.oci.registry_http;

const Capture = struct {
    stdout_buffer: [64 * 1024]u8 = undefined,
    stderr_buffer: [16 * 1024]u8 = undefined,
    progress_buffer: [16 * 1024]u8 = undefined,
    stdout_writer: std.Io.Writer = undefined,
    stderr_writer: std.Io.Writer = undefined,
    progress_writer: std.Io.Writer = undefined,

    fn reset(self: *Capture) void {
        self.stdout_writer = std.Io.Writer.fixed(&self.stdout_buffer);
        self.stderr_writer = std.Io.Writer.fixed(&self.stderr_buffer);
        self.progress_writer = std.Io.Writer.fixed(&self.progress_buffer);
    }

    fn attach(self: *Capture, runtime: *runtime_mod.Runtime) void {
        runtime.stdout = runtime_mod.OutputSink.fromWriter(&self.stdout_writer);
        runtime.stderr = runtime_mod.OutputSink.fromWriter(&self.stderr_writer);
    }

    fn attachProgress(self: *Capture, runtime: *runtime_mod.Runtime) void {
        runtime.progress = runtime_mod.OutputSink.fromWriter(&self.progress_writer);
    }

    fn stdout(self: *const Capture) []const u8 {
        return self.stdout_buffer[0..self.stdout_writer.end];
    }

    fn stderr(self: *const Capture) []const u8 {
        return self.stderr_buffer[0..self.stderr_writer.end];
    }

    fn progress(self: *const Capture) []const u8 {
        return self.progress_buffer[0..self.progress_writer.end];
    }
};

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

    pub fn sleep(self: *FakeClock, duration_ns: u64) http.SleepError!void {
        self.now_ns += duration_ns;
    }
};

const FakeWallClock = struct {
    seconds: i64,

    pub fn unixSeconds(self: *FakeWallClock) i64 {
        return self.seconds;
    }
};

const SecretSequence = struct {
    values: []const []const u8,
    index: usize = 0,

    pub fn readSecret(
        self: *SecretSequence,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: usize,
    ) ![]u8 {
        if (self.index >= self.values.len) return error.NoMoreSecrets;
        const value = self.values[self.index];
        self.index += 1;
        return std.fmt.allocPrint(allocator, "{s}\n", .{value});
    }
};

const CapturedDescriptor = struct {
    media_type: []u8,
    digest: []u8,
    bytes: []u8,

    fn deinit(self: *CapturedDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.digest);
        allocator.free(self.media_type);
        self.* = undefined;
    }
};

const RecordingDestination = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    spool_path: []const u8,
    captures: [16]?CapturedDescriptor = @splat(null),
    capture_count: usize = 0,
    phase: enum {
        initial,
        prepared,
        staged,
        committed,
        finished,
        failed,
    } = .initial,
    config_outcome: wabt.oci.transport.DescriptorResult = .transferred,
    layer_outcome: wabt.oci.transport.DescriptorResult = .transferred,
    document_outcome: wabt.oci.transport.DescriptorResult = .transferred,
    root_outcome: wabt.oci.transport.DescriptorResult = .transferred,
    dependency_calls: usize = 0,
    fail_dependency_at: ?usize = null,
    fail_stage: bool = false,
    fail_commit: bool = false,
    fail_finish: bool = false,
    committed: bool = false,
    finished: bool = false,
    selected_tag: ?[]const u8 = null,

    fn reset(self: *RecordingDestination) void {
        self.clearCaptures();
        self.phase = .initial;
        self.config_outcome = .transferred;
        self.layer_outcome = .transferred;
        self.document_outcome = .transferred;
        self.root_outcome = .transferred;
        self.dependency_calls = 0;
        self.fail_dependency_at = null;
        self.fail_stage = false;
        self.fail_commit = false;
        self.fail_finish = false;
        self.committed = false;
        self.finished = false;
        self.selected_tag = null;
    }

    fn cleanup(self: *RecordingDestination) void {
        self.clearCaptures();
    }

    fn clearCaptures(self: *RecordingDestination) void {
        for (self.captures[0..self.capture_count]) |*slot| {
            if (slot.*) |*value| value.deinit(self.allocator);
            slot.* = null;
        }
        self.capture_count = 0;
    }

    pub fn asTransport(self: *RecordingDestination) wabt.oci.Destination {
        return wabt.oci.Destination.init(self);
    }

    pub fn deinit(_: *RecordingDestination) void {}

    pub fn prepareRoot(
        self: *RecordingDestination,
        _: wabt.oci.Descriptor,
        selection: ?wabt.oci.Selection,
    ) !void {
        if (self.phase != .initial) return error.DestinationStateConflict;
        const selected = selection orelse return error.TagRequired;
        self.selected_tag = switch (selected) {
            .tag => |tag| tag,
            .digest => null,
        };
        self.phase = .prepared;
    }

    pub fn ensureDescriptor(
        self: *RecordingDestination,
        transfer: wabt.oci.transport.DescriptorTransfer,
    ) !wabt.oci.transport.DescriptorResult {
        if (self.phase != .prepared) return error.DestinationStateConflict;
        if (self.fail_dependency_at == self.dependency_calls) {
            self.phase = .failed;
            return error.UploadAmbiguous;
        }
        self.dependency_calls += 1;
        try self.captureTransfer(transfer);
        if (transfer.roles.config) return self.config_outcome;
        if (transfer.roles.layer) return self.layer_outcome;
        return self.document_outcome;
    }

    pub fn stageRoot(
        self: *RecordingDestination,
        publication: wabt.oci.transport.RootPublication,
    ) !wabt.oci.transport.DescriptorResult {
        if (self.phase != .prepared) return error.DestinationStateConflict;
        if (self.fail_stage) {
            self.phase = .failed;
            return error.PublicationUnconfirmed;
        }
        try self.capture(publication.descriptor, publication.exact_bytes);
        self.phase = .staged;
        return self.root_outcome;
    }

    pub fn commitRoot(
        self: *RecordingDestination,
        _: wabt.oci.transport.RootPublication,
        _: ?wabt.oci.Selection,
    ) !wabt.oci.transport.CommitResult {
        if (self.phase != .staged) return error.DestinationStateConflict;
        if (self.fail_commit) {
            self.phase = .failed;
            return error.PublicationUnconfirmed;
        }
        self.phase = .committed;
        self.committed = true;
        return .published;
    }

    pub fn finish(self: *RecordingDestination) !void {
        if (self.phase != .committed) return error.DestinationStateConflict;
        if (self.fail_finish) {
            self.phase = .failed;
            return error.DestinationStateConflict;
        }
        self.phase = .finished;
        self.finished = true;
    }

    fn captureTransfer(
        self: *RecordingDestination,
        transfer: wabt.oci.transport.DescriptorTransfer,
    ) !void {
        switch (transfer.data) {
            .exact_metadata => |bytes| try self.capture(transfer.descriptor, bytes),
            .opaque_blob => |source| {
                const name = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/capture-{d}",
                    .{ self.spool_path, self.capture_count },
                );
                defer self.allocator.free(name);
                var file = try std.Io.Dir.cwd().createFile(self.io, name, .{
                    .read = true,
                    .truncate = true,
                });
                defer {
                    file.close(self.io);
                    std.Io.Dir.cwd().deleteFile(self.io, name) catch {};
                }
                try source.copyVerifiedTo(transfer.descriptor, file);
                const size = try file.length(self.io);
                if (size > std.math.maxInt(usize)) return error.FileTooBig;
                const bytes = try self.allocator.alloc(u8, @intCast(size));
                defer self.allocator.free(bytes);
                if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) {
                    return error.UnexpectedEndOfFile;
                }
                try self.capture(transfer.descriptor, bytes);
            },
        }
    }

    fn capture(
        self: *RecordingDestination,
        descriptor: wabt.oci.Descriptor,
        bytes: []const u8,
    ) !void {
        if (self.capture_count == self.captures.len) return error.TooManyCaptures;
        const digest = try wabt.oci.Digest.parse(descriptor.digest);
        try wabt.oci.content.verifyBytes(digest, descriptor.size, bytes);
        const media_type = try self.allocator.dupe(u8, descriptor.mediaType);
        errdefer self.allocator.free(media_type);
        const digest_text = try self.allocator.dupe(u8, descriptor.digest);
        errdefer self.allocator.free(digest_text);
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        self.captures[self.capture_count] = .{
            .media_type = media_type,
            .digest = digest_text,
            .bytes = owned_bytes,
        };
        self.capture_count += 1;
    }

    fn captured(self: *const RecordingDestination, digest: []const u8) ?*const CapturedDescriptor {
        for (self.captures[0..self.capture_count]) |*slot| {
            if (std.mem.eql(u8, slot.*.?.digest, digest)) return &slot.*.?;
        }
        return null;
    }
};

const DestinationFactory = struct {
    destination: *RecordingDestination,
    create_count: usize = 0,
    saw_basic: bool = false,
    saw_bearer: bool = false,
    saw_none: bool = false,
    saw_discover: bool = false,
    saw_ca: bool = false,
    deadline_ns: i128 = 0,
    expected_basic_user: ?[]const u8 = null,
    expected_basic_secret: ?[]const u8 = null,
    expected_bearer: ?[]const u8 = null,
    expected_ca: ?[]const u8 = null,

    fn create(
        context: ?*anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: wabt.oci.RegistryReference,
        destination_options: wabt.oci.RegistryDestinationOptions,
    ) !runtime_mod.RegistryDestinationHandle {
        const self: *DestinationFactory = @ptrCast(@alignCast(context.?));
        self.create_count += 1;
        self.deadline_ns = destination_options.deadline.at_ns;
        self.saw_ca = if (destination_options.additional_ca) |ca| switch (ca) {
            .file_path => |path| if (self.expected_ca) |expected|
                std.mem.eql(u8, path, expected)
            else
                true,
            .pem_data => false,
        } else false;
        switch (destination_options.credential_policy) {
            .supplied => |credential| switch (credential) {
                .basic => |basic| {
                    self.saw_basic =
                        (self.expected_basic_user == null or std.mem.eql(
                            u8,
                            basic.username,
                            self.expected_basic_user.?,
                        )) and
                        (self.expected_basic_secret == null or std.mem.eql(
                            u8,
                            basic.secret,
                            self.expected_basic_secret.?,
                        ));
                },
                .bearer_token => |token| {
                    self.saw_bearer = self.expected_bearer == null or
                        std.mem.eql(u8, token, self.expected_bearer.?);
                },
            },
            .auth_file => {},
            .none => self.saw_none = true,
            .discover => self.saw_discover = true,
        }
        return runtime_mod.RegistryDestinationHandle.init(self.destination);
    }
};

const PackageRegistryBackend = struct {
    package: *const wabt.oci.PreparedWasmArtifact,
    moved_package: ?*const wabt.oci.PreparedWasmArtifact = null,
    tag_reads: usize = 0,
    requests: usize = 0,
    fail_payload: bool = false,
    last_authorization: [512]u8 = undefined,
    last_authorization_len: usize = 0,

    fn backend(self: *PackageRegistryBackend) http.Backend {
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
        self: *PackageRegistryBackend,
        allocator: std.mem.Allocator,
        request_options: http.BackendRequest,
    ) http.BackendError!http.Response {
        self.requests += 1;
        if (request_options.authorization) |authorization| {
            if (authorization.len > self.last_authorization.len) {
                return error.ProtocolFailure;
            }
            @memcpy(self.last_authorization[0..authorization.len], authorization);
            self.last_authorization_len = authorization.len;
        }

        const root_tag_path = "/manifests/latest";
        if (request_options.method == .GET and
            std.mem.endsWith(u8, request_options.url, root_tag_path))
        {
            self.tag_reads += 1;
            const selected = if (self.tag_reads == 1 or self.moved_package == null)
                self.package
            else
                self.moved_package.?;
            return respond(
                allocator,
                request_options,
                selected.root_descriptor,
                selected.manifest_bytes,
            );
        }

        for ([2]*const wabt.oci.PreparedWasmArtifact{
            self.package,
            self.moved_package orelse self.package,
        }) |package| {
            if (std.mem.endsWith(
                u8,
                request_options.url,
                package.root_descriptor.digest,
            )) {
                return respond(
                    allocator,
                    request_options,
                    package.root_descriptor,
                    package.manifest_bytes,
                );
            }
            if (std.mem.endsWith(
                u8,
                request_options.url,
                package.config_descriptor.digest,
            )) {
                return respond(
                    allocator,
                    request_options,
                    package.config_descriptor,
                    package.config_bytes,
                );
            }
            if (std.mem.endsWith(
                u8,
                request_options.url,
                package.layer_descriptor.digest,
            )) {
                if (self.fail_payload) return error.ConnectionReset;
                return respond(
                    allocator,
                    request_options,
                    package.layer_descriptor,
                    package.payload_bytes,
                );
            }
        }
        return http.Response.initCopy(allocator, 404, &.{}, "") catch
            error.OutOfMemory;
    }

    fn respond(
        allocator: std.mem.Allocator,
        request_options: http.BackendRequest,
        descriptor: wabt.oci.Descriptor,
        bytes: []const u8,
    ) http.BackendError!http.Response {
        var length_buffer: [32]u8 = undefined;
        const length = std.fmt.bufPrint(
            &length_buffer,
            "{d}",
            .{descriptor.size},
        ) catch return error.ProtocolFailure;
        const headers = [_]http.Header{
            .{ .name = "Content-Type", .value = descriptor.mediaType },
            .{ .name = "Content-Length", .value = length },
            .{ .name = "Docker-Content-Digest", .value = descriptor.digest },
        };
        if (request_options.body_sink) |sink| {
            sink.begin(descriptor.size) catch return error.BodySinkFailed;
            sink.write(bytes) catch return error.BodySinkFailed;
            sink.finish() catch return error.BodySinkFailed;
            return http.Response.initCopy(allocator, 200, &headers, "") catch
                error.OutOfMemory;
        }
        return http.Response.initCopy(allocator, 200, &headers, bytes) catch
            error.OutOfMemory;
    }
};

const SourceFactory = struct {
    backend: *PackageRegistryBackend,
    clock: *FakeClock,
    create_count: usize = 0,
    saw_basic: bool = false,
    saw_bearer: bool = false,
    saw_ca: bool = false,
    deadline_ns: i128 = 0,
    expected_basic_user: ?[]const u8 = null,
    expected_basic_secret: ?[]const u8 = null,
    expected_bearer: ?[]const u8 = null,
    expected_ca: ?[]const u8 = null,

    fn create(
        context: ?*anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        reference: wabt.oci.RegistryReference,
        source_options: wabt.oci.RegistryOptions,
    ) !wabt.oci.RegistrySource {
        const self: *SourceFactory = @ptrCast(@alignCast(context.?));
        self.create_count += 1;
        self.deadline_ns = source_options.deadline.at_ns;
        self.saw_ca = if (source_options.additional_ca) |ca| switch (ca) {
            .file_path => |path| if (self.expected_ca) |expected|
                std.mem.eql(u8, path, expected)
            else
                true,
            .pem_data => false,
        } else false;
        switch (source_options.credential_policy) {
            .supplied => |credential| switch (credential) {
                .basic => |basic| {
                    self.saw_basic =
                        (self.expected_basic_user == null or std.mem.eql(
                            u8,
                            basic.username,
                            self.expected_basic_user.?,
                        )) and
                        (self.expected_basic_secret == null or std.mem.eql(
                            u8,
                            basic.secret,
                            self.expected_basic_secret.?,
                        ));
                },
                .bearer_token => |token| {
                    self.saw_bearer = self.expected_bearer == null or
                        std.mem.eql(u8, token, self.expected_bearer.?);
                },
            },
            else => {},
        }
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

fn initRuntime(
    counters: *runtime_mod.Counters,
    capture: *Capture,
) runtime_mod.Runtime {
    var runtime = runtime_mod.Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        counters,
    );
    capture.attach(&runtime);
    return runtime;
}

fn tempPath(
    allocator: std.mem.Allocator,
    temporary: *const std.testing.TmpDir,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/{s}",
        .{ temporary.sub_path, name },
    );
}

fn writeTempFile(
    temporary: *std.testing.TmpDir,
    name: []const u8,
    bytes: []const u8,
) !void {
    var file = try temporary.dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

fn preparePackage(
    allocator: std.mem.Allocator,
    payload: []const u8,
    profile: wabt.oci.WasmProfile,
    created: []const u8,
    source_name: []const u8,
) !wabt.oci.PreparedWasmArtifact {
    return wabt.oci.prepareWasmArtifact(allocator, payload, .{
        .profile = profile,
        .created = created,
        .author = if (profile == .wasm_v0) "WABT" else null,
        .source_name = source_name,
    });
}

fn publishLayout(
    allocator: std.mem.Allocator,
    package: *const wabt.oci.PreparedWasmArtifact,
    path: []const u8,
    tag: []const u8,
) !void {
    _ = try wabt.oci.copyPackageToLayout(
        std.testing.io,
        allocator,
        package,
        .{ .path = path, .selection = .{ .tag = tag } },
        .{},
    );
}

fn layoutReferenceAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    tag: ?[]const u8,
) ![]u8 {
    return if (tag) |value|
        std.fmt.allocPrint(allocator, "oci:{s}:{s}", .{ path, value })
    else
        std.fmt.allocPrint(allocator, "oci:{s}", .{path});
}

fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(limit),
    );
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(
        std.testing.io,
        path,
        .{ .truncate = true },
    );
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}

const TestDescriptor = struct {
    media_type: []const u8,
    digest_text: [wabt.oci.content.digest_text_size]u8,
    size: u64,

    fn init(media_type: []const u8, bytes: []const u8) !TestDescriptor {
        const description = try wabt.oci.content.describeBytes(bytes);
        return .{
            .media_type = media_type,
            .digest_text = description.digest.format(),
            .size = description.size,
        };
    }

    fn value(self: *const TestDescriptor) wabt.oci.Descriptor {
        return .{
            .mediaType = self.media_type,
            .digest = &self.digest_text,
            .size = self.size,
        };
    }
};

fn writeLayoutBlob(
    allocator: std.mem.Allocator,
    layout_path: []const u8,
    descriptor: *const TestDescriptor,
    bytes: []const u8,
) !void {
    const digest = try wabt.oci.Digest.parse(&descriptor.digest_text);
    const blob_path = digest.blobPath();
    const full_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ layout_path, &blob_path },
    );
    defer allocator.free(full_path);
    try writeFile(full_path, bytes);
}

fn writeLayoutIndex(
    allocator: std.mem.Allocator,
    layout_path: []const u8,
    descriptor: wabt.oci.Descriptor,
    tag: []const u8,
) !void {
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d},\"annotations\":{{\"org.opencontainers.image.ref.name\":\"{s}\"}}}}]}}",
        .{
            wabt.oci.model.media_type_oci_index,
            descriptor.mediaType,
            descriptor.digest,
            descriptor.size,
            tag,
        },
    );
    defer allocator.free(bytes);
    const index_path = try std.fmt.allocPrint(
        allocator,
        "{s}/index.json",
        .{layout_path},
    );
    defer allocator.free(index_path);
    try writeFile(index_path, bytes);
}

const FailOnWrite = struct {
    fail_at: usize,
    calls: usize = 0,
    bytes: [2048]u8 = undefined,
    len: usize = 0,

    pub fn writeAll(self: *FailOnWrite, data: []const u8) !void {
        self.calls += 1;
        if (self.calls == self.fail_at) return error.InjectedWriteFailure;
        if (self.len + data.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }
};

test "push publishes exact Wasm-v0 core/component and generic package bytes" {
    const allocator = std.testing.allocator;
    const core = "\x00asm\x01\x00\x00\x00";
    const component = "\x00asm\x0d\x00\x01\x00";
    const Case = struct {
        payload: []const u8,
        profile: wabt.oci.WasmProfile,
        format_args: []const []const u8,
        expected_profile: []const u8,
        name: []const u8,
    };
    const cases = [_]Case{
        .{
            .payload = core,
            .profile = .wasm_v0,
            .format_args = &.{},
            .expected_profile = "wasm-v0",
            .name = "core.wasm",
        },
        .{
            .payload = component,
            .profile = .wasm_v0,
            .format_args = &.{},
            .expected_profile = "wasm-v0",
            .name = "component.wasm",
        },
        .{
            .payload = core,
            .profile = .oci,
            .format_args = &.{ "--format", "oci" },
            .expected_profile = "oci-1.1",
            .name = "generic.wasm",
        },
    };

    for (cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try writeTempFile(&temporary, case.name, case.payload);
        const input_path = try tempPath(allocator, &temporary, case.name);
        defer allocator.free(input_path);
        const spool_path = try tempPath(allocator, &temporary, ".");
        defer allocator.free(spool_path);

        var expected = try preparePackage(
            allocator,
            case.payload,
            case.profile,
            "2026-09-19T00:00:00Z",
            case.name,
        );
        defer expected.deinit();
        var destination: RecordingDestination = .{
            .allocator = allocator,
            .io = std.testing.io,
            .spool_path = spool_path,
        };
        defer destination.cleanup();
        var factory: DestinationFactory = .{ .destination = &destination };
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_destination_factory = .{
            .context = &factory,
            .create_fn = DestinationFactory.create,
        };

        var args: [8][]const u8 = undefined;
        args[0] = "registry.example/team/app:latest";
        args[1] = input_path;
        var len: usize = 2;
        for (case.format_args) |arg| {
            args[len] = arg;
            len += 1;
        }
        args[len] = "--created";
        len += 1;
        args[len] = "2026-09-19T00:00:00Z";
        len += 1;
        if (case.profile == .wasm_v0) {
            args[len] = "--author";
            len += 1;
            args[len] = "WABT";
            len += 1;
        }
        args[len] = "--json";
        len += 1;
        try push_cmd.execute(args[0..len], &runtime);

        try std.testing.expect(destination.finished);
        try std.testing.expectEqual(@as(usize, 3), destination.capture_count);
        try std.testing.expectEqualSlices(
            u8,
            expected.manifest_bytes,
            destination.captured(expected.root_descriptor.digest).?.bytes,
        );
        try std.testing.expectEqualSlices(
            u8,
            expected.config_bytes,
            destination.captured(expected.config_descriptor.digest).?.bytes,
        );
        try std.testing.expectEqualSlices(
            u8,
            case.payload,
            destination.captured(expected.layer_descriptor.digest).?.bytes,
        );
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"schema\":\"wabt.oci.push\"",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            case.expected_profile,
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            expected.root_descriptor.digest,
        ) != null);
        try std.testing.expectEqual(@as(usize, 1), counters.network_clients);
        try std.testing.expectEqual(@as(usize, 0), counters.stdin_reads);
    }
}

test "push creation time policy explains deterministic and changing digests" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeTempFile(&temporary, "module.wasm", payload);
    const input_path = try tempPath(allocator, &temporary, "module.wasm");
    defer allocator.free(input_path);
    const spool_path = try tempPath(allocator, &temporary, ".");
    defer allocator.free(spool_path);

    var first_digest: [wabt.oci.content.digest_text_size]u8 = undefined;
    var changed_digest: [wabt.oci.content.digest_text_size]u8 = undefined;
    const seconds = [_]i64{ 0, 0, 1 };
    for (seconds, 0..) |second, index| {
        var destination: RecordingDestination = .{
            .allocator = allocator,
            .io = std.testing.io,
            .spool_path = spool_path,
        };
        defer destination.cleanup();
        var factory: DestinationFactory = .{ .destination = &destination };
        var wall_clock: FakeWallClock = .{ .seconds = second };
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_destination_factory = .{
            .context = &factory,
            .create_fn = DestinationFactory.create,
        };
        runtime.wall_clock = runtime_mod.WallClock.init(&wall_clock);
        try push_cmd.execute(&.{
            "registry.example/team/app:latest",
            input_path,
        }, &runtime);
        const root = destination.captures[destination.capture_count - 1].?.digest;
        if (index == 0) {
            @memcpy(&first_digest, root);
        } else if (index == 1) {
            try std.testing.expectEqualStrings(&first_digest, root);
        } else {
            @memcpy(&changed_digest, root);
            try std.testing.expect(!std.mem.eql(
                u8,
                &first_digest,
                &changed_digest,
            ));
        }
        const expected_stdout = try std.fmt.allocPrint(
            allocator,
            "registry.example/team/app@{s}\n",
            .{root},
        );
        defer allocator.free(expected_stdout);
        try std.testing.expectEqualStrings(expected_stdout, capture.stdout());
    }

    var explicit_one = try preparePackage(
        allocator,
        payload,
        .wasm_v0,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer explicit_one.deinit();
    var explicit_two = try preparePackage(
        allocator,
        payload,
        .wasm_v0,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer explicit_two.deinit();
    try std.testing.expectEqualStrings(
        explicit_one.root_descriptor.digest,
        explicit_two.root_descriptor.digest,
    );
}

test "push rejects invalid truncated oversized and unsupported inputs before registry access" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "not-wasm",
        "\x00asm\x02\x00\x00\x00",
        "\x00asm\x0d\x00",
    };
    for (cases, 0..) |bytes, index| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const name = try std.fmt.allocPrint(allocator, "invalid-{d}.wasm", .{index});
        defer allocator.free(name);
        try writeTempFile(&temporary, name, bytes);
        const input_path = try tempPath(allocator, &temporary, name);
        defer allocator.free(input_path);
        const spool_path = try tempPath(allocator, &temporary, ".");
        defer allocator.free(spool_path);
        var destination: RecordingDestination = .{
            .allocator = allocator,
            .io = std.testing.io,
            .spool_path = spool_path,
        };
        defer destination.cleanup();
        var factory: DestinationFactory = .{ .destination = &destination };
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_destination_factory = .{
            .context = &factory,
            .create_fn = DestinationFactory.create,
        };
        try std.testing.expectError(
            error.InvalidPayload,
            push_cmd.execute(&.{
                "registry.example/team/app:latest",
                input_path,
                "--created",
                "2026-09-19T00:00:00Z",
            }, &runtime),
        );
        try std.testing.expectEqual(@as(usize, 0), factory.create_count);
        try std.testing.expect(counters.isZero());
    }

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var oversized = try temporary.dir.createFile(
        std.testing.io,
        "oversized.wasm",
        .{},
    );
    try oversized.setLength(
        std.testing.io,
        wabt.oci.wasm.max_payload_bytes + 1,
    );
    oversized.close(std.testing.io);
    const oversized_path = try tempPath(allocator, &temporary, "oversized.wasm");
    defer allocator.free(oversized_path);
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    try std.testing.expectError(
        error.LimitExceeded,
        push_cmd.execute(&.{
            "registry.example/team/app:latest",
            oversized_path,
            "--created",
            "2026-09-19T00:00:00Z",
        }, &runtime),
    );
    try std.testing.expect(counters.isZero());
}

test "push maps endpoint policy and commit-gated reporting failures" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try writeTempFile(&temporary, "module.wasm", payload);
    const input_path = try tempPath(allocator, &temporary, "module.wasm");
    defer allocator.free(input_path);
    const spool_path = try tempPath(allocator, &temporary, ".");
    defer allocator.free(spool_path);

    var destination: RecordingDestination = .{
        .allocator = allocator,
        .io = std.testing.io,
        .spool_path = spool_path,
    };
    defer destination.cleanup();
    var factory: DestinationFactory = .{
        .destination = &destination,
        .expected_basic_user = "alice",
        .expected_basic_secret = "password",
        .expected_ca = "ca.pem",
    };
    var secrets: SecretSequence = .{ .values = &.{"password"} };
    var clock: FakeClock = .{ .now_ns = 40 };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    runtime.secret_provider = runtime_mod.SecretProvider.init(&secrets);
    runtime.clock = runtime_mod.Clock.init(&clock);
    try push_cmd.execute(&.{
        "localhost:5000/team/app:latest",
        input_path,
        "--created",
        "2026-09-19T00:00:00Z",
        "--username",
        "alice",
        "--password-stdin",
        "--ca-file",
        "ca.pem",
        "--deadline",
        "3s",
        "--plain-http",
    }, &runtime);
    try std.testing.expect(factory.saw_basic);
    try std.testing.expect(factory.saw_ca);
    try std.testing.expectEqual(
        @as(i128, 40 + 3 * std.time.ns_per_s),
        factory.deadline_ns,
    );
    try std.testing.expectEqual(@as(usize, 1), counters.stdin_reads);

    destination.reset();
    factory = .{ .destination = &destination };
    capture.reset();
    counters = .{};
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    var failing_stdout = std.Io.Writer.failing;
    runtime.stdout = runtime_mod.OutputSink.fromWriter(&failing_stdout);
    try std.testing.expectError(
        error.CommittedButReportingFailed,
        push_cmd.execute(&.{
            "registry.example/team/app:latest",
            input_path,
            "--created",
            "2026-09-19T00:00:00Z",
        }, &runtime),
    );
    try std.testing.expect(destination.finished);

    destination.reset();
    factory = .{ .destination = &destination };
    capture.reset();
    counters = .{};
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    var failing_progress = std.Io.Writer.failing;
    runtime.progress = runtime_mod.OutputSink.fromWriter(&failing_progress);
    try std.testing.expectError(
        error.ProgressWriteFailed,
        push_cmd.execute(&.{
            "registry.example/team/app:latest",
            input_path,
            "--created",
            "2026-09-19T00:00:00Z",
        }, &runtime),
    );
    try std.testing.expectEqual(@as(usize, 0), factory.create_count);
    try std.testing.expect(!destination.committed);

    destination.reset();
    factory = .{ .destination = &destination };
    capture.reset();
    counters = .{};
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    var fail_after: FailOnWrite = .{ .fail_at = 2 };
    runtime.progress = runtime_mod.OutputSink.init(&fail_after);
    try std.testing.expectError(
        error.CommittedButReportingFailed,
        push_cmd.execute(&.{
            "registry.example/team/app:latest",
            input_path,
            "--created",
            "2026-09-19T00:00:00Z",
        }, &runtime),
    );
    try std.testing.expect(destination.finished);

    destination.reset();
    destination.fail_commit = true;
    factory = .{ .destination = &destination };
    capture.reset();
    counters = .{};
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    try std.testing.expectError(
        error.UploadAmbiguous,
        push_cmd.execute(&.{
            "registry.example/team/app:latest",
            input_path,
            "--created",
            "2026-09-19T00:00:00Z",
        }, &runtime),
    );
    try std.testing.expectEqualStrings("", capture.stdout());
    try std.testing.expect(!destination.committed);
}

test "write diagnostics are stable and redact secret-shaped text" {
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    try output.writeDiagnostic(
        &runtime,
        "push",
        error.CommittedButReportingFailed,
    );
    try std.testing.expectEqualStrings(
        "error: wabt oci push: operation committed but reporting failed\n",
        capture.stderr(),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stderr(),
        "TOP_SECRET",
    ) == null);
}

test "copy executes all four endpoint pairings with immutable roots and exact counts" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer package.deinit();
    var moved = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:01Z",
        "module.wasm",
    );
    defer moved.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_layout = try tempPath(allocator, &temporary, "source-layout");
    defer allocator.free(source_layout);
    const destination_layout_one = try tempPath(
        allocator,
        &temporary,
        "destination-layout-one",
    );
    defer allocator.free(destination_layout_one);
    const destination_layout_two = try tempPath(
        allocator,
        &temporary,
        "destination-layout-two",
    );
    defer allocator.free(destination_layout_two);
    const spool_path = try tempPath(allocator, &temporary, ".");
    defer allocator.free(spool_path);
    try publishLayout(allocator, &package, source_layout, "root");
    const source_layout_ref = try layoutReferenceAlloc(
        allocator,
        source_layout,
        "root",
    );
    defer allocator.free(source_layout_ref);
    const destination_layout_one_ref = try layoutReferenceAlloc(
        allocator,
        destination_layout_one,
        "copy",
    );
    defer allocator.free(destination_layout_one_ref);
    const destination_layout_two_ref = try layoutReferenceAlloc(
        allocator,
        destination_layout_two,
        "copy",
    );
    defer allocator.free(destination_layout_two_ref);

    {
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        try copy_cmd.execute(&.{
            source_layout_ref,
            destination_layout_one_ref,
            "--json",
        }, &runtime);
        try std.testing.expect(counters.isZero());
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"schema\":\"wabt.oci.copy\"",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"transferred\":3",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            "\"manifest\":{\"mediaType\":",
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

    var recording: RecordingDestination = .{
        .allocator = allocator,
        .io = std.testing.io,
        .spool_path = spool_path,
    };
    defer recording.cleanup();
    var destination_factory: DestinationFactory = .{
        .destination = &recording,
    };
    {
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_destination_factory = .{
            .context = &destination_factory,
            .create_fn = DestinationFactory.create,
        };
        try copy_cmd.execute(&.{
            source_layout_ref,
            "registry.example/team/destination:latest",
            "--json",
        }, &runtime);
        try std.testing.expect(recording.finished);
        try std.testing.expectEqual(@as(usize, 3), recording.capture_count);
        try std.testing.expectEqual(@as(usize, 1), counters.network_clients);
        try std.testing.expect(std.mem.indexOf(
            u8,
            capture.stdout(),
            package.root_descriptor.digest,
        ) != null);
    }

    recording.reset();
    destination_factory = .{ .destination = &recording };
    const digest_destination = try std.fmt.allocPrint(
        allocator,
        "registry.example/team/destination@{s}",
        .{package.root_descriptor.digest},
    );
    defer allocator.free(digest_destination);
    {
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_destination_factory = .{
            .context = &destination_factory,
            .create_fn = DestinationFactory.create,
        };
        try copy_cmd.execute(&.{
            source_layout_ref,
            digest_destination,
            "--json",
        }, &runtime);
        try std.testing.expect(recording.finished);
        try std.testing.expect(recording.selected_tag == null);
        try std.testing.expectEqual(@as(usize, 1), destination_factory.create_count);
    }

    recording.reset();
    destination_factory = .{ .destination = &recording };
    {
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_destination_factory = .{
            .context = &destination_factory,
            .create_fn = DestinationFactory.create,
        };
        try std.testing.expectError(
            error.DestinationDigestMismatch,
            copy_cmd.execute(&.{
                source_layout_ref,
                "registry.example/team/destination@" ++
                    "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            }, &runtime),
        );
        try std.testing.expectEqual(@as(usize, 0), destination_factory.create_count);
        try std.testing.expect(counters.isZero());
    }

    var backend: PackageRegistryBackend = .{
        .package = &package,
        .moved_package = &moved,
    };
    var clock: FakeClock = .{};
    var source_factory: SourceFactory = .{
        .backend = &backend,
        .clock = &clock,
    };
    {
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_factory = .{
            .context = &source_factory,
            .create_fn = SourceFactory.create,
        };
        try copy_cmd.execute(&.{
            "registry.example/team/source:latest",
            destination_layout_two_ref,
            "--source-no-credential-discovery",
            "--json",
        }, &runtime);
        try std.testing.expectEqual(@as(usize, 1), backend.tag_reads);
        try std.testing.expectEqual(@as(usize, 1), counters.network_clients);
        var layout_source = wabt.oci.LayoutSource.init(
            std.testing.io,
            allocator,
            destination_layout_two,
        );
        var resolved = try layout_source.resolve(.{
            .path = destination_layout_two,
            .selection = .{ .tag = "copy" },
        });
        defer resolved.deinit();
        try std.testing.expectEqualStrings(
            package.root_descriptor.digest,
            resolved.descriptor.digest,
        );
    }

    recording.reset();
    destination_factory = .{ .destination = &recording };
    backend.tag_reads = 0;
    backend.requests = 0;
    source_factory.create_count = 0;
    {
        var counters: runtime_mod.Counters = .{};
        var capture: Capture = undefined;
        capture.reset();
        var runtime = initRuntime(&counters, &capture);
        runtime.registry_factory = .{
            .context = &source_factory,
            .create_fn = SourceFactory.create,
        };
        runtime.registry_destination_factory = .{
            .context = &destination_factory,
            .create_fn = DestinationFactory.create,
        };
        try copy_cmd.execute(&.{
            "registry.example/team/source:latest",
            "registry.example/team/destination:latest",
            "--source-no-credential-discovery",
            "--destination-no-credential-discovery",
            "--json",
        }, &runtime);
        try std.testing.expectEqual(@as(usize, 1), backend.tag_reads);
        try std.testing.expectEqual(@as(usize, 2), counters.network_clients);
        try std.testing.expect(recording.finished);
        try std.testing.expect(
            recording.captured(package.root_descriptor.digest) != null,
        );
        try std.testing.expect(
            recording.captured(moved.root_descriptor.digest) == null,
        );
    }
}

test "copy keeps endpoint credentials CA deadlines and stdin records independent" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer package.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const spool_path = try tempPath(allocator, &temporary, ".");
    defer allocator.free(spool_path);
    var recording: RecordingDestination = .{
        .allocator = allocator,
        .io = std.testing.io,
        .spool_path = spool_path,
    };
    defer recording.cleanup();
    var backend: PackageRegistryBackend = .{ .package = &package };
    var clock: FakeClock = .{ .now_ns = 100 };
    var source_factory: SourceFactory = .{
        .backend = &backend,
        .clock = &clock,
        .expected_basic_user = "source-user",
        .expected_basic_secret = "source-password",
        .expected_ca = "source-ca.pem",
    };
    var destination_factory: DestinationFactory = .{
        .destination = &recording,
        .expected_bearer = "destination-token",
        .expected_ca = "destination-ca.pem",
    };
    var secrets: SecretSequence = .{
        .values = &.{ "source-password", "destination-token" },
    };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    runtime.registry_factory = .{
        .context = &source_factory,
        .create_fn = SourceFactory.create,
    };
    runtime.registry_destination_factory = .{
        .context = &destination_factory,
        .create_fn = DestinationFactory.create,
    };
    runtime.secret_provider = runtime_mod.SecretProvider.init(&secrets);
    runtime.clock = runtime_mod.Clock.init(&clock);
    try copy_cmd.execute(&.{
        "localhost:5000/team/source:latest",
        "localhost:6000/team/destination:latest",
        "--source-username",
        "source-user",
        "--source-password-stdin",
        "--source-ca-file",
        "source-ca.pem",
        "--source-deadline",
        "3s",
        "--source-plain-http",
        "--destination-token-stdin",
        "--destination-ca-file",
        "destination-ca.pem",
        "--destination-deadline",
        "5s",
        "--destination-plain-http",
        "--json",
    }, &runtime);
    try std.testing.expect(source_factory.saw_basic);
    try std.testing.expect(source_factory.saw_ca);
    try std.testing.expect(destination_factory.saw_bearer);
    try std.testing.expect(destination_factory.saw_ca);
    try std.testing.expectEqual(
        @as(i128, 100 + 3 * std.time.ns_per_s),
        source_factory.deadline_ns,
    );
    try std.testing.expectEqual(
        @as(i128, 100 + 5 * std.time.ns_per_s),
        destination_factory.deadline_ns,
    );
    try std.testing.expectEqual(@as(usize, 2), secrets.index);
    try std.testing.expectEqual(@as(usize, 2), counters.stdin_reads);
    try std.testing.expectEqual(@as(usize, 2), counters.network_clients);
}

test "copy reports reused mounted transferred counters and root-last failures" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer package.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_layout = try tempPath(allocator, &temporary, "source");
    defer allocator.free(source_layout);
    const spool_path = try tempPath(allocator, &temporary, ".");
    defer allocator.free(spool_path);
    try publishLayout(allocator, &package, source_layout, "root");
    const source_ref = try layoutReferenceAlloc(allocator, source_layout, "root");
    defer allocator.free(source_ref);

    var recording: RecordingDestination = .{
        .allocator = allocator,
        .io = std.testing.io,
        .spool_path = spool_path,
        .config_outcome = .reused,
        .layer_outcome = .mounted,
        .root_outcome = .transferred,
    };
    defer recording.cleanup();
    var factory: DestinationFactory = .{ .destination = &recording };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    try copy_cmd.execute(&.{
        source_ref,
        "registry.example/team/destination:latest",
        "--json",
    }, &runtime);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"transferred\":1,\"reused\":1,\"mounted\":1",
    ) != null);

    recording.reset();
    recording.fail_dependency_at = 1;
    factory = .{ .destination = &recording };
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    try std.testing.expectError(
        error.UploadAmbiguous,
        copy_cmd.execute(&.{
            source_ref,
            "registry.example/team/destination:latest",
        }, &runtime),
    );
    try std.testing.expect(!recording.committed);
    try std.testing.expectEqualStrings("", capture.stdout());

    recording.reset();
    recording.fail_commit = true;
    factory = .{ .destination = &recording };
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    try std.testing.expectError(
        error.UploadAmbiguous,
        copy_cmd.execute(&.{
            source_ref,
            "registry.example/team/destination:latest",
        }, &runtime),
    );
    try std.testing.expect(!recording.committed);
    try std.testing.expectEqualStrings("", capture.stdout());
}

test "copy output and progress failures distinguish before and after commit" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer package.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_layout = try tempPath(allocator, &temporary, "source");
    defer allocator.free(source_layout);
    const spool_path = try tempPath(allocator, &temporary, ".");
    defer allocator.free(spool_path);
    try publishLayout(allocator, &package, source_layout, "root");
    const source_ref = try layoutReferenceAlloc(allocator, source_layout, "root");
    defer allocator.free(source_ref);

    var recording: RecordingDestination = .{
        .allocator = allocator,
        .io = std.testing.io,
        .spool_path = spool_path,
    };
    defer recording.cleanup();
    var factory: DestinationFactory = .{ .destination = &recording };
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    var failing_stdout = std.Io.Writer.failing;
    runtime.stdout = runtime_mod.OutputSink.fromWriter(&failing_stdout);
    try std.testing.expectError(
        error.CommittedButReportingFailed,
        copy_cmd.execute(&.{
            source_ref,
            "registry.example/team/destination:latest",
        }, &runtime),
    );
    try std.testing.expect(recording.finished);

    recording.reset();
    factory = .{ .destination = &recording };
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    var fail_before: FailOnWrite = .{ .fail_at = 1 };
    runtime.progress = runtime_mod.OutputSink.init(&fail_before);
    try std.testing.expectError(
        error.ProgressWriteFailed,
        copy_cmd.execute(&.{
            source_ref,
            "registry.example/team/destination:latest",
        }, &runtime),
    );
    try std.testing.expectEqual(@as(usize, 0), factory.create_count);
    try std.testing.expect(!recording.committed);

    recording.reset();
    factory = .{ .destination = &recording };
    counters = .{};
    capture.reset();
    runtime = initRuntime(&counters, &capture);
    runtime.registry_destination_factory = .{
        .context = &factory,
        .create_fn = DestinationFactory.create,
    };
    var fail_after: FailOnWrite = .{ .fail_at = 2 };
    runtime.progress = runtime_mod.OutputSink.init(&fail_after);
    try std.testing.expectError(
        error.CommittedButReportingFailed,
        copy_cmd.execute(&.{
            source_ref,
            "registry.example/team/destination:latest",
        }, &runtime),
    );
    try std.testing.expect(recording.finished);
}

test "layout copy preserves nested shared graphs and exact root extensions" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var first = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:00Z",
        "one.wasm",
    );
    defer first.deinit();
    var second = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:01Z",
        "two.wasm",
    );
    defer second.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_layout = try tempPath(allocator, &temporary, "source");
    defer allocator.free(source_layout);
    const destination_layout = try tempPath(allocator, &temporary, "destination");
    defer allocator.free(destination_layout);
    try publishLayout(allocator, &first, source_layout, "one");
    try publishLayout(allocator, &second, source_layout, "two");

    const nested_bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d},\"x-child\":1}},{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d},\"x-child\":2}}],\"x-root\":{{\"exact\":true}}}}",
        .{
            wabt.oci.model.media_type_oci_index,
            first.root_descriptor.mediaType,
            first.root_descriptor.digest,
            first.root_descriptor.size,
            second.root_descriptor.mediaType,
            second.root_descriptor.digest,
            second.root_descriptor.size,
        },
    );
    defer allocator.free(nested_bytes);
    var nested = try TestDescriptor.init(
        wabt.oci.model.media_type_oci_index,
        nested_bytes,
    );
    try writeLayoutBlob(allocator, source_layout, &nested, nested_bytes);
    try writeLayoutIndex(
        allocator,
        source_layout,
        nested.value(),
        "nested",
    );
    const source_ref = try layoutReferenceAlloc(
        allocator,
        source_layout,
        "nested",
    );
    defer allocator.free(source_ref);
    const destination_ref = try layoutReferenceAlloc(
        allocator,
        destination_layout,
        "nested",
    );
    defer allocator.free(destination_ref);
    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    try copy_cmd.execute(&.{ source_ref, destination_ref, "--json" }, &runtime);
    try std.testing.expect(counters.isZero());

    const copied_digest = try wabt.oci.Digest.parse(&nested.digest_text);
    const copied_blob = copied_digest.blobPath();
    const copied_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ destination_layout, &copied_blob },
    );
    defer allocator.free(copied_path);
    const copied = try readFileAlloc(allocator, copied_path, 1024 * 1024);
    defer allocator.free(copied);
    try std.testing.expectEqualSlices(u8, nested_bytes, copied);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"transferred\":5",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        capture.stdout(),
        "\"manifest\":null,\"config\":null,\"payload\":null",
    ) != null);
}

test "layout copy maps corruption subjects limits and interruption while retaining old root" {
    const allocator = std.testing.allocator;
    const payload = "\x00asm\x01\x00\x00\x00";
    var package = try preparePackage(
        allocator,
        payload,
        .oci,
        "2026-09-19T00:00:00Z",
        "module.wasm",
    );
    defer package.deinit();
    var old_package = try preparePackage(
        allocator,
        "\x00asm\x0d\x00\x01\x00",
        .oci,
        "2026-09-18T00:00:00Z",
        "old.wasm",
    );
    defer old_package.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_layout = try tempPath(allocator, &temporary, "source");
    defer allocator.free(source_layout);
    const destination_layout = try tempPath(allocator, &temporary, "destination");
    defer allocator.free(destination_layout);
    try publishLayout(allocator, &package, source_layout, "root");
    try publishLayout(allocator, &old_package, destination_layout, "old");
    const source_ref = try layoutReferenceAlloc(allocator, source_layout, "root");
    defer allocator.free(source_ref);
    const destination_ref = try layoutReferenceAlloc(
        allocator,
        destination_layout,
        "new",
    );
    defer allocator.free(destination_ref);
    const destination_index_path = try std.fmt.allocPrint(
        allocator,
        "{s}/index.json",
        .{destination_layout},
    );
    defer allocator.free(destination_index_path);
    const before = try readFileAlloc(
        allocator,
        destination_index_path,
        1024 * 1024,
    );
    defer allocator.free(before);

    var counters: runtime_mod.Counters = .{};
    var capture: Capture = undefined;
    capture.reset();
    var runtime = initRuntime(&counters, &capture);
    runtime.graph_limits.max_nodes = 0;
    try std.testing.expectError(
        error.LimitExceeded,
        copy_cmd.execute(&.{ source_ref, destination_ref }, &runtime),
    );
    var after = try readFileAlloc(
        allocator,
        destination_index_path,
        1024 * 1024,
    );
    try std.testing.expectEqualSlices(u8, before, after);
    allocator.free(after);

    runtime.graph_limits = .{};
    runtime.layout_failure_point = .before_index_publish;
    try std.testing.expectError(
        error.LocalWriteFailed,
        copy_cmd.execute(&.{ source_ref, destination_ref }, &runtime),
    );
    after = try readFileAlloc(
        allocator,
        destination_index_path,
        1024 * 1024,
    );
    try std.testing.expectEqualSlices(u8, before, after);
    allocator.free(after);

    runtime.layout_failure_point = .none;
    const layer_digest = try wabt.oci.Digest.parse(package.layer_descriptor.digest);
    const layer_path = layer_digest.blobPath();
    const source_layer_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ source_layout, &layer_path },
    );
    defer allocator.free(source_layer_path);
    const destination_layer_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ destination_layout, &layer_path },
    );
    defer allocator.free(destination_layer_path);
    std.Io.Dir.cwd().deleteFile(
        std.testing.io,
        destination_layer_path,
    ) catch {};
    try writeFile(source_layer_path, "bad!!!!!");
    try std.testing.expectError(
        error.Corruption,
        copy_cmd.execute(&.{ source_ref, destination_ref }, &runtime),
    );
    after = try readFileAlloc(
        allocator,
        destination_index_path,
        1024 * 1024,
    );
    try std.testing.expectEqualSlices(u8, before, after);
    allocator.free(after);

    try writeFile(source_layer_path, payload);
    const subject_manifest = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"artifactType\":\"application/wasm\",\"subject\":{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}},\"config\":{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{
            wabt.oci.model.media_type_oci_manifest,
            package.config_descriptor.mediaType,
            package.config_descriptor.digest,
            package.config_descriptor.size,
            package.config_descriptor.mediaType,
            package.config_descriptor.digest,
            package.config_descriptor.size,
            package.layer_descriptor.mediaType,
            package.layer_descriptor.digest,
            package.layer_descriptor.size,
        },
    );
    defer allocator.free(subject_manifest);
    var subject_root = try TestDescriptor.init(
        wabt.oci.model.media_type_oci_manifest,
        subject_manifest,
    );
    try writeLayoutBlob(
        allocator,
        source_layout,
        &subject_root,
        subject_manifest,
    );
    try writeLayoutIndex(
        allocator,
        source_layout,
        subject_root.value(),
        "subject",
    );
    const subject_ref = try layoutReferenceAlloc(
        allocator,
        source_layout,
        "subject",
    );
    defer allocator.free(subject_ref);
    try std.testing.expectError(
        error.UnsupportedContent,
        copy_cmd.execute(&.{ subject_ref, destination_ref }, &runtime),
    );
    after = try readFileAlloc(
        allocator,
        destination_index_path,
        1024 * 1024,
    );
    defer allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
}
