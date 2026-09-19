const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const output = @import("oci_output.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci push REF FILE [options]\n" ++
    "\n" ++
    "Publish one validated core Wasm module or component to a registry tag.\n" ++
    "The default wasm-v0 profile is wkg-compatible. The explicit oci profile\n" ++
    "uses the generic OCI 1.1/ORAS shape and is not wkg-compatible.\n" ++
    "Without --created, the current UTC second is embedded; --json reports it.\n" ++
    "Use --created for reproducible digests.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --format wasm-v0|oci             Artifact profile (default: wasm-v0)\n" ++
    "  --created RFC3339                 Reproducible creation timestamp\n" ++
    "  --author TEXT                     Wasm-v0 author metadata\n" ++
    "  --json                            Emit the versioned JSON result\n" ++
    options.endpoint_help;

pub const Format = enum {
    wasm_v0,
    oci,
};

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.RegistryReference,
    file: []const u8,
    format: Format = .wasm_v0,
    created: ?[]const u8 = null,
    author: ?[]const u8 = null,
    json: bool = false,
    endpoint: options.EndpointOptions,
};

pub const Error = options.Error || wabt.oci.reference.Error ||
    output.ExecutionError || error{
    MissingReference,
    MissingFile,
    UnexpectedArgument,
    DestinationMustBeRegistry,
    DestinationTagRequired,
    InvalidFormat,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var endpoint_builder: options.EndpointBuilder = .{};
    var positionals: [2]?[]const u8 = .{ null, null };
    var positional_count: usize = 0;
    var format: Format = .wasm_v0;
    var created: ?[]const u8 = null;
    var author: ?[]const u8 = null;
    var json = false;
    var format_seen = false;
    var created_seen = false;
    var author_seen = false;
    var json_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try endpoint_builder.consume(args, &index, .single)) continue;
        if (std.mem.eql(u8, arg, "--format")) {
            try options.markOnce(&format_seen);
            const value = try options.takeValue(args, &index);
            format = if (std.mem.eql(u8, value, "wasm-v0"))
                .wasm_v0
            else if (std.mem.eql(u8, value, "oci"))
                .oci
            else
                return error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--created")) {
            try options.markOnce(&created_seen);
            created = try options.takeValue(args, &index);
            try options.validateRfc3339(created.?);
        } else if (std.mem.eql(u8, arg, "--author")) {
            try options.markOnce(&author_seen);
            author = try options.takeValue(args, &index);
            if (author.?.len > wabt.oci.wasm.max_author_bytes or
                !std.unicode.utf8ValidateSlice(author.?))
            {
                return error.InvalidOptionValue;
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            try options.markOnce(&json_seen);
            json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return if (options.isPlaintextSecretOption(arg))
                error.PlaintextSecretOption
            else
                error.UnknownOption;
        } else {
            if (positional_count == positionals.len) return error.UnexpectedArgument;
            positionals[positional_count] = arg;
            positional_count += 1;
        }
    }

    if (positional_count == 0) return error.MissingReference;
    if (positional_count == 1) return error.MissingFile;

    const parsed = try wabt.oci.parseReference(positionals[0].?, .destination);
    const registry = switch (parsed) {
        .registry => |value| value,
        .layout => return error.DestinationMustBeRegistry,
    };
    const selection = registry.selection orelse return error.DestinationTagRequired;
    if (selection != .tag) return error.DestinationTagRequired;
    try options.validateFile(positionals[1].?);
    if (format == .oci and author != null) {
        return error.InvalidProfile;
    }

    return .{
        .reference_text = positionals[0].?,
        .reference = registry,
        .file = positionals[1].?,
        .format = format,
        .created = created,
        .author = author,
        .json = json,
        .endpoint = (try endpoint_builder.finish(parsed)).?,
    };
}

pub fn execute(
    args: []const []const u8,
    runtime: *runtime_mod.Runtime,
) Error!void {
    const parsed = try parseArgs(args);
    const payload = readPayload(runtime, parsed.file) catch |err|
        return output.mapLocalReadError(err);
    defer runtime.allocator.free(payload);

    var owned_created: ?[]u8 = null;
    defer if (owned_created) |value| runtime.allocator.free(value);
    const created = if (parsed.created) |value|
        value
    else blk: {
        owned_created = currentCreatedAlloc(runtime) catch |err|
            return output.mapPushError(err);
        break :blk owned_created.?;
    };
    const created_source = if (parsed.created == null)
        "current-time"
    else
        "explicit";

    var package = wabt.oci.prepareWasmArtifact(
        runtime.allocator,
        payload,
        .{
            .profile = switch (parsed.format) {
                .wasm_v0 => .wasm_v0,
                .oci => .oci,
            },
            .created = created,
            .author = parsed.author,
            .source_name = parsed.file,
        },
    ) catch |err| return output.mapPushError(err);
    defer package.deinit();

    const immutable = immutableRegistryReferenceAlloc(
        runtime.allocator,
        parsed.reference,
        package.root_descriptor.digest,
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(immutable);

    const start = std.fmt.allocPrint(
        runtime.allocator,
        "pushing {s} created={s} created-source={s}\n",
        .{ parsed.reference_text, created, created_source },
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(start);
    try output.writeProgress(runtime, start);

    var destination = runtime.openRegistryDestination(
        parsed.reference,
        parsed.endpoint,
    ) catch |err| return output.mapPushError(err);
    defer destination.deinit();
    var source = wabt.oci.PackageSource.init(runtime.io, &package);
    const result = wabt.oci.copySourceToDestination(
        runtime.allocator,
        source.asTransport(),
        source.root(),
        destination.asTransport(),
        parsed.reference.selection,
        runtime.graph_limits,
    ) catch |err| return output.mapPushError(err);

    const completed = std.fmt.allocPrint(
        runtime.allocator,
        "committed {s}\n",
        .{immutable},
    ) catch return error.CommittedButReportingFailed;
    defer runtime.allocator.free(completed);
    output.writeProgress(runtime, completed) catch
        return error.CommittedButReportingFailed;

    emit(
        runtime,
        parsed,
        immutable,
        created,
        created_source,
        package,
        result,
    ) catch return error.CommittedButReportingFailed;
}

fn readPayload(
    runtime: *runtime_mod.Runtime,
    path: []const u8,
) ![]u8 {
    var file = std.Io.Dir.cwd().openFile(runtime.io, path, .{}) catch
        return error.ReadFailed;
    defer file.close(runtime.io);
    const size = file.length(runtime.io) catch return error.ReadFailed;
    if (size > wabt.oci.wasm.max_payload_bytes or
        size > std.math.maxInt(usize))
    {
        return error.PayloadTooLarge;
    }
    const bytes = try runtime.allocator.alloc(u8, @intCast(size));
    errdefer runtime.allocator.free(bytes);
    const read = file.readPositionalAll(runtime.io, bytes, 0) catch
        return error.ReadFailed;
    if (read != bytes.len) {
        return error.UnexpectedEndOfFile;
    }
    if ((file.length(runtime.io) catch return error.ReadFailed) != size) {
        return error.InputChanged;
    }
    return bytes;
}

fn currentCreatedAlloc(
    runtime: *runtime_mod.Runtime,
) ![]u8 {
    const seconds = runtime.unixSeconds();
    if (seconds < 0) return error.InvalidCreated;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        runtime.allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn immutableRegistryReferenceAlloc(
    allocator: std.mem.Allocator,
    reference: wabt.oci.RegistryReference,
    digest_text: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}@{s}",
        .{ reference.authority, reference.repository, digest_text },
    );
}

fn emit(
    runtime: *runtime_mod.Runtime,
    parsed: Options,
    immutable: []const u8,
    created: []const u8,
    created_source: []const u8,
    package: wabt.oci.PreparedWasmArtifact,
    result: wabt.oci.TransferResult,
) output.ExecutionError!void {
    _ = result;
    if (parsed.json) {
        return output.writeJson(runtime, output.PushV1{
            .originalReference = parsed.reference_text,
            .reference = immutable,
            .profile = switch (parsed.format) {
                .wasm_v0 => "wasm-v0",
                .oci => "oci-1.1",
            },
            .created = created,
            .createdSource = created_source,
            .root = output.descriptor(package.root_descriptor),
            .manifest = output.descriptor(package.root_descriptor),
            .config = output.descriptor(package.config_descriptor),
            .payload = output.descriptor(package.layer_descriptor),
        });
    }
    const line = std.fmt.allocPrint(runtime.allocator, "{s}\n", .{immutable}) catch
        return error.OutOfMemory;
    defer runtime.allocator.free(line);
    return output.writeText(runtime, line);
}

const sample_digest =
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "push parses tagged destinations formats and endpoint policy" {
    const defaults = try parseArgs(&.{ "registry.example/team/app:stable", "app.wasm" });
    try std.testing.expectEqual(Format.wasm_v0, defaults.format);
    try std.testing.expect(!defaults.json);
    try std.testing.expect(defaults.reference.selection.? == .tag);

    const full = try parseArgs(&.{
        "localhost:5000/team/app:next",
        "app.wasm",
        "--format",
        "oci",
        "--created",
        "2026-09-19T12:16:26Z",
        "--json",
        "--username",
        "alice",
        "--password-stdin",
        "--ca-file",
        "registry-ca.pem",
        "--deadline",
        "30s",
        "--plain-http",
    });
    try std.testing.expectEqual(Format.oci, full.format);
    try std.testing.expect(full.json);
    try std.testing.expect(full.endpoint.credentials == .basic);
    try std.testing.expect(full.endpoint.plain_http);
}

test "push rejects non-tags duplicates unknowns and extra positionals" {
    try std.testing.expectError(
        error.DestinationTagRequired,
        parseArgs(&.{ "registry.example/team/app@" ++ sample_digest, "app.wasm" }),
    );
    try std.testing.expectError(
        error.DestinationMustBeRegistry,
        parseArgs(&.{ "oci:layout:tag", "app.wasm" }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "registry.example/team/app:tag", "app.wasm", "--json", "--json" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app:tag", "app.wasm", "extra" }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        parseArgs(&.{ "registry.example/team/app:tag", "app.wasm", "--output", "x" }),
    );
    try std.testing.expectError(
        error.InvalidFormat,
        parseArgs(&.{ "registry.example/team/app:tag", "app.wasm", "--format", "wasm" }),
    );
    try std.testing.expectError(
        error.InvalidProfile,
        parseArgs(&.{
            "registry.example/team/app:tag",
            "app.wasm",
            "--format",
            "oci",
            "--author",
            "ignored",
        }),
    );
}
