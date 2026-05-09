//! Depth-aware traversal helpers for component-level type trees.
//!
//! Two reusable passes:
//!
//!   * `collect…` — walk a `TypeDef` / `Decl` / `ExternDesc` and emit
//!     the set of type-indexspace operands that read the *enclosing*
//!     (depth-0) component's type indexspace. Operands at `depth>0`
//!     reference a local-to-the-nested-scope indexspace and are
//!     ignored — except for outer aliases whose `outer_count` reaches
//!     all the way back to depth 0, which DO contribute a depth-0
//!     ref.
//!
//!   * `clone…` — deep-copy a `TypeDef` / `Decl` / `ExternDesc` while
//!     rewriting every depth-0 operand through a `type_remap` table.
//!     Operands at `depth>0` are copied verbatim. Outer aliases whose
//!     chain reaches depth 0 (`outer_count == depth` and `sort ==
//!     .type`) are remapped — keeping the alias valid after the
//!     enclosing component's type indexspace has been rewritten.
//!
//! Originally extracted from `src/component/adapter/world_gc.zig`,
//! which still owns the per-decl-metadata pre-pass and liveness
//! solver. This module just provides the shared walk primitives so
//! `wabt component compose` can reuse them when topologically
//! emitting consumer types into a wrapping component.
//!
//! Limitations (deliberate, mirrored from `world_gc`):
//!
//!   * `.component` TypeDefs at any depth → `error.UnsupportedAdapterShape`.
//!     Real component-type bodies inside top-level types are rare in
//!     wasm-tools output and the wasi-preview1 adapter never uses
//!     them. Relax in a follow-up if real inputs hit it.
//!   * `core_type` decls inside an instance body →
//!     `error.UnsupportedAdapterShape`. Same rationale.
//!
//! All slices are arena-allocated; the caller owns the arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("types.zig");

// `UnsupportedAdapterShape` is preserved as a name for compatibility
// with the adapter splicer's existing error sets (see
// `src/component/adapter/world_gc.zig::Error`). Conceptually it means
// "the type tree contains a construct this walk doesn't model" — it
// is not adapter-specific.
pub const Error = error{ OutOfMemory, UnsupportedAdapterShape };

// ── Collect: type-indexspace refs at depth 0 ───────────────────────────────

/// Collect type-idx refs from a type def. `depth` is the nesting
/// depth — 0 for the enclosing component's body, 1 inside an
/// instance type body, etc. Refs at `depth>0` reference a
/// local-to-nested-scope indexspace and are *not* emitted; outer
/// aliases whose `outer_count == depth` bubble up to depth 0 and ARE
/// emitted (handled in `collectInstanceBodyRefs`).
pub fn collectTypeDefRefs(
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

/// Collect type-idx refs from valtype operands. ValTypes at `depth>0`
/// reference the local type indexspace at THAT depth — not the
/// enclosing component's. So they don't contribute body-level refs.
pub fn collectValTypeRefs(
    arena: Allocator,
    vt: ctypes.ValType,
    out: *std.ArrayListUnmanaged(u32),
    depth: u32,
) Error!void {
    if (depth != 0) return;
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

pub fn collectInstanceBodyRefs(
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
                    // enclosing component) — its `idx` reads that
                    // component's type indexspace.
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

pub fn collectExternDescRefs(
    arena: Allocator,
    desc: ctypes.ExternDesc,
    out: *std.ArrayListUnmanaged(u32),
) Error!void {
    return collectExternDescRefsAtDepth(arena, desc, out, 0);
}

pub fn collectExternDescRefsAtDepth(
    arena: Allocator,
    desc: ctypes.ExternDesc,
    out: *std.ArrayListUnmanaged(u32),
    depth: u32,
) Error!void {
    if (depth != 0) return;
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

pub fn cloneDecl(
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

pub fn cloneAlias(
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
            // depth-0 outer alias references the enclosing
            // component's indexspace; world_gc's caller has always
            // emitted this for boilerplate (idx 0) and left it
            // verbatim. Compose's caller likewise emits this only
            // for top-level body alias decls, where the enclosing
            // scope is the wrapping component and the idx is fresh
            // in the wrapper's space — leave verbatim here too.
            .idx = o.idx,
        } },
    };
}

pub fn cloneTypeDef(
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

pub fn cloneInstanceBody(
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
/// chain reaches depth 0 (`outer_count == depth`) have their `idx`
/// rewritten through `type_remap`, so the alias target survives a
/// rewrite of the depth-0 type indexspace.
pub fn cloneInstanceBodyAlias(
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

pub fn cloneExternDesc(
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

pub fn cloneValType(
    arena: Allocator,
    vt: ctypes.ValType,
    type_remap: []const u32,
    depth: u32,
) Error!ctypes.ValType {
    _ = arena;
    if (depth != 0) return vt;
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

/// Rewrite `idx` through `table`. Values past the end of `table` are
/// returned verbatim — sentinel for "this idx is outside the remap'd
/// indexspace and should be passed through" (e.g. depth>0 local
/// types when `cloneValType` is called at depth==0 by mistake won't
/// crash, but should never happen in practice).
pub fn remap(table: []const u32, idx: u32) u32 {
    if (idx >= table.len) return idx;
    return table[idx];
}
