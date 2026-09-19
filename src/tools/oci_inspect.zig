const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci inspect REF [options]\n" ++
    "\n" ++
    "Validate a selected registry reference for future descriptor inspection.\n" ++
    "JSON is the future default output; execution is not implemented yet.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Select versioned JSON (default)\n" ++
    options.endpoint_help;

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.RegistryReference,
    json: bool = true,
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
    var json_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try endpoint_builder.consume(args, &index, .single)) continue;
        if (std.mem.eql(u8, arg, "--json")) {
            try options.markOnce(&json_seen);
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

test "inspect parses selected registry references and explicit JSON" {
    const parsed = try parseArgs(&.{
        "registry.example/team/app:tag",
        "--json",
        "--auth-file",
        "auth.json",
    });
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.endpoint.credentials == .auth_file);
}

test "inspect rejects layouts missing selectors duplicates and extras" {
    try std.testing.expectError(error.MissingSelection, parseArgs(&.{"registry.example/team/app"}));
    try std.testing.expectError(error.SourceMustBeRegistry, parseArgs(&.{"oci:layout:tag"}));
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "registry.example/team/app:tag", "--json", "--json" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app:tag", "extra" }),
    );
}
