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
//!   * record / variant / enum / flags / type-alias / use clause /
//!     resource decl in interface bodies (the wamr fixtures don't
//!     use them).
//!   * `own<R>` / `borrow<R>` handle types.
//!   * stream / future / async / error-context.
//!   * named-type references inside func sigs (`name` is rejected).
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

    // Each `export <iface>;` / `import <ns>:<pkg>/<iface>;` becomes a
    // type=instance-type decl followed by an export/import decl.
    var inst_idx: u32 = 0;
    for (world.items) |item| {
        switch (item) {
            .@"export", .import => |we| {
                const is_export = item == .@"export";
                const ext = we;
                const iface_name = qualifiedName(ar, ext, pkg_id) catch return error.InvalidWit;
                const iface_decls = try buildInterfaceBody(ar, resolver, ext);
                try world_decls.append(ar, .{ .type = .{
                    .instance = .{ .decls = iface_decls },
                } });
                const desc: ctypes.ExternDesc = .{ .instance = inst_idx };
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
                inst_idx += 1;
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
fn buildInterfaceBody(
    ar: Allocator,
    resolver: wit_resolver.Resolver,
    ext: ast.WorldExtern,
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
    // and a `ValType.type_idx` reference to its slot.
    var builder: BodyBuilder = .{ .ar = ar, .decls = .empty, .type_idx = 0 };
    for (iface_body.items) |it| {
        switch (it) {
            .func => |f| {
                // Lower param/result types first — this may emit
                // `.type` decls for compound types, bumping
                // `type_idx`. The `.func` `.type` itself goes last.
                const params = try ar.alloc(ctypes.NamedValType, f.func.params.len);
                for (f.func.params, 0..) |p, i| {
                    params[i] = .{ .name = p.name, .type = try builder.lowerType(p.type) };
                }
                const results: ctypes.FuncType.ResultList = if (f.func.result) |t|
                    .{ .unnamed = try builder.lowerType(t) }
                else
                    .none;

                const func_type_idx = builder.type_idx;
                try builder.decls.append(ar, .{ .type = .{ .func = .{
                    .params = params,
                    .results = results,
                } } });
                builder.type_idx += 1;

                try builder.decls.append(ar, .{ .@"export" = .{
                    .name = f.name,
                    .desc = .{ .func = func_type_idx },
                } });
            },
            .type, .use => return error.UnsupportedWitFeature,
        }
    }
    return try builder.decls.toOwnedSlice(ar);
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
            .name => error.UnsupportedWitFeature,
            .borrow, .own => error.UnsupportedWitFeature,
        };
    }

    fn appendCompound(self: *BodyBuilder, td: ctypes.TypeDef) EncodeError!ctypes.ValType {
        const idx = self.type_idx;
        try self.decls.append(self.ar, .{ .type = td });
        self.type_idx += 1;
        return .{ .type_idx = idx };
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
