const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci resolve REF [options]\n" ++
    "\n" ++
    "Validate a selected registry reference for future immutable resolution.\n" ++
    "Execution is not implemented in this command-shell increment.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Select the future versioned JSON result\n" ++
    options.endpoint_help;

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.RegistryReference,
    json: bool = false,
    endpoint: options.EndpointOptions,
};

pub const Error = options.Error || wabt.oci.reference.Error || error{
    MissingReference,
    UnexpectedArgument,
    SourceMustBeRegistry,
    CommandNotImplemented,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var endpoint_builder: options.EndpointBuilder = .{};
    var reference_text: ?[]const u8 = null;
    var json = false;
    var json_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try endpoint_builder.consume(args, &index, .single)) continue;
        if (std.mem.eql(u8, arg, "--json")) {
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
    const parsed = try wabt.oci.parseReference(requested, .source);
    const registry = switch (parsed) {
        .registry => |value| value,
        .layout => return error.SourceMustBeRegistry,
    };
    return .{
        .reference_text = requested,
        .reference = registry,
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

test "resolve parses tags digests JSON and endpoint options" {
    const parsed = try parseArgs(&.{
        "localhost:5000/team/app:tag",
        "--json",
        "--token-stdin",
        "--plain-http",
        "--deadline",
        "1m",
    });
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.endpoint.credentials == .bearer);
    try std.testing.expect(parsed.endpoint.deadline.? == .relative_ns);
}

test "resolve rejects layouts missing selectors plaintext secrets and extras" {
    try std.testing.expectError(error.MissingSelection, parseArgs(&.{"registry.example/team/app"}));
    try std.testing.expectError(error.SourceMustBeRegistry, parseArgs(&.{"oci:layout:tag"}));
    try std.testing.expectError(
        error.PlaintextSecretOption,
        parseArgs(&.{ "registry.example/team/app:tag", "--token", "secret" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app:tag", "extra" }),
    );
}
