//! Transport-neutral execution of one fully discovered OCI graph plan.
const std = @import("std");
const content = @import("content.zig");
const graph = @import("graph.zig");
const layout = @import("layout.zig");
const reference = @import("reference.zig");
const transport = @import("transport.zig");

pub const Options = struct {
    limits: graph.Limits = .{},
    failure_point: layout.FailurePoint = .none,
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
