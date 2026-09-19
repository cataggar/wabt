const std = @import("std");
const auth = @import("auth.zig");
const content = @import("content.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");
const registry = @import("registry.zig");
const registry_http = @import("registry_http.zig");

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
        if (!std.mem.endsWith(u8, options.url, step.path_suffix) or
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
}

test "stream retries rewind destination and final corruption removes partial output" {
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
