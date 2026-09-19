//! Shared discovery and execution for every OCI source/destination pairing.
const content = @import("content.zig");
const graph = @import("graph.zig");
const layout = @import("layout.zig");
const reference = @import("reference.zig");
const std = @import("std");
const transport = @import("transport.zig");

pub const Options = struct {
    limits: graph.Limits = .{},
    failure_point: layout.FailurePoint = .none,
};

/// Discovers and validates the complete bounded graph before the destination
/// receives its first preflight or transfer operation.
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

/// Executes one complete post-order plan. Dependencies are confirmed before
/// the exact root bytes are staged, and the selected root is committed last.
pub fn executePlan(
    plan: *const graph.Plan,
    source: transport.Source,
    destination: transport.Destination,
    selection: ?reference.Selection,
) !transport.Result {
    const root_entry = plan.rootEntry();
    const root_digest = try content.Digest.parse(root_entry.descriptor.digest);
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

    return .{
        .root = root_digest,
        .counts = counts,
        .commit = commit,
    };
}
