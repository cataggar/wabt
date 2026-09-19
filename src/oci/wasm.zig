//! Pure OCI packaging profiles for immutable WebAssembly payloads.
//!
//! `wasm_v0` matches oci-wasm v0.6.0's config contract. The `wasip1` and
//! `wasip2` values are profile labels backed by native parsing evidence, not
//! claims that WABT can execute the payload on a particular runtime.
//!
//! The explicit `oci` profile is the OCI 1.1 generic-artifact shape used by
//! ORAS: `artifactType: application/wasm`, the canonical empty JSON config,
//! and one raw Wasm layer. It is intentionally not compatible with wkg's
//! Wasm-v0-only config check.

const std = @import("std");
const content = @import("content.zig");
const model = @import("model.zig");
const wasm_metadata = @import("wasm_metadata.zig");

pub const WasmKind = wasm_metadata.WasmKind;
pub const PayloadMetadata = wasm_metadata.PayloadMetadata;
pub const ValidationError = wasm_metadata.ValidationError;
pub const validatePayload = wasm_metadata.validatePayload;
pub const classifyPayload = wasm_metadata.classifyPayload;

pub const media_type_manifest = model.media_type_oci_manifest;
pub const media_type_index = model.media_type_oci_index;
pub const media_type_wasm_config = "application/vnd.wasm.config.v0+json";
pub const media_type_empty_config = model.media_type_oci_empty_config;
pub const media_type_wasm = "application/wasm";
pub const artifact_type_wasm = "application/wasm";
pub const annotation_created = "org.opencontainers.image.created";
pub const annotation_title = "org.opencontainers.image.title";
pub const empty_config_bytes = "{}";
pub const empty_config_digest =
    "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";

pub const max_payload_bytes: usize = 256 * 1024 * 1024;
pub const max_manifest_bytes: usize = 1024 * 1024;
pub const max_config_bytes: usize = 1024 * 1024;
pub const max_layer_title_bytes: usize = 255;
pub const max_author_bytes: usize = 4096;
pub const max_created_bytes: usize = 64;
pub const max_component_externs: usize = 4096;
pub const max_component_name_bytes: usize = 4096;
pub const max_component_metadata_bytes: usize = 128 * 1024;

pub const Profile = enum {
    wasm_v0,
    /// OCI 1.1 generic/ORAS-compatible publication; not wkg-compatible.
    oci,
};

pub const DirectManifestProfile = enum {
    wasm_v0,
    oci_1_1,
    /// Documented ORAS OCI 1.0 compatibility shape, accepted for reads only.
    oci_1_0,
};

pub const BuildOptions = struct {
    /// Required RFC 3339 text. This pure API never reads the wall clock.
    /// A caller choosing "now" is explicitly choosing non-reproducible bytes.
    created: []const u8,
    /// Wasm-v0 config author. Generic OCI has no author field and ignores it.
    author: ?[]const u8 = null,
    source_name: ?[]const u8 = null,
    profile: Profile = .wasm_v0,
};

/// Field order is part of the Wasm-v0 golden-byte contract.
pub const WasmV0Component = struct {
    exports: []const []const u8,
    imports: []const []const u8,
    target: ?[]const u8 = null,
};

/// Field order and camel-case names match oci-wasm v0.6.0.
pub const WasmV0Config = struct {
    created: []const u8,
    author: ?[]const u8,
    architecture: []const u8,
    os: []const u8,
    layerDigests: []const []const u8,
    component: ?WasmV0Component,
};

pub const Error = error{
    PayloadTooLarge,
    ManifestTooLarge,
    ConfigTooLarge,
    InvalidCreated,
    InvalidAuthor,
    ComponentMetadataTooLarge,
    MalformedManifest,
    MalformedWasmV0Config,
    DirectManifestRequired,
    UnsupportedRootMediaType,
    UnsupportedManifestMediaType,
    ManifestSubjectUnsupported,
    InvalidLayerCount,
    UnsupportedLayerMediaType,
    UnsupportedProfile,
    InvalidEmptyConfig,
    ArchitectureMismatch,
    OsMismatch,
    LayerDigestsMismatch,
    ComponentPresenceMismatch,
    ComponentImportsMismatch,
    ComponentExportsMismatch,
    DuplicateConfigExtern,
    InvalidConfigExtern,
    OutOfMemory,
} || content.Error || wasm_metadata.ValidationError;

pub const PreparedArtifact = struct {
    owner_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    profile: Profile,
    kind: wasm_metadata.WasmKind,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
    config_descriptor: model.Descriptor,
    config_bytes: []const u8,
    layer_descriptor: model.Descriptor,
    /// The caller's original slice, borrowed without copying or rewriting.
    payload_bytes: []const u8,

    pub fn deinit(self: *PreparedArtifact) void {
        self.arena.deinit();
        self.owner_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const ExtractionPlan = struct {
    owner_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    profile: DirectManifestProfile,
    kind: wasm_metadata.WasmKind,
    config_descriptor: model.Descriptor,
    layer_descriptor: model.Descriptor,
    /// Wasm-v0 target is indexing metadata only and is not runtime-verified.
    unverified_target: ?[]const u8,
    /// Exact caller-owned source bytes. Classification never reconstructs them.
    manifest_bytes: []const u8,
    payload_bytes: []const u8,

    pub fn deinit(self: *ExtractionPlan) void {
        self.arena.deinit();
        self.owner_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

const JsonDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
};

const LayerAnnotations = struct {
    @"org.opencontainers.image.title": []const u8,
};

const JsonLayerDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    annotations: LayerAnnotations,
};

const WasmV0Manifest = struct {
    schemaVersion: u32,
    mediaType: []const u8,
    config: JsonDescriptor,
    layers: [1]JsonLayerDescriptor,
};

const GenericAnnotations = struct {
    @"org.opencontainers.image.created": []const u8,
};

const GenericManifest = struct {
    schemaVersion: u32,
    mediaType: []const u8,
    artifactType: []const u8,
    config: JsonDescriptor,
    layers: [1]JsonLayerDescriptor,
    annotations: GenericAnnotations,
};

/// Validate and package one immutable payload into exact owned config/manifest
/// bytes plus canonical descriptors. The payload slice itself is returned
/// unchanged and remains caller-owned.
pub fn prepare(
    allocator: std.mem.Allocator,
    payload: []const u8,
    options: BuildOptions,
) Error!PreparedArtifact {
    if (payload.len > max_payload_bytes) return error.PayloadTooLarge;
    try validateCreated(options.created);
    if (options.profile == .wasm_v0) try validateAuthor(options.author);

    const arena = try createArena(allocator);
    errdefer destroyArena(allocator, arena);
    const owned = arena.allocator();

    var metadata = try wasm_metadata.validatePayload(owned, payload);
    defer metadata.deinit(owned);
    try validateMetadataBounds(metadata);

    const title = try owned.dupe(
        u8,
        safeLayerTitle(options.source_name, metadata.kind),
    );
    const layer_descriptor = try describeLayer(owned, payload, title);

    const config_bytes = switch (options.profile) {
        .wasm_v0 => try buildWasmV0Config(
            owned,
            metadata,
            layer_descriptor.digest,
            options,
        ),
        .oci => try owned.dupe(u8, empty_config_bytes),
    };
    if (config_bytes.len > max_config_bytes) return error.ConfigTooLarge;

    const config_media_type = switch (options.profile) {
        .wasm_v0 => media_type_wasm_config,
        .oci => media_type_empty_config,
    };
    const config_descriptor = try describe(owned, config_media_type, config_bytes);

    const manifest_bytes = switch (options.profile) {
        .wasm_v0 => try stringifyBounded(
            owned,
            WasmV0Manifest{
                .schemaVersion = 2,
                .mediaType = media_type_manifest,
                .config = jsonDescriptor(config_descriptor),
                .layers = .{jsonLayerDescriptor(layer_descriptor, title)},
            },
        ),
        .oci => try stringifyBounded(
            owned,
            GenericManifest{
                .schemaVersion = 2,
                .mediaType = media_type_manifest,
                .artifactType = artifact_type_wasm,
                .config = jsonDescriptor(config_descriptor),
                .layers = .{jsonLayerDescriptor(layer_descriptor, title)},
                .annotations = .{
                    .@"org.opencontainers.image.created" = options.created,
                },
            },
        ),
    };
    const root_descriptor = try describe(owned, media_type_manifest, manifest_bytes);

    return .{
        .owner_allocator = allocator,
        .arena = arena,
        .profile = options.profile,
        .kind = metadata.kind,
        .root_descriptor = root_descriptor,
        .manifest_bytes = manifest_bytes,
        .config_descriptor = config_descriptor,
        .config_bytes = config_bytes,
        .layer_descriptor = layer_descriptor,
        .payload_bytes = payload,
    };
}

/// Strictly classify one verified direct-manifest candidate. All four supplied
/// byte slices remain borrowed. No output path is selected and the payload is
/// never executed, unpacked, or rewritten.
pub fn classifyDirectManifest(
    allocator: std.mem.Allocator,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
    config_bytes: []const u8,
    payload_bytes: []const u8,
) Error!ExtractionPlan {
    if (manifest_bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
    if (config_bytes.len > max_config_bytes) return error.ConfigTooLarge;
    if (payload_bytes.len > max_payload_bytes) return error.PayloadTooLarge;

    if (std.mem.eql(u8, root_descriptor.mediaType, media_type_index))
        return error.DirectManifestRequired;
    if (!std.mem.eql(u8, root_descriptor.mediaType, media_type_manifest))
        return error.UnsupportedRootMediaType;
    try verifyDescriptorBytes(root_descriptor, manifest_bytes);

    const arena = try createArena(allocator);
    errdefer destroyArena(allocator, arena);
    const owned = arena.allocator();

    var document = model.parseDocument(owned, manifest_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedDocumentMediaType, error.DocumentMediaTypeMismatch => return error.UnsupportedManifestMediaType,
        else => return error.MalformedManifest,
    };
    defer document.deinit();

    const manifest = switch (document.value) {
        .index => return error.DirectManifestRequired,
        .manifest => |parsed| parsed.value,
    };
    const fields = try inspectManifestFields(owned, manifest_bytes);
    if (manifest.mediaType == null or
        !std.mem.eql(u8, manifest.mediaType.?, media_type_manifest))
        return error.UnsupportedManifestMediaType;
    if (fields.subject) return error.ManifestSubjectUnsupported;
    if (manifest.layers.len != 1) return error.InvalidLayerCount;

    const layer = manifest.layers[0];
    if (!std.mem.eql(u8, layer.mediaType, media_type_wasm))
        return error.UnsupportedLayerMediaType;
    try verifyDescriptorBytes(layer, payload_bytes);
    try verifyDescriptorBytes(manifest.config, config_bytes);

    var metadata = try wasm_metadata.validatePayload(owned, payload_bytes);
    defer metadata.deinit(owned);
    try validateMetadataBounds(metadata);

    const profile: DirectManifestProfile = blk: {
        if (manifest.artifactType) |artifact_type| {
            if (!std.mem.eql(u8, artifact_type, artifact_type_wasm) or
                !std.mem.eql(u8, manifest.config.mediaType, media_type_empty_config))
                return error.UnsupportedProfile;
            if (!std.mem.eql(u8, config_bytes, empty_config_bytes))
                return error.InvalidEmptyConfig;
            break :blk .oci_1_1;
        }

        if (fields.artifact_type) return error.UnsupportedProfile;
        if (std.mem.eql(u8, manifest.config.mediaType, media_type_wasm_config))
            break :blk .wasm_v0;
        if (std.mem.eql(u8, manifest.config.mediaType, media_type_wasm)) {
            if (!std.mem.eql(u8, config_bytes, empty_config_bytes))
                return error.InvalidEmptyConfig;
            break :blk .oci_1_0;
        }
        return error.UnsupportedProfile;
    };

    var unverified_target: ?[]const u8 = null;
    if (profile == .wasm_v0) {
        var parsed_config = std.json.parseFromSlice(
            WasmV0Config,
            owned,
            config_bytes,
            .{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedWasmV0Config,
        };
        defer parsed_config.deinit();
        try validateWasmV0Config(
            owned,
            parsed_config.value,
            layer,
            metadata,
        );
        if (parsed_config.value.component) |component|
            unverified_target = component.target;
    }

    return .{
        .owner_allocator = allocator,
        .arena = arena,
        .profile = profile,
        .kind = metadata.kind,
        .config_descriptor = try cloneDescriptor(owned, manifest.config),
        .layer_descriptor = try cloneDescriptor(owned, layer),
        .unverified_target = if (unverified_target) |target|
            try owned.dupe(u8, target)
        else
            null,
        .manifest_bytes = manifest_bytes,
        .payload_bytes = payload_bytes,
    };
}

/// Return a conservative cross-platform basename for an informational layer
/// annotation. It is never suitable as an extraction path.
pub fn safeLayerTitle(
    source_name: ?[]const u8,
    kind: wasm_metadata.WasmKind,
) []const u8 {
    const fallback = switch (kind) {
        .core_module => "module.wasm",
        .component => "component.wasm",
    };
    const source = source_name orelse return fallback;

    var start: usize = 0;
    for (source, 0..) |byte, index| {
        if (byte == '/' or byte == '\\') start = index + 1;
    }
    const basename = source[start..];
    if (basename.len == 0 or basename.len > max_layer_title_bytes)
        return fallback;
    if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, ".."))
        return fallback;
    if (!std.unicode.utf8ValidateSlice(basename)) return fallback;
    for (basename) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\')
            return fallback;
    }
    return basename;
}

fn createArena(allocator: std.mem.Allocator) error{OutOfMemory}!*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyArena(
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
) void {
    arena.deinit();
    allocator.destroy(arena);
}

fn validateCreated(created: []const u8) Error!void {
    if (created.len < 20 or created.len > max_created_bytes)
        return error.InvalidCreated;
    if (!allAscii(created)) return error.InvalidCreated;
    if (created[4] != '-' or created[7] != '-' or
        (created[10] != 'T' and created[10] != 't') or
        created[13] != ':' or created[16] != ':')
        return error.InvalidCreated;

    const year = parseFixedDecimal(created[0..4]) orelse return error.InvalidCreated;
    const month = parseFixedDecimal(created[5..7]) orelse return error.InvalidCreated;
    const day = parseFixedDecimal(created[8..10]) orelse return error.InvalidCreated;
    const hour = parseFixedDecimal(created[11..13]) orelse return error.InvalidCreated;
    const minute = parseFixedDecimal(created[14..16]) orelse return error.InvalidCreated;
    const second = parseFixedDecimal(created[17..19]) orelse return error.InvalidCreated;
    if (month < 1 or month > 12 or day < 1 or
        day > daysInMonth(year, month) or hour > 23 or
        minute > 59 or second > 60)
        return error.InvalidCreated;

    var cursor: usize = 19;
    if (cursor < created.len and created[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < created.len and std.ascii.isDigit(created[cursor]))
            cursor += 1;
        if (cursor == fraction_start) return error.InvalidCreated;
    }
    if (cursor >= created.len) return error.InvalidCreated;
    if (created[cursor] == 'Z' or created[cursor] == 'z') {
        if (cursor + 1 != created.len) return error.InvalidCreated;
        return;
    }
    if (created[cursor] != '+' and created[cursor] != '-')
        return error.InvalidCreated;
    if (cursor + 6 != created.len or created[cursor + 3] != ':')
        return error.InvalidCreated;
    const offset_hour = parseFixedDecimal(created[cursor + 1 .. cursor + 3]) orelse
        return error.InvalidCreated;
    const offset_minute = parseFixedDecimal(created[cursor + 4 .. cursor + 6]) orelse
        return error.InvalidCreated;
    if (offset_hour > 23 or offset_minute > 59) return error.InvalidCreated;
}

fn validateAuthor(author: ?[]const u8) Error!void {
    const value = author orelse return;
    if (value.len > max_author_bytes or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidAuthor;
}

fn validateMetadataBounds(metadata: wasm_metadata.PayloadMetadata) Error!void {
    const component = metadata.component orelse return;
    if (component.imports.len > max_component_externs or
        component.exports.len > max_component_externs)
        return error.ComponentMetadataTooLarge;
    var total: usize = 0;
    for (component.imports) |external| {
        if (external.name.len > max_component_name_bytes)
            return error.ComponentMetadataTooLarge;
        total = std.math.add(usize, total, external.name.len) catch
            return error.ComponentMetadataTooLarge;
    }
    for (component.exports) |external| {
        if (external.name.len > max_component_name_bytes)
            return error.ComponentMetadataTooLarge;
        total = std.math.add(usize, total, external.name.len) catch
            return error.ComponentMetadataTooLarge;
    }
    if (total > max_component_metadata_bytes)
        return error.ComponentMetadataTooLarge;
}

fn buildWasmV0Config(
    allocator: std.mem.Allocator,
    metadata: wasm_metadata.PayloadMetadata,
    layer_digest: []const u8,
    options: BuildOptions,
) Error![]u8 {
    const os = metadata.wasmV0Os();
    const layer_digests = [1][]const u8{layer_digest};
    const component: ?WasmV0Component = if (metadata.component) |native| .{
        .exports = try externNames(allocator, native.exports),
        .imports = try externNames(allocator, native.imports),
        .target = null,
    } else null;

    const bytes = try std.json.Stringify.valueAlloc(
        allocator,
        WasmV0Config{
            .created = options.created,
            .author = options.author,
            .architecture = "wasm",
            .os = os,
            .layerDigests = &layer_digests,
            .component = component,
        },
        .{},
    );
    if (bytes.len > max_config_bytes) return error.ConfigTooLarge;
    return bytes;
}

fn externNames(
    allocator: std.mem.Allocator,
    externs: []const wasm_metadata.Extern,
) error{OutOfMemory}![]const []const u8 {
    const names = try allocator.alloc([]const u8, externs.len);
    for (externs, 0..) |external, index| names[index] = external.name;
    return names;
}

fn stringifyBounded(
    allocator: std.mem.Allocator,
    value: anytype,
) Error![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;
    return bytes;
}

fn describe(
    allocator: std.mem.Allocator,
    media_type: []const u8,
    bytes: []const u8,
) Error!model.Descriptor {
    const digest = content.digestBytes(bytes).format();
    return .{
        .mediaType = media_type,
        .digest = try allocator.dupe(u8, &digest),
        .size = try content.checkedSize(bytes.len),
    };
}

fn describeLayer(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    title: []const u8,
) Error!model.Descriptor {
    var descriptor = try describe(allocator, media_type_wasm, bytes);
    var annotations: std.json.ObjectMap = .{};
    try annotations.put(
        allocator,
        annotation_title,
        .{ .string = title },
    );
    descriptor.annotations = .{ .object = annotations };
    return descriptor;
}

fn jsonDescriptor(descriptor: model.Descriptor) JsonDescriptor {
    return .{
        .mediaType = descriptor.mediaType,
        .digest = descriptor.digest,
        .size = descriptor.size,
    };
}

fn jsonLayerDescriptor(
    descriptor: model.Descriptor,
    title: []const u8,
) JsonLayerDescriptor {
    return .{
        .mediaType = descriptor.mediaType,
        .digest = descriptor.digest,
        .size = descriptor.size,
        .annotations = .{
            .@"org.opencontainers.image.title" = title,
        },
    };
}

fn verifyDescriptorBytes(
    descriptor: model.Descriptor,
    bytes: []const u8,
) Error!void {
    const digest = try content.Digest.parse(descriptor.digest);
    try content.verifyBytes(digest, descriptor.size, bytes);
}

const ManifestFields = struct {
    artifact_type: bool,
    subject: bool,
};

fn inspectManifestFields(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!ManifestFields {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedManifest,
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedManifest,
    };
    return .{
        .artifact_type = object.get("artifactType") != null,
        .subject = object.get("subject") != null,
    };
}

fn validateWasmV0Config(
    allocator: std.mem.Allocator,
    config: WasmV0Config,
    layer: model.Descriptor,
    metadata: wasm_metadata.PayloadMetadata,
) Error!void {
    try validateCreated(config.created);
    try validateAuthor(config.author);
    if (!std.mem.eql(u8, config.architecture, "wasm"))
        return error.ArchitectureMismatch;
    if (config.layerDigests.len != 1 or
        !std.mem.eql(u8, config.layerDigests[0], layer.digest))
        return error.LayerDigestsMismatch;

    const expected_os = metadata.wasmV0Os();
    if (!std.mem.eql(u8, config.os, expected_os)) return error.OsMismatch;

    switch (metadata.kind) {
        .core_module => {
            if (config.component != null) return error.ComponentPresenceMismatch;
        },
        .component => {
            const actual = config.component orelse
                return error.ComponentPresenceMismatch;
            const native = metadata.component orelse
                return error.ComponentPresenceMismatch;
            try compareExternNames(
                allocator,
                actual.imports,
                native.imports,
                error.ComponentImportsMismatch,
            );
            try compareExternNames(
                allocator,
                actual.exports,
                native.exports,
                error.ComponentExportsMismatch,
            );
        },
    }
}

fn compareExternNames(
    allocator: std.mem.Allocator,
    configured: []const []const u8,
    native: []const wasm_metadata.Extern,
    mismatch: Error,
) Error!void {
    if (configured.len > max_component_externs)
        return error.ComponentMetadataTooLarge;
    if (configured.len != native.len) return mismatch;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var total: usize = 0;
    for (configured) |name| {
        if (name.len == 0 or name.len > max_component_name_bytes or
            !std.unicode.utf8ValidateSlice(name))
            return error.InvalidConfigExtern;
        total = std.math.add(usize, total, name.len) catch
            return error.ComponentMetadataTooLarge;
        if (total > max_component_metadata_bytes)
            return error.ComponentMetadataTooLarge;
        const entry = try seen.getOrPut(allocator, name);
        if (entry.found_existing) return error.DuplicateConfigExtern;
    }
    for (native) |external| {
        if (!seen.contains(external.name)) return mismatch;
    }
}

fn cloneDescriptor(
    allocator: std.mem.Allocator,
    source: model.Descriptor,
) Error!model.Descriptor {
    return .{
        .mediaType = try allocator.dupe(u8, source.mediaType),
        .digest = try allocator.dupe(u8, source.digest),
        .size = source.size,
        .urls = try cloneOptionalStrings(allocator, source.urls),
        .annotations = if (source.annotations) |annotations|
            try cloneAnnotations(allocator, annotations)
        else
            null,
        .data = if (source.data) |data| try allocator.dupe(u8, data) else null,
        .artifactType = if (source.artifactType) |artifact_type|
            try allocator.dupe(u8, artifact_type)
        else
            null,
        .platform = if (source.platform) |platform|
            try clonePlatform(allocator, platform)
        else
            null,
    };
}

fn cloneOptionalStrings(
    allocator: std.mem.Allocator,
    values: ?[]const []const u8,
) Error!?[]const []const u8 {
    const source = values orelse return null;
    const result = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |value, index|
        result[index] = try allocator.dupe(u8, value);
    return result;
}

fn cloneAnnotations(
    allocator: std.mem.Allocator,
    annotations: model.Annotations,
) Error!model.Annotations {
    const source = switch (annotations) {
        .object => |object| object,
        else => return error.MalformedManifest,
    };
    var result: std.json.ObjectMap = .{};
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.MalformedManifest;
        try result.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            .{ .string = try allocator.dupe(u8, entry.value_ptr.string) },
        );
    }
    return .{ .object = result };
}

fn clonePlatform(
    allocator: std.mem.Allocator,
    platform: model.Platform,
) Error!model.Platform {
    return .{
        .architecture = try allocator.dupe(u8, platform.architecture),
        .os = try allocator.dupe(u8, platform.os),
        .@"os.version" = if (platform.@"os.version") |version|
            try allocator.dupe(u8, version)
        else
            null,
        .@"os.features" = try cloneOptionalStrings(allocator, platform.@"os.features"),
        .variant = if (platform.variant) |variant|
            try allocator.dupe(u8, variant)
        else
            null,
        .features = try cloneOptionalStrings(allocator, platform.features),
    };
}

fn allAscii(bytes: []const u8) bool {
    for (bytes) |byte| if (byte >= 0x80) return false;
    return true;
}

fn parseFixedDecimal(bytes: []const u8) ?u16 {
    if (bytes.len == 0) return null;
    var result: u16 = 0;
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
        result = result * 10 + (byte - '0');
    }
    return result;
}

fn daysInMonth(year: u16, month: u16) u16 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

// ── Compact hermetic profile fixtures and tests ──────────────────────────

const testing = std.testing;

fn appendU32(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    value: u32,
) !void {
    var encoded: [5]u8 = undefined;
    const len = @import("../leb128.zig").writeU32Leb128(&encoded, value);
    try bytes.appendSlice(allocator, encoded[0..len]);
}

fn appendName(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) !void {
    try appendU32(bytes, allocator, @intCast(name.len));
    try bytes.appendSlice(allocator, name);
}

fn appendSection(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    id: u8,
    body: []const u8,
) !void {
    try bytes.append(allocator, id);
    try appendU32(bytes, allocator, @intCast(body.len));
    try bytes.appendSlice(allocator, body);
}

fn buildWasiCoreFixture(
    allocator: std.mem.Allocator,
    custom_payload: ?[]const u8,
) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(
        allocator,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 },
    );
    try appendSection(&bytes, allocator, 1, &.{ 0x01, 0x60, 0x00, 0x00 });

    var imports: std.ArrayListUnmanaged(u8) = .empty;
    defer imports.deinit(allocator);
    try imports.append(allocator, 0x01);
    try appendName(&imports, allocator, "wasi_snapshot_preview1");
    try appendName(&imports, allocator, "fd_write");
    try imports.appendSlice(allocator, &.{ 0x00, 0x00 });
    try appendSection(&bytes, allocator, 2, imports.items);

    if (custom_payload) |payload| {
        var custom: std.ArrayListUnmanaged(u8) = .empty;
        defer custom.deinit(allocator);
        try appendName(&custom, allocator, "golden");
        try custom.appendSlice(allocator, payload);
        try appendSection(&bytes, allocator, 0, custom.items);
    }
    return bytes.toOwnedSlice(allocator);
}

const AttributeFixture = union(enum) {
    implements: []const u8,
    version_suffix: []const u8,
    external_id: []const u8,
};

fn appendExternName(
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    attributes: []const AttributeFixture,
) !void {
    try bytes.append(allocator, if (attributes.len == 0) 0x00 else 0x02);
    try appendName(bytes, allocator, name);
    if (attributes.len == 0) return;
    try appendU32(bytes, allocator, @intCast(attributes.len));
    for (attributes) |attribute| switch (attribute) {
        .implements => |value| {
            try bytes.append(allocator, 0x00);
            try appendName(bytes, allocator, value);
        },
        .version_suffix => |value| {
            try bytes.append(allocator, 0x01);
            try appendName(bytes, allocator, value);
        },
        .external_id => |value| {
            try bytes.append(allocator, 0x02);
            try appendName(bytes, allocator, value);
        },
    };
}

fn buildComponentFixture(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(
        allocator,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 },
    );
    try appendSection(
        &bytes,
        allocator,
        7,
        &.{ 0x02, 0x42, 0x00, 0x40, 0x00, 0x01, 0x00 },
    );

    var imports: std.ArrayListUnmanaged(u8) = .empty;
    defer imports.deinit(allocator);
    try imports.append(allocator, 0x02);
    try appendExternName(
        &imports,
        allocator,
        "wasi:io/poll@0.2",
        &.{
            .{ .implements = "wasi:io/poll@0.2" },
            .{ .version_suffix = ".6" },
            .{ .external_id = "urn:wasi:io/poll" },
        },
    );
    try imports.appendSlice(allocator, &.{ 0x05, 0x00 });
    try appendExternName(&imports, allocator, "run-func", &.{});
    try imports.appendSlice(allocator, &.{ 0x01, 0x01 });
    try appendSection(&bytes, allocator, 10, imports.items);

    var exports: std.ArrayListUnmanaged(u8) = .empty;
    defer exports.deinit(allocator);
    try exports.append(allocator, 0x02);
    try appendExternName(
        &exports,
        allocator,
        "wasi:cli/run@0.2.6",
        &.{},
    );
    try exports.appendSlice(allocator, &.{ 0x05, 0x00, 0x00 });
    try appendExternName(&exports, allocator, "run-func", &.{});
    try exports.appendSlice(allocator, &.{ 0x01, 0x00, 0x00 });
    try appendSection(&bytes, allocator, 11, exports.items);

    return bytes.toOwnedSlice(allocator);
}

fn buildBinaryWitFixture(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(
        allocator,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 },
    );
    try appendSection(&bytes, allocator, 7, &.{ 0x01, 0x41, 0x00 });
    var exports: std.ArrayListUnmanaged(u8) = .empty;
    defer exports.deinit(allocator);
    try exports.append(allocator, 0x01);
    try appendExternName(&exports, allocator, "package", &.{});
    try exports.appendSlice(allocator, &.{ 0x03, 0x00, 0x00 });
    try appendSection(&bytes, allocator, 11, exports.items);
    return bytes.toOwnedSlice(allocator);
}

test "safe layer titles are basename-only and conservative" {
    try testing.expectEqualStrings(
        "module.wasm",
        safeLayerTitle(null, .core_module),
    );
    try testing.expectEqualStrings(
        "module.wasm",
        safeLayerTitle("/usr/local/module.wasm", .core_module),
    );
    try testing.expectEqualStrings(
        "component.wasm",
        safeLayerTitle("C:\\work\\component.wasm", .component),
    );
    try testing.expectEqualStrings(
        "escape.wasm",
        safeLayerTitle("../../escape.wasm", .core_module),
    );
    try testing.expectEqualStrings(
        "模型.wasm",
        safeLayerTitle("fixtures/模型.wasm", .core_module),
    );
    try testing.expectEqualStrings(
        "CON:name\".wasm",
        safeLayerTitle("CON:name\".wasm", .core_module),
    );

    const unsafe = [_][]const u8{
        "",
        ".",
        "..",
        "path/",
        "bad\x00.wasm",
        "bad\n.wasm",
        "bad\x7f.wasm",
        "\xff.wasm",
    };
    for (unsafe) |name| {
        try testing.expectEqualStrings(
            "module.wasm",
            safeLayerTitle(name, .core_module),
        );
    }

    var oversized: [max_layer_title_bytes + 1]u8 = @splat('a');
    try testing.expectEqualStrings(
        "module.wasm",
        safeLayerTitle(&oversized, .core_module),
    );
}

test "Wasm-v0 core golden bytes descriptors and round trip" {
    const allocator = testing.allocator;
    const payload = try buildWasiCoreFixture(allocator, "opaque");
    defer allocator.free(payload);

    var artifact = try prepare(allocator, payload, .{
        .created = "2025-01-02T03:04:05Z",
        .author = "WABT",
        .source_name = "/inputs/core-golden.wasm",
    });
    defer artifact.deinit();

    try testing.expectEqual(Profile.wasm_v0, artifact.profile);
    try testing.expectEqual(wasm_metadata.WasmKind.core_module, artifact.kind);
    try testing.expect(artifact.payload_bytes.ptr == payload.ptr);
    try testing.expectEqual(payload.len, artifact.payload_bytes.len);
    try testing.expectEqualStrings(media_type_wasm_config, artifact.config_descriptor.mediaType);
    try testing.expectEqualStrings(media_type_wasm, artifact.layer_descriptor.mediaType);
    try testing.expectEqualStrings(media_type_manifest, artifact.root_descriptor.mediaType);
    try testing.expectEqualStrings(
        "core-golden.wasm",
        artifact.layer_descriptor.annotations.?.object.get(annotation_title).?.string,
    );

    const expected_config =
        "{\"created\":\"2025-01-02T03:04:05Z\",\"author\":\"WABT\",\"architecture\":\"wasm\",\"os\":\"wasip1\",\"layerDigests\":[\"sha256:e26ec1be966c2febead635d81e735e2dc2b7fff8eae9dce2d71042e03d4cd694\"],\"component\":null}";
    const expected_manifest =
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.wasm.config.v0+json\",\"digest\":\"sha256:0e8e095d8f678a5b96ca9ebee509909280194c74bb674ca198ea2989eae5d289\",\"size\":194},\"layers\":[{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:e26ec1be966c2febead635d81e735e2dc2b7fff8eae9dce2d71042e03d4cd694\",\"size\":66,\"annotations\":{\"org.opencontainers.image.title\":\"core-golden.wasm\"}}]}";
    try testing.expectEqualStrings(expected_config, artifact.config_bytes);
    try testing.expectEqualStrings(expected_manifest, artifact.manifest_bytes);
    try testing.expectEqualStrings("sha256:e26ec1be966c2febead635d81e735e2dc2b7fff8eae9dce2d71042e03d4cd694", artifact.layer_descriptor.digest);
    try testing.expectEqualStrings("sha256:0e8e095d8f678a5b96ca9ebee509909280194c74bb674ca198ea2989eae5d289", artifact.config_descriptor.digest);
    try testing.expectEqualStrings("sha256:848f821bfd326348f8813715c8962915cf1117f28128945a50d31b72a5b023ef", artifact.root_descriptor.digest);

    var plan = try classifyDirectManifest(
        allocator,
        artifact.root_descriptor,
        artifact.manifest_bytes,
        artifact.config_bytes,
        artifact.payload_bytes,
    );
    defer plan.deinit();
    try testing.expectEqual(DirectManifestProfile.wasm_v0, plan.profile);
    try testing.expectEqual(wasm_metadata.WasmKind.core_module, plan.kind);
    try testing.expect(plan.manifest_bytes.ptr == artifact.manifest_bytes.ptr);
    try testing.expect(plan.payload_bytes.ptr == payload.ptr);
}

test "Wasm-v0 component golden retains versioned names" {
    const allocator = testing.allocator;
    const payload = try buildComponentFixture(allocator);
    defer allocator.free(payload);

    var artifact = try prepare(allocator, payload, .{
        .created = "2025-06-07T08:09:10.123Z",
        .author = null,
        .source_name = "component.wasm",
    });
    defer artifact.deinit();

    const expected_config =
        "{\"created\":\"2025-06-07T08:09:10.123Z\",\"author\":null,\"architecture\":\"wasm\",\"os\":\"wasip2\",\"layerDigests\":[\"sha256:11333abdd381efa327ca05e1729e873744dcb545fa930da63e4baf5aa653756d\"],\"component\":{\"exports\":[\"wasi:cli/run@0.2.6\",\"run-func\"],\"imports\":[\"wasi:io/poll@0.2.6\",\"run-func\"],\"target\":null}}";
    const expected_manifest =
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.wasm.config.v0+json\",\"digest\":\"sha256:94ecf6e8548ebf4e516496507bbd0b20ed3304b68f0091e33f6449eaf2c6242e\",\"size\":295},\"layers\":[{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:11333abdd381efa327ca05e1729e873744dcb545fa930da63e4baf5aa653756d\",\"size\":132,\"annotations\":{\"org.opencontainers.image.title\":\"component.wasm\"}}]}";
    try testing.expectEqualStrings(expected_config, artifact.config_bytes);
    try testing.expectEqualStrings(expected_manifest, artifact.manifest_bytes);
    try testing.expectEqualStrings("sha256:11333abdd381efa327ca05e1729e873744dcb545fa930da63e4baf5aa653756d", artifact.layer_descriptor.digest);
    try testing.expectEqualStrings("sha256:94ecf6e8548ebf4e516496507bbd0b20ed3304b68f0091e33f6449eaf2c6242e", artifact.config_descriptor.digest);
    try testing.expectEqualStrings("sha256:49cad28f75af0e2f530d5f628cc1522f6845a27ca7b83b9d1dbb8ad26c9c8fe5", artifact.root_descriptor.digest);

    var plan = try classifyDirectManifest(
        allocator,
        artifact.root_descriptor,
        artifact.manifest_bytes,
        artifact.config_bytes,
        artifact.payload_bytes,
    );
    defer plan.deinit();
    try testing.expectEqual(DirectManifestProfile.wasm_v0, plan.profile);
    try testing.expectEqual(wasm_metadata.WasmKind.component, plan.kind);
    try testing.expectEqual(@as(?[]const u8, null), plan.unverified_target);
}

test "fixed time and author are deterministic and explicit" {
    const allocator = testing.allocator;
    const payload = try buildWasiCoreFixture(allocator, null);
    defer allocator.free(payload);

    var first = try prepare(allocator, payload, .{
        .created = "2025-01-01T00:00:00Z",
        .author = "one",
    });
    defer first.deinit();
    var same = try prepare(allocator, payload, .{
        .created = "2025-01-01T00:00:00Z",
        .author = "one",
    });
    defer same.deinit();
    var later = try prepare(allocator, payload, .{
        .created = "2025-01-01T00:00:01Z",
        .author = "one",
    });
    defer later.deinit();
    var other_author = try prepare(allocator, payload, .{
        .created = "2025-01-01T00:00:00Z",
        .author = "two",
    });
    defer other_author.deinit();

    try testing.expectEqualStrings(first.config_bytes, same.config_bytes);
    try testing.expectEqualStrings(first.manifest_bytes, same.manifest_bytes);
    try testing.expectEqualStrings(first.root_descriptor.digest, same.root_descriptor.digest);
    try testing.expect(!std.mem.eql(u8, first.config_descriptor.digest, later.config_descriptor.digest));
    try testing.expect(!std.mem.eql(u8, first.root_descriptor.digest, later.root_descriptor.digest));
    try testing.expect(!std.mem.eql(u8, first.config_descriptor.digest, other_author.config_descriptor.digest));
    try testing.expectEqualStrings(first.layer_descriptor.digest, later.layer_descriptor.digest);
    try testing.expectEqualStrings(first.layer_descriptor.digest, other_author.layer_descriptor.digest);

    try testing.expectError(error.InvalidCreated, prepare(allocator, payload, .{
        .created = "now",
    }));
    try testing.expectError(error.InvalidAuthor, prepare(allocator, payload, .{
        .created = "2025-01-01T00:00:00Z",
        .author = "\xff",
    }));
}

test "generic profile determinism depends on created and title, not author" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var first = try prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2025-01-01T00:00:00Z",
        .author = "first",
        .source_name = "same.wasm",
    });
    defer first.deinit();
    var other_author = try prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2025-01-01T00:00:00Z",
        .author = "second",
        .source_name = "same.wasm",
    });
    defer other_author.deinit();
    var later = try prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2025-01-01T00:00:01Z",
        .author = "first",
        .source_name = "same.wasm",
    });
    defer later.deinit();
    var invalid_author = try prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2025-01-01T00:00:00Z",
        .author = "\xff",
        .source_name = "same.wasm",
    });
    defer invalid_author.deinit();

    try testing.expectEqualStrings(first.manifest_bytes, other_author.manifest_bytes);
    try testing.expectEqualStrings(first.root_descriptor.digest, other_author.root_descriptor.digest);
    try testing.expectEqualStrings(first.manifest_bytes, invalid_author.manifest_bytes);
    try testing.expectEqualStrings(first.root_descriptor.digest, invalid_author.root_descriptor.digest);
    try testing.expect(!std.mem.eql(u8, first.root_descriptor.digest, later.root_descriptor.digest));
    try testing.expectEqualStrings(first.config_descriptor.digest, later.config_descriptor.digest);
    try testing.expectEqualStrings(first.layer_descriptor.digest, later.layer_descriptor.digest);
}

test "generic OCI 1.1 golden is ORAS compatible and classifies" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var artifact = try prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2025-02-03T04:05:06Z",
        .author = "not represented by this profile",
        .source_name = "plain.wasm",
    });
    defer artifact.deinit();

    try testing.expectEqualStrings(empty_config_bytes, artifact.config_bytes);
    try testing.expectEqualStrings(empty_config_digest, artifact.config_descriptor.digest);
    try testing.expectEqual(@as(u64, 2), artifact.config_descriptor.size);
    try testing.expectEqualStrings(media_type_empty_config, artifact.config_descriptor.mediaType);
    const expected_manifest =
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"artifactType\":\"application/wasm\",\"config\":{\"mediaType\":\"application/vnd.oci.empty.v1+json\",\"digest\":\"sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\",\"size\":2},\"layers\":[{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:93a44bbb96c751218e4c00d479e4c14358122a389acca16205b1e4d0dc5f9476\",\"size\":8,\"annotations\":{\"org.opencontainers.image.title\":\"plain.wasm\"}}],\"annotations\":{\"org.opencontainers.image.created\":\"2025-02-03T04:05:06Z\"}}";
    try testing.expectEqualStrings(expected_manifest, artifact.manifest_bytes);
    try testing.expectEqualStrings("sha256:5d733aeb27f01d56c3d42b8a72085ddd1b7258d1c79d92aae82be37efbeee372", artifact.root_descriptor.digest);

    var plan = try classifyDirectManifest(
        allocator,
        artifact.root_descriptor,
        artifact.manifest_bytes,
        artifact.config_bytes,
        artifact.payload_bytes,
    );
    defer plan.deinit();
    try testing.expectEqual(DirectManifestProfile.oci_1_1, plan.profile);
    try testing.expectEqual(wasm_metadata.WasmKind.core_module, plan.kind);
}

const TestManifest = struct {
    schemaVersion: u32,
    mediaType: []const u8,
    artifactType: ?[]const u8 = null,
    config: JsonDescriptor,
    layers: []const JsonDescriptor,
    subject: ?JsonDescriptor = null,
};

const TestManifestOptions = struct {
    schema_version: u32 = 2,
    manifest_media_type: []const u8 = media_type_manifest,
    artifact_type: ?[]const u8 = null,
    config_media_type: []const u8,
    config_digest: ?[]const u8 = null,
    config_size: ?u64 = null,
    layer_media_type: []const u8 = media_type_wasm,
    layer_digest: ?[]const u8 = null,
    layer_size: ?u64 = null,
    layer_count: usize = 1,
    subject: bool = false,
};

const TestBuiltManifest = struct {
    bytes: []u8,
    digest: [content.digest_text_size]u8,

    fn deinit(self: *TestBuiltManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    fn rootDescriptor(self: *const TestBuiltManifest) model.Descriptor {
        return .{
            .mediaType = media_type_manifest,
            .digest = &self.digest,
            .size = self.bytes.len,
        };
    }
};

fn buildRawTestManifest(bytes: []u8) TestBuiltManifest {
    return .{
        .bytes = bytes,
        .digest = content.digestBytes(bytes).format(),
    };
}

fn buildTestManifest(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    payload_bytes: []const u8,
    options: TestManifestOptions,
) !TestBuiltManifest {
    const actual_config_digest = content.digestBytes(config_bytes).format();
    const actual_layer_digest = content.digestBytes(payload_bytes).format();
    const config_digest = options.config_digest orelse &actual_config_digest;
    const layer_digest = options.layer_digest orelse &actual_layer_digest;
    const config_size = options.config_size orelse try content.checkedSize(config_bytes.len);
    const layer_size = options.layer_size orelse try content.checkedSize(payload_bytes.len);

    const layers = try allocator.alloc(JsonDescriptor, options.layer_count);
    defer allocator.free(layers);
    for (layers) |*layer| {
        layer.* = .{
            .mediaType = options.layer_media_type,
            .digest = layer_digest,
            .size = layer_size,
        };
    }
    const subject: ?JsonDescriptor = if (options.subject) .{
        .mediaType = media_type_manifest,
        .digest = &actual_layer_digest,
        .size = layer_size,
    } else null;
    const bytes = try std.json.Stringify.valueAlloc(
        allocator,
        TestManifest{
            .schemaVersion = options.schema_version,
            .mediaType = options.manifest_media_type,
            .artifactType = options.artifact_type,
            .config = .{
                .mediaType = options.config_media_type,
                .digest = config_digest,
                .size = config_size,
            },
            .layers = layers,
            .subject = subject,
        },
        .{ .emit_null_optional_fields = false },
    );
    return .{
        .bytes = bytes,
        .digest = content.digestBytes(bytes).format(),
    };
}

fn wasmV0ConfigForTest(
    allocator: std.mem.Allocator,
    architecture: []const u8,
    os: []const u8,
    layer_digests_json: []const u8,
    component_json: []const u8,
    extension_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"created\":\"2025-01-02T03:04:05Z\",\"author\":null,\"architecture\":\"{s}\",\"os\":\"{s}\",\"layerDigests\":{s},\"component\":{s}{s}}}",
        .{
            architecture,
            os,
            layer_digests_json,
            component_json,
            extension_json,
        },
    );
}

test "generic OCI 1.0 documented read shape is accepted only when explicit" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .config_media_type = media_type_wasm,
    });
    defer fixture.deinit(allocator);
    const expected_manifest =
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\",\"size\":2},\"layers\":[{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:93a44bbb96c751218e4c00d479e4c14358122a389acca16205b1e4d0dc5f9476\",\"size\":8}]}";
    try testing.expectEqualStrings(expected_manifest, fixture.bytes);
    try testing.expectEqualStrings(
        "sha256:6f0c2ca871b835821b98dc1da5a2e02a864742e1b7165b65a891fcab9c3ee850",
        &fixture.digest,
    );

    var plan = try classifyDirectManifest(
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        empty_config_bytes,
        &payload,
    );
    defer plan.deinit();
    try testing.expectEqual(DirectManifestProfile.oci_1_0, plan.profile);
    try testing.expectEqual(wasm_metadata.WasmKind.core_module, plan.kind);
    try testing.expectEqualStrings(media_type_wasm, plan.config_descriptor.mediaType);
}

test "payload custom sections remain byte-identical and content-addressed" {
    const allocator = testing.allocator;
    const first_payload = try buildWasiCoreFixture(allocator, "first");
    defer allocator.free(first_payload);
    const second_payload = try buildWasiCoreFixture(allocator, "second");
    defer allocator.free(second_payload);

    var first = try prepare(allocator, first_payload, .{
        .created = "2025-01-01T00:00:00Z",
    });
    defer first.deinit();
    var second = try prepare(allocator, second_payload, .{
        .created = "2025-01-01T00:00:00Z",
    });
    defer second.deinit();

    try testing.expect(first.payload_bytes.ptr == first_payload.ptr);
    try testing.expect(second.payload_bytes.ptr == second_payload.ptr);
    try testing.expectEqualSlices(u8, first_payload, first.payload_bytes);
    try testing.expectEqualSlices(u8, second_payload, second.payload_bytes);
    try testing.expect(!std.mem.eql(u8, first.layer_descriptor.digest, second.layer_descriptor.digest));
    try testing.expect(!std.mem.eql(u8, first.config_descriptor.digest, second.config_descriptor.digest));
    try testing.expect(!std.mem.eql(u8, first.root_descriptor.digest, second.root_descriptor.digest));
}

test "Wasm-v0 preparation uses profile labels after native validation" {
    const allocator = testing.allocator;
    const plain_core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var wasm_v0 = try prepare(allocator, &plain_core, .{
        .created = "2025-01-01T00:00:00Z",
    });
    defer wasm_v0.deinit();
    try testing.expectEqual(WasmKind.core_module, wasm_v0.kind);
    try testing.expect(std.mem.indexOf(
        u8,
        wasm_v0.config_bytes,
        "\"os\":\"wasip1\",\"layerDigests\"",
    ) != null);

    var generic = try prepare(allocator, &plain_core, .{
        .profile = .oci,
        .created = "2025-01-01T00:00:00Z",
    });
    defer generic.deinit();
    try testing.expectEqual(wasm_metadata.WasmKind.core_module, generic.kind);

    const unsupported_component = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        0x0c, 0x01, 0x00,
    };
    try testing.expectError(
        error.UnsupportedComponentSection,
        prepare(allocator, &unsupported_component, .{
            .created = "2025-01-01T00:00:00Z",
        }),
    );
    const binary_wit = try buildBinaryWitFixture(allocator);
    defer allocator.free(binary_wit);
    try testing.expectError(
        error.BinaryWitUnsupported,
        prepare(allocator, binary_wit, .{
            .created = "2025-01-01T00:00:00Z",
        }),
    );
    try testing.expectError(error.InvalidWasm, prepare(allocator, "not wasm", .{
        .profile = .oci,
        .created = "2025-01-01T00:00:00Z",
    }));
}

test "classifier rejects indexes subjects layer counts and unsupported media" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    const index_bytes =
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[]}";
    const index_digest = content.digestBytes(index_bytes).format();
    const index_root = model.Descriptor{
        .mediaType = media_type_index,
        .digest = &index_digest,
        .size = index_bytes.len,
    };
    try testing.expectError(
        error.DirectManifestRequired,
        classifyDirectManifest(
            allocator,
            index_root,
            index_bytes,
            empty_config_bytes,
            &payload,
        ),
    );

    var zero = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .layer_count = 0,
    });
    defer zero.deinit(allocator);
    try testing.expectError(error.InvalidLayerCount, classifyDirectManifest(
        allocator,
        zero.rootDescriptor(),
        zero.bytes,
        empty_config_bytes,
        &payload,
    ));

    var two = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .layer_count = 2,
    });
    defer two.deinit(allocator);
    try testing.expectError(error.InvalidLayerCount, classifyDirectManifest(
        allocator,
        two.rootDescriptor(),
        two.bytes,
        empty_config_bytes,
        &payload,
    ));

    var subject = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .subject = true,
    });
    defer subject.deinit(allocator);
    try testing.expectError(error.ManifestSubjectUnsupported, classifyDirectManifest(
        allocator,
        subject.rootDescriptor(),
        subject.bytes,
        empty_config_bytes,
        &payload,
    ));

    const unsupported_layers = [_][]const u8{
        model.media_type_oci_layer,
        model.media_type_oci_layer_gzip,
        model.media_type_oci_layer_zstd,
        "application/octet-stream",
    };
    for (unsupported_layers) |layer_media_type| {
        var unsupported_layer = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
            .artifact_type = artifact_type_wasm,
            .config_media_type = media_type_empty_config,
            .layer_media_type = layer_media_type,
        });
        defer unsupported_layer.deinit(allocator);
        try testing.expectError(error.UnsupportedLayerMediaType, classifyDirectManifest(
            allocator,
            unsupported_layer.rootDescriptor(),
            unsupported_layer.bytes,
            empty_config_bytes,
            &payload,
        ));
    }

    var docker = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .manifest_media_type = model.media_type_docker_manifest,
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer docker.deinit(allocator);
    try testing.expectError(error.UnsupportedManifestMediaType, classifyDirectManifest(
        allocator,
        docker.rootDescriptor(),
        docker.bytes,
        empty_config_bytes,
        &payload,
    ));

    var artifact_manifest = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .manifest_media_type = "application/vnd.oci.artifact.manifest.v1+json",
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer artifact_manifest.deinit(allocator);
    try testing.expectError(error.UnsupportedManifestMediaType, classifyDirectManifest(
        allocator,
        artifact_manifest.rootDescriptor(),
        artifact_manifest.bytes,
        empty_config_bytes,
        &payload,
    ));

    var schema_one = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .schema_version = 1,
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer schema_one.deinit(allocator);
    try testing.expectError(error.MalformedManifest, classifyDirectManifest(
        allocator,
        schema_one.rootDescriptor(),
        schema_one.bytes,
        empty_config_bytes,
        &payload,
    ));

    var valid = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer valid.deinit(allocator);
    var bad_root_media = valid.rootDescriptor();
    bad_root_media.mediaType = model.media_type_docker_manifest;
    try testing.expectError(error.UnsupportedRootMediaType, classifyDirectManifest(
        allocator,
        bad_root_media,
        valid.bytes,
        empty_config_bytes,
        &payload,
    ));

    const malformed = "{";
    const malformed_digest = content.digestBytes(malformed).format();
    const malformed_root = model.Descriptor{
        .mediaType = media_type_manifest,
        .digest = &malformed_digest,
        .size = malformed.len,
    };
    try testing.expectError(error.MalformedManifest, classifyDirectManifest(
        allocator,
        malformed_root,
        malformed,
        empty_config_bytes,
        &payload,
    ));
}

test "classifier rejects ambiguous and mixed generic profiles" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const cases = [_]TestManifestOptions{
        .{ .config_media_type = media_type_empty_config },
        .{
            .artifact_type = artifact_type_wasm,
            .config_media_type = media_type_wasm,
        },
        .{
            .artifact_type = artifact_type_wasm,
            .config_media_type = media_type_wasm_config,
        },
        .{ .config_media_type = "application/octet-stream" },
        .{
            .artifact_type = "application/example",
            .config_media_type = media_type_empty_config,
        },
    };
    for (cases) |case| {
        var fixture = try buildTestManifest(
            allocator,
            empty_config_bytes,
            &payload,
            case,
        );
        defer fixture.deinit(allocator);
        try testing.expectError(error.UnsupportedProfile, classifyDirectManifest(
            allocator,
            fixture.rootDescriptor(),
            fixture.bytes,
            empty_config_bytes,
            &payload,
        ));
    }

    const spaced_empty = "{ }";
    var noncanonical = try buildTestManifest(allocator, spaced_empty, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer noncanonical.deinit(allocator);
    try testing.expectError(error.InvalidEmptyConfig, classifyDirectManifest(
        allocator,
        noncanonical.rootDescriptor(),
        noncanonical.bytes,
        spaced_empty,
        &payload,
    ));

    var generic = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer generic.deinit(allocator);

    const subject_null_bytes = try std.fmt.allocPrint(
        allocator,
        "{s},\"subject\":null}}",
        .{generic.bytes[0 .. generic.bytes.len - 1]},
    );
    var subject_null = buildRawTestManifest(subject_null_bytes);
    defer subject_null.deinit(allocator);
    try testing.expectError(error.ManifestSubjectUnsupported, classifyDirectManifest(
        allocator,
        subject_null.rootDescriptor(),
        subject_null.bytes,
        empty_config_bytes,
        &payload,
    ));

    var oci_1_0 = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .config_media_type = media_type_wasm,
    });
    defer oci_1_0.deinit(allocator);
    const artifact_null_bytes = try std.fmt.allocPrint(
        allocator,
        "{s},\"artifactType\":null}}",
        .{oci_1_0.bytes[0 .. oci_1_0.bytes.len - 1]},
    );
    var artifact_null = buildRawTestManifest(artifact_null_bytes);
    defer artifact_null.deinit(allocator);
    try testing.expectError(error.UnsupportedProfile, classifyDirectManifest(
        allocator,
        artifact_null.rootDescriptor(),
        artifact_null.bytes,
        empty_config_bytes,
        &payload,
    ));

    const extension_bytes = try std.fmt.allocPrint(
        allocator,
        "{s},\"x-profile-extension\":{{\"ignored\":true}}}}",
        .{generic.bytes[0 .. generic.bytes.len - 1]},
    );
    var extension = buildRawTestManifest(extension_bytes);
    defer extension.deinit(allocator);
    var extension_plan = try classifyDirectManifest(
        allocator,
        extension.rootDescriptor(),
        extension.bytes,
        empty_config_bytes,
        &payload,
    );
    defer extension_plan.deinit();
    try testing.expectEqual(DirectManifestProfile.oci_1_1, extension_plan.profile);
}

test "descriptor verification rejects moved roots and blob mismatches" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var valid = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer valid.deinit(allocator);

    var wrong_root_size = valid.rootDescriptor();
    wrong_root_size.size += 1;
    try testing.expectError(error.SizeMismatch, classifyDirectManifest(
        allocator,
        wrong_root_size,
        valid.bytes,
        empty_config_bytes,
        &payload,
    ));
    var wrong_root_digest = valid.rootDescriptor();
    wrong_root_digest.digest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try testing.expectError(error.DigestMismatch, classifyDirectManifest(
        allocator,
        wrong_root_digest,
        valid.bytes,
        empty_config_bytes,
        &payload,
    ));

    var wrong_config_size = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .config_size = 3,
    });
    defer wrong_config_size.deinit(allocator);
    try testing.expectError(error.SizeMismatch, classifyDirectManifest(
        allocator,
        wrong_config_size.rootDescriptor(),
        wrong_config_size.bytes,
        empty_config_bytes,
        &payload,
    ));
    var wrong_config_digest = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .config_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });
    defer wrong_config_digest.deinit(allocator);
    try testing.expectError(error.DigestMismatch, classifyDirectManifest(
        allocator,
        wrong_config_digest.rootDescriptor(),
        wrong_config_digest.bytes,
        empty_config_bytes,
        &payload,
    ));

    var wrong_layer_size = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .layer_size = 9,
    });
    defer wrong_layer_size.deinit(allocator);
    try testing.expectError(error.SizeMismatch, classifyDirectManifest(
        allocator,
        wrong_layer_size.rootDescriptor(),
        wrong_layer_size.bytes,
        empty_config_bytes,
        &payload,
    ));
    var wrong_layer_digest = try buildTestManifest(allocator, empty_config_bytes, &payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
        .layer_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });
    defer wrong_layer_digest.deinit(allocator);
    try testing.expectError(error.DigestMismatch, classifyDirectManifest(
        allocator,
        wrong_layer_digest.rootDescriptor(),
        wrong_layer_digest.bytes,
        empty_config_bytes,
        &payload,
    ));

    var noncanonical_digest = valid.rootDescriptor();
    noncanonical_digest.digest =
        "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try testing.expectError(error.InvalidDigest, classifyDirectManifest(
        allocator,
        noncanonical_digest,
        valid.bytes,
        empty_config_bytes,
        &payload,
    ));
}

test "Wasm-v0 core config consistency is strict" {
    const allocator = testing.allocator;
    const payload = try buildWasiCoreFixture(allocator, null);
    defer allocator.free(payload);
    const layer_digest = content.digestBytes(payload).format();
    const layer_digests = try std.fmt.allocPrint(
        allocator,
        "[\"{s}\"]",
        .{&layer_digest},
    );
    defer allocator.free(layer_digests);

    const valid_config = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip1",
        layer_digests,
        "null",
        "",
    );
    defer allocator.free(valid_config);
    var valid = try buildTestManifest(allocator, valid_config, payload, .{
        .config_media_type = media_type_wasm_config,
    });
    defer valid.deinit(allocator);
    var valid_plan = try classifyDirectManifest(
        allocator,
        valid.rootDescriptor(),
        valid.bytes,
        valid_config,
        payload,
    );
    valid_plan.deinit();

    const wrong_arch = try wasmV0ConfigForTest(
        allocator,
        "amd64",
        "wasip1",
        layer_digests,
        "null",
        "",
    );
    defer allocator.free(wrong_arch);
    var wrong_arch_manifest = try buildTestManifest(allocator, wrong_arch, payload, .{
        .config_media_type = media_type_wasm_config,
    });
    defer wrong_arch_manifest.deinit(allocator);
    try testing.expectError(error.ArchitectureMismatch, classifyDirectManifest(
        allocator,
        wrong_arch_manifest.rootDescriptor(),
        wrong_arch_manifest.bytes,
        wrong_arch,
        payload,
    ));

    const wrong_os = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "null",
        "",
    );
    defer allocator.free(wrong_os);
    var wrong_os_manifest = try buildTestManifest(allocator, wrong_os, payload, .{
        .config_media_type = media_type_wasm_config,
    });
    defer wrong_os_manifest.deinit(allocator);
    try testing.expectError(error.OsMismatch, classifyDirectManifest(
        allocator,
        wrong_os_manifest.rootDescriptor(),
        wrong_os_manifest.bytes,
        wrong_os,
        payload,
    ));

    const wrong_digests = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip1",
        "[]",
        "null",
        "",
    );
    defer allocator.free(wrong_digests);
    var wrong_digests_manifest = try buildTestManifest(
        allocator,
        wrong_digests,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer wrong_digests_manifest.deinit(allocator);
    try testing.expectError(error.LayerDigestsMismatch, classifyDirectManifest(
        allocator,
        wrong_digests_manifest.rootDescriptor(),
        wrong_digests_manifest.bytes,
        wrong_digests,
        payload,
    ));

    const dishonest_component = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip1",
        layer_digests,
        "{\"exports\":[],\"imports\":[],\"target\":null}",
        "",
    );
    defer allocator.free(dishonest_component);
    var dishonest_manifest = try buildTestManifest(
        allocator,
        dishonest_component,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer dishonest_manifest.deinit(allocator);
    try testing.expectError(error.ComponentPresenceMismatch, classifyDirectManifest(
        allocator,
        dishonest_manifest.rootDescriptor(),
        dishonest_manifest.bytes,
        dishonest_component,
        payload,
    ));

    const unknown_field = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip1",
        layer_digests,
        "null",
        ",\"unknown\":true",
    );
    defer allocator.free(unknown_field);
    var unknown_manifest = try buildTestManifest(
        allocator,
        unknown_field,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer unknown_manifest.deinit(allocator);
    try testing.expectError(error.MalformedWasmV0Config, classifyDirectManifest(
        allocator,
        unknown_manifest.rootDescriptor(),
        unknown_manifest.bytes,
        unknown_field,
        payload,
    ));

    const missing_author =
        try std.fmt.allocPrint(
            allocator,
            "{{\"created\":\"2025-01-02T03:04:05Z\",\"architecture\":\"wasm\",\"os\":\"wasip1\",\"layerDigests\":[\"{s}\"],\"component\":null}}",
            .{&layer_digest},
        );
    defer allocator.free(missing_author);
    var missing_manifest = try buildTestManifest(
        allocator,
        missing_author,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer missing_manifest.deinit(allocator);
    try testing.expectError(error.MalformedWasmV0Config, classifyDirectManifest(
        allocator,
        missing_manifest.rootDescriptor(),
        missing_manifest.bytes,
        missing_author,
        payload,
    ));
}

test "Wasm-v0 component config compares names as duplicate-free sets" {
    const allocator = testing.allocator;
    const payload = try buildComponentFixture(allocator);
    defer allocator.free(payload);
    const layer_digest = content.digestBytes(payload).format();
    const layer_digests = try std.fmt.allocPrint(
        allocator,
        "[\"{s}\"]",
        .{&layer_digest},
    );
    defer allocator.free(layer_digests);

    const reordered = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "{\"exports\":[\"run-func\",\"wasi:cli/run@0.2.6\"],\"imports\":[\"run-func\",\"wasi:io/poll@0.2.6\"],\"target\":\"wasi:cli/command@0.2.6\"}",
        "",
    );
    defer allocator.free(reordered);
    var reordered_manifest = try buildTestManifest(
        allocator,
        reordered,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer reordered_manifest.deinit(allocator);
    var plan = try classifyDirectManifest(
        allocator,
        reordered_manifest.rootDescriptor(),
        reordered_manifest.bytes,
        reordered,
        payload,
    );
    defer plan.deinit();
    try testing.expectEqual(DirectManifestProfile.wasm_v0, plan.profile);
    try testing.expectEqualStrings(
        "wasi:cli/command@0.2.6",
        plan.unverified_target.?,
    );

    const missing_target = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "{\"exports\":[\"wasi:cli/run@0.2.6\",\"run-func\"],\"imports\":[\"wasi:io/poll@0.2.6\",\"run-func\"]}",
        "",
    );
    defer allocator.free(missing_target);
    var missing_target_manifest = try buildTestManifest(
        allocator,
        missing_target,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer missing_target_manifest.deinit(allocator);
    var missing_target_plan = try classifyDirectManifest(
        allocator,
        missing_target_manifest.rootDescriptor(),
        missing_target_manifest.bytes,
        missing_target,
        payload,
    );
    defer missing_target_plan.deinit();
    try testing.expectEqual(@as(?[]const u8, null), missing_target_plan.unverified_target);

    const missing_component = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "null",
        "",
    );
    defer allocator.free(missing_component);
    var missing_manifest = try buildTestManifest(
        allocator,
        missing_component,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer missing_manifest.deinit(allocator);
    try testing.expectError(error.ComponentPresenceMismatch, classifyDirectManifest(
        allocator,
        missing_manifest.rootDescriptor(),
        missing_manifest.bytes,
        missing_component,
        payload,
    ));

    const bad_import = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "{\"exports\":[\"wasi:cli/run@0.2.6\",\"run-func\"],\"imports\":[\"wrong\",\"run-func\"],\"target\":null}",
        "",
    );
    defer allocator.free(bad_import);
    var bad_import_manifest = try buildTestManifest(
        allocator,
        bad_import,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer bad_import_manifest.deinit(allocator);
    try testing.expectError(error.ComponentImportsMismatch, classifyDirectManifest(
        allocator,
        bad_import_manifest.rootDescriptor(),
        bad_import_manifest.bytes,
        bad_import,
        payload,
    ));

    const bad_export = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "{\"exports\":[\"wrong\",\"run-func\"],\"imports\":[\"wasi:io/poll@0.2.6\",\"run-func\"],\"target\":null}",
        "",
    );
    defer allocator.free(bad_export);
    var bad_export_manifest = try buildTestManifest(
        allocator,
        bad_export,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer bad_export_manifest.deinit(allocator);
    try testing.expectError(error.ComponentExportsMismatch, classifyDirectManifest(
        allocator,
        bad_export_manifest.rootDescriptor(),
        bad_export_manifest.bytes,
        bad_export,
        payload,
    ));

    const duplicate_import = try wasmV0ConfigForTest(
        allocator,
        "wasm",
        "wasip2",
        layer_digests,
        "{\"exports\":[\"wasi:cli/run@0.2.6\",\"run-func\"],\"imports\":[\"run-func\",\"run-func\"],\"target\":null}",
        "",
    );
    defer allocator.free(duplicate_import);
    var duplicate_manifest = try buildTestManifest(
        allocator,
        duplicate_import,
        payload,
        .{ .config_media_type = media_type_wasm_config },
    );
    defer duplicate_manifest.deinit(allocator);
    try testing.expectError(error.DuplicateConfigExtern, classifyDirectManifest(
        allocator,
        duplicate_manifest.rootDescriptor(),
        duplicate_manifest.bytes,
        duplicate_import,
        payload,
    ));
}

test "classifier rejects invalid payload behind canonical Wasm descriptors" {
    const allocator = testing.allocator;
    const payload = "not wasm";
    var fixture = try buildTestManifest(allocator, empty_config_bytes, payload, .{
        .artifact_type = artifact_type_wasm,
        .config_media_type = media_type_empty_config,
    });
    defer fixture.deinit(allocator);
    try testing.expectError(error.InvalidWasm, classifyDirectManifest(
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        empty_config_bytes,
        payload,
    ));
}

test "RFC 3339 creation values are validated and preserved exactly" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const valid = [_][]const u8{
        "2024-02-29T23:59:60Z",
        "2025-01-02t03:04:05.123456789+05:30",
        "2025-01-02T03:04:05-00:00",
    };
    for (valid) |created| {
        var artifact = try prepare(allocator, &payload, .{
            .profile = .oci,
            .created = created,
        });
        defer artifact.deinit();
        try testing.expect(std.mem.indexOf(u8, artifact.manifest_bytes, created) != null);
    }

    const invalid = [_][]const u8{
        "2023-02-29T00:00:00Z",
        "2025-13-01T00:00:00Z",
        "2025-01-01T24:00:00Z",
        "2025-01-01T00:00:00",
        "2025-01-01T00:00:00.",
        "2025-01-01T00:00:00+24:00",
    };
    for (invalid) |created| {
        try testing.expectError(error.InvalidCreated, prepare(allocator, &payload, .{
            .profile = .oci,
            .created = created,
        }));
    }
}
