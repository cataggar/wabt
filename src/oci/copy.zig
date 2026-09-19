//! Transport-neutral execution of one fully discovered OCI graph plan.
const std = @import("std");
const content = @import("content.zig");
const graph = @import("graph.zig");
const layout = @import("layout.zig");
const model = @import("model.zig");
const reference = @import("reference.zig");
const transport = @import("transport.zig");
const wasm = @import("wasm.zig");

pub const Options = struct {
    limits: graph.Limits = .{},
    failure_point: layout.FailurePoint = .none,
};

/// Transport adapter over the exact bytes returned by `wasm.prepare`.
///
/// The package remains caller-owned and immutable for this source's lifetime.
/// Payload transfer uses a fixed buffer and re-verifies the descriptor while
/// preserving the original bytes.
pub const PackageSource = struct {
    io: std.Io,
    package: *const wasm.PreparedArtifact,

    pub fn init(
        io: std.Io,
        package: *const wasm.PreparedArtifact,
    ) PackageSource {
        return .{ .io = io, .package = package };
    }

    pub fn asTransport(self: *PackageSource) transport.Source {
        return transport.Source.init(self);
    }

    pub fn rootDescriptor(self: *const PackageSource) model.Descriptor {
        return self.package.root_descriptor;
    }

    pub fn root(self: *const PackageSource) graph.Root {
        return .{ .descriptor = self.rootDescriptor() };
    }

    /// Implements `transport.Source.readMetadata`.
    pub fn readMetadata(
        self: *PackageSource,
        allocator: std.mem.Allocator,
        descriptor: model.Descriptor,
        max_bytes: u64,
    ) !transport.Metadata {
        const bytes = if (descriptorIdentityEqual(
            descriptor,
            self.package.root_descriptor,
        ))
            self.package.manifest_bytes
        else if (descriptorIdentityEqual(
            descriptor,
            self.package.config_descriptor,
        ))
            self.package.config_bytes
        else
            return error.DescriptorUnavailable;

        if (descriptor.size > max_bytes) return error.MetadataTooLarge;
        try verifyExactBytes(descriptor, bytes);
        return transport.Metadata.copy(allocator, bytes);
    }

    /// Implements `transport.Source.copyVerifiedTo`.
    pub fn copyVerifiedTo(
        self: *PackageSource,
        descriptor: model.Descriptor,
        destination: std.Io.File,
    ) !void {
        const bytes = if (descriptorIdentityEqual(
            descriptor,
            self.package.root_descriptor,
        ))
            self.package.manifest_bytes
        else if (descriptorIdentityEqual(
            descriptor,
            self.package.config_descriptor,
        ))
            self.package.config_bytes
        else if (descriptorIdentityEqual(
            descriptor,
            self.package.layer_descriptor,
        ))
            self.package.payload_bytes
        else
            return error.DescriptorUnavailable;

        const digest = try model.validateDescriptor(descriptor);
        var verifier = content.Verifier.init(digest, descriptor.size);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + transport.copy_buffer_size, bytes.len);
            const chunk = bytes[offset..end];
            try verifier.update(chunk);
            try destination.writeStreamingAll(self.io, chunk);
            offset = end;
        }
        try verifier.finish();
    }
};

/// The concrete pairing supplied in this increment. Graph discovery finishes
/// before a destination is created or preflighted.
pub fn layoutToLayout(
    io: std.Io,
    allocator: std.mem.Allocator,
    source_reference: reference.LayoutReference,
    destination_reference: reference.LayoutReference,
    options: Options,
) !transport.Result {
    var source = layout.Source.initWithMetadataLimit(
        io,
        allocator,
        source_reference.path,
        options.limits.max_metadata_bytes,
    );
    var resolved = try source.resolve(source_reference);
    defer resolved.deinit();

    var plan = try graph.planCopy(
        allocator,
        source.asTransport(),
        .{
            .descriptor = resolved.descriptor,
            .descriptor_json = resolved.descriptor_json,
        },
        options.limits,
    );
    defer plan.deinit();

    var destination = try layout.Destination.init(
        io,
        allocator,
        destination_reference.path,
    );
    defer destination.deinit();
    destination.failure_point = options.failure_point;

    return executePlan(
        &plan,
        source.asTransport(),
        destination.asTransport(),
        destination_reference.selection,
    );
}

/// Publishes one prepared profile package through the shared graph planner and
/// copy engine. This works for both new and existing OCI layouts.
pub fn packageToLayout(
    io: std.Io,
    allocator: std.mem.Allocator,
    package: *const wasm.PreparedArtifact,
    destination_reference: reference.LayoutReference,
    options: Options,
) !transport.Result {
    var source = PackageSource.init(io, package);
    var destination = try layout.Destination.init(
        io,
        allocator,
        destination_reference.path,
    );
    defer destination.deinit();
    destination.failure_point = options.failure_point;

    return planAndCopy(
        allocator,
        source.asTransport(),
        source.root(),
        destination.asTransport(),
        destination_reference.selection,
        options.limits,
    );
}

/// Reusable source/destination entry point for later registry pairings.
pub fn planAndCopy(
    allocator: std.mem.Allocator,
    source: transport.Source,
    root: graph.Root,
    destination: transport.Destination,
    selection: ?reference.Selection,
    limits: graph.Limits,
) !transport.Result {
    var plan = try graph.planCopy(allocator, source, root, limits);
    defer plan.deinit();
    return executePlan(&plan, source, destination, selection);
}

/// Executes only a complete plan: dependencies first, the exact root last,
/// then reference publication and destination finalization.
pub fn executePlan(
    plan: *const graph.Plan,
    source: transport.Source,
    destination: transport.Destination,
    selection: ?reference.Selection,
) !transport.Result {
    const root_entry = plan.rootEntry();
    try destination.prepareRoot(root_entry.descriptor, selection);

    var counts: transport.Counts = .{};
    for (plan.dependencyEntries()) |entry| {
        const outcome = try destination.ensureDescriptor(
            entry.transfer(source),
        );
        try counts.record(outcome);
    }

    const publication = plan.rootPublication();
    const root_outcome = try destination.stageRoot(publication);
    try counts.record(root_outcome);
    const commit = try destination.commitRoot(publication, selection);
    try destination.finish();

    const digest = content.Digest.parse(publication.descriptor.digest) catch
        return error.InvalidDigest;
    return .{
        .root = digest,
        .counts = counts,
        .commit = commit,
    };
}

fn descriptorIdentityEqual(
    a: model.Descriptor,
    b: model.Descriptor,
) bool {
    return a.size == b.size and
        std.mem.eql(u8, a.mediaType, b.mediaType) and
        std.mem.eql(u8, a.digest, b.digest);
}

fn verifyExactBytes(
    descriptor: model.Descriptor,
    bytes: []const u8,
) !void {
    const digest = try model.validateDescriptor(descriptor);
    try content.verifyBytes(digest, descriptor.size, bytes);
}

const testing = std.testing;

const RecordingDestination = struct {
    io: std.Io,
    directory: *std.Io.Dir,
    package: *const wasm.PreparedArtifact,
    phase: enum {
        initial,
        prepared,
        root_staged,
        committed,
        finished,
    } = .initial,
    dependency_count: usize = 0,

    pub fn prepareRoot(
        self: *RecordingDestination,
        root: model.Descriptor,
        selection: ?reference.Selection,
    ) !void {
        try testing.expectEqual(.initial, self.phase);
        try testing.expect(descriptorIdentityEqual(
            root,
            self.package.root_descriptor,
        ));
        try testing.expectEqualStrings(
            "generic",
            selection.?.tag,
        );
        self.phase = .prepared;
    }

    pub fn ensureDescriptor(
        self: *RecordingDestination,
        transfer: transport.DescriptorTransfer,
    ) !transport.DescriptorResult {
        try testing.expectEqual(.prepared, self.phase);
        const source = switch (transfer.data) {
            .opaque_blob => |source| source,
            .exact_metadata => return error.UnexpectedMetadataDependency,
        };
        const expected_descriptor, const expected_bytes, const name =
            if (self.dependency_count == 0)
                .{
                    self.package.config_descriptor,
                    self.package.config_bytes,
                    "config",
                }
            else if (self.dependency_count == 1)
                .{
                    self.package.layer_descriptor,
                    self.package.payload_bytes,
                    "layer",
                }
            else
                return error.UnexpectedDependency;
        try testing.expect(descriptorIdentityEqual(
            transfer.descriptor,
            expected_descriptor,
        ));

        var file = try self.directory.createFile(self.io, name, .{
            .exclusive = true,
            .read = true,
        });
        defer file.close(self.io);
        try source.copyVerifiedTo(transfer.descriptor, file);
        try testing.expectEqual(
            transfer.descriptor.size,
            try file.length(self.io),
        );
        const actual = try testing.allocator.alloc(
            u8,
            @intCast(transfer.descriptor.size),
        );
        defer testing.allocator.free(actual);
        try testing.expectEqual(
            actual.len,
            try file.readPositionalAll(self.io, actual, 0),
        );
        try testing.expectEqualSlices(u8, expected_bytes, actual);

        self.dependency_count += 1;
        return .transferred;
    }

    pub fn stageRoot(
        self: *RecordingDestination,
        publication: transport.RootPublication,
    ) !transport.DescriptorResult {
        try testing.expectEqual(.prepared, self.phase);
        try testing.expectEqual(@as(usize, 2), self.dependency_count);
        try testing.expect(descriptorIdentityEqual(
            publication.descriptor,
            self.package.root_descriptor,
        ));
        try testing.expectEqualSlices(
            u8,
            self.package.manifest_bytes,
            publication.exact_bytes,
        );
        self.phase = .root_staged;
        return .transferred;
    }

    pub fn commitRoot(
        self: *RecordingDestination,
        publication: transport.RootPublication,
        selection: ?reference.Selection,
    ) !transport.CommitResult {
        try testing.expectEqual(.root_staged, self.phase);
        try testing.expect(descriptorIdentityEqual(
            publication.descriptor,
            self.package.root_descriptor,
        ));
        try testing.expectEqualStrings("generic", selection.?.tag);
        self.phase = .committed;
        return .published;
    }

    pub fn finish(self: *RecordingDestination) !void {
        try testing.expectEqual(.committed, self.phase);
        self.phase = .finished;
    }
};

test "prepared package uses bounded generic copy and publishes root last" {
    const payload = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x04, 0x03, 0x61, 0x62, 0x63,
    };
    var package = try wasm.prepare(testing.allocator, &payload, .{
        .profile = .oci,
        .created = "2026-09-19T00:00:00Z",
        .source_name = "generic.wasm",
    });
    defer package.deinit();

    var source = PackageSource.init(testing.io, &package);
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var destination: RecordingDestination = .{
        .io = testing.io,
        .directory = &temporary.dir,
        .package = &package,
    };
    const total_bytes = package.root_descriptor.size +
        package.config_descriptor.size +
        package.layer_descriptor.size;
    const limits: graph.Limits = .{
        .max_depth = 1,
        .max_nodes = 3,
        .max_total_bytes = total_bytes,
        .max_metadata_bytes = package.root_descriptor.size,
    };

    const result = try planAndCopy(
        testing.allocator,
        source.asTransport(),
        source.root(),
        transport.Destination.init(&destination),
        .{ .tag = "generic" },
        limits,
    );
    try testing.expectEqual(.finished, destination.phase);
    try testing.expectEqual(@as(u64, 3), result.counts.transferred);
    try testing.expectEqual(@as(u64, 0), result.counts.reused);
    try testing.expectEqual(@as(u64, 0), result.counts.mounted);
    try testing.expectEqual(transport.CommitResult.published, result.commit);
    try testing.expect(
        (try content.Digest.parse(package.root_descriptor.digest)).eql(
            result.root,
        ),
    );

    var bounded_destination: RecordingDestination = .{
        .io = testing.io,
        .directory = &temporary.dir,
        .package = &package,
    };
    var bounded_limits = limits;
    bounded_limits.max_total_bytes -= 1;
    try testing.expectError(
        error.MaximumTotalBytesExceeded,
        planAndCopy(
            testing.allocator,
            source.asTransport(),
            source.root(),
            transport.Destination.init(&bounded_destination),
            .{ .tag = "generic" },
            bounded_limits,
        ),
    );
    try testing.expectEqual(.initial, bounded_destination.phase);
}
