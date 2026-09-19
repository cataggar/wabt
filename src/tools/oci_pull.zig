const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci pull REF -o FILE [options]\n" ++
    "\n" ++
    "Validate a selected registry source and one output filename.\n" ++
    "Existing output refusal is the default; --force is an explicit opt-in.\n" ++
    "Execution and extraction are not implemented in this increment.\n" ++
    "\n" ++
    "Options:\n" ++
    "  -o, --output FILE                 One output filename (required)\n" ++
    "  --force                           Permit future atomic replacement\n" ++
    "  --json                            Select the future versioned JSON result\n" ++
    options.endpoint_help;

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.RegistryReference,
    output_file: []const u8,
    force: bool = false,
    json: bool = false,
    endpoint: options.EndpointOptions,
};

pub const Error = options.Error || wabt.oci.reference.Error || error{
    MissingReference,
    MissingOutput,
    UnexpectedArgument,
    SourceMustBeRegistry,
    CommandNotImplemented,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var endpoint_builder: options.EndpointBuilder = .{};
    var reference_text: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var force = false;
    var json = false;
    var output_seen = false;
    var force_seen = false;
    var json_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try endpoint_builder.consume(args, &index, .single)) continue;
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            try options.markOnce(&output_seen);
            output_file = try options.takeValue(args, &index);
            try options.validateOutputFile(output_file.?);
        } else if (std.mem.eql(u8, arg, "--force")) {
            try options.markOnce(&force_seen);
            force = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            try options.markOnce(&json_seen);
            json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return if (options.isPlaintextSecretOption(arg))
                error.PlaintextSecretOption
            else
                error.UnknownOption;
        } else if (reference_text == null) {
            reference_text = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }

    const requested = reference_text orelse return error.MissingReference;
    const output = output_file orelse return error.MissingOutput;
    const parsed = try wabt.oci.parseReference(requested, .source);
    const registry = switch (parsed) {
        .registry => |value| value,
        .layout => return error.SourceMustBeRegistry,
    };

    return .{
        .reference_text = requested,
        .reference = registry,
        .output_file = output,
        .force = force,
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

test "pull parses tag or digest and exactly one output filename" {
    const tagged = try parseArgs(&.{ "registry.example/team/app:tag", "-o", "app.wasm" });
    try std.testing.expectEqualStrings("app.wasm", tagged.output_file);
    try std.testing.expect(!tagged.force);

    const immutable = try parseArgs(&.{
        "registry.example/team/app@" ++ digest,
        "--output",
        "out/app.wasm",
        "--force",
        "--json",
        "--no-credential-discovery",
    });
    try std.testing.expect(immutable.reference.selection.? == .digest);
    try std.testing.expect(immutable.force);
    try std.testing.expect(immutable.json);
    try std.testing.expect(immutable.endpoint.credentials == .none);
}

test "pull rejects missing duplicate directory-like and extra outputs" {
    try std.testing.expectError(
        error.MissingSelection,
        parseArgs(&.{ "registry.example/team/app", "-o", "app.wasm" }),
    );
    try std.testing.expectError(
        error.SourceMustBeRegistry,
        parseArgs(&.{ "oci:layout:tag", "-o", "app.wasm" }),
    );
    try std.testing.expectError(
        error.MissingOutput,
        parseArgs(&.{"registry.example/team/app:tag"}),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "registry.example/team/app:tag", "-o", "a", "--output", "b" }),
    );
    try std.testing.expectError(
        error.InvalidOutputFile,
        parseArgs(&.{ "registry.example/team/app:tag", "-o", "out/" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app:tag", "-o", "app.wasm", "extra" }),
    );
}
