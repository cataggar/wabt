const std = @import("std");

pub const component_payload = @embedFile("../fixtures/oci/profiles/component.wasm");
pub const core_payload = @embedFile("../fixtures/oci/profiles/core.wasm");
pub const fixture_manifest = @embedFile("../fixtures/oci/manifest.json");

pub const EmbeddedFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const LayoutFixture = struct {
    name: []const u8,
    root_digest: []const u8,
    profile: ?[]const u8,
    files: []const EmbeddedFile,
};

const payload_digest = "0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9";
const empty_config_digest = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
const wasm_v0_config_digest = "16b287f376406152d521f47bfce1a0202b28039eddb3f6ab65c61d0755150886";

const wkg_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/wkg-wasm-v0/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/wkg-wasm-v0/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/wkg-wasm-v0/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ wasm_v0_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/wkg-wasm-v0/blobs/sha256/" ++ wasm_v0_config_digest) },
    .{ .path = "blobs/sha256/f0a0d909a4592beddc8e207ad4c246892e733f3677977d6e0e80555c81f12d3b", .bytes = @embedFile("../fixtures/oci/layouts/wkg-wasm-v0/blobs/sha256/f0a0d909a4592beddc8e207ad4c246892e733f3677977d6e0e80555c81f12d3b") },
};

const wabt_v0_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/wabt-wasm-v0/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/wabt-wasm-v0/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/wabt-wasm-v0/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ wasm_v0_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/wabt-wasm-v0/blobs/sha256/" ++ wasm_v0_config_digest) },
    .{ .path = "blobs/sha256/f987dbe05025e936f0043c6ce69199d14baddbe972f56806e3b5b251c7b39642", .bytes = @embedFile("../fixtures/oci/layouts/wabt-wasm-v0/blobs/sha256/f987dbe05025e936f0043c6ce69199d14baddbe972f56806e3b5b251c7b39642") },
};

const oras_v1_0_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.0/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.0/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.0/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ empty_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.0/blobs/sha256/" ++ empty_config_digest) },
    .{ .path = "blobs/sha256/4c6bdbc100d383fc1e6c54d40c2def710587327e662faa6b86955a2469cd151d", .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.0/blobs/sha256/4c6bdbc100d383fc1e6c54d40c2def710587327e662faa6b86955a2469cd151d") },
};

const oras_v1_1_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.1/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.1/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.1/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ empty_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.1/blobs/sha256/" ++ empty_config_digest) },
    .{ .path = "blobs/sha256/207c3d2146076671d7d31ca21ec0a26e248a6a82d8b62f9d518d9e9411b3bde7", .bytes = @embedFile("../fixtures/oci/layouts/oras-oci-v1.1/blobs/sha256/207c3d2146076671d7d31ca21ec0a26e248a6a82d8b62f9d518d9e9411b3bde7") },
};

const wabt_oci_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/wabt-oci-v1.1/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/wabt-oci-v1.1/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/wabt-oci-v1.1/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ empty_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/wabt-oci-v1.1/blobs/sha256/" ++ empty_config_digest) },
    .{ .path = "blobs/sha256/517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39", .bytes = @embedFile("../fixtures/oci/layouts/wabt-oci-v1.1/blobs/sha256/517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39") },
};

const copy_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/copy-roundtrip/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/copy-roundtrip/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/copy-roundtrip/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ empty_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/copy-roundtrip/blobs/sha256/" ++ empty_config_digest) },
    .{ .path = "blobs/sha256/517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39", .bytes = @embedFile("../fixtures/oci/layouts/copy-roundtrip/blobs/sha256/517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39") },
};

const index_files = [_]EmbeddedFile{
    .{ .path = "oci-layout", .bytes = @embedFile("../fixtures/oci/layouts/index/oci-layout") },
    .{ .path = "index.json", .bytes = @embedFile("../fixtures/oci/layouts/index/index.json") },
    .{ .path = "blobs/sha256/" ++ payload_digest, .bytes = @embedFile("../fixtures/oci/layouts/index/blobs/sha256/" ++ payload_digest) },
    .{ .path = "blobs/sha256/" ++ empty_config_digest, .bytes = @embedFile("../fixtures/oci/layouts/index/blobs/sha256/" ++ empty_config_digest) },
    .{ .path = "blobs/sha256/207c3d2146076671d7d31ca21ec0a26e248a6a82d8b62f9d518d9e9411b3bde7", .bytes = @embedFile("../fixtures/oci/layouts/index/blobs/sha256/207c3d2146076671d7d31ca21ec0a26e248a6a82d8b62f9d518d9e9411b3bde7") },
    .{ .path = "blobs/sha256/517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39", .bytes = @embedFile("../fixtures/oci/layouts/index/blobs/sha256/517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39") },
    .{ .path = "blobs/sha256/def0412196b08c523e995dab0d5f3a1696f8217a3f431e2625cebc5bea05719f", .bytes = @embedFile("../fixtures/oci/layouts/index/blobs/sha256/def0412196b08c523e995dab0d5f3a1696f8217a3f431e2625cebc5bea05719f") },
};

pub const direct_layouts = [_]LayoutFixture{
    .{ .name = "wkg-wasm-v0", .root_digest = "sha256:f0a0d909a4592beddc8e207ad4c246892e733f3677977d6e0e80555c81f12d3b", .profile = "wasm-v0", .files = &wkg_files },
    .{ .name = "wabt-wasm-v0", .root_digest = "sha256:f987dbe05025e936f0043c6ce69199d14baddbe972f56806e3b5b251c7b39642", .profile = "wasm-v0", .files = &wabt_v0_files },
    .{ .name = "oras-oci-v1.0", .root_digest = "sha256:4c6bdbc100d383fc1e6c54d40c2def710587327e662faa6b86955a2469cd151d", .profile = "oci-1.0", .files = &oras_v1_0_files },
    .{ .name = "oras-oci-v1.1", .root_digest = "sha256:207c3d2146076671d7d31ca21ec0a26e248a6a82d8b62f9d518d9e9411b3bde7", .profile = "oci-1.1", .files = &oras_v1_1_files },
    .{ .name = "wabt-oci-v1.1", .root_digest = "sha256:517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39", .profile = "oci-1.1", .files = &wabt_oci_files },
};

pub const copy_layout = LayoutFixture{
    .name = "copy-roundtrip",
    .root_digest = "sha256:517c728181ef8f5144e9764a8d4317d97a6f955fad53bb0c25131c0094363b39",
    .profile = "oci-1.1",
    .files = &copy_files,
};

pub const index_layout = LayoutFixture{
    .name = "index",
    .root_digest = "sha256:def0412196b08c523e995dab0d5f3a1696f8217a3f431e2625cebc5bea05719f",
    .profile = null,
    .files = &index_files,
};

pub const negative_documents = [_][]const u8{
    @embedFile("../fixtures/oci/negative/wrong-descriptor-size.json"),
    @embedFile("../fixtures/oci/negative/wrong-descriptor-digest.json"),
    @embedFile("../fixtures/oci/negative/moved-tag.json"),
    @embedFile("../fixtures/oci/negative/missing-title.json"),
    @embedFile("../fixtures/oci/negative/hostile-titles.json"),
    @embedFile("../fixtures/oci/negative/layer-count.json"),
    @embedFile("../fixtures/oci/negative/tar-labeled-raw-wasm.json"),
    @embedFile("../fixtures/oci/negative/unsupported-media-types.json"),
    @embedFile("../fixtures/oci/negative/index-extraction.json"),
    @embedFile("../fixtures/oci/negative/interrupted-publication.json"),
};

pub fn materialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    base: []const u8,
    fixture: LayoutFixture,
) !void {
    for (fixture.files) |file| {
        const relative = try std.fs.path.join(allocator, &.{ base, file.path });
        defer allocator.free(relative);
        if (std.fs.path.dirname(relative)) |parent| {
            try directory.createDirPath(io, parent);
        }
        try directory.writeFile(io, .{
            .sub_path = relative,
            .data = file.bytes,
        });
    }
}

pub fn cwdPath(
    allocator: std.mem.Allocator,
    temporary_sub_path: []const u8,
    relative: []const u8,
) ![]u8 {
    return std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", temporary_sub_path, relative },
    );
}
