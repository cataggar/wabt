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
};

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
            resolveTypeIdxIn(outer_decls, o.idx, &.{})
        else
            null,
        // `(alias export <inst-idx> <name> (type T))` inside an
        // instance type body would be unusual; we don't try to
        // resolve cross-instance refs here. Treat as opaque.
        .instance_export => null,
    };
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
            const elem_info = if (resolver.resolveLocal(idx)) |td|
                flattenTypeDef(td, resolver, depth + 1)
            else
                FlatInfo{ .flat = 1 };
            break :blk .{
                .flat = 2,
                .needs_memory = true,
                .needs_realloc_alloc = true,
                .contains_string = elem_info.contains_string,
            };
        },
        .type_idx => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            // Likely an outer alias to a resource — treat as i32 handle.
            .{ .flat = 1 },
        .record => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            .{ .flat = 1 },
        .variant => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            .{ .flat = 2 },
        .tuple => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            .{ .flat = 1 },
        .flags => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            .{ .flat = 1 },
        .enum_ => .{ .flat = 1 },
        .option => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            .{ .flat = 2 },
        .result => |idx| if (resolver.resolveLocal(idx)) |td|
            flattenTypeDef(td, resolver, depth + 1)
        else
            .{ .flat = 2 },
    };
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

/// Compute the flat core-wasm signature an indirect import lowers
/// to. Used by the splicer when sizing the shim's trampoline slots
/// (which must match the lowered call's flat repr — params first,
/// then `(memory option)` adds nothing extra to the core sig
/// because `(memory)` is a per-call option, not a param).
///
/// Caveat: when results-flat > MAX_FLAT_RESULTS, the canon ABI
/// passes results through a returned pointer, which means the core
/// sig actually has 0 results and one extra `i32` param (the output
/// pointer). We model that here.
pub fn lowerCoreSig(
    arena: Allocator,
    cls: Classification,
) Error!struct {
    params: []const @import("../../types.zig").ValType,
    results: []const @import("../../types.zig").ValType,
} {
    const wtypes = @import("../../types.zig");
    const params_flat = cls.params_flat;
    const ret_via_pointer = cls.results_flat > MAX_FLAT_RESULTS;

    const total_params: u32 = if (ret_via_pointer)
        saturatingAdd(params_flat, 1)
    else
        params_flat;

    const total_results: u32 = if (ret_via_pointer)
        0
    else
        cls.results_flat;

    const params = try arena.alloc(wtypes.ValType, total_params);
    for (params) |*p| p.* = .i32;

    const results = try arena.alloc(wtypes.ValType, total_results);
    for (results) |*r| r.* = .i32;

    return .{ .params = params, .results = results };
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

test "lowerCoreSig: 2-flat result becomes (i32 in, no out) with output pointer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = try lowerCoreSig(arena.allocator(), .{
        .class = .indirect,
        .opts = .{ .memory = true, .realloc = false, .string_encoding = false },
        .params_flat = 1,
        .results_flat = 2,
        .has_result = true,
    });
    try testing.expectEqual(@as(usize, 2), sig.params.len); // 1 real + 1 ret-ptr
    try testing.expectEqual(@as(usize, 0), sig.results.len);
}

test "lowerCoreSig: 1-flat result keeps 1 result, no extra param" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = try lowerCoreSig(arena.allocator(), .{
        .class = .direct,
        .opts = .{ .memory = false, .realloc = false, .string_encoding = false },
        .params_flat = 0,
        .results_flat = 1,
        .has_result = true,
    });
    try testing.expectEqual(@as(usize, 0), sig.params.len);
    try testing.expectEqual(@as(usize, 1), sig.results.len);
}
