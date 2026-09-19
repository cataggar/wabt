//! Transport-neutral contracts for discovering and publishing OCI graphs.
const std = @import("std");
const content = @import("content.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");

pub const copy_buffer_size = 64 * 1024;

pub const DescriptorRole = enum {
    root,
    index_child,
    config,
    layer,
};

pub const DescriptorRoles = packed struct {
    root: bool = false,
    index_child: bool = false,
    config: bool = false,
    layer: bool = false,

    pub fn init(role: DescriptorRole) DescriptorRoles {
        var roles: DescriptorRoles = .{};
        roles.add(role);
        return roles;
    }

    pub fn add(self: *DescriptorRoles, role: DescriptorRole) void {
        switch (role) {
            .root => self.root = true,
            .index_child => self.index_child = true,
            .config => self.config = true,
            .layer => self.layer = true,
        }
    }

    pub fn contains(self: DescriptorRoles, role: DescriptorRole) bool {
        return switch (role) {
            .root => self.root,
            .index_child => self.index_child,
            .config => self.config,
            .layer => self.layer,
        };
    }
};

/// Metadata ownership is explicit so graph discovery can retain exact bytes
/// without depending on a source transport's lifetime.
pub const Metadata = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn copy(
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) std.mem.Allocator.Error!Metadata {
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, bytes),
        };
    }

    pub fn deinit(self: *Metadata) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Source = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_metadata: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            descriptor: model.Descriptor,
            max_bytes: u64,
        ) anyerror!Metadata,
        read_manifest_metadata: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            descriptor: model.Descriptor,
            max_bytes: u64,
        ) anyerror!Metadata,
        copy_verified_to: *const fn (
            context: *anyopaque,
            descriptor: model.Descriptor,
            destination: std.Io.File,
        ) anyerror!void,
    };

    /// Adapts a mutable implementation pointer. Implementations provide
    /// `readMetadata` and `copyVerifiedTo`; casts remain centralized here.
    pub fn init(pointer: anytype) Source {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn readMetadata(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                descriptor: model.Descriptor,
                max_bytes: u64,
            ) anyerror!Metadata {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.readMetadata(allocator, descriptor, max_bytes);
            }

            fn copyVerifiedTo(
                context: *anyopaque,
                descriptor: model.Descriptor,
                destination: std.Io.File,
            ) anyerror!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.copyVerifiedTo(descriptor, destination);
            }

            fn readManifestMetadata(
                context: *anyopaque,
                allocator: std.mem.Allocator,
                descriptor: model.Descriptor,
                max_bytes: u64,
            ) anyerror!Metadata {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                if (comptime @hasDecl(@TypeOf(implementation.*), "readManifestMetadata")) {
                    return implementation.readManifestMetadata(
                        allocator,
                        descriptor,
                        max_bytes,
                    );
                }
                return implementation.readMetadata(allocator, descriptor, max_bytes);
            }

            const vtable: VTable = .{
                .read_metadata = @This().readMetadata,
                .read_manifest_metadata = @This().readManifestMetadata,
                .copy_verified_to = @This().copyVerifiedTo,
            };
        };

        return .{
            .context = pointer,
            .vtable = &Adapter.vtable,
        };
    }

    /// The returned allocation is owned by the caller. Sources must reject a
    /// response larger than `max_bytes`; graph discovery checks again.
    pub fn readMetadata(
        self: Source,
        allocator: std.mem.Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !Metadata {
        return self.vtable.read_metadata(
            self.context,
            allocator,
            descriptor,
            max_bytes,
        );
    }

    /// Reads an index child through a manifest-capable source path even when
    /// its extension media type is not recognized locally.
    pub fn readManifestMetadata(
        self: Source,
        allocator: std.mem.Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !Metadata {
        return self.vtable.read_manifest_metadata(
            self.context,
            allocator,
            descriptor,
            max_bytes,
        );
    }

    /// Streams an opaque descriptor into a destination-owned file while
    /// verifying its declared size and digest.
    pub fn copyVerifiedTo(
        self: Source,
        descriptor: model.Descriptor,
        destination: std.Io.File,
    ) !void {
        return self.vtable.copy_verified_to(
            self.context,
            descriptor,
            destination,
        );
    }
};

pub const DescriptorData = union(enum) {
    exact_metadata: []const u8,
    opaque_blob: Source,
};

pub const DescriptorTransfer = struct {
    descriptor: model.Descriptor,
    roles: DescriptorRoles,
    data: DescriptorData,
};

pub const RootPublication = struct {
    descriptor: model.Descriptor,
    /// Exact selected-root descriptor JSON, when the source has one.
    descriptor_json: ?[]const u8,
    /// Exact verified manifest or index bytes.
    exact_bytes: []const u8,
};

pub const DescriptorResult = enum {
    transferred,
    reused,
    mounted,
};

pub const CommitResult = enum {
    published,
    unchanged,
};

pub const Counts = struct {
    transferred: u64 = 0,
    reused: u64 = 0,
    mounted: u64 = 0,

    pub fn record(self: *Counts, result: DescriptorResult) error{CountOverflow}!void {
        const counter = switch (result) {
            .transferred => &self.transferred,
            .reused => &self.reused,
            .mounted => &self.mounted,
        };
        counter.* = std.math.add(u64, counter.*, 1) catch return error.CountOverflow;
    }
};

pub const Result = struct {
    root: content.Digest,
    counts: Counts,
    commit: CommitResult,
};

pub const Destination = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prepare_root: *const fn (
            context: *anyopaque,
            root: model.Descriptor,
            selection: ?reference.Selection,
        ) anyerror!void,
        ensure_descriptor: *const fn (
            context: *anyopaque,
            transfer: DescriptorTransfer,
        ) anyerror!DescriptorResult,
        stage_root: *const fn (
            context: *anyopaque,
            publication: RootPublication,
        ) anyerror!DescriptorResult,
        commit_root: *const fn (
            context: *anyopaque,
            publication: RootPublication,
            selection: ?reference.Selection,
        ) anyerror!CommitResult,
        finish: *const fn (context: *anyopaque) anyerror!void,
    };

    /// Adapts a mutable implementation pointer. The implementation methods
    /// have the same names and arguments as the public methods below.
    pub fn init(pointer: anytype) Destination {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn prepareRoot(
                context: *anyopaque,
                root: model.Descriptor,
                selection: ?reference.Selection,
            ) anyerror!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.prepareRoot(root, selection);
            }

            fn ensureDescriptor(
                context: *anyopaque,
                transfer: DescriptorTransfer,
            ) anyerror!DescriptorResult {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.ensureDescriptor(transfer);
            }

            fn stageRoot(
                context: *anyopaque,
                publication: RootPublication,
            ) anyerror!DescriptorResult {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.stageRoot(publication);
            }

            fn commitRoot(
                context: *anyopaque,
                publication: RootPublication,
                selection: ?reference.Selection,
            ) anyerror!CommitResult {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.commitRoot(publication, selection);
            }

            fn finish(context: *anyopaque) anyerror!void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                return implementation.finish();
            }

            const vtable: VTable = .{
                .prepare_root = @This().prepareRoot,
                .ensure_descriptor = @This().ensureDescriptor,
                .stage_root = @This().stageRoot,
                .commit_root = @This().commitRoot,
                .finish = @This().finish,
            };
        };

        return .{
            .context = pointer,
            .vtable = &Adapter.vtable,
        };
    }

    /// Performs selector and conflict checks before any descriptor transfer.
    pub fn prepareRoot(
        self: Destination,
        root: model.Descriptor,
        selection: ?reference.Selection,
    ) !void {
        return self.vtable.prepare_root(self.context, root, selection);
    }

    pub fn ensureDescriptor(
        self: Destination,
        transfer: DescriptorTransfer,
    ) !DescriptorResult {
        return self.vtable.ensure_descriptor(self.context, transfer);
    }

    /// Stages root content only after every dependency has succeeded.
    pub fn stageRoot(
        self: Destination,
        publication: RootPublication,
    ) !DescriptorResult {
        return self.vtable.stage_root(self.context, publication);
    }

    /// Makes the selected root visible. This is separate from staging so
    /// publication cannot precede dependency completion.
    pub fn commitRoot(
        self: Destination,
        publication: RootPublication,
        selection: ?reference.Selection,
    ) !CommitResult {
        return self.vtable.commit_root(self.context, publication, selection);
    }

    pub fn finish(self: Destination) !void {
        return self.vtable.finish(self.context);
    }
};

pub const ProgressPhase = enum {
    discovery,
    preflight,
    transfer,
    stage_root,
    commit_root,
    finish,
};

pub const Progress = struct {
    phase: ProgressPhase,
    digest: ?content.Digest = null,
    outcome: ?DescriptorResult = null,
    counts: Counts = .{},
};

pub const FailureCode = enum {
    unavailable,
    corrupt_content,
    unsupported_graph,
    limit_exceeded,
    conflict,
    transfer_failed,
    commit_failed,
    internal,
};

/// Deliberately excludes URLs, credentials, implementation errors, and raw
/// messages so callers can report it across trust boundaries.
pub const Failure = struct {
    phase: ProgressPhase,
    digest: ?content.Digest = null,
    code: FailureCode,
};

pub const Reporter = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        progress: *const fn (context: *anyopaque, event: Progress) void,
        failure: *const fn (context: *anyopaque, event: Failure) void,
    };

    pub fn init(pointer: anytype) Reporter {
        const Pointer = @TypeOf(pointer);
        const Adapter = struct {
            fn progress(context: *anyopaque, event: Progress) void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                implementation.progress(event);
            }

            fn failure(context: *anyopaque, event: Failure) void {
                const implementation: Pointer = @ptrCast(@alignCast(context));
                implementation.failure(event);
            }

            const vtable: VTable = .{
                .progress = @This().progress,
                .failure = @This().failure,
            };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn reportProgress(self: Reporter, event: Progress) void {
        self.vtable.progress(self.context, event);
    }

    pub fn reportFailure(self: Reporter, event: Failure) void {
        self.vtable.failure(self.context, event);
    }
};

/// Reusable verified streaming core for source implementations.
pub fn copyAndVerify(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    descriptor: model.Descriptor,
) !void {
    const digest = try model.validateDescriptor(descriptor);
    var verifier = content.Verifier.init(digest, descriptor.size);
    var buffer: [copy_buffer_size]u8 = undefined;

    while (true) {
        const count = try reader.readSliceShort(&buffer);
        if (count == 0) break;
        const chunk = buffer[0..count];
        try verifier.update(chunk);
        try writer.writeAll(chunk);
    }
    try verifier.finish();
}

const test_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test "verified streaming uses exact bytes and rejects corrupt content" {
    const bytes = "opaque payload";
    const description = try content.describeBytes(bytes);
    const digest_text = description.digest.format();
    const descriptor: model.Descriptor = .{
        .mediaType = "application/wasm",
        .digest = &digest_text,
        .size = description.size,
    };

    var reader = std.Io.Reader.fixed(bytes);
    var output: [bytes.len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try copyAndVerify(&reader, &writer, descriptor);
    try std.testing.expectEqualStrings(bytes, &output);

    var bad_reader = std.Io.Reader.fixed("opaque payloae");
    var bad_output: [bytes.len]u8 = undefined;
    var bad_writer = std.Io.Writer.fixed(&bad_output);
    try std.testing.expectError(
        error.DigestMismatch,
        copyAndVerify(&bad_reader, &bad_writer, descriptor),
    );
}

test "source destination and lifecycle adapters preserve typed boundaries" {
    const SourceImpl = struct {
        reads: usize = 0,
        copies: usize = 0,

        fn readMetadata(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: model.Descriptor,
            max_bytes: u64,
        ) !Metadata {
            self.reads += 1;
            try std.testing.expect(max_bytes >= 2);
            return Metadata.copy(allocator, "{}");
        }

        fn copyVerifiedTo(
            self: *@This(),
            _: model.Descriptor,
            _: std.Io.File,
        ) !void {
            self.copies += 1;
        }
    };
    const DestinationImpl = struct {
        step: usize = 0,

        fn prepareRoot(
            self: *@This(),
            _: model.Descriptor,
            _: ?reference.Selection,
        ) !void {
            try std.testing.expectEqual(@as(usize, 0), self.step);
            self.step = 1;
        }

        fn ensureDescriptor(
            self: *@This(),
            transfer: DescriptorTransfer,
        ) !DescriptorResult {
            try std.testing.expectEqual(@as(usize, 1), self.step);
            try std.testing.expect(transfer.roles.contains(.config));
            try std.testing.expect(transfer.data == .opaque_blob);
            self.step = 2;
            return .reused;
        }

        fn stageRoot(
            self: *@This(),
            publication: RootPublication,
        ) !DescriptorResult {
            try std.testing.expectEqual(@as(usize, 2), self.step);
            try std.testing.expectEqualStrings("{}", publication.exact_bytes);
            self.step = 3;
            return .transferred;
        }

        fn commitRoot(
            self: *@This(),
            publication: RootPublication,
            _: ?reference.Selection,
        ) !CommitResult {
            try std.testing.expectEqual(@as(usize, 3), self.step);
            try std.testing.expectEqualStrings("{}", publication.exact_bytes);
            self.step = 4;
            return .published;
        }

        fn finish(self: *@This()) !void {
            try std.testing.expectEqual(@as(usize, 4), self.step);
            self.step = 5;
        }
    };

    const descriptor: model.Descriptor = .{
        .mediaType = model.media_type_oci_manifest,
        .digest = test_digest,
        .size = 2,
    };
    var source_impl: SourceImpl = .{};
    const source = Source.init(&source_impl);
    var metadata = try source.readMetadata(std.testing.allocator, descriptor, 2);
    defer metadata.deinit();
    try std.testing.expectEqualStrings("{}", metadata.bytes);

    var destination_impl: DestinationImpl = .{};
    const destination = Destination.init(&destination_impl);
    try destination.prepareRoot(descriptor, null);
    const dependency_result = try destination.ensureDescriptor(.{
        .descriptor = descriptor,
        .roles = DescriptorRoles.init(.config),
        .data = .{ .opaque_blob = source },
    });
    try std.testing.expectEqual(DescriptorResult.reused, dependency_result);
    const publication: RootPublication = .{
        .descriptor = descriptor,
        .descriptor_json = null,
        .exact_bytes = "{}",
    };
    try std.testing.expectEqual(
        DescriptorResult.transferred,
        try destination.stageRoot(publication),
    );
    try std.testing.expectEqual(
        CommitResult.published,
        try destination.commitRoot(publication, null),
    );
    try destination.finish();
    try std.testing.expectEqual(@as(usize, 5), destination_impl.step);

    var counts: Counts = .{};
    try counts.record(dependency_result);
    try counts.record(.transferred);
    try std.testing.expectEqual(@as(u64, 1), counts.reused);
    try std.testing.expectEqual(@as(u64, 1), counts.transferred);
    counts.mounted = std.math.maxInt(u64);
    try std.testing.expectError(error.CountOverflow, counts.record(.mounted));
}

test "progress and failure reporting expose only sanitized typed data" {
    const Recorder = struct {
        progress_count: usize = 0,
        failure_count: usize = 0,

        fn progress(self: *@This(), event: Progress) void {
            std.debug.assert(event.phase == .transfer);
            self.progress_count += 1;
        }

        fn failure(self: *@This(), event: Failure) void {
            std.debug.assert(event.code == .corrupt_content);
            self.failure_count += 1;
        }
    };

    var recorder: Recorder = .{};
    const reporter = Reporter.init(&recorder);
    reporter.reportProgress(.{ .phase = .transfer });
    reporter.reportFailure(.{
        .phase = .discovery,
        .code = .corrupt_content,
    });
    try std.testing.expectEqual(@as(usize, 1), recorder.progress_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.failure_count);
}
