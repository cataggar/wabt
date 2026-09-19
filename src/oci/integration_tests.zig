const std = @import("std");
const content = @import("content.zig");
const copy = @import("copy.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");

const ManifestOptions = struct {
    tag: ?[]const u8 = "source",
    config_media_type: []const u8 = model.media_type_oci_config,
    config_bytes: []const u8 = "{}",
    layer_media_type: []const u8 = model.media_type_oci_layer,
    layer_bytes: []const u8 = "layer",
    artifact_type: ?[]const u8 = null,
    manifest_extension: []const u8 = "",
    root_extension: []const u8 = "",
    catalog_extension: []const u8 = "",
};

const Fixture = struct {
    root: model.Descriptor,
    config: model.Descriptor,
    layer: model.Descriptor,
    root_bytes: []const u8,
};

test "layout source resolves tag digest and unambiguous roots" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const fixture = try makeManifestLayout(
        std.testing.io,
        allocator,
        source_path,
        .{},
    );

    var source = layout.Source.init(
        std.testing.io,
        std.testing.allocator,
        source_path,
    );
    var by_tag = try source.resolve(.{
        .path = source_path,
        .selection = .{ .tag = "source" },
    });
    defer by_tag.deinit();
    try std.testing.expectEqualStrings(fixture.root.digest, by_tag.descriptor.digest);
    try std.testing.expectEqualSlices(u8, fixture.root_bytes, by_tag.bytes);

    const root_digest = try content.Digest.parse(fixture.root.digest);
    var by_digest = try source.resolve(.{
        .path = source_path,
        .selection = .{ .digest = root_digest },
    });
    defer by_digest.deinit();
    try std.testing.expectEqualStrings(fixture.root.digest, by_digest.descriptor.digest);

    var unambiguous = try source.resolve(.{
        .path = source_path,
        .selection = null,
    });
    defer unambiguous.deinit();
    try std.testing.expectEqualStrings(fixture.root.digest, unambiguous.descriptor.digest);

    const duplicate = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"manifests\":[{s},{s}]}}",
        .{ by_tag.descriptor_json, by_tag.descriptor_json },
    );
    try writeFile(std.testing.io, source_path, "index.json", duplicate);
    try std.testing.expectError(
        error.AmbiguousRoot,
        source.resolve(.{ .path = source_path, .selection = null }),
    );
    var selected_duplicate = try source.resolve(.{
        .path = source_path,
        .selection = .{ .tag = "source" },
    });
    defer selected_duplicate.deinit();
    try std.testing.expectEqualStrings(
        fixture.root.digest,
        selected_duplicate.descriptor.digest,
    );
}

test "layout source rejects invalid layout version and catalog" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);

    const bad_layout = try childPath(allocator, root, "bad-layout");
    _ = try makeManifestLayout(std.testing.io, allocator, bad_layout, .{});
    try writeFile(std.testing.io, bad_layout, "oci-layout", "not json");
    var source = layout.Source.init(std.testing.io, allocator, bad_layout);
    try std.testing.expectError(error.InvalidLayout, source.validateLayout());

    const bad_version = try childPath(allocator, root, "bad-version");
    _ = try makeManifestLayout(std.testing.io, allocator, bad_version, .{});
    try writeFile(
        std.testing.io,
        bad_version,
        "oci-layout",
        "{\"imageLayoutVersion\":\"1.1.0\"}",
    );
    source = layout.Source.init(std.testing.io, allocator, bad_version);
    try std.testing.expectError(
        error.InvalidLayoutVersion,
        source.validateLayout(),
    );

    const bad_catalog = try childPath(allocator, root, "bad-catalog");
    _ = try makeManifestLayout(std.testing.io, allocator, bad_catalog, .{});
    try writeFile(
        std.testing.io,
        bad_catalog,
        "index.json",
        "{\"schemaVersion\":1,\"manifests\":[]}",
    );
    source = layout.Source.init(std.testing.io, allocator, bad_catalog);
    try std.testing.expectError(error.InvalidIndex, source.validateLayout());
}

test "copy preserves exact direct manifest artifact and catalog extensions" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const destination_path = try childPath(allocator, root, "destination");

    const fixture = try makeManifestLayout(
        std.testing.io,
        allocator,
        source_path,
        .{
            .config_media_type = model.media_type_oci_empty_config,
            .layer_media_type = "application/wasm",
            .layer_bytes = "\x00asm\x01\x00\x00\x00",
            .artifact_type = "application/vnd.example.wasm.v1",
            .manifest_extension = ",\"x-document\":{\"bytes\":\"kept\"}",
            .root_extension = ",\"x-root-extension\":{\"kept\":true}",
        },
    );
    const old = try makeManifestLayout(
        std.testing.io,
        allocator,
        destination_path,
        .{
            .tag = "old",
            .catalog_extension = ",\"x-top-level\":{\"kept\":true}",
        },
    );

    const result = try copy.layoutToLayout(
        std.testing.io,
        std.testing.allocator,
        .{ .path = source_path, .selection = .{ .tag = "source" } },
        .{ .path = destination_path, .selection = .{ .tag = "copied" } },
        .{},
    );
    try std.testing.expect((try content.Digest.parse(fixture.root.digest)).eql(result.root));
    try std.testing.expectEqual(@as(u64, 0), result.counts.mounted);

    const copied_manifest = try readBlob(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        fixture.root,
    );
    defer std.testing.allocator.free(copied_manifest);
    try std.testing.expectEqualSlices(u8, fixture.root_bytes, copied_manifest);

    const index = try readFile(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        "index.json",
    );
    defer std.testing.allocator.free(index);
    try std.testing.expect(std.mem.indexOf(u8, index, "\"x-top-level\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, index, "\"x-root-extension\"") != null);

    var destination = layout.Source.init(
        std.testing.io,
        std.testing.allocator,
        destination_path,
    );
    var copied = try destination.resolve(.{
        .path = destination_path,
        .selection = .{ .tag = "copied" },
    });
    defer copied.deinit();
    try std.testing.expectEqualSlices(u8, fixture.root_bytes, copied.bytes);
    var retained = try destination.resolve(.{
        .path = destination_path,
        .selection = .{ .tag = "old" },
    });
    defer retained.deinit();
    try std.testing.expectEqualStrings(old.root.digest, retained.descriptor.digest);
}

test "copy preserves nested index graph and streams a large blob" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const destination_path = try childPath(allocator, root, "destination");

    const payload = try allocator.alloc(u8, transportBufferTestSize());
    for (payload, 0..) |*byte, index| byte.* = @truncate(index);
    const manifest = try makeManifestLayout(
        std.testing.io,
        allocator,
        source_path,
        .{
            .layer_bytes = payload,
            .manifest_extension = ",\"x-manifest\":\"exact\"",
        },
    );
    const nested_bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d},\"x-child-extension\":true}}],\"x-index-extension\":[1,2,3]}}",
        .{
            model.media_type_oci_index,
            manifest.root.mediaType,
            manifest.root.digest,
            manifest.root.size,
        },
    );
    const nested = try testDescriptor(
        allocator,
        model.media_type_oci_index,
        nested_bytes,
    );
    try writeBlob(std.testing.io, source_path, nested, nested_bytes);
    const top = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d},\"annotations\":{{\"org.opencontainers.image.ref.name\":\"nested\"}},\"x-root\":{{\"keep\":true}}}}]}}",
        .{ nested.mediaType, nested.digest, nested.size },
    );
    try writeFile(std.testing.io, source_path, "index.json", top);

    const result = try copy.layoutToLayout(
        std.testing.io,
        std.testing.allocator,
        .{ .path = source_path, .selection = .{ .tag = "nested" } },
        .{ .path = destination_path, .selection = .{ .tag = "nested" } },
        .{},
    );
    try std.testing.expect((try content.Digest.parse(nested.digest)).eql(result.root));
    const copied_index = try readBlob(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        nested,
    );
    defer std.testing.allocator.free(copied_index);
    try std.testing.expectEqualSlices(u8, nested_bytes, copied_index);
    const copied_manifest = try readBlob(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        manifest.root,
    );
    defer std.testing.allocator.free(copied_manifest);
    try std.testing.expectEqualSlices(u8, manifest.root_bytes, copied_manifest);
    const copied_layer = try readBlob(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        manifest.layer,
    );
    defer std.testing.allocator.free(copied_layer);
    try std.testing.expectEqualSlices(u8, payload, copied_layer);
}

test "copy is idempotent and rejects corrupt source or reusable destination" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const destination_path = try childPath(allocator, root, "destination");
    const corrupt_source_path = try childPath(allocator, root, "corrupt-source");
    const failed_path = try childPath(allocator, root, "failed");
    const fixture = try makeManifestLayout(
        std.testing.io,
        allocator,
        source_path,
        .{},
    );

    const first = try copy.layoutToLayout(
        std.testing.io,
        std.testing.allocator,
        .{ .path = source_path, .selection = .{ .tag = "source" } },
        .{ .path = destination_path, .selection = .{ .tag = "copy" } },
        .{},
    );
    try std.testing.expectEqual(@as(u64, 3), first.counts.transferred);
    const second = try copy.layoutToLayout(
        std.testing.io,
        std.testing.allocator,
        .{ .path = source_path, .selection = .{ .tag = "source" } },
        .{ .path = destination_path, .selection = .{ .tag = "copy" } },
        .{},
    );
    try std.testing.expectEqual(@as(u64, 0), second.counts.transferred);
    try std.testing.expectEqual(@as(u64, 3), second.counts.reused);
    try std.testing.expectEqual(.unchanged, second.commit);

    const before = try readFile(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        "index.json",
    );
    defer std.testing.allocator.free(before);
    try writeBlob(
        std.testing.io,
        destination_path,
        fixture.layer,
        "bad!!",
    );
    try std.testing.expectError(
        error.CorruptBlob,
        copy.layoutToLayout(
            std.testing.io,
            std.testing.allocator,
            .{ .path = source_path, .selection = .{ .tag = "source" } },
            .{ .path = destination_path, .selection = .{ .tag = "copy" } },
            .{},
        ),
    );
    const after = try readFile(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        "index.json",
    );
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, before, after);

    const corrupt = try makeManifestLayout(
        std.testing.io,
        allocator,
        corrupt_source_path,
        .{},
    );
    try writeBlob(
        std.testing.io,
        corrupt_source_path,
        corrupt.root,
        "corrupt",
    );
    try std.testing.expectError(
        error.CorruptBlob,
        copy.layoutToLayout(
            std.testing.io,
            std.testing.allocator,
            .{
                .path = corrupt_source_path,
                .selection = .{ .tag = "source" },
            },
            .{ .path = failed_path, .selection = .{ .tag = "copy" } },
            .{},
        ),
    );

    var source = layout.Source.init(std.testing.io, allocator, source_path);
    const missing = try testDescriptor(
        allocator,
        model.media_type_oci_layer,
        "not installed",
    );
    try std.testing.expectEqual(.missing, try source.blobState(missing));
    try std.testing.expectError(
        error.MissingBlob,
        source.readMetadata(
            std.testing.allocator,
            missing,
            layout.default_metadata_limit,
        ),
    );
    try writeBlob(std.testing.io, source_path, missing, "wrong bytes!!");
    try std.testing.expectEqual(.corrupt, try source.blobState(missing));
    try std.testing.expectError(
        error.CorruptBlob,
        source.readMetadata(
            std.testing.allocator,
            missing,
            layout.default_metadata_limit,
        ),
    );
}

test "destination preflight and failures preserve atomic visibility" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const mismatch_path = try childPath(allocator, root, "mismatch");
    const conflict_path = try childPath(allocator, root, "conflict");
    const failed_path = try childPath(allocator, root, "failed");
    const fixture = try makeManifestLayout(
        std.testing.io,
        allocator,
        source_path,
        .{ .layer_bytes = "new source layer" },
    );

    const wrong = try content.Digest.parse(
        "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    );
    try std.testing.expectError(
        error.DescriptorMismatch,
        copy.layoutToLayout(
            std.testing.io,
            std.testing.allocator,
            .{ .path = source_path, .selection = .{ .tag = "source" } },
            .{ .path = mismatch_path, .selection = .{ .digest = wrong } },
            .{},
        ),
    );
    try expectMissingLayout(std.testing.io, mismatch_path);
    try expectNoStaging(std.testing.io, root, "mismatch");

    try std.Io.Dir.cwd().createDirPath(std.testing.io, conflict_path);
    var conflict_dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        conflict_path,
        .{},
    );
    defer conflict_dir.close(std.testing.io);
    try conflict_dir.createDirPath(std.testing.io, "blobs/sha256");
    try conflict_dir.writeFile(std.testing.io, .{
        .sub_path = "oci-layout",
        .data = "{\"imageLayoutVersion\":\"1.0.0\"}",
    });
    const conflict_index = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{
            fixture.root.mediaType,
            fixture.root.digest,
            fixture.root.size + 1,
        },
    );
    try conflict_dir.writeFile(std.testing.io, .{
        .sub_path = "index.json",
        .data = conflict_index,
    });
    const actual = try content.Digest.parse(fixture.root.digest);
    try std.testing.expectError(
        error.ConflictingDescriptor,
        copy.layoutToLayout(
            std.testing.io,
            std.testing.allocator,
            .{ .path = source_path, .selection = .{ .tag = "source" } },
            .{ .path = conflict_path, .selection = .{ .digest = actual } },
            .{},
        ),
    );
    var conflict_source = layout.Source.init(
        std.testing.io,
        std.testing.allocator,
        conflict_path,
    );
    try std.testing.expectEqual(
        .missing,
        try conflict_source.blobState(fixture.root),
    );

    try std.testing.expectError(
        error.InjectedFailure,
        copy.layoutToLayout(
            std.testing.io,
            std.testing.allocator,
            .{ .path = source_path, .selection = .{ .tag = "source" } },
            .{ .path = failed_path, .selection = .{ .tag = "copy" } },
            .{ .failure_point = .before_index_publish },
        ),
    );
    try expectMissingLayout(std.testing.io, failed_path);
    try expectNoStaging(std.testing.io, root, "failed");
}

test "existing layout keeps old catalog and cleans temporary files on failure" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const destination_path = try childPath(allocator, root, "destination");
    _ = try makeManifestLayout(
        std.testing.io,
        allocator,
        source_path,
        .{ .layer_bytes = "new source layer" },
    );
    _ = try makeManifestLayout(
        std.testing.io,
        allocator,
        destination_path,
        .{ .tag = "old" },
    );
    const before = try readFile(
        std.testing.io,
        std.testing.allocator,
        destination_path,
        "index.json",
    );
    defer std.testing.allocator.free(before);

    const points = [_]layout.FailurePoint{
        .after_blob_temp_sync,
        .before_index_publish,
        .after_index_temp_sync,
    };
    for (points) |point| {
        try std.testing.expectError(
            error.InjectedFailure,
            copy.layoutToLayout(
                std.testing.io,
                std.testing.allocator,
                .{ .path = source_path, .selection = .{ .tag = "source" } },
                .{
                    .path = destination_path,
                    .selection = .{ .tag = "new" },
                },
                .{ .failure_point = point },
            ),
        );
        const after = try readFile(
            std.testing.io,
            std.testing.allocator,
            destination_path,
            "index.json",
        );
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualSlices(u8, before, after);
        try expectNoTemporaryFiles(std.testing.io, destination_path);
    }

    var destination = layout.Source.init(
        std.testing.io,
        std.testing.allocator,
        destination_path,
    );
    var old = try destination.resolve(.{
        .path = destination_path,
        .selection = .{ .tag = "old" },
    });
    defer old.deinit();
    try std.testing.expectError(
        error.RootNotFound,
        destination.resolve(.{
            .path = destination_path,
            .selection = .{ .tag = "new" },
        }),
    );
}

test "concurrent first and existing layout writers retain references" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, &tmp.sub_path);
    const source_path = try childPath(allocator, root, "source");
    const first_path = try childPath(allocator, root, "first");
    const existing_path = try childPath(allocator, root, "existing");
    _ = try makeManifestLayout(std.testing.io, allocator, source_path, .{});

    try runConcurrentCopies(source_path, first_path);
    try expectTags(first_path, "one", "two");

    _ = try makeManifestLayout(
        std.testing.io,
        allocator,
        existing_path,
        .{ .tag = "old" },
    );
    try runConcurrentCopies(source_path, existing_path);
    try expectTags(existing_path, "one", "two");
    var existing = layout.Source.init(
        std.testing.io,
        std.testing.allocator,
        existing_path,
    );
    var old = try existing.resolve(.{
        .path = existing_path,
        .selection = .{ .tag = "old" },
    });
    defer old.deinit();
}

fn makeManifestLayout(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: ManifestOptions,
) !Fixture {
    try std.Io.Dir.cwd().createDirPath(io, path);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "blobs/sha256");
    try dir.writeFile(io, .{
        .sub_path = "oci-layout",
        .data = "{\"imageLayoutVersion\":\"1.0.0\"}\n",
    });

    const config = try testDescriptor(
        allocator,
        options.config_media_type,
        options.config_bytes,
    );
    try writeBlob(io, path, config, options.config_bytes);
    const layer_descriptor = try testDescriptor(
        allocator,
        options.layer_media_type,
        options.layer_bytes,
    );
    try writeBlob(io, path, layer_descriptor, options.layer_bytes);
    const artifact = if (options.artifact_type) |artifact_type|
        try std.fmt.allocPrint(
            allocator,
            ",\"artifactType\":\"{s}\"",
            .{artifact_type},
        )
    else
        "";
    const manifest_bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\"{s},\"config\":{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}]{s}}}\n",
        .{
            model.media_type_oci_manifest,
            artifact,
            config.mediaType,
            config.digest,
            config.size,
            layer_descriptor.mediaType,
            layer_descriptor.digest,
            layer_descriptor.size,
            options.manifest_extension,
        },
    );
    const root = try testDescriptor(
        allocator,
        model.media_type_oci_manifest,
        manifest_bytes,
    );
    try writeBlob(io, path, root, manifest_bytes);

    const annotations = if (options.tag) |tag|
        try std.fmt.allocPrint(
            allocator,
            ",\"annotations\":{{\"org.opencontainers.image.ref.name\":\"{s}\"}}",
            .{tag},
        )
    else
        "";
    const index = try std.fmt.allocPrint(
        allocator,
        "{{\"schemaVersion\":2,\"manifests\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}{s}{s}}}]{s}}}\n",
        .{
            root.mediaType,
            root.digest,
            root.size,
            annotations,
            options.root_extension,
            options.catalog_extension,
        },
    );
    try dir.writeFile(io, .{ .sub_path = "index.json", .data = index });
    return .{
        .root = root,
        .config = config,
        .layer = layer_descriptor,
        .root_bytes = manifest_bytes,
    };
}

fn testDescriptor(
    allocator: std.mem.Allocator,
    media_type: []const u8,
    bytes: []const u8,
) !model.Descriptor {
    const digest = content.digestBytes(bytes).format();
    return .{
        .mediaType = media_type,
        .digest = try std.fmt.allocPrint(allocator, "{s}", .{digest}),
        .size = try content.checkedSize(bytes.len),
    };
}

fn writeBlob(
    io: std.Io,
    path: []const u8,
    descriptor: model.Descriptor,
    bytes: []const u8,
) !void {
    const digest = try content.Digest.parse(descriptor.digest);
    const relative = digest.blobPath();
    try writeFile(io, path, &relative, bytes);
}

fn writeFile(
    io: std.Io,
    path: []const u8,
    relative: []const u8,
    bytes: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = relative, .data = bytes });
}

fn readBlob(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    descriptor: model.Descriptor,
) ![]u8 {
    const digest = try content.Digest.parse(descriptor.digest);
    const relative = digest.blobPath();
    return readFile(io, allocator, path, &relative);
}

fn readFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    relative: []const u8,
) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var file = try dir.openFile(io, relative, .{});
    defer file.close(io);
    const size = try file.length(io);
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) {
        return error.UnexpectedEndOfFile;
    }
    return bytes;
}

fn testRoot(
    allocator: std.mem.Allocator,
    sub_path: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{sub_path},
    );
}

fn childPath(
    allocator: std.mem.Allocator,
    parent: []const u8,
    child: []const u8,
) ![]u8 {
    return std.fs.path.join(allocator, &.{ parent, child });
}

fn transportBufferTestSize() usize {
    return 64 * 1024 * 3 + 17;
}

fn expectMissingLayout(io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dir.close(io);
    return error.TestUnexpectedResult;
}

fn expectNoStaging(
    io: std.Io,
    parent: []const u8,
    base: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    const prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        ".wabt-oci-{s}-staging-",
        .{base},
    );
    defer std.testing.allocator.free(prefix);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, prefix));
    }
}

fn expectNoTemporaryFiles(io: std.Io, path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    try expectNoTempsInDir(io, dir);
    var blobs = try dir.openDir(io, "blobs/sha256", .{ .iterate = true });
    defer blobs.close(io);
    try expectNoTempsInDir(io, blobs);
}

fn expectNoTempsInDir(io: std.Io, dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const temporary = std.mem.startsWith(
            u8,
            entry.name,
            ".wabt-oci-",
        ) and std.mem.endsWith(u8, entry.name, ".tmp");
        try std.testing.expect(!temporary);
    }
}

const StartGate = struct {
    ready: std.atomic.Value(u8) = .init(0),
    released: std.atomic.Value(bool) = .init(false),

    fn wait(self: *StartGate) void {
        _ = self.ready.fetchAdd(1, .release);
        while (!self.released.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn releaseWhenReady(self: *StartGate) void {
        while (self.ready.load(.acquire) < 2) std.atomic.spinLoopHint();
        self.released.store(true, .release);
    }
};

const CopyThread = struct {
    source_path: []const u8,
    destination_path: []const u8,
    destination_tag: []const u8,
    gate: *StartGate,
    ok: bool = true,

    fn run(self: *CopyThread) void {
        self.gate.wait();
        _ = copy.layoutToLayout(
            std.testing.io,
            std.heap.page_allocator,
            .{
                .path = self.source_path,
                .selection = .{ .tag = "source" },
            },
            .{
                .path = self.destination_path,
                .selection = .{ .tag = self.destination_tag },
            },
            .{},
        ) catch {
            self.ok = false;
        };
    }
};

fn runConcurrentCopies(
    source_path: []const u8,
    destination_path: []const u8,
) !void {
    var gate: StartGate = .{};
    var first: CopyThread = .{
        .source_path = source_path,
        .destination_path = destination_path,
        .destination_tag = "one",
        .gate = &gate,
    };
    var second: CopyThread = .{
        .source_path = source_path,
        .destination_path = destination_path,
        .destination_tag = "two",
        .gate = &gate,
    };
    var first_thread = try std.Thread.spawn(.{}, CopyThread.run, .{&first});
    var second_thread = try std.Thread.spawn(.{}, CopyThread.run, .{&second});
    gate.releaseWhenReady();
    first_thread.join();
    second_thread.join();
    try std.testing.expect(first.ok);
    try std.testing.expect(second.ok);
}

fn expectTags(
    path: []const u8,
    first_tag: []const u8,
    second_tag: []const u8,
) !void {
    var source = layout.Source.init(
        std.testing.io,
        std.testing.allocator,
        path,
    );
    var first = try source.resolve(.{
        .path = path,
        .selection = .{ .tag = first_tag },
    });
    defer first.deinit();
    var second = try source.resolve(.{
        .path = path,
        .selection = .{ .tag = second_tag },
    });
    defer second.deinit();
    try std.testing.expectEqualStrings(
        first.descriptor.digest,
        second.descriptor.digest,
    );
}
