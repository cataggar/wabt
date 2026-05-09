//! Encoded-world AST garbage collection for adapter splicing.
//!
//! Companion to `gc.zig` (which GC's the adapter's core wasm). This
//! module GC's the adapter's `:encoded world` payload — the component
//! AST inside the `component-type:…:encoded world` custom section.
//!
//! Why this needs its own pass: the encoded world references
//! component-instances by absolute index. The wasi-preview1 adapter
//! type-declares ~25 WASI namespaces in a fixed order; if the embed
//! only uses a few, the rest still leak as top-level imports of the
//! wrapping component (because `types_import.hoist` deliberately
//! doesn't renumber — see its module header). Naive import filtering
//! is unsafe: dropping a body-level import shifts every subsequent
//! instance index and breaks every `(alias outer 1 N)` that points
//! at a dropped or shifted slot.
//!
//! What this module does:
//!
//!   1. Walk the body decls to compute, for each decl, the type /
//!      instance slot it produces and the type / instance idxs it
//!      references (including outer-alias `idx` operands inside
//!      depth-1 instance-type bodies, which read the world body's
//!      type indexspace).
//!   2. Seed liveness from the live namespace set (imports whose
//!      `name` matches) and the live export name set (typically
//!      `wasi:cli/run@<ver>`); transitively close to fixed point.
//!   3. Build per-indexspace remap tables (type_old→new,
//!      inst_old→new) for the surviving subset.
//!   4. Deep-clone surviving body decls with operands rewritten via
//!      the remaps. Outer-alias `idx` operands inside depth-1 type
//!      bodies are rewritten via the world-body type remap, so
//!      hoisting the GC'd body to the top of the wrapping component
//!      keeps every nested outer alias valid.
//!   5. Rebuild the encoded-world wrapper component (preserving the
//!      shape `decode.parse` expects), encode via `writer.encode`,
//!      and re-parse via `decode.parse` so the returned `AdapterWorld`
//!      is structurally consistent and ready to feed into
//!      `types_import.hoist` verbatim.
//!
//! Out of scope:
//!
//!   * Component-type bodies inside the world body (the wasi-preview1
//!     adapter doesn't use them) — rejected with
//!     `error.UnsupportedAdapterShape`.
//!   * Adapters whose body uses non-instance imports (also unused by
//!     the v36.0.9 adapter). Type/func/value/component imports would
//!     contribute to other indexspaces; we follow `decode.zig`'s
//!     simplification and treat every import as an instance-import
//!     for indexspace bookkeeping.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const decode = @import("decode.zig");
const loader = @import("../loader.zig");
const writer = @import("../writer.zig");
const leb128 = @import("../../leb128.zig");

pub const Error = error{
    OutOfMemory,
    UnsupportedAdapterShape,
    ValueTooLarge,
    InvalidAdapterCore,
    MissingEncodedWorld,
} || loader.LoadError;

const SENTINEL: u32 = std.math.maxInt(u32);

pub const Result = struct {
    /// Pruned `AdapterWorld` ready to feed into `types_import.hoist`.
    world: decode.AdapterWorld,
    /// Encoded payload bytes for the rebuilt `:encoded world` custom
    /// section. Owned by the caller's arena.
    payload_bytes: []const u8,
};

/// GC the world.
///
/// `live_namespaces` is the set of import names that must survive
/// (e.g. `wasi:cli/environment@0.2.6`) — usually computed from the
/// GC'd adapter core wasm's actual `module_name`s.
///
/// `live_export_names` is the set of body-level export names that
/// must survive (e.g. `wasi:cli/run@0.2.6`). For the wasi-preview1
/// command adapter this is exactly one entry.
///
/// Names not present in the world are silently ignored — the caller
/// (the splicer) computes both sets from runtime data and the world
/// may have shifted between adapter versions.
pub fn gcWorld(
    arena: Allocator,
    world: decode.AdapterWorld,
    live_namespaces: []const []const u8,
    live_export_names: []const []const u8,
) Error!Result {
    // ── Step 1: per-decl metadata pre-pass ────────────────────────────────
    const meta = try buildDeclMeta(arena, world.body_decls);

    // ── Step 2: liveness ──────────────────────────────────────────────────
    var live_decls = try std.DynamicBitSetUnmanaged.initEmpty(arena, world.body_decls.len);
    var live_types = try std.DynamicBitSetUnmanaged.initEmpty(arena, world.body_type_count);
    // Instance count: number of imports (matching decode's bookkeeping).
    var inst_count: u32 = 0;
    for (world.body_decls) |d| if (d == .import) {
        inst_count += 1;
    };
    var live_inst = try std.DynamicBitSetUnmanaged.initEmpty(arena, inst_count);

    // Seed: imports/exports matching the live name sets.
    for (world.body_decls, 0..) |d, i| {
        switch (d) {
            .import => |im| {
                if (containsName(live_namespaces, im.name)) live_decls.set(i);
            },
            .@"export" => |e| {
                if (containsName(live_export_names, e.name)) live_decls.set(i);
            },
            else => {},
        }
    }

    // Fixed-point: any live decl marks its type/instance refs live;
    // any live type/instance idx marks the decl that produces it
    // live; that in turn pulls more refs. Iterate until stable.
    var changed = true;
    while (changed) {
        changed = false;

        // Propagate refs of live decls.
        for (world.body_decls, 0..) |_, i| {
            if (!live_decls.isSet(i)) continue;
            for (meta[i].type_refs) |t| {
                if (t < live_types.bit_length and !live_types.isSet(t)) {
                    live_types.set(t);
                    changed = true;
                }
            }
            for (meta[i].inst_refs) |s| {
                if (s < live_inst.bit_length and !live_inst.isSet(s)) {
                    live_inst.set(s);
                    changed = true;
                }
            }
        }

        // Live indexspace slots → mark the producing decl live.
        for (world.body_decls, 0..) |_, i| {
            if (live_decls.isSet(i)) continue;
            const m = meta[i];
            const become_live = blk: {
                if (m.type_slot) |t| if (t < live_types.bit_length and live_types.isSet(t)) break :blk true;
                if (m.inst_slot) |s| if (s < live_inst.bit_length and live_inst.isSet(s)) break :blk true;
                break :blk false;
            };
            if (become_live) {
                live_decls.set(i);
                changed = true;
            }
        }
    }

    // ── Step 3: per-indexspace remaps ─────────────────────────────────────
    var type_remap = try arena.alloc(u32, world.body_type_count);
    @memset(type_remap, SENTINEL);
    var inst_remap = try arena.alloc(u32, inst_count);
    @memset(inst_remap, SENTINEL);

    var new_type_cursor: u32 = 0;
    var new_inst_cursor: u32 = 0;
    for (world.body_decls, 0..) |_, i| {
        if (!live_decls.isSet(i)) continue;
        const m = meta[i];
        if (m.type_slot) |t| {
            type_remap[t] = new_type_cursor;
            new_type_cursor += 1;
        }
        if (m.inst_slot) |s| {
            inst_remap[s] = new_inst_cursor;
            new_inst_cursor += 1;
        }
    }

    // ── Step 4: deep-clone surviving decls with rewritten operands ────────
    var new_decls = std.ArrayListUnmanaged(ctypes.Decl).empty;
    for (world.body_decls, 0..) |d, i| {
        if (!live_decls.isSet(i)) continue;
        const cloned = try cloneDecl(arena, d, type_remap, inst_remap);
        try new_decls.append(arena, cloned);
    }
    const new_body_decls = try new_decls.toOwnedSlice(arena);

    // ── Step 5: rebuild outer wrapper Component, encode, re-parse ─────────
    const payload_bytes = try buildAndEncodePayload(arena, world, new_body_decls);
    const new_world = try decode.parse(arena, payload_bytes);

    return .{ .world = new_world, .payload_bytes = payload_bytes };
}

// ── Per-decl metadata pre-pass ─────────────────────────────────────────────

const DeclMeta = struct {
    type_slot: ?u32 = null,
    inst_slot: ?u32 = null,
    type_refs: []const u32 = &.{},
    inst_refs: []const u32 = &.{},
};

fn buildDeclMeta(arena: Allocator, decls: []const ctypes.Decl) Error![]const DeclMeta {
    const out = try arena.alloc(DeclMeta, decls.len);
    var type_cursor: u32 = 0;
    var inst_cursor: u32 = 0;

    for (decls, 0..) |d, i| {
        var trefs = std.ArrayListUnmanaged(u32).empty;
        var srefs = std.ArrayListUnmanaged(u32).empty;
        var type_slot: ?u32 = null;
        var inst_slot: ?u32 = null;

        switch (d) {
            .core_type => return error.UnsupportedAdapterShape,
            .type => |td| {
                type_slot = type_cursor;
                type_cursor += 1;
                try collectTypeDefRefs(arena, td, &trefs, 0);
            },
            .alias => |a| {
                switch (a) {
                    .instance_export => |ie| {
                        // Pull `instance_export` of any sort from a
                        // body-level instance. Only sort=type
                        // contributes a slot to the type indexspace;
                        // other sorts are unusual at world body
                        // level. The instance idx is referenced
                        // either way.
                        if (ie.sort == .type) {
                            type_slot = type_cursor;
                            type_cursor += 1;
                        }
                        try srefs.append(arena, ie.instance_idx);
                    },
                    .outer => |o| {
                        if (o.sort == .type) {
                            type_slot = type_cursor;
                            type_cursor += 1;
                        }
                        // outer-alias at body depth-0 references the
                        // wrapper's indexspace (boilerplate scope).
                        // Body-level types aren't referenced; nothing
                        // to add to trefs.
                    },
                }
            },
            .import => |im| {
                inst_slot = inst_cursor;
                inst_cursor += 1;
                try collectExternDescRefs(arena, im.desc, &trefs);
            },
            .@"export" => |e| {
                try collectExternDescRefs(arena, e.desc, &trefs);
            },
        }

        out[i] = .{
            .type_slot = type_slot,
            .inst_slot = inst_slot,
            .type_refs = try trefs.toOwnedSlice(arena),
            .inst_refs = try srefs.toOwnedSlice(arena),
        };
    }

    return out;
}

/// Collect type-idx refs from a type def. `depth` is the nesting
/// depth — 0 for the world body, 1 inside an instance type body, etc.
/// Refs with `outer_count == depth` and sort=type bubble up to the
/// world body's type indexspace and are added to `out`. Refs to local
/// (same-depth) types stay local and are ignored at body level.
fn collectTypeDefRefs(
    arena: Allocator,
    td: ctypes.TypeDef,
    out: *std.ArrayListUnmanaged(u32),
    depth: u32,
) Error!void {
    switch (td) {
        .val => |vt| try collectValTypeRefs(arena, vt, out, depth),
        .record => |r| for (r.fields) |f| try collectValTypeRefs(arena, f.type, out, depth),
        .variant => |v| for (v.cases) |c| {
            if (c.type) |vt| try collectValTypeRefs(arena, vt, out, depth);
        },
        .list => |l| try collectValTypeRefs(arena, l.element, out, depth),
        .tuple => |t| for (t.fields) |f| try collectValTypeRefs(arena, f, out, depth),
        .flags, .enum_ => {},
        .option => |o| try collectValTypeRefs(arena, o.inner, out, depth),
        .result => |r| {
            if (r.ok) |vt| try collectValTypeRefs(arena, vt, out, depth);
            if (r.err) |vt| try collectValTypeRefs(arena, vt, out, depth);
        },
        .resource => {},
        .func => |f| {
            for (f.params) |p| try collectValTypeRefs(arena, p.type, out, depth);
            switch (f.results) {
                .none => {},
                .unnamed => |vt| try collectValTypeRefs(arena, vt, out, depth),
                .named => |list| for (list) |nv| try collectValTypeRefs(arena, nv.type, out, depth),
            }
        },
        .component => return error.UnsupportedAdapterShape,
        .instance => |i| try collectInstanceBodyRefs(arena, i.decls, out, depth + 1),
    }
}

/// Collect type-idx refs from valtype operands. ValTypes at depth>0
/// reference the local type indexspace at THAT depth — not the world
/// body's. So they don't contribute body-level refs.
fn collectValTypeRefs(
    arena: Allocator,
    vt: ctypes.ValType,
    out: *std.ArrayListUnmanaged(u32),
    depth: u32,
) Error!void {
    if (depth != 0) return; // local-typespace refs at depth>0 are local
    switch (vt) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .string => {},
        .own => |idx| try out.append(arena, idx),
        .borrow => |idx| try out.append(arena, idx),
        .type_idx => |idx| try out.append(arena, idx),
        .record => |idx| try out.append(arena, idx),
        .variant => |idx| try out.append(arena, idx),
        .list => |idx| try out.append(arena, idx),
        .tuple => |idx| try out.append(arena, idx),
        .flags => |idx| try out.append(arena, idx),
        .enum_ => |idx| try out.append(arena, idx),
        .option => |idx| try out.append(arena, idx),
        .result => |idx| try out.append(arena, idx),
    }
}

fn collectInstanceBodyRefs(
    arena: Allocator,
    decls: []const ctypes.Decl,
    out: *std.ArrayListUnmanaged(u32),
    depth: u32,
) Error!void {
    for (decls) |d| {
        switch (d) {
            .core_type => {},
            .type => |td| try collectTypeDefRefs(arena, td, out, depth),
            .alias => |a| switch (a) {
                .instance_export => {},
                .outer => |o| {
                    // Outer-alias whose chain reaches depth 0 (the
                    // world body) — its `idx` reads the world body's
                    // type indexspace.
                    if (o.outer_count == depth and o.sort == .type) {
                        try out.append(arena, o.idx);
                    }
                },
            },
            .import => |im| {
                // Imports inside an instance type are unusual; instance
                // bodies normally only have type defs, aliases, and
                // exports. Treat opaquely (still walk the desc).
                try collectExternDescRefsAtDepth(arena, im.desc, out, depth);
            },
            .@"export" => |e| try collectExternDescRefsAtDepth(arena, e.desc, out, depth),
        }
    }
}

fn collectExternDescRefs(
    arena: Allocator,
    desc: ctypes.ExternDesc,
    out: *std.ArrayListUnmanaged(u32),
) Error!void {
    return collectExternDescRefsAtDepth(arena, desc, out, 0);
}

fn collectExternDescRefsAtDepth(
    arena: Allocator,
    desc: ctypes.ExternDesc,
    out: *std.ArrayListUnmanaged(u32),
    depth: u32,
) Error!void {
    if (depth != 0) return; // descs at depth>0 reference local typespace
    switch (desc) {
        .module => {},
        .func => |idx| try out.append(arena, idx),
        .value => |vt| try collectValTypeRefs(arena, vt, out, 0),
        .type => |tb| switch (tb) {
            .eq => |idx| try out.append(arena, idx),
            .sub_resource => {},
        },
        .component => |idx| try out.append(arena, idx),
        .instance => |idx| try out.append(arena, idx),
    }
}

// ── Clone with operand renumbering ─────────────────────────────────────────

fn cloneDecl(
    arena: Allocator,
    d: ctypes.Decl,
    type_remap: []const u32,
    inst_remap: []const u32,
) Error!ctypes.Decl {
    return switch (d) {
        .core_type => error.UnsupportedAdapterShape,
        .type => |td| .{ .type = try cloneTypeDef(arena, td, type_remap, 0) },
        .alias => |a| .{ .alias = try cloneAlias(arena, a, type_remap, inst_remap) },
        .import => |im| .{ .import = .{
            .name = try arena.dupe(u8, im.name),
            .desc = try cloneExternDesc(arena, im.desc, type_remap, 0),
        } },
        .@"export" => |e| .{ .@"export" = .{
            .name = try arena.dupe(u8, e.name),
            .desc = try cloneExternDesc(arena, e.desc, type_remap, 0),
            .sort_idx = e.sort_idx,
        } },
    };
}

fn cloneAlias(
    arena: Allocator,
    a: ctypes.Alias,
    type_remap: []const u32,
    inst_remap: []const u32,
) Error!ctypes.Alias {
    _ = type_remap;
    return switch (a) {
        .instance_export => |ie| .{ .instance_export = .{
            .sort = ie.sort,
            .instance_idx = remap(inst_remap, ie.instance_idx),
            .name = try arena.dupe(u8, ie.name),
        } },
        .outer => |o| .{ .outer = .{
            .sort = o.sort,
            .outer_count = o.outer_count,
            // depth-0 outer alias references wrapper type indexspace
            // (boilerplate, idx 0); leave verbatim.
            .idx = o.idx,
        } },
    };
}

fn cloneTypeDef(
    arena: Allocator,
    td: ctypes.TypeDef,
    type_remap: []const u32,
    depth: u32,
) Error!ctypes.TypeDef {
    return switch (td) {
        .val => |vt| .{ .val = try cloneValType(arena, vt, type_remap, depth) },
        .record => |r| blk: {
            const fields = try arena.alloc(ctypes.Field, r.fields.len);
            for (r.fields, fields) |src, *dst| {
                dst.* = .{
                    .name = try arena.dupe(u8, src.name),
                    .type = try cloneValType(arena, src.type, type_remap, depth),
                };
            }
            break :blk .{ .record = .{ .fields = fields } };
        },
        .variant => |v| blk: {
            const cases = try arena.alloc(ctypes.Case, v.cases.len);
            for (v.cases, cases) |src, *dst| {
                dst.* = .{
                    .name = try arena.dupe(u8, src.name),
                    .type = if (src.type) |t| try cloneValType(arena, t, type_remap, depth) else null,
                    .refines = src.refines,
                };
            }
            break :blk .{ .variant = .{ .cases = cases } };
        },
        .list => |l| .{ .list = .{ .element = try cloneValType(arena, l.element, type_remap, depth) } },
        .tuple => |t| blk: {
            const fields = try arena.alloc(ctypes.ValType, t.fields.len);
            for (t.fields, fields) |src, *dst| dst.* = try cloneValType(arena, src, type_remap, depth);
            break :blk .{ .tuple = .{ .fields = fields } };
        },
        .flags => |f| blk: {
            const names = try arena.alloc([]const u8, f.names.len);
            for (f.names, names) |src, *dst| dst.* = try arena.dupe(u8, src);
            break :blk .{ .flags = .{ .names = names } };
        },
        .enum_ => |e| blk: {
            const names = try arena.alloc([]const u8, e.names.len);
            for (e.names, names) |src, *dst| dst.* = try arena.dupe(u8, src);
            break :blk .{ .enum_ = .{ .names = names } };
        },
        .option => |o| .{ .option = .{ .inner = try cloneValType(arena, o.inner, type_remap, depth) } },
        .result => |r| .{ .result = .{
            .ok = if (r.ok) |t| try cloneValType(arena, t, type_remap, depth) else null,
            .err = if (r.err) |t| try cloneValType(arena, t, type_remap, depth) else null,
        } },
        .resource => |r| .{ .resource = r },
        .func => |f| blk: {
            const params = try arena.alloc(ctypes.NamedValType, f.params.len);
            for (f.params, params) |src, *dst| dst.* = .{
                .name = try arena.dupe(u8, src.name),
                .type = try cloneValType(arena, src.type, type_remap, depth),
            };
            const results: ctypes.FuncType.ResultList = switch (f.results) {
                .none => .none,
                .unnamed => |vt| .{ .unnamed = try cloneValType(arena, vt, type_remap, depth) },
                .named => |list| named: {
                    const dst = try arena.alloc(ctypes.NamedValType, list.len);
                    for (list, dst) |src, *d| d.* = .{
                        .name = try arena.dupe(u8, src.name),
                        .type = try cloneValType(arena, src.type, type_remap, depth),
                    };
                    break :named .{ .named = dst };
                },
            };
            break :blk .{ .func = .{ .params = params, .results = results } };
        },
        .component => return error.UnsupportedAdapterShape,
        .instance => |i| .{ .instance = .{ .decls = try cloneInstanceBody(arena, i.decls, type_remap, depth + 1) } },
    };
}

fn cloneInstanceBody(
    arena: Allocator,
    decls: []const ctypes.Decl,
    type_remap: []const u32,
    depth: u32,
) Error![]const ctypes.Decl {
    const out = try arena.alloc(ctypes.Decl, decls.len);
    for (decls, out) |src, *dst| {
        dst.* = switch (src) {
            .core_type => return error.UnsupportedAdapterShape,
            .type => |td| .{ .type = try cloneTypeDef(arena, td, type_remap, depth) },
            .alias => |a| .{ .alias = try cloneInstanceBodyAlias(arena, a, type_remap, depth) },
            .import => |im| .{ .import = .{
                .name = try arena.dupe(u8, im.name),
                .desc = try cloneExternDesc(arena, im.desc, type_remap, depth),
            } },
            .@"export" => |e| .{ .@"export" = .{
                .name = try arena.dupe(u8, e.name),
                .desc = try cloneExternDesc(arena, e.desc, type_remap, depth),
                .sort_idx = e.sort_idx,
            } },
        };
    }
    return out;
}

/// Clone an alias inside an instance type body. Outer aliases whose
/// chain reaches the world body (`outer_count == depth`) have their
/// `idx` rewritten through `type_remap` so the alias target survives
/// the prune.
fn cloneInstanceBodyAlias(
    arena: Allocator,
    a: ctypes.Alias,
    type_remap: []const u32,
    depth: u32,
) Error!ctypes.Alias {
    return switch (a) {
        .instance_export => |ie| .{ .instance_export = .{
            .sort = ie.sort,
            .instance_idx = ie.instance_idx,
            .name = try arena.dupe(u8, ie.name),
        } },
        .outer => |o| blk: {
            const new_idx = if (o.outer_count == depth and o.sort == .type)
                remap(type_remap, o.idx)
            else
                o.idx;
            break :blk .{ .outer = .{
                .sort = o.sort,
                .outer_count = o.outer_count,
                .idx = new_idx,
            } };
        },
    };
}

fn cloneExternDesc(
    arena: Allocator,
    desc: ctypes.ExternDesc,
    type_remap: []const u32,
    depth: u32,
) Error!ctypes.ExternDesc {
    return switch (desc) {
        .module => |idx| .{ .module = idx },
        .func => |idx| .{ .func = if (depth == 0) remap(type_remap, idx) else idx },
        .value => |vt| .{ .value = try cloneValType(arena, vt, type_remap, depth) },
        .type => |tb| .{ .type = switch (tb) {
            .eq => |idx| .{ .eq = if (depth == 0) remap(type_remap, idx) else idx },
            .sub_resource => .sub_resource,
        } },
        .component => |idx| .{ .component = if (depth == 0) remap(type_remap, idx) else idx },
        .instance => |idx| .{ .instance = if (depth == 0) remap(type_remap, idx) else idx },
    };
}

fn cloneValType(
    arena: Allocator,
    vt: ctypes.ValType,
    type_remap: []const u32,
    depth: u32,
) Error!ctypes.ValType {
    _ = arena;
    if (depth != 0) return vt; // local-typespace refs at depth>0 unchanged
    return switch (vt) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .string => vt,
        .own => |idx| .{ .own = remap(type_remap, idx) },
        .borrow => |idx| .{ .borrow = remap(type_remap, idx) },
        .type_idx => |idx| .{ .type_idx = remap(type_remap, idx) },
        .record => |idx| .{ .record = remap(type_remap, idx) },
        .variant => |idx| .{ .variant = remap(type_remap, idx) },
        .list => |idx| .{ .list = remap(type_remap, idx) },
        .tuple => |idx| .{ .tuple = remap(type_remap, idx) },
        .flags => |idx| .{ .flags = remap(type_remap, idx) },
        .enum_ => |idx| .{ .enum_ = remap(type_remap, idx) },
        .option => |idx| .{ .option = remap(type_remap, idx) },
        .result => |idx| .{ .result = remap(type_remap, idx) },
    };
}

fn remap(table: []const u32, idx: u32) u32 {
    if (idx >= table.len) return idx;
    return table[idx];
}

// ── Encode the rebuilt encoded-world payload ──────────────────────────────

fn buildAndEncodePayload(
    arena: Allocator,
    src_world: decode.AdapterWorld,
    new_body_decls: []const ctypes.Decl,
) Error![]const u8 {
    // Outer wrapper: component-type whose decl[0] is the world body
    // and decl[1] re-exports the body component under the world's
    // qualified name. Mirrors `metadata_encode.encodeWorldFromResolver`.
    const outer_decls = try arena.alloc(ctypes.Decl, 2);
    outer_decls[0] = .{ .type = .{ .component = .{ .decls = new_body_decls } } };
    outer_decls[1] = .{ .@"export" = .{
        .name = try arena.dupe(u8, src_world.world_qualified_name),
        .desc = .{ .component = 0 },
    } };

    const types = try arena.alloc(ctypes.TypeDef, 1);
    types[0] = .{ .component = .{ .decls = outer_decls } };

    // Top-level world-name export. Reuse the original short name from
    // `src_world.component.exports[0]` — this is the unqualified
    // world name (e.g. `command`), not the wire-form qualified name.
    if (src_world.component.exports.len < 1) return error.UnsupportedAdapterShape;
    const orig_export = src_world.component.exports[0];
    const exports = try arena.alloc(ctypes.ExportDecl, 1);
    exports[0] = .{
        .name = try arena.dupe(u8, orig_export.name),
        .desc = .{ .type = .{ .eq = 0 } },
        .sort_idx = .{ .sort = .type, .idx = 0 },
    };

    // Standard wit-component-encoding marker (loader drops custom
    // sections, so we always re-emit the canonical `0x04 0x00`).
    const custom_sections = try arena.alloc(ctypes.CustomSection, 1);
    custom_sections[0] = .{
        .name = "wit-component-encoding",
        .payload = &[_]u8{ 0x04, 0x00 },
    };

    const component: ctypes.Component = .{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = types,
        .canons = &.{},
        .imports = &.{},
        .exports = exports,
        .custom_sections = custom_sections,
    };
    return writer.encode(arena, &component);
}

// ── Replace `:encoded world` custom section in adapter core wasm ──────────

/// Splice `new_payload` into `adapter_core_bytes` in place of the
/// existing `:encoded world` custom section. All other sections are
/// preserved byte-identically.
pub fn replaceEncodedWorldSection(
    arena: Allocator,
    adapter_core_bytes: []const u8,
    new_payload: []const u8,
) Error![]u8 {
    if (adapter_core_bytes.len < 8) return error.InvalidAdapterCore;
    if (!std.mem.eql(u8, adapter_core_bytes[0..4], "\x00asm")) return error.InvalidAdapterCore;

    var out = std.ArrayListUnmanaged(u8).empty;
    try out.appendSlice(arena, adapter_core_bytes[0..8]);

    var found = false;
    var i: usize = 8;
    while (i < adapter_core_bytes.len) {
        const id = adapter_core_bytes[i];
        i += 1;
        const sz = try readU32Leb(adapter_core_bytes, i);
        i += sz.bytes_read;
        if (i + sz.value > adapter_core_bytes.len) return error.InvalidAdapterCore;
        const body = adapter_core_bytes[i .. i + sz.value];
        i += sz.value;

        const is_encoded_world = blk: {
            if (id != 0 or body.len == 0) break :blk false;
            const n = readU32Leb(body, 0) catch break :blk false;
            if (n.bytes_read + n.value > body.len) break :blk false;
            const sec_name = body[n.bytes_read .. n.bytes_read + n.value];
            const suffix = ":encoded world";
            const prefix = "component-type:";
            const matches_suffix = sec_name.len >= suffix.len and
                std.mem.eql(u8, sec_name[sec_name.len - suffix.len ..], suffix) and
                std.mem.startsWith(u8, sec_name, prefix);
            const is_bare = std.mem.eql(u8, sec_name, "component-type");
            break :blk matches_suffix or is_bare;
        };

        if (is_encoded_world) {
            if (found) return error.UnsupportedAdapterShape; // duplicate
            found = true;
            // Reuse the original section name; replace only the payload.
            const n = try readU32Leb(body, 0);
            const sec_name_with_len = body[0 .. n.bytes_read + n.value];
            const new_body_len = sec_name_with_len.len + new_payload.len;
            try out.append(arena, 0); // custom section id
            try writeU32Leb(arena, &out, @intCast(new_body_len));
            try out.appendSlice(arena, sec_name_with_len);
            try out.appendSlice(arena, new_payload);
        } else {
            try out.append(arena, id);
            try writeU32Leb(arena, &out, sz.value);
            try out.appendSlice(arena, body);
        }
    }

    if (!found) return error.MissingEncodedWorld;
    return out.toOwnedSlice(arena);
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn containsName(set: []const []const u8, name: []const u8) bool {
    for (set) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const LebRead = struct { value: u32, bytes_read: usize };

fn readU32Leb(buf: []const u8, start: usize) Error!LebRead {
    var result: u32 = 0;
    var shift: u5 = 0;
    var i: usize = start;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        result |= @as(u32, b & 0x7f) << shift;
        if ((b & 0x80) == 0) {
            return .{ .value = result, .bytes_read = i + 1 - start };
        }
        if (shift >= 25) return error.InvalidAdapterCore;
        shift += 7;
    }
    return error.InvalidAdapterCore;
}

fn writeU32Leb(arena: Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) Error!void {
    var x = v;
    while (true) {
        var byte: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) byte |= 0x80;
        try out.append(arena, byte);
        if (x == 0) break;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const metadata_encode = @import("../wit/metadata_encode.zig");

fn buildMockEncodedWorld(allocator: Allocator, source: []const u8, world_name: []const u8) ![]u8 {
    return metadata_encode.encodeWorldFromSource(allocator, source, world_name);
}

const std_world =
    \\package mock:adapter@0.1.0;
    \\
    \\interface in1 { ping: func() -> u32; }
    \\interface in2 { pong: func() -> u32; }
    \\interface in3 { peng: func() -> u32; }
    \\interface out { run: func() -> u32; }
    \\
    \\world adapter-mock {
    \\    import in1;
    \\    import in2;
    \\    import in3;
    \\    export out;
    \\}
;

test "gcWorld: drops unused imports, keeps live ones" {
    const ct = try buildMockEncodedWorld(testing.allocator, std_world, "adapter-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);

    // Keep in2 only (drop in1, in3).
    const live_ns: []const []const u8 = &.{"mock:adapter/in2@0.1.0"};
    const live_ex: []const []const u8 = &.{"mock:adapter/out@0.1.0"};

    const result = try gcWorld(a, world, live_ns, live_ex);

    // Imports: only in2 should remain.
    try testing.expectEqual(@as(usize, 1), result.world.imports.len);
    try testing.expectEqualStrings("mock:adapter/in2@0.1.0", result.world.imports[0].name);

    // Exports: out should remain.
    try testing.expectEqual(@as(usize, 1), result.world.exports.len);
    try testing.expectEqualStrings("mock:adapter/out@0.1.0", result.world.exports[0].name);

    // Verify the result round-trips through loader (decode.parse already
    // succeeded inside gcWorld) and through types_import.hoist.
    const types_import = @import("types_import.zig");
    const hoisted = try types_import.hoist(a, result.world);
    try testing.expectEqual(@as(usize, 1), hoisted.imports.len);
    try testing.expectEqual(@as(usize, 1), hoisted.instances.len);
    try testing.expectEqual(@as(u32, 0), hoisted.instances[0].instance_idx);
}

test "gcWorld: empty live-namespace set yields export-only world" {
    const ct = try buildMockEncodedWorld(testing.allocator, std_world, "adapter-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);

    const result = try gcWorld(a, world, &.{}, &.{"mock:adapter/out@0.1.0"});

    try testing.expectEqual(@as(usize, 0), result.world.imports.len);
    try testing.expectEqual(@as(usize, 1), result.world.exports.len);
}

test "gcWorld: bogus live name (not in world) is silently ignored" {
    const ct = try buildMockEncodedWorld(testing.allocator, std_world, "adapter-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);

    const result = try gcWorld(
        a,
        world,
        &.{ "mock:adapter/in1@0.1.0", "wasi:does-not-exist@9.9.9" },
        &.{"mock:adapter/out@0.1.0"},
    );

    try testing.expectEqual(@as(usize, 1), result.world.imports.len);
    try testing.expectEqualStrings("mock:adapter/in1@0.1.0", result.world.imports[0].name);
}

test "gcWorld: keeps all imports when all are live" {
    const ct = try buildMockEncodedWorld(testing.allocator, std_world, "adapter-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);

    const result = try gcWorld(
        a,
        world,
        &.{ "mock:adapter/in1@0.1.0", "mock:adapter/in2@0.1.0", "mock:adapter/in3@0.1.0" },
        &.{"mock:adapter/out@0.1.0"},
    );

    try testing.expectEqual(@as(usize, 3), result.world.imports.len);
    try testing.expectEqualStrings("mock:adapter/in1@0.1.0", result.world.imports[0].name);
    try testing.expectEqualStrings("mock:adapter/in2@0.1.0", result.world.imports[1].name);
    try testing.expectEqualStrings("mock:adapter/in3@0.1.0", result.world.imports[2].name);
}

test "gcWorld: renumbers instance and type idx in surviving imports" {
    const ct = try buildMockEncodedWorld(testing.allocator, std_world, "adapter-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const world = try decode.parse(a, ct);

    // Keep middle import only; its instance idx in the original was 1
    // (after in1) and its type idx was 1 (after in1's instance type).
    // After GC: instance idx = 0, type idx = 0.
    const result = try gcWorld(
        a,
        world,
        &.{"mock:adapter/in2@0.1.0"},
        &.{"mock:adapter/out@0.1.0"},
    );

    try testing.expectEqual(@as(usize, 1), result.world.imports.len);
    try testing.expectEqual(@as(u32, 0), result.world.imports[0].body_instance_idx);
    try testing.expectEqual(@as(u32, 0), result.world.imports[0].body_type_idx);

    // Export's body_type_idx should be the next slot after in2's type
    // (idx=1 if export instance type comes after import instance type).
    try testing.expectEqual(@as(usize, 1), result.world.exports.len);
}

test "gcWorld: payload bytes round-trip through replaceEncodedWorldSection" {
    const ct = try buildMockEncodedWorld(testing.allocator, std_world, "adapter-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Wrap the original CT as adapter core wasm (mirroring decode.zig's
    // wrapAsAdapterCore helper).
    const adapter_core = try wrapAsAdapterCore(a, ct);

    const world = try decode.parse(a, ct);
    const result = try gcWorld(a, world, &.{"mock:adapter/in2@0.1.0"}, &.{"mock:adapter/out@0.1.0"});

    const new_core = try replaceEncodedWorldSection(a, adapter_core, result.payload_bytes);
    // The new core should still parse cleanly and yield the GC'd world.
    const reparsed = try decode.parseFromAdapterCore(a, new_core);
    try testing.expectEqual(@as(usize, 1), reparsed.imports.len);
    try testing.expectEqualStrings("mock:adapter/in2@0.1.0", reparsed.imports[0].name);
}

fn wrapAsAdapterCore(arena: Allocator, ct_payload: []const u8) ![]u8 {
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const sec_name = "component-type:mock:encoded world";
    var name_leb: [leb128.max_u32_bytes]u8 = undefined;
    const name_leb_n = leb128.writeU32Leb128(&name_leb, @intCast(sec_name.len));
    const body_len = name_leb_n + sec_name.len + ct_payload.len;
    var size_leb: [leb128.max_u32_bytes]u8 = undefined;
    const size_leb_n = leb128.writeU32Leb128(&size_leb, @intCast(body_len));

    var out = try std.ArrayListUnmanaged(u8).initCapacity(arena, preamble.len + 1 + size_leb_n + body_len);
    out.appendSliceAssumeCapacity(&preamble);
    out.appendAssumeCapacity(0); // custom section id
    out.appendSliceAssumeCapacity(size_leb[0..size_leb_n]);
    out.appendSliceAssumeCapacity(name_leb[0..name_leb_n]);
    out.appendSliceAssumeCapacity(sec_name);
    out.appendSliceAssumeCapacity(ct_payload);
    return out.toOwnedSlice(arena);
}
