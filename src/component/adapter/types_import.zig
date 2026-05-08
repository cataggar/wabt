//! Hoist the adapter's encoded-world body into the wrapping
//! component's top-level sections.
//!
//! The wasi-preview1 adapter ships its WASI 0.2.6 type tree and
//! every import/export it consumes inside a self-contained
//! `component-type:…:encoded world` payload (see
//! `adapter/decode.zig`). For the splicer to emit a wrapping
//! component that imports the right WASI instances and lifts
//! `wasi:cli/run@<ver>`, every body decl needs to live at the
//! wrapping component's top level.
//!
//! Crucially we *don't* renumber type indices. Inside an instance
//! type body `(alias outer 1 X)` reads the type indexspace of the
//! enclosing component. In the original adapter that enclosing
//! component is the world body. Once we hoist the body decls to
//! the top level of the wrapping component, the wrapping component
//! IS the new enclosing component — and because we hoist it as the
//! FIRST thing we emit, the type indexspace at the relevant depth
//! stays positionally identical to what the body decls expect.
//!
//! Outer aliases inside instance type bodies thus remain valid
//! verbatim; we just need to preserve the original *declaration
//! order* between type defs / imports / alias-exports. That's
//! exactly what `Component.section_order` is for — see
//! `component/writer.zig`.
//!
//! What this module produces:
//!
//!   * Four parallel slices the splicer assigns directly to the
//!     wrapping component (`types`, `imports`, `aliases`, `exports`
//!     — the last is empty unless the adapter exports a
//!     non-instance, which it never does).
//!   * A `section_order` slice that interleaves them in the same
//!     order as the original body decls.
//!   * An `instance_slot_for_import` lookup so the splicer knows
//!     which component-instance index each WASI namespace import
//!     occupies (used when emitting `canon lower`).
//!   * Each export's body type idx (used when emitting `canon
//!     lift` for `wasi:cli/run@<ver>`).
//!
//! All slices are arena-allocated; the caller owns the arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const decode = @import("decode.zig");

pub const Error = error{ OutOfMemory, UnsupportedAdapterShape };

pub const InstanceSlot = struct {
    name: []const u8,
    /// Slot in the wrapping component's component-instance
    /// indexspace.
    instance_idx: u32,
    /// Type idx (in the wrapping component) of this import's
    /// instance type — needed when later emitting an instance
    /// import that references the same type.
    type_idx: u32,
};

pub const ExportInfo = struct {
    name: []const u8,
    type_idx: u32,
};

pub const Hoisted = struct {
    types: []const ctypes.TypeDef,
    imports: []const ctypes.ImportDecl,
    aliases: []const ctypes.Alias,
    section_order: []const ctypes.SectionEntry,
    instances: []const InstanceSlot,
    exports: []const ExportInfo,
    /// Total number of slots in the wrapping component's type
    /// indexspace after hoisting (= the next free type idx). Useful
    /// to the splicer when synthesising additional types after the
    /// hoist (e.g. the canon-lift target).
    type_count: u32,
};

/// Walk an adapter `AdapterWorld`'s body decls and emit four
/// parallel slices + a section-order list mirroring the original
/// declaration order.
pub fn hoist(arena: Allocator, world: decode.AdapterWorld) Error!Hoisted {
    var types = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    var imports = std.ArrayListUnmanaged(ctypes.ImportDecl).empty;
    var aliases = std.ArrayListUnmanaged(ctypes.Alias).empty;
    var entries = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    var instances = std.ArrayListUnmanaged(InstanceSlot).empty;
    var exports_out = std.ArrayListUnmanaged(ExportInfo).empty;

    var type_idx: u32 = 0;
    var inst_idx: u32 = 0;

    // We coalesce contiguous runs of the same kind into a single
    // SectionEntry — multiple same-kind entries are legal but
    // bigger-than-needed.
    var run_kind: ?ctypes.SectionKind = null;
    var run_start: u32 = 0;
    var run_count: u32 = 0;

    const flush = struct {
        fn doFlush(
            ar: Allocator,
            es: *std.ArrayListUnmanaged(ctypes.SectionEntry),
            kind: *?ctypes.SectionKind,
            start: u32,
            count: u32,
        ) Error!void {
            if (kind.* == null or count == 0) return;
            try es.append(ar, .{ .kind = kind.*.?, .start = start, .count = count });
        }
    }.doFlush;

    for (world.body_decls) |d| {
        const kind: ctypes.SectionKind = switch (d) {
            .type, .core_type => .type,
            .import => .import,
            .alias => .alias,
            .@"export" => .@"export",
        };

        // Open or extend a run.
        if (run_kind) |rk| {
            if (rk != kind) {
                try flush(arena, &entries, &run_kind, run_start, run_count);
                run_kind = kind;
                run_start = currentStartFor(kind, &types, &imports, &aliases, &exports_out);
                run_count = 0;
            }
        } else {
            run_kind = kind;
            run_start = currentStartFor(kind, &types, &imports, &aliases, &exports_out);
            run_count = 0;
        }

        // Append the decl into the matching slice.
        switch (d) {
            .type => |td| {
                try types.append(arena, td);
                type_idx += 1;
            },
            .core_type => |ct| {
                // We don't currently have a separate per-decl
                // representation for core types vs component types
                // at the wrapping level. The adapter's encoded
                // world doesn't actually emit core types in the
                // body (it's all component-level), so reject if we
                // ever see one.
                _ = ct;
                return error.UnsupportedAdapterShape;
            },
            .import => |im| {
                try imports.append(arena, im);
                if (im.desc == .instance) {
                    try instances.append(arena, .{
                        .name = im.name,
                        .instance_idx = inst_idx,
                        .type_idx = im.desc.instance,
                    });
                }
                inst_idx += 1;
            },
            .alias => |a| {
                try aliases.append(arena, a);
                const sort: ctypes.Sort = switch (a) {
                    .instance_export => |ie| ie.sort,
                    .outer => |o| o.sort,
                };
                if (sort == .type) type_idx += 1;
            },
            .@"export" => |e| {
                if (e.desc == .instance) {
                    try exports_out.append(arena, .{
                        .name = e.name,
                        .type_idx = e.desc.instance,
                    });
                }
                // The body's `export` decls also create a slot in
                // the wrapping component's exports[] but the splicer
                // typically replaces them with its own export of
                // the lifted instance, so we still emit them for
                // shape parity. (For our supported adapters this is
                // a single `wasi:cli/run@<ver>` entry.)
            },
        }
        run_count += 1;
    }

    try flush(arena, &entries, &run_kind, run_start, run_count);

    return .{
        .types = try types.toOwnedSlice(arena),
        .imports = try imports.toOwnedSlice(arena),
        .aliases = try aliases.toOwnedSlice(arena),
        .section_order = try entries.toOwnedSlice(arena),
        .instances = try instances.toOwnedSlice(arena),
        .exports = try exports_out.toOwnedSlice(arena),
        .type_count = type_idx,
    };
}

fn currentStartFor(
    kind: ctypes.SectionKind,
    types: *const std.ArrayListUnmanaged(ctypes.TypeDef),
    imports: *const std.ArrayListUnmanaged(ctypes.ImportDecl),
    aliases: *const std.ArrayListUnmanaged(ctypes.Alias),
    exports_: *const std.ArrayListUnmanaged(ExportInfo),
) u32 {
    return switch (kind) {
        .type => @intCast(types.items.len),
        .import => @intCast(imports.items.len),
        .alias => @intCast(aliases.items.len),
        .@"export" => @intCast(exports_.items.len),
        else => 0,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const loader = @import("../loader.zig");
const writer = @import("../writer.zig");
const metadata_encode = @import("../wit/metadata_encode.zig");

fn buildMockEncodedWorld(allocator: Allocator) ![]u8 {
    return metadata_encode.encodeWorldFromSource(allocator,
        \\package mock:adapter@0.1.0;
        \\
        \\interface in1 { ping: func() -> u32; }
        \\interface in2 { pong: func() -> u32; }
        \\interface out { run: func() -> u32; }
        \\
        \\world adapter-mock {
        \\    import in1;
        \\    import in2;
        \\    export out;
        \\}
    , "adapter-mock");
}

test "hoist: copies body decls and tracks instance slots" {
    const ct = try buildMockEncodedWorld(testing.allocator);
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);
    const h = try hoist(a, world);

    // 3 instance type defs (in1, in2, out)
    try testing.expectEqual(@as(usize, 3), h.types.len);
    // 2 imports (in1, in2)
    try testing.expectEqual(@as(usize, 2), h.imports.len);
    // 1 export (out) — captured for the canon-lift step
    try testing.expectEqual(@as(usize, 1), h.exports.len);
    try testing.expectEqualStrings("mock:adapter/out@0.1.0", h.exports[0].name);

    // 2 imported instance slots. They sit in the wrapping
    // component's instance indexspace at 0 and 1.
    try testing.expectEqual(@as(usize, 2), h.instances.len);
    try testing.expectEqual(@as(u32, 0), h.instances[0].instance_idx);
    try testing.expectEqual(@as(u32, 1), h.instances[1].instance_idx);
    try testing.expectEqualStrings("mock:adapter/in1@0.1.0", h.instances[0].name);
    try testing.expectEqualStrings("mock:adapter/in2@0.1.0", h.instances[1].name);

    // 3 type defs in the wrapping component's type indexspace.
    try testing.expectEqual(@as(u32, 3), h.type_count);

    // Body order is interleaved per the wit-component encoder:
    //   type, import, type, import, type, export
    // → at minimum 4 alternating runs of (type, import) plus a
    // trailing (type, export) — total 6 SectionEntries when fully
    // run-coalesced. Our coalescer never merges different kinds, so
    // expect exactly 6.
    try testing.expectEqual(@as(usize, 6), h.section_order.len);
    try testing.expectEqual(ctypes.SectionKind.type, h.section_order[0].kind);
    try testing.expectEqual(ctypes.SectionKind.import, h.section_order[1].kind);
    try testing.expectEqual(ctypes.SectionKind.type, h.section_order[2].kind);
    try testing.expectEqual(ctypes.SectionKind.import, h.section_order[3].kind);
    try testing.expectEqual(ctypes.SectionKind.type, h.section_order[4].kind);
    try testing.expectEqual(ctypes.SectionKind.@"export", h.section_order[5].kind);
}

test "hoist: roundtrip — emit the hoisted slices and reload" {
    // Verify the hoisted body forms a structurally valid component
    // when handed to the writer with section_order set. This is the
    // closest hermetic check we have to "the splicer's first phase
    // produces a valid component".
    const ct = try buildMockEncodedWorld(testing.allocator);
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);
    const h = try hoist(a, world);

    // Build the wrapping component using ONLY the hoisted body. The
    // export decls in `h.exports` are kept by the splicer for
    // tracking but not emitted at the top level here — they live
    // inside the world-body encoding only. We don't include them in
    // the round-trip component.
    //
    // Strip the .export entries from section_order before encoding.
    var trimmed = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    for (h.section_order) |se| {
        if (se.kind != .@"export") try trimmed.append(a, se);
    }

    const c = ctypes.Component{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = h.aliases,
        .types = h.types,
        .canons = &.{},
        .imports = h.imports,
        .exports = &.{},
        .section_order = trimmed.items,
    };

    const bytes = try writer.encode(testing.allocator, &c);
    defer testing.allocator.free(bytes);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const decoded = try loader.load(bytes, arena2.allocator());
    try testing.expectEqual(@as(usize, 3), decoded.types.len);
    try testing.expectEqual(@as(usize, 2), decoded.imports.len);
}
