//! Component composition planner — match a consumer component's
//! imports to provider components' exports by name, and produce
//! the resolution table needed by the binary emitter.
//!
//! Adapted from `../wamr/src/component/compose.zig` (Apache-2.0).

const std = @import("std");
const ctypes = @import("types.zig");
const extern_name = @import("extern_name.zig");

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

// ── Version-mismatch conflict detection ─────────────────────────────────────
//
// `wabt component compose` matches consumer↔provider seams by string
// equality (see `plan` above), so when consumer and provider were
// independently built against different patch versions of the same
// `wasi:*` package (typical: consumer built against `@0.2.6`, provider
// built against `@0.2.10`), the seam never matches and both halves'
// extern names leak through to the composed component's outer-import
// surface. Runtimes (wasmtime) apply strict version equality and
// refuse the resulting binary at load time. See issue #209 for the
// concrete repro and the design discussion.
//
// `detectVersionConflicts` scans every outer-level extern name on
// every input (consumer + each provider, both imports and exports)
// and groups them by `(ns, pkg, iface)`. Any group that exhibits more
// than one distinct `@version` is returned as a `Conflict`, ready
// for either a `--align-wasi=...` rewrite pass or a default-mode
// diagnostic. Names without a `@version` suffix or that don't parse
// as `[ns:]pkg/iface[@ver]` are skipped — they can't participate in
// version mismatches.

/// Source location of a versioned extern-name observation.
pub const Source = struct {
    /// 0 ⇒ consumer; 1..providers.len ⇒ providers[source_idx - 1].
    source_idx: u32,
    role: enum { @"import", @"export" },
};

/// One observation of a versioned name.
pub const Occurrence = struct {
    version: []const u8,
    where: Source,
};

/// A single `(ns, pkg, iface)` triple seen at multiple versions.
pub const Conflict = struct {
    ns: []const u8,
    pkg: []const u8,
    iface: []const u8,
    /// All observations, in encounter order. Guaranteed to contain
    /// at least two distinct `version` strings.
    occurrences: []const Occurrence,
};

const SeenKey = struct {
    ns: []const u8,
    pkg: []const u8,
    iface: []const u8,
};

const SeenKeyContext = struct {
    pub fn hash(_: SeenKeyContext, k: SeenKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.ns);
        h.update("\x00");
        h.update(k.pkg);
        h.update("\x00");
        h.update(k.iface);
        return h.final();
    }
    pub fn eql(_: SeenKeyContext, a: SeenKey, b: SeenKey) bool {
        return std.mem.eql(u8, a.ns, b.ns) and
            std.mem.eql(u8, a.pkg, b.pkg) and
            std.mem.eql(u8, a.iface, b.iface);
    }
};

/// Walk the outer-level extern names of `consumer` and each
/// `providers[*]`, return groups whose `(ns, pkg, iface)` triple
/// appears at multiple distinct `@version`s. Each returned
/// `Conflict` carries its full encounter list so callers can render
/// a diagnostic that names each contributing file.
pub fn detectVersionConflicts(
    arena: std.mem.Allocator,
    consumer: *const ctypes.Component,
    providers: []const *const ctypes.Component,
) ![]const Conflict {
    var groups = std.HashMapUnmanaged(
        SeenKey,
        std.ArrayListUnmanaged(Occurrence),
        SeenKeyContext,
        std.hash_map.default_max_load_percentage,
    ).empty;

    const collect = struct {
        fn run(
            ar: std.mem.Allocator,
            map: *std.HashMapUnmanaged(
                SeenKey,
                std.ArrayListUnmanaged(Occurrence),
                SeenKeyContext,
                std.hash_map.default_max_load_percentage,
            ),
            comp: *const ctypes.Component,
            src_idx: u32,
        ) !void {
            for (comp.imports) |imp| {
                try observe(ar, map, imp.name, .{ .source_idx = src_idx, .role = .@"import" });
            }
            for (comp.exports) |exp| {
                try observe(ar, map, exp.name, .{ .source_idx = src_idx, .role = .@"export" });
            }
        }
        fn observe(
            ar: std.mem.Allocator,
            map: *std.HashMapUnmanaged(
                SeenKey,
                std.ArrayListUnmanaged(Occurrence),
                SeenKeyContext,
                std.hash_map.default_max_load_percentage,
            ),
            name: []const u8,
            where: Source,
        ) !void {
            const parts = extern_name.parse(name) orelse return;
            const ver = parts.version orelse return;
            const key: SeenKey = .{ .ns = parts.ns, .pkg = parts.pkg, .iface = parts.iface };
            const gop = try map.getOrPut(ar, key);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayListUnmanaged(Occurrence).empty;
            try gop.value_ptr.append(ar, .{ .version = ver, .where = where });
        }
    };

    try collect.run(arena, &groups, consumer, 0);
    for (providers, 0..) |p, i| {
        try collect.run(arena, &groups, p, @intCast(i + 1));
    }

    var conflicts = std.ArrayListUnmanaged(Conflict).empty;
    var it = groups.iterator();
    while (it.next()) |entry| {
        const occs = entry.value_ptr.items;
        if (occs.len < 2) continue;
        var multi_version = false;
        for (occs[1..]) |o| {
            if (!std.mem.eql(u8, o.version, occs[0].version)) {
                multi_version = true;
                break;
            }
        }
        if (!multi_version) continue;
        try conflicts.append(arena, .{
            .ns = entry.key_ptr.ns,
            .pkg = entry.key_ptr.pkg,
            .iface = entry.key_ptr.iface,
            .occurrences = occs,
        });
    }

    // Deterministic order so diagnostics + tests are stable.
    std.mem.sort(Conflict, conflicts.items, {}, struct {
        fn lt(_: void, a: Conflict, b: Conflict) bool {
            const c1 = std.mem.order(u8, a.ns, b.ns);
            if (c1 != .eq) return c1 == .lt;
            const c2 = std.mem.order(u8, a.pkg, b.pkg);
            if (c2 != .eq) return c2 == .lt;
            return std.mem.order(u8, a.iface, b.iface) == .lt;
        }
    }.lt);

    return conflicts.toOwnedSlice(arena);
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

test "detectVersionConflicts: reports same iface at two patch versions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.6", .desc = .{ .instance = 0 } },
        .{ .name = "wasi:io/streams@0.2.6", .desc = .{ .instance = 0 } },
    };
    const prov_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } },
    };
    const prov_exports = [_]ctypes.ExportDecl{
        .{ .name = "wasi:io/streams@0.2.10", .desc = .{ .instance = 0 } },
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
        .imports = &prov_imports, .exports = &prov_exports,
    };
    const providers = [_]*const ctypes.Component{&provider};
    const conflicts = try detectVersionConflicts(ar, &consumer, &providers);

    try testing.expectEqual(@as(usize, 2), conflicts.len);
    try testing.expectEqualStrings("wasi", conflicts[0].ns);
    try testing.expectEqualStrings("io", conflicts[0].pkg);
    try testing.expectEqualStrings("error", conflicts[0].iface);
    try testing.expectEqual(@as(usize, 2), conflicts[0].occurrences.len);
    try testing.expectEqualStrings("io", conflicts[1].pkg);
    try testing.expectEqualStrings("streams", conflicts[1].iface);

    var saw_6: bool = false;
    var saw_10: bool = false;
    for (conflicts[0].occurrences) |o| {
        if (std.mem.eql(u8, o.version, "0.2.6")) saw_6 = true;
        if (std.mem.eql(u8, o.version, "0.2.10")) saw_10 = true;
    }
    try testing.expect(saw_6 and saw_10);
}

test "detectVersionConflicts: same version everywhere is not a conflict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.6", .desc = .{ .instance = 0 } },
    };
    const prov_exports = [_]ctypes.ExportDecl{
        .{ .name = "wasi:io/error@0.2.6", .desc = .{ .instance = 0 } },
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
    const conflicts = try detectVersionConflicts(ar, &consumer, &providers);
    try testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "detectVersionConflicts: unversioned names are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error", .desc = .{ .instance = 0 } },
        .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{}, .types = &.{}, .canons = &.{},
        .imports = &cons_imports, .exports = &.{},
    };
    const providers = [_]*const ctypes.Component{};
    const conflicts = try detectVersionConflicts(ar, &consumer, &providers);
    try testing.expectEqual(@as(usize, 0), conflicts.len);
}

test "detectVersionConflicts: records source index + role for each occurrence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.6", .desc = .{ .instance = 0 } },
    };
    const prov_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } },
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
        .imports = &prov_imports, .exports = &.{},
    };
    const providers = [_]*const ctypes.Component{&provider};
    const conflicts = try detectVersionConflicts(ar, &consumer, &providers);

    try testing.expectEqual(@as(usize, 1), conflicts.len);
    var saw_consumer = false;
    var saw_provider = false;
    for (conflicts[0].occurrences) |o| {
        if (o.where.source_idx == 0 and o.where.role == .@"import") saw_consumer = true;
        if (o.where.source_idx == 1 and o.where.role == .@"import") saw_provider = true;
    }
    try testing.expect(saw_consumer);
    try testing.expect(saw_provider);
}
