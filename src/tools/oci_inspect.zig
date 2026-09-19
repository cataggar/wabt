const std = @import("std");
const wabt = @import("wabt");
const options = @import("oci_options.zig");
const output = @import("oci_output.zig");
const runtime_mod = @import("oci_runtime.zig");

pub const usage =
    "Usage: wabt oci inspect REF [options]\n" ++
    "\n" ++
    "Inspect a verified registry or OCI layout graph without extracting it.\n" ++
    "Output is stable versioned JSON.\n" ++
    "\n" ++
    "Options:\n" ++
    "  --json                            Emit versioned JSON (default)\n" ++
    options.endpoint_help;

pub const Options = struct {
    reference_text: []const u8,
    reference: wabt.oci.Reference,
    json: bool = true,
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
    return .{
        .reference_text = requested,
        .reference = parsed,
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
            var immutable_source = source.resolvedSource(&resolved);
            try inspectResolved(
                runtime,
                parsed.reference_text,
                resolved.canonical_reference,
                immutable_source.asTransport(),
                resolved.descriptor,
                resolved.descriptor_json,
                resolved.bytes,
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
            try inspectResolved(
                runtime,
                parsed.reference_text,
                canonical,
                source.asTransport(),
                resolved.descriptor,
                resolved.descriptor_json,
                resolved.bytes,
            );
        },
    }
}

fn inspectResolved(
    runtime: *runtime_mod.Runtime,
    original: []const u8,
    canonical: []const u8,
    source: wabt.oci.Source,
    root_descriptor: wabt.oci.Descriptor,
    root_descriptor_json: ?[]const u8,
    root_bytes: []const u8,
) output.ExecutionError!void {
    var plan = wabt.oci.planGraphInspect(
        runtime.allocator,
        source,
        .{
            .descriptor = root_descriptor,
            .descriptor_json = root_descriptor_json,
        },
        .{},
    ) catch |err| return output.mapExecutionError(err);
    defer plan.deinit();

    const root_node = plan.rootNode();
    const document_kind = @tagName(root_node.kind());
    const artifact_type: ?[]const u8 = switch (root_node.view) {
        .index => |index| index.artifactType,
        .manifest => |manifest| manifest.artifactType,
    };
    const subject = if (root_node.subject) |descriptor_value|
        output.descriptor(descriptor_value)
    else
        null;
    const manifest_descriptor: ?output.DescriptorV1 =
        if (root_node.kind() == .manifest)
            output.descriptor(root_descriptor)
        else
            null;

    var profile: ?[]const u8 = null;
    var config_descriptor: ?output.DescriptorV1 = null;
    var payload_descriptor: ?output.DescriptorV1 = null;
    switch (root_node.view) {
        .index => {},
        .manifest => |manifest| {
            if (isDirectWasmCandidate(manifest)) {
                if (manifest.layers.len != 1 or
                    !std.mem.eql(
                        u8,
                        manifest.layers[0].mediaType,
                        wabt.oci.wasm.media_type_wasm,
                    ))
                {
                    return error.UnsupportedContent;
                }
                var config = source.readVerifiedBlob(
                    runtime.allocator,
                    manifest.config,
                    wabt.oci.wasm.max_config_bytes,
                ) catch |err| return output.mapExecutionError(err);
                defer config.deinit();
                var payload = source.readVerifiedBlob(
                    runtime.allocator,
                    manifest.layers[0],
                    wabt.oci.wasm.max_payload_bytes,
                ) catch |err| return output.mapExecutionError(err);
                defer payload.deinit();
                var extraction = wabt.oci.classifyDirectWasmManifest(
                    runtime.allocator,
                    root_descriptor,
                    root_bytes,
                    config.bytes,
                    payload.bytes,
                ) catch |err| return output.mapExecutionError(err);
                defer extraction.deinit();
                profile = output.profileText(extraction.profile);
                config_descriptor = output.descriptor(manifest.config);
                payload_descriptor = output.descriptor(manifest.layers[0]);
            }
        },
    }

    try output.writeJson(runtime, output.InspectV1{
        .originalReference = original,
        .reference = canonical,
        .root = output.descriptor(root_descriptor),
        .documentKind = document_kind,
        .artifactType = artifact_type,
        .subject = subject,
        .manifest = manifest_descriptor,
        .profile = profile,
        .config = config_descriptor,
        .payload = payload_descriptor,
        .graph = .{
            .documents = @intCast(plan.nodes.len),
            .descriptors = @intCast(plan.entries.len),
            .totalSize = plan.total_bytes,
        },
    });
}

fn isDirectWasmCandidate(manifest: wabt.oci.Manifest) bool {
    if (manifest.artifactType) |artifact_type| {
        if (std.mem.eql(
            u8,
            artifact_type,
            wabt.oci.wasm.artifact_type_wasm,
        )) return true;
    }
    if (std.mem.eql(
        u8,
        manifest.config.mediaType,
        wabt.oci.wasm.media_type_wasm_config,
    ) or std.mem.eql(
        u8,
        manifest.config.mediaType,
        wabt.oci.wasm.media_type_wasm,
    )) return true;
    return manifest.layers.len == 1 and std.mem.eql(
        u8,
        manifest.layers[0].mediaType,
        wabt.oci.wasm.media_type_wasm,
    );
}

test "inspect accepts registry and layout sources with JSON default" {
    const registry = try parseArgs(&.{
        "registry.example/team/app:tag",
        "--json",
        "--auth-file",
        "auth.json",
    });
    try std.testing.expect(registry.reference == .registry);
    try std.testing.expect(registry.json);
    try std.testing.expect(registry.endpoint.?.credentials == .auth_file);

    const layout = try parseArgs(&.{"oci:layout"});
    try std.testing.expect(layout.reference == .layout);
    try std.testing.expect(layout.endpoint == null);
}

test "inspect rejects missing selectors duplicates and layout registry options" {
    try std.testing.expectError(
        error.MissingSelection,
        parseArgs(&.{"registry.example/team/app"}),
    );
    try std.testing.expectError(
        error.DuplicateOption,
        parseArgs(&.{ "registry.example/team/app:tag", "--json", "--json" }),
    );
    try std.testing.expectError(
        error.RegistryOptionForLayout,
        parseArgs(&.{ "oci:layout", "--deadline", "1s" }),
    );
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "registry.example/team/app:tag", "extra" }),
    );
}
