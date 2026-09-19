const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci copy SOURCE DESTINATION [options]\n" ++
    "\n" ++
    "Validate registry and/or oci: layout references for a complete graph copy.\n" ++
    "Execution is not implemented in this command-shell increment.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Select the future versioned JSON result\n" ++
    options.copy_endpoint_help;

pub const Options = struct {
    source_text: []const u8,
    source: wabt.oci.Reference,
    destination_text: []const u8,
    destination: wabt.oci.Reference,
    source_endpoint: ?options.EndpointOptions,
    destination_endpoint: ?options.EndpointOptions,
    json: bool = false,

    pub fn stdinRequests(self: Options) StdinRequests {
        var result: StdinRequests = .{ .values = undefined, .len = 0 };
        options.appendStdinRequests(
            self.source_endpoint,
            .source,
            &result.values,
            &result.len,
        );
        options.appendStdinRequests(
            self.destination_endpoint,
            .destination,
            &result.values,
            &result.len,
        );
        return result;
    }
};

pub const StdinRequests = struct {
    values: [2]options.SecretRequest,
    len: usize,
};

pub const Error = options.Error || wabt.oci.reference.Error || error{
    MissingSource,
    MissingDestination,
    UnexpectedArgument,
    CommandNotImplemented,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var source_builder: options.EndpointBuilder = .{};
    var destination_builder: options.EndpointBuilder = .{};
    var positionals: [2]?[]const u8 = .{ null, null };
    var positional_count: usize = 0;
    var json = false;
    var json_seen = false;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (try source_builder.consume(args, &index, .source)) continue;
        if (try destination_builder.consume(args, &index, .destination)) continue;
        if (std.mem.eql(u8, arg, "--json")) {
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

    if (positional_count == 0) return error.MissingSource;
    if (positional_count == 1) return error.MissingDestination;

    const source = try wabt.oci.parseReference(positionals[0].?, .source);
    const destination = try wabt.oci.parseReference(positionals[1].?, .destination);
    return .{
        .source_text = positionals[0].?,
        .source = source,
        .destination_text = positionals[1].?,
        .destination = destination,
        .source_endpoint = try source_builder.finish(source),
        .destination_endpoint = try destination_builder.finish(destination),
        .json = json,
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

test "copy parses every endpoint pairing and keeps endpoint options separate" {
    const cases = [_][2][]const u8{
        .{ "registry.example/team/source:tag", "registry.example/team/dest:tag" },
        .{ "registry.example/team/source:tag", "oci:layout:dest" },
        .{ "oci:layout:source", "registry.example/team/dest:tag" },
        .{ "oci:source-layout", "oci:destination-layout" },
    };
    for (cases) |case| {
        _ = try parseArgs(&.{ case[0], case[1] });
    }

    const separated = try parseArgs(&.{
        "localhost:5000/team/source:tag",
        "localhost:6000/team/dest:tag",
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
    });
    try std.testing.expect(separated.source_endpoint.?.credentials == .basic);
    try std.testing.expect(separated.destination_endpoint.?.credentials == .bearer);
    try std.testing.expectEqualStrings(
        "source-ca.pem",
        separated.source_endpoint.?.additional_ca_file.?,
    );
    try std.testing.expectEqualStrings(
        "destination-ca.pem",
        separated.destination_endpoint.?.additional_ca_file.?,
    );
    const requests = separated.stdinRequests();
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqual(options.EndpointRole.source, requests.values[0].role);
    try std.testing.expectEqual(options.SecretKind.password, requests.values[0].kind);
    try std.testing.expectEqual(options.EndpointRole.destination, requests.values[1].role);
    try std.testing.expectEqual(options.SecretKind.token, requests.values[1].kind);
}

test "copy rejects registry options on layouts and unprefixed endpoint options" {
    try std.testing.expectError(
        error.RegistryOptionForLayout,
        parseArgs(&.{
            "oci:source-layout",
            "oci:destination-layout",
            "--source-auth-file",
            "auth.json",
        }),
    );
    try std.testing.expectError(
        error.UnknownOption,
        parseArgs(&.{
            "registry.example/team/source:tag",
            "registry.example/team/dest:tag",
            "--auth-file",
            "auth.json",
        }),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{
            "registry.example/team/source:tag",
            "registry.example/team/dest:tag",
            "--source-deadline",
            "1s",
            "--source-deadline",
            "2s",
        }),
    );
    try std.testing.expectError(
        error.MissingSelection,
        parseArgs(&.{
            "registry.example/team/source",
            "registry.example/team/dest:tag",
        }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "oci:a", "oci:b", "extra" }),
    );
}
