//! Offline verification, qualification, and manifest assembly for pinned OCI
//! interoperability fixtures, plus helper commands used by the OCI interop
//! scripts and CI workflow.

const std = @import("std");

const schema_name = "wabt.oci.interop-fixtures";
const negative_schema_name = "wabt.oci.negative-fixture";
const fixed_created = "2026-09-19T00:00:00Z";
const payload_sha256 = "0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9";
const payload_size: u64 = 58495;
const core_wasm_bytes = "\x00asm\x01\x00\x00\x00";

const layout_names = [_][]const u8{
    "wkg-wasm-v0",
    "wabt-wasm-v0",
    "oras-oci-v1.0",
    "oras-oci-v1.1",
    "wabt-oci-v1.1",
    "copy-roundtrip",
    "index",
};

const NegativeCaseSpec = struct {
    id: []const u8,
    expected_result: []const u8,
    json: []const u8,
};

const negative_cases = [_]NegativeCaseSpec{
    .{
        .id = "wrong-descriptor-size",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "category": "descriptor-size-mismatch",
        \\    "destinationTag": "absent-or-unchanged",
        \\    "finalOutput": "absent-or-byte-identical",
        \\    "result": "reject"
        \\  },
        \\  "id": "wrong-descriptor-size",
        \\  "mutations": [
        \\    {
        \\      "operation": "add",
        \\      "target": "root.size",
        \\      "value": 1
        \\    },
        \\    {
        \\      "operation": "add",
        \\      "target": "manifest.config.size",
        \\      "value": 1
        \\    },
        \\    {
        \\      "operation": "add",
        \\      "target": "manifest.layers[0].size",
        \\      "value": 1
        \\    }
        \\  ],
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "wrong-descriptor-digest",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "category": "descriptor-digest-mismatch",
        \\    "destinationTag": "absent-or-unchanged",
        \\    "finalOutput": "absent-or-byte-identical",
        \\    "result": "reject",
        \\    "staging": "removed"
        \\  },
        \\  "id": "wrong-descriptor-digest",
        \\  "mutations": [
        \\    {
        \\      "operation": "replace",
        \\      "target": "root.digest",
        \\      "value": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        \\    },
        \\    {
        \\      "operation": "replace",
        \\      "target": "manifest.config.digest",
        \\      "value": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
        \\    },
        \\    {
        \\      "operation": "replace",
        \\      "target": "manifest.layers[0].digest",
        \\      "value": "sha256:2222222222222222222222222222222222222222222222222222222222222222"
        \\    }
        \\  ],
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "moved-tag",
        .expected_result = "accept-original",
        .json =
        \\{
        \\  "baseLayout": "wkg-wasm-v0",
        \\  "expected": {
        \\    "reportedRoot": "original-root",
        \\    "result": "accept-original",
        \\    "tagResolutions": 1
        \\  },
        \\  "id": "moved-tag",
        \\  "scenario": {
        \\    "moveTagBeforeBlobReads": "replacement-root",
        \\    "resolve": "original-root",
        \\    "subsequentReads": "original-digest-only"
        \\  },
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "missing-title",
        .expected_result = "accept",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "outputSelection": "explicit-only",
        \\    "payload": "byte-identical",
        \\    "result": "accept"
        \\  },
        \\  "id": "missing-title",
        \\  "mutation": {
        \\    "operation": "remove",
        \\    "target": "manifest.layers[0].annotations.org.opencontainers.image.title"
        \\  },
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "hostile-titles",
        .expected_result = "accept-explicit-output",
        .json = "{\n" ++
            "  \"baseLayout\": \"wabt-oci-v1.1\",\n" ++
            "  \"expected\": {\n" ++
            "    \"createdPaths\": [\n" ++
            "      \"explicit-output\"\n" ++
            "    ],\n" ++
            "    \"result\": \"accept-explicit-output\",\n" ++
            "    \"unsafeDiagnosticEcho\": false\n" ++
            "  },\n" ++
            "  \"id\": \"hostile-titles\",\n" ++
            "  \"mutation\": {\n" ++
            "    \"operation\": \"replace-each\",\n" ++
            "    \"target\": \"manifest.layers[0].annotations.org.opencontainers.image.title\",\n" ++
            "    \"values\": [\n" ++
            "      \"../../escape.wasm\",\n" ++
            "      \"/absolute/escape.wasm\",\n" ++
            "      \"C:\\\\escape.wasm\",\n" ++
            "      \"\\\\\\\\server\\\\share\\\\escape.wasm\",\n" ++
            "      \"" ++ (&@as([4096]u8, @splat('x'))) ++ "\"\n" ++
            "    ]\n" ++
            "  },\n" ++
            "  \"schema\": \"wabt.oci.negative-fixture\",\n" ++
            "  \"schemaVersion\": 1\n" ++
            "}\n",
    },
    .{
        .id = "layer-count",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "category": "invalid-layer-count",
        \\    "finalOutput": "absent",
        \\    "inspect": "accept-descriptors",
        \\    "pull": "reject"
        \\  },
        \\  "id": "layer-count",
        \\  "mutations": [
        \\    {
        \\      "operation": "replace",
        \\      "target": "manifest.layers",
        \\      "value": []
        \\    },
        \\    {
        \\      "count": 2,
        \\      "operation": "duplicate-first",
        \\      "target": "manifest.layers"
        \\    }
        \\  ],
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "tar-labeled-raw-wasm",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "category": "unsupported-layer-media-type",
        \\    "finalOutput": "absent",
        \\    "result": "reject",
        \\    "unpacked": false
        \\  },
        \\  "id": "tar-labeled-raw-wasm",
        \\  "mutation": {
        \\    "operation": "replace",
        \\    "target": "manifest.layers[0].mediaType",
        \\    "value": "application/vnd.oci.image.layer.v1.tar"
        \\  },
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "unsupported-media-types",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "category": "unsupported-profile-or-media-type",
        \\    "finalOutput": "absent",
        \\    "result": "reject"
        \\  },
        \\  "id": "unsupported-media-types",
        \\  "mutations": [
        \\    {
        \\      "operation": "replace",
        \\      "target": "root.mediaType",
        \\      "value": "application/vnd.example.root"
        \\    },
        \\    {
        \\      "operation": "replace",
        \\      "target": "manifest.config.mediaType",
        \\      "value": "application/vnd.example.config"
        \\    },
        \\    {
        \\      "operation": "replace",
        \\      "target": "manifest.layers[0].mediaType",
        \\      "value": "application/vnd.example.layer"
        \\    }
        \\  ],
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "index-extraction",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "index",
        \\  "expected": {
        \\    "copy": "preserve-complete-graph",
        \\    "finalOutput": "absent",
        \\    "inspect": "accept-complete-graph",
        \\    "platformSelection": false,
        \\    "pull": "reject"
        \\  },
        \\  "id": "index-extraction",
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
    .{
        .id = "interrupted-publication",
        .expected_result = "reject",
        .json =
        \\{
        \\  "baseLayout": "wabt-oci-v1.1",
        \\  "expected": {
        \\    "committedDigestPrinted": false,
        \\    "destinationTag": "absent-or-unchanged",
        \\    "finalOutput": "absent-or-byte-identical",
        \\    "result": "reject",
        \\    "rootPublishedBeforeDependencies": false
        \\  },
        \\  "failurePoints": [
        \\    "truncated-layer-download",
        \\    "interrupted-blob-upload",
        \\    "declined-cross-repository-mount",
        \\    "final-manifest-put",
        \\    "final-tag-put"
        \\  ],
        \\  "id": "interrupted-publication",
        \\  "schema": "wabt.oci.negative-fixture",
        \\  "schemaVersion": 1
        \\}
        \\
        ,
    },
};

const readme_text =
    \\# OCI interoperability fixtures
    \\
    \\These committed OCI layouts are untrusted test data. They prove only the
    \\transport/profile assertions recorded in `manifest.json`; they are not signed
    \\packages, runtime compatibility evidence, or a production-readiness claim.
    \\
    \\Offline verification:
    \\
    \\```sh
    \\scripts/oci/verify_interop_fixtures.sh
    \\```
    \\
    \\Pinned Linux/arm64 regeneration (network and a loopback-only disposable
    \\registry are required):
    \\
    \\```sh
    \\WABT_OCI_INTEROP_STATE_DIR=/d/wabt-worktrees/.cache/wabt-oci-interop \
    \\  scripts/oci/generate_interop_fixtures.sh
    \\```
    \\
    \\To execute the same live matrix without replacing producer metadata:
    \\
    \\```sh
    \\WABT_OCI_INTEROP_MODE=qualify \
    \\  WABT_OCI_INTEROP_STATE_DIR=/d/wabt-worktrees/.cache/wabt-oci-interop \
    \\  scripts/oci/generate_interop_fixtures.sh
    \\```
    \\
    \\The fixed producer timestamp is `2026-09-19T00:00:00Z`. External tools are
    \\fixture producers only and are never needed by WABT at runtime or by ordinary
    \\tests.
    \\
;

const generator_source_paths = [_][]const u8{
    "scripts/oci/fixed_realtime.c",
    "tools/oci_fixture_manifest.zig",
    "scripts/oci/generate_interop_fixtures.sh",
    "scripts/oci/verify_interop_fixtures.sh",
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fixture verification failed: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn sha256BytesHex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const FileHash = struct {
    size: u64,
    sha256: [64]u8,
};

fn sha256AndSizeFile(io: std.Io, path: []const u8) !FileHash {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const count = try file.readPositional(io, &.{&buf}, offset);
        if (count == 0) return error.UnexpectedEndOfFile;
        hasher.update(buf[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .size = size,
        .sha256 = std.fmt.bytesToHex(digest, .lower),
    };
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn copyFile(allocator: std.mem.Allocator, io: std.Io, src_path: []const u8, dst_path: []const u8) !void {
    const data = try readFileAlloc(allocator, io, src_path, 64 * 1024 * 1024);
    defer allocator.free(data);
    try writeFile(io, dst_path, data);
}

fn copyTree(allocator: std.mem.Allocator, io: std.Io, src_root: []const u8, dst_root: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dst_root);
    var files = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    try collectFiles(allocator, io, src_root, "", &files, null);
    for (files.items) |rel| {
        const src = try std.fs.path.join(allocator, &.{ src_root, rel });
        defer allocator.free(src);
        const dst = try std.fs.path.join(allocator, &.{ dst_root, rel });
        defer allocator.free(dst);
        try copyFile(allocator, io, src, dst);
    }
}

fn isLeftoverName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".wabt-oci") or
        std.mem.endsWith(u8, name, ".wabt-oci-bootstrap.lock") or
        std.mem.endsWith(u8, name, ".partial") or
        std.mem.endsWith(u8, name, ".tmp");
}

fn collectFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    rel_prefix: []const u8,
    files: *std.ArrayListUnmanaged([]u8),
    leftovers: ?*std.ArrayListUnmanaged([]u8),
) !void {
    const dir_path = if (rel_prefix.len == 0)
        try allocator.dupe(u8, root_path)
    else
        try std.fs.path.join(allocator, &.{ root_path, rel_prefix });
    defer allocator.free(dir_path);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const rel = if (rel_prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_prefix, entry.name });
        errdefer allocator.free(rel);

        if (leftovers) |leftover_list| {
            if (isLeftoverName(entry.name)) {
                try leftover_list.append(allocator, try allocator.dupe(u8, rel));
            }
        }

        switch (entry.kind) {
            .directory => {
                defer allocator.free(rel);
                try collectFiles(allocator, io, root_path, rel, files, leftovers);
            },
            .file => {
                try files.append(allocator, rel);
            },
            else => {
                allocator.free(rel);
            },
        }
    }
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const RootRecord = struct {
    media_type: []const u8,
    digest: []const u8,
    size: u64,
    tag: ?[]const u8,
};

const DescriptorEntry = struct {
    media_type: []const u8,
    digest: []const u8,
    size: u64,
    roles: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *DescriptorEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.media_type);
        allocator.free(self.digest);
        for (self.roles.items) |r| allocator.free(r);
        self.roles.deinit(allocator);
    }
};

const LayoutGraph = struct {
    roots: std.ArrayListUnmanaged(RootRecord) = .empty,
    descriptors: std.ArrayListUnmanaged(DescriptorEntry) = .empty,

    fn deinit(self: *LayoutGraph, allocator: std.mem.Allocator) void {
        for (self.roots.items) |r| {
            allocator.free(r.media_type);
            allocator.free(r.digest);
            if (r.tag) |t| allocator.free(t);
        }
        self.roots.deinit(allocator);
        for (self.descriptors.items) |*d| d.deinit(allocator);
        self.descriptors.deinit(allocator);
    }
};

fn descriptorLessThan(_: void, a: DescriptorEntry, b: DescriptorEntry) bool {
    return std.mem.lessThan(u8, a.digest, b.digest);
}

fn addGraphDescriptor(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(DescriptorEntry),
    media_type: []const u8,
    digest: []const u8,
    size: u64,
    role: []const u8,
) !void {
    for (entries.items) |*item| {
        if (std.mem.eql(u8, item.media_type, media_type) and
            std.mem.eql(u8, item.digest, digest) and
            item.size == size)
        {
            for (item.roles.items) |existing_role| {
                if (std.mem.eql(u8, existing_role, role)) return;
            }
            try item.roles.append(allocator, try allocator.dupe(u8, role));
            return;
        }
    }
    var entry = DescriptorEntry{
        .media_type = try allocator.dupe(u8, media_type),
        .digest = try allocator.dupe(u8, digest),
        .size = size,
    };
    errdefer entry.deinit(allocator);
    try entry.roles.append(allocator, try allocator.dupe(u8, role));
    try entries.append(allocator, entry);
}

fn readVerifiedBlob(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout_path: []const u8,
    digest: []const u8,
    expected_size: u64,
) ![]u8 {
    if (!std.mem.startsWith(u8, digest, "sha256:") or digest.len != 71) {
        return error.UnsupportedDigest;
    }
    const encoded = digest[7..];
    const blob_path = try std.fs.path.join(allocator, &.{ layout_path, "blobs", "sha256", encoded });
    defer allocator.free(blob_path);
    const data = try readFileAlloc(allocator, io, blob_path, 64 * 1024 * 1024);
    errdefer allocator.free(data);
    const hex = sha256BytesHex(data);
    if (data.len != expected_size or !std.mem.eql(u8, &hex, encoded)) {
        return error.CorruptDescriptor;
    }
    return data;
}

fn visitLayoutDocument(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout_path: []const u8,
    entries: *std.ArrayListUnmanaged(DescriptorEntry),
    visited_docs: *std.ArrayListUnmanaged([]u8),
    descriptor: std.json.ObjectMap,
    role: []const u8,
) !void {
    const media_type = (descriptor.get("mediaType") orelse return error.InvalidDescriptor).string;
    const digest = (descriptor.get("digest") orelse return error.InvalidDescriptor).string;
    const size: u64 = @intCast((descriptor.get("size") orelse return error.InvalidDescriptor).integer);

    try addGraphDescriptor(allocator, entries, media_type, digest, size, role);

    const doc_key = try std.fmt.allocPrint(allocator, "{s}|{s}|{d}", .{ media_type, digest, size });
    for (visited_docs.items) |existing| {
        if (std.mem.eql(u8, existing, doc_key)) {
            allocator.free(doc_key);
            return;
        }
    }
    try visited_docs.append(allocator, doc_key);

    const data = try readVerifiedBlob(allocator, io, layout_path, digest, size);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const doc = parsed.value.object;

    if (std.mem.eql(u8, media_type, "application/vnd.oci.image.index.v1+json")) {
        if (doc.get("manifests")) |manifests_val| {
            for (manifests_val.array.items) |child| {
                try visitLayoutDocument(
                    allocator,
                    io,
                    layout_path,
                    entries,
                    visited_docs,
                    child.object,
                    "child-manifest",
                );
            }
        }
    } else if (std.mem.eql(u8, media_type, "application/vnd.oci.image.manifest.v1+json")) {
        const config = (doc.get("config") orelse return error.InvalidManifest).object;
        try addGraphDescriptor(
            allocator,
            entries,
            config.get("mediaType").?.string,
            config.get("digest").?.string,
            @intCast(config.get("size").?.integer),
            "config",
        );
        if (doc.get("layers")) |layers_val| {
            for (layers_val.array.items) |layer_val| {
                const layer = layer_val.object;
                try addGraphDescriptor(
                    allocator,
                    entries,
                    layer.get("mediaType").?.string,
                    layer.get("digest").?.string,
                    @intCast(layer.get("size").?.integer),
                    "payload",
                );
            }
        }
    } else {
        return error.UnsupportedDocumentMediaType;
    }
}

fn graphForLayout(allocator: std.mem.Allocator, io: std.Io, layout_path: []const u8) !LayoutGraph {
    const index_path = try std.fs.path.join(allocator, &.{ layout_path, "index.json" });
    defer allocator.free(index_path);
    const index_bytes = try readFileAlloc(allocator, io, index_path, 4 * 1024 * 1024);
    defer allocator.free(index_bytes);

    var parsed_index = try std.json.parseFromSlice(std.json.Value, allocator, index_bytes, .{});
    defer parsed_index.deinit();
    const index_obj = parsed_index.value.object;
    const manifests_val = index_obj.get("manifests") orelse return error.MissingLayoutRoots;
    if (manifests_val != .array or manifests_val.array.items.len == 0) {
        return error.MissingLayoutRoots;
    }

    var graph = LayoutGraph{};
    errdefer graph.deinit(allocator);

    var visited_docs = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (visited_docs.items) |k| allocator.free(k);
        visited_docs.deinit(allocator);
    }

    for (manifests_val.array.items) |root_val| {
        const root = root_val.object;
        try visitLayoutDocument(
            allocator,
            io,
            layout_path,
            &graph.descriptors,
            &visited_docs,
            root,
            "root",
        );
        const tag: ?[]u8 = if (root.get("annotations")) |ann_val| blk: {
            if (ann_val == .object) {
                if (ann_val.object.get("org.opencontainers.image.ref.name")) |ref_val| {
                    if (ref_val == .string) break :blk try allocator.dupe(u8, ref_val.string);
                }
            }
            break :blk null;
        } else null;

        try graph.roots.append(allocator, .{
            .media_type = try allocator.dupe(u8, root.get("mediaType").?.string),
            .digest = try allocator.dupe(u8, root.get("digest").?.string),
            .size = @intCast(root.get("size").?.integer),
            .tag = tag,
        });
    }

    for (graph.descriptors.items) |*item| {
        const blob = try readVerifiedBlob(allocator, io, layout_path, item.digest, item.size);
        allocator.free(blob);
        std.mem.sort([]const u8, item.roles.items, {}, lessThanSlice);
    }
    std.mem.sort(DescriptorEntry, graph.descriptors.items, {}, descriptorLessThan);
    return graph;
}

fn verifyTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    target_path: []const u8,
    maybe_repo_path: ?[]const u8,
) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ target_path, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = try readFileAlloc(allocator, io, manifest_path, 16 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    const manifest = parsed.value.object;

    if (!std.mem.eql(u8, manifest.get("schema").?.string, schema_name) or
        manifest.get("schemaVersion").?.integer != 1)
    {
        fail("unsupported fixture manifest", .{});
    }
    if (!std.mem.eql(u8, manifest.get("fixedCreated").?.string, fixed_created)) {
        fail("fixture timestamp drift", .{});
    }
    if (!std.mem.eql(u8, manifest.get("executionPlatform").?.string, "linux/arm64")) {
        fail("fixture producer platform drift", .{});
    }

    const repo_path = if (maybe_repo_path) |r|
        try allocator.dupe(u8, r)
    else
        try std.fs.path.resolve(allocator, &.{ target_path, "..", "..", ".." });
    defer allocator.free(repo_path);

    const generator = manifest.get("generator").?.object;
    if (!std.mem.eql(u8, generator.get("ordinaryVerification").?.string, "offline")) {
        fail("ordinary fixture verification must remain offline", .{});
    }
    const sources = generator.get("sources").?.array.items;
    if (sources.len != generator_source_paths.len) {
        fail("fixture generator source list length drift", .{});
    }
    for (sources) |src_val| {
        const src = src_val.object;
        const rel_path = src.get("path").?.string;
        const expected_size: u64 = @intCast(src.get("size").?.integer);
        const expected_sha = src.get("sha256").?.string;
        const full_path = try std.fs.path.join(allocator, &.{ repo_path, rel_path });
        defer allocator.free(full_path);
        const info = sha256AndSizeFile(io, full_path) catch {
            fail("fixture generator source missing: {s}", .{rel_path});
        };
        if (info.size != expected_size or !std.mem.eql(u8, &info.sha256, expected_sha)) {
            fail("fixture generator source drift: {s}", .{rel_path});
        }
    }

    const producers = manifest.get("producers").?.object;
    const RequiredPin = struct {
        producer: []const u8,
        field: []const u8,
        expected: []const u8,
    };
    const required_pins = [_]RequiredPin{
        .{ .producer = "oras", .field = "version", .expected = "1.3.4" },
        .{ .producer = "oras", .field = "commit", .expected = "db9e29505c3059f2b8fde34ae8cae266c5c765e9" },
        .{ .producer = "wkg", .field = "version", .expected = "0.16.1" },
        .{ .producer = "wkg", .field = "sourceRevision", .expected = "5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a" },
        .{ .producer = "wkg", .field = "cargoLockSha256", .expected = "bf465c989fa26cb06778624fd2de843ca5d6318b4a58418c9e392e13dc02d732" },
        .{ .producer = "oci-wasm", .field = "version", .expected = "0.6.0" },
        .{ .producer = "oci-wasm", .field = "crateChecksumSha256", .expected = "87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21" },
        .{ .producer = "oci-wasm", .field = "tagCommit", .expected = "8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd" },
        .{ .producer = "registry", .field = "version", .expected = "3.1.1" },
    };
    for (required_pins) |pin| {
        const actual = producers.get(pin.producer).?.object.get(pin.field).?.string;
        if (!std.mem.eql(u8, actual, pin.expected)) {
            fail("{s} {s} drift", .{ pin.producer, pin.field });
        }
    }

    const profiles = manifest.get("profiles").?.object;
    const comp_rel = profiles.get("component").?.object.get("path").?.string;
    const comp_path = try std.fs.path.join(allocator, &.{ target_path, comp_rel });
    defer allocator.free(comp_path);
    const comp_info = try sha256AndSizeFile(io, comp_path);
    if (comp_info.size != payload_size or !std.mem.eql(u8, &comp_info.sha256, payload_sha256)) {
        fail("component profile drift", .{});
    }

    const core_rel = profiles.get("core").?.object.get("path").?.string;
    const core_path = try std.fs.path.join(allocator, &.{ target_path, core_rel });
    defer allocator.free(core_path);
    const core_bytes = try readFileAlloc(allocator, io, core_path, 64);
    defer allocator.free(core_bytes);
    if (!std.mem.eql(u8, core_bytes, core_wasm_bytes)) {
        fail("core profile drift", .{});
    }

    var actual_files = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (actual_files.items) |p| allocator.free(p);
        actual_files.deinit(allocator);
    }
    var leftovers = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (leftovers.items) |p| allocator.free(p);
        leftovers.deinit(allocator);
    }
    try collectFiles(allocator, io, target_path, "", &actual_files, &leftovers);
    if (leftovers.items.len > 0) {
        fail("partial fixture output remains: {s}", .{leftovers.items[0]});
    }

    var filtered_files = std.ArrayListUnmanaged([]const u8).empty;
    defer filtered_files.deinit(allocator);
    for (actual_files.items) |rel| {
        if (std.mem.eql(u8, std.fs.path.basename(rel), "manifest.json")) continue;
        try filtered_files.append(allocator, rel);
    }
    std.mem.sort([]const u8, filtered_files.items, {}, lessThanSlice);

    const fixture_files = manifest.get("fixtureFiles").?.array.items;
    if (fixture_files.len != filtered_files.items.len) {
        fail(
            "fixture file set drift: expected {d} files, found {d}",
            .{ fixture_files.len, filtered_files.items.len },
        );
    }
    for (fixture_files, filtered_files.items) |expected_val, actual_rel| {
        const expected_obj = expected_val.object;
        const expected_rel = expected_obj.get("path").?.string;
        if (!std.mem.eql(u8, expected_rel, actual_rel)) {
            fail("fixture file set drift: expected {s}, found {s}", .{ expected_rel, actual_rel });
        }
        const full = try std.fs.path.join(allocator, &.{ target_path, actual_rel });
        defer allocator.free(full);
        const info = try sha256AndSizeFile(io, full);
        const expected_size: u64 = @intCast(expected_obj.get("size").?.integer);
        const expected_sha = expected_obj.get("sha256").?.string;
        if (info.size != expected_size or !std.mem.eql(u8, &info.sha256, expected_sha)) {
            fail("fixture file drift: {s}", .{actual_rel});
        }
    }

    const layouts = manifest.get("layouts").?.object;
    if (layouts.count() != layout_names.len) {
        fail("layout set drift", .{});
    }
    for (layout_names) |layout_name| {
        const expected_layout_val = layouts.get(layout_name) orelse fail("layout set drift: missing {s}", .{layout_name});
        const expected_layout = expected_layout_val.object;
        const layout_dir = try std.fs.path.join(allocator, &.{ target_path, "layouts", layout_name });
        defer allocator.free(layout_dir);

        var actual_graph = graphForLayout(allocator, io, layout_dir) catch |err| {
            fail("{s}: graph verification error: {s}", .{ layout_name, @errorName(err) });
        };
        defer actual_graph.deinit(allocator);

        const expected_roots = expected_layout.get("roots").?.array.items;
        if (actual_graph.roots.items.len != expected_roots.len) {
            fail("{s}: root drift", .{layout_name});
        }
        for (actual_graph.roots.items, expected_roots) |act_r, exp_r_val| {
            const exp_r = exp_r_val.object;
            if (!std.mem.eql(u8, act_r.media_type, exp_r.get("mediaType").?.string) or
                !std.mem.eql(u8, act_r.digest, exp_r.get("digest").?.string) or
                act_r.size != @as(u64, @intCast(exp_r.get("size").?.integer)))
            {
                fail("{s}: root drift", .{layout_name});
            }
            const exp_tag_val = exp_r.get("tag") orelse .null;
            switch (exp_tag_val) {
                .null => if (act_r.tag != null) fail("{s}: root tag drift", .{layout_name}),
                .string => |s| if (act_r.tag == null or !std.mem.eql(u8, act_r.tag.?, s))
                    fail("{s}: root tag drift", .{layout_name}),
                else => fail("{s}: root tag drift", .{layout_name}),
            }
        }

        const expected_descs = expected_layout.get("descriptors").?.array.items;
        if (actual_graph.descriptors.items.len != expected_descs.len) {
            fail("{s}: descriptor drift", .{layout_name});
        }
        for (actual_graph.descriptors.items, expected_descs) |act_d, exp_d_val| {
            const exp_d = exp_d_val.object;
            if (!std.mem.eql(u8, act_d.media_type, exp_d.get("mediaType").?.string) or
                !std.mem.eql(u8, act_d.digest, exp_d.get("digest").?.string) or
                act_d.size != @as(u64, @intCast(exp_d.get("size").?.integer)))
            {
                fail("{s}: descriptor drift", .{layout_name});
            }
            const exp_roles = exp_d.get("roles").?.array.items;
            if (act_d.roles.items.len != exp_roles.len) {
                fail("{s}: descriptor roles drift", .{layout_name});
            }
            for (act_d.roles.items, exp_roles) |act_role, exp_role_val| {
                if (!std.mem.eql(u8, act_role, exp_role_val.string)) {
                    fail("{s}: descriptor roles drift", .{layout_name});
                }
            }
        }

        const commands_val = expected_layout.get("commands") orelse fail("{s}: missing generation argv", .{layout_name});
        if (commands_val != .array or commands_val.array.items.len == 0) {
            fail("{s}: missing generation argv", .{layout_name});
        }
        for (commands_val.array.items) |cmd_val| {
            if (cmd_val != .array or cmd_val.array.items.len == 0) {
                fail("{s}: missing generation argv", .{layout_name});
            }
        }
    }

    const neg_items = manifest.get("negativeCases").?.array.items;
    if (neg_items.len != negative_cases.len) {
        fail("negative fixture set drift", .{});
    }
    for (negative_cases) |spec| {
        var found_path: ?[]const u8 = null;
        for (neg_items) |item_val| {
            const obj = item_val.object;
            if (std.mem.eql(u8, obj.get("id").?.string, spec.id)) {
                found_path = obj.get("path").?.string;
                break;
            }
        }
        const rel_path = found_path orelse fail("negative fixture set drift: missing {s}", .{spec.id});
        const neg_full = try std.fs.path.join(allocator, &.{ target_path, rel_path });
        defer allocator.free(neg_full);
        const neg_bytes = try readFileAlloc(allocator, io, neg_full, 1024 * 1024);
        defer allocator.free(neg_bytes);

        var neg_parsed = try std.json.parseFromSlice(std.json.Value, allocator, neg_bytes, .{});
        defer neg_parsed.deinit();
        const neg_doc = neg_parsed.value.object;
        if (!std.mem.eql(u8, neg_doc.get("schema").?.string, negative_schema_name) or
            neg_doc.get("schemaVersion").?.integer != 1 or
            !std.mem.eql(u8, neg_doc.get("id").?.string, spec.id))
        {
            fail("invalid negative fixture {s}", .{spec.id});
        }
    }

    const positive_matrix_ids = [_][]const u8{
        "wkg-to-wabt",
        "wabt-wasm-v0-to-wkg",
        "oras-oci-1.0-to-wabt",
        "oras-oci-1.1-to-wabt",
        "wabt-generic-to-oras",
        "wabt-generic-to-wkg",
        "digest-preserving-copies",
        "index-preservation-and-extraction-rejection",
    };
    const matrix_items = manifest.get("matrix").?.array.items;
    if (matrix_items.len != positive_matrix_ids.len + negative_cases.len) {
        fail("fixture matrix drift", .{});
    }
    for (positive_matrix_ids) |req_id| {
        var found = false;
        for (matrix_items) |item_val| {
            if (std.mem.eql(u8, item_val.object.get("id").?.string, req_id)) {
                found = true;
                break;
            }
        }
        if (!found) fail("fixture matrix drift: missing {s}", .{req_id});
    }
    for (negative_cases) |spec| {
        const neg_id = try std.fmt.allocPrint(allocator, "negative-{s}", .{spec.id});
        defer allocator.free(neg_id);
        var found = false;
        for (matrix_items) |item_val| {
            if (std.mem.eql(u8, item_val.object.get("id").?.string, neg_id)) {
                found = true;
                break;
            }
        }
        if (!found) fail("fixture matrix drift: missing {s}", .{neg_id});
    }
    for (matrix_items) |item_val| {
        const result_str = item_val.object.get("result").?.string;
        if (!std.mem.startsWith(u8, result_str, "pass")) {
            fail("fixture matrix contains a non-passing result", .{});
        }
    }
}

fn assembleCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    work_path: []const u8,
) ![]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ work_path, "candidate" });
    errdefer allocator.free(candidate);

    std.Io.Dir.cwd().deleteTree(io, candidate) catch {};

    const profiles_dir = try std.fs.path.join(allocator, &.{ candidate, "profiles" });
    defer allocator.free(profiles_dir);
    const layouts_dir = try std.fs.path.join(allocator, &.{ candidate, "layouts" });
    defer allocator.free(layouts_dir);
    const negative_dir = try std.fs.path.join(allocator, &.{ candidate, "negative" });
    defer allocator.free(negative_dir);

    try std.Io.Dir.cwd().createDirPath(io, profiles_dir);
    try std.Io.Dir.cwd().createDirPath(io, layouts_dir);
    try std.Io.Dir.cwd().createDirPath(io, negative_dir);

    const component_src = try std.fs.path.join(
        allocator,
        &.{ repo_path, "src", "component", "fixtures", "stdio-echo.wasm" },
    );
    defer allocator.free(component_src);
    const comp_info = try sha256AndSizeFile(io, component_src);
    if (comp_info.size != payload_size or !std.mem.eql(u8, &comp_info.sha256, payload_sha256)) {
        fail("component payload changed", .{});
    }
    const component_dst = try std.fs.path.join(allocator, &.{ profiles_dir, "component.wasm" });
    defer allocator.free(component_dst);
    try copyFile(allocator, io, component_src, component_dst);

    const core_dst = try std.fs.path.join(allocator, &.{ profiles_dir, "core.wasm" });
    defer allocator.free(core_dst);
    try writeFile(io, core_dst, core_wasm_bytes);

    for (layout_names) |name| {
        const src_layout = try std.fs.path.join(allocator, &.{ work_path, "layouts", name });
        defer allocator.free(src_layout);
        const dst_layout = try std.fs.path.join(allocator, &.{ layouts_dir, name });
        defer allocator.free(dst_layout);
        var dir = std.Io.Dir.cwd().openDir(io, src_layout, .{}) catch {
            fail("missing generated layout {s}", .{name});
        };
        dir.close(io);
        try copyTree(allocator, io, src_layout, dst_layout);
    }

    for (negative_cases) |spec| {
        const neg_file = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ negative_dir, spec.id });
        defer allocator.free(neg_file);
        try writeFile(io, neg_file, spec.json);
    }

    const readme_path = try std.fs.path.join(allocator, &.{ candidate, "README.md" });
    defer allocator.free(readme_path);
    try writeFile(io, readme_path, readme_text);

    return candidate;
}

fn compareTrees(
    allocator: std.mem.Allocator,
    io: std.Io,
    expected_root: []const u8,
    actual_root: []const u8,
) !void {
    var expected_files = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (expected_files.items) |p| allocator.free(p);
        expected_files.deinit(allocator);
    }
    var actual_files = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (actual_files.items) |p| allocator.free(p);
        actual_files.deinit(allocator);
    }

    try collectFiles(allocator, io, expected_root, "", &expected_files, null);
    try collectFiles(allocator, io, actual_root, "", &actual_files, null);

    std.mem.sort([]u8, expected_files.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    std.mem.sort([]u8, actual_files.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    if (expected_files.items.len != actual_files.items.len) {
        fail(
            "regeneration file set drift: expected {d} files, got {d}",
            .{ expected_files.items.len, actual_files.items.len },
        );
    }
    for (expected_files.items, actual_files.items) |exp_rel, act_rel| {
        if (!std.mem.eql(u8, exp_rel, act_rel)) {
            fail("regeneration file set drift: {s} vs {s}", .{ exp_rel, act_rel });
        }
        const exp_path = try std.fs.path.join(allocator, &.{ expected_root, exp_rel });
        defer allocator.free(exp_path);
        const act_path = try std.fs.path.join(allocator, &.{ actual_root, act_rel });
        defer allocator.free(act_path);
        const exp_bytes = try readFileAlloc(allocator, io, exp_path, 64 * 1024 * 1024);
        defer allocator.free(exp_bytes);
        const act_bytes = try readFileAlloc(allocator, io, act_path, 64 * 1024 * 1024);
        defer allocator.free(act_bytes);
        if (!std.mem.eql(u8, exp_bytes, act_bytes)) {
            fail("regeneration byte drift: {s}", .{exp_rel});
        }
    }
}

fn runOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environ_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    const raw = if (result.stdout.len > 0) result.stdout else result.stderr;
    return allocator.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

fn findOnPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    exe_name: []const u8,
) ![]u8 {
    const path_env = environ_map.get("PATH") orelse return error.ExecutableNotFound;
    var iter = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);
    while (iter.next()) |dir_entry| {
        const candidate = try std.fs.path.join(allocator, &.{ dir_entry, exe_name });
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |stat| {
            if (stat.kind == .file or stat.kind == .sym_link) {
                return candidate;
            }
        } else |_| {}
        allocator.free(candidate);
    }
    return error.ExecutableNotFound;
}

fn verifyQualificationProducers(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    repo_path: []const u8,
    tools_path: []const u8,
    manifest: std.json.ObjectMap,
) !void {
    const producers = manifest.get("producers").?.object;
    const tool_bin = try std.fs.path.join(allocator, &.{ tools_path, "bin" });
    defer allocator.free(tool_bin);
    const source_dir = try std.fs.path.resolve(
        allocator,
        &.{ tools_path, "..", "cache", "source", "wasm-pkg-tools" },
    );
    defer allocator.free(source_dir);
    const toolchain_bin = try std.fs.path.join(
        allocator,
        &.{ tools_path, "rustup", "toolchains", "1.97.0-aarch64-unknown-linux-gnu", "bin" },
    );
    defer allocator.free(toolchain_bin);

    const oras_bin = try std.fs.path.join(allocator, &.{ tool_bin, "oras" });
    defer allocator.free(oras_bin);
    const registry_bin = try std.fs.path.join(allocator, &.{ tool_bin, "registry" });
    defer allocator.free(registry_bin);
    const rustup_bin = try std.fs.path.join(allocator, &.{ tool_bin, "rustup-init" });
    defer allocator.free(rustup_bin);
    const wkg_bin = try std.fs.path.join(allocator, &.{ tool_bin, "wkg" });
    defer allocator.free(wkg_bin);
    const rustc_bin = try std.fs.path.join(allocator, &.{ toolchain_bin, "rustc" });
    defer allocator.free(rustc_bin);
    const cargo_bin = try std.fs.path.join(allocator, &.{ toolchain_bin, "cargo" });
    defer allocator.free(cargo_bin);
    const zig_bin = try findOnPath(allocator, io, environ_map, "zig");
    defer allocator.free(zig_bin);

    const oras_obj = producers.get("oras").?.object;
    const registry_obj = producers.get("registry").?.object;
    const rustup_obj = producers.get("rustup").?.object;
    const wkg_obj = producers.get("wkg").?.object;
    const wkg_build = wkg_obj.get("build").?.object;
    const fixed_rt_obj = producers.get("fixedRealtime").?.object;

    const ExpectedBinary = struct {
        path: []const u8,
        expected_sha: []const u8,
    };
    const expected_binaries = [_]ExpectedBinary{
        .{ .path = oras_bin, .expected_sha = oras_obj.get("binary").?.object.get("sha256").?.string },
        .{ .path = registry_bin, .expected_sha = registry_obj.get("binary").?.object.get("sha256").?.string },
        .{ .path = rustup_bin, .expected_sha = rustup_obj.get("binarySha256").?.string },
        .{ .path = rustc_bin, .expected_sha = wkg_build.get("compiler").?.object.get("sha256").?.string },
        .{ .path = cargo_bin, .expected_sha = wkg_build.get("cargo").?.object.get("sha256").?.string },
        .{ .path = zig_bin, .expected_sha = wkg_build.get("zigLinker").?.object.get("sha256").?.string },
    };
    for (expected_binaries) |item| {
        const info = sha256AndSizeFile(io, item.path) catch {
            fail("qualification producer binary missing: {s}", .{item.path});
        };
        if (!std.mem.eql(u8, &info.sha256, item.expected_sha)) {
            fail("qualification producer binary drift: {s}", .{item.path});
        }
    }

    const oras_ver_out = try runOutput(allocator, io, &.{ oras_bin, "version" }, environ_map);
    defer allocator.free(oras_ver_out);
    const expected_oras_lines = oras_obj.get("binary").?.object.get("versionOutput").?.array.items;
    var line_it = std.mem.splitScalar(u8, oras_ver_out, '\n');
    var line_idx: usize = 0;
    while (line_it.next()) |line| : (line_idx += 1) {
        if (line_idx >= expected_oras_lines.len or
            !std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), expected_oras_lines[line_idx].string))
        {
            fail("ORAS version output drift", .{});
        }
    }
    if (line_idx != expected_oras_lines.len) {
        fail("ORAS version output drift", .{});
    }

    const wkg_ver_out = try runOutput(allocator, io, &.{ wkg_bin, "--version" }, environ_map);
    defer allocator.free(wkg_ver_out);
    if (!std.mem.eql(u8, wkg_ver_out, "wkg 0.16.1")) {
        fail("wkg version output drift", .{});
    }

    const fixed_src_rel = fixed_rt_obj.get("source").?.object.get("path").?.string;
    const fixed_src_sha = fixed_rt_obj.get("source").?.object.get("sha256").?.string;
    const fixed_src_path = try std.fs.path.join(allocator, &.{ repo_path, fixed_src_rel });
    defer allocator.free(fixed_src_path);
    const fixed_src_info = try sha256AndSizeFile(io, fixed_src_path);
    if (!std.mem.eql(u8, &fixed_src_info.sha256, fixed_src_sha)) {
        fail("fixed realtime source drift", .{});
    }

    const reg_ver_out = try runOutput(allocator, io, &.{ registry_bin, "--version" }, environ_map);
    defer allocator.free(reg_ver_out);
    if (std.mem.indexOf(u8, reg_ver_out, " 3.1.1") == null) {
        fail("registry version output drift", .{});
    }

    const zig_ver_out = try runOutput(allocator, io, &.{ "zig", "version" }, environ_map);
    defer allocator.free(zig_ver_out);
    if (!std.mem.eql(u8, zig_ver_out, "0.17.0")) {
        fail("Zig version output drift", .{});
    }

    const rustc_ver_out = try runOutput(allocator, io, &.{ rustc_bin, "--version" }, environ_map);
    defer allocator.free(rustc_ver_out);
    if (!std.mem.startsWith(u8, rustc_ver_out, "rustc 1.97.0 ")) {
        fail("Rust compiler version drift", .{});
    }

    const cargo_ver_out = try runOutput(allocator, io, &.{ cargo_bin, "--version" }, environ_map);
    defer allocator.free(cargo_ver_out);
    if (!std.mem.startsWith(u8, cargo_ver_out, "cargo 1.97.0 ")) {
        fail("Cargo version drift", .{});
    }

    const cargo_lock_path = try std.fs.path.join(allocator, &.{ source_dir, "Cargo.lock" });
    defer allocator.free(cargo_lock_path);
    const cargo_lock_info = try sha256AndSizeFile(io, cargo_lock_path);
    if (!std.mem.eql(u8, &cargo_lock_info.sha256, wkg_obj.get("cargoLockSha256").?.string)) {
        fail("wkg Cargo.lock changed", .{});
    }

    const head_rev = try runOutput(
        allocator,
        io,
        &.{ "git", "-C", source_dir, "rev-parse", "HEAD" },
        environ_map,
    );
    defer allocator.free(head_rev);
    if (!std.mem.eql(u8, head_rev, wkg_obj.get("sourceRevision").?.string)) {
        fail("wkg source revision changed", .{});
    }

    const head_tree = try runOutput(
        allocator,
        io,
        &.{ "git", "-C", source_dir, "rev-parse", "HEAD^{tree}" },
        environ_map,
    );
    defer allocator.free(head_tree);
    if (!std.mem.eql(u8, head_tree, wkg_obj.get("sourceTree").?.string)) {
        fail("wkg source tree changed", .{});
    }

    const wabt_bin = try std.fs.path.join(allocator, &.{ repo_path, "zig-out", "bin", "wabt" });
    defer allocator.free(wabt_bin);
    const wabt_ver_out = try runOutput(allocator, io, &.{ wabt_bin, "version" }, environ_map);
    defer allocator.free(wabt_ver_out);
    if (!std.mem.eql(u8, wabt_ver_out, "wabt oci-fixtures")) {
        fail("WABT qualification build version drift", .{});
    }
}

fn writeJsonString(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try out.appendSlice(allocator, esc);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

fn writeIndent(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, level: usize) !void {
    try out.appendNTimes(allocator, ' ', level * 2);
}

fn writeFormattedJsonValue(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: std.json.Value,
    indent_level: usize,
) !void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
            try out.appendSlice(allocator, s);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
            try out.appendSlice(allocator, s);
        },
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try writeJsonString(out, allocator, s),
        .array => |arr| {
            if (arr.items.len == 0) {
                try out.appendSlice(allocator, "[]");
                return;
            }
            try out.appendSlice(allocator, "[\n");
            for (arr.items, 0..) |item, idx| {
                try writeIndent(out, allocator, indent_level + 1);
                try writeFormattedJsonValue(out, allocator, item, indent_level + 1);
                if (idx + 1 < arr.items.len) try out.append(allocator, ',');
                try out.append(allocator, '\n');
            }
            try writeIndent(out, allocator, indent_level);
            try out.append(allocator, ']');
        },
        .object => |obj| {
            if (obj.count() == 0) {
                try out.appendSlice(allocator, "{}");
                return;
            }
            const keys = try allocator.alloc([]const u8, obj.count());
            defer allocator.free(keys);
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                keys[i] = entry.key_ptr.*;
            }
            std.mem.sort([]const u8, keys, {}, lessThanSlice);

            try out.appendSlice(allocator, "{\n");
            for (keys, 0..) |k, idx| {
                try writeIndent(out, allocator, indent_level + 1);
                try writeJsonString(out, allocator, k);
                try out.appendSlice(allocator, ": ");
                try writeFormattedJsonValue(out, allocator, obj.get(k).?, indent_level + 1);
                if (idx + 1 < keys.len) try out.append(allocator, ',');
                try out.append(allocator, '\n');
            }
            try writeIndent(out, allocator, indent_level);
            try out.append(allocator, '}');
        },
    }
}

fn updateManifestGeneratorSourcesInTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_path: []const u8,
    manifest_path: []const u8,
) !void {
    const manifest_bytes = try readFileAlloc(allocator, io, manifest_path, 16 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ar, manifest_bytes, .{});
    var root_obj = parsed.object;
    var gen_obj = root_obj.getPtr("generator").?.object;

    var new_sources = std.json.Array.init(ar);
    for (generator_source_paths) |rel_path| {
        const full = try std.fs.path.join(ar, &.{ repo_path, rel_path });
        const info = try sha256AndSizeFile(io, full);
        var entry = std.json.ObjectMap.empty;
        try entry.put(ar, "path", .{ .string = rel_path });
        try entry.put(ar, "sha256", .{ .string = try ar.dupe(u8, &info.sha256) });
        try entry.put(ar, "size", .{ .integer = @intCast(info.size) });
        try new_sources.append(.{ .object = entry });
    }
    try gen_obj.put(ar, "sources", .{ .array = new_sources });
    try root_obj.put(ar, "generator", .{ .object = gen_obj });

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    try writeFormattedJsonValue(&out, allocator, .{ .object = root_obj }, 0);
    try out.append(allocator, '\n');
    try writeFile(io, manifest_path, out.items);
}

fn updateProducerBinaryRecord(
    ar: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    obj: *std.json.ObjectMap,
    bin_path: []const u8,
    argv: []const []const u8,
    prefix: ?[]const u8,
) !void {
    const info = try sha256AndSizeFile(io, bin_path);
    const out_str = try runOutput(ar, io, argv, environ_map);
    const full_out = if (prefix) |p| blk: {
        const space_idx = std.mem.indexOfScalar(u8, out_str, ' ') orelse 0;
        const rest = if (space_idx > 0) out_str[space_idx + 1 ..] else out_str;
        break :blk try std.fmt.allocPrint(ar, "{s}{s}", .{ p, rest });
    } else out_str;

    var lines_arr = std.json.Array.init(ar);
    var it = std.mem.splitScalar(u8, full_out, '\n');
    while (it.next()) |line| {
        try lines_arr.append(.{ .string = try ar.dupe(u8, std.mem.trimEnd(u8, line, "\r")) });
    }
    try obj.put(ar, "sha256", .{ .string = try ar.dupe(u8, &info.sha256) });
    try obj.put(ar, "versionOutput", .{ .array = lines_arr });
}

fn publishCandidate(io: std.Io, candidate: []const u8, target: []const u8) !void {
    var arena_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const backup = try std.fmt.allocPrint(fba.allocator(), "{s}.previous", .{target});

    std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    if (std.Io.Dir.cwd().statFile(io, target, .{})) |_| {
        try std.Io.Dir.rename(std.Io.Dir.cwd(), target, std.Io.Dir.cwd(), backup, io);
    } else |_| {}

    std.Io.Dir.rename(std.Io.Dir.cwd(), candidate, std.Io.Dir.cwd(), target, io) catch |err| {
        if (std.Io.Dir.cwd().statFile(io, backup, .{})) |_| {
            std.Io.Dir.rename(std.Io.Dir.cwd(), backup, std.Io.Dir.cwd(), target, io) catch {};
        } else |_| {}
        return err;
    };
    std.Io.Dir.cwd().deleteTree(io, backup) catch {};
}

fn runQualify(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    repo_path: []const u8,
    work_path: []const u8,
    tools_path: []const u8,
) !void {
    const target = try std.fs.path.join(allocator, &.{ repo_path, "src", "fixtures", "oci" });
    defer allocator.free(target);
    try verifyTree(allocator, io, target, repo_path);

    const candidate = try assembleCandidate(allocator, io, repo_path, work_path);
    defer {
        std.Io.Dir.cwd().deleteTree(io, candidate) catch {};
        allocator.free(candidate);
    }

    const target_manifest = try std.fs.path.join(allocator, &.{ target, "manifest.json" });
    defer allocator.free(target_manifest);
    const candidate_manifest = try std.fs.path.join(allocator, &.{ candidate, "manifest.json" });
    defer allocator.free(candidate_manifest);
    try copyFile(allocator, io, target_manifest, candidate_manifest);

    try compareTrees(allocator, io, target, candidate);

    const manifest_bytes = try readFileAlloc(allocator, io, target_manifest, 16 * 1024 * 1024);
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed.deinit();

    try verifyQualificationProducers(
        allocator,
        io,
        environ_map,
        repo_path,
        tools_path,
        parsed.value.object,
    );
}

fn runWrite(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    repo_path: []const u8,
    work_path: []const u8,
    tools_path: []const u8,
    update: bool,
) !void {
    const target = try std.fs.path.join(allocator, &.{ repo_path, "src", "fixtures", "oci" });
    defer allocator.free(target);
    const candidate = try assembleCandidate(allocator, io, repo_path, work_path);
    defer allocator.free(candidate);

    const target_manifest = try std.fs.path.join(allocator, &.{ target, "manifest.json" });
    defer allocator.free(target_manifest);
    const candidate_manifest = try std.fs.path.join(allocator, &.{ candidate, "manifest.json" });
    defer allocator.free(candidate_manifest);

    const base_bytes = try readFileAlloc(allocator, io, target_manifest, 16 * 1024 * 1024);
    defer allocator.free(base_bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ar, base_bytes, .{});
    var root_obj = parsed.object;

    // Update producer binary records and generator sources from live environment.
    const tool_bin = try std.fs.path.join(ar, &.{ tools_path, "bin" });
    const toolchain_bin = try std.fs.path.join(
        ar,
        &.{ tools_path, "rustup", "toolchains", "1.97.0-aarch64-unknown-linux-gnu", "bin" },
    );
    const zig_bin = try findOnPath(ar, io, environ_map, "zig");
    const wabt_bin = try std.fs.path.join(ar, &.{ repo_path, "zig-out", "bin", "wabt" });

    var producers = root_obj.getPtr("producers").?.object;
    var oras_obj = producers.getPtr("oras").?.object;
    var oras_bin_obj = oras_obj.getPtr("binary").?.object;
    const oras_bin = try std.fs.path.join(ar, &.{ tool_bin, "oras" });
    try updateProducerBinaryRecord(ar, io, environ_map, &oras_bin_obj, oras_bin, &.{ oras_bin, "version" }, null);
    try oras_obj.put(ar, "binary", .{ .object = oras_bin_obj });
    try producers.put(ar, "oras", .{ .object = oras_obj });

    var wkg_obj = producers.getPtr("wkg").?.object;
    var wkg_bin_obj = wkg_obj.getPtr("binary").?.object;
    const wkg_bin = try std.fs.path.join(ar, &.{ tool_bin, "wkg" });
    try updateProducerBinaryRecord(ar, io, environ_map, &wkg_bin_obj, wkg_bin, &.{ wkg_bin, "--version" }, null);
    try wkg_obj.put(ar, "binary", .{ .object = wkg_bin_obj });

    var wkg_build = wkg_obj.getPtr("build").?.object;
    var compiler_obj = wkg_build.getPtr("compiler").?.object;
    const rustc_bin = try std.fs.path.join(ar, &.{ toolchain_bin, "rustc" });
    try updateProducerBinaryRecord(ar, io, environ_map, &compiler_obj, rustc_bin, &.{ rustc_bin, "--version", "--verbose" }, null);
    try wkg_build.put(ar, "compiler", .{ .object = compiler_obj });

    var cargo_obj = wkg_build.getPtr("cargo").?.object;
    const cargo_bin = try std.fs.path.join(ar, &.{ toolchain_bin, "cargo" });
    try updateProducerBinaryRecord(ar, io, environ_map, &cargo_obj, cargo_bin, &.{ cargo_bin, "--version", "--verbose" }, null);
    try wkg_build.put(ar, "cargo", .{ .object = cargo_obj });

    var zig_obj = wkg_build.getPtr("zigLinker").?.object;
    try updateProducerBinaryRecord(ar, io, environ_map, &zig_obj, zig_bin, &.{ "zig", "version" }, null);
    try wkg_build.put(ar, "zigLinker", .{ .object = zig_obj });
    try wkg_obj.put(ar, "build", .{ .object = wkg_build });
    try producers.put(ar, "wkg", .{ .object = wkg_obj });

    var reg_obj = producers.getPtr("registry").?.object;
    var reg_bin_obj = reg_obj.getPtr("binary").?.object;
    const reg_bin = try std.fs.path.join(ar, &.{ tool_bin, "registry" });
    try updateProducerBinaryRecord(ar, io, environ_map, &reg_bin_obj, reg_bin, &.{ reg_bin, "--version" }, "registry ");
    try reg_obj.put(ar, "binary", .{ .object = reg_bin_obj });
    try producers.put(ar, "registry", .{ .object = reg_obj });

    var fixed_rt_obj = producers.getPtr("fixedRealtime").?.object;
    const fixed_so = try std.fs.path.join(ar, &.{ tool_bin, "fixed_realtime.so" });
    const fixed_so_info = try sha256AndSizeFile(io, fixed_so);
    try fixed_rt_obj.put(ar, "binarySha256", .{ .string = try ar.dupe(u8, &fixed_so_info.sha256) });
    try producers.put(ar, "fixedRealtime", .{ .object = fixed_rt_obj });

    var wabt_under_test = producers.getPtr("wabtUnderTest").?.object;
    try updateProducerBinaryRecord(ar, io, environ_map, &wabt_under_test, wabt_bin, &.{ wabt_bin, "version" }, null);
    try producers.put(ar, "wabtUnderTest", .{ .object = wabt_under_test });
    try root_obj.put(ar, "producers", .{ .object = producers });

    const source_dir = try std.fs.path.resolve(
        ar,
        &.{ tools_path, "..", "cache", "source", "wasm-pkg-tools" },
    );
    const cargo_lock_path = try std.fs.path.join(ar, &.{ source_dir, "Cargo.lock" });
    const cargo_lock_info = try sha256AndSizeFile(io, cargo_lock_path);
    if (!std.mem.eql(u8, &cargo_lock_info.sha256, wkg_obj.get("cargoLockSha256").?.string)) {
        fail("wkg Cargo.lock changed", .{});
    }
    const head_rev = try runOutput(
        ar,
        io,
        &.{ "git", "-C", source_dir, "rev-parse", "HEAD" },
        environ_map,
    );
    if (!std.mem.eql(u8, head_rev, wkg_obj.get("sourceRevision").?.string)) {
        fail("wkg source revision changed", .{});
    }

    // Recompute layout graphs and root digests from candidate layouts.
    var layouts_obj = root_obj.getPtr("layouts").?.object;
    for (layout_names) |layout_name| {
        const layout_dir = try std.fs.path.join(ar, &.{ candidate, "layouts", layout_name });
        var graph = try graphForLayout(ar, io, layout_dir);
        defer graph.deinit(ar);

        var layout_entry = layouts_obj.getPtr(layout_name).?.object;
        var roots_arr = std.json.Array.init(ar);
        for (graph.roots.items) |r| {
            var r_obj = std.json.ObjectMap.empty;
            try r_obj.put(ar, "digest", .{ .string = try ar.dupe(u8, r.digest) });
            try r_obj.put(ar, "mediaType", .{ .string = try ar.dupe(u8, r.media_type) });
            try r_obj.put(ar, "size", .{ .integer = @intCast(r.size) });
            try r_obj.put(ar, "tag", if (r.tag) |t| .{ .string = try ar.dupe(u8, t) } else .null);
            try roots_arr.append(.{ .object = r_obj });
        }
        try layout_entry.put(ar, "roots", .{ .array = roots_arr });

        var descs_arr = std.json.Array.init(ar);
        for (graph.descriptors.items) |d| {
            var d_obj = std.json.ObjectMap.empty;
            try d_obj.put(ar, "digest", .{ .string = try ar.dupe(u8, d.digest) });
            try d_obj.put(ar, "mediaType", .{ .string = try ar.dupe(u8, d.media_type) });
            var roles_arr = std.json.Array.init(ar);
            for (d.roles.items) |role| {
                try roles_arr.append(.{ .string = try ar.dupe(u8, role) });
            }
            try d_obj.put(ar, "roles", .{ .array = roles_arr });
            try d_obj.put(ar, "size", .{ .integer = @intCast(d.size) });
            try descs_arr.append(.{ .object = d_obj });
        }
        try layout_entry.put(ar, "descriptors", .{ .array = descs_arr });
        try layouts_obj.put(ar, layout_name, .{ .object = layout_entry });
    }
    try root_obj.put(ar, "layouts", .{ .object = layouts_obj });

    // Recompute fixtureFiles from candidate directory.
    var cand_files = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (cand_files.items) |p| allocator.free(p);
        cand_files.deinit(allocator);
    }
    try collectFiles(allocator, io, candidate, "", &cand_files, null);
    std.mem.sort([]u8, cand_files.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var fixture_files_arr = std.json.Array.init(ar);
    for (cand_files.items) |rel| {
        if (std.mem.eql(u8, std.fs.path.basename(rel), "manifest.json")) continue;
        const full = try std.fs.path.join(ar, &.{ candidate, rel });
        const info = try sha256AndSizeFile(io, full);
        var f_obj = std.json.ObjectMap.empty;
        try f_obj.put(ar, "path", .{ .string = try ar.dupe(u8, rel) });
        try f_obj.put(ar, "sha256", .{ .string = try ar.dupe(u8, &info.sha256) });
        try f_obj.put(ar, "size", .{ .integer = @intCast(info.size) });
        try fixture_files_arr.append(.{ .object = f_obj });
    }
    try root_obj.put(ar, "fixtureFiles", .{ .array = fixture_files_arr });

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    try writeFormattedJsonValue(&out, allocator, .{ .object = root_obj }, 0);
    try out.append(allocator, '\n');
    try writeFile(io, candidate_manifest, out.items);
    try updateManifestGeneratorSourcesInTree(allocator, io, repo_path, candidate_manifest);

    try verifyTree(allocator, io, candidate, repo_path);
    const target_exists = blk: {
        var d = std.Io.Dir.cwd().openDir(io, target, .{}) catch break :blk false;
        d.close(io);
        break :blk true;
    };
    if (target_exists and !update) {
        try compareTrees(allocator, io, target, candidate);
        std.Io.Dir.cwd().deleteTree(io, candidate) catch {};
    } else {
        try publishCandidate(io, candidate, target);
    }
    try verifyTree(allocator, io, target, repo_path);
}

fn runCheckCargoLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    lock_path: []const u8,
    expected_sha: []const u8,
) !void {
    const lock = try readFileAlloc(allocator, io, lock_path, 16 * 1024 * 1024);
    defer allocator.free(lock);

    const marker = "name = \"oci-wasm\"";
    const start = std.mem.indexOf(u8, lock, marker) orelse
        fail("Cargo.lock does not contain pinned oci-wasm 0.6.0", .{});
    const after = lock[start + marker.len ..];
    const end = std.mem.indexOf(u8, after, "\n\n") orelse after.len;
    const block = after[0..end];

    const expected_line = try std.fmt.allocPrint(allocator, "checksum = \"{s}\"", .{expected_sha});
    defer allocator.free(expected_line);

    if (std.mem.indexOf(u8, block, "version = \"0.6.0\"") == null or
        std.mem.indexOf(u8, block, expected_line) == null)
    {
        fail("Cargo.lock does not contain pinned oci-wasm 0.6.0", .{});
    }
}

fn runPatchWkgRunpath(allocator: std.mem.Allocator, io: std.Io, bin_path: []const u8) !void {
    const data = try readFileAlloc(allocator, io, bin_path, 128 * 1024 * 1024);
    defer allocator.free(data);

    const prefix = "/deps/rustc";
    const suffix = "/raw-dylibs";
    const total_len = prefix.len + 6 + suffix.len;

    var count: usize = 0;
    var i: usize = 0;
    while (i + total_len <= data.len) {
        if (std.mem.eql(u8, data[i .. i + prefix.len], prefix) and
            std.mem.eql(u8, data[i + prefix.len + 6 .. i + total_len], suffix))
        {
            var all_alnum = true;
            for (data[i + prefix.len .. i + prefix.len + 6]) |b| {
                if (!std.ascii.isAlphanumeric(b)) {
                    all_alnum = false;
                    break;
                }
            }
            if (all_alnum) {
                @memcpy(data[i + prefix.len .. i + prefix.len + 6], "STATIC");
                count += 1;
                i += total_len;
                continue;
            }
        }
        i += 1;
    }

    if (count != 1) {
        fail("expected one Rust raw-dylibs RUNPATH, found {d}", .{count});
    }
    try writeFile(io, bin_path, data);
}

fn formatIso8601Utc(sec_signed: i64, buf: *[20]u8) ![]const u8 {
    if (sec_signed < 0) return error.NegativeTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(sec_signed) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn runCheckFixedClock(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    expected_iso: []const u8,
) !void {
    const now_sec = std.Io.Clock.real.now(io).toSeconds();
    var iso_buf: [20]u8 = undefined;
    if (formatIso8601Utc(now_sec, &iso_buf)) |formatted| {
        if (std.mem.eql(u8, formatted, expected_iso)) return;
    } else |_| {}

    // When `zig run` is compiled without dynamic libc linkage, raw syscalls
    // bypass LD_PRELOAD; verify through `date` which dynamically links libc.
    const date_out = runOutput(
        allocator,
        io,
        &.{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" },
        environ_map,
    ) catch fail("fixed wall-clock interposer did not take effect", .{});
    defer allocator.free(date_out);
    if (!std.mem.eql(u8, date_out, expected_iso)) {
        fail("fixed wall-clock interposer did not take effect: got {s}", .{date_out});
    }
}

fn runCheckPortFree(io: std.Io, host_port: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse
        fail("invalid host:port: {s}", .{host_port});
    const host = host_port[0..colon];
    const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch
        fail("invalid port in {s}", .{host_port});
    const address = std.Io.net.IpAddress.parse(host, port) catch
        fail("invalid IP address in {s}", .{host_port});
    var listener = address.listen(io, .{ .reuse_address = true }) catch |err|
        fail("port {s} is not free: {s}", .{ host_port, @errorName(err) });
    listener.deinit(io);
}

fn runCompareRootDigest(
    allocator: std.mem.Allocator,
    io: std.Io,
    left_path: []const u8,
    right_path: []const u8,
) !void {
    const left_bytes = try readFileAlloc(allocator, io, left_path, 4 * 1024 * 1024);
    defer allocator.free(left_bytes);
    const right_bytes = try readFileAlloc(allocator, io, right_path, 4 * 1024 * 1024);
    defer allocator.free(right_bytes);

    var left_parsed = try std.json.parseFromSlice(std.json.Value, allocator, left_bytes, .{});
    defer left_parsed.deinit();
    var right_parsed = try std.json.parseFromSlice(std.json.Value, allocator, right_bytes, .{});
    defer right_parsed.deinit();

    const left_digest = left_parsed.value.object.get("root").?.object.get("digest").?.string;
    const right_digest = right_parsed.value.object.get("root").?.object.get("digest").?.string;
    if (!std.mem.eql(u8, left_digest, right_digest)) {
        fail("layout copy root changed: {s} != {s}", .{ left_digest, right_digest });
    }
}

fn matchKeywordIgnoreCase(text: []const u8, pos: usize) ?usize {
    const keywords = [_][]const u8{ "authorization", "password", "token" };
    for (keywords) |kw| {
        if (pos + kw.len <= text.len and std.ascii.eqlIgnoreCase(text[pos .. pos + kw.len], kw)) {
            if (pos > 0 and (std.ascii.isAlphanumeric(text[pos - 1]) or text[pos - 1] == '_')) {
                continue;
            }
            return kw.len;
        }
    }
    return null;
}

fn redactLogText(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Pass 1: redact (authorization|password|token)(\s*[:=]\s*)\S+ -> \1\2<redacted>
    var pass1 = std.ArrayListUnmanaged(u8).empty;
    defer pass1.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (matchKeywordIgnoreCase(input, i)) |kw_len| {
            var j = i + kw_len;
            while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
            if (j < input.len and (input[j] == ':' or input[j] == '=')) {
                j += 1;
                while (j < input.len and std.ascii.isWhitespace(input[j])) : (j += 1) {}
                const val_start = j;
                while (j < input.len and !std.ascii.isWhitespace(input[j])) : (j += 1) {}
                if (j > val_start) {
                    try pass1.appendSlice(allocator, input[i..val_start]);
                    try pass1.appendSlice(allocator, "<redacted>");
                    i = j;
                    continue;
                }
            }
        }
        try pass1.append(allocator, input[i]);
        i += 1;
    }

    // Pass 2: redact (https?://[^\s?]+)\?[^\s]+ -> \1?<redacted-query>
    var pass2 = std.ArrayListUnmanaged(u8).empty;
    errdefer pass2.deinit(allocator);

    const src = pass1.items;
    i = 0;
    while (i < src.len) {
        const is_http = (i + 7 <= src.len and std.mem.eql(u8, src[i .. i + 7], "http://")) or
            (i + 8 <= src.len and std.mem.eql(u8, src[i .. i + 8], "https://"));
        if (is_http) {
            const proto_len: usize = if (src[i + 4] == 's') 8 else 7;
            var j = i + proto_len;
            while (j < src.len and !std.ascii.isWhitespace(src[j]) and src[j] != '?') : (j += 1) {}
            if (j > i + proto_len and j < src.len and src[j] == '?') {
                const q_pos = j;
                j += 1;
                while (j < src.len and !std.ascii.isWhitespace(src[j])) : (j += 1) {}
                if (j > q_pos + 1) {
                    try pass2.appendSlice(allocator, src[i .. q_pos + 1]);
                    try pass2.appendSlice(allocator, "<redacted-query>");
                    i = j;
                    continue;
                }
            }
        }
        try pass2.append(allocator, src[i]);
        i += 1;
    }

    return pass2.toOwnedSlice(allocator);
}

fn collectSortedDirFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    suffix_filter: ?[]const u8,
    out_paths: *std.ArrayListUnmanaged([]u8),
) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var names = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (suffix_filter) |sfx| {
            if (!std.mem.endsWith(u8, entry.name, sfx)) continue;
        }
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |name| {
        try out_paths.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, name }));
    }
}

fn runFailureSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_dir: []const u8,
    manifest_path: []const u8,
    output_path: []const u8,
) !void {
    const manifest_bytes = try readFileAlloc(allocator, io, manifest_path, 16 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    const manifest = parsed.value.object;
    const producers = manifest.get("producers").?.object;
    const oras = producers.get("oras").?.object;
    const wkg = producers.get("wkg").?.object;
    const registry = producers.get("registry").?.object;

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);

    const header = try std.fmt.allocPrint(
        allocator,
        "OCI external interoperability failure\n" ++
            "schema={s}@{d}\n" ++
            "platform={s}\n" ++
            "oras={s} {s}\n" ++
            "wkg={s} {s}\n" ++
            "registry={s} {s}",
        .{
            manifest.get("schema").?.string,
            manifest.get("schemaVersion").?.integer,
            manifest.get("executionPlatform").?.string,
            oras.get("version").?.string,
            oras.get("binary").?.object.get("sha256").?.string,
            wkg.get("version").?.string,
            wkg.get("binary").?.object.get("sha256").?.string,
            registry.get("version").?.string,
            registry.get("binary").?.object.get("sha256").?.string,
        },
    );
    defer allocator.free(header);
    try out.appendSlice(allocator, header);

    var candidates = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (candidates.items) |p| allocator.free(p);
        candidates.deinit(allocator);
    }

    const ci_logs_dir = try std.fs.path.join(allocator, &.{ state_dir, "ci-logs" });
    defer allocator.free(ci_logs_dir);
    try collectSortedDirFiles(allocator, io, ci_logs_dir, ".log", &candidates);

    const work_logs_dir = try std.fs.path.join(allocator, &.{ state_dir, "work", "logs" });
    defer allocator.free(work_logs_dir);
    try collectSortedDirFiles(allocator, io, work_logs_dir, null, &candidates);

    var remaining: usize = 48 * 1024;
    for (candidates.items) |path| {
        if (remaining == 0) break;
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer file.close(io);
        const size = file.length(io) catch continue;
        const tail_len: usize = @intCast(@min(size, @as(u64, 16 * 1024)));
        const tail_offset: u64 = size - tail_len;
        const tail_buf = try allocator.alloc(u8, tail_len);
        defer allocator.free(tail_buf);
        const read_n = file.readPositionalAll(io, tail_buf, tail_offset) catch continue;

        const redacted = try redactLogText(allocator, tail_buf[0..read_n]);
        defer allocator.free(redacted);

        const section = try std.fmt.allocPrint(
            allocator,
            "\n\n--- {s} (tail) ---\n{s}",
            .{ std.fs.path.basename(path), redacted },
        );
        defer allocator.free(section);

        const take = @min(section.len, remaining);
        try out.appendSlice(allocator, section[0..take]);
        remaining -= take;
    }

    const max_body = 64 * 1024 - 1;
    if (out.items.len > max_body) {
        out.shrinkRetainingCapacity(max_body);
    }
    try out.append(allocator, '\n');
    try writeFile(io, output_path, out.items);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        fail("missing subcommand", .{});
    }
    const subcmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, subcmd, "verify")) {
        var fixtures: ?[]const u8 = null;
        var repo: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--fixtures") and i + 1 < rest.len) {
                i += 1;
                fixtures = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--repo") and i + 1 < rest.len) {
                i += 1;
                repo = rest[i];
            } else {
                fail("unknown verify option: {s}", .{rest[i]});
            }
        }
        const fixtures_dir = fixtures orelse fail("verify requires --fixtures <dir>", .{});
        try verifyTree(gpa, io, fixtures_dir, repo);
        return;
    }

    if (std.mem.eql(u8, subcmd, "qualify")) {
        var repo: ?[]const u8 = null;
        var work: ?[]const u8 = null;
        var tools: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--repo") and i + 1 < rest.len) {
                i += 1;
                repo = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--work") and i + 1 < rest.len) {
                i += 1;
                work = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--tools") and i + 1 < rest.len) {
                i += 1;
                tools = rest[i];
            } else {
                fail("unknown qualify option: {s}", .{rest[i]});
            }
        }
        try runQualify(
            gpa,
            io,
            init.environ_map,
            repo orelse fail("qualify requires --repo", .{}),
            work orelse fail("qualify requires --work", .{}),
            tools orelse fail("qualify requires --tools", .{}),
        );
        return;
    }

    if (std.mem.eql(u8, subcmd, "write")) {
        var repo: ?[]const u8 = null;
        var work: ?[]const u8 = null;
        var tools: ?[]const u8 = null;
        var update = false;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--repo") and i + 1 < rest.len) {
                i += 1;
                repo = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--work") and i + 1 < rest.len) {
                i += 1;
                work = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--tools") and i + 1 < rest.len) {
                i += 1;
                tools = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--update")) {
                update = true;
            } else {
                fail("unknown write option: {s}", .{rest[i]});
            }
        }
        try runWrite(
            gpa,
            io,
            init.environ_map,
            repo orelse fail("write requires --repo", .{}),
            work orelse fail("write requires --work", .{}),
            tools orelse fail("write requires --tools", .{}),
            update,
        );
        return;
    }

    if (std.mem.eql(u8, subcmd, "update-generator-sources")) {
        var repo: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--repo") and i + 1 < rest.len) {
                i += 1;
                repo = rest[i];
            } else {
                fail("unknown update-generator-sources option: {s}", .{rest[i]});
            }
        }
        const repo_dir = repo orelse fail("update-generator-sources requires --repo", .{});
        const manifest_path = try std.fs.path.join(
            gpa,
            &.{ repo_dir, "src", "fixtures", "oci", "manifest.json" },
        );
        defer gpa.free(manifest_path);
        try updateManifestGeneratorSourcesInTree(gpa, io, repo_dir, manifest_path);
        return;
    }

    if (std.mem.eql(u8, subcmd, "check-cargo-lock")) {
        if (rest.len != 2) fail("usage: check-cargo-lock <Cargo.lock> <expected-sha256>", .{});
        try runCheckCargoLock(gpa, io, rest[0], rest[1]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "patch-wkg-runpath")) {
        if (rest.len != 1) fail("usage: patch-wkg-runpath <wkg-binary-path>", .{});
        try runPatchWkgRunpath(gpa, io, rest[0]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "check-fixed-clock")) {
        if (rest.len != 1) fail("usage: check-fixed-clock <expected-iso8601>", .{});
        try runCheckFixedClock(gpa, io, init.environ_map, rest[0]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "check-port-free")) {
        if (rest.len != 1) fail("usage: check-port-free <host:port>", .{});
        try runCheckPortFree(io, rest[0]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "compare-root-digest")) {
        if (rest.len != 2) fail("usage: compare-root-digest <json-a> <json-b>", .{});
        try runCompareRootDigest(gpa, io, rest[0], rest[1]);
        return;
    }

    if (std.mem.eql(u8, subcmd, "failure-summary")) {
        var state: ?[]const u8 = null;
        var manifest: ?[]const u8 = null;
        var output: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--state") and i + 1 < rest.len) {
                i += 1;
                state = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--manifest") and i + 1 < rest.len) {
                i += 1;
                manifest = rest[i];
            } else if (std.mem.eql(u8, rest[i], "--output") and i + 1 < rest.len) {
                i += 1;
                output = rest[i];
            } else {
                fail("unknown failure-summary option: {s}", .{rest[i]});
            }
        }
        try runFailureSummary(
            gpa,
            io,
            state orelse fail("failure-summary requires --state", .{}),
            manifest orelse fail("failure-summary requires --manifest", .{}),
            output orelse fail("failure-summary requires --output", .{}),
        );
        return;
    }

    fail("unknown subcommand: {s}", .{subcmd});
}
