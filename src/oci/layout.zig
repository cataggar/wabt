//! Verified transactional access to local OCI image layouts.
//!
//! Files are synced before publication. Zig's portable `std.Io` exposes file
//! sync and atomic rename, but no portable directory-sync primitive, so this
//! does not promise stronger power-loss durability than those operations.
const std = @import("std");
const content = @import("content.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");
const transport = @import("transport.zig");

const Io = std.Io;

pub const Error = error{
    InvalidLayout,
    InvalidLayoutVersion,
    InvalidIndex,
    InvalidDestinationPath,
    RootNotFound,
    AmbiguousRoot,
    MissingBlob,
    CorruptBlob,
    MetadataTooLarge,
    DescriptorMismatch,
    ConflictingDescriptor,
    DestinationNotPrepared,
    RootNotStaged,
    DestinationNotCommitted,
    InjectedFailure,
} || std.mem.Allocator.Error;

pub const FailurePoint = enum {
    none,
    before_index_publish,
    after_blob_temp_sync,
    after_index_temp_sync,
};

pub const default_metadata_limit: u64 = 16 * 1024 * 1024;
const layout_file_limit: u64 = 4096;
const reference_name_annotation = "org.opencontainers.image.ref.name";

pub const BlobState = enum {
    missing,
    valid,
    corrupt,
};

pub const ResolvedRoot = struct {
    allocator: std.mem.Allocator,
    descriptor: model.Descriptor,
    descriptor_json: []u8,
    descriptor_parsed: std.json.Parsed(model.Descriptor),
    bytes: []u8,

    pub fn deinit(self: *ResolvedRoot) void {
        self.allocator.free(self.bytes);
        self.descriptor_parsed.deinit();
        self.allocator.free(self.descriptor_json);
        self.* = undefined;
    }
};

/// Read-only layout operations. Digest-derived paths are never trusted
/// without independently checking both the declared size and SHA-256.
pub const Source = struct {
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    metadata_limit: u64,

    pub fn init(
        io: Io,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) Source {
        return initWithMetadataLimit(
            io,
            allocator,
            path,
            default_metadata_limit,
        );
    }

    pub fn initWithMetadataLimit(
        io: Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        metadata_limit: u64,
    ) Source {
        return .{
            .io = io,
            .allocator = allocator,
            .path = path,
            .metadata_limit = metadata_limit,
        };
    }

    pub fn asTransport(self: *Source) transport.Source {
        return transport.Source.init(self);
    }

    pub fn resolve(
        self: *Source,
        layout_reference: reference.LayoutReference,
    ) !ResolvedRoot {
        if (!std.mem.eql(u8, self.path, layout_reference.path)) {
            return error.InvalidLayout;
        }
        try self.validateLayout();

        const index_bytes = self.readIndexBytes() catch |err| switch (err) {
            error.MetadataTooLarge => return err,
            else => return error.InvalidIndex,
        };
        defer self.allocator.free(index_bytes);

        var index_value = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            index_bytes,
            .{},
        ) catch return error.InvalidIndex;
        defer index_value.deinit();
        const object = switch (index_value.value) {
            .object => |object| object,
            else => return error.InvalidIndex,
        };
        const manifests = object.get("manifests") orelse
            return error.InvalidIndex;
        if (manifests != .array) return error.InvalidIndex;

        const selected_index = try selectRoot(
            manifests.array.items,
            layout_reference.selection,
        );
        const descriptor_json = std.json.Stringify.valueAlloc(
            self.allocator,
            manifests.array.items[selected_index],
            .{},
        ) catch return error.InvalidIndex;
        errdefer self.allocator.free(descriptor_json);

        var descriptor_parsed = std.json.parseFromSlice(
            model.Descriptor,
            self.allocator,
            descriptor_json,
            .{ .ignore_unknown_fields = true },
        ) catch return error.InvalidIndex;
        errdefer descriptor_parsed.deinit();
        model.validateRootDescriptor(descriptor_parsed.value) catch
            return error.InvalidIndex;

        var metadata = try self.readMetadata(
            self.allocator,
            descriptor_parsed.value,
            self.metadata_limit,
        );
        defer metadata.deinit();
        try validateRootDocument(
            self.allocator,
            descriptor_parsed.value,
            metadata.bytes,
        );
        const bytes = try self.allocator.dupe(u8, metadata.bytes);

        return .{
            .allocator = self.allocator,
            .descriptor = descriptor_parsed.value,
            .descriptor_json = descriptor_json,
            .descriptor_parsed = descriptor_parsed,
            .bytes = bytes,
        };
    }

    pub fn validateLayout(self: *Source) !void {
        const layout_bytes = self.readFile(
            "oci-layout",
            layout_file_limit,
        ) catch return error.InvalidLayout;
        defer self.allocator.free(layout_bytes);
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            layout_bytes,
            .{},
        ) catch return error.InvalidLayout;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidLayout,
        };
        const version = object.get("imageLayoutVersion") orelse
            return error.InvalidLayoutVersion;
        if (version != .string or
            !std.mem.eql(u8, version.string, "1.0.0"))
        {
            return error.InvalidLayoutVersion;
        }

        const index_bytes = self.readIndexBytes() catch |err| switch (err) {
            error.MetadataTooLarge => return err,
            else => return error.InvalidIndex,
        };
        defer self.allocator.free(index_bytes);
        try validateIndexBytes(self.allocator, index_bytes);

        var dir = Io.Dir.cwd().openDir(self.io, self.path, .{}) catch
            return error.InvalidLayout;
        defer dir.close(self.io);
        var blobs = dir.openDir(self.io, "blobs/sha256", .{}) catch
            return error.InvalidLayout;
        blobs.close(self.io);
    }

    /// Implements `transport.Source.readMetadata`.
    pub fn readMetadata(
        self: *Source,
        allocator: std.mem.Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !transport.Metadata {
        const digest = model.validateDescriptor(descriptor) catch
            return error.CorruptBlob;
        if (descriptor.size > max_bytes or
            descriptor.size > self.metadata_limit or
            descriptor.size > std.math.maxInt(usize))
        {
            return error.MetadataTooLarge;
        }
        const path = digest.blobPath();
        const bytes = try self.readVerifiedAlloc(
            allocator,
            &path,
            digest,
            descriptor.size,
        );
        return .{ .allocator = allocator, .bytes = bytes };
    }

    /// Implements `transport.Source.copyVerifiedTo`.
    pub fn copyVerifiedTo(
        self: *Source,
        descriptor: model.Descriptor,
        destination: Io.File,
    ) !void {
        const digest = model.validateDescriptor(descriptor) catch
            return error.CorruptBlob;
        const path = digest.blobPath();
        var dir = Io.Dir.cwd().openDir(self.io, self.path, .{}) catch
            return error.InvalidLayout;
        defer dir.close(self.io);
        var file = dir.openFile(self.io, &path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.MissingBlob,
            else => return err,
        };
        defer file.close(self.io);
        if (try file.length(self.io) != descriptor.size) {
            return error.CorruptBlob;
        }

        var verifier = content.Verifier.init(digest, descriptor.size);
        var buffer: [transport.copy_buffer_size]u8 = undefined;
        var offset: u64 = 0;
        while (offset < descriptor.size) {
            const remaining: usize = @intCast(@min(
                descriptor.size - offset,
                buffer.len,
            ));
            const count = try file.readPositional(
                self.io,
                &.{buffer[0..remaining]},
                offset,
            );
            if (count == 0) return error.CorruptBlob;
            verifier.update(buffer[0..count]) catch
                return error.CorruptBlob;
            try destination.writeStreamingAll(self.io, buffer[0..count]);
            offset += count;
        }
        verifier.finish() catch return error.CorruptBlob;
    }

    pub fn blobState(
        self: *Source,
        descriptor: model.Descriptor,
    ) !BlobState {
        const digest = model.validateDescriptor(descriptor) catch
            return .corrupt;
        const path = digest.blobPath();
        return self.verifiedPathState(&path, digest, descriptor.size);
    }

    fn readIndexBytes(self: *Source) ![]u8 {
        return self.readFile("index.json", self.metadata_limit);
    }

    fn readFile(
        self: *Source,
        relative: []const u8,
        max_size: u64,
    ) ![]u8 {
        var dir = try Io.Dir.cwd().openDir(self.io, self.path, .{});
        defer dir.close(self.io);
        var file = try dir.openFile(self.io, relative, .{});
        defer file.close(self.io);
        const size = try file.length(self.io);
        if (size > max_size or size > std.math.maxInt(usize)) {
            return error.MetadataTooLarge;
        }
        const bytes = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) {
            return error.InvalidLayout;
        }
        return bytes;
    }

    fn readVerifiedAlloc(
        self: *Source,
        allocator: std.mem.Allocator,
        relative: []const u8,
        digest: content.Digest,
        size: u64,
    ) ![]u8 {
        if (size > std.math.maxInt(usize)) return error.MetadataTooLarge;
        var dir = Io.Dir.cwd().openDir(self.io, self.path, .{}) catch
            return error.InvalidLayout;
        defer dir.close(self.io);
        var file = dir.openFile(self.io, relative, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.MissingBlob,
            else => return err,
        };
        defer file.close(self.io);
        if (try file.length(self.io) != size) return error.CorruptBlob;

        const bytes = try allocator.alloc(u8, @intCast(size));
        errdefer allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) {
            return error.CorruptBlob;
        }
        content.verifyBytes(digest, size, bytes) catch
            return error.CorruptBlob;
        return bytes;
    }

    fn verifiedPathState(
        self: *Source,
        relative: []const u8,
        digest: content.Digest,
        size: u64,
    ) !BlobState {
        var dir = try Io.Dir.cwd().openDir(self.io, self.path, .{});
        defer dir.close(self.io);
        var file = dir.openFile(self.io, relative, .{}) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        defer file.close(self.io);
        if (try file.length(self.io) != size) return .corrupt;
        verifyFile(self.io, file, digest, size) catch return .corrupt;
        return .valid;
    }
};

/// A destination writes either directly into a valid existing layout or into
/// a sibling staging layout that is renamed into view only by `finish`.
pub const Destination = struct {
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    work_path: []u8,
    is_new: bool,
    bootstrap_lock: ?Io.File = null,
    failure_point: FailurePoint = .none,
    prepared: bool = false,
    prepared_digest: ?content.Digest = null,
    staged_digest: ?content.Digest = null,
    committed: bool = false,
    committed_selection: ?reference.Selection = null,

    pub fn init(
        io: Io,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !Destination {
        const parent = std.fs.path.dirname(path) orelse ".";
        const base = std.fs.path.basename(path);
        if (base.len == 0 or std.mem.eql(u8, base, ".") or
            std.mem.eql(u8, base, ".."))
        {
            return error.InvalidDestinationPath;
        }
        try Io.Dir.cwd().createDirPath(io, parent);
        var bootstrap_lock = try openBootstrapLock(
            io,
            allocator,
            parent,
            base,
        );
        errdefer bootstrap_lock.close(io);

        const existing = Io.Dir.cwd().openDir(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |dir| {
            dir.close(io);
            var source = Source.init(io, allocator, path);
            try source.validateLayout();
            const work_path = try allocator.dupe(u8, path);
            bootstrap_lock.close(io);
            return .{
                .io = io,
                .allocator = allocator,
                .path = path,
                .work_path = work_path,
                .is_new = false,
            };
        }

        const staging = try createUniqueDirectory(
            io,
            allocator,
            parent,
            base,
        );
        errdefer Io.Dir.cwd().deleteTree(io, staging) catch {};
        errdefer allocator.free(staging);
        var result: Destination = .{
            .io = io,
            .allocator = allocator,
            .path = path,
            .work_path = staging,
            .is_new = true,
            .bootstrap_lock = bootstrap_lock,
        };
        try result.createSkeleton();
        return result;
    }

    pub fn deinit(self: *Destination) void {
        if (self.is_new) {
            Io.Dir.cwd().deleteTree(self.io, self.work_path) catch {};
        }
        if (self.bootstrap_lock) |lock| lock.close(self.io);
        self.allocator.free(self.work_path);
        self.* = undefined;
    }

    pub fn asTransport(self: *Destination) transport.Destination {
        return transport.Destination.init(self);
    }

    pub fn prepareRoot(
        self: *Destination,
        root: model.Descriptor,
        selection: ?reference.Selection,
    ) !void {
        model.validateRootDescriptor(root) catch
            return error.DescriptorMismatch;
        const digest = content.Digest.parse(root.digest) catch
            return error.DescriptorMismatch;
        if (selection) |selected| switch (selected) {
            .tag => |tag| {
                if (!validLayoutName(tag)) return error.DescriptorMismatch;
            },
            .digest => |expected| {
                if (!digest.eql(expected)) return error.DescriptorMismatch;
            },
        };

        const bytes = try readLayoutFile(
            self.io,
            self.allocator,
            self.work_path,
            "index.json",
            default_metadata_limit,
        );
        defer self.allocator.free(bytes);
        var parsed = try parseIndexValue(self.allocator, bytes);
        defer parsed.deinit();
        _ = try mergeRoot(
            parsed.arena.allocator(),
            &parsed.value,
            root,
            null,
            selection,
        );

        self.prepared = true;
        self.prepared_digest = digest;
    }

    pub fn ensureDescriptor(
        self: *Destination,
        transfer: transport.DescriptorTransfer,
    ) !transport.DescriptorResult {
        if (!self.prepared) return error.DestinationNotPrepared;
        return switch (transfer.data) {
            .exact_metadata => |bytes| self.ensureContent(
                transfer.descriptor,
                bytes,
                null,
            ),
            .opaque_blob => |source| self.ensureContent(
                transfer.descriptor,
                null,
                source,
            ),
        };
    }

    pub fn stageRoot(
        self: *Destination,
        publication: transport.RootPublication,
    ) !transport.DescriptorResult {
        if (!self.prepared) return error.DestinationNotPrepared;
        const digest = try publicationDigest(publication);
        if (!digest.eql(self.prepared_digest.?)) {
            return error.DescriptorMismatch;
        }
        const result = try self.ensureContent(
            publication.descriptor,
            publication.exact_bytes,
            null,
        );
        self.staged_digest = digest;
        return result;
    }

    pub fn commitRoot(
        self: *Destination,
        publication: transport.RootPublication,
        selection: ?reference.Selection,
    ) !transport.CommitResult {
        if (!self.prepared) return error.DestinationNotPrepared;
        const digest = try publicationDigest(publication);
        if (self.staged_digest == null or
            !digest.eql(self.staged_digest.?) or
            !digest.eql(self.prepared_digest.?))
        {
            return error.RootNotStaged;
        }

        var lock = try self.openCatalogLock();
        defer lock.close(self.io);

        var source = Source.init(self.io, self.allocator, self.work_path);
        if (try source.blobState(publication.descriptor) != .valid) {
            return error.CorruptBlob;
        }

        const current = try readLayoutFile(
            self.io,
            self.allocator,
            self.work_path,
            "index.json",
            default_metadata_limit,
        );
        defer self.allocator.free(current);
        var parsed = try parseIndexValue(self.allocator, current);
        defer parsed.deinit();
        const changed = try mergeRoot(
            parsed.arena.allocator(),
            &parsed.value,
            publication.descriptor,
            publication.descriptor_json,
            selection,
        );
        if (!changed) {
            self.committed = true;
            self.committed_selection = selection;
            return .unchanged;
        }

        const output = try std.json.Stringify.valueAlloc(
            self.allocator,
            parsed.value,
            .{},
        );
        defer self.allocator.free(output);
        try validateIndexBytes(self.allocator, output);
        if (self.failure_point == .before_index_publish) {
            return error.InjectedFailure;
        }

        var dir = try Io.Dir.cwd().openDir(self.io, self.work_path, .{});
        defer dir.close(self.io);
        const temporary = try createUniqueTempFile(
            self.io,
            self.allocator,
            dir,
            "index",
        );
        defer self.allocator.free(temporary.name);
        var file = temporary.file;
        var file_closed = false;
        defer {
            if (!file_closed) file.close(self.io);
            dir.deleteFile(self.io, temporary.name) catch {};
        }
        try file.writeStreamingAll(self.io, output);
        try file.sync(self.io);
        if (self.failure_point == .after_index_temp_sync) {
            return error.InjectedFailure;
        }
        file.close(self.io);
        file_closed = true;
        try Io.Dir.rename(
            dir,
            temporary.name,
            dir,
            "index.json",
            self.io,
        );
        self.committed = true;
        self.committed_selection = selection;
        return .published;
    }

    pub fn finish(self: *Destination) !void {
        if (!self.committed) return error.DestinationNotCommitted;
        if (!self.is_new) return;

        var source = Source.init(self.io, self.allocator, self.work_path);
        var resolved = try source.resolve(.{
            .path = self.work_path,
            .selection = self.committed_selection,
        });
        defer resolved.deinit();
        const actual = try content.Digest.parse(resolved.descriptor.digest);
        if (!actual.eql(self.prepared_digest.?)) {
            return error.DescriptorMismatch;
        }

        try Io.Dir.renamePreserve(
            Io.Dir.cwd(),
            self.work_path,
            Io.Dir.cwd(),
            self.path,
            self.io,
        );
        self.is_new = false;
        if (self.bootstrap_lock) |lock| {
            lock.close(self.io);
            self.bootstrap_lock = null;
        }
    }

    fn ensureContent(
        self: *Destination,
        descriptor: model.Descriptor,
        bytes: ?[]const u8,
        source: ?transport.Source,
    ) !transport.DescriptorResult {
        const digest = model.validateDescriptor(descriptor) catch
            return error.CorruptBlob;
        if (bytes) |data| {
            content.verifyBytes(digest, descriptor.size, data) catch
                return error.CorruptBlob;
        } else if (source == null) {
            return error.CorruptBlob;
        }

        var layout_source = Source.init(
            self.io,
            self.allocator,
            self.work_path,
        );
        switch (try layout_source.blobState(descriptor)) {
            .valid => return .reused,
            .corrupt => return error.CorruptBlob,
            .missing => {},
        }

        var layout_dir = try Io.Dir.cwd().openDir(
            self.io,
            self.work_path,
            .{},
        );
        defer layout_dir.close(self.io);
        var blob_dir = try layout_dir.openDir(
            self.io,
            "blobs/sha256",
            .{},
        );
        defer blob_dir.close(self.io);
        const temporary = try createUniqueTempFile(
            self.io,
            self.allocator,
            blob_dir,
            "blob",
        );
        defer self.allocator.free(temporary.name);
        var file = temporary.file;
        var file_closed = false;
        defer {
            if (!file_closed) file.close(self.io);
            blob_dir.deleteFile(self.io, temporary.name) catch {};
        }

        if (bytes) |data| {
            try file.writeStreamingAll(self.io, data);
        } else {
            try source.?.copyVerifiedTo(descriptor, file);
        }
        try file.sync(self.io);
        try verifyFile(self.io, file, digest, descriptor.size);
        if (self.failure_point == .after_blob_temp_sync) {
            return error.InjectedFailure;
        }
        file.close(self.io);
        file_closed = true;

        const component = digest.blobPathComponent();
        Io.Dir.renamePreserve(
            blob_dir,
            temporary.name,
            blob_dir,
            &component,
            self.io,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => switch (try layout_source.blobState(
                descriptor,
            )) {
                .valid => return .reused,
                .missing, .corrupt => return error.CorruptBlob,
            },
            else => return err,
        };
        return .transferred;
    }

    fn createSkeleton(self: *Destination) !void {
        var dir = try Io.Dir.cwd().openDir(self.io, self.work_path, .{});
        defer dir.close(self.io);
        try dir.createDirPath(self.io, "blobs/sha256");
        try writeSyncedFile(
            self.io,
            dir,
            "oci-layout",
            "{\"imageLayoutVersion\":\"1.0.0\"}\n",
        );
        try writeSyncedFile(
            self.io,
            dir,
            "index.json",
            "{\"schemaVersion\":2,\"manifests\":[]}\n",
        );
        var source = Source.init(self.io, self.allocator, self.work_path);
        try source.validateLayout();
    }

    fn openCatalogLock(self: *Destination) !Io.File {
        var dir = try Io.Dir.cwd().openDir(self.io, self.work_path, .{});
        defer dir.close(self.io);
        return dir.createFile(self.io, ".wabt-oci.lock", .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
    }
};

const UniqueTempFile = struct {
    name: []u8,
    file: Io.File,
};

fn selectRoot(
    items: []const std.json.Value,
    selection: ?reference.Selection,
) !usize {
    if (selection == null) {
        if (items.len == 0) return error.RootNotFound;
        if (items.len != 1) return error.AmbiguousRoot;
        return 0;
    }

    for (items, 0..) |item, index| {
        const matches = switch (selection.?) {
            .digest => |digest| blk: {
                const text = digest.format();
                if (item != .object) return error.InvalidIndex;
                const candidate = item.object.get("digest") orelse
                    return error.InvalidIndex;
                if (candidate != .string) return error.InvalidIndex;
                break :blk std.mem.eql(u8, candidate.string, &text);
            },
            .tag => |tag| blk: {
                const name = try descriptorReferenceName(item);
                break :blk name != null and std.mem.eql(u8, name.?, tag);
            },
        };
        if (!matches) continue;
        return index;
    }
    return error.RootNotFound;
}

fn validateRootDocument(
    allocator: std.mem.Allocator,
    descriptor: model.Descriptor,
    bytes: []const u8,
) !void {
    var document = model.parseDocument(allocator, bytes) catch
        return error.InvalidIndex;
    defer document.deinit();
    const descriptor_class = model.classifyMediaType(descriptor.mediaType);
    if ((descriptor_class.isIndex() and document.kind() != .index) or
        (descriptor_class.isManifest() and document.kind() != .manifest))
    {
        return error.DescriptorMismatch;
    }
    const document_media_type = switch (document.value) {
        .index => |parsed| parsed.value.mediaType,
        .manifest => |parsed| parsed.value.mediaType,
    };
    if (document_media_type) |actual| {
        if (!std.mem.eql(u8, actual, descriptor.mediaType)) {
            return error.DescriptorMismatch;
        }
    }
}

fn publicationDigest(
    publication: transport.RootPublication,
) !content.Digest {
    model.validateRootDescriptor(publication.descriptor) catch
        return error.DescriptorMismatch;
    const digest = content.Digest.parse(publication.descriptor.digest) catch
        return error.DescriptorMismatch;
    content.verifyBytes(
        digest,
        publication.descriptor.size,
        publication.exact_bytes,
    ) catch return error.CorruptBlob;
    return digest;
}

fn verifyFile(
    io: Io,
    file: Io.File,
    digest: content.Digest,
    size: u64,
) !void {
    if (try file.length(io) != size) return error.CorruptBlob;
    var verifier = content.Verifier.init(digest, size);
    var buffer: [transport.copy_buffer_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const remaining: usize = @intCast(@min(size - offset, buffer.len));
        const count = try file.readPositional(
            io,
            &.{buffer[0..remaining]},
            offset,
        );
        if (count == 0) return error.CorruptBlob;
        verifier.update(buffer[0..count]) catch return error.CorruptBlob;
        offset += count;
    }
    verifier.finish() catch return error.CorruptBlob;
}

fn validateIndexBytes(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(
        model.Index,
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return error.InvalidIndex;
    defer parsed.deinit();
    model.validateIndex(parsed.value) catch return error.InvalidIndex;
}

fn parseIndexValue(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(std.json.Value) {
    try validateIndexBytes(allocator, bytes);
    return std.json.parseFromSlice(
        std.json.Value,
        allocator,
        bytes,
        .{},
    ) catch return error.InvalidIndex;
}

fn readLayoutFile(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    relative: []const u8,
    max_size: u64,
) ![]u8 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    var file = try dir.openFile(io, relative, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size > max_size or size > std.math.maxInt(usize)) {
        return error.MetadataTooLarge;
    }
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) {
        return error.InvalidIndex;
    }
    return bytes;
}

fn writeSyncedFile(
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    var file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn createUniqueDirectory(
    io: Io,
    allocator: std.mem.Allocator,
    parent: []const u8,
    base: []const u8,
) ![]u8 {
    var random: [16]u8 = undefined;
    for (0..64) |_| {
        try io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            ".wabt-oci-{s}-staging-{s}",
            .{ base, suffix },
        );
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ parent, name });
        Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                return err;
            },
        };
        return path;
    }
    return error.PathAlreadyExists;
}

fn openBootstrapLock(
    io: Io,
    allocator: std.mem.Allocator,
    parent: []const u8,
    base: []const u8,
) !Io.File {
    var parent_dir = try Io.Dir.cwd().openDir(io, parent, .{});
    defer parent_dir.close(io);
    const name = try std.fmt.allocPrint(
        allocator,
        ".{s}.wabt-oci-bootstrap.lock",
        .{base},
    );
    defer allocator.free(name);
    return parent_dir.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    });
}

fn createUniqueTempFile(
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
    kind: []const u8,
) !UniqueTempFile {
    var random: [16]u8 = undefined;
    for (0..64) |_| {
        try io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const name = try std.fmt.allocPrint(
            allocator,
            ".wabt-oci-{s}-{s}.tmp",
            .{ kind, suffix },
        );
        const file = dir.createFile(io, name, .{
            .exclusive = true,
            .read = true,
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

fn mergeRoot(
    allocator: std.mem.Allocator,
    index: *std.json.Value,
    root: model.Descriptor,
    root_json: ?[]const u8,
    selection: ?reference.Selection,
) !bool {
    const object = switch (index.*) {
        .object => |*object| object,
        else => return error.InvalidIndex,
    };
    const schema = object.get("schemaVersion") orelse
        return error.InvalidIndex;
    if (schema != .integer or schema.integer != 2) {
        return error.InvalidIndex;
    }
    const manifests = object.getPtr("manifests") orelse
        return error.InvalidIndex;
    if (manifests.* != .array) return error.InvalidIndex;

    _ = try containsCompatibleDigest(
        allocator,
        manifests.array.items,
        root,
    );
    const generated = if (root_json == null)
        try std.json.Stringify.valueAlloc(allocator, root, .{})
    else
        null;
    defer if (generated) |bytes| allocator.free(bytes);
    var root_value = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        root_json orelse generated.?,
        .{},
    ) catch return error.InvalidIndex;
    if (root_value != .object) return error.InvalidIndex;
    const parsed_root = parseDescriptorLeaky(allocator, root_value) catch
        return error.InvalidIndex;
    model.validateRootDescriptor(parsed_root) catch
        return error.DescriptorMismatch;
    if (!descriptorIdentityEqual(parsed_root, root)) {
        return error.DescriptorMismatch;
    }

    if (selection == null) {
        try setReferenceName(allocator, &root_value.object, null);
        var unannotated: ?usize = null;
        for (manifests.array.items, 0..) |item, index_in_catalog| {
            if (try descriptorReferenceName(item) != null) continue;
            if (unannotated != null) return error.AmbiguousRoot;
            unannotated = index_in_catalog;
        }
        if (unannotated) |index_in_catalog| {
            if (try valuesEqual(
                allocator,
                manifests.array.items[index_in_catalog],
                root_value,
            )) return false;
            manifests.array.items[index_in_catalog] = root_value;
        } else {
            try manifests.array.append(root_value);
        }
        return true;
    }

    switch (selection.?) {
        .tag => |tag| {
            try setReferenceName(allocator, &root_value.object, tag);
            for (manifests.array.items) |*item| {
                const old = try descriptorReferenceName(item.*) orelse
                    continue;
                if (!std.mem.eql(u8, old, tag)) continue;
                if (try valuesEqual(allocator, item.*, root_value)) {
                    return false;
                }
                item.* = root_value;
                return true;
            }
            try manifests.array.append(root_value);
            return true;
        },
        .digest => |digest| {
            const actual = content.Digest.parse(root.digest) catch
                return error.DescriptorMismatch;
            if (!actual.eql(digest)) return error.DescriptorMismatch;
            const desired_name = try descriptorReferenceName(root_value);
            for (manifests.array.items) |*item| {
                if (item.* != .object) return error.InvalidIndex;
                const candidate = item.object.get("digest") orelse
                    return error.InvalidIndex;
                if (candidate != .string or
                    !std.mem.eql(u8, candidate.string, root.digest))
                {
                    continue;
                }
                if (try valuesEqual(allocator, item.*, root_value)) {
                    return false;
                }
                const existing_name = try descriptorReferenceName(item.*);
                if (optionalStringsEqual(existing_name, desired_name)) {
                    item.* = root_value;
                    return true;
                }
            }
            try manifests.array.append(root_value);
            return true;
        },
    }
}

fn containsCompatibleDigest(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
    root: model.Descriptor,
) !bool {
    var found = false;
    for (items) |item| {
        if (item != .object) return error.InvalidIndex;
        const candidate_digest = item.object.get("digest") orelse
            return error.InvalidIndex;
        if (candidate_digest != .string) return error.InvalidIndex;
        if (!std.mem.eql(u8, candidate_digest.string, root.digest)) continue;
        const candidate = parseDescriptorLeaky(allocator, item) catch
            return error.InvalidIndex;
        if (candidate.size != root.size or
            !std.mem.eql(u8, candidate.mediaType, root.mediaType))
        {
            return error.ConflictingDescriptor;
        }
        found = true;
    }
    return found;
}

fn parseDescriptorLeaky(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !model.Descriptor {
    return std.json.parseFromValueLeaky(
        model.Descriptor,
        allocator,
        value,
        .{ .ignore_unknown_fields = true },
    );
}

fn descriptorReferenceName(value: std.json.Value) !?[]const u8 {
    if (value != .object) return error.InvalidIndex;
    const annotations = value.object.get("annotations") orelse return null;
    if (annotations != .object) return error.InvalidIndex;
    const name = annotations.object.get(reference_name_annotation) orelse
        return null;
    if (name != .string) return error.InvalidIndex;
    return name.string;
}

fn setReferenceName(
    allocator: std.mem.Allocator,
    descriptor: *std.json.ObjectMap,
    name: ?[]const u8,
) !void {
    var annotations = descriptor.getPtr("annotations");
    if (annotations == null) {
        if (name == null) return;
        try descriptor.put(
            allocator,
            "annotations",
            .{ .object = .empty },
        );
        annotations = descriptor.getPtr("annotations");
    } else if (annotations.?.* != .object) {
        return error.InvalidIndex;
    }
    if (name) |value| {
        try annotations.?.object.put(
            allocator,
            reference_name_annotation,
            .{ .string = value },
        );
    } else {
        _ = annotations.?.object.orderedRemove(reference_name_annotation);
    }
}

fn valuesEqual(
    allocator: std.mem.Allocator,
    left: std.json.Value,
    right: std.json.Value,
) !bool {
    const left_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        left,
        .{},
    );
    defer allocator.free(left_bytes);
    const right_bytes = try std.json.Stringify.valueAlloc(
        allocator,
        right,
        .{},
    );
    defer allocator.free(right_bytes);
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn descriptorIdentityEqual(
    left: model.Descriptor,
    right: model.Descriptor,
) bool {
    return left.size == right.size and
        std.mem.eql(u8, left.mediaType, right.mediaType) and
        std.mem.eql(u8, left.digest, right.digest);
}

fn optionalStringsEqual(
    left: ?[]const u8,
    right: ?[]const u8,
) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn validLayoutName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or
        (!std.ascii.isAlphanumeric(name[0]) and name[0] != '_'))
    {
        return false;
    }
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and
            byte != '.' and byte != '-')
        {
            return false;
        }
    }
    return true;
}
