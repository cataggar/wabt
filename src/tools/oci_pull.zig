const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const output = @import("oci_output.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci pull REF -o FILE [options]\n" ++
    "\n" ++
    "Pull one supported direct Wasm artifact from a registry or OCI layout.\n" ++
    "The explicit output is atomically published and is not overwritten unless\n" ++
    "--force is specified. OCI layer titles are never used as paths.\n" ++
    "\n" ++
    "Options:\n" ++
    "  -o, --output FILE                 Output filename (required)\n" ++
    "  --force                           Atomically replace one regular file\n" ++
    "  --json                            Emit the versioned JSON result\n" ++
    options.endpoint_help;

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.Reference,
    output_file: []const u8,
    force: bool = false,
    json: bool = false,
    endpoint: ?options.EndpointOptions,
};

pub const Error = options.Error || wabt.oci.reference.Error ||
    output.ExecutionError || error{
    MissingReference,
    MissingOutput,
    UnexpectedArgument,
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
        if (std.mem.eql(u8, arg, "-o") or
            std.mem.eql(u8, arg, "--output"))
        {
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
    const output_file_value = output_file orelse return error.MissingOutput;
    const parsed = try wabt.oci.parseReference(requested, .source);
    return .{
        .reference_text = requested,
        .reference = parsed,
        .output_file = output_file_value,
        .force = force,
        .json = json,
        .endpoint = try endpoint_builder.finish(parsed),
    };
}

pub fn execute(
    args: []const []const u8,
    runtime: *runtime_mod.Runtime,
) Error!void {
    const parsed = try parseArgs(args);
    const extraction_options: wabt.oci.ExtractionOptions = .{
        .force = parsed.force,
    };
    wabt.oci.preflightExtractionOutput(
        runtime.io,
        parsed.output_file,
        extraction_options,
    ) catch |err| return output.mapLocalWriteError(err);

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
            var immutable_source = source.resolvedSource(&resolved);
            try pullResolved(
                runtime,
                parsed,
                resolved.canonical_reference,
                immutable_source.asTransport(),
                resolved.descriptor,
                resolved.bytes,
                extraction_options,
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
            try pullResolved(
                runtime,
                parsed,
                canonical,
                source.asTransport(),
                resolved.descriptor,
                resolved.bytes,
                extraction_options,
            );
        },
    }
}

fn pullResolved(
    runtime: *runtime_mod.Runtime,
    parsed: Options,
    canonical: []const u8,
    source: wabt.oci.Source,
    root_descriptor: wabt.oci.Descriptor,
    manifest_bytes: []const u8,
    extraction_options: wabt.oci.ExtractionOptions,
) output.ExecutionError!void {
    var document = wabt.oci.parseDocument(
        runtime.allocator,
        manifest_bytes,
    ) catch |err| return output.mapExecutionError(err);
    defer document.deinit();
    const manifest = switch (document.value) {
        .index => return error.UnsupportedContent,
        .manifest => |manifest| manifest.value,
    };

    const result = wabt.oci.extractResolvedSource(
        runtime.io,
        runtime.allocator,
        source,
        root_descriptor,
        manifest_bytes,
        parsed.output_file,
        extraction_options,
    ) catch |err| return output.mapLocalWriteError(err);
    if (manifest.layers.len != 1) return error.UnsupportedContent;
    const payload = manifest.layers[0];

    if (parsed.json) {
        return output.writeJson(runtime, output.PullV1{
            .originalReference = parsed.reference_text,
            .reference = canonical,
            .root = output.descriptor(root_descriptor),
            .manifest = output.descriptor(root_descriptor),
            .config = output.descriptor(manifest.config),
            .payload = output.descriptor(payload),
            .profile = output.profileText(result.profile),
            .output = parsed.output_file,
            .size = result.bytes_written,
        });
    }

    const line = std.fmt.allocPrint(
        runtime.allocator,
        "pulled {s} to {s}\n",
        .{ payload.digest, parsed.output_file },
    ) catch return error.OutOfMemory;
    defer runtime.allocator.free(line);
    return output.writeText(runtime, line);
}

const digest =
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

test "pull parses registry or layout and exactly one output filename" {
    const tagged = try parseArgs(&.{
        "registry.example/team/app:tag",
        "-o",
        "app.wasm",
    });
    try std.testing.expect(tagged.reference == .registry);
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
    try std.testing.expect(immutable.force);
    try std.testing.expect(immutable.json);
    try std.testing.expect(immutable.endpoint.?.credentials == .none);

    const layout = try parseArgs(&.{ "oci:layout", "-o", "app.wasm" });
    try std.testing.expect(layout.reference == .layout);
    try std.testing.expect(layout.endpoint == null);
}

test "pull rejects missing duplicate directory-like and extra outputs" {
    try std.testing.expectError(
        error.MissingSelection,
        parseArgs(&.{ "registry.example/team/app", "-o", "app.wasm" }),
    );
    try std.testing.expectError(
        error.MissingOutput,
        parseArgs(&.{"registry.example/team/app:tag"}),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{
            "registry.example/team/app:tag", "-o", "a", "--output", "b",
        }),
    );
    try std.testing.expectError(
        error.InvalidOutputFile,
        parseArgs(&.{ "registry.example/team/app:tag", "-o", "out/" }),
    );
    try std.testing.expectError(
        error.RegistryOptionForLayout,
        parseArgs(&.{ "oci:layout", "-o", "app.wasm", "--token-stdin" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{
            "registry.example/team/app:tag", "-o", "app.wasm", "extra",
        }),
    );
}
