//! Strict extraction of one already-resolved direct-manifest Wasm artifact.
//!
//! The caller supplies the exact root descriptor, manifest/config bytes, one
//! layer reader, and an explicit output path. Layer titles are never paths.
//! The layer is streamed into a unique sibling file, checked for exact size
//! and SHA-256, synced, natively validated through
//! `wasm.classifyDirectManifest`, and only then atomically published.
//!
//! Files are synced before publication. Zig's portable `std.Io` exposes file
//! sync and atomic rename, but no portable directory-sync primitive, so this
//! does not promise stronger power-loss durability than those operations.

const builtin = @import("builtin");
const std = @import("std");
const content = @import("content.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");
const registry = @import("registry.zig");
const transport = @import("transport.zig");
const wasm = @import("wasm.zig");

const Io = std.Io;

pub const Error = error{
    InvalidOutputPath,
    DestinationExists,
    DestinationChanged,
    DestinationIsDirectory,
    DestinationIsSymlink,
    UnsupportedDestinationType,
    InvalidSourceRead,
    StagedFileChanged,
} || wasm.Error || std.mem.Allocator.Error;

/// Pull-neutral sequential layer source. Implementations must return zero only
/// at end-of-stream and must never return more than `destination.len`.
pub const LayerSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (
            context: *anyopaque,
            destination: []u8,
        ) anyerror!usize,
    };

    pub fn init(pointer: anytype) LayerSource {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn read(
                context: *anyopaque,
                destination: []u8,
            ) anyerror!usize {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.read(destination);
            }

            const vtable: VTable = .{ .read = @This().read };
        };

        return .{
            .context = pointer,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn read(self: LayerSource, destination: []u8) !usize {
        const count = try self.vtable.read(self.context, destination);
        if (count > destination.len) return error.InvalidSourceRead;
        return count;
    }
};

const FailurePoint = enum {
    none,
    after_first_write,
    before_file_sync,
    before_rename,
};

const PublishHook = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        run: *const fn (
            context: *anyopaque,
            io: Io,
            parent: Io.Dir,
            output_name: []const u8,
            staging_name: []const u8,
        ) anyerror!void,
    };

    pub fn init(pointer: anytype) PublishHook {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn run(
                context: *anyopaque,
                io: Io,
                parent: Io.Dir,
                output_name: []const u8,
                staging_name: []const u8,
            ) anyerror!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.run(
                    io,
                    parent,
                    output_name,
                    staging_name,
                );
            }

            const vtable: VTable = .{ .run = @This().run };
        };

        return .{
            .context = pointer,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn run(
        self: PublishHook,
        io: Io,
        parent: Io.Dir,
        output_name: []const u8,
        staging_name: []const u8,
    ) !void {
        return self.vtable.run(
            self.context,
            io,
            parent,
            output_name,
            staging_name,
        );
    }
};

pub const Options = struct {
    /// Atomically replace one pre-existing regular file. Directories,
    /// symlinks, and other destination types are always rejected.
    force: bool = false,
};

const TestOptions = struct {
    failure_point: FailurePoint = .none,
    before_checks: ?PublishHook = null,
    after_checks: ?PublishHook = null,
};

pub const Result = struct {
    profile: wasm.DirectManifestProfile,
    kind: wasm.WasmKind,
    bytes_written: u64,
};

const DestinationSnapshot = union(enum) {
    missing,
    file: FileIdentity,
};

const FileIdentity = struct {
    inode: Io.File.INode,
    ctime: Io.Timestamp,
    mtime: Io.Timestamp,
    size: u64,
};

const Temporary = struct {
    name: []u8,
    file: Io.File,
};

const ConfigInput = union(enum) {
    exact: []const u8,
    source: transport.Source,
};

const LayerInput = union(enum) {
    sequential: LayerSource,
    source: transport.Source,
};

/// Extract exactly one supported raw `application/wasm` layer.
///
/// No registry resolution, index selection, archive unpacking, title-derived
/// path selection, or execution occurs here.
pub fn directManifest(
    io: Io,
    allocator: std.mem.Allocator,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
    config_bytes: []const u8,
    layer_source: LayerSource,
    output_path: []const u8,
    options: Options,
) !Result {
    return directManifestImpl(
        io,
        allocator,
        root_descriptor,
        manifest_bytes,
        .{ .exact = config_bytes },
        .{ .sequential = layer_source },
        output_path,
        options,
        .{},
    );
}

/// Extracts one already-resolved direct manifest through a generic transport
/// source. The exact resolved manifest is never fetched again; only its
/// bounded config blob and selected raw Wasm layer are requested by digest.
pub fn fromResolvedSource(
    io: Io,
    allocator: std.mem.Allocator,
    source: transport.Source,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
    output_path: []const u8,
    options: Options,
) !Result {
    return directManifestImpl(
        io,
        allocator,
        root_descriptor,
        manifest_bytes,
        .{ .source = source },
        .{ .source = source },
        output_path,
        options,
        .{},
    );
}

/// Resolves one layout root and extracts it only if that root is a supported
/// direct manifest. Index children and host platforms are never selected.
pub fn fromLayoutSource(
    allocator: std.mem.Allocator,
    source: *layout.Source,
    layout_reference: reference.LayoutReference,
    output_path: []const u8,
    options: Options,
) !Result {
    var resolved = try source.resolve(layout_reference);
    defer resolved.deinit();
    return fromResolvedSource(
        source.io,
        allocator,
        source.asTransport(),
        resolved.descriptor,
        resolved.bytes,
        output_path,
        options,
    );
}

/// Resolves a registry tag or digest exactly once, then reads config and layer
/// content only through the immutable descriptors from that response.
pub fn fromRegistrySource(
    allocator: std.mem.Allocator,
    source: *registry.Source,
    registry_reference: reference.RegistryReference,
    output_path: []const u8,
    options: Options,
) !Result {
    var resolved = try source.resolve(registry_reference);
    defer resolved.deinit();
    return fromResolvedSource(
        source.io,
        allocator,
        source.asTransport(),
        resolved.descriptor,
        resolved.bytes,
        output_path,
        options,
    );
}

fn directManifestImpl(
    io: Io,
    allocator: std.mem.Allocator,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
    config_input: ConfigInput,
    layer_input: LayerInput,
    output_path: []const u8,
    options: Options,
    test_options: TestOptions,
) !Result {
    const output_name = try outputName(output_path);
    const parent_path = std.fs.path.dirname(output_path) orelse ".";
    var parent = try Io.Dir.cwd().openDir(io, parent_path, .{});
    defer parent.close(io);

    const destination = try initialDestination(
        io,
        parent,
        output_name,
        options.force,
    );

    var candidate = try inspectDirectManifest(
        allocator,
        root_descriptor,
        manifest_bytes,
    );
    defer candidate.deinit();
    if (candidate.layer_descriptor.size > wasm.max_payload_bytes)
        return error.PayloadTooLarge;

    var config_metadata: ?transport.Metadata = null;
    defer if (config_metadata) |*metadata| metadata.deinit();
    const config_bytes = switch (config_input) {
        .exact => |bytes| bytes,
        .source => |source| blk: {
            config_metadata = try source.readVerifiedBlob(
                allocator,
                candidate.config_descriptor,
                wasm.max_config_bytes,
            );
            break :blk config_metadata.?.bytes;
        },
    };
    try validateCandidateConfig(&candidate, config_bytes);

    const temporary = try createUniqueTemporary(io, allocator, parent);
    defer allocator.free(temporary.name);
    var file = temporary.file;
    var file_closed = false;
    var published = false;
    defer {
        if (!file_closed) file.close(io);
        if (!published) parent.deleteFile(io, temporary.name) catch {};
    }

    switch (layer_input) {
        .sequential => |layer_source| {
            var verifier = content.Verifier.init(
                try content.Digest.parse(candidate.layer_descriptor.digest),
                candidate.layer_descriptor.size,
            );
            var buffer: [transport.copy_buffer_size]u8 = undefined;
            var wrote_any = false;
            while (true) {
                const count = try layer_source.read(&buffer);
                if (count == 0) break;
                const chunk = buffer[0..count];
                try verifier.update(chunk);
                try file.writeStreamingAll(io, chunk);
                if (!wrote_any) {
                    wrote_any = true;
                    if (test_options.failure_point == .after_first_write)
                        return error.InjectedWriteFailure;
                }
            }
            try verifier.finish();
        },
        .source => |source| try source.copyVerifiedTo(
            candidate.layer_descriptor,
            file,
        ),
    }
    try verifyStagedDescriptor(
        io,
        file,
        candidate.layer_descriptor,
    );

    if (test_options.failure_point == .before_file_sync)
        return error.InjectedSyncFailure;
    try file.sync(io);

    const payload = try readStagedPayload(
        io,
        allocator,
        file,
        candidate.layer_descriptor.size,
    );
    defer allocator.free(payload);

    var plan = try wasm.classifyDirectManifest(
        allocator,
        root_descriptor,
        manifest_bytes,
        config_bytes,
        payload,
    );
    defer plan.deinit();
    const result: Result = .{
        .profile = plan.profile,
        .kind = plan.kind,
        .bytes_written = candidate.layer_descriptor.size,
    };

    const staged_identity = fileIdentity(try file.stat(io));
    file.close(io);
    file_closed = true;

    if (test_options.before_checks) |hook|
        try hook.run(io, parent, output_name, temporary.name);

    try requireUnchangedDestination(io, parent, output_name, destination);
    try requireUnchangedStaging(
        io,
        parent,
        temporary.name,
        staged_identity,
    );
    if (test_options.after_checks) |hook|
        try hook.run(io, parent, output_name, temporary.name);
    if (test_options.failure_point == .before_rename)
        return error.InjectedRenameFailure;

    switch (destination) {
        .missing => Io.Dir.renamePreserve(
            parent,
            temporary.name,
            parent,
            output_name,
            io,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => return error.DestinationChanged,
            else => return err,
        },
        .file => try Io.Dir.rename(
            parent,
            temporary.name,
            parent,
            output_name,
            io,
        ),
    }
    published = true;
    return result;
}

fn outputName(output_path: []const u8) Error![]const u8 {
    if (output_path.len == 0 or
        std.mem.indexOfScalar(u8, output_path, 0) != null or
        std.fs.path.isSep(output_path[output_path.len - 1]))
        return error.InvalidOutputPath;
    const name = std.fs.path.basename(output_path);
    if (name.len == 0 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
        return error.InvalidOutputPath;
    return name;
}

const DirectManifestCandidate = struct {
    document: model.ParsedDocument,
    profile: wasm.DirectManifestProfile,
    config_descriptor: model.Descriptor,
    layer_descriptor: model.Descriptor,

    fn deinit(self: *DirectManifestCandidate) void {
        self.document.deinit();
        self.* = undefined;
    }
};

fn inspectDirectManifest(
    allocator: std.mem.Allocator,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
) Error!DirectManifestCandidate {
    if (manifest_bytes.len > wasm.max_manifest_bytes)
        return error.ManifestTooLarge;
    if (std.mem.eql(u8, root_descriptor.mediaType, wasm.media_type_index))
        return error.DirectManifestRequired;
    if (!std.mem.eql(u8, root_descriptor.mediaType, wasm.media_type_manifest))
        return error.UnsupportedRootMediaType;
    try verifyDescriptorBytes(root_descriptor, manifest_bytes);

    var document = model.parseDocument(allocator, manifest_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedDocumentMediaType, error.DocumentMediaTypeMismatch => return error.UnsupportedManifestMediaType,
        else => return error.MalformedManifest,
    };
    errdefer document.deinit();
    const manifest = switch (document.value) {
        .index => return error.DirectManifestRequired,
        .manifest => |parsed| parsed.value,
    };
    const fields = try inspectManifestFields(allocator, manifest_bytes);
    if (manifest.mediaType == null or
        !std.mem.eql(u8, manifest.mediaType.?, wasm.media_type_manifest))
        return error.UnsupportedManifestMediaType;
    if (fields.subject) return error.ManifestSubjectUnsupported;
    if (manifest.layers.len != 1) return error.InvalidLayerCount;

    const layer = manifest.layers[0];
    if (!std.mem.eql(u8, layer.mediaType, wasm.media_type_wasm))
        return error.UnsupportedLayerMediaType;

    const profile: wasm.DirectManifestProfile = if (manifest.artifactType) |artifact_type| blk: {
        if (!std.mem.eql(u8, artifact_type, wasm.artifact_type_wasm) or
            !std.mem.eql(u8, manifest.config.mediaType, wasm.media_type_empty_config))
            return error.UnsupportedProfile;
        break :blk .oci_1_1;
    } else blk: {
        if (fields.artifact_type) return error.UnsupportedProfile;
        if (std.mem.eql(u8, manifest.config.mediaType, wasm.media_type_wasm_config)) {
            break :blk .wasm_v0;
        } else if (std.mem.eql(u8, manifest.config.mediaType, wasm.media_type_wasm)) {
            break :blk .oci_1_0;
        } else {
            return error.UnsupportedProfile;
        }
    };

    return .{
        .document = document,
        .profile = profile,
        .config_descriptor = manifest.config,
        .layer_descriptor = layer,
    };
}

fn validateCandidateConfig(
    candidate: *const DirectManifestCandidate,
    config_bytes: []const u8,
) Error!void {
    if (config_bytes.len > wasm.max_config_bytes)
        return error.ConfigTooLarge;
    try verifyDescriptorBytes(candidate.config_descriptor, config_bytes);
    if (candidate.profile != .wasm_v0 and
        !std.mem.eql(u8, config_bytes, wasm.empty_config_bytes))
    {
        return error.InvalidEmptyConfig;
    }
}

fn verifyDescriptorBytes(
    descriptor: model.Descriptor,
    bytes: []const u8,
) Error!void {
    const digest = try content.Digest.parse(descriptor.digest);
    try content.verifyBytes(digest, descriptor.size, bytes);
}

fn verifyStagedDescriptor(
    io: Io,
    file: Io.File,
    descriptor: model.Descriptor,
) !void {
    if (try file.length(io) != descriptor.size)
        return error.SizeMismatch;
    const digest = try content.Digest.parse(descriptor.digest);
    var verifier = content.Verifier.init(digest, descriptor.size);
    var buffer: [transport.copy_buffer_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < descriptor.size) {
        const remaining: usize = @intCast(@min(
            descriptor.size - offset,
            buffer.len,
        ));
        const count = try file.readPositional(
            io,
            &.{buffer[0..remaining]},
            offset,
        );
        if (count == 0) return error.SizeMismatch;
        try verifier.update(buffer[0..count]);
        offset += count;
    }
    try verifier.finish();
}

const ManifestFields = struct {
    artifact_type: bool,
    subject: bool,
};

fn inspectManifestFields(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!ManifestFields {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    ) catch |err| switch (err) {
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

fn initialDestination(
    io: Io,
    parent: Io.Dir,
    name: []const u8,
    force: bool,
) !DestinationSnapshot {
    const stat = parent.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    return switch (stat.kind) {
        .file => if (force)
            .{ .file = fileIdentity(stat) }
        else
            error.DestinationExists,
        .directory => error.DestinationIsDirectory,
        .sym_link => error.DestinationIsSymlink,
        else => error.UnsupportedDestinationType,
    };
}

fn requireUnchangedDestination(
    io: Io,
    parent: Io.Dir,
    name: []const u8,
    expected: DestinationSnapshot,
) !void {
    const stat = parent.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return switch (expected) {
            .missing => {},
            .file => error.DestinationChanged,
        },
        else => return err,
    };
    switch (stat.kind) {
        .directory => return error.DestinationIsDirectory,
        .sym_link => return error.DestinationIsSymlink,
        .file => {},
        else => return error.UnsupportedDestinationType,
    }
    switch (expected) {
        .missing => return error.DestinationChanged,
        .file => |identity| if (!sameFileIdentity(identity, fileIdentity(stat)))
            return error.DestinationChanged,
    }
}

fn stagingIdentity(
    io: Io,
    parent: Io.Dir,
    name: []const u8,
) !FileIdentity {
    const stat = parent.statFile(
        io,
        name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return error.StagedFileChanged,
        else => return err,
    };
    if (stat.kind != .file) return error.StagedFileChanged;
    return fileIdentity(stat);
}

fn requireUnchangedStaging(
    io: Io,
    parent: Io.Dir,
    name: []const u8,
    expected: FileIdentity,
) !void {
    const actual = try stagingIdentity(io, parent, name);
    if (!sameFileIdentity(expected, actual))
        return error.StagedFileChanged;
}

fn fileIdentity(stat: Io.File.Stat) FileIdentity {
    return .{
        .inode = stat.inode,
        .ctime = stat.ctime,
        .mtime = stat.mtime,
        .size = stat.size,
    };
}

fn sameFileIdentity(a: FileIdentity, b: FileIdentity) bool {
    return a.inode == b.inode and
        std.meta.eql(a.ctime, b.ctime) and
        std.meta.eql(a.mtime, b.mtime) and
        a.size == b.size;
}

fn readStagedPayload(
    io: Io,
    allocator: std.mem.Allocator,
    file: Io.File,
    expected_size: u64,
) ![]u8 {
    if (try file.length(io) != expected_size)
        return error.StagedFileChanged;
    if (expected_size > wasm.max_payload_bytes or
        expected_size > std.math.maxInt(usize))
        return error.PayloadTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(expected_size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len)
        return error.StagedFileChanged;
    return bytes;
}

fn createUniqueTemporary(
    io: Io,
    allocator: std.mem.Allocator,
    parent: Io.Dir,
) !Temporary {
    var random: [16]u8 = undefined;
    for (0..64) |_| {
        try io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            ".wabt-oci-extract-{s}.tmp",
            .{suffix},
        );
        const file = parent.createFile(io, name, .{
            .exclusive = true,
            .read = true,
            .permissions = restrictivePermissions(),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(name);
                continue;
            },
            else => {
                allocator.free(name);
                return err;
            },
        };
        return .{ .name = name, .file = file };
    }
    return error.PathAlreadyExists;
}

fn restrictivePermissions() Io.File.Permissions {
    return if (builtin.os.tag == .windows)
        .default_file
    else
        @enumFromInt(0o600);
}

// ── Hermetic extraction fixtures and tests ───────────────────────────────

const testing = std.testing;

const SliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    max_chunk: usize = std.math.maxInt(usize),
    interrupt_after: ?usize = null,

    fn read(self: *SliceSource, destination: []u8) !usize {
        if (self.interrupt_after) |limit| {
            if (self.offset >= limit) return error.SourceInterrupted;
        }
        if (self.offset == self.bytes.len) return 0;
        var count = @min(destination.len, self.max_chunk);
        count = @min(count, self.bytes.len - self.offset);
        if (self.interrupt_after) |limit|
            count = @min(count, limit - self.offset);
        @memcpy(destination[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

const TransportFixture = struct {
    config_descriptor: model.Descriptor,
    layer_descriptor: model.Descriptor,
    config_bytes: []const u8,
    payload_bytes: []const u8,
    corrupt_config: bool = false,
    interrupt_after: ?usize = null,
    metadata_reads: usize = 0,
    layer_copies: usize = 0,

    pub fn readMetadata(
        self: *TransportFixture,
        allocator: std.mem.Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !transport.Metadata {
        self.metadata_reads += 1;
        if (!sameDescriptorIdentity(descriptor, self.config_descriptor))
            return error.UnexpectedDescriptor;
        if (descriptor.size > max_bytes) return error.MetadataTooLarge;
        return transport.Metadata.copy(
            allocator,
            if (self.corrupt_config) "[]" else self.config_bytes,
        );
    }

    pub fn copyVerifiedTo(
        self: *TransportFixture,
        descriptor: model.Descriptor,
        destination: Io.File,
    ) !void {
        self.layer_copies += 1;
        if (!sameDescriptorIdentity(descriptor, self.layer_descriptor))
            return error.UnexpectedDescriptor;
        const limit = self.interrupt_after orelse self.payload_bytes.len;
        var offset: usize = 0;
        while (offset < @min(limit, self.payload_bytes.len)) {
            const end = @min(
                offset + 3,
                @min(limit, self.payload_bytes.len),
            );
            try destination.writeStreamingAll(
                testing.io,
                self.payload_bytes[offset..end],
            );
            offset = end;
        }
        if (self.interrupt_after != null) return error.SourceInterrupted;
    }
};

fn sameDescriptorIdentity(a: model.Descriptor, b: model.Descriptor) bool {
    return a.size == b.size and
        std.mem.eql(u8, a.mediaType, b.mediaType) and
        std.mem.eql(u8, a.digest, b.digest);
}

const JsonDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
};

const TestLayerAnnotations = struct {
    @"org.opencontainers.image.title": []const u8,
};

const TestLayerDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    annotations: ?TestLayerAnnotations = null,
};

const TestManifest = struct {
    schemaVersion: u32,
    mediaType: []const u8,
    artifactType: ?[]const u8 = null,
    config: JsonDescriptor,
    layers: []const TestLayerDescriptor,
    subject: ?JsonDescriptor = null,
};

const TestManifestOptions = struct {
    schema_version: u32 = 2,
    manifest_media_type: []const u8 = wasm.media_type_manifest,
    artifact_type: ?[]const u8 = wasm.artifact_type_wasm,
    config_media_type: []const u8 = wasm.media_type_empty_config,
    config_digest: ?[]const u8 = null,
    config_size: ?u64 = null,
    layer_media_type: []const u8 = wasm.media_type_wasm,
    layer_digest: ?[]const u8 = null,
    layer_size: ?u64 = null,
    layer_count: usize = 1,
    title: ?[]const u8 = null,
    subject: bool = false,
};

const BuiltManifest = struct {
    bytes: []u8,
    digest: [content.digest_text_size]u8,

    fn deinit(self: *BuiltManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    fn rootDescriptor(self: *const BuiltManifest) model.Descriptor {
        return .{
            .mediaType = wasm.media_type_manifest,
            .digest = &self.digest,
            .size = self.bytes.len,
        };
    }
};

fn buildTestManifest(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    payload: []const u8,
    options: TestManifestOptions,
) !BuiltManifest {
    const actual_config_digest = content.digestBytes(config_bytes).format();
    const actual_layer_digest = content.digestBytes(payload).format();
    const layers = try allocator.alloc(TestLayerDescriptor, options.layer_count);
    defer allocator.free(layers);
    for (layers) |*layer| {
        layer.* = .{
            .mediaType = options.layer_media_type,
            .digest = options.layer_digest orelse &actual_layer_digest,
            .size = options.layer_size orelse payload.len,
            .annotations = if (options.title) |title| .{
                .@"org.opencontainers.image.title" = title,
            } else null,
        };
    }
    const subject: ?JsonDescriptor = if (options.subject) .{
        .mediaType = wasm.media_type_manifest,
        .digest = &actual_layer_digest,
        .size = payload.len,
    } else null;
    const bytes = try std.json.Stringify.valueAlloc(
        allocator,
        TestManifest{
            .schemaVersion = options.schema_version,
            .mediaType = options.manifest_media_type,
            .artifactType = options.artifact_type,
            .config = .{
                .mediaType = options.config_media_type,
                .digest = options.config_digest orelse &actual_config_digest,
                .size = options.config_size orelse config_bytes.len,
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

fn readOutput(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        allocator,
        .limited(wasm.max_payload_bytes),
    );
}

fn writeOutput(path: []const u8, bytes: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(testing.io, path, .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, bytes);
}

fn expectNoTemporaryFiles(parent_path: []const u8) !void {
    var parent = try Io.Dir.cwd().openDir(
        testing.io,
        parent_path,
        .{ .iterate = true },
    );
    defer parent.close(testing.io);
    var iterator = parent.iterate();
    while (try iterator.next(testing.io)) |entry| {
        try testing.expect(!std.mem.startsWith(
            u8,
            entry.name,
            ".wabt-oci-",
        ));
    }
}

fn expectRejected(
    expected_error: anyerror,
    root_descriptor: model.Descriptor,
    manifest_bytes: []const u8,
    config_bytes: []const u8,
    payload: []const u8,
    parent_path: []const u8,
    output_name: []const u8,
) !usize {
    const output = try childPath(testing.allocator, parent_path, output_name);
    defer testing.allocator.free(output);
    var source = SliceSource{ .bytes = payload, .max_chunk = 2 };
    try testing.expectError(expected_error, directManifest(
        testing.io,
        testing.allocator,
        root_descriptor,
        manifest_bytes,
        config_bytes,
        LayerSource.init(&source),
        output,
        .{},
    ));
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, output, .{}),
    );
    try expectNoTemporaryFiles(parent_path);
    return source.offset;
}

test "oci extraction: supports every direct-manifest profile and native kind" {
    const allocator = testing.allocator;
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const component = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    const Case = struct {
        profile: wasm.Profile,
        payload: []const u8,
        expected_profile: wasm.DirectManifestProfile,
        expected_kind: wasm.WasmKind,
        name: []const u8,
    };
    const cases = [_]Case{
        .{
            .profile = .wasm_v0,
            .payload = &core,
            .expected_profile = .wasm_v0,
            .expected_kind = .core_module,
            .name = "v0-core.wasm",
        },
        .{
            .profile = .wasm_v0,
            .payload = &component,
            .expected_profile = .wasm_v0,
            .expected_kind = .component,
            .name = "v0-component.wasm",
        },
        .{
            .profile = .oci,
            .payload = &core,
            .expected_profile = .oci_1_1,
            .expected_kind = .core_module,
            .name = "oci-1-1-core.wasm",
        },
        .{
            .profile = .oci,
            .payload = &component,
            .expected_profile = .oci_1_1,
            .expected_kind = .component,
            .name = "oci-1-1-component.wasm",
        },
    };
    for (cases) |case| {
        var artifact = try wasm.prepare(allocator, case.payload, .{
            .profile = case.profile,
            .created = "2026-09-19T00:00:00Z",
            .source_name = "../../ignored.wasm",
        });
        defer artifact.deinit();
        const output = try childPath(allocator, root, case.name);
        defer allocator.free(output);
        var source = SliceSource{ .bytes = case.payload, .max_chunk = 3 };
        const result = try directManifest(
            testing.io,
            allocator,
            artifact.root_descriptor,
            artifact.manifest_bytes,
            artifact.config_bytes,
            LayerSource.init(&source),
            output,
            .{},
        );
        try testing.expectEqual(case.expected_profile, result.profile);
        try testing.expectEqual(case.expected_kind, result.kind);
        try testing.expectEqual(@as(u64, case.payload.len), result.bytes_written);
        const actual = try readOutput(allocator, output);
        defer allocator.free(actual);
        try testing.expectEqualSlices(u8, case.payload, actual);
    }

    var oci_1_0 = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &core,
        .{
            .artifact_type = null,
            .config_media_type = wasm.media_type_wasm,
        },
    );
    defer oci_1_0.deinit(allocator);
    const output = try childPath(allocator, root, "oci-1-0.wasm");
    defer allocator.free(output);
    var source = SliceSource{ .bytes = &core };
    const result = try directManifest(
        testing.io,
        allocator,
        oci_1_0.rootDescriptor(),
        oci_1_0.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&source),
        output,
        .{},
    );
    try testing.expectEqual(wasm.DirectManifestProfile.oci_1_0, result.profile);

    var oci_1_0_component = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &component,
        .{
            .artifact_type = null,
            .config_media_type = wasm.media_type_wasm,
        },
    );
    defer oci_1_0_component.deinit(allocator);
    const component_output = try childPath(
        allocator,
        root,
        "oci-1-0-component.wasm",
    );
    defer allocator.free(component_output);
    var component_source = SliceSource{ .bytes = &component };
    const component_result = try directManifest(
        testing.io,
        allocator,
        oci_1_0_component.rootDescriptor(),
        oci_1_0_component.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&component_source),
        component_output,
        .{},
    );
    try testing.expectEqual(
        wasm.DirectManifestProfile.oci_1_0,
        component_result.profile,
    );
    try testing.expectEqual(wasm.WasmKind.component, component_result.kind);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: multi-buffer output is exact and ignores hostile title" {
    const allocator = testing.allocator;
    const custom_size = transport.copy_buffer_size * 3 + 17;
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(
        allocator,
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x00 },
    );
    var section_size: [5]u8 = undefined;
    const name_and_data_size: u32 = @intCast(custom_size + 1);
    const section_size_len = @import("../leb128.zig").writeU32Leb128(
        &section_size,
        name_and_data_size,
    );
    try payload.appendSlice(allocator, section_size[0..section_size_len]);
    try payload.append(allocator, 0);
    for (0..custom_size) |index|
        try payload.append(allocator, @truncate(index));

    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        payload.items,
        .{ .title = "../../outside.wasm" },
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const nested = try childPath(allocator, root, "selected");
    defer allocator.free(nested);
    try Io.Dir.cwd().createDir(testing.io, nested, .default_dir);
    const output = try childPath(allocator, nested, "chosen.wasm");
    defer allocator.free(output);

    var source = SliceSource{ .bytes = payload.items };
    _ = try directManifest(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&source),
        output,
        .{},
    );
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualSlices(u8, payload.items, actual);
    const outside = try childPath(allocator, root, "outside.wasm");
    defer allocator.free(outside);
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, outside, .{}),
    );
    try expectNoTemporaryFiles(nested);
}

test "oci extraction: no-overwrite and force publish atomically" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const output = try childPath(allocator, root, "output.wasm");
    defer allocator.free(output);
    try writeOutput(output, "old");

    var refusing_source = SliceSource{ .bytes = &payload };
    try testing.expectError(
        error.DestinationExists,
        directManifest(
            testing.io,
            allocator,
            fixture.rootDescriptor(),
            fixture.bytes,
            wasm.empty_config_bytes,
            LayerSource.init(&refusing_source),
            output,
            .{},
        ),
    );
    try testing.expectEqual(@as(usize, 0), refusing_source.offset);
    const old = try readOutput(allocator, output);
    defer allocator.free(old);
    try testing.expectEqualStrings("old", old);

    var replacing_source = SliceSource{ .bytes = &payload };
    _ = try directManifest(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&replacing_source),
        output,
        .{ .force = true },
    );
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualSlices(u8, &payload, actual);
    if (comptime builtin.os.tag != .windows) {
        const stat = try Io.Dir.cwd().statFile(testing.io, output, .{});
        try testing.expectEqual(
            @as(std.posix.mode_t, 0o600),
            stat.permissions.toMode() & 0o777,
        );
    }
    try expectNoTemporaryFiles(root);
}

test "oci extraction: force failures preserve old bytes and remove staging" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    const cases = [_]struct {
        point: FailurePoint,
        expected: anyerror,
        name: []const u8,
    }{
        .{
            .point = .after_first_write,
            .expected = error.InjectedWriteFailure,
            .name = "write.wasm",
        },
        .{
            .point = .before_file_sync,
            .expected = error.InjectedSyncFailure,
            .name = "sync.wasm",
        },
        .{
            .point = .before_rename,
            .expected = error.InjectedRenameFailure,
            .name = "rename.wasm",
        },
    };
    for (cases) |case| {
        const output = try childPath(allocator, root, case.name);
        defer allocator.free(output);
        try writeOutput(output, "old bytes");
        var source = SliceSource{ .bytes = &payload };
        try testing.expectError(case.expected, directManifestImpl(
            testing.io,
            allocator,
            fixture.rootDescriptor(),
            fixture.bytes,
            .{ .exact = wasm.empty_config_bytes },
            .{ .sequential = LayerSource.init(&source) },
            output,
            .{ .force = true },
            .{ .failure_point = case.point },
        ));
        const actual = try readOutput(allocator, output);
        defer allocator.free(actual);
        try testing.expectEqualStrings("old bytes", actual);
        try expectNoTemporaryFiles(root);
    }

    const invalid = "not wasm";
    var invalid_fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        invalid,
        .{},
    );
    defer invalid_fixture.deinit(allocator);
    const parse_output = try childPath(allocator, root, "parse.wasm");
    defer allocator.free(parse_output);
    try writeOutput(parse_output, "old bytes");
    var invalid_source = SliceSource{ .bytes = invalid };
    try testing.expectError(error.InvalidWasm, directManifest(
        testing.io,
        allocator,
        invalid_fixture.rootDescriptor(),
        invalid_fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&invalid_source),
        parse_output,
        .{ .force = true },
    ));
    const parse_actual = try readOutput(allocator, parse_output);
    defer allocator.free(parse_actual);
    try testing.expectEqualStrings("old bytes", parse_actual);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: destination race does not overwrite the racer" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const output = try childPath(allocator, root, "race.wasm");
    defer allocator.free(output);

    const Race = struct {
        fn run(
            _: *@This(),
            io: Io,
            parent: Io.Dir,
            name: []const u8,
            _: []const u8,
        ) !void {
            var file = try parent.createFile(io, name, .{ .exclusive = true });
            defer file.close(io);
            try file.writeStreamingAll(io, "racer");
        }
    };
    var race = Race{};
    var source = SliceSource{ .bytes = &payload };
    try testing.expectError(error.DestinationChanged, directManifestImpl(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        .{ .exact = wasm.empty_config_bytes },
        .{ .sequential = LayerSource.init(&source) },
        output,
        .{},
        .{ .after_checks = PublishHook.init(&race) },
    ));
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualStrings("racer", actual);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: replaced staging file is never published" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const output = try childPath(allocator, root, "staging-race.wasm");
    defer allocator.free(output);
    try writeOutput(output, "old bytes");

    const Race = struct {
        fn run(
            _: *@This(),
            io: Io,
            parent: Io.Dir,
            _: []const u8,
            staging_name: []const u8,
        ) !void {
            try parent.deleteFile(io, staging_name);
            var replacement = try parent.createFile(
                io,
                staging_name,
                .{ .exclusive = true },
            );
            defer replacement.close(io);
            try replacement.writeStreamingAll(io, "evil");
        }
    };
    var race = Race{};
    var source = SliceSource{ .bytes = &payload };
    try testing.expectError(error.StagedFileChanged, directManifestImpl(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        .{ .exact = wasm.empty_config_bytes },
        .{ .sequential = LayerSource.init(&source) },
        output,
        .{ .force = true },
        .{ .before_checks = PublishHook.init(&race) },
    ));
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualStrings("old bytes", actual);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: invalid source count preserves destination" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const output = try childPath(allocator, root, "invalid-source.wasm");
    defer allocator.free(output);
    try writeOutput(output, "old bytes");

    const InvalidSource = struct {
        fn read(_: *@This(), destination: []u8) !usize {
            return destination.len + 1;
        }
    };
    var invalid_source = InvalidSource{};
    try testing.expectError(error.InvalidSourceRead, directManifest(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&invalid_source),
        output,
        .{ .force = true },
    ));
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualStrings("old bytes", actual);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: interrupted source and invalid Wasm publish nothing" {
    const allocator = testing.allocator;
    const valid = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var valid_fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &valid,
        .{},
    );
    defer valid_fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    const interrupted_output = try childPath(
        allocator,
        root,
        "interrupted.wasm",
    );
    defer allocator.free(interrupted_output);
    var interrupted = SliceSource{
        .bytes = &valid,
        .max_chunk = 2,
        .interrupt_after = 4,
    };
    try testing.expectError(error.SourceInterrupted, directManifest(
        testing.io,
        allocator,
        valid_fixture.rootDescriptor(),
        valid_fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&interrupted),
        interrupted_output,
        .{},
    ));
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, interrupted_output, .{}),
    );

    const invalid = "not wasm";
    var invalid_fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        invalid,
        .{},
    );
    defer invalid_fixture.deinit(allocator);
    const invalid_output = try childPath(allocator, root, "invalid.wasm");
    defer allocator.free(invalid_output);
    var invalid_source = SliceSource{ .bytes = invalid };
    try testing.expectError(error.InvalidWasm, directManifest(
        testing.io,
        allocator,
        invalid_fixture.rootDescriptor(),
        invalid_fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&invalid_source),
        invalid_output,
        .{},
    ));
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, invalid_output, .{}),
    );

    const malformed_payloads = [_][]const u8{
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01 },
        &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00, 0x0a },
    };
    for (malformed_payloads, 0..) |malformed, index| {
        var malformed_fixture = try buildTestManifest(
            allocator,
            wasm.empty_config_bytes,
            malformed,
            .{},
        );
        defer malformed_fixture.deinit(allocator);
        const malformed_output = try childPath(
            allocator,
            root,
            if (index == 0) "malformed-core.wasm" else "malformed-component.wasm",
        );
        defer allocator.free(malformed_output);
        var malformed_source = SliceSource{ .bytes = malformed };
        try testing.expectError(error.InvalidWasm, directManifest(
            testing.io,
            allocator,
            malformed_fixture.rootDescriptor(),
            malformed_fixture.bytes,
            wasm.empty_config_bytes,
            LayerSource.init(&malformed_source),
            malformed_output,
            .{},
        ));
        try testing.expectError(
            error.FileNotFound,
            Io.Dir.cwd().statFile(testing.io, malformed_output, .{}),
        );
    }
    try expectNoTemporaryFiles(root);
}

test "oci extraction: metadata config and layer verification is strict" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const wrong_digest =
        "sha256:0000000000000000000000000000000000000000000000000000000000000000";
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    var valid = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer valid.deinit(allocator);
    var wrong_root_size = valid.rootDescriptor();
    wrong_root_size.size += 1;
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.SizeMismatch,
        wrong_root_size,
        valid.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "root-size.wasm",
    ));
    var wrong_root_digest = valid.rootDescriptor();
    wrong_root_digest.digest = wrong_digest;
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.DigestMismatch,
        wrong_root_digest,
        valid.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "root-digest.wasm",
    ));

    var wrong_config_size = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{ .config_size = wasm.empty_config_bytes.len + 1 },
    );
    defer wrong_config_size.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.SizeMismatch,
        wrong_config_size.rootDescriptor(),
        wrong_config_size.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "config-size.wasm",
    ));
    var wrong_config_digest = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{ .config_digest = wrong_digest },
    );
    defer wrong_config_digest.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.DigestMismatch,
        wrong_config_digest.rootDescriptor(),
        wrong_config_digest.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "config-digest.wasm",
    ));

    var wrong_layer_size = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{ .layer_size = payload.len + 1 },
    );
    defer wrong_layer_size.deinit(allocator);
    try testing.expectEqual(payload.len, try expectRejected(
        error.SizeMismatch,
        wrong_layer_size.rootDescriptor(),
        wrong_layer_size.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "layer-size.wasm",
    ));
    var wrong_layer_digest = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{ .layer_digest = wrong_digest },
    );
    defer wrong_layer_digest.deinit(allocator);
    try testing.expectEqual(payload.len, try expectRejected(
        error.DigestMismatch,
        wrong_layer_digest.rootDescriptor(),
        wrong_layer_digest.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "layer-digest.wasm",
    ));
    var malformed_layer = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{ .layer_digest = "sha256:not-a-digest" },
    );
    defer malformed_layer.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.MalformedManifest,
        malformed_layer.rootDescriptor(),
        malformed_layer.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "malformed-layer.wasm",
    ));

    const layer_digest = content.digestBytes(&payload).format();
    const inconsistent_config = try std.fmt.allocPrint(
        allocator,
        "{{\"created\":\"2026-09-19T00:00:00Z\",\"author\":null,\"architecture\":\"wasm\",\"os\":\"wasip2\",\"layerDigests\":[\"{s}\"],\"component\":null}}",
        .{&layer_digest},
    );
    defer allocator.free(inconsistent_config);
    var inconsistent = try buildTestManifest(
        allocator,
        inconsistent_config,
        &payload,
        .{
            .artifact_type = null,
            .config_media_type = wasm.media_type_wasm_config,
        },
    );
    defer inconsistent.deinit(allocator);
    try testing.expectEqual(payload.len, try expectRejected(
        error.OsMismatch,
        inconsistent.rootDescriptor(),
        inconsistent.bytes,
        inconsistent_config,
        &payload,
        root,
        "config-consistency.wasm",
    ));
}

test "oci extraction: rejects indexes ambiguous archives and unsupported profiles" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    const index_bytes =
        "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[]}";
    const index_digest = content.digestBytes(index_bytes).format();
    const index_root: model.Descriptor = .{
        .mediaType = wasm.media_type_index,
        .digest = &index_digest,
        .size = index_bytes.len,
    };
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.DirectManifestRequired,
        index_root,
        index_bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "index.wasm",
    ));

    const layer_counts = [_]usize{ 0, 2 };
    for (layer_counts, 0..) |layer_count, index| {
        var fixture = try buildTestManifest(
            allocator,
            wasm.empty_config_bytes,
            &payload,
            .{ .layer_count = layer_count },
        );
        defer fixture.deinit(allocator);
        const name = if (index == 0) "no-layer.wasm" else "two-layers.wasm";
        try testing.expectEqual(@as(usize, 0), try expectRejected(
            error.InvalidLayerCount,
            fixture.rootDescriptor(),
            fixture.bytes,
            wasm.empty_config_bytes,
            &payload,
            root,
            name,
        ));
    }

    const archive_media_types = [_][]const u8{
        model.media_type_oci_layer,
        model.media_type_oci_layer_gzip,
        model.media_type_oci_layer_zstd,
    };
    for (archive_media_types, 0..) |media_type, index| {
        var fixture = try buildTestManifest(
            allocator,
            wasm.empty_config_bytes,
            &payload,
            .{ .layer_media_type = media_type },
        );
        defer fixture.deinit(allocator);
        const name = switch (index) {
            0 => "tar.wasm",
            1 => "gzip.wasm",
            else => "zstd.wasm",
        };
        try testing.expectEqual(@as(usize, 0), try expectRejected(
            error.UnsupportedLayerMediaType,
            fixture.rootDescriptor(),
            fixture.bytes,
            wasm.empty_config_bytes,
            &payload,
            root,
            name,
        ));
    }

    var unsupported = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{
            .artifact_type = null,
            .config_media_type = wasm.media_type_empty_config,
        },
    );
    defer unsupported.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), try expectRejected(
        error.UnsupportedProfile,
        unsupported.rootDescriptor(),
        unsupported.bytes,
        wasm.empty_config_bytes,
        &payload,
        root,
        "unsupported.wasm",
    ));
}

test "oci extraction: directories and symlinks are explicit failures" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    const directory_output = try childPath(allocator, root, "directory.wasm");
    defer allocator.free(directory_output);
    try Io.Dir.cwd().createDir(testing.io, directory_output, .default_dir);
    var directory_source = SliceSource{ .bytes = &payload };
    try testing.expectError(error.DestinationIsDirectory, directManifest(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&directory_source),
        directory_output,
        .{ .force = true },
    ));
    try testing.expectEqual(@as(usize, 0), directory_source.offset);

    var parent = try Io.Dir.cwd().openDir(testing.io, root, .{});
    defer parent.close(testing.io);
    var target = try parent.createFile(testing.io, "target.wasm", .{});
    target.close(testing.io);
    parent.symLink(
        testing.io,
        "target.wasm",
        "symlink.wasm",
        .{},
    ) catch |err| switch (err) {
        error.AccessDenied,
        error.PermissionDenied,
        => return error.SkipZigTest,
        else => return err,
    };
    const symlink_output = try childPath(allocator, root, "symlink.wasm");
    defer allocator.free(symlink_output);
    var symlink_source = SliceSource{ .bytes = &payload };
    try testing.expectError(error.DestinationIsSymlink, directManifest(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        wasm.empty_config_bytes,
        LayerSource.init(&symlink_source),
        symlink_output,
        .{ .force = true },
    ));
    try testing.expectEqual(@as(usize, 0), symlink_source.offset);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: force detects replacement race" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const output = try childPath(allocator, root, "force-race.wasm");
    defer allocator.free(output);
    try writeOutput(output, "old");

    const Race = struct {
        fn run(
            _: *@This(),
            io: Io,
            parent: Io.Dir,
            name: []const u8,
            _: []const u8,
        ) !void {
            var replacement = try parent.createFile(
                io,
                ".race-replacement",
                .{ .exclusive = true },
            );
            try replacement.writeStreamingAll(io, "racer");
            replacement.close(io);
            try Io.Dir.rename(
                parent,
                ".race-replacement",
                parent,
                name,
                io,
            );
        }
    };
    var race = Race{};
    var source = SliceSource{ .bytes = &payload };
    try testing.expectError(error.DestinationChanged, directManifestImpl(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        .{ .exact = wasm.empty_config_bytes },
        .{ .sequential = LayerSource.init(&source) },
        output,
        .{ .force = true },
        .{ .before_checks = PublishHook.init(&race) },
    ));
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualStrings("racer", actual);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: success follows the synced-file hook boundary" {
    const allocator = testing.allocator;
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var fixture = try buildTestManifest(
        allocator,
        wasm.empty_config_bytes,
        &payload,
        .{},
    );
    defer fixture.deinit(allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);
    const output = try childPath(allocator, root, "durable-boundary.wasm");
    defer allocator.free(output);

    const Observer = struct {
        called: bool = false,

        fn run(
            self: *@This(),
            io: Io,
            parent: Io.Dir,
            output_name: []const u8,
            staging_name: []const u8,
        ) !void {
            self.called = true;
            try testing.expectError(
                error.FileNotFound,
                parent.statFile(io, output_name, .{}),
            );
            const stat = try parent.statFile(
                io,
                staging_name,
                .{ .follow_symlinks = false },
            );
            try testing.expectEqual(Io.File.Kind.file, stat.kind);
            if (comptime builtin.os.tag != .windows) {
                try testing.expectEqual(
                    @as(std.posix.mode_t, 0o600),
                    stat.permissions.toMode() & 0o777,
                );
            }
        }
    };
    var observer = Observer{};
    var source = SliceSource{ .bytes = &payload };
    _ = try directManifestImpl(
        testing.io,
        allocator,
        fixture.rootDescriptor(),
        fixture.bytes,
        .{ .exact = wasm.empty_config_bytes },
        .{ .sequential = LayerSource.init(&source) },
        output,
        .{},
        .{ .before_checks = PublishHook.init(&observer) },
    );
    try testing.expect(observer.called);
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualSlices(u8, &payload, actual);
    try expectNoTemporaryFiles(root);
}

test "oci extraction: resolved transport source is bounded streamed and cleaned" {
    const allocator = testing.allocator;
    const payload = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x03, 0x61, 0x62, 0x63,
    };
    var package = try wasm.prepare(allocator, &payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:00Z",
        .source_name = "../../ignored.wasm",
    });
    defer package.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testRoot(allocator, &tmp.sub_path);
    defer allocator.free(root);

    var source_impl: TransportFixture = .{
        .config_descriptor = package.config_descriptor,
        .layer_descriptor = package.layer_descriptor,
        .config_bytes = package.config_bytes,
        .payload_bytes = package.payload_bytes,
    };
    const existing = try childPath(allocator, root, "existing.wasm");
    defer allocator.free(existing);
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = existing,
        .data = "old",
    });
    try testing.expectError(
        error.DestinationExists,
        fromResolvedSource(
            testing.io,
            allocator,
            transport.Source.init(&source_impl),
            package.root_descriptor,
            package.manifest_bytes,
            existing,
            .{},
        ),
    );
    try testing.expectEqual(@as(usize, 0), source_impl.metadata_reads);
    try testing.expectEqual(@as(usize, 0), source_impl.layer_copies);

    const output = try childPath(allocator, root, "selected.wasm");
    defer allocator.free(output);
    const result = try fromResolvedSource(
        testing.io,
        allocator,
        transport.Source.init(&source_impl),
        package.root_descriptor,
        package.manifest_bytes,
        output,
        .{},
    );
    try testing.expectEqual(wasm.DirectManifestProfile.oci_1_1, result.profile);
    try testing.expectEqual(wasm.WasmKind.core_module, result.kind);
    try testing.expectEqual(@as(usize, 1), source_impl.metadata_reads);
    try testing.expectEqual(@as(usize, 1), source_impl.layer_copies);
    const actual = try readOutput(allocator, output);
    defer allocator.free(actual);
    try testing.expectEqualSlices(u8, &payload, actual);

    var corrupt_config: TransportFixture = .{
        .config_descriptor = package.config_descriptor,
        .layer_descriptor = package.layer_descriptor,
        .config_bytes = package.config_bytes,
        .payload_bytes = package.payload_bytes,
        .corrupt_config = true,
    };
    const corrupt_output = try childPath(allocator, root, "corrupt-config.wasm");
    defer allocator.free(corrupt_output);
    try testing.expectError(
        error.DigestMismatch,
        fromResolvedSource(
            testing.io,
            allocator,
            transport.Source.init(&corrupt_config),
            package.root_descriptor,
            package.manifest_bytes,
            corrupt_output,
            .{},
        ),
    );
    try testing.expectEqual(@as(usize, 1), corrupt_config.metadata_reads);
    try testing.expectEqual(@as(usize, 0), corrupt_config.layer_copies);

    var interrupted: TransportFixture = .{
        .config_descriptor = package.config_descriptor,
        .layer_descriptor = package.layer_descriptor,
        .config_bytes = package.config_bytes,
        .payload_bytes = package.payload_bytes,
        .interrupt_after = 5,
    };
    const interrupted_output = try childPath(
        allocator,
        root,
        "interrupted.wasm",
    );
    defer allocator.free(interrupted_output);
    try testing.expectError(
        error.SourceInterrupted,
        fromResolvedSource(
            testing.io,
            allocator,
            transport.Source.init(&interrupted),
            package.root_descriptor,
            package.manifest_bytes,
            interrupted_output,
            .{},
        ),
    );
    try testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(testing.io, interrupted_output, .{}),
    );
    try expectNoTemporaryFiles(root);
}

test "oci extraction: output path is mandatory" {
    const payload = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const digest = content.digestBytes(&payload).format();
    const unused: model.Descriptor = .{
        .mediaType = wasm.media_type_manifest,
        .digest = &digest,
        .size = payload.len,
    };
    const invalid_paths = [_][]const u8{ "", ".", "..", "/", "name/", "bad\x00name" };
    for (invalid_paths) |path| {
        var source = SliceSource{ .bytes = &payload };
        try testing.expectError(error.InvalidOutputPath, directManifest(
            testing.io,
            testing.allocator,
            unused,
            "",
            "",
            LayerSource.init(&source),
            path,
            .{},
        ));
        try testing.expectEqual(@as(usize, 0), source.offset);
    }
}
