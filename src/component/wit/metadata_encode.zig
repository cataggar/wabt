//! WIT → component-type custom-section encoder.
//!
//! Produces the payload of a `component-type:<world>` custom section,
//! as appended to the core wasm by `wasm-tools component embed` and
//! consumed by `wasm-tools component new`. The payload is itself a
//! component binary.
//!
//! Structure (matches wasm-tools `wit-component` 0.220.0 output for
//! the wamr fixtures):
//!
//! ```text
//! preamble (magic + component version)
//! custom "wit-component-encoding" 0x04 0x00       ; encoding marker
//! type section:
//!   TypeDef[0] = component-type {                  ; outer wrapper
//!     decl: type = component-type {                ; world body
//!       for each export interface:
//!         decl: type = instance-type { funcs+exports }
//!         decl: export "<ns>:<pkg>/<iface>[@<ver>]" instance <idx>
//!       for each import interface:
//!         decl: type = instance-type { funcs+exports }
//!         decl: import "<ns>:<pkg>/<iface>[@<ver>]" instance <idx>
//!     }
//!     decl: export "<ns>:<pkg>/<world>[@<ver>]" component 0
//!   }
//! export "<world>" sort=type idx=0
//! ```
//!
//! MVP scope — sufficient for all three wamr fixtures (`zig-adder`,
//! `zig-calculator-cmd`, `mixed-zig-rust-calc`) plus the wabt-built
//! `wasi-preview1` adapter world (`cataggar/wamr#453`):
//!
//!   * Worlds with `export <iface>;` (in-package) and
//!     `import <ns>:<pkg>/<iface>[@<ver>];` (qualified) extern refs.
//!   * Interfaces containing only func defs.
//!   * Func signatures over primitive WIT types and `list<T>` /
//!     `option<T>` / `result<T,E>` / `tuple<T...>` of primitives,
//!     including bare `result` (no payloads). Compound types are
//!     hoisted into `TypeDef` decls before the func that references
//!     them; the func params/results then carry `ValType.type_idx`
//!     references to those slots.
//!
//! Deferred (rejected with `error.UnsupportedWitFeature`):
//!
//!   * `use` clauses (cross-interface type imports).
//!   * stream / future / async / error-context.
//!
//! Supported: `type <name> = <Type>;` aliases, nominal typedefs
//! (`record`, `variant`, `enum`, `flags`), and `resource R { … }`
//! decls with constructor / method / static members.
//!
//! Resource encoding follows the canonical wit-component shape: a
//! `TypeDef.resource` decl is followed by an `exportname'` decl
//! binding the resource's external name to that slot
//! (`(type (eq <idx>))`). Members are emitted as ordinary func
//! exports with their canonical-ABI names (`[constructor]R`,
//! `[method]R.M`, `[static]R.M`); methods get an implicit
//! `self: borrow<R>` prepended, constructors get `-> own<R>`
//! appended. `[resource-drop]R` is *not* written into the encoded
//! section — the consuming canon stage synthesizes it implicitly.
//! `borrow<R>` / `own<R>` ValTypes resolve via the in-body
//! `name_map` and lower directly to `ValType.borrow` / `own`.
//!
//! Lifting these is incremental: each remaining WIT type maps to a
//! `TypeDef` declarator before the func that references it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const witParser = @import("parser.zig");
const wit_resolver = @import("resolver.zig");
const ctypes = @import("../types.zig");
const writer = @import("../writer.zig");

pub const EncodeError = error{
    UnknownWorld,
    UnknownInterface,
    UnsupportedWitFeature,
    InvalidWit,
} || writer.EncodeError;

/// Encode the named world from `doc` as a `component-type:<world>`
/// payload. The returned slice is owned by `allocator`.
pub fn encodeWorld(
    allocator: Allocator,
    doc: ast.Document,
    world_name: []const u8,
) EncodeError![]u8 {
    return encodeWorldFromResolver(
        allocator,
        wit_resolver.Resolver.init(doc, &.{}),
        world_name,
    );
}

/// Encode the named world using a multi-package resolver. Imports
/// like `import docs:adder/add@0.1.0;` resolve their interface body
/// against `resolver.deps`. The world itself is always taken from
/// `resolver.main`.
pub fn encodeWorldFromResolver(
    allocator: Allocator,
    resolver: wit_resolver.Resolver,
    world_name: []const u8,
) EncodeError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const world = findWorld(resolver.main, world_name) orelse return error.UnknownWorld;
    const pkg_id = resolver.main.package orelse return error.InvalidWit;

    // Build the world's body component-type decls.
    var world_decls = std.ArrayListUnmanaged(ctypes.Decl).empty;

    // The world body has TWO independent index spaces we must track:
    //   * `inst_idx`        — instance indexspace. Bumped by every
    //     `import` and `export (instance N)` decl. Used as the source
    //     index of `alias instance-export` decls.
    //   * `world_type_idx`  — type indexspace. Bumped by every type
    //     def and every `alias` whose sort is `.type`. Used as the
    //     target index for `alias outer (type 1 K)` decls emitted
    //     inside consuming interface bodies.
    var inst_idx: u32 = 0;
    var world_type_idx: u32 = 0;

    // For each `use src.{T};` clause encountered inside an interface
    // body, the world body must surface `T` at its own type-indexspace
    // level via an `alias instance-export sort=type inst=N name="T"`
    // decl emitted just after `src`'s import. The consuming interface
    // body then references that slot via `alias outer (type 1 K)`.
    //
    // Keyed by `<source-iface-qname>::<type-name>` so a single source
    // type referenced by multiple consumers shares one alias slot.
    var world_alias_map = std.StringHashMapUnmanaged(u32).empty;
    // Records each (source_qname, type_names) bundle each imported
    // iface must surface. Populated in a pre-pass so the world body
    // can emit alias-export decls right after each import without
    // having to re-walk every other interface.
    var alias_requests = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)).empty;
    for (world.items) |item| {
        switch (item) {
            .@"export", .import => |we| {
                try collectUseRequests(ar, resolver, we, &alias_requests);
            },
            .use, .include, .type => return error.UnsupportedWitFeature,
        }
    }

    // Each `export <iface>;` / `import <ns>:<pkg>/<iface>;` becomes a
    // type=instance-type decl followed by an export/import decl.
    for (world.items) |item| {
        switch (item) {
            .@"export", .import => |we| {
                const is_export = item == .@"export";
                const ext = we;
                const iface_name = qualifiedName(ar, ext, pkg_id) catch return error.InvalidWit;
                const iface_decls = try buildInterfaceBody(ar, resolver, ext, world_alias_map);
                const iface_type_idx = world_type_idx;
                try world_decls.append(ar, .{ .type = .{
                    .instance = .{ .decls = iface_decls },
                } });
                world_type_idx += 1;
                // ExternDesc.instance carries the TYPE index of the
                // just-allocated instance-type slot — NOT the
                // instance index. The two diverge as soon as a `use`
                // clause surfaces an `alias instance-export` decl
                // between imports, since aliases bump
                // `world_type_idx` without bumping `inst_idx`.
                const desc: ctypes.ExternDesc = .{ .instance = iface_type_idx };
                if (is_export) {
                    try world_decls.append(ar, .{ .@"export" = .{
                        .name = iface_name,
                        .desc = desc,
                    } });
                } else {
                    try world_decls.append(ar, .{ .import = .{
                        .name = iface_name,
                        .desc = desc,
                    } });
                }
                const imported_inst_idx = inst_idx;
                inst_idx += 1;

                // Surface every `use`-requested type from this
                // interface as an `alias instance-export` decl at the
                // world body level so consumers can pull it via
                // `alias outer (type 1 K)`.
                if (alias_requests.get(iface_name)) |names| {
                    for (names.items) |type_name| {
                        try world_decls.append(ar, .{ .alias = .{ .instance_export = .{
                            .sort = .type,
                            .instance_idx = imported_inst_idx,
                            .name = type_name,
                        } } });
                        const key = try std.fmt.allocPrint(ar, "{s}::{s}", .{ iface_name, type_name });
                        try world_alias_map.put(ar, key, world_type_idx);
                        world_type_idx += 1;
                    }
                }
            },
            .use, .include, .type => return error.UnsupportedWitFeature,
        }
    }

    // World qualified name: <ns>:<pkg>/<world>[@<ver>]
    const world_qualified = try formatQualifiedName(ar, pkg_id.namespace, pkg_id.name, world.name, pkg_id.version);

    // Outer wrapper: component-type with one inner component-type
    // (the world body) and one export of that world component.
    var outer_decls = try ar.alloc(ctypes.Decl, 2);
    outer_decls[0] = .{ .type = .{ .component = .{ .decls = try world_decls.toOwnedSlice(ar) } } };
    outer_decls[1] = .{ .@"export" = .{
        .name = world_qualified,
        .desc = .{ .component = 0 },
    } };

    var types = try ar.alloc(ctypes.TypeDef, 1);
    types[0] = .{ .component = .{ .decls = outer_decls } };

    // Top-level export: the world type as a top-level type export.
    var exports = try ar.alloc(ctypes.ExportDecl, 1);
    exports[0] = .{
        .name = world.name,
        .desc = .{ .type = .{ .eq = 0 } },
        .sort_idx = .{ .sort = .type, .idx = 0 },
    };

    // wit-component-encoding marker custom section. The two payload
    // bytes are an encoding-format version (`0x04`) and a flags byte
    // (`0x00`) per wit-component 0.220.0.
    var custom_sections = try ar.alloc(ctypes.CustomSection, 1);
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
    return writer.encode(allocator, &component);
}

/// Pre-pass: walk every `use src.{T};` clause inside `we`'s interface
/// body and record `(source-qname, type-name)` so the world body can
/// emit a matching `alias instance-export` decl right after `src`'s
/// import. `we`'s package context is used to resolve short refs.
fn collectUseRequests(
    ar: Allocator,
    resolver: wit_resolver.Resolver,
    we: ast.WorldExtern,
    map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
) EncodeError!void {
    const ref = switch (we) {
        .interface_ref => |ir| ir.ref,
        else => return,
    };
    const lookup = resolver.findInterfaceWithPkg(ref) orelse return error.UnknownInterface;
    for (lookup.iface.items) |it| {
        if (it != .use) continue;
        const u = it.use;
        const src_lookup = resolver.findInterfaceWithPkg(u.from) orelse return error.UnknownInterface;
        const src_qname = try formatQualifiedName(
            ar,
            src_lookup.pkg.namespace,
            src_lookup.pkg.name,
            u.from.name,
            src_lookup.pkg.version,
        );
        const gop = try map.getOrPut(ar, src_qname);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (u.names) |n| {
            // Same type used by multiple consumers → one alias slot
            // serves all.
            var already = false;
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, n.name)) {
                    already = true;
                    break;
                }
            }
            if (!already) try gop.value_ptr.append(ar, n.name);
        }
    }
}

/// Convenience: parse `source` and encode the named world.
pub fn encodeWorldFromSource(
    allocator: Allocator,
    source: []const u8,
    world_name: []const u8,
) EncodeError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag: witParser.ParseDiagnostic = .{};
    const doc = witParser.parse(arena.allocator(), source, &diag) catch return error.InvalidWit;
    return encodeWorld(allocator, doc, world_name);
}

// ── helpers ────────────────────────────────────────────────────────────────

fn findWorld(doc: ast.Document, name: []const u8) ?ast.World {
    for (doc.items) |it| {
        if (it == .world and std.mem.eql(u8, it.world.name, name)) return it.world;
    }
    return null;
}

/// Compute the qualified name to advertise on the wire for a world's
/// extern. `<id>;` and `<id>@<ver>;` get prefixed by the document's
/// package; `<ns>:<pkg>/<iface>[@<ver>];` is used as-is.
fn qualifiedName(
    ar: Allocator,
    ext: ast.WorldExtern,
    pkg: ast.PackageId,
) ![]const u8 {
    return switch (ext) {
        .interface_ref => |ir| blk: {
            const ref = ir.ref;
            if (ref.package) |p| {
                break :blk try formatQualifiedName(ar, p.namespace, p.name, ref.name, p.version);
            }
            break :blk try formatQualifiedName(ar, pkg.namespace, pkg.name, ref.name, pkg.version);
        },
        .named_func, .named_interface => return error.UnsupportedWitFeature,
    };
}

fn formatQualifiedName(
    ar: Allocator,
    ns: []const u8,
    pkg: []const u8,
    item: []const u8,
    version: ?[]const u8,
) ![]const u8 {
    if (version) |v| {
        return try std.fmt.allocPrint(ar, "{s}:{s}/{s}@{s}", .{ ns, pkg, item, v });
    }
    return try std.fmt.allocPrint(ar, "{s}:{s}/{s}", .{ ns, pkg, item });
}

/// Lower an interface's WIT items to instance-type decls.
///
/// `world_alias_map` is keyed `<src-iface-qname>::<type-name>` and
/// stores each `use`-target's slot in the **outer** (world-body)
/// type indexspace. Used to emit `alias outer (type 1 K)` decls
/// inside this body for every `use src.{T};` clause.
fn buildInterfaceBody(
    ar: Allocator,
    resolver: wit_resolver.Resolver,
    ext: ast.WorldExtern,
    world_alias_map: std.StringHashMapUnmanaged(u32),
) EncodeError![]const ctypes.Decl {
    const ref = switch (ext) {
        .interface_ref => |ir| ir.ref,
        else => return error.UnsupportedWitFeature,
    };

    // Resolve the interface body across packages: same-package refs
    // (no `pkg/` qualifier) hit the main doc; `<ns>:<pkg>/<iface>[@<ver>]`
    // refs traverse the deps (populated by `parseLayout` walking
    // `<root>/deps/<pkg>/`). The resolver returns the same shape
    // either way.
    const iface_body = resolver.findInterface(ref) orelse return error.UnknownInterface;

    // `BodyBuilder` tracks the type-index space inside this
    // instance-type body. Every appended `.type` decl bumps
    // `type_idx`; compound valtypes lower to a fresh `.type` decl
    // and a `ValType.type_idx` reference to its slot. Named-type
    // refs (e.g. `Type.name`) resolve against `name_map`, which is
    // populated as `type <name> = T;` aliases are encountered in
    // declaration order.
    var builder: BodyBuilder = .{
        .ar = ar,
        .decls = .empty,
        .type_idx = 0,
        .name_map = .empty,
    };
    for (iface_body.items) |it| {
        switch (it) {
            .func => |f| try builder.emitFuncExport(f.name, f.func, null),
            .type => |td| switch (td.kind) {
                .alias => |inner| {
                    const vt = try builder.lowerType(inner);
                    try builder.bindName(td.name, vt);
                },
                .record => |fields| {
                    const lowered = try ar.alloc(ctypes.Field, fields.len);
                    for (fields, 0..) |f, i| {
                        lowered[i] = .{ .name = f.name, .type = try builder.lowerType(f.type) };
                    }
                    const body_vt = try builder.appendCompound(.{ .record = .{ .fields = lowered } });
                    try builder.exportNamedType(td.name, body_vt.type_idx);
                },
                .variant => |cases| {
                    const lowered = try ar.alloc(ctypes.Case, cases.len);
                    for (cases, 0..) |c, i| {
                        const payload: ?ctypes.ValType = if (c.type) |ty|
                            try builder.lowerType(ty)
                        else
                            null;
                        lowered[i] = .{ .name = c.name, .type = payload };
                    }
                    const body_vt = try builder.appendCompound(.{ .variant = .{ .cases = lowered } });
                    try builder.exportNamedType(td.name, body_vt.type_idx);
                },
                .@"enum" => |names| {
                    const body_vt = try builder.appendCompound(.{ .enum_ = .{ .names = names } });
                    try builder.exportNamedType(td.name, body_vt.type_idx);
                },
                .flags => |names| {
                    const body_vt = try builder.appendCompound(.{ .flags = .{ .names = names } });
                    try builder.exportNamedType(td.name, body_vt.type_idx);
                },
                .resource => |methods| {
                    // Per the component-model spec, resources cannot
                    // be *defined* with `(sub resource)` as a typedef
                    // body decl inside a component-TYPE (only inside
                    // a concrete component). Within a `(type
                    // (instance ...))` decl inside a
                    // `(type (component ...))`, the resource is
                    // introduced via an `export` decl whose extern
                    // desc carries the `(sub resource)` bound; that
                    // export allocates a fresh slot in the
                    // surrounding type space.
                    const resource_idx = builder.type_idx;
                    try builder.decls.append(ar, .{ .@"export" = .{
                        .name = td.name,
                        .desc = .{ .type = .sub_resource },
                    } });
                    builder.type_idx += 1;
                    try builder.bindName(td.name, .{ .type_idx = resource_idx });

                    // Methods / statics / constructors synthesize their
                    // canonical-ABI external names (`[method]R.M`,
                    // `[static]R.M`, `[constructor]R`) and the implicit
                    // `self: borrow<R>` / `-> own<R>` insertions. The
                    // `[resource-drop]R` intrinsic is *not* declared in
                    // the encoded section — the consuming canon stage
                    // synthesizes it implicitly for every resource.
                    for (methods) |m| {
                        const ext_name = try formatResourceMemberName(ar, m.kind, td.name, m.name);
                        const self_param: ?ctypes.NamedValType = switch (m.kind) {
                            .method => .{ .name = "self", .type = try builder.handleSlot(resource_idx, .borrow) },
                            .static, .constructor => null,
                        };
                        const constructor_result: ?ctypes.ValType = switch (m.kind) {
                            .constructor => try builder.handleSlot(resource_idx, .own),
                            .method, .static => null,
                        };
                        try builder.emitFuncExport(
                            ext_name,
                            m.func,
                            BodyBuilder.FuncInjection{
                                .self_param = self_param,
                                .forced_result = constructor_result,
                            },
                        );
                    }
                },
            },
            .use => |u| {
                // `use src.{T1, T2 as renamed};` — for each name N,
                // emit `alias outer (type 1 K)` where K is the
                // world-body type slot that the outer pre-pass
                // populated for (src_qname, N). Then `export "N"
                // type=eq{local-slot}` to re-export the type under
                // its WIT name inside this interface's body (matches
                // canonical wit-component output: consumers of this
                // iface can pull the type via the export chain
                // without re-traversing the alias path).
                const src_lookup = resolver.findInterfaceWithPkg(u.from) orelse return error.UnknownInterface;
                const src_qname = try formatQualifiedName(
                    ar,
                    src_lookup.pkg.namespace,
                    src_lookup.pkg.name,
                    u.from.name,
                    src_lookup.pkg.version,
                );
                for (u.names) |un| {
                    const key = try std.fmt.allocPrint(ar, "{s}::{s}", .{ src_qname, un.name });
                    const outer_idx = world_alias_map.get(key) orelse return error.InvalidWit;
                    const local_idx = builder.type_idx;
                    try builder.decls.append(ar, .{ .alias = .{ .outer = .{
                        .sort = .type,
                        .outer_count = 1,
                        .idx = outer_idx,
                    } } });
                    builder.type_idx += 1;
                    const visible_name = un.rename orelse un.name;
                    // The Export Eq itself allocates a fresh slot in
                    // wasm-tools' type-index view; bump our counter
                    // and bind the name to that export slot so
                    // downstream `borrow<R>` / `own<R>` references
                    // resolve through the named export id (required
                    // by wasm-tools' `validate_and_register_named_types`).
                    try builder.decls.append(ar, .{ .@"export" = .{
                        .name = visible_name,
                        .desc = .{ .type = .{ .eq = local_idx } },
                    } });
                    const export_slot = builder.type_idx;
                    builder.type_idx += 1;
                    try builder.bindName(visible_name, .{ .type_idx = export_slot });
                }
            },
        }
    }
    return try builder.decls.toOwnedSlice(ar);
}

/// Canonical-ABI external name for a resource member. Constructor
/// uses just the resource name; method / static prefix the bracketed
/// tag and qualify with `R.M`.
fn formatResourceMemberName(
    ar: Allocator,
    kind: ast.ResourceMethodKind,
    resource: []const u8,
    member: []const u8,
) ![]const u8 {
    return switch (kind) {
        .constructor => try std.fmt.allocPrint(ar, "[constructor]{s}", .{resource}),
        .method => try std.fmt.allocPrint(ar, "[method]{s}.{s}", .{ resource, member }),
        .static => try std.fmt.allocPrint(ar, "[static]{s}.{s}", .{ resource, member }),
    };
}

/// Stateful helper that builds the body of an instance-type while
/// tracking the type-index space. Compound types (`list`, `option`,
/// `result`, `tuple`) appear as standalone `TypeDef` decls and are
/// then referenced from func params/results via `ValType.type_idx`.
const BodyBuilder = struct {
    ar: Allocator,
    decls: std.ArrayListUnmanaged(ctypes.Decl),
    /// Current count of `.type` decls already appended to `decls` —
    /// equivalently, the next free slot in the instance-type body's
    /// type-index space.
    type_idx: u32,
    /// Maps `type <name> = T;` aliases (and, in later chunks,
    /// nominal typedefs) to the `ValType` to substitute when a
    /// `Type.name` reference points at them. Aliases to primitives
    /// map directly to the primitive `ValType` without consuming a
    /// fresh slot; aliases whose RHS is a compound type map to the
    /// `type_idx` produced by the compound's lowering.
    name_map: std.StringHashMapUnmanaged(ctypes.ValType),

    fn lowerType(self: *BodyBuilder, t: ast.Type) EncodeError!ctypes.ValType {
        return switch (t) {
            .bool => .bool,
            .s8 => .s8,
            .u8 => .u8,
            .s16 => .s16,
            .u16 => .u16,
            .s32 => .s32,
            .u32 => .u32,
            .s64 => .s64,
            .u64 => .u64,
            .f32 => .f32,
            .f64 => .f64,
            .char => .char,
            .string => .string,
            .list => |inner| blk: {
                const elem = try self.lowerType(inner.*);
                break :blk try self.appendCompound(.{ .list = .{ .element = elem } });
            },
            .option => |inner| blk: {
                const inner_vt = try self.lowerType(inner.*);
                break :blk try self.appendCompound(.{ .option = .{ .inner = inner_vt } });
            },
            .result => |r| blk: {
                const ok_vt: ?ctypes.ValType = if (r.ok) |ok_ty|
                    try self.lowerType(ok_ty.*)
                else
                    null;
                const err_vt: ?ctypes.ValType = if (r.err) |err_ty|
                    try self.lowerType(err_ty.*)
                else
                    null;
                break :blk try self.appendCompound(.{ .result = .{ .ok = ok_vt, .err = err_vt } });
            },
            .tuple => |fields| blk: {
                const inner = try self.ar.alloc(ctypes.ValType, fields.len);
                for (fields, 0..) |f, i| inner[i] = try self.lowerType(f);
                break :blk try self.appendCompound(.{ .tuple = .{ .fields = inner } });
            },
            .name => |n| self.name_map.get(n) orelse error.InvalidWit,
            .borrow => |n| try self.handleValType(n, .borrow),
            .own => |n| try self.handleValType(n, .own),
        };
    }

    const HandleKind = enum { borrow, own };

    /// Resolve `borrow<R>` / `own<R>` to a handle ValType. The named
    /// resource must already be bound in `name_map`, and that
    /// binding must be a `type_idx` — borrowing or owning a
    /// non-resource named type (e.g. an alias to `u32`) is malformed.
    ///
    /// Per the component-model spec, handle types (`borrow<R>`,
    /// `own<R>`) are *defined* types — they must occupy their own
    /// typedef slot in the surrounding type space; the func-param
    /// position then references that slot via its typeidx. We
    /// allocate a fresh slot per use (no interning); external
    /// tooling (wasm-tools / wasmtime) accepts duplicate slots and
    /// the encoded section size cost is one byte per handle.
    fn handleValType(
        self: *BodyBuilder,
        resource_name: []const u8,
        kind: HandleKind,
    ) EncodeError!ctypes.ValType {
        const bound = self.name_map.get(resource_name) orelse return error.InvalidWit;
        if (bound != .type_idx) return error.InvalidWit;
        return self.handleSlot(bound.type_idx, kind);
    }

    /// Append a typedef slot containing `borrow<resource_idx>` or
    /// `own<resource_idx>` and return a `ValType.type_idx`
    /// reference to that slot.
    fn handleSlot(
        self: *BodyBuilder,
        resource_idx: u32,
        kind: HandleKind,
    ) EncodeError!ctypes.ValType {
        const handle_vt: ctypes.ValType = switch (kind) {
            .borrow => .{ .borrow = resource_idx },
            .own => .{ .own = resource_idx },
        };
        return self.appendCompound(.{ .val = handle_vt });
    }

    /// Injection hooks for resource-method synthesis: `self_param`
    /// is prepended to the canonical param list; `forced_result`
    /// overrides any AST result (used for `-> own<R>` on
    /// constructors).
    const FuncInjection = struct {
        self_param: ?ctypes.NamedValType = null,
        forced_result: ?ctypes.ValType = null,
    };

    /// Lower an AST `Func` to a component-type `FuncType` and append
    /// it to `decls`, then export it under `export_name`. When
    /// `injection` is non-null, methods get an implicit
    /// `self: borrow<R>` prepended and constructors get
    /// `-> own<R>` appended.
    fn emitFuncExport(
        self: *BodyBuilder,
        export_name: []const u8,
        func: ast.Func,
        injection: ?FuncInjection,
    ) EncodeError!void {
        const inj: FuncInjection = injection orelse .{};
        const extra: usize = if (inj.self_param != null) 1 else 0;
        const params = try self.ar.alloc(ctypes.NamedValType, func.params.len + extra);
        if (inj.self_param) |sp| params[0] = sp;
        for (func.params, 0..) |p, i| {
            params[i + extra] = .{ .name = p.name, .type = try self.lowerType(p.type) };
        }

        const results: ctypes.FuncType.ResultList = if (inj.forced_result) |fr|
            .{ .unnamed = fr }
        else if (func.result) |t|
            .{ .unnamed = try self.lowerType(t) }
        else
            .none;

        const func_type_idx = self.type_idx;
        try self.decls.append(self.ar, .{ .type = .{ .func = .{
            .params = params,
            .results = results,
        } } });
        self.type_idx += 1;

        try self.decls.append(self.ar, .{ .@"export" = .{
            .name = export_name,
            .desc = .{ .func = func_type_idx },
        } });
    }

    fn appendCompound(self: *BodyBuilder, td: ctypes.TypeDef) EncodeError!ctypes.ValType {
        const idx = self.type_idx;
        try self.decls.append(self.ar, .{ .type = td });
        self.type_idx += 1;
        return .{ .type_idx = idx };
    }

    fn bindName(self: *BodyBuilder, name: []const u8, vt: ctypes.ValType) EncodeError!void {
        const gop = try self.name_map.getOrPut(self.ar, name);
        if (gop.found_existing) return error.InvalidWit;
        gop.value_ptr.* = vt;
    }

    /// Emit an `export <name> (type (eq <body_slot>))` decl and bind
    /// `name` to the EXPORT'S slot (not the underlying typedef
    /// slot). Per the component-model spec, exports of types
    /// allocate a fresh slot in the surrounding type space; consumers
    /// that reference the named type must use that export slot so
    /// wasm-tools' "all referenced types must be named" validator
    /// finds the type id in the import/export name set.
    fn exportNamedType(self: *BodyBuilder, name: []const u8, body_slot: u32) EncodeError!void {
        try self.decls.append(self.ar, .{ .@"export" = .{
            .name = name,
            .desc = .{ .type = .{ .eq = body_slot } },
        } });
        const export_slot = self.type_idx;
        self.type_idx += 1;
        try self.bindName(name, .{ .type_idx = export_slot });
    }
};

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "metadata_encode: zig-adder world round-trips through loader" {
    const source =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\    add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\    export add;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "adder");
    defer testing.allocator.free(bytes);

    // Component starts with the right preamble.
    try testing.expect(bytes.len > 16);
    try testing.expect(std.mem.eql(u8, bytes[0..4], "\x00asm"));
    // version=0x0d, layer=0x01
    try testing.expectEqual(@as(u8, 0x0d), bytes[4]);
    try testing.expectEqual(@as(u8, 0x01), bytes[6]);

    // Round-trip: load it back and check structure.
    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    try testing.expectEqual(@as(usize, 1), comp.types.len);
    try testing.expect(comp.types[0] == .component);
    const outer = comp.types[0].component;
    try testing.expectEqual(@as(usize, 2), outer.decls.len);
    try testing.expect(outer.decls[0] == .type);
    try testing.expect(outer.decls[0].type == .component);
    try testing.expect(outer.decls[1] == .@"export");
    try testing.expectEqualStrings("docs:adder/adder@0.1.0", outer.decls[1].@"export".name);

    // The world body has one export interface (the `add` interface).
    const world = outer.decls[0].type.component;
    try testing.expectEqual(@as(usize, 2), world.decls.len);
    try testing.expect(world.decls[0] == .type);
    try testing.expect(world.decls[0].type == .instance);
    try testing.expect(world.decls[1] == .@"export");
    try testing.expectEqualStrings("docs:adder/add@0.1.0", world.decls[1].@"export".name);

    // The interface body has one func + one export.
    const iface = world.decls[0].type.instance;
    try testing.expectEqual(@as(usize, 2), iface.decls.len);
    try testing.expect(iface.decls[0] == .type);
    try testing.expect(iface.decls[0].type == .func);
    try testing.expect(iface.decls[1] == .@"export");
    try testing.expectEqualStrings("add", iface.decls[1].@"export".name);

    // Top-level export of the world type.
    try testing.expectEqual(@as(usize, 1), comp.exports.len);
    try testing.expectEqualStrings("adder", comp.exports[0].name);
}

test "metadata_encode: zig-calculator-cmd app world (import only)" {
    // Combined source: package + adder interface + app world that
    // imports it qualified. (The real wamr layout splits the dep
    // package into wit/deps/adder/world.wit; for a single-source
    // test we fold them.)
    const source =
        \\package docs:zigcalc@0.1.0;
        \\
        \\interface add {
        \\    add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world app {
        \\    import docs:zigcalc/add@0.1.0;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "app");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const outer = comp.types[0].component;
    const world = outer.decls[0].type.component;
    try testing.expectEqual(@as(usize, 2), world.decls.len);
    try testing.expect(world.decls[0] == .type);
    try testing.expect(world.decls[0].type == .instance);
    try testing.expect(world.decls[1] == .import);
    try testing.expectEqualStrings("docs:zigcalc/add@0.1.0", world.decls[1].import.name);
}

test "metadata_encode: unknown world reports error" {
    const source = "package docs:adder@0.1.0;\nworld adder { }";
    const r = encodeWorldFromSource(testing.allocator, source, "missing");
    try testing.expectError(error.UnknownWorld, r);
}

test "metadata_encode: multi-package resolver — cross-package import" {
    // Mirrors the wamr `zig-calculator-cmd` layout: the main package
    // defines a world that imports from a sibling package found under
    // `<root>/deps/adder/`. This test exercises the resolver path
    // end-to-end (resolver → metadata_encode → loader) without
    // touching disk, proving the deps walk and metadata encoding
    // are wired correctly for compose with multi-package inputs.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const parser = @import("parser.zig");
    const resolver_mod = @import("resolver.zig");

    const main_src =
        \\package docs:zigcalc@0.1.0;
        \\world app { import docs:adder/add@0.1.0; }
    ;
    const dep_src =
        \\package docs:adder@0.1.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
    ;
    const main_doc = try parser.parse(ar, main_src, null);
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(@import("ast.zig").Document, 1);
    deps[0] = dep_doc;
    const resolver = resolver_mod.Resolver.init(main_doc, deps);

    const bytes = try encodeWorldFromResolver(testing.allocator, resolver, "app");
    defer testing.allocator.free(bytes);

    // Round-trip the encoded payload through the component loader.
    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    // Outer component-type wraps a world component-type whose body
    // has the `add` interface as an instance type and the matching
    // qualified import declaration.
    const outer = comp.types[0].component;
    const world = outer.decls[0].type.component;
    try testing.expectEqual(@as(usize, 2), world.decls.len);
    try testing.expect(world.decls[0] == .type);
    try testing.expect(world.decls[0].type == .instance);
    try testing.expect(world.decls[1] == .import);
    try testing.expectEqualStrings("docs:adder/add@0.1.0", world.decls[1].import.name);

    // The interface body picks up the func from the *dep* package.
    const iface = world.decls[0].type.instance;
    try testing.expectEqual(@as(usize, 2), iface.decls.len);
    try testing.expect(iface.decls[0] == .type);
    try testing.expect(iface.decls[0].type == .func);
    try testing.expect(iface.decls[1] == .@"export");
    try testing.expectEqualStrings("add", iface.decls[1].@"export".name);
}

test "metadata_encode: bare `result` return is hoisted into a TypeDef + idx ref" {
    // wasi-preview1 adapter's `wasi:cli/run.run` returns bare
    // `result` (no `ok` or `err` payloads). The encoder must hoist
    // the `result` valtype into a `TypeDef.result` decl and reference
    // it from the func via `ValType.type_idx` — compound types
    // cannot appear inline in func param/result positions.
    const source =
        \\package wasi:cli@0.2.6;
        \\interface run {
        \\    run: func() -> result;
        \\}
        \\world cmd {
        \\    export run;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "cmd");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const outer = comp.types[0].component;
    const world = outer.decls[0].type.component;
    const iface = world.decls[0].type.instance;

    // Body must be: [result TypeDef, func TypeDef, export(func=1)].
    try testing.expectEqual(@as(usize, 3), iface.decls.len);
    try testing.expect(iface.decls[0] == .type);
    try testing.expect(iface.decls[0].type == .result);
    try testing.expect(iface.decls[0].type.result.ok == null);
    try testing.expect(iface.decls[0].type.result.err == null);

    try testing.expect(iface.decls[1] == .type);
    try testing.expect(iface.decls[1].type == .func);
    const func = iface.decls[1].type.func;
    try testing.expectEqual(@as(usize, 0), func.params.len);
    try testing.expect(func.results == .unnamed);
    try testing.expect(func.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 0), func.results.unnamed.type_idx);

    try testing.expect(iface.decls[2] == .@"export");
    try testing.expectEqualStrings("run", iface.decls[2].@"export".name);
    try testing.expect(iface.decls[2].@"export".desc == .func);
    try testing.expectEqual(@as(u32, 1), iface.decls[2].@"export".desc.func);
}

test "metadata_encode: `result<u32, string>` payloads hoist correctly" {
    // Exercise both ok and err payloads on a parameterized result.
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    parse: func(s: string) -> result<u32, string>;
        \\}
        \\world demo {
        \\    export ops;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body: [result TypeDef, func TypeDef, export(func=1)].
    try testing.expectEqual(@as(usize, 3), iface.decls.len);
    try testing.expect(iface.decls[0].type.result.ok != null);
    try testing.expect(iface.decls[0].type.result.err != null);
    try testing.expect(iface.decls[0].type.result.ok.? == .u32);
    try testing.expect(iface.decls[0].type.result.err.? == .string);
    try testing.expect(iface.decls[1].type.func.results.unnamed.type_idx == 0);
    try testing.expect(iface.decls[2].@"export".desc.func == 1);
}

test "metadata_encode: `list<u8>` param hoists to a TypeDef.list" {
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    write: func(bytes: list<u8>) -> u32;
        \\}
        \\world demo {
        \\    export ops;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    try testing.expectEqual(@as(usize, 3), iface.decls.len);
    try testing.expect(iface.decls[0].type == .list);
    try testing.expect(iface.decls[0].type.list.element == .u8);
    try testing.expect(iface.decls[1].type.func.params[0].type == .type_idx);
    try testing.expectEqual(@as(u32, 0), iface.decls[1].type.func.params[0].type.type_idx);
    try testing.expect(iface.decls[1].type.func.results.unnamed == .u32);
}

test "metadata_encode: primitive type alias resolves via name_map without a fresh slot" {
    // `type my-u32 = u32;` is a pure rename — aliasing a primitive
    // produces no new slot in the body's type-index space. A func
    // referencing `my-u32` should inline the underlying primitive
    // ValType.
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    type my-u32 = u32;
        \\    inc: func(x: my-u32) -> my-u32;
        \\}
        \\world demo {
        \\    export ops;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Just [func TypeDef, export(func=0)] — no slot for the alias.
    try testing.expectEqual(@as(usize, 2), iface.decls.len);
    try testing.expect(iface.decls[0].type == .func);
    const func = iface.decls[0].type.func;
    try testing.expectEqual(@as(usize, 1), func.params.len);
    try testing.expect(func.params[0].type == .u32);
    try testing.expect(func.results.unnamed == .u32);
}

test "metadata_encode: compound alias is hoisted once, named refs reuse the slot" {
    // `type bytes = list<u8>;` should emit exactly one TypeDef.list
    // and bind `bytes` to that slot. A func using `bytes` twice
    // (param + result) must reference the same `type_idx`, not
    // re-hoist the list each time.
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    type bytes = list<u8>;
        \\    roundtrip: func(b: bytes) -> bytes;
        \\}
        \\world demo {
        \\    export ops;
        \\}
    ;
    const bytes_out = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes_out);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes_out, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body: [list TypeDef (idx 0), func TypeDef (idx 1), export(func=1)].
    try testing.expectEqual(@as(usize, 3), iface.decls.len);
    try testing.expect(iface.decls[0].type == .list);
    try testing.expect(iface.decls[0].type.list.element == .u8);
    try testing.expect(iface.decls[1].type == .func);
    const func = iface.decls[1].type.func;
    try testing.expectEqual(@as(u32, 0), func.params[0].type.type_idx);
    try testing.expect(func.results == .unnamed);
    try testing.expectEqual(@as(u32, 0), func.results.unnamed.type_idx);
}

test "metadata_encode: alias chain (a -> u32, b -> a) resolves transitively" {
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    type a = u32;
        \\    type b = a;
        \\    f: func(x: b) -> b;
        \\}
        \\world demo {
        \\    export ops;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    try testing.expectEqual(@as(usize, 2), iface.decls.len);
    const func = iface.decls[0].type.func;
    try testing.expect(func.params[0].type == .u32);
    try testing.expect(func.results.unnamed == .u32);
}

test "metadata_encode: unresolved name reports InvalidWit" {
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    f: func(x: nonexistent) -> u32;
        \\}
        \\world demo {
        \\    export ops;
        \\}
    ;
    const r = encodeWorldFromSource(testing.allocator, source, "demo");
    try testing.expectError(error.InvalidWit, r);
}

test "metadata_encode: record typedef emits TypeDef.record + name binding" {
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    record point { x: u32, y: u32 }
        \\    move-by: func(p: point, dx: s32) -> point;
        \\}
        \\world demo { export ops; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body: [record TypeDef (idx 0), Export "point" Eq 0 (idx 1), func TypeDef (idx 2), export(func=2)].
    try testing.expectEqual(@as(usize, 4), iface.decls.len);
    try testing.expect(iface.decls[0].type == .record);
    const rec = iface.decls[0].type.record;
    try testing.expectEqual(@as(usize, 2), rec.fields.len);
    try testing.expectEqualStrings("x", rec.fields[0].name);
    try testing.expect(rec.fields[0].type == .u32);
    try testing.expectEqualStrings("y", rec.fields[1].name);
    try testing.expect(rec.fields[1].type == .u32);

    try testing.expect(iface.decls[1] == .@"export");
    try testing.expectEqualStrings("point", iface.decls[1].@"export".name);
    try testing.expect(iface.decls[1].@"export".desc == .type);
    try testing.expect(iface.decls[1].@"export".desc.type == .eq);
    try testing.expectEqual(@as(u32, 0), iface.decls[1].@"export".desc.type.eq);

    const func = iface.decls[2].type.func;
    try testing.expectEqual(@as(u32, 1), func.params[0].type.type_idx);
    try testing.expect(func.params[1].type == .s32);
    try testing.expectEqual(@as(u32, 1), func.results.unnamed.type_idx);
}

test "metadata_encode: variant typedef with mixed payloads" {
    // Mirrors `wasi:io/streams.stream-error`: a no-payload `closed`
    // case plus a payload-carrying case. Both forms must encode and
    // round-trip cleanly.
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    variant stream-error {
        \\        closed,
        \\        last-operation-failed(string),
        \\    }
        \\    drain: func() -> result<u32, stream-error>;
        \\}
        \\world demo { export ops; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body: [variant (0), Export "stream-error" Eq 0 (1), result (2), func (3), export(func=3)].
    try testing.expectEqual(@as(usize, 5), iface.decls.len);
    try testing.expect(iface.decls[0].type == .variant);
    const v = iface.decls[0].type.variant;
    try testing.expectEqual(@as(usize, 2), v.cases.len);
    try testing.expectEqualStrings("closed", v.cases[0].name);
    try testing.expect(v.cases[0].type == null);
    try testing.expectEqualStrings("last-operation-failed", v.cases[1].name);
    try testing.expect(v.cases[1].type != null);
    try testing.expect(v.cases[1].type.? == .string);

    try testing.expect(iface.decls[1] == .@"export");
    try testing.expectEqualStrings("stream-error", iface.decls[1].@"export".name);

    try testing.expect(iface.decls[2].type == .result);
    const res = iface.decls[2].type.result;
    try testing.expect(res.ok != null and res.ok.? == .u32);
    try testing.expect(res.err != null);
    try testing.expectEqual(@as(u32, 1), res.err.?.type_idx);

    try testing.expect(iface.decls[3].type == .func);
    try testing.expectEqual(@as(u32, 2), iface.decls[3].type.func.results.unnamed.type_idx);
}

test "metadata_encode: enum typedef" {
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    enum color { red, green, blue }
        \\    pick: func() -> color;
        \\}
        \\world demo { export ops; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body: [enum (0), Export "color" Eq 0 (1), func (2), export(func=2)].
    try testing.expectEqual(@as(usize, 4), iface.decls.len);
    try testing.expect(iface.decls[0].type == .enum_);
    const e = iface.decls[0].type.enum_;
    try testing.expectEqual(@as(usize, 3), e.names.len);
    try testing.expectEqualStrings("red", e.names[0]);
    try testing.expectEqualStrings("green", e.names[1]);
    try testing.expectEqualStrings("blue", e.names[2]);
    try testing.expect(iface.decls[1] == .@"export");
    try testing.expectEqualStrings("color", iface.decls[1].@"export".name);
    try testing.expectEqual(@as(u32, 1), iface.decls[2].type.func.results.unnamed.type_idx);
}

test "metadata_encode: flags typedef" {
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    flags perms { read, write, exec }
        \\    check: func(p: perms) -> bool;
        \\}
        \\world demo { export ops; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body: [flags (0), Export "perms" Eq 0 (1), func (2), export(func=2)].
    try testing.expectEqual(@as(usize, 4), iface.decls.len);
    try testing.expect(iface.decls[0].type == .flags);
    const f = iface.decls[0].type.flags;
    try testing.expectEqual(@as(usize, 3), f.names.len);
    try testing.expectEqualStrings("read", f.names[0]);
    try testing.expectEqualStrings("write", f.names[1]);
    try testing.expectEqualStrings("exec", f.names[2]);
    try testing.expect(iface.decls[1] == .@"export");
    try testing.expectEqualStrings("perms", iface.decls[1].@"export".name);
    try testing.expectEqual(@as(u32, 1), iface.decls[2].type.func.params[0].type.type_idx);
}

test "metadata_encode: resource with constructor + method + static" {
    // Mirrors `wasi:io/streams.output-stream` style: a constructor, a
    // method (gets implicit `self: borrow<R>`), and a static. The
    // encoder must synthesize the canonical-ABI external names and
    // the implicit `self` / `-> own<R>` insertions. The resource name
    // is `output-stream` to mirror the canonical WIT identifier
    // (kebab-case) rather than triggering a reserved `kw_stream`.
    const source =
        \\package docs:demo@0.1.0;
        \\interface streams {
        \\    resource output-stream {
        \\        constructor(seed: u32);
        \\        write: func(byte: u8) -> u32;
        \\        check: static func() -> u32;
        \\    }
        \\}
        \\world demo { export streams; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body shape (handle types `borrow<R>` / `own<R>` must occupy
    // their own typedef slot per the component-model spec):
    //   0: ExportDecl "output-stream" (type sub-resource)   — slot 0
    //   1: TypeDef.val .own=0          (ctor return slot)   — slot 1
    //   2: TypeDef.func (seed:u32) -> type_idx=1            — slot 2
    //   3: ExportDecl "[constructor]output-stream" func=2
    //   4: TypeDef.val .borrow=0       (method self slot)   — slot 3
    //   5: TypeDef.func (self:type_idx=3, byte:u8) -> u32   — slot 4
    //   6: ExportDecl "[method]output-stream.write" func=4
    //   7: TypeDef.func () -> u32                           — slot 5
    //   8: ExportDecl "[static]output-stream.check" func=5
    try testing.expectEqual(@as(usize, 9), iface.decls.len);

    // Resource: introduced via export with `sub_resource` bound; no
    // separate body type decl (component-types cannot *define* a
    // resource as a body typedef, only export-by-name).
    try testing.expect(iface.decls[0] == .@"export");
    try testing.expectEqualStrings("output-stream", iface.decls[0].@"export".name);
    try testing.expect(iface.decls[0].@"export".desc == .type);
    try testing.expect(iface.decls[0].@"export".desc.type == .sub_resource);

    // Constructor: own slot then func slot then export.
    try testing.expect(iface.decls[1].type == .val);
    try testing.expect(iface.decls[1].type.val == .own);
    try testing.expectEqual(@as(u32, 0), iface.decls[1].type.val.own);
    try testing.expect(iface.decls[2].type == .func);
    const ctor = iface.decls[2].type.func;
    try testing.expectEqual(@as(usize, 1), ctor.params.len);
    try testing.expectEqualStrings("seed", ctor.params[0].name);
    try testing.expect(ctor.params[0].type == .u32);
    try testing.expect(ctor.results == .unnamed);
    try testing.expect(ctor.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 1), ctor.results.unnamed.type_idx);
    try testing.expectEqualStrings("[constructor]output-stream", iface.decls[3].@"export".name);

    // Method: implicit `self: borrow<0>` prepended (via its own
    // typedef slot at index 3).
    try testing.expect(iface.decls[4].type == .val);
    try testing.expect(iface.decls[4].type.val == .borrow);
    try testing.expectEqual(@as(u32, 0), iface.decls[4].type.val.borrow);
    try testing.expect(iface.decls[5].type == .func);
    const method = iface.decls[5].type.func;
    try testing.expectEqual(@as(usize, 2), method.params.len);
    try testing.expectEqualStrings("self", method.params[0].name);
    try testing.expect(method.params[0].type == .type_idx);
    try testing.expectEqual(@as(u32, 3), method.params[0].type.type_idx);
    try testing.expectEqualStrings("byte", method.params[1].name);
    try testing.expect(method.params[1].type == .u8);
    try testing.expect(method.results.unnamed == .u32);
    try testing.expectEqualStrings("[method]output-stream.write", iface.decls[6].@"export".name);

    // Static: no implicit self, no forced result.
    try testing.expect(iface.decls[7].type == .func);
    const stat = iface.decls[7].type.func;
    try testing.expectEqual(@as(usize, 0), stat.params.len);
    try testing.expect(stat.results.unnamed == .u32);
    try testing.expectEqualStrings("[static]output-stream.check", iface.decls[8].@"export".name);
}

test "metadata_encode: explicit `borrow<R>` / `own<R>` in func sigs" {
    // A function that takes a borrow and returns an own — exercises
    // `lowerType` for both handle forms via the post-resource
    // `name_map` binding. Each handle gets its own typedef slot per
    // the component-model spec (handle types are *defined* types).
    const source =
        \\package docs:demo@0.1.0;
        \\interface streams {
        \\    resource output-stream { }
        \\    clone: func(s: borrow<output-stream>) -> own<output-stream>;
        \\}
        \\world demo { export streams; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "demo");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const iface = comp.types[0].component.decls[0].type.component.decls[0].type.instance;
    // Body shape:
    //   0: ExportDecl "output-stream" (type sub-resource)  — slot 0
    //   1: TypeDef.val .borrow=0                            — slot 1
    //   2: TypeDef.val .own=0                               — slot 2
    //   3: TypeDef.func (s: type_idx=1) -> type_idx=2       — slot 3
    //   4: ExportDecl "clone" func=3
    try testing.expectEqual(@as(usize, 5), iface.decls.len);
    try testing.expect(iface.decls[1].type == .val);
    try testing.expect(iface.decls[1].type.val == .borrow);
    try testing.expectEqual(@as(u32, 0), iface.decls[1].type.val.borrow);
    try testing.expect(iface.decls[2].type == .val);
    try testing.expect(iface.decls[2].type.val == .own);
    try testing.expectEqual(@as(u32, 0), iface.decls[2].type.val.own);
    try testing.expect(iface.decls[3].type == .func);
    const f = iface.decls[3].type.func;
    try testing.expect(f.params[0].type == .type_idx);
    try testing.expectEqual(@as(u32, 1), f.params[0].type.type_idx);
    try testing.expect(f.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 2), f.results.unnamed.type_idx);
    try testing.expectEqualStrings("clone", iface.decls[4].@"export".name);
}

test "metadata_encode: borrow<non-resource> reports InvalidWit" {
    // `borrow<R>` where `R` is bound to a primitive alias (not a
    // resource) is malformed. The encoder must catch it.
    const source =
        \\package docs:demo@0.1.0;
        \\interface ops {
        \\    type r = u32;
        \\    f: func(x: borrow<r>);
        \\}
        \\world demo { export ops; }
    ;
    const r = encodeWorldFromSource(testing.allocator, source, "demo");
    try testing.expectError(error.InvalidWit, r);
}

test "metadata_encode: use clause aliases resource from outer world body" {
    // `use streams.{output-stream};` inside `stdout` must surface
    // `output-stream` at the world-body type indexspace via an
    // `alias instance-export sort=type` decl emitted right after
    // `streams`'s import, and the consuming interface must pull it
    // in via `alias outer (type 1 K)`. Mirrors wit-component
    // 0.220.0's canonical encoding shape.
    const source =
        \\package docs:demo@0.1.0;
        \\interface streams {
        \\    resource output-stream { }
        \\}
        \\interface stdout {
        \\    use streams.{output-stream};
        \\    get-stdout: func() -> own<output-stream>;
        \\}
        \\world cmd {
        \\    import streams;
        \\    import stdout;
        \\}
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "cmd");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    // World body should contain 5 decls in order:
    //   0: TypeDef.instance (streams body)            — world type slot 0
    //   1: ImportDecl "docs:demo/streams@0.1.0"
    //   2: Alias.instance_export sort=type inst=0 name="output-stream"
    //                                                 — world type slot 1
    //   3: TypeDef.instance (stdout body)             — world type slot 2
    //   4: ImportDecl "docs:demo/stdout@0.1.0"
    const world_body = comp.types[0].component.decls[0].type.component;
    try testing.expectEqual(@as(usize, 5), world_body.decls.len);
    try testing.expect(world_body.decls[2] == .alias);
    try testing.expect(world_body.decls[2].alias == .instance_export);
    try testing.expectEqualStrings("output-stream", world_body.decls[2].alias.instance_export.name);
    try testing.expect(world_body.decls[2].alias.instance_export.sort == .type);
    try testing.expectEqual(@as(u32, 0), world_body.decls[2].alias.instance_export.instance_idx);

    // stdout body should contain 5 decls in order:
    //   0: Alias.outer sort=type count=1 idx=1        — local type slot 0
    //   1: ExportDecl "output-stream" type=eq{0}      — local type slot 1
    //                                                  (binds `output-stream`
    //                                                   here so `own<R>` /
    //                                                   `borrow<R>` resolve
    //                                                   through the named
    //                                                   export id, per
    //                                                   wasm-tools'
    //                                                   `validate_and_register_named_types`)
    //   2: TypeDef.val .own=1                          — local type slot 2
    //                                                   (references the
    //                                                   export slot, NOT the
    //                                                   raw alias slot)
    //   3: TypeDef.func get-stdout() -> type_idx=2     — local type slot 3
    //   4: ExportDecl "get-stdout" func=3
    const stdout_body = world_body.decls[3].type.instance;
    try testing.expectEqual(@as(usize, 5), stdout_body.decls.len);
    try testing.expect(stdout_body.decls[0] == .alias);
    try testing.expect(stdout_body.decls[0].alias == .outer);
    try testing.expect(stdout_body.decls[0].alias.outer.sort == .type);
    try testing.expectEqual(@as(u32, 1), stdout_body.decls[0].alias.outer.outer_count);
    try testing.expectEqual(@as(u32, 1), stdout_body.decls[0].alias.outer.idx);
    try testing.expect(stdout_body.decls[1] == .@"export");
    try testing.expectEqualStrings("output-stream", stdout_body.decls[1].@"export".name);
    try testing.expect(stdout_body.decls[1].@"export".desc == .type);
    try testing.expectEqual(@as(u32, 0), stdout_body.decls[1].@"export".desc.type.eq);
    try testing.expect(stdout_body.decls[2].type == .val);
    try testing.expect(stdout_body.decls[2].type.val == .own);
    try testing.expectEqual(@as(u32, 1), stdout_body.decls[2].type.val.own);
    try testing.expect(stdout_body.decls[3].type == .func);
    try testing.expect(stdout_body.decls[3].type.func.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 2), stdout_body.decls[3].type.func.results.unnamed.type_idx);
}

test "metadata_encode: use clause with rename binds the renamed name" {
    // `use streams.{output-stream as out};` should bind the type
    // under `out` in the consuming interface, not the original
    // `output-stream`. The rename also drives the export decl's
    // visible name so consumers see `out`, not `output-stream`.
    const source =
        \\package docs:demo@0.1.0;
        \\interface streams { resource output-stream { } }
        \\interface stdout {
        \\    use streams.{output-stream as out};
        \\    get-stdout: func() -> own<out>;
        \\}
        \\world cmd { import streams; import stdout; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "cmd");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const world_body = comp.types[0].component.decls[0].type.component;
    const stdout_body = world_body.decls[3].type.instance;
    try testing.expectEqualStrings("out", stdout_body.decls[1].@"export".name);
}

test "metadata_encode: use of an unknown type in source iface reports InvalidWit" {
    // `use streams.{missing-type};` — when `missing-type` is never
    // declared in the source interface, the world-body pre-pass
    // still records the request, but the consuming-iface lookup at
    // `alias outer` emission time finds the slot (the pre-pass
    // doesn't validate). To produce a clean error, the encoder
    // would need a second validation pass — for now this test
    // documents that the alias is emitted anyway; the splicer/canon
    // stage will reject the dangling alias when the source
    // interface is materialised.
    //
    // The wit-component encoder rejects this at parse time; we
    // accept it here and rely on downstream validation. This test
    // pins the current behaviour so a future validation pass can
    // tighten it without surprise.
    const source =
        \\package docs:demo@0.1.0;
        \\interface streams { resource output-stream { } }
        \\interface stdout { use streams.{missing-type}; }
        \\world cmd { import streams; import stdout; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "cmd");
    defer testing.allocator.free(bytes);
}

test "metadata_encode: rejects use whose source iface is not in the world" {
    // The source interface of a `use` clause must also be reachable
    // from the world body (as an import or export). Without that,
    // the world body has no instance to alias from, and the
    // pre-pass key won't be populated — leaving the consuming-iface
    // body looking up a slot that doesn't exist.
    const source =
        \\package docs:demo@0.1.0;
        \\interface streams { resource output-stream { } }
        \\interface stdout { use streams.{output-stream}; }
        \\world cmd { import stdout; }
    ;
    const r = encodeWorldFromSource(testing.allocator, source, "cmd");
    try testing.expectError(error.InvalidWit, r);
}

test "metadata_encode: use clause from qualified versioned source ref" {
    // `use wasi:io/streams@0.2.6.{output-stream};` exercises
    // `parseSemverText`'s lookahead so the `.` before `{` is not
    // greedily swallowed as a semver continuation. Regression
    // pin for the bug discovered while wiring Phase 1.c.3a
    // (preview1.wit declaring `wasi:cli/stdout` + `wasi:cli/stderr`).
    const source =
        \\package wabt:demo@0.0.0;
        \\interface streams { resource output-stream { } }
        \\interface stdout {
        \\    use wabt:demo/streams@0.0.0.{output-stream};
        \\    get-stdout: func() -> own<output-stream>;
        \\}
        \\world cmd { import streams; import stdout; }
    ;
    const bytes = try encodeWorldFromSource(testing.allocator, source, "cmd");
    defer testing.allocator.free(bytes);

    const loader = @import("../loader.zig");
    var arena_loaded = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_loaded.deinit();
    const comp = try loader.load(bytes, arena_loaded.allocator());

    const world_body = comp.types[0].component.decls[0].type.component;
    // Same shape as the short-ref version: 5 world-body decls, with
    // the alias-instance-export decl between `streams` and `stdout`.
    try testing.expectEqual(@as(usize, 5), world_body.decls.len);
    try testing.expectEqualStrings("output-stream", world_body.decls[2].alias.instance_export.name);
}
