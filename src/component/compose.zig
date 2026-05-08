//! Component composition planner — match a consumer component's
//! imports to provider components' exports by name, and produce
//! the resolution table needed by the binary emitter.
//!
//! Adapted from `../wamr/src/component/compose.zig` (Apache-2.0).

const std = @import("std");
const ctypes = @import("types.zig");

/// One resolved import binding.
pub const ImportBinding = struct {
    /// Index of the import on the consumer.
    consumer_import_idx: u32,
    /// Imported name (== `consumer.imports[consumer_import_idx].name`).
    name: []const u8,
    /// Index into the providers slice.
    provider_idx: u32,
    /// Index of the export on the matched provider.
    provider_export_idx: u32,
};

/// Result of planning a composition. Imports listed in `unresolved`
/// must either be left as outer-level imports (default) or rejected
/// outright (caller's choice).
pub const Plan = struct {
    bindings: []const ImportBinding,
    unresolved: []const u32,
};

pub fn plan(
    arena: std.mem.Allocator,
    consumer: *const ctypes.Component,
    providers: []const *const ctypes.Component,
) !Plan {
    var bindings = std.ArrayListUnmanaged(ImportBinding).empty;
    var unresolved = std.ArrayListUnmanaged(u32).empty;

    for (consumer.imports, 0..) |imp, i| {
        var matched = false;
        for (providers, 0..) |prov, p_idx| {
            for (prov.exports, 0..) |exp, e_idx| {
                if (std.mem.eql(u8, imp.name, exp.name)) {
                    try bindings.append(arena, .{
                        .consumer_import_idx = @intCast(i),
                        .name = imp.name,
                        .provider_idx = @intCast(p_idx),
                        .provider_export_idx = @intCast(e_idx),
                    });
                    matched = true;
                    break;
                }
            }
            if (matched) break;
        }
        if (!matched) try unresolved.append(arena, @intCast(i));
    }

    return .{
        .bindings = try bindings.toOwnedSlice(arena),
        .unresolved = try unresolved.toOwnedSlice(arena),
    };
}

const testing = std.testing;

test "plan: resolves matching import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "docs:adder/add@0.1.0", .desc = .{ .instance = 0 } },
    };
    const prov_exports = [_]ctypes.ExportDecl{
        .{ .name = "docs:adder/add@0.1.0", .desc = .{ .instance = 0 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{}, .types = &.{}, .canons = &.{},
        .imports = &cons_imports, .exports = &.{},
    };
    const provider: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{}, .types = &.{}, .canons = &.{},
        .imports = &.{}, .exports = &prov_exports,
    };
    const providers = [_]*const ctypes.Component{&provider};
    const p = try plan(ar, &consumer, &providers);
    try testing.expectEqual(@as(usize, 1), p.bindings.len);
    try testing.expectEqual(@as(usize, 0), p.unresolved.len);
    try testing.expectEqualStrings("docs:adder/add@0.1.0", p.bindings[0].name);
}

test "plan: leaves unmatched imports unresolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:cli/environment@0.2.0", .desc = .{ .instance = 0 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{}, .types = &.{}, .canons = &.{},
        .imports = &cons_imports, .exports = &.{},
    };
    const providers = [_]*const ctypes.Component{};
    const p = try plan(ar, &consumer, &providers);
    try testing.expectEqual(@as(usize, 0), p.bindings.len);
    try testing.expectEqual(@as(usize, 1), p.unresolved.len);
}
