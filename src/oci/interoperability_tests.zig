const std = @import("std");
const content = @import("content.zig");
const copy = @import("copy.zig");
const extract = @import("extract.zig");
const fixture = @import("fixture_support.zig");
const graph = @import("graph.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const wasm = @import("wasm.zig");

test "fixture manifest pins producers files and complete expected matrix" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        fixture.fixture_manifest,
        .{},
    );
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(
        "wabt.oci.interop-fixtures",
        root.get("schema").?.string,
    );
    try std.testing.expectEqual(@as(i64, 1), root.get("schemaVersion").?.integer);
    try std.testing.expectEqualStrings(
        "2026-09-19T00:00:00Z",
        root.get("fixedCreated").?.string,
    );

    const producers = root.get("producers").?.object;
    try std.testing.expectEqualStrings(
        "1.3.4",
        producers.get("oras").?.object.get("version").?.string,
    );
    try std.testing.expectEqualStrings(
        "5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a",
        producers.get("wkg").?.object.get("sourceRevision").?.string,
    );
    try std.testing.expectEqualStrings(
        "87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21",
        producers.get("oci-wasm").?.object.get("crateChecksumSha256").?.string,
    );

    const payload_digest = content.digestBytes(fixture.component_payload).format();
    try std.testing.expectEqualStrings(
        "sha256:0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9",
        &payload_digest,
    );
    try std.testing.expectEqual(@as(usize, 58495), fixture.component_payload.len);
    try std.testing.expectEqualSlices(
        u8,
        "\x00asm\x01\x00\x00\x00",
        fixture.core_payload,
    );

    const required_matrix = [_][]const u8{
        "wkg-to-wabt",
        "wabt-wasm-v0-to-wkg",
        "oras-oci-1.0-to-wabt",
        "oras-oci-1.1-to-wabt",
        "wabt-generic-to-oras",
        "wabt-generic-to-wkg",
        "digest-preserving-copies",
        "index-preservation-and-extraction-rejection",
        "negative-wrong-descriptor-size",
        "negative-wrong-descriptor-digest",
        "negative-moved-tag",
        "negative-missing-title",
        "negative-hostile-titles",
        "negative-layer-count",
        "negative-tar-labeled-raw-wasm",
        "negative-unsupported-media-types",
        "negative-index-extraction",
        "negative-interrupted-publication",
    };
    const matrix = root.get("matrix").?.array.items;
    try std.testing.expectEqual(required_matrix.len, matrix.len);
    for (required_matrix) |required| {
        var found = false;
        for (matrix) |entry| {
            const object = entry.object;
            if (!std.mem.eql(u8, object.get("id").?.string, required)) continue;
            found = true;
            try std.testing.expect(std.mem.startsWith(
                u8,
                object.get("result").?.string,
                "pass",
            ));
        }
        try std.testing.expect(found);
    }

    for (fixture.negative_documents) |bytes| {
        var negative = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            bytes,
            .{},
        );
        defer negative.deinit();
        const object = negative.value.object;
        try std.testing.expectEqualStrings(
            "wabt.oci.negative-fixture",
            object.get("schema").?.string,
        );
        try std.testing.expectEqual(@as(i64, 1), object.get("schemaVersion").?.integer);
        try std.testing.expect(object.get("expected") != null);
    }
}

test "external producer layouts extract byte-identical checked-in component" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();

    for (fixture.direct_layouts, 0..) |case, index| {
        const base = try std.fmt.allocPrint(allocator, "layout-{d}", .{index});
        defer allocator.free(base);
        try fixture.materialize(
            allocator,
            std.testing.io,
            temporary.dir,
            base,
            case,
        );
        const layout_path = try fixture.cwdPath(
            allocator,
            &temporary.sub_path,
            base,
        );
        defer allocator.free(layout_path);
        var source = layout.Source.init(std.testing.io, allocator, layout_path);
        const reference = layoutReference(layout_path, "fixture");
        var resolved = try source.resolve(reference);
        defer resolved.deinit();
        try std.testing.expectEqualStrings(
            case.root_digest,
            resolved.descriptor.digest,
        );

        var plan = try graph.planInspect(
            allocator,
            source.asTransport(),
            .{
                .descriptor = resolved.descriptor,
                .descriptor_json = resolved.descriptor_json,
            },
            .{},
        );
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 3), plan.entries.len);
        try std.testing.expectEqual(@as(usize, 1), plan.nodes.len);

        const output_name = try std.fmt.allocPrint(
            allocator,
            "pulled-{d}.wasm",
            .{index},
        );
        defer allocator.free(output_name);
        const output_path = try fixture.cwdPath(
            allocator,
            &temporary.sub_path,
            output_name,
        );
        defer allocator.free(output_path);
        const result = try extract.fromLayoutSource(
            allocator,
            &source,
            reference,
            output_path,
            .{},
        );
        try std.testing.expectEqual(
            expectedProfile(case.profile.?),
            result.profile,
        );
        const pulled = try temporary.dir.readFileAlloc(
            std.testing.io,
            output_name,
            allocator,
            .limited(fixture.component_payload.len + 1),
        );
        defer allocator.free(pulled);
        try std.testing.expectEqualSlices(
            u8,
            fixture.component_payload,
            pulled,
        );
    }
}

test "checked-in copy and index preserve exact graphs without platform extraction" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();

    try fixture.materialize(
        allocator,
        std.testing.io,
        temporary.dir,
        "source",
        fixture.direct_layouts[4],
    );
    try fixture.materialize(
        allocator,
        std.testing.io,
        temporary.dir,
        "recorded-copy",
        fixture.copy_layout,
    );
    for (fixture.direct_layouts[4].files, fixture.copy_layout.files) |source, recorded| {
        try std.testing.expectEqualStrings(source.path, recorded.path);
        try std.testing.expectEqualSlices(u8, source.bytes, recorded.bytes);
    }

    const source_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "source",
    );
    defer allocator.free(source_path);
    const copied_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "copied",
    );
    defer allocator.free(copied_path);
    const copy_result = try copy.layoutToLayout(
        std.testing.io,
        allocator,
        layoutReference(source_path, "fixture"),
        layoutReference(copied_path, "copied"),
        .{},
    );
    const expected_copy_digest = try content.Digest.parse(
        fixture.copy_layout.root_digest,
    );
    try std.testing.expect(expected_copy_digest.eql(copy_result.root));

    var copied_source = layout.Source.init(
        std.testing.io,
        allocator,
        copied_path,
    );
    var copied_root = try copied_source.resolve(
        layoutReference(copied_path, "copied"),
    );
    defer copied_root.deinit();
    try std.testing.expectEqualStrings(
        fixture.copy_layout.root_digest,
        copied_root.descriptor.digest,
    );

    try fixture.materialize(
        allocator,
        std.testing.io,
        temporary.dir,
        "index",
        fixture.index_layout,
    );
    const index_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "index",
    );
    defer allocator.free(index_path);
    var index_source = layout.Source.init(std.testing.io, allocator, index_path);
    const index_reference = layoutReference(index_path, "fixture");
    var index_root = try index_source.resolve(index_reference);
    defer index_root.deinit();
    try std.testing.expectEqualStrings(
        fixture.index_layout.root_digest,
        index_root.descriptor.digest,
    );
    var index_plan = try graph.planInspect(
        allocator,
        index_source.asTransport(),
        .{
            .descriptor = index_root.descriptor,
            .descriptor_json = index_root.descriptor_json,
        },
        .{},
    );
    defer index_plan.deinit();
    try std.testing.expectEqual(@as(usize, 5), index_plan.entries.len);
    try std.testing.expectEqual(@as(usize, 3), index_plan.nodes.len);

    const index_output = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "index-output.wasm",
    );
    defer allocator.free(index_output);
    try std.testing.expectError(
        error.DirectManifestRequired,
        extract.fromLayoutSource(
            allocator,
            &index_source,
            index_reference,
            index_output,
            .{},
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(std.testing.io, "index-output.wasm", .{}),
    );

    const index_copy_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "index-copy",
    );
    defer allocator.free(index_copy_path);
    const index_copy = try copy.layoutToLayout(
        std.testing.io,
        allocator,
        index_reference,
        layoutReference(index_copy_path, "copied"),
        .{},
    );
    try std.testing.expect(
        (try content.Digest.parse(fixture.index_layout.root_digest)).eql(
            index_copy.root,
        ),
    );
}

test "negative corpus rejects corruption media and partial publication" {
    const allocator = std.testing.allocator;
    const config = model.Descriptor{
        .mediaType = wasm.media_type_empty_config,
        .digest = wasm.empty_config_digest,
        .size = @intCast(wasm.empty_config_bytes.len),
    };
    const layer = model.Descriptor{
        .mediaType = wasm.media_type_wasm,
        .digest = "sha256:0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9",
        .size = @intCast(fixture.component_payload.len),
    };

    const missing_title = try genericManifest(
        allocator,
        config,
        &.{layer},
        null,
    );
    defer allocator.free(missing_title);
    var accepted = try classifyGeneric(
        allocator,
        model.media_type_oci_manifest,
        missing_title,
        wasm.empty_config_bytes,
        fixture.component_payload,
    );
    accepted.deinit();

    const hostile_titles = [_][]const u8{
        "../../escape.wasm",
        "/absolute/escape.wasm",
        "C:\\escape.wasm",
        "\\\\server\\share\\escape.wasm",
        "x" ** 4096,
    };
    for (hostile_titles) |title| {
        const manifest = try genericManifest(
            allocator,
            config,
            &.{layer},
            title,
        );
        defer allocator.free(manifest);
        var plan = try classifyGeneric(
            allocator,
            model.media_type_oci_manifest,
            manifest,
            wasm.empty_config_bytes,
            fixture.component_payload,
        );
        plan.deinit();
    }

    const no_layers = try genericManifest(allocator, config, &.{}, null);
    defer allocator.free(no_layers);
    try expectClassificationError(error.InvalidLayerCount, no_layers);

    const two_layers = try genericManifest(
        allocator,
        config,
        &.{ layer, layer },
        null,
    );
    defer allocator.free(two_layers);
    try expectClassificationError(error.InvalidLayerCount, two_layers);

    var tar_layer = layer;
    tar_layer.mediaType = model.media_type_oci_layer;
    const tar_manifest = try genericManifest(
        allocator,
        config,
        &.{tar_layer},
        null,
    );
    defer allocator.free(tar_manifest);
    try expectClassificationError(error.UnsupportedLayerMediaType, tar_manifest);

    var unsupported_config = config;
    unsupported_config.mediaType = "application/vnd.example.config";
    const unsupported_config_manifest = try genericManifest(
        allocator,
        unsupported_config,
        &.{layer},
        null,
    );
    defer allocator.free(unsupported_config_manifest);
    try expectClassificationError(
        error.UnsupportedProfile,
        unsupported_config_manifest,
    );

    var bad_config_size = config;
    bad_config_size.size += 1;
    const bad_config_size_manifest = try genericManifest(
        allocator,
        bad_config_size,
        &.{layer},
        null,
    );
    defer allocator.free(bad_config_size_manifest);
    try expectClassificationError(error.SizeMismatch, bad_config_size_manifest);

    var bad_config_digest = config;
    bad_config_digest.digest = "sha256:" ++ "1" ** 64;
    const bad_config_digest_manifest = try genericManifest(
        allocator,
        bad_config_digest,
        &.{layer},
        null,
    );
    defer allocator.free(bad_config_digest_manifest);
    try expectClassificationError(error.DigestMismatch, bad_config_digest_manifest);

    var bad_layer_size = layer;
    bad_layer_size.size += 1;
    const bad_layer_size_manifest = try genericManifest(
        allocator,
        config,
        &.{bad_layer_size},
        null,
    );
    defer allocator.free(bad_layer_size_manifest);
    try expectClassificationError(error.SizeMismatch, bad_layer_size_manifest);

    var bad_layer_digest = layer;
    bad_layer_digest.digest = "sha256:" ++ "2" ** 64;
    const bad_layer_digest_manifest = try genericManifest(
        allocator,
        config,
        &.{bad_layer_digest},
        null,
    );
    defer allocator.free(bad_layer_digest_manifest);
    try expectClassificationError(error.DigestMismatch, bad_layer_digest_manifest);

    const valid_manifest = try genericManifest(
        allocator,
        config,
        &.{layer},
        "component.wasm",
    );
    defer allocator.free(valid_manifest);
    var root_digest: [content.digest_text_size]u8 = undefined;
    var root = descriptorFor(
        model.media_type_oci_manifest,
        valid_manifest,
        &root_digest,
    );
    root.size += 1;
    try std.testing.expectError(
        error.SizeMismatch,
        wasm.classifyDirectManifest(
            allocator,
            root,
            valid_manifest,
            wasm.empty_config_bytes,
            fixture.component_payload,
        ),
    );
    root = descriptorFor(
        model.media_type_oci_manifest,
        valid_manifest,
        &root_digest,
    );
    root.digest = "sha256:" ++ "0" ** 64;
    try std.testing.expectError(
        error.DigestMismatch,
        wasm.classifyDirectManifest(
            allocator,
            root,
            valid_manifest,
            wasm.empty_config_bytes,
            fixture.component_payload,
        ),
    );
    root = descriptorFor(
        "application/vnd.example.root",
        valid_manifest,
        &root_digest,
    );
    try std.testing.expectError(
        error.UnsupportedRootMediaType,
        wasm.classifyDirectManifest(
            allocator,
            root,
            valid_manifest,
            wasm.empty_config_bytes,
            fixture.component_payload,
        ),
    );

    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "preserved.wasm",
        .data = "preserved",
    });
    const output_path = try fixture.cwdPath(
        allocator,
        &temporary.sub_path,
        "preserved.wasm",
    );
    defer allocator.free(output_path);
    var interrupted = InterruptedLayerSource{
        .bytes = fixture.component_payload,
    };
    root = descriptorFor(
        model.media_type_oci_manifest,
        valid_manifest,
        &root_digest,
    );
    try std.testing.expectError(
        error.InjectedReadFailure,
        extract.directManifest(
            std.testing.io,
            allocator,
            root,
            valid_manifest,
            wasm.empty_config_bytes,
            extract.LayerSource.init(&interrupted),
            output_path,
            .{ .force = true },
        ),
    );
    const preserved = try temporary.dir.readFileAlloc(
        std.testing.io,
        "preserved.wasm",
        allocator,
        .limited(16),
    );
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("preserved", preserved);
    var iterator = temporary.dir.iterate();
    var entries: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        entries += 1;
        try std.testing.expectEqualStrings("preserved.wasm", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

const JsonDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
};

const TitleAnnotations = struct {
    @"org.opencontainers.image.title": []const u8,
};

const JsonLayer = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    annotations: ?TitleAnnotations,
};

const CreatedAnnotations = struct {
    @"org.opencontainers.image.created": []const u8,
};

const JsonManifest = struct {
    schemaVersion: u32 = 2,
    mediaType: []const u8 = model.media_type_oci_manifest,
    artifactType: []const u8 = wasm.artifact_type_wasm,
    config: JsonDescriptor,
    layers: []const JsonLayer,
    annotations: CreatedAnnotations = .{
        .@"org.opencontainers.image.created" = "2026-09-19T00:00:00Z",
    },
};

fn genericManifest(
    allocator: std.mem.Allocator,
    config: model.Descriptor,
    layers: []const model.Descriptor,
    title: ?[]const u8,
) ![]u8 {
    const json_layers = try allocator.alloc(JsonLayer, layers.len);
    defer allocator.free(json_layers);
    for (layers, 0..) |layer, index| {
        json_layers[index] = .{
            .mediaType = layer.mediaType,
            .digest = layer.digest,
            .size = layer.size,
            .annotations = if (title) |value|
                .{ .@"org.opencontainers.image.title" = value }
            else
                null,
        };
    }
    return std.json.Stringify.valueAlloc(
        allocator,
        JsonManifest{
            .config = .{
                .mediaType = config.mediaType,
                .digest = config.digest,
                .size = config.size,
            },
            .layers = json_layers,
        },
        .{},
    );
}

fn descriptorFor(
    media_type: []const u8,
    bytes: []const u8,
    digest: *[content.digest_text_size]u8,
) model.Descriptor {
    digest.* = content.digestBytes(bytes).format();
    return .{
        .mediaType = media_type,
        .digest = digest,
        .size = @intCast(bytes.len),
    };
}

fn classifyGeneric(
    allocator: std.mem.Allocator,
    root_media_type: []const u8,
    manifest: []const u8,
    config: []const u8,
    payload: []const u8,
) !wasm.ExtractionPlan {
    var digest: [content.digest_text_size]u8 = undefined;
    return wasm.classifyDirectManifest(
        allocator,
        descriptorFor(root_media_type, manifest, &digest),
        manifest,
        config,
        payload,
    );
}

fn expectClassificationError(expected: anyerror, manifest: []const u8) !void {
    try std.testing.expectError(
        expected,
        classifyGeneric(
            std.testing.allocator,
            model.media_type_oci_manifest,
            manifest,
            wasm.empty_config_bytes,
            fixture.component_payload,
        ),
    );
}

fn expectedProfile(text: []const u8) wasm.DirectManifestProfile {
    if (std.mem.eql(u8, text, "wasm-v0")) return .wasm_v0;
    if (std.mem.eql(u8, text, "oci-1.0")) return .oci_1_0;
    return .oci_1_1;
}

fn layoutReference(path: []const u8, tag: []const u8) @import("reference.zig").LayoutReference {
    return .{ .path = path, .selection = .{ .tag = tag } };
}

const InterruptedLayerSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    failed: bool = false,

    pub fn read(self: *InterruptedLayerSource, destination: []u8) !usize {
        if (self.failed) return error.InjectedReadFailure;
        const remaining = self.bytes.len - self.offset;
        if (remaining == 0) return 0;
        const count = @min(@min(remaining, destination.len), 1024);
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        self.failed = true;
        return count;
    }
};
