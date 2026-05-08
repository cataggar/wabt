//! Synthesize the wasi-preview1 adapter splicer's "shim" core module.
//!
//! The shim is a tiny core wasm module that gets instantiated *first*
//! inside the wrapping component. It exposes one trapping trampoline
//! per preview1 import the embed module declares, plus a funcref
//! table named "$imports" that the trampolines call_indirect through.
//!
//! After the main embed module is instantiated (using these
//! trampolines as its `wasi_snapshot_preview1.*` imports) and the
//! adapter is instantiated (consuming main's exports + the lowered
//! WASI 0.2.6 imports), the *fixup* module (see `fixup.zig`) is
//! instantiated and its start function writes the adapter's preview1
//! exports into the shim's table — patching every trampoline so
//! subsequent calls reach the adapter instead of trapping.
//!
//! Wire shape:
//!
//!   ┌─ shim core module ─────────────────────────────────────────┐
//!   │ types: one (func ...) per UNIQUE preview1-import signature │
//!   │ table 0: funcref, min/max = N (one slot per import)         │
//!   │ funcs: N trampolines, each with body                        │
//!   │   local.get 0 … local.get k   (forward params)              │
//!   │   i32.const i                  (slot index)                 │
//!   │   call_indirect (type T) 0     (through table 0)            │
//!   │ exports:                                                    │
//!   │   "0" func 0, "1" func 1, …                                 │
//!   │   "$imports" table 0                                        │
//!   └─────────────────────────────────────────────────────────────┘
//!
//! Stable export naming ("0", "1", …) matches `wit-component`'s
//! convention so the splicer can blindly alias the i'th shim export
//! as `wasi_snapshot_preview1.<i'th preview1 import name>` from
//! main's perspective.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wtypes = @import("../../types.zig");
const leb = @import("../../leb128.zig");

pub const Error = error{OutOfMemory};

/// One preview1 trampoline the shim should expose.
pub const Slot = struct {
    /// Param val types (i32 / i64 / f32 / f64). Reference types are
    /// not currently supported — preview1 sigs only ever use ints.
    params: []const wtypes.ValType,
    /// Result val types. preview1 funcs always return either nothing
    /// or a single i32 errno but we keep this open.
    results: []const wtypes.ValType,
};

/// Build the shim core wasm bytes for the given slots. Slot order
/// equals export-name order ("0", "1", …) and table-slot order.
/// Caller frees the returned slice via `gpa`.
pub fn build(gpa: Allocator, slots: []const Slot) Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    // magic + version
    try out.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // ── deduplicate signatures so the type section is compact ────────────
    var sig_idx_for_slot = try gpa.alloc(u32, slots.len);
    defer gpa.free(sig_idx_for_slot);

    var unique_sigs = std.ArrayListUnmanaged(Slot).empty;
    defer unique_sigs.deinit(gpa);

    for (slots, 0..) |s, i| {
        var found: ?u32 = null;
        for (unique_sigs.items, 0..) |u, j| {
            if (sigEql(u, s)) {
                found = @intCast(j);
                break;
            }
        }
        if (found) |idx| {
            sig_idx_for_slot[i] = idx;
        } else {
            sig_idx_for_slot[i] = @intCast(unique_sigs.items.len);
            try unique_sigs.append(gpa, s);
        }
    }

    // ── type section ─────────────────────────────────────────────────────
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(unique_sigs.items.len));
        for (unique_sigs.items) |s| {
            try body.append(gpa, 0x60); // func type
            try writeU32Leb(gpa, &body, @intCast(s.params.len));
            for (s.params) |p| try body.append(gpa, valTypeByte(p));
            try writeU32Leb(gpa, &body, @intCast(s.results.len));
            for (s.results) |r| try body.append(gpa, valTypeByte(r));
        }
        try writeSection(gpa, &out, 0x01, body.items);
    }

    // ── function section: one defined func per slot ──────────────────────
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        for (sig_idx_for_slot) |t| try writeU32Leb(gpa, &body, t);
        try writeSection(gpa, &out, 0x03, body.items);
    }

    // ── table section: 1 funcref table sized to the slot count ─────────
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try body.append(gpa, 0x01); // count
        try body.append(gpa, 0x70); // funcref
        try body.append(gpa, 0x01); // min/max present
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        try writeSection(gpa, &out, 0x04, body.items);
    }

    // ── export section: "<i>" funcs + "$imports" table ──────────────────
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(slots.len + 1));
        var name_buf: [16]u8 = undefined;
        for (0..slots.len) |i| {
            const name = std.fmt.bufPrint(&name_buf, "{d}", .{i}) catch unreachable;
            try writeU32Leb(gpa, &body, @intCast(name.len));
            try body.appendSlice(gpa, name);
            try body.append(gpa, 0x00); // export desc: func
            try writeU32Leb(gpa, &body, @intCast(i));
        }
        const tbl_name = "$imports";
        try writeU32Leb(gpa, &body, @intCast(tbl_name.len));
        try body.appendSlice(gpa, tbl_name);
        try body.append(gpa, 0x01); // export desc: table
        try body.append(gpa, 0x00); // table idx 0
        try writeSection(gpa, &out, 0x07, body.items);
    }

    // ── code section: one trampoline body per slot ──────────────────────
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        for (slots, 0..) |s, i| {
            var fn_body = std.ArrayListUnmanaged(u8).empty;
            defer fn_body.deinit(gpa);
            try fn_body.append(gpa, 0x00); // 0 local decls
            // forward each param via local.get
            for (0..s.params.len) |k| {
                try fn_body.append(gpa, 0x20); // local.get
                try writeU32Leb(gpa, &fn_body, @intCast(k));
            }
            // i32.const i  (signed LEB; small values fit in one byte)
            try fn_body.append(gpa, 0x41);
            try writeS32Leb(gpa, &fn_body, @intCast(i));
            // call_indirect (type sig_idx_for_slot[i]) (table 0)
            try fn_body.append(gpa, 0x11);
            try writeU32Leb(gpa, &fn_body, sig_idx_for_slot[i]);
            try writeU32Leb(gpa, &fn_body, 0);
            // end
            try fn_body.append(gpa, 0x0b);

            try writeU32Leb(gpa, &body, @intCast(fn_body.items.len));
            try body.appendSlice(gpa, fn_body.items);
        }
        try writeSection(gpa, &out, 0x0a, body.items);
    }

    return out.toOwnedSlice(gpa);
}

// ── helpers ────────────────────────────────────────────────────────────────

fn sigEql(a: Slot, b: Slot) bool {
    return std.mem.eql(wtypes.ValType, a.params, b.params) and
        std.mem.eql(wtypes.ValType, a.results, b.results);
}

fn valTypeByte(v: wtypes.ValType) u8 {
    return switch (v) {
        .i32 => 0x7f,
        .i64 => 0x7e,
        .f32 => 0x7d,
        .f64 => 0x7c,
        .v128 => 0x7b,
        .funcref => 0x70,
        .externref => 0x6f,
        else => 0x7f, // not used for adapter sigs; default to i32
    };
}

fn writeU32Leb(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), v: u32) Error!void {
    var tmp: [leb.max_u32_bytes]u8 = undefined;
    const n = leb.writeU32Leb128(&tmp, v);
    try buf.appendSlice(gpa, tmp[0..n]);
}

fn writeS32Leb(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), v: i32) Error!void {
    var tmp: [leb.max_s32_bytes]u8 = undefined;
    const n = leb.writeS32Leb128(&tmp, v);
    try buf.appendSlice(gpa, tmp[0..n]);
}

fn writeSection(gpa: Allocator, out: *std.ArrayListUnmanaged(u8), id: u8, body: []const u8) Error!void {
    try out.append(gpa, id);
    var len_buf: [leb.max_u32_bytes]u8 = undefined;
    const n = leb.writeU32Leb128(&len_buf, @intCast(body.len));
    try out.appendSlice(gpa, len_buf[0..n]);
    try out.appendSlice(gpa, body);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const reader = @import("../../binary/reader.zig");

test "build: empty slot list still produces a valid module" {
    const bytes = try build(testing.allocator, &.{});
    defer testing.allocator.free(bytes);

    var module = try reader.readModule(testing.allocator, bytes);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 0), module.funcs.items.len);
    try testing.expectEqual(@as(usize, 1), module.tables.items.len);
    try testing.expectEqual(@as(usize, 1), module.exports.items.len);
    try testing.expectEqualStrings("$imports", module.exports.items[0].name);
}

test "build: one i32->i32 slot — exports '0' func + '$imports' table" {
    const i32_p = [_]wtypes.ValType{.i32};
    const i32_r = [_]wtypes.ValType{.i32};
    const slots = [_]Slot{
        .{ .params = &i32_p, .results = &i32_r },
    };
    const bytes = try build(testing.allocator, &slots);
    defer testing.allocator.free(bytes);

    var module = try reader.readModule(testing.allocator, bytes);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 1), module.module_types.items.len);
    try testing.expectEqual(@as(usize, 1), module.funcs.items.len);
    try testing.expectEqual(@as(usize, 1), module.tables.items.len);
    try testing.expectEqual(@as(u64, 1), module.tables.items[0].type.limits.initial);

    try testing.expectEqual(@as(usize, 2), module.exports.items.len);
    try testing.expectEqualStrings("0", module.exports.items[0].name);
    try testing.expectEqual(wtypes.ExternalKind.func, module.exports.items[0].kind);
    try testing.expectEqualStrings("$imports", module.exports.items[1].name);
    try testing.expectEqual(wtypes.ExternalKind.table, module.exports.items[1].kind);
}

test "build: deduplicates signatures across multiple slots" {
    const sig_a_p = [_]wtypes.ValType{ .i32, .i32 };
    const sig_a_r = [_]wtypes.ValType{.i32};
    const sig_b_p = [_]wtypes.ValType{.i32};
    const sig_b_r = [_]wtypes.ValType{.i32};

    const slots = [_]Slot{
        .{ .params = &sig_a_p, .results = &sig_a_r },
        .{ .params = &sig_b_p, .results = &sig_b_r },
        .{ .params = &sig_a_p, .results = &sig_a_r }, // duplicate of slot 0
    };
    const bytes = try build(testing.allocator, &slots);
    defer testing.allocator.free(bytes);

    var module = try reader.readModule(testing.allocator, bytes);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 2), module.module_types.items.len);
    try testing.expectEqual(@as(usize, 3), module.funcs.items.len);
    try testing.expectEqual(@as(u64, 3), module.tables.items[0].type.limits.initial);
    // 3 stub exports + 1 table export
    try testing.expectEqual(@as(usize, 4), module.exports.items.len);
}
