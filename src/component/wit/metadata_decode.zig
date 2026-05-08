//! Decode a `component-type:<world>` custom section payload back
//! into a structured world description.
//!
//! Inverse of `metadata_encode.zig`. Walks the embedded component AST
//! produced by the loader and recovers, for each world extern:
//!
//!   * whether it's an import or export,
//!   * the qualified interface name (`<ns>:<pkg>/<iface>[@<ver>]`),
//!   * the list of funcs in the interface, with their full
//!     component-level signatures.
//!
//! Currently MVP-scoped: only the wamr-fixture shape is recognised
//! (component-type wrapper → world component-type → instance-type
//! per interface → func type per func). Compound types (record,
//! variant, etc.) and resource handles in interface bodies aren't
//! recognised yet — they'll surface as `error.UnsupportedShape`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const loader = @import("../loader.zig");

pub const DecodeError = error{
    InvalidComponentType,
    UnsupportedShape,
    OutOfMemory,
} || loader.LoadError;

pub const FuncRef = struct {
    /// Func name within the interface (e.g. `add`).
    name: []const u8,
    /// Component-level signature.
    sig: ctypes.FuncType,
};

pub const WorldExtern = struct {
    is_export: bool,
    /// Qualified name on the wire (e.g. `docs:adder/add@0.1.0`).
    qualified_name: []const u8,
    /// Funcs declared by the interface this extern references.
    funcs: []const FuncRef,
};

pub const DecodedWorld = struct {
    /// Bare world name, e.g. `adder`.
    name: []const u8,
    /// Qualified world name on the wire, e.g. `docs:adder/adder@0.1.0`.
    qualified_name: []const u8,
    /// All world externs (imports and exports), in declaration order.
    externs: []const WorldExtern,
};

/// Decode the given `component-type` custom-section payload.
/// All returned slices borrow from `arena`.
pub fn decode(arena: Allocator, ct_payload: []const u8) DecodeError!DecodedWorld {
    const comp = try loader.load(ct_payload, arena);
    if (comp.types.len == 0) return error.InvalidComponentType;

    // The outermost type is a component-type with two decls:
    //   decl[0] = type = component-type (the world itself)
    //   decl[1] = export "<ns>:<pkg>/<world>[@<ver>]" component 0
    if (comp.types[0] != .component) return error.UnsupportedShape;
    const outer = comp.types[0].component;
    if (outer.decls.len < 2) return error.UnsupportedShape;
    if (outer.decls[0] != .type or outer.decls[0].type != .component) return error.UnsupportedShape;
    if (outer.decls[1] != .@"export") return error.UnsupportedShape;
    const world_qualified = outer.decls[1].@"export".name;

    const world_body = outer.decls[0].type.component;

    // Walk world body in pairs: (type=instance, import|export).
    var externs = std.ArrayListUnmanaged(WorldExtern).empty;
    var i: usize = 0;
    while (i < world_body.decls.len) {
        const decl = world_body.decls[i];
        if (decl != .type or decl.type != .instance) return error.UnsupportedShape;
        const inst_type = decl.type.instance;
        if (i + 1 >= world_body.decls.len) return error.UnsupportedShape;
        const next = world_body.decls[i + 1];
        var is_export: bool = undefined;
        var qualified_name: []const u8 = undefined;
        switch (next) {
            .@"export" => |e| {
                is_export = true;
                qualified_name = e.name;
            },
            .import => |im| {
                is_export = false;
                qualified_name = im.name;
            },
            else => return error.UnsupportedShape,
        }
        const funcs = try decodeInterfaceBody(arena, inst_type);
        try externs.append(arena, .{
            .is_export = is_export,
            .qualified_name = qualified_name,
            .funcs = funcs,
        });
        i += 2;
    }

    // Bare world name is the part after `/` (and before `@`) of the
    // qualified name. Top-level export's name *would* give us the
    // bare form, but it's also derivable.
    const bare = bareName(world_qualified);

    return .{
        .name = bare,
        .qualified_name = world_qualified,
        .externs = try externs.toOwnedSlice(arena),
    };
}

fn decodeInterfaceBody(arena: Allocator, inst: ctypes.InstanceTypeDecl) DecodeError![]const FuncRef {
    var funcs = std.ArrayListUnmanaged(FuncRef).empty;
    var j: usize = 0;
    while (j < inst.decls.len) {
        const d = inst.decls[j];
        if (d != .type or d.type != .func) return error.UnsupportedShape;
        const sig = d.type.func;
        if (j + 1 >= inst.decls.len) return error.UnsupportedShape;
        const exp = inst.decls[j + 1];
        if (exp != .@"export") return error.UnsupportedShape;
        try funcs.append(arena, .{ .name = exp.@"export".name, .sig = sig });
        j += 2;
    }
    return try funcs.toOwnedSlice(arena);
}

fn bareName(qualified: []const u8) []const u8 {
    // Strip everything before `/` (the package prefix). Strip `@<version>`.
    var name = qualified;
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        name = name[slash + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, name, '@')) |at| {
        name = name[0..at];
    }
    return name;
}

/// Locate `component-type:<world>` custom sections in a core wasm and
/// return the world name + payload of the (single) match. Returns
/// `null` if no such section exists. If multiple sections are
/// present (rare), the first wins.
pub fn extractFromCoreWasm(core_bytes: []const u8) !?struct {
    world_name: []const u8,
    payload: []const u8,
} {
    if (core_bytes.len < 8) return error.InvalidCoreModule;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidCoreModule;

    var i: usize = 8;
    while (i < core_bytes.len) {
        const id = core_bytes[i];
        i += 1;
        const sz = try readU32Leb(core_bytes, i);
        i += sz.bytes_read;
        if (i + sz.value > core_bytes.len) return error.InvalidCoreModule;
        const body = core_bytes[i .. i + sz.value];
        i += sz.value;

        if (id == 0) {
            const n = try readU32Leb(body, 0);
            const name_len = n.value;
            if (n.bytes_read + name_len > body.len) return error.InvalidCoreModule;
            const sec_name = body[n.bytes_read .. n.bytes_read + name_len];
            const prefix = "component-type:";
            if (std.mem.startsWith(u8, sec_name, prefix)) {
                return .{
                    .world_name = sec_name[prefix.len..],
                    .payload = body[n.bytes_read + name_len ..],
                };
            }
        }
    }
    return null;
}

const LebRead = struct { value: u32, bytes_read: usize };

fn readU32Leb(buf: []const u8, start: usize) !LebRead {
    var result: u32 = 0;
    var shift: u5 = 0;
    var i: usize = start;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        result |= @as(u32, b & 0x7f) << shift;
        if ((b & 0x80) == 0) {
            return .{ .value = result, .bytes_read = i + 1 - start };
        }
        if (shift >= 25) return error.LebOverflow;
        shift += 7;
    }
    return error.LebTruncated;
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const metadata_encode = @import("metadata_encode.zig");

test "decode: round-trip adder world" {
    const wit_source =
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
    const ct = try metadata_encode.encodeWorldFromSource(testing.allocator, wit_source, "adder");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try decode(arena.allocator(), ct);

    try testing.expectEqualStrings("adder", w.name);
    try testing.expectEqualStrings("docs:adder/adder@0.1.0", w.qualified_name);
    try testing.expectEqual(@as(usize, 1), w.externs.len);
    try testing.expect(w.externs[0].is_export);
    try testing.expectEqualStrings("docs:adder/add@0.1.0", w.externs[0].qualified_name);
    try testing.expectEqual(@as(usize, 1), w.externs[0].funcs.len);
    try testing.expectEqualStrings("add", w.externs[0].funcs[0].name);
    try testing.expectEqual(@as(usize, 2), w.externs[0].funcs[0].sig.params.len);
    try testing.expectEqualStrings("x", w.externs[0].funcs[0].sig.params[0].name);
    try testing.expect(w.externs[0].funcs[0].sig.params[0].type == .u32);
    try testing.expect(w.externs[0].funcs[0].sig.results == .unnamed);
    try testing.expect(w.externs[0].funcs[0].sig.results.unnamed == .u32);
}

test "extractFromCoreWasm: finds custom section" {
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x07,
        0x05, // name length=5
        'h', 'e', 'l', 'l', 'o',
    } ++ [_]u8{0x00};
    const found = try extractFromCoreWasm(&core);
    try testing.expect(found == null); // name doesn't match prefix

    const core2 = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x13, // section id=0, size=19
        0x10, // name len=16 ("component-type:w")
        'c', 'o', 'm', 'p', 'o', 'n', 'e', 'n', 't', '-', 't', 'y', 'p', 'e', ':', 'w',
        0xAA, 0xBB,
    };
    const f2 = try extractFromCoreWasm(&core2);
    try testing.expect(f2 != null);
    try testing.expectEqualStrings("w", f2.?.world_name);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, f2.?.payload);
}
