const std = @import("std");
const content = @import("content.zig");

pub const media_type_oci_manifest = "application/vnd.oci.image.manifest.v1+json";
pub const media_type_oci_index = "application/vnd.oci.image.index.v1+json";
pub const media_type_oci_config = "application/vnd.oci.image.config.v1+json";
pub const media_type_oci_empty_config = "application/vnd.oci.empty.v1+json";
pub const media_type_oci_layer = "application/vnd.oci.image.layer.v1.tar";
pub const media_type_oci_layer_gzip = "application/vnd.oci.image.layer.v1.tar+gzip";
pub const media_type_oci_layer_zstd = "application/vnd.oci.image.layer.v1.tar+zstd";
pub const media_type_oci_nondistributable_layer = "application/vnd.oci.image.layer.nondistributable.v1.tar";
pub const media_type_oci_nondistributable_layer_gzip = "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip";
pub const media_type_oci_nondistributable_layer_zstd = "application/vnd.oci.image.layer.nondistributable.v1.tar+zstd";

pub const media_type_docker_manifest = "application/vnd.docker.distribution.manifest.v2+json";
pub const media_type_docker_manifest_list = "application/vnd.docker.distribution.manifest.list.v2+json";
pub const media_type_docker_config = "application/vnd.docker.container.image.v1+json";
pub const media_type_docker_layer = "application/vnd.docker.image.rootfs.diff.tar";
pub const media_type_docker_layer_gzip = "application/vnd.docker.image.rootfs.diff.tar.gzip";
pub const media_type_docker_layer_zstd = "application/vnd.docker.image.rootfs.diff.tar.zstd";
pub const media_type_docker_foreign_layer = "application/vnd.docker.image.rootfs.foreign.diff.tar";
pub const media_type_docker_foreign_layer_gzip = "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip";

pub const MediaTypeClass = enum {
    unknown,
    oci_manifest,
    oci_index,
    oci_config,
    oci_layer,
    docker_manifest,
    docker_manifest_list,
    docker_config,
    docker_layer,

    pub fn isManifest(self: MediaTypeClass) bool {
        return self == .oci_manifest or self == .docker_manifest;
    }

    pub fn isIndex(self: MediaTypeClass) bool {
        return self == .oci_index or self == .docker_manifest_list;
    }

    pub fn isDocument(self: MediaTypeClass) bool {
        return self.isManifest() or self.isIndex();
    }
};

pub const ValidationError = error{
    InvalidSchemaVersion,
    InvalidMediaType,
    InvalidAnnotations,
    InvalidPlatform,
    InvalidDocumentShape,
    DocumentMediaTypeMismatch,
    UnsupportedDocumentMediaType,
    UnsupportedDescriptorMediaType,
    UnsupportedConfigMediaType,
    UnsupportedLayerMediaType,
} || content.Error;

pub const max_media_type_len = 255;

pub fn validateMediaType(media_type: []const u8) ValidationError!void {
    if (media_type.len == 0 or media_type.len > max_media_type_len) {
        return error.InvalidMediaType;
    }

    const slash = std.mem.indexOfScalar(u8, media_type, '/') orelse {
        return error.InvalidMediaType;
    };
    if (slash == 0 or slash + 1 == media_type.len or
        std.mem.indexOfScalarPos(u8, media_type, slash + 1, '/') != null)
    {
        return error.InvalidMediaType;
    }

    for (media_type[0..slash]) |byte| {
        if (!isTokenByte(byte)) return error.InvalidMediaType;
    }
    for (media_type[slash + 1 ..]) |byte| {
        if (!isTokenByte(byte)) return error.InvalidMediaType;
    }
}

fn isTokenByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

pub fn classifyMediaType(media_type: ?[]const u8) MediaTypeClass {
    const value = media_type orelse return .unknown;
    if (std.mem.eql(u8, value, media_type_oci_manifest)) return .oci_manifest;
    if (std.mem.eql(u8, value, media_type_oci_index)) return .oci_index;
    if (std.mem.eql(u8, value, media_type_oci_config)) return .oci_config;
    if (std.mem.eql(u8, value, media_type_oci_layer) or
        std.mem.eql(u8, value, media_type_oci_layer_gzip) or
        std.mem.eql(u8, value, media_type_oci_layer_zstd) or
        std.mem.eql(u8, value, media_type_oci_nondistributable_layer) or
        std.mem.eql(u8, value, media_type_oci_nondistributable_layer_gzip) or
        std.mem.eql(u8, value, media_type_oci_nondistributable_layer_zstd)) return .oci_layer;
    if (std.mem.eql(u8, value, media_type_docker_manifest)) return .docker_manifest;
    if (std.mem.eql(u8, value, media_type_docker_manifest_list)) return .docker_manifest_list;
    if (std.mem.eql(u8, value, media_type_docker_config)) return .docker_config;
    if (std.mem.eql(u8, value, media_type_docker_layer) or
        std.mem.eql(u8, value, media_type_docker_layer_gzip) or
        std.mem.eql(u8, value, media_type_docker_layer_zstd) or
        std.mem.eql(u8, value, media_type_docker_foreign_layer) or
        std.mem.eql(u8, value, media_type_docker_foreign_layer_gzip)) return .docker_layer;
    return .unknown;
}

/// Annotations remain dynamically represented so callers can retain unknown
/// metadata together with the exact source document bytes.
pub const Annotations = std.json.Value;

pub const Platform = struct {
    architecture: []const u8,
    os: []const u8,
    @"os.version": ?[]const u8 = null,
    @"os.features": ?[]const []const u8 = null,
    variant: ?[]const u8 = null,
    features: ?[]const []const u8 = null,
};

pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    urls: ?[]const []const u8 = null,
    annotations: ?Annotations = null,
    data: ?[]const u8 = null,
    artifactType: ?[]const u8 = null,
    platform: ?Platform = null,

    pub fn parsedDigest(self: Descriptor) content.Error!content.Digest {
        return content.Digest.parse(self.digest);
    }
};

pub const Index = struct {
    schemaVersion: u32,
    mediaType: ?[]const u8 = null,
    manifests: []const Descriptor,
    artifactType: ?[]const u8 = null,
    subject: ?Descriptor = null,
    annotations: ?Annotations = null,
};

pub const Manifest = struct {
    schemaVersion: u32,
    mediaType: ?[]const u8 = null,
    config: Descriptor,
    layers: []const Descriptor,
    artifactType: ?[]const u8 = null,
    subject: ?Descriptor = null,
    annotations: ?Annotations = null,
};

pub const ConfigPlatform = struct {
    architecture: ?[]const u8 = null,
    os: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    @"os.version": ?[]const u8 = null,
    @"os.features": ?[]const []const u8 = null,
};

pub const ImageConfigPlatform = ConfigPlatform;

pub const ImageRootFs = struct {
    type: []const u8,
    diff_ids: []const []const u8,
};

pub const ImageHistory = struct {
    created: ?[]const u8 = null,
    author: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    empty_layer: bool = false,
};

pub const ImageExecutionConfig = struct {
    User: ?[]const u8 = null,
    ExposedPorts: ?std.json.Value = null,
    Env: ?[]const []const u8 = null,
    Entrypoint: ?[]const []const u8 = null,
    Cmd: ?[]const []const u8 = null,
    Volumes: ?std.json.Value = null,
    WorkingDir: ?[]const u8 = null,
    Labels: ?std.json.Value = null,
    StopSignal: ?[]const u8 = null,
};

/// Typed image-configuration fields. Callers that rewrite configurations must
/// also retain their raw JSON so unknown fields are not lost.
pub const ImageConfiguration = struct {
    created: ?[]const u8 = null,
    author: ?[]const u8 = null,
    architecture: ?[]const u8 = null,
    os: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    @"os.version": ?[]const u8 = null,
    @"os.features": ?[]const []const u8 = null,
    config: ?ImageExecutionConfig = null,
    rootfs: ImageRootFs,
    history: ?[]const ImageHistory = null,
};

pub fn validateDescriptor(descriptor: Descriptor) ValidationError!content.Digest {
    try validateMediaType(descriptor.mediaType);
    if (descriptor.artifactType) |artifact_type| try validateMediaType(artifact_type);
    if (descriptor.annotations) |annotations| try validateAnnotations(annotations);
    if (descriptor.platform) |platform| try validatePlatform(platform);
    return descriptor.parsedDigest();
}

pub fn validateIndex(index: Index) ValidationError!void {
    if (index.schemaVersion != 2) return error.InvalidSchemaVersion;
    if (index.mediaType) |media_type| {
        try validateMediaType(media_type);
        if (!classifyMediaType(media_type).isIndex()) {
            return error.UnsupportedDocumentMediaType;
        }
    }
    if (index.artifactType) |artifact_type| try validateMediaType(artifact_type);
    if (index.annotations) |annotations| try validateAnnotations(annotations);
    for (index.manifests) |descriptor| _ = try validateDescriptor(descriptor);
    if (index.subject) |descriptor| _ = try validateDescriptor(descriptor);
}

pub fn validateRootDescriptor(descriptor: Descriptor) ValidationError!void {
    _ = try validateDescriptor(descriptor);
    if (!classifyMediaType(descriptor.mediaType).isDocument()) {
        return error.UnsupportedDescriptorMediaType;
    }
}

/// Validates any recognized OCI or Docker schema-2 manifest while allowing
/// generic artifact config and layer media types.
pub fn validateArtifactManifest(manifest: Manifest) ValidationError!void {
    if (manifest.schemaVersion != 2) return error.InvalidSchemaVersion;
    if (manifest.mediaType) |media_type| {
        try validateMediaType(media_type);
        if (!classifyMediaType(media_type).isManifest()) {
            return error.UnsupportedDocumentMediaType;
        }
    }
    if (manifest.artifactType) |artifact_type| try validateMediaType(artifact_type);
    if (manifest.annotations) |annotations| try validateAnnotations(annotations);
    _ = try validateDescriptor(manifest.config);
    for (manifest.layers) |layer| _ = try validateDescriptor(layer);
    if (manifest.subject) |descriptor| _ = try validateDescriptor(descriptor);
}

/// Applies container-image config and layer restrictions in addition to the
/// generic artifact checks.
pub fn validateImageManifest(manifest: Manifest) ValidationError!void {
    try validateArtifactManifest(manifest);

    const config_class = classifyMediaType(manifest.config.mediaType);
    if (config_class != .oci_config and config_class != .docker_config) {
        return error.UnsupportedConfigMediaType;
    }
    for (manifest.layers) |layer| {
        const layer_class = classifyMediaType(layer.mediaType);
        if (layer_class != .oci_layer and layer_class != .docker_layer) {
            return error.UnsupportedLayerMediaType;
        }
    }
}

fn validateAnnotations(annotations: Annotations) ValidationError!void {
    const object = switch (annotations) {
        .object => |object| object,
        else => return error.InvalidAnnotations,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidAnnotations;
    }
}

fn validatePlatform(platform: Platform) ValidationError!void {
    if (platform.architecture.len == 0 or platform.os.len == 0) {
        return error.InvalidPlatform;
    }
}

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
};

pub fn parseIndex(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Index) {
    return std.json.parseFromSlice(Index, allocator, bytes, parse_options);
}

pub fn parseManifest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(Manifest, allocator, bytes, parse_options);
}

pub const DocumentKind = enum {
    index,
    manifest,
};

pub const ParsedDocument = struct {
    /// Exact caller-owned bytes. Content-addressed documents must be copied
    /// from this slice rather than reconstructed from the typed view.
    raw: []const u8,
    value: Value,

    pub const Value = union(DocumentKind) {
        index: std.json.Parsed(Index),
        manifest: std.json.Parsed(Manifest),
    };

    pub fn deinit(self: *ParsedDocument) void {
        switch (self.value) {
            .index => |parsed| parsed.deinit(),
            .manifest => |parsed| parsed.deinit(),
        }
        self.* = undefined;
    }

    pub fn kind(self: *const ParsedDocument) DocumentKind {
        return std.meta.activeTag(self.value);
    }

    pub fn mediaTypeClass(self: *const ParsedDocument) MediaTypeClass {
        return switch (self.value) {
            .index => |parsed| classifyMediaType(parsed.value.mediaType),
            .manifest => |parsed| classifyMediaType(parsed.value.mediaType),
        };
    }
};

const DocumentProbe = struct {
    schemaVersion: ?u32 = null,
    mediaType: ?[]const u8 = null,
    manifests: ?std.json.Value = null,
    config: ?std.json.Value = null,
    layers: ?std.json.Value = null,
};

/// Decodes and validates a recognized graph document without changing its
/// content-addressed representation. Unknown JSON fields remain in `raw`.
pub fn parseDocument(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !ParsedDocument {
    const probe = try std.json.parseFromSlice(DocumentProbe, allocator, bytes, parse_options);
    defer probe.deinit();

    if (probe.value.schemaVersion == null) return error.InvalidDocumentShape;
    const is_index_shape = probe.value.manifests != null and
        probe.value.config == null and probe.value.layers == null;
    const is_manifest_shape = probe.value.manifests == null and
        probe.value.config != null and probe.value.layers != null;
    if (is_index_shape == is_manifest_shape) return error.InvalidDocumentShape;
    if (probe.value.manifests) |manifests| {
        if (manifests != .array) return error.InvalidDocumentShape;
    }
    if (probe.value.config) |config| {
        if (config != .object) return error.InvalidDocumentShape;
    }
    if (probe.value.layers) |layers| {
        if (layers != .array) return error.InvalidDocumentShape;
    }

    if (probe.value.mediaType) |media_type| {
        try validateMediaType(media_type);
        const class = classifyMediaType(media_type);
        if (!class.isDocument()) return error.UnsupportedDocumentMediaType;
        if ((is_index_shape and !class.isIndex()) or
            (is_manifest_shape and !class.isManifest()))
        {
            return error.DocumentMediaTypeMismatch;
        }
    }

    if (is_index_shape) {
        const parsed = try parseIndex(allocator, bytes);
        errdefer parsed.deinit();
        try validateIndex(parsed.value);
        return .{ .raw = bytes, .value = .{ .index = parsed } };
    }

    const parsed = try parseManifest(allocator, bytes);
    errdefer parsed.deinit();
    try validateArtifactManifest(parsed.value);
    return .{ .raw = bytes, .value = .{ .manifest = parsed } };
}

const digest_a = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const digest_b = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const digest_c = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

test "unknown fields parse compatibly while exact document bytes remain available" {
    const json =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","x-vendor":{"keep":true},"config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2,"x-descriptor":"keep"},"layers":[]}
    ;
    var document = try parseDocument(std.testing.allocator, json);
    defer document.deinit();

    try std.testing.expectEqual(DocumentKind.manifest, document.kind());
    try std.testing.expectEqualStrings(json, document.raw);
    const manifest = document.value.manifest.value;
    try std.testing.expectEqualStrings(media_type_oci_empty_config, manifest.config.mediaType);
}

test "document media classes distinguish OCI and Docker schema two" {
    try std.testing.expectEqual(.oci_manifest, classifyMediaType(media_type_oci_manifest));
    try std.testing.expectEqual(.oci_index, classifyMediaType(media_type_oci_index));
    try std.testing.expectEqual(.oci_config, classifyMediaType(media_type_oci_config));
    try std.testing.expectEqual(.oci_layer, classifyMediaType(media_type_oci_layer_zstd));
    try std.testing.expectEqual(.docker_manifest, classifyMediaType(media_type_docker_manifest));
    try std.testing.expectEqual(.docker_manifest_list, classifyMediaType(media_type_docker_manifest_list));
    try std.testing.expectEqual(.docker_config, classifyMediaType(media_type_docker_config));
    try std.testing.expectEqual(.docker_layer, classifyMediaType(media_type_docker_foreign_layer_gzip));
    try std.testing.expect(classifyMediaType(media_type_oci_manifest).isManifest());
    try std.testing.expect(classifyMediaType(media_type_docker_manifest_list).isIndex());
    try std.testing.expectEqual(.unknown, classifyMediaType("application/vnd.example.document+json"));

    const wrong_shape =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},"layers":[]}
    ;
    try std.testing.expectError(
        error.DocumentMediaTypeMismatch,
        parseDocument(std.testing.allocator, wrong_shape),
    );
}

test "artifact manifest accepts generic payloads rejected by image validation" {
    const manifest = Manifest{
        .schemaVersion = 2,
        .mediaType = media_type_oci_manifest,
        .artifactType = "application/vnd.example.wasm.artifact.v1",
        .config = .{
            .mediaType = media_type_oci_empty_config,
            .digest = digest_a,
            .size = 2,
        },
        .layers = &.{.{
            .mediaType = "application/wasm",
            .digest = digest_b,
            .size = 42,
        }},
    };

    try validateArtifactManifest(manifest);
    try std.testing.expectError(error.UnsupportedConfigMediaType, validateImageManifest(manifest));

    const image_config_artifact = Manifest{
        .schemaVersion = 2,
        .mediaType = media_type_oci_manifest,
        .artifactType = manifest.artifactType,
        .config = .{
            .mediaType = media_type_oci_config,
            .digest = digest_a,
            .size = 2,
        },
        .layers = manifest.layers,
    };
    try validateArtifactManifest(image_config_artifact);
    try std.testing.expectError(
        error.UnsupportedLayerMediaType,
        validateImageManifest(image_config_artifact),
    );
}

test "OCI and Docker image document roles validate strictly" {
    try validateImageManifest(.{
        .schemaVersion = 2,
        .mediaType = media_type_oci_manifest,
        .config = .{
            .mediaType = media_type_oci_config,
            .digest = digest_a,
            .size = 1,
        },
        .layers = &.{.{
            .mediaType = media_type_oci_layer_gzip,
            .digest = digest_b,
            .size = 2,
        }},
    });
    try validateImageManifest(.{
        .schemaVersion = 2,
        .mediaType = media_type_docker_manifest,
        .config = .{
            .mediaType = media_type_docker_config,
            .digest = digest_a,
            .size = 1,
        },
        .layers = &.{.{
            .mediaType = media_type_docker_layer_gzip,
            .digest = digest_b,
            .size = 2,
        }},
    });
    try validateIndex(.{
        .schemaVersion = 2,
        .mediaType = media_type_docker_manifest_list,
        .manifests = &.{.{
            .mediaType = media_type_docker_manifest,
            .digest = digest_c,
            .size = 3,
        }},
    });
}

test "subject and OCI 1.1 artifact fields parse and validate" {
    const json =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","artifactType":"application/vnd.example.signature","config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},"layers":[],"subject":{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":123,"annotations":{"org.example.kind":"subject"}}}
    ;
    var document = try parseDocument(std.testing.allocator, json);
    defer document.deinit();

    const manifest = document.value.manifest.value;
    try std.testing.expectEqualStrings("application/vnd.example.signature", manifest.artifactType.?);
    try std.testing.expectEqualStrings(digest_c, manifest.subject.?.digest);
    try validateArtifactManifest(manifest);
}

test "index and descriptors retain all standard fields" {
    const json =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","artifactType":"application/vnd.example.collection","x-index":"keep","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":7,"urls":["https://registry.example/blob"],"annotations":{"org.example.kind":"child"},"data":"cGF5bG9hZA==","artifactType":"application/vnd.example.child","platform":{"architecture":"amd64","os":"linux","os.version":"6.0","os.features":["feature-a"],"variant":"v1","features":["legacy"]},"x-descriptor":"keep"}],"subject":{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","size":123}}
    ;
    var document = try parseDocument(std.testing.allocator, json);
    defer document.deinit();

    try std.testing.expectEqual(DocumentKind.index, document.kind());
    try std.testing.expectEqualStrings(json, document.raw);
    const index = document.value.index.value;
    try std.testing.expectEqualStrings("application/vnd.example.collection", index.artifactType.?);
    try std.testing.expectEqualStrings(digest_c, index.subject.?.digest);

    const descriptor = index.manifests[0];
    try std.testing.expectEqualStrings("https://registry.example/blob", descriptor.urls.?[0]);
    try std.testing.expectEqualStrings("cGF5bG9hZA==", descriptor.data.?);
    try std.testing.expectEqualStrings("application/vnd.example.child", descriptor.artifactType.?);
    try std.testing.expectEqualStrings("amd64", descriptor.platform.?.architecture);
    try std.testing.expectEqualStrings("linux", descriptor.platform.?.os);
    try std.testing.expectEqualStrings("6.0", descriptor.platform.?.@"os.version".?);
    try std.testing.expectEqualStrings("feature-a", descriptor.platform.?.@"os.features".?[0]);
    try std.testing.expectEqualStrings("v1", descriptor.platform.?.variant.?);
    try std.testing.expectEqualStrings("legacy", descriptor.platform.?.features.?[0]);
}

test "media type validation rejects header and control injection" {
    const invalid = [_][]const u8{
        "application/example\r\nAuthorization: injected",
        "application/example\n",
        "application/example; charset=utf-8",
        "application/example value",
        "application/",
        "/json",
        "application//json",
    };
    for (invalid) |media_type| {
        try std.testing.expectError(error.InvalidMediaType, validateMediaType(media_type));
    }
    try validateMediaType("application/vnd.example.artifact.v1+json");
    try validateMediaType("application/wasm");

    var maximum: [max_media_type_len]u8 = @splat('a');
    maximum[1] = '/';
    try validateMediaType(&maximum);

    var oversized: [max_media_type_len + 1]u8 = @splat('a');
    oversized[1] = '/';
    try std.testing.expectError(error.InvalidMediaType, validateMediaType(&oversized));
}

test "schema media descriptor and document shape errors are explicit" {
    try std.testing.expectError(
        error.UnexpectedEndOfInput,
        parseDocument(std.testing.allocator, "{\"schemaVersion\":2"),
    );

    const schema_one =
        \\{"schemaVersion":1,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}
    ;
    try std.testing.expectError(
        error.InvalidSchemaVersion,
        parseDocument(std.testing.allocator, schema_one),
    );

    const unsupported_media =
        \\{"schemaVersion":2,"mediaType":"application/vnd.example.unknown+json","manifests":[]}
    ;
    try std.testing.expectError(
        error.UnsupportedDocumentMediaType,
        parseDocument(std.testing.allocator, unsupported_media),
    );

    const mixed_shape =
        \\{"schemaVersion":2,"manifests":[],"config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},"layers":[]}
    ;
    try std.testing.expectError(
        error.InvalidDocumentShape,
        parseDocument(std.testing.allocator, mixed_shape),
    );

    const invalid_digest =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:ABCDEF","size":2},"layers":[]}
    ;
    try std.testing.expectError(
        error.InvalidDigest,
        parseDocument(std.testing.allocator, invalid_digest),
    );

    const oversized_descriptor =
        \\{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":18446744073709551616},"layers":[]}
    ;
    try std.testing.expectError(
        error.Overflow,
        parseDocument(std.testing.allocator, oversized_descriptor),
    );

    const injected_media =
        "{\"schemaVersion\":2,\"mediaType\":\"application/example\\r\\nX-Header: value\",\"manifests\":[]}";
    try std.testing.expectError(
        error.InvalidMediaType,
        parseDocument(std.testing.allocator, injected_media),
    );

    const missing_layers =
        \\{"schemaVersion":2,"config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2}}
    ;
    try std.testing.expectError(
        error.InvalidDocumentShape,
        parseDocument(std.testing.allocator, missing_layers),
    );
}
