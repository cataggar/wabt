//! Canonical-ABI flattening for adapter import classification.
//!
//! For each WASI function the adapter declares as a *core import*,
//! the splicer needs to decide whether to:
//!
//!   * `(canon lower)` directly at the component level — works when
//!     the lowered call needs no memory I/O and fits in one flat
//!     return register (e.g. `() -> own<output-stream>`); or
//!   * route through the **shim + fixup** machinery — required when
//!     either the params or the results need memory access (any
//!     `string` / `list` somewhere in the tree, OR more than one
//!     flat result, since a multi-result call returns through a
//!     pointer the caller allocates).
//!
//! `wit-component` makes the same decision; this module mirrors its
//! flattening rules over our `Component` AST. We classify against
//! the encoded-world's body decls so the input is exactly what
//! `decode.zig` already produced — no re-parsing.
//!
//! Outer-alias chains inside an instance type body always resolve to
//! resources (handles) in WASI 0.2.6 — `output-stream`, `descriptor`,
//! `datetime`, etc. We treat any type idx we can't fully resolve as
//! a resource handle (1 flat `i32`, no memory). For WASI 0.2.6 this
//! is precise; for adapters carrying a richer type tree the
//! splicer would need to follow outer aliases through more layers
//! (a follow-up if needed).

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const decode = @import("decode.zig");

pub const Error = error{ OutOfMemory, FuncNotFound, NotAFuncExport, UnsupportedShape };

/// Classification result for a single adapter wasi func import.
pub const Class = enum {
    /// Lowered directly as `(canon lower (func F))` with no opts —
    /// takes no memory I/O and returns at most one flat scalar.
    direct,
    /// Lowered via shim+fixup. The wrapping component lowers with
    /// `(memory M) [+ (realloc R)] [+ string-encoding=utf8]` opts and
    /// the fixup writes the lowered func into the shim's table.
    indirect,
};

/// Aggregate flatness info of a WIT value type (recursively walked).
pub const FlatInfo = struct {
    /// Number of i32/i64/f32/f64 the value lowers to in the flat
    /// canon-ABI representation. Always `>= 0`. We saturate at
    /// 32 to keep the math bounded — anything bigger is well past
    /// `MAX_FLAT_PARAMS`/`MAX_FLAT_RESULTS` anyway.
    flat: u32 = 0,
    /// True if the value (or any child) needs caller-memory access
    /// to lower / lift — i.e. contains `string`, `list`, or any
    /// compound whose flat repr exceeds the register cutoff in a
    /// way that would force pass-by-pointer.
    needs_memory: bool = false,
    /// True if the value needs callee-side allocation in caller
    /// memory — i.e. a `string` or `list` appears somewhere in this
    /// (sub)tree. Used to decide whether the canon-lower needs a
    /// `(realloc <cabi_import_realloc>)` opt.
    needs_realloc_alloc: bool = false,
    /// True if a `string` appears anywhere in this (sub)tree.
    contains_string: bool = false,
};

pub const FuncOpts = struct {
    /// True iff lowering the func needs `(memory <main_memory>)`.
    /// Required when params have list/string, when result needs
    /// pass-by-pointer (`flat_results > 1`), or when result has
    /// list/string.
    memory: bool,
    /// True iff lowering the func needs
    /// `(realloc <adapter_cabi_import_realloc>)`. Required when the
    /// result contains list/string (callee allocates the result data
    /// into caller memory).
    realloc: bool,
    /// True iff `string-encoding=utf8` is required (any param OR
    /// result contains string).
    string_encoding: bool,
};

pub const FuncTypeRef = struct {
    /// Component-level FuncType the import points at.
    func: ctypes.FuncType,
    /// Resolver carrying the instance type body and outer scope for
    /// type-idx resolution.
    resolver: TypeResolver,
};

/// View of the type indexspace as seen from inside an instance type
/// body. Lets `flatten` resolve `.type_idx` references back to a
/// concrete `TypeDef`, recursing through outer aliases when needed.
pub const TypeResolver = struct {
    /// Decls of the instance body itself.
    inst_decls: []const ctypes.Decl,
    /// Decls of the world body (one level out from the instance).
    world_decls: []const ctypes.Decl,

    /// Resolve a local type idx in the instance scope to the
    /// underlying `TypeDef`, following outer aliases into the world
    /// body. Returns null if the idx points outside what's
    /// resolvable here (treat as scalar handle by the caller).
    pub fn resolveLocal(self: TypeResolver, idx: u32) ?ctypes.TypeDef {
        return resolveTypeIdxIn(self.inst_decls, idx, self.world_decls);
    }

    /// Resolve a type idx in the world scope. Used when an outer
    /// alias points at a world-body type idx and we want to follow
    /// it to its definition.
    pub fn resolveWorld(self: TypeResolver, idx: u32) ?ctypes.TypeDef {
        return resolveTypeIdxIn(self.world_decls, idx, &.{});
    }

    /// Like `resolveLocal`, but also reports the decls scope in which
    /// the resolved `TypeDef`'s own child `type_idx` references live.
    /// When a `type_idx` resolves across an interface boundary (via an
    /// `alias instance-export` into another imported interface's
    /// body), the resolved type's children are numbered in *that*
    /// interface's type-index space — so flattening them requires
    /// rebasing the resolver onto the returned scope. Failing to
    /// rebase silently drops nested `string`/`list` content and the
    /// canon-lower opts (`realloc`/`string-encoding`) that go with it
    /// (#234).
    pub fn resolveLocalScoped(self: TypeResolver, idx: u32) ?ResolvedType {
        return resolveTypeIdxInScoped(self.inst_decls, idx, self.world_decls);
    }
};

/// A resolved `TypeDef` together with the decls scope its child
/// `type_idx` references must be interpreted in.
pub const ResolvedType = struct {
    td: ctypes.TypeDef,
    inst_decls: []const ctypes.Decl,
};

fn resolveTypeIdxInScoped(
    decls: []const ctypes.Decl,
    target: u32,
    outer_decls: []const ctypes.Decl,
) ?ResolvedType {
    var cursor: u32 = 0;
    for (decls) |d| {
        switch (d) {
            .type => |td| {
                if (cursor == target) return .{ .td = td, .inst_decls = decls };
                cursor += 1;
            },
            .core_type => cursor += 1,
            .alias => |a| {
                const sort: ctypes.Sort = switch (a) {
                    .instance_export => |ie| ie.sort,
                    .outer => |o| o.sort,
                };
                if (sort == .type) {
                    if (cursor == target) return resolveAliasScoped(a, outer_decls);
                    cursor += 1;
                }
            },
            .@"export" => |e| switch (e.desc) {
                .type => |bound| {
                    if (cursor == target) return resolveTypeBoundScoped(bound, decls, outer_decls);
                    cursor += 1;
                },
                else => {},
            },
            else => {},
        }
    }
    return null;
}

fn resolveAliasScoped(a: ctypes.Alias, outer_decls: []const ctypes.Decl) ?ResolvedType {
    return switch (a) {
        .outer => |o| if (o.sort == .type)
            resolveTypeIdxInScoped(outer_decls, o.idx, outer_decls)
        else
            null,
        .instance_export => |ie| resolveInstanceTypeExportScoped(outer_decls, ie.instance_idx, ie.name),
    };
}

fn resolveInstanceTypeExportScoped(
    world_decls: []const ctypes.Decl,
    instance_idx: u32,
    name: []const u8,
) ?ResolvedType {
    const inst_decls = findInstanceBodyAtIdx(world_decls, instance_idx) orelse return null;
    for (inst_decls) |d| switch (d) {
        .@"export" => |e| {
            if (e.desc != .type) continue;
            if (!std.mem.eql(u8, e.name, name)) continue;
            return resolveTypeBoundScoped(e.desc.type, inst_decls, world_decls);
        },
        else => {},
    };
    return null;
}

fn resolveTypeBoundScoped(
    bound: ctypes.TypeBound,
    decls: []const ctypes.Decl,
    outer_decls: []const ctypes.Decl,
) ?ResolvedType {
    return switch (bound) {
        .eq => |idx| resolveTypeIdxInScoped(decls, idx, outer_decls),
        .sub_resource => ResolvedType{ .td = .{ .resource = .{} }, .inst_decls = decls },
    };
}

/// Walk `decls` (instance or world body) and return the `TypeDef` at
/// type-indexspace position `target`, following outer aliases into
/// `outer_decls` when present.
fn resolveTypeIdxIn(
    decls: []const ctypes.Decl,
    target: u32,
    outer_decls: []const ctypes.Decl,
) ?ctypes.TypeDef {
    var cursor: u32 = 0;
    for (decls) |d| {
        switch (d) {
            .type => |td| {
                if (cursor == target) return td;
                cursor += 1;
            },
            .core_type => {
                cursor += 1;
            },
            .alias => |a| {
                const sort: ctypes.Sort = switch (a) {
                    .instance_export => |ie| ie.sort,
                    .outer => |o| o.sort,
                };
                if (sort == .type) {
                    if (cursor == target) {
                        return resolveAlias(a, outer_decls);
                    }
                    cursor += 1;
                }
            },
            .@"export" => |e| {
                // Exports of types in an instance body contribute to
                // the type indexspace too (type re-exports).
                switch (e.desc) {
                    .type => |bound| {
                        if (cursor == target) {
                            return resolveTypeBound(bound, decls, outer_decls);
                        }
                        cursor += 1;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
    return null;
}

fn resolveAlias(a: ctypes.Alias, outer_decls: []const ctypes.Decl) ?ctypes.TypeDef {
    return switch (a) {
        .outer => |o| if (o.sort == .type)
            resolveOuterType(outer_decls, o.idx)
        else
            null,
        // `(alias export <inst-idx> <name> (type T))` resolves into
        // the instance type body for `inst-idx` to find a named
        // type export. Used heavily by WASI types that pull other
        // namespaces' types in (e.g. wasi:filesystem/types
        // pulling datetime from wasi:clocks/wall-clock).
        .instance_export => |ie| resolveInstanceTypeExport(outer_decls, ie.instance_idx, ie.name),
    };
}

/// Resolve a type idx in the OUTER (world) scope, including any
/// alias chains that resolve to other parts of the same world. The
/// outer scope is its own "outer" — there is no further outer here.
fn resolveOuterType(outer_decls: []const ctypes.Decl, target: u32) ?ctypes.TypeDef {
    return resolveTypeIdxIn(outer_decls, target, outer_decls);
}

/// At the world level, locate the instance type body backing the
/// instance at `instance_idx` in the world's instance indexspace,
/// then look up `name` as a type export in that body and resolve
/// its bound back to a `TypeDef`.
fn resolveInstanceTypeExport(world_decls: []const ctypes.Decl, instance_idx: u32, name: []const u8) ?ctypes.TypeDef {
    const inst_decls = findInstanceBodyAtIdx(world_decls, instance_idx) orelse return null;
    for (inst_decls) |d| switch (d) {
        .@"export" => |e| {
            if (e.desc != .type) continue;
            if (!std.mem.eql(u8, e.name, name)) continue;
            return resolveTypeBound(e.desc.type, inst_decls, world_decls);
        },
        else => {},
    };
    return null;
}

/// Walk world-level decls and find the body of the instance type
/// at the given world-level instance indexspace position. Counts
/// instance imports + instance type defs (and instance-typed
/// exports / aliases, for completeness) per the spec's instance
/// indexspace ordering.
fn findInstanceBodyAtIdx(world_decls: []const ctypes.Decl, target: u32) ?[]const ctypes.Decl {
    var cursor: u32 = 0;
    for (world_decls) |d| switch (d) {
        .import => |im| {
            if (im.desc == .instance) {
                if (cursor == target) {
                    const td = resolveOuterType(world_decls, im.desc.instance) orelse return null;
                    if (td != .instance) return null;
                    return td.instance.decls;
                }
                cursor += 1;
            }
        },
        else => {},
    };
    return null;
}

fn resolveTypeBound(
    bound: ctypes.TypeBound,
    decls: []const ctypes.Decl,
    outer_decls: []const ctypes.Decl,
) ?ctypes.TypeDef {
    return switch (bound) {
        .eq => |idx| resolveTypeIdxIn(decls, idx, outer_decls),
        .sub_resource => ctypes.TypeDef{ .resource = .{} },
    };
}

/// Locate the func type referenced by `(export "<name>" (func F))`
/// inside the instance whose type idx is `inst_type_idx` in the
/// world body, and return both the FuncType and a resolver scoped
/// to that instance.
pub fn findFuncImport(
    world: decode.AdapterWorld,
    inst_type_idx: u32,
    func_name: []const u8,
) Error!FuncTypeRef {
    const inst_decls = try findInstanceTypeBody(world.body_decls, inst_type_idx);
    const func_type_idx = (try findFuncExportTypeIdx(inst_decls, func_name)) orelse
        return error.FuncNotFound;
    const td = resolveTypeIdxIn(inst_decls, func_type_idx, world.body_decls) orelse
        return error.UnsupportedShape;
    if (td != .func) return error.NotAFuncExport;
    return .{
        .func = td.func,
        .resolver = .{
            .inst_decls = inst_decls,
            .world_decls = world.body_decls,
        },
    };
}

fn findInstanceTypeBody(
    world_decls: []const ctypes.Decl,
    inst_type_idx: u32,
) Error![]const ctypes.Decl {
    const td = resolveTypeIdxIn(world_decls, inst_type_idx, &.{}) orelse
        return error.UnsupportedShape;
    if (td != .instance) return error.UnsupportedShape;
    return td.instance.decls;
}

fn findFuncExportTypeIdx(
    inst_decls: []const ctypes.Decl,
    func_name: []const u8,
) Error!?u32 {
    for (inst_decls) |d| switch (d) {
        .@"export" => |e| {
            if (e.desc == .func and std.mem.eql(u8, e.name, func_name)) {
                return e.desc.func;
            }
        },
        else => {},
    };
    return null;
}

/// Walk a `ValType` and aggregate flat / memory / realloc / string
/// info. `is_param` matters because list/string in a param needs
/// memory but does NOT need realloc; in a result, it needs both.
pub fn flatten(vt: ctypes.ValType, resolver: TypeResolver) FlatInfo {
    return flattenInner(vt, resolver, 0);
}

fn flattenInner(vt: ctypes.ValType, resolver: TypeResolver, depth: u32) FlatInfo {
    if (depth > 32) return .{ .flat = 1 }; // recursion guard
    return switch (vt) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => .{ .flat = 1 },
        .s64, .u64 => .{ .flat = 1 },
        .f32, .f64 => .{ .flat = 1 },
        .own, .borrow => .{ .flat = 1 },
        .string => .{
            .flat = 2,
            .needs_memory = true,
            .needs_realloc_alloc = true,
            .contains_string = true,
        },
        .list => |idx| blk: {
            // list always flattens to (ptr, len) regardless of
            // element. Element walk only needed to propagate
            // contains_string.
            const elem_info = resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 1 });
            break :blk .{
                .flat = 2,
                .needs_memory = true,
                .needs_realloc_alloc = true,
                .contains_string = elem_info.contains_string,
            };
        },
        // Likely an outer alias to a resource — treat as i32 handle.
        .type_idx => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 1 }),
        .record => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 1 }),
        .variant => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 2 }),
        .tuple => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 1 }),
        .flags => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 1 }),
        .enum_ => .{ .flat = 1 },
        .option => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 2 }),
        .result => |idx| resolveAndFlatten(idx, resolver, depth, FlatInfo{ .flat = 2 }),
    };
}

/// Resolve `idx` in `resolver`'s scope and flatten the resulting
/// `TypeDef`, rebasing the resolver onto the scope the resolved type
/// lives in (so cross-interface `type_idx` children resolve correctly,
/// #234). Falls back to `unresolved` when `idx` can't be resolved
/// (e.g. a bare outer alias to a resource → scalar handle).
fn resolveAndFlatten(idx: u32, resolver: TypeResolver, depth: u32, unresolved: FlatInfo) FlatInfo {
    const r = resolver.resolveLocalScoped(idx) orelse return unresolved;
    const sub = TypeResolver{ .inst_decls = r.inst_decls, .world_decls = resolver.world_decls };
    return flattenTypeDef(r.td, sub, depth + 1);
}


fn flattenTypeDef(td: ctypes.TypeDef, resolver: TypeResolver, depth: u32) FlatInfo {
    return switch (td) {
        .val => |vt| flattenInner(vt, resolver, depth),
        .record => |r| blk: {
            var info = FlatInfo{};
            for (r.fields) |f| {
                const fi = flattenInner(f.type, resolver, depth);
                info.flat = saturatingAdd(info.flat, fi.flat);
                info.needs_memory = info.needs_memory or fi.needs_memory;
                info.needs_realloc_alloc = info.needs_realloc_alloc or fi.needs_realloc_alloc;
                info.contains_string = info.contains_string or fi.contains_string;
            }
            break :blk info;
        },
        .variant => |v| blk: {
            // Variant flat = 1 (disc) + max(case flat).
            var info = FlatInfo{ .flat = 1 };
            var max_case: u32 = 0;
            for (v.cases) |c| {
                if (c.type) |vt| {
                    const ci = flattenInner(vt, resolver, depth);
                    if (ci.flat > max_case) max_case = ci.flat;
                    info.needs_memory = info.needs_memory or ci.needs_memory;
                    info.needs_realloc_alloc = info.needs_realloc_alloc or ci.needs_realloc_alloc;
                    info.contains_string = info.contains_string or ci.contains_string;
                }
            }
            info.flat = saturatingAdd(info.flat, max_case);
            break :blk info;
        },
        .list => |l| blk: {
            const elem_info = flattenInner(l.element, resolver, depth);
            break :blk .{
                .flat = 2,
                .needs_memory = true,
                .needs_realloc_alloc = true,
                .contains_string = elem_info.contains_string,
            };
        },
        .tuple => |t| blk: {
            var info = FlatInfo{};
            for (t.fields) |fty| {
                const fi = flattenInner(fty, resolver, depth);
                info.flat = saturatingAdd(info.flat, fi.flat);
                info.needs_memory = info.needs_memory or fi.needs_memory;
                info.needs_realloc_alloc = info.needs_realloc_alloc or fi.needs_realloc_alloc;
                info.contains_string = info.contains_string or fi.contains_string;
            }
            break :blk info;
        },
        .flags => |f| blk: {
            const slots = (f.names.len + 31) / 32;
            const slots_u32: u32 = if (slots == 0) 1 else @intCast(slots);
            break :blk .{ .flat = slots_u32 };
        },
        .enum_ => .{ .flat = 1 },
        .option => |o| blk: {
            const inner = flattenInner(o.inner, resolver, depth);
            break :blk .{
                .flat = saturatingAdd(1, inner.flat),
                .needs_memory = inner.needs_memory,
                .needs_realloc_alloc = inner.needs_realloc_alloc,
                .contains_string = inner.contains_string,
            };
        },
        .result => |r| blk: {
            var info = FlatInfo{ .flat = 1 };
            var max_case: u32 = 0;
            inline for (.{ r.ok, r.err }) |maybe_vt| {
                if (maybe_vt) |vt| {
                    const ci = flattenInner(vt, resolver, depth);
                    if (ci.flat > max_case) max_case = ci.flat;
                    info.needs_memory = info.needs_memory or ci.needs_memory;
                    info.needs_realloc_alloc = info.needs_realloc_alloc or ci.needs_realloc_alloc;
                    info.contains_string = info.contains_string or ci.contains_string;
                }
            }
            info.flat = saturatingAdd(info.flat, max_case);
            break :blk info;
        },
        .resource => .{ .flat = 1 },
        // Func / component / instance are not value types; reaching
        // them through a `.type_idx` is malformed but treat as scalar.
        .func, .component, .instance => .{ .flat = 1 },
    };
}

fn saturatingAdd(a: u32, b: u32) u32 {
    const sum = @as(u64, a) + @as(u64, b);
    return if (sum > 32) 32 else @intCast(sum);
}

/// Maximum number of flat values that fit in registers — beyond
/// these, the canon ABI passes through memory pointers.
pub const MAX_FLAT_PARAMS: u32 = 16;
pub const MAX_FLAT_RESULTS: u32 = 1;

pub const Classification = struct {
    class: Class,
    opts: FuncOpts,
    /// Sum of flat params (capped). Useful for shim sig generation.
    params_flat: u32,
    /// Result flat count (capped). Useful for shim sig generation.
    results_flat: u32,
    /// Whether the result is non-empty (`results != .none`).
    has_result: bool,
};

/// Classify a func signature into direct-vs-indirect and produce
/// the canon-lower opt list flags.
pub fn classifyFunc(ftr: FuncTypeRef) Classification {
    const ft = ftr.func;
    const resolver = ftr.resolver;

    var params_flat: u32 = 0;
    var params_have_string_or_list_via_memory = false;
    var any_string = false;
    for (ft.params) |p| {
        const info = flatten(p.type, resolver);
        params_flat = saturatingAdd(params_flat, info.flat);
        if (info.needs_memory) params_have_string_or_list_via_memory = true;
        if (info.contains_string) any_string = true;
    }

    var results_flat: u32 = 0;
    var results_have_string_or_list = false;
    var has_result = false;
    switch (ft.results) {
        .none => {},
        .unnamed => |vt| {
            const info = flatten(vt, resolver);
            results_flat = info.flat;
            results_have_string_or_list = info.needs_realloc_alloc;
            if (info.contains_string) any_string = true;
            has_result = true;
        },
        .named => |list| {
            for (list) |nv| {
                const info = flatten(nv.type, resolver);
                results_flat = saturatingAdd(results_flat, info.flat);
                if (info.needs_realloc_alloc) results_have_string_or_list = true;
                if (info.contains_string) any_string = true;
            }
            has_result = list.len > 0;
        },
    }

    const need_memory =
        params_have_string_or_list_via_memory or
        results_flat > MAX_FLAT_RESULTS or
        results_have_string_or_list;

    const need_realloc = results_have_string_or_list;

    const class: Class = if (need_memory or params_flat > MAX_FLAT_PARAMS)
        .indirect
    else
        .direct;

    return .{
        .class = class,
        .opts = .{
            .memory = need_memory,
            .realloc = need_realloc,
            .string_encoding = any_string,
        },
        .params_flat = params_flat,
        .results_flat = results_flat,
        .has_result = has_result,
    };
}

/// Canon-*lift* options for an exported func. Distinct from `FuncOpts`
/// (which is tailored for `canon lower`): on the lift side `realloc`
/// is needed to lower string/list **params** into guest memory, and
/// `post_return` is needed to free string/list **results** the guest
/// allocated. (Lower instead needs `realloc` for its results.)
pub const LiftOpts = struct {
    /// `(memory <main_memory>)` — params or results reach memory.
    memory: bool,
    /// `(realloc <cabi_realloc>)` — a param contains string/list.
    realloc: bool,
    /// `string-encoding=utf8` — any param or result contains string.
    string_encoding: bool,
    /// A result contains string/list, so the lift needs a
    /// `(post-return <cabi_post_…>)` to release it — provided the guest
    /// actually exports the matching `cabi_post_*` core func.
    needs_post_return: bool,
};

/// Classify an exported func for `canon lift`. See `LiftOpts`.
pub fn classifyFuncLift(ftr: FuncTypeRef) LiftOpts {
    const ft = ftr.func;
    const resolver = ftr.resolver;

    var params_flat: u32 = 0;
    var params_need_memory = false;
    var params_need_realloc = false;
    var any_string = false;
    for (ft.params) |p| {
        const info = flatten(p.type, resolver);
        params_flat = saturatingAdd(params_flat, info.flat);
        if (info.needs_memory) params_need_memory = true;
        if (info.needs_realloc_alloc) params_need_realloc = true;
        if (info.contains_string) any_string = true;
    }

    var results_flat: u32 = 0;
    var results_need_memory = false;
    var results_need_cleanup = false;
    switch (ft.results) {
        .none => {},
        .unnamed => |vt| {
            const info = flatten(vt, resolver);
            results_flat = info.flat;
            if (info.needs_memory) results_need_memory = true;
            if (info.needs_realloc_alloc) results_need_cleanup = true;
            if (info.contains_string) any_string = true;
        },
        .named => |list| for (list) |nv| {
            const info = flatten(nv.type, resolver);
            results_flat = saturatingAdd(results_flat, info.flat);
            if (info.needs_memory) results_need_memory = true;
            if (info.needs_realloc_alloc) results_need_cleanup = true;
            if (info.contains_string) any_string = true;
        },
    }

    const need_memory =
        params_need_memory or results_need_memory or
        params_flat > MAX_FLAT_PARAMS or results_flat > MAX_FLAT_RESULTS;

    return .{
        .memory = need_memory,
        .realloc = params_need_realloc,
        .string_encoding = any_string,
        .needs_post_return = results_need_cleanup,
    };
}

/// True iff lifting this exported func requires any canon-lift option
/// (and therefore the shim/fixup path, which aliases `memory` /
/// `cabi_realloc`).
pub fn liftNeedsOpts(lo: LiftOpts) bool {
    return lo.memory or lo.realloc or lo.string_encoding or lo.needs_post_return;
}

/// Compute the flat core-wasm signature an indirect import lowers
/// to. Used by the splicer when sizing the shim's trampoline slots
/// (which must match the lowered call's flat repr — params first,
/// then `(memory option)` adds nothing extra to the core sig
/// because `(memory)` is a per-call option, not a param).
///
/// Slot types follow the canon-ABI flattening rules:
/// `bool`/`s8`/`u8`/`s16`/`u16`/`s32`/`u32`/`char`/handle → `i32`,
/// `s64`/`u64` → `i64`, `f32` → `f32`, `f64` → `f64`,
/// `string`/`list` → `(i32, i32)` (ptr, len),
/// `record`/`tuple` → field-wise concatenation,
/// `variant`/`option`/`result` → `i32` discriminant + `join`ed
/// payload across cases (`join(t,t)=t`, `join(i32,f32)=i32`,
/// otherwise `i64`).
///
/// Caveat: when results-flat > MAX_FLAT_RESULTS, the canon ABI
/// passes results through a returned pointer, which means the core
/// sig actually has 0 results and one extra `i32` param (the output
/// pointer). We model that here.
pub fn lowerCoreSig(
    arena: Allocator,
    ftr: FuncTypeRef,
) Error!struct {
    params: []const wtypes.ValType,
    results: []const wtypes.ValType,
} {
    const ft = ftr.func;
    const resolver = ftr.resolver;

    var params = std.ArrayListUnmanaged(wtypes.ValType).empty;
    for (ft.params) |p| try flattenSlots(arena, p.type, resolver, 0, &params);

    var results = std.ArrayListUnmanaged(wtypes.ValType).empty;
    switch (ft.results) {
        .none => {},
        .unnamed => |vt| try flattenSlots(arena, vt, resolver, 0, &results),
        .named => |list| for (list) |nv|
            try flattenSlots(arena, nv.type, resolver, 0, &results),
    }

    if (results.items.len > MAX_FLAT_RESULTS) {
        // Indirect result: callee writes into caller-supplied
        // pointer. Core sig becomes (params + ret_ptr) -> ().
        try params.append(arena, .i32);
        results.clearRetainingCapacity();
    }

    return .{
        .params = try params.toOwnedSlice(arena),
        .results = try results.toOwnedSlice(arena),
    };
}

const wtypes = @import("../../types.zig");

/// Append the canon-ABI flat slot types of `vt` into `out`.
fn flattenSlots(
    arena: Allocator,
    vt: ctypes.ValType,
    resolver: TypeResolver,
    depth: u32,
    out: *std.ArrayListUnmanaged(wtypes.ValType),
) Error!void {
    if (depth > 32) {
        try out.append(arena, .i32);
        return;
    }
    switch (vt) {
        .bool, .s8, .u8, .s16, .u16, .s32, .u32, .char => try out.append(arena, .i32),
        .s64, .u64 => try out.append(arena, .i64),
        .f32 => try out.append(arena, .f32),
        .f64 => try out.append(arena, .f64),
        .own, .borrow => try out.append(arena, .i32),
        .string => {
            try out.append(arena, .i32);
            try out.append(arena, .i32);
        },
        .list => {
            try out.append(arena, .i32);
            try out.append(arena, .i32);
        },
        .type_idx,
        .record,
        .variant,
        .tuple,
        .flags,
        .option,
        .result,
        => |idx| {
            if (resolver.resolveLocalScoped(idx)) |r| {
                const sub = TypeResolver{ .inst_decls = r.inst_decls, .world_decls = resolver.world_decls };
                try flattenTypeDefSlots(arena, r.td, sub, depth + 1, out);
            } else {
                // Unresolvable (likely outer-aliased resource handle).
                // Default depends on the leaf shape.
                switch (vt) {
                    .variant, .option, .result => {
                        try out.append(arena, .i32);
                        try out.append(arena, .i32);
                    },
                    else => try out.append(arena, .i32),
                }
            }
        },
        .enum_ => try out.append(arena, .i32),
    }
}

fn flattenTypeDefSlots(
    arena: Allocator,
    td: ctypes.TypeDef,
    resolver: TypeResolver,
    depth: u32,
    out: *std.ArrayListUnmanaged(wtypes.ValType),
) Error!void {
    switch (td) {
        .val => |vt| try flattenSlots(arena, vt, resolver, depth, out),
        .record => |r| {
            for (r.fields) |f| try flattenSlots(arena, f.type, resolver, depth, out);
        },
        .tuple => |t| {
            for (t.fields) |fty| try flattenSlots(arena, fty, resolver, depth, out);
        },
        .flags => |f| {
            const slots = (f.names.len + 31) / 32;
            const slots_u32: u32 = if (slots == 0) 1 else @intCast(slots);
            var i: u32 = 0;
            while (i < slots_u32) : (i += 1) try out.append(arena, .i32);
        },
        .enum_ => try out.append(arena, .i32),
        .variant => |v| {
            // i32 discriminant + slot-wise join across case payloads.
            try out.append(arena, .i32);
            var payload = std.ArrayListUnmanaged(wtypes.ValType).empty;
            for (v.cases) |c| {
                if (c.type) |vt| {
                    var case_slots = std.ArrayListUnmanaged(wtypes.ValType).empty;
                    try flattenSlots(arena, vt, resolver, depth, &case_slots);
                    try joinInto(arena, &payload, case_slots.items);
                }
            }
            try out.appendSlice(arena, payload.items);
        },
        .option => |o| {
            try out.append(arena, .i32);
            try flattenSlots(arena, o.inner, resolver, depth, out);
        },
        .result => |r| {
            try out.append(arena, .i32);
            var payload = std.ArrayListUnmanaged(wtypes.ValType).empty;
            inline for (.{ r.ok, r.err }) |maybe_vt| {
                if (maybe_vt) |vt| {
                    var case_slots = std.ArrayListUnmanaged(wtypes.ValType).empty;
                    try flattenSlots(arena, vt, resolver, depth, &case_slots);
                    try joinInto(arena, &payload, case_slots.items);
                }
            }
            try out.appendSlice(arena, payload.items);
        },
        .list => |l| {
            try out.append(arena, .i32);
            try out.append(arena, .i32);
            _ = l;
        },
        .resource => try out.append(arena, .i32),
        .func, .component, .instance => try out.append(arena, .i32),
    }
}

/// Join `case_slots` into `acc` slot-wise per the canon-ABI rule:
/// extend `acc` if `case_slots` is longer; for overlapping slots,
/// use `joinValType`.
fn joinInto(
    arena: Allocator,
    acc: *std.ArrayListUnmanaged(wtypes.ValType),
    case_slots: []const wtypes.ValType,
) Error!void {
    var i: usize = 0;
    while (i < case_slots.len) : (i += 1) {
        if (i < acc.items.len) {
            acc.items[i] = joinValType(acc.items[i], case_slots[i]);
        } else {
            try acc.append(arena, case_slots[i]);
        }
    }
}

fn joinValType(a: wtypes.ValType, b: wtypes.ValType) wtypes.ValType {
    if (a == b) return a;
    if ((a == .i32 and b == .f32) or (a == .f32 and b == .i32)) return .i32;
    return .i64;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const metadata_encode = @import("../wit/metadata_encode.zig");

/// Build a small mock `AdapterWorld` whose body has exactly one
/// imported instance with one func export of the given signature.
/// Use to test the classifier against synthetic types
/// (`metadata_encode` doesn't support list/option/result yet).
fn buildSyntheticWorld(
    arena: Allocator,
    inst_decls_ext: []const ctypes.Decl,
    inner_func_idx: u32,
) !decode.AdapterWorld {
    // World body decls:
    //   .type = .{ .instance = { decls = inst_decls_ext } }    // type idx 0
    //   .import "mock:abi/in1@0.1.0" (instance 0)              // instance idx 0
    const inst_td = try arena.create(ctypes.TypeDef);
    inst_td.* = .{ .instance = .{ .decls = inst_decls_ext } };

    const decls = try arena.alloc(ctypes.Decl, 2);
    decls[0] = .{ .type = inst_td.* };
    decls[1] = .{ .import = .{ .name = "mock:abi/in1@0.1.0", .desc = .{ .instance = 0 } } };

    const imports = try arena.alloc(decode.ImportEntry, 1);
    imports[0] = .{
        .name = "mock:abi/in1@0.1.0",
        .body_decl_idx = 1,
        .body_type_idx = 0,
        .body_instance_idx = 0,
    };

    _ = inner_func_idx; // silence unused

    return .{
        .component = undefined, // not used by the classifier
        .body_decls = decls,
        .body_type_count = 1,
        .imports = imports,
        .exports = &.{},
        .world_qualified_name = "mock:abi/abi-mock@0.1.0",
    };
}

test "classifyFunc: scalar-returning func is direct, no opts" {
    // Build a minimal world where one interface has func() -> u32.
    const ct = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package mock:abi@0.1.0;
        \\interface in1 { ping: func() -> u32; }
        \\world abi-mock { import in1; }
    , "abi-mock");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = try decode.parse(a, ct);
    try testing.expectEqual(@as(usize, 1), w.imports.len);
    const ftr = try findFuncImport(w, w.imports[0].body_type_idx, "ping");
    const cls = classifyFunc(ftr);

    try testing.expectEqual(Class.direct, cls.class);
    try testing.expect(!cls.opts.memory);
    try testing.expect(!cls.opts.realloc);
    try testing.expect(!cls.opts.string_encoding);
    try testing.expectEqual(@as(u32, 0), cls.params_flat);
    try testing.expectEqual(@as(u32, 1), cls.results_flat);
}

test "classifyFunc: list<u8> param triggers indirect with memory only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // instance body:
    //   .type = .{ .list = u8 }          // local type idx 0
    //   .type = .{ .func ... }           // local type idx 1
    //   .export "eat" (func 1)
    const inst_decls = try a.alloc(ctypes.Decl, 3);
    inst_decls[0] = .{ .type = .{ .list = .{ .element = .u8 } } };
    const params = try a.alloc(ctypes.NamedValType, 1);
    params[0] = .{ .name = "buf", .type = .{ .type_idx = 0 } };
    inst_decls[1] = .{ .type = .{ .func = .{
        .params = params,
        .results = .{ .unnamed = .u32 },
    } } };
    inst_decls[2] = .{ .@"export" = .{ .name = "eat", .desc = .{ .func = 1 } } };

    const w = try buildSyntheticWorld(a, inst_decls, 1);

    const ftr = try findFuncImport(w, w.imports[0].body_type_idx, "eat");
    const cls = classifyFunc(ftr);

    try testing.expectEqual(Class.indirect, cls.class);
    try testing.expect(cls.opts.memory);
    try testing.expect(!cls.opts.realloc);
    try testing.expect(!cls.opts.string_encoding);
    try testing.expectEqual(@as(u32, 2), cls.params_flat);
}

test "classifyFunc: list<u8> result triggers indirect with memory + realloc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // instance body:
    //   .type = .{ .list = u8 }          // local type idx 0
    //   .type = .{ .func () -> 0 }       // local type idx 1
    //   .export "make" (func 1)
    const inst_decls = try a.alloc(ctypes.Decl, 3);
    inst_decls[0] = .{ .type = .{ .list = .{ .element = .u8 } } };
    inst_decls[1] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 0 } },
    } } };
    inst_decls[2] = .{ .@"export" = .{ .name = "make", .desc = .{ .func = 1 } } };

    const w = try buildSyntheticWorld(a, inst_decls, 1);

    const ftr = try findFuncImport(w, w.imports[0].body_type_idx, "make");
    const cls = classifyFunc(ftr);

    try testing.expectEqual(Class.indirect, cls.class);
    try testing.expect(cls.opts.memory);
    try testing.expect(cls.opts.realloc);
    try testing.expect(!cls.opts.string_encoding);
}

test "classifyFunc: string in result triggers utf8 encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // instance body:
    //   .type = .{ .func () -> string }   // local type idx 0
    //   .export "name" (func 0)
    const inst_decls = try a.alloc(ctypes.Decl, 2);
    inst_decls[0] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .string },
    } } };
    inst_decls[1] = .{ .@"export" = .{ .name = "name", .desc = .{ .func = 0 } } };

    const w = try buildSyntheticWorld(a, inst_decls, 0);

    const ftr = try findFuncImport(w, w.imports[0].body_type_idx, "name");
    const cls = classifyFunc(ftr);

    try testing.expectEqual(Class.indirect, cls.class);
    try testing.expect(cls.opts.memory);
    try testing.expect(cls.opts.realloc);
    try testing.expect(cls.opts.string_encoding);
}

test "classifyFunc: option<u32> result has flat=2, indirect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // option<u32> flattens to (disc i32, val i32) → 2 flat returns →
    // indirect via memory pointer.
    const inst_decls = try a.alloc(ctypes.Decl, 3);
    inst_decls[0] = .{ .type = .{ .option = .{ .inner = .u32 } } };
    inst_decls[1] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 0 } },
    } } };
    inst_decls[2] = .{ .@"export" = .{ .name = "maybe", .desc = .{ .func = 1 } } };

    const w = try buildSyntheticWorld(a, inst_decls, 1);

    const ftr = try findFuncImport(w, w.imports[0].body_type_idx, "maybe");
    const cls = classifyFunc(ftr);

    try testing.expectEqual(Class.indirect, cls.class);
    try testing.expect(cls.opts.memory);
    try testing.expect(!cls.opts.realloc);
    try testing.expect(!cls.opts.string_encoding);
    try testing.expectEqual(@as(u32, 2), cls.results_flat);
}

test "classifyFunc: () -> own<resource> is direct (handle is i32)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // instance body:
    //   .export "stream" (type (sub resource))    // local type idx 0
    //   .type = .{ .val (.own 0) }                 // local type idx 1
    //   .type = .{ .func () -> 1 }                 // local type idx 2
    //   .export "open" (func 0)
    const inst_decls = try a.alloc(ctypes.Decl, 4);
    inst_decls[0] = .{ .@"export" = .{
        .name = "stream",
        .desc = .{ .type = .sub_resource },
    } };
    inst_decls[1] = .{ .type = .{ .val = .{ .own = 0 } } };
    inst_decls[2] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 1 } },
    } } };
    inst_decls[3] = .{ .@"export" = .{ .name = "open", .desc = .{ .func = 2 } } };

    const w = try buildSyntheticWorld(a, inst_decls, 2);

    const ftr = try findFuncImport(w, w.imports[0].body_type_idx, "open");
    const cls = classifyFunc(ftr);

    try testing.expectEqual(Class.direct, cls.class);
    try testing.expect(!cls.opts.memory);
    try testing.expectEqual(@as(u32, 1), cls.results_flat);
}

test "classifyFunc #234: cross-iface result whose nested string lives in another iface's scope needs realloc" {
    // Regression for cataggar/wabt#234. Interface B's `make` returns a
    // variant `err` that B pulls in via `use A.{err};`. `err`'s only
    // string content is NESTED inside an `option<string>` case payload
    // whose `type_idx` is numbered in A's local type space. Classifying
    // `make` must rebase the resolver onto A's scope when it crosses the
    // `use` boundary — otherwise the nested string is missed and the
    // canon-lower `realloc` opt is dropped (the `canonical option
    // realloc is required` validation failure).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Interface A body:
    //   slot 0: .type option<string>
    //   slot 1: .type variant { "boom"(type_idx 0) }
    //   slot 2: .export "err" (type (eq 1))
    const a_decls = try a.alloc(ctypes.Decl, 3);
    a_decls[0] = .{ .type = .{ .option = .{ .inner = .string } } };
    const cases = try a.alloc(ctypes.Case, 1);
    cases[0] = .{ .name = "boom", .type = .{ .type_idx = 0 } };
    a_decls[1] = .{ .type = .{ .variant = .{ .cases = cases } } };
    a_decls[2] = .{ .@"export" = .{ .name = "err", .desc = .{ .type = .{ .eq = 1 } } } };

    // Interface B body:
    //   slot 0: .alias outer (type 1 <world-slot 1>)   ← `use A.{err}`
    //   slot 1: .export "err" (type (eq 0))
    //   slot 2: .type func () -> type_idx 1
    //   .export "make" (func 2)
    const b_decls = try a.alloc(ctypes.Decl, 4);
    b_decls[0] = .{ .alias = .{ .outer = .{ .sort = .type, .outer_count = 1, .idx = 1 } } };
    b_decls[1] = .{ .@"export" = .{ .name = "err", .desc = .{ .type = .{ .eq = 0 } } } };
    b_decls[2] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 1 } },
    } } };
    b_decls[3] = .{ .@"export" = .{ .name = "make", .desc = .{ .func = 2 } } };

    const a_inst = try a.create(ctypes.TypeDef);
    a_inst.* = .{ .instance = .{ .decls = a_decls } };
    const b_inst = try a.create(ctypes.TypeDef);
    b_inst.* = .{ .instance = .{ .decls = b_decls } };

    // World body:
    //   decls[0]: .type instance A        (world type slot 0)
    //   decls[1]: .import "mock:a/a" (instance 0)
    //   decls[2]: .alias inst-export type inst=0 "err"  (world type slot 1)
    //   decls[3]: .type instance B        (world type slot 2)
    //   decls[4]: .import "mock:b/b" (instance 1)
    const decls = try a.alloc(ctypes.Decl, 5);
    decls[0] = .{ .type = a_inst.* };
    decls[1] = .{ .import = .{ .name = "mock:a/a@0.1.0", .desc = .{ .instance = 0 } } };
    decls[2] = .{ .alias = .{ .instance_export = .{ .sort = .type, .instance_idx = 0, .name = "err" } } };
    decls[3] = .{ .type = b_inst.* };
    decls[4] = .{ .import = .{ .name = "mock:b/b@0.1.0", .desc = .{ .instance = 2 } } };

    const w = decode.AdapterWorld{
        .component = undefined,
        .body_decls = decls,
        .body_type_count = 3,
        .imports = &.{},
        .exports = &.{},
        .world_qualified_name = "mock:abi/abi-mock@0.1.0",
    };

    // B's instance type is at world type slot 2.
    const ftr = try findFuncImport(w, 2, "make");
    const cls = classifyFunc(ftr);
    try testing.expect(cls.opts.memory);
    try testing.expect(cls.opts.realloc);
    try testing.expect(cls.opts.string_encoding);
}

test "lowerCoreSig: option<u32> result becomes ret-ptr (i32) -> ()" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inst_decls = try a.alloc(ctypes.Decl, 3);
    inst_decls[0] = .{ .type = .{ .option = .{ .inner = .u32 } } };
    inst_decls[1] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 0 } },
    } } };
    inst_decls[2] = .{ .@"export" = .{ .name = "f", .desc = .{ .func = 1 } } };

    const world = try buildSyntheticWorld(a, inst_decls, 1);
    const ftr = try findFuncImport(world, 0, "f");
    const sig = try lowerCoreSig(a, ftr);
    try testing.expectEqual(@as(usize, 1), sig.params.len);
    try testing.expectEqual(wtypes.ValType.i32, sig.params[0]);
    try testing.expectEqual(@as(usize, 0), sig.results.len);
}

test "lowerCoreSig: 1-flat result keeps 1 result, no extra param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inst_decls = try a.alloc(ctypes.Decl, 2);
    inst_decls[0] = .{ .type = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .u32 },
    } } };
    inst_decls[1] = .{ .@"export" = .{ .name = "f", .desc = .{ .func = 0 } } };

    const world = try buildSyntheticWorld(a, inst_decls, 0);
    const ftr = try findFuncImport(world, 0, "f");
    const sig = try lowerCoreSig(a, ftr);
    try testing.expectEqual(@as(usize, 0), sig.params.len);
    try testing.expectEqual(@as(usize, 1), sig.results.len);
    try testing.expectEqual(wtypes.ValType.i32, sig.results[0]);
}

test "lowerCoreSig: u64 params lower to i64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inst_decls = try a.alloc(ctypes.Decl, 2);
    inst_decls[0] = .{ .type = .{ .func = .{
        .params = &.{ .{ .name = "a", .type = .u64 }, .{ .name = "b", .type = .u32 } },
        .results = .none,
    } } };
    inst_decls[1] = .{ .@"export" = .{ .name = "f", .desc = .{ .func = 0 } } };

    const world = try buildSyntheticWorld(a, inst_decls, 0);
    const ftr = try findFuncImport(world, 0, "f");
    const sig = try lowerCoreSig(a, ftr);
    try testing.expectEqual(@as(usize, 2), sig.params.len);
    try testing.expectEqual(wtypes.ValType.i64, sig.params[0]);
    try testing.expectEqual(wtypes.ValType.i32, sig.params[1]);
}

test "lowerCoreSig: result with option<u64>-bearing variant widens joined slot to i64 (#244)" {
    // Regression for cataggar/wabt#244. The canonical-ABI variant
    // flattening joins each case's payload slot-by-slot with
    // `join(i32, i64) = i64`, so a variant case carrying `option<u64>`
    // forces a joined payload slot to `i64`. This mirrors `wasi:http`
    // `[static]response-outparam.set`'s
    // `result<own<…>, error-code>` param, whose canonical core sig is
    // `(i32 i32 i32 i32 i64 i32 i32 i32 i32)` — wasm-tools/wasmtime
    // require exactly this. The test locks in the `i64` so a future
    // "fix" toward all-`i32` (which would corrupt `u64` payloads) is
    // caught.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // instance body type-index space:
    //   0: option<u64>
    //   1: option<string>
    //   2: variant { none_case, big(option<u64>), str(option<string>) }
    //   3: result<u32, variant#2>
    //   4: func(p0: u32, p1: result#3) -> ()
    //   export "set" -> func 4
    var inst_decls = try a.alloc(ctypes.Decl, 6);
    inst_decls[0] = .{ .type = .{ .option = .{ .inner = .u64 } } };
    inst_decls[1] = .{ .type = .{ .option = .{ .inner = .string } } };
    const cases = try a.alloc(ctypes.Case, 3);
    cases[0] = .{ .name = "none_case", .type = null };
    cases[1] = .{ .name = "big", .type = .{ .type_idx = 0 } };
    cases[2] = .{ .name = "str", .type = .{ .type_idx = 1 } };
    inst_decls[2] = .{ .type = .{ .variant = .{ .cases = cases } } };
    inst_decls[3] = .{ .type = .{ .result = .{ .ok = .u32, .err = .{ .type_idx = 2 } } } };
    const params = try a.alloc(ctypes.NamedValType, 2);
    params[0] = .{ .name = "p0", .type = .u32 };
    params[1] = .{ .name = "p1", .type = .{ .type_idx = 3 } };
    inst_decls[4] = .{ .type = .{ .func = .{ .params = params, .results = .none } } };
    inst_decls[5] = .{ .@"export" = .{ .name = "set", .desc = .{ .func = 4 } } };

    const world = try buildSyntheticWorld(a, inst_decls, 4);
    const ftr = try findFuncImport(world, 0, "set");
    const sig = try lowerCoreSig(a, ftr);

    // p0(u32)=i32; result = disc i32 + joined payload [i32, i32, i64, i32]
    // => [i32, i32, i32, i32, i64, i32]; the i64 lands at index 4.
    const want = [_]wtypes.ValType{ .i32, .i32, .i32, .i32, .i64, .i32 };
    try testing.expectEqual(@as(usize, want.len), sig.params.len);
    try testing.expectEqual(@as(usize, 0), sig.results.len);
    for (want, 0..) |w, idx| try testing.expectEqual(w, sig.params[idx]);
}
