const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci push REF FILE [options]\n" ++
    "\n" ++
    "Validate a tagged registry destination and a Wasm input filename.\n" ++
    "Execution is not implemented in this command-shell increment.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --format wasm-v0|oci             Artifact profile (default: wasm-v0)\n" ++
    "  --created RFC3339                 Reproducible creation timestamp\n" ++
    "  --author TEXT                     Artifact author metadata\n" ++
    "  --json                            Select the future versioned JSON result\n" ++
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

pub const Error = options.Error || wabt.oci.reference.Error || error{
    MissingReference,
    MissingFile,
    UnexpectedArgument,
    DestinationMustBeRegistry,
    DestinationTagRequired,
    InvalidFormat,
    CommandNotImplemented,
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
    _ = runtime;
    _ = try parseArgs(args);
    return error.CommandNotImplemented;
}

const digest =
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
        "--author",
        "WABT",
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
        parseArgs(&.{ "registry.example/team/app@" ++ digest, "app.wasm" }),
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
}
