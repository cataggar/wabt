//! Injectable side-effect boundary for OCI commands.

const std = @import("std");
const wabt = @import("wabt");
const options_mod = @import("oci_options.zig");

pub const default_deadline_ns: u64 = 5 * std.time.ns_per_min;
pub const max_secret_bytes: usize = 64 * 1024;

pub const Counters = struct {
    network_clients: usize = 0,
    credential_discoveries: usize = 0,
    helper_runs: usize = 0,
    stdin_reads: usize = 0,

    pub fn isZero(self: Counters) bool {
        return self.network_clients == 0 and
            self.credential_discoveries == 0 and
            self.helper_runs == 0 and
            self.stdin_reads == 0;
    }
};

pub const OutputSink = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn init(pointer: anytype) OutputSink {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.writeAll(bytes);
            }
        };
        return .{ .context = pointer, .write_fn = Adapter.write };
    }

    pub fn fromWriter(writer: *std.Io.Writer) OutputSink {
        return init(writer);
    }

    pub fn write(self: OutputSink, bytes: []const u8) !void {
        return self.write_fn(self.context, bytes);
    }
};

pub const SecretProvider = struct {
    context: *anyopaque,
    read_fn: *const fn (
        *anyopaque,
        std.mem.Allocator,
        std.Io,
        usize,
    ) anyerror![]u8,

    pub fn init(pointer: anytype) SecretProvider {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn read(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                io: std.Io,
                limit: usize,
            ) anyerror![]u8 {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.readSecret(allocator, io, limit);
            }
        };
        return .{ .context = pointer, .read_fn = Adapter.read };
    }

    pub fn read(
        self: SecretProvider,
        allocator: std.mem.Allocator,
        io: std.Io,
        limit: usize,
    ) ![]u8 {
        return self.read_fn(self.context, allocator, io, limit);
    }
};

pub const RegistryFactory = struct {
    context: ?*anyopaque = null,
    create_fn: *const fn (
        ?*anyopaque,
        std.Io,
        std.mem.Allocator,
        wabt.oci.RegistryReference,
        wabt.oci.RegistryOptions,
    ) anyerror!wabt.oci.RegistrySource = createProductionSource,

    pub fn create(
        self: RegistryFactory,
        io: std.Io,
        allocator: std.mem.Allocator,
        reference: wabt.oci.RegistryReference,
        source_options: wabt.oci.RegistryOptions,
    ) !wabt.oci.RegistrySource {
        return self.create_fn(
            self.context,
            io,
            allocator,
            reference,
            source_options,
        );
    }
};

pub const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) i128,

    pub fn init(pointer: anytype) Clock {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn now(context: *anyopaque) i128 {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.now();
            }
        };
        return .{ .context = pointer, .now_fn = Adapter.now };
    }

    pub fn now(self: Clock) i128 {
        return self.now_fn(self.context);
    }
};

const OwnedSecret = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    value_len: usize,

    fn value(self: OwnedSecret) []const u8 {
        return self.bytes[0..self.value_len];
    }

    fn deinit(self: *OwnedSecret) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
    counters: *Counters,
    stdout: ?OutputSink = null,
    stderr: ?OutputSink = null,
    secret_provider: ?SecretProvider = null,
    registry_factory: RegistryFactory = .{},
    clock: ?Clock = null,

    pub fn initProcess(
        init: std.process.Init,
        counters: *Counters,
    ) Runtime {
        return .{
            .allocator = init.gpa,
            .io = init.io,
            .environment = init.environ_map,
            .counters = counters,
        };
    }

    pub fn initForTest(
        allocator: std.mem.Allocator,
        io: std.Io,
        counters: *Counters,
    ) Runtime {
        return .{
            .allocator = allocator,
            .io = io,
            .environment = null,
            .counters = counters,
        };
    }

    pub fn writeStdout(self: *Runtime, bytes: []const u8) !void {
        if (self.stdout) |sink| return sink.write(bytes);
        var file = std.Io.File.stdout();
        return file.writeStreamingAll(self.io, bytes);
    }

    pub fn writeStderr(self: *Runtime, bytes: []const u8) !void {
        if (self.stderr) |sink| return sink.write(bytes);
        var file = std.Io.File.stderr();
        return file.writeStreamingAll(self.io, bytes);
    }

    pub fn nowNs(self: *Runtime) i128 {
        if (self.clock) |clock| return clock.now();
        return std.Io.Clock.awake.now(self.io).toNanoseconds();
    }

    /// Reads any required caller/stdin secret, resolves the absolute deadline
    /// once, and only then constructs the registry source.
    pub fn openRegistrySource(
        self: *Runtime,
        reference: wabt.oci.RegistryReference,
        endpoint: options_mod.EndpointOptions,
    ) !wabt.oci.RegistrySource {
        const now_ns = self.nowNs();
        const deadline_ns = if (endpoint.deadline) |deadline|
            try deadline.absoluteNs(now_ns)
        else
            std.math.add(
                i128,
                now_ns,
                @as(i128, default_deadline_ns),
            ) catch return error.DeadlineOverflow;

        var owned_secret: ?OwnedSecret = null;
        defer if (owned_secret) |*secret| secret.deinit();

        const credential_policy: wabt.oci.CredentialPolicy = switch (endpoint.credentials) {
            .discover => blk: {
                self.counters.credential_discoveries += 1;
                break :blk .discover;
            },
            .none => .none,
            .auth_file => |path| .{ .auth_file = path },
            .basic => |basic| .{ .supplied = .{ .basic = .{
                .username = basic.username,
                .secret = switch (basic.secret) {
                    .caller => |value| value,
                    .stdin => blk: {
                        owned_secret = try self.readSecret();
                        break :blk owned_secret.?.value();
                    },
                },
            } } },
            .bearer => |secret| .{ .supplied = .{
                .bearer_token = switch (secret) {
                    .caller => |value| value,
                    .stdin => blk: {
                        owned_secret = try self.readSecret();
                        break :blk owned_secret.?.value();
                    },
                },
            } },
        };

        const tracked_files: wabt.oci.auth.FileReader = .{
            .context = self,
            .read = trackedFileRead,
        };
        const tracked_process: wabt.oci.auth.ProcessRunner = .{
            .context = self,
            .run = trackedProcessRun,
        };
        const source_options: wabt.oci.RegistryOptions = .{
            .plain_http = endpoint.plain_http,
            .additional_ca = if (endpoint.additional_ca_file) |path|
                .{ .file_path = path }
            else
                null,
            .credential_policy = credential_policy,
            .auth_context = .{
                .io = self.io,
                .environment = self.environment,
                .files = tracked_files,
                .process = tracked_process,
            },
            .deadline = .{ .at_ns = deadline_ns },
        };

        self.counters.network_clients += 1;
        return self.registry_factory.create(
            self.io,
            self.allocator,
            reference,
            source_options,
        );
    }

    fn readSecret(self: *Runtime) !OwnedSecret {
        self.counters.stdin_reads += 1;
        const bytes = if (self.secret_provider) |provider|
            provider.read(
                self.allocator,
                self.io,
                max_secret_bytes + 2,
            ) catch return error.SecretReadFailed
        else
            readSecretFromStdin(
                self.allocator,
                self.io,
                max_secret_bytes,
            ) catch |err| return err;
        errdefer {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        }
        if (bytes.len > max_secret_bytes + 2) return error.SecretTooLarge;

        var value_len = bytes.len;
        if (value_len != 0 and bytes[value_len - 1] == '\n') value_len -= 1;
        if (value_len != 0 and bytes[value_len - 1] == '\r') value_len -= 1;
        if (value_len == 0) return error.EmptySecret;
        if (value_len > max_secret_bytes) return error.SecretTooLarge;
        if (std.mem.indexOfAny(u8, bytes[0..value_len], "\r\n\x00") != null) {
            return error.SecretReadFailed;
        }
        return .{
            .allocator = self.allocator,
            .bytes = bytes,
            .value_len = value_len,
        };
    }
};

fn createProductionSource(
    _: ?*anyopaque,
    io: std.Io,
    allocator: std.mem.Allocator,
    reference: wabt.oci.RegistryReference,
    source_options: wabt.oci.RegistryOptions,
) !wabt.oci.RegistrySource {
    return wabt.oci.RegistrySource.init(
        io,
        allocator,
        reference,
        source_options,
    );
}

fn readSecretFromStdin(
    allocator: std.mem.Allocator,
    io: std.Io,
    limit: usize,
) ![]u8 {
    var buffer: [max_secret_bytes + 2]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.SecretTooLarge,
        error.ReadFailed => return error.SecretReadFailed,
    } orelse return error.EmptySecret;
    if (line.len > limit + 2) return error.SecretTooLarge;
    return allocator.dupe(u8, line);
}

fn trackedFileRead(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    limit: usize,
) wabt.oci.auth.FileReadError![]u8 {
    _ = context;
    const default_reader: wabt.oci.auth.FileReader = .{};
    return default_reader.read(
        default_reader.context,
        allocator,
        io,
        path,
        limit,
    );
}

fn trackedProcessRun(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdin_data: []const u8,
    max_output: usize,
    timeout_ns: u64,
) wabt.oci.auth.ProcessError!wabt.oci.auth.ProcessResult {
    const self: *Runtime = @ptrCast(@alignCast(context.?));
    self.counters.helper_runs += 1;
    const default_runner: wabt.oci.auth.ProcessRunner = .{};
    return default_runner.run(
        default_runner.context,
        allocator,
        io,
        argv,
        stdin_data,
        max_output,
        timeout_ns,
    );
}

test "layout-only runtime stays completely idle" {
    var counters: Counters = .{};
    _ = Runtime.initForTest(std.testing.allocator, std.testing.io, &counters);
    try std.testing.expect(counters.isZero());
}

test "caller-owned secrets avoid stdin and are not retained by runtime" {
    const CallerFactory = struct {
        saw_secret: bool = false,

        fn create(
            context: ?*anyopaque,
            _: std.Io,
            _: std.mem.Allocator,
            _: wabt.oci.RegistryReference,
            source_options: wabt.oci.RegistryOptions,
        ) !wabt.oci.RegistrySource {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.saw_secret = switch (source_options.credential_policy) {
                .supplied => |credential| switch (credential) {
                    .bearer_token => |token| std.mem.eql(u8, token, "caller-token"),
                    else => false,
                },
                else => false,
            };
            return error.InjectedFactoryStop;
        }
    };

    var factory: CallerFactory = .{};
    var counters: Counters = .{};
    var runtime = Runtime.initForTest(
        std.testing.allocator,
        std.testing.io,
        &counters,
    );
    runtime.registry_factory = .{
        .context = &factory,
        .create_fn = CallerFactory.create,
    };
    const parsed = try wabt.oci.parseReference(
        "registry.example/team/app:tag",
        .source,
    );
    try std.testing.expectError(
        error.InjectedFactoryStop,
        runtime.openRegistrySource(parsed.registry, .{
            .credentials = .{ .bearer = .{ .caller = "caller-token" } },
        }),
    );
    try std.testing.expect(factory.saw_secret);
    try std.testing.expectEqual(@as(usize, 0), counters.stdin_reads);
    try std.testing.expectEqual(@as(usize, 1), counters.network_clients);
}
