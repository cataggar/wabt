//! Decode the WASI preview1 → component adapter's metadata.
//!
//! The wasi-preview1 adapter is a core wasm module produced by
//! `wit-bindgen` from the wasmtime tree. It carries an embedded
//! `component-type:wit-bindgen:<ver>:wasi:cli@<ver>:command:encoded
//! world` custom section whose payload is itself a component binary
//! describing the full WASI 0.2.6 type tree, every component-level
//! instance the adapter consumes (`wasi:cli/environment@0.2.6` etc.),
//! and the `wasi:cli/run@0.2.6` instance the adapter exports.
//!
//! This module:
//!
//!   * locates the `…:encoded world` custom section by suffix match
//!     (the `wit-bindgen:<ver>` prefix changes between releases — we
//!     match the trailing `":encoded world"` so future-version
//!     adapters are accepted unchanged),
//!   * loads the payload through wabt's existing component loader
//!     (which already handles resources, compound types, and outer
//!     aliases — verified empirically against the v36.0.9 adapter),
//!   * walks the decoded shape and returns a flat `AdapterWorld` the
//!     splicer can hoist into the wrapping component's top-level
//!     section list.
//!
//! The shape we expect (matches every adapter we've seen and is
//! invariant under the wit-component encoding rule):
//!
//!   types[0]    = component-type — the OUTER WRAPPER
//!     decls[0]  = type = component-type — the WORLD BODY
//!       (interleaved type defs / imports / alias-export decls)
//!     decls[1]  = export "<world-qualified-name>" component 0
//!   exports[0]  = "<world-name>" type=eq{0}    (top-level)
//!
//! Anything that doesn't match is rejected with
//! `error.UnsupportedAdapterShape` — the splicer is brittle enough
//! that bailing early with a clear error is preferable to producing
//! a malformed wrapping component.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const loader = @import("../loader.zig");
const leb128 = @import("../../leb128.zig");

pub const DecodeError = error{
    InvalidAdapterCore,
    MissingEncodedWorld,
    UnsupportedAdapterShape,
} || loader.LoadError;

/// One import the adapter declares at the world level.
pub const ImportEntry = struct {
    /// Qualified name on the wire, e.g. `wasi:cli/environment@0.2.6`.
    name: []const u8,
    /// Index of the `.import` decl within
    /// `AdapterWorld.body_decls`. The preceding entry is the
    /// `.type = .{ .instance = … }` that types this import.
    body_decl_idx: u32,
    /// Index into the world body's *type indexspace* of the instance
    /// type used by this import. Equal to the count of type-producing
    /// decls (type/alias) preceding `body_decl_idx`.
    body_type_idx: u32,
    /// Component-instance-indexspace position of this import within
    /// the world body. Imports appear in declaration order and are
    /// the only contributors to the instance indexspace inside a
    /// component-type body, so this is just the running import count.
    body_instance_idx: u32,
};

/// One export the adapter declares at the world level.
pub const ExportEntry = struct {
    name: []const u8,
    body_decl_idx: u32,
    body_type_idx: u32,
};

/// Parsed shape of the adapter's `:encoded world` payload.
///
/// `component`, `body_decls`, and the `*name` slices all borrow from
/// the arena passed to `parse`.
pub const AdapterWorld = struct {
    /// The fully-loaded component carried by the adapter's
    /// `:encoded world` custom section. Useful as a witness that the
    /// payload was loadable; callers should reach decls via
    /// `body_decls` to keep the index math consistent.
    component: ctypes.Component,
    /// Decl list of the world body (the inner component-type inside
    /// the outer wrapper).
    body_decls: []const ctypes.Decl,
    /// Number of slots in the world body's type indexspace —
    /// produced by every `.type` def, `.core_type` def, and `.alias`
    /// of sort `.type`. Equal to the type-idx the next type-producing
    /// decl would occupy.
    body_type_count: u32,
    /// All imports declared by the world body, in declaration order.
    imports: []const ImportEntry,
    /// All exports declared by the world body. Adapters typically
    /// have exactly one export (`wasi:cli/run@0.2.6` for the command
    /// adapter); the array is kept open to also accommodate adapters
    /// that export multiple instances (e.g. command + something else).
    exports: []const ExportEntry,
    /// Qualified world name, e.g. `wasi:cli/command@0.2.6`. Pulled
    /// from the outer wrapper's export decl.
    world_qualified_name: []const u8,
};

/// Locate the `…:encoded world` custom section in an adapter's core
/// wasm and return its payload (the inner component bytes).
pub fn extractEncodedWorld(adapter_core_bytes: []const u8) DecodeError!?[]const u8 {
    if (adapter_core_bytes.len < 8) return error.InvalidAdapterCore;
    if (!std.mem.eql(u8, adapter_core_bytes[0..4], "\x00asm")) return error.InvalidAdapterCore;

    var i: usize = 8;
    while (i < adapter_core_bytes.len) {
        const id = adapter_core_bytes[i];
        i += 1;
        const sz = readU32Leb(adapter_core_bytes, i) catch return error.InvalidAdapterCore;
        i += sz.bytes_read;
        if (i + sz.value > adapter_core_bytes.len) return error.InvalidAdapterCore;
        const body = adapter_core_bytes[i .. i + sz.value];
        i += sz.value;

        if (id != 0) continue;
        const n = readU32Leb(body, 0) catch return error.InvalidAdapterCore;
        const name_len = n.value;
        if (n.bytes_read + name_len > body.len) return error.InvalidAdapterCore;
        const sec_name = body[n.bytes_read .. n.bytes_read + name_len];
        // Match by suffix to track wit-bindgen version drift.
        const suffix = ":encoded world";
        if (sec_name.len < suffix.len) continue;
        if (!std.mem.eql(u8, sec_name[sec_name.len - suffix.len ..], suffix)) continue;
        // Custom section also requires the conventional
        // `component-type:` prefix to avoid matching unrelated
        // customs that happen to end in `:encoded world`.
        if (!std.mem.startsWith(u8, sec_name, "component-type:")) continue;
        return body[n.bytes_read + name_len ..];
    }
    return null;
}

/// Parse a `:encoded world` payload into a flat `AdapterWorld`.
/// Slices in the result borrow from `arena`.
pub fn parse(arena: Allocator, ct_payload: []const u8) DecodeError!AdapterWorld {
    const comp = try loader.load(ct_payload, arena);

    if (comp.types.len < 1 or comp.types[0] != .component) {
        return error.UnsupportedAdapterShape;
    }
    const outer = comp.types[0].component;
    if (outer.decls.len < 2) return error.UnsupportedAdapterShape;
    if (outer.decls[0] != .type or outer.decls[0].type != .component) {
        return error.UnsupportedAdapterShape;
    }
    if (outer.decls[1] != .@"export") return error.UnsupportedAdapterShape;

    const body = outer.decls[0].type.component;
    const world_qname = outer.decls[1].@"export".name;

    // Walk body decls, tagging:
    //   * imports + their preceding instance-type idx,
    //   * exports + their preceding instance-type idx,
    //   * type-indexspace cursor.
    var imports = std.ArrayListUnmanaged(ImportEntry).empty;
    var exports = std.ArrayListUnmanaged(ExportEntry).empty;
    var type_idx: u32 = 0;
    var inst_idx: u32 = 0;
    for (body.decls, 0..) |d, i| {
        switch (d) {
            .type, .core_type => type_idx += 1,
            .alias => |a| {
                // `instance_export` of sort `.type` and `outer` of
                // sort `.type` both contribute to the type
                // indexspace. Other alias sorts contribute to other
                // indexspaces and don't bump type_idx.
                const sort: ctypes.Sort = switch (a) {
                    .instance_export => |ie| ie.sort,
                    .outer => |o| o.sort,
                };
                if (sort == .type) type_idx += 1;
            },
            .import => |im| {
                const inst_type_idx: u32 = switch (im.desc) {
                    .instance => |idx| idx,
                    else => 0,
                };
                try imports.append(arena, .{
                    .name = im.name,
                    .body_decl_idx = @intCast(i),
                    .body_type_idx = inst_type_idx,
                    .body_instance_idx = inst_idx,
                });
                inst_idx += 1;
            },
            .@"export" => |e| {
                const inst_type_idx: u32 = switch (e.desc) {
                    .instance => |idx| idx,
                    else => 0,
                };
                try exports.append(arena, .{
                    .name = e.name,
                    .body_decl_idx = @intCast(i),
                    .body_type_idx = inst_type_idx,
                });
            },
        }
    }

    return .{
        .component = comp,
        .body_decls = body.decls,
        .body_type_count = type_idx,
        .imports = try imports.toOwnedSlice(arena),
        .exports = try exports.toOwnedSlice(arena),
        .world_qualified_name = world_qname,
    };
}

/// Convenience: combines `extractEncodedWorld` + `parse`.
pub fn parseFromAdapterCore(
    arena: Allocator,
    adapter_core_bytes: []const u8,
) DecodeError!AdapterWorld {
    const ct = (try extractEncodedWorld(adapter_core_bytes)) orelse return error.MissingEncodedWorld;
    return parse(arena, ct);
}

const LebRead = struct { value: u32, bytes_read: usize };

fn readU32Leb(buf: []const u8, start: usize) !LebRead {
    if (start >= buf.len) return error.UnexpectedEnd;
    const r = leb128.readU32Leb128(buf[start..]) catch return error.InvalidAdapterCore;
    return .{ .value = r.value, .bytes_read = r.bytes_read };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const writer = @import("../writer.zig");
const metadata_encode = @import("../wit/metadata_encode.zig");

/// Build a minimal adapter-shaped `component-type:…:encoded world`
/// payload by re-using `metadata_encode`. The world has one import
/// and one export, both of single-func interfaces — the smallest
/// shape that exercises the body-decl walk.
fn buildMockEncodedWorld(allocator: Allocator) ![]u8 {
    return metadata_encode.encodeWorldFromSource(allocator,
        \\package mock:adapter@0.1.0;
        \\
        \\interface in {
        \\    ping: func() -> u32;
        \\}
        \\
        \\interface out {
        \\    pong: func() -> u32;
        \\}
        \\
        \\world adapter-mock {
        \\    import in;
        \\    export out;
        \\}
    , "adapter-mock");
}

/// Wrap a payload as the body of a `component-type:mock:encoded
/// world` custom section appended to a minimal core wasm preamble —
/// produces a freestanding "adapter-shaped" core wasm for tests.
fn wrapAsAdapterCore(allocator: Allocator, ct_payload: []const u8) ![]u8 {
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const sec_name = "component-type:mock:encoded world";
    var name_leb: [leb128.max_u32_bytes]u8 = undefined;
    const name_leb_n = leb128.writeU32Leb128(&name_leb, @intCast(sec_name.len));
    const body_len = name_leb_n + sec_name.len + ct_payload.len;
    var size_leb: [leb128.max_u32_bytes]u8 = undefined;
    const size_leb_n = leb128.writeU32Leb128(&size_leb, @intCast(body_len));

    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, preamble.len + 1 + size_leb_n + body_len);
    out.appendSliceAssumeCapacity(&preamble);
    out.appendAssumeCapacity(0); // custom section id
    out.appendSliceAssumeCapacity(size_leb[0..size_leb_n]);
    out.appendSliceAssumeCapacity(name_leb[0..name_leb_n]);
    out.appendSliceAssumeCapacity(sec_name);
    out.appendSliceAssumeCapacity(ct_payload);
    return out.toOwnedSlice(allocator);
}

test "extractEncodedWorld: matches by suffix and prefix" {
    const ct = try buildMockEncodedWorld(testing.allocator);
    defer testing.allocator.free(ct);
    const core = try wrapAsAdapterCore(testing.allocator, ct);
    defer testing.allocator.free(core);

    const found = try extractEncodedWorld(core);
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, ct, found.?);
}

test "extractEncodedWorld: rejects non-adapter custom sections" {
    // Core wasm with a custom section whose name doesn't match
    // either prefix or suffix.
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x07, // custom section, body size 7
        0x05, 'h', 'e', 'l', 'l', 'o', 0x00,
    };
    const found = try extractEncodedWorld(&core);
    try testing.expect(found == null);
}

test "parse: walks mock world body and surfaces imports/exports" {
    const ct = try buildMockEncodedWorld(testing.allocator);
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try parse(arena.allocator(), ct);

    try testing.expectEqual(@as(usize, 1), w.imports.len);
    try testing.expectEqualStrings("mock:adapter/in@0.1.0", w.imports[0].name);
    try testing.expectEqual(@as(u32, 0), w.imports[0].body_instance_idx);

    try testing.expectEqual(@as(usize, 1), w.exports.len);
    try testing.expectEqualStrings("mock:adapter/out@0.1.0", w.exports[0].name);

    try testing.expectEqualStrings("mock:adapter/adapter-mock@0.1.0", w.world_qualified_name);

    // body_type_count counts every type-producing body decl. The
    // world has 2 instance-type defs.
    try testing.expectEqual(@as(u32, 2), w.body_type_count);
}

test "parseFromAdapterCore: end-to-end through extract + load" {
    const ct = try buildMockEncodedWorld(testing.allocator);
    defer testing.allocator.free(ct);
    const core = try wrapAsAdapterCore(testing.allocator, ct);
    defer testing.allocator.free(core);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try parseFromAdapterCore(arena.allocator(), core);
    try testing.expectEqual(@as(usize, 1), w.imports.len);
    try testing.expectEqual(@as(usize, 1), w.exports.len);
}
