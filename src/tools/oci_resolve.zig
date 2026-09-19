const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const output = @import("oci_output.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci resolve REF [options]\n" ++
    "\n" ++
    "Resolve a registry tag/digest or selected/unambiguous OCI layout root.\n" ++
    "The default output is one canonical immutable reference.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Emit the versioned JSON result\n" ++
    options.endpoint_help;

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.Reference,
    json: bool = false,
    endpoint: ?options.EndpointOptions,
};

pub const Error = options.Error || wabt.oci.reference.Error ||
    output.ExecutionError || error{
    MissingReference,
    UnexpectedArgument,
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
    return .{
        .reference_text = requested,
        .reference = parsed,
        .json = json,
        .endpoint = try endpoint_builder.finish(parsed),
    };
}

pub fn execute(
    args: []const []const u8,
    runtime: *runtime_mod.Runtime,
) Error!void {
    const parsed = try parseArgs(args);
    switch (parsed.reference) {
        .registry => |reference| {
            var source = runtime.openRegistrySource(
                reference,
                parsed.endpoint.?,
            ) catch |err| return output.mapExecutionError(err);
            defer source.deinit();
            var resolved = source.resolve(reference) catch |err|
                return output.mapExecutionError(err);
            defer resolved.deinit();
            try emit(
                runtime,
                parsed.reference_text,
                resolved.canonical_reference,
                resolved.descriptor,
                parsed.json,
            );
        },
        .layout => |reference| {
            var source = wabt.oci.LayoutSource.init(
                runtime.io,
                runtime.allocator,
                reference.path,
            );
            var resolved = source.resolve(reference) catch |err|
                return output.mapExecutionError(err);
            defer resolved.deinit();
            const canonical = std.fmt.allocPrint(
                runtime.allocator,
                "oci:{s}@{s}",
                .{ reference.path, resolved.descriptor.digest },
            ) catch return error.OutOfMemory;
            defer runtime.allocator.free(canonical);
            try emit(
                runtime,
                parsed.reference_text,
                canonical,
                resolved.descriptor,
                parsed.json,
            );
        },
    }
}

fn emit(
    runtime: *runtime_mod.Runtime,
    original: []const u8,
    canonical: []const u8,
    descriptor: wabt.oci.Descriptor,
    json: bool,
) output.ExecutionError!void {
    const kind = documentKind(descriptor.mediaType);
    if (json) {
        const is_manifest = std.mem.eql(u8, kind, "manifest");
        return output.writeJson(runtime, output.ResolveV1{
            .originalReference = original,
            .reference = canonical,
            .rootKind = kind,
            .rootMediaType = descriptor.mediaType,
            .rootDigest = descriptor.digest,
            .rootSize = descriptor.size,
            .manifestMediaType = if (is_manifest) descriptor.mediaType else null,
            .manifestDigest = if (is_manifest) descriptor.digest else null,
            .manifestSize = if (is_manifest) descriptor.size else null,
        });
    }
    const line = std.fmt.allocPrint(
        runtime.allocator,
        "{s}\n",
        .{canonical},
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(line);
    return output.writeText(runtime, line);
}

fn documentKind(media_type: []const u8) []const u8 {
    const class = wabt.oci.classifyMediaType(media_type);
    if (class.isManifest()) return "manifest";
    if (class.isIndex()) return "index";
    return "unknown";
}

test "resolve accepts registry and layout sources" {
    const registry = try parseArgs(&.{
        "localhost:5000/team/app:tag",
        "--json",
        "--token-stdin",
        "--plain-http",
        "--deadline",
        "1m",
    });
    try std.testing.expect(registry.reference == .registry);
    try std.testing.expect(registry.json);
    try std.testing.expect(registry.endpoint.?.credentials == .bearer);

    const layout = try parseArgs(&.{"oci:layout"});
    try std.testing.expect(layout.reference == .layout);
    try std.testing.expect(layout.endpoint == null);
}

test "resolve rejects missing selectors plaintext secrets and extras" {
    try std.testing.expectError(
        error.MissingSelection,
        parseArgs(&.{"registry.example/team/app"}),
    );
    try std.testing.expectError(
        error.PlaintextSecretOption,
        parseArgs(&.{ "registry.example/team/app:tag", "--token", "secret" }),
    );
    try std.testing.expectError(
        error.RegistryOptionForLayout,
        parseArgs(&.{ "oci:layout:tag", "--auth-file", "auth.json" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app:tag", "extra" }),
    );
}
