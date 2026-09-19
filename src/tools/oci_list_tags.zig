const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const output = @import("oci_output.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci list-tags REGISTRY/REPOSITORY [options]\n" ++
    "\n" ++
    "List all tags from one registry repository using bounded pagination.\n" ++
    "Output is stable versioned JSON with deterministic tag ordering.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Emit versioned JSON (default)\n" ++
    options.endpoint_help;

pub const Options = struct {
    repository_text: []const u8,
    repository: wabt.oci.RegistryReference,
    json: bool = true,
    endpoint: options.EndpointOptions,
};

pub const Error = options.Error || wabt.oci.reference.Error ||
    output.ExecutionError || error{
    MissingRepository,
    UnexpectedArgument,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var endpoint_builder: options.EndpointBuilder = .{};
    var repository_text: ?[]const u8 = null;
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
        } else if (repository_text == null) {
            repository_text = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }

    const requested = repository_text orelse return error.MissingRepository;
    const parsed = try wabt.oci.parseReference(requested, .list_tags);
    return .{
        .repository_text = requested,
        .repository = parsed.registry,
        .endpoint = (try endpoint_builder.finish(parsed)).?,
    };
}

pub fn execute(
    args: []const []const u8,
    runtime: *runtime_mod.Runtime,
) Error!void {
    const parsed = try parseArgs(args);
    var source = runtime.openRegistrySource(
        parsed.repository,
        parsed.endpoint,
    ) catch |err| return output.mapExecutionError(err);
    defer source.deinit();
    var result = source.listTags(parsed.repository) catch |err|
        return output.mapExecutionError(err);
    defer result.deinit();

    const repository = std.fmt.allocPrint(
        runtime.allocator,
        "{s}/{s}",
        .{ parsed.repository.authority, parsed.repository.repository },
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(repository);
    const tags = runtime.allocator.alloc(
        []const u8,
        result.tags.len,
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(tags);
    for (result.tags, 0..) |tag, index| tags[index] = tag;

    try output.writeJson(runtime, output.ListTagsV1{
        .repository = repository,
        .tags = tags,
    });
}

test "list-tags parses only selector-less registry repositories" {
    const parsed = try parseArgs(&.{
        "registry.example/team/app",
        "--json",
        "--ca-file",
        "ca.pem",
    });
    try std.testing.expect(parsed.json);
    try std.testing.expect(parsed.repository.selection == null);
    try std.testing.expectEqualStrings(
        "ca.pem",
        parsed.endpoint.additional_ca_file.?,
    );
}

test "list-tags rejects selectors layouts duplicates and extras" {
    try std.testing.expectError(
        error.UnexpectedSelection,
        parseArgs(&.{"registry.example/team/app:tag"}),
    );
    try std.testing.expectError(
        error.InvalidReference,
        parseArgs(&.{"oci:layout"}),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "registry.example/team/app", "--json", "--json" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app", "extra" }),
    );
}
