//! Synthesize the wasi-preview1 adapter splicer's "fixup" core
//! module.
//!
//! The fixup is instantiated *last* inside the wrapping component
//! (after main + adapter). Its job is to write the adapter's
//! preview1 exports into the shim's funcref table so that calls
//! through the shim trampolines reach real adapter funcs instead of
//! trapping. We use an *active* element segment that initialises
//! the imported table with the imported funcs at offset 0 — this
//! runs implicitly during instantiation and avoids the need for a
//! start function (matching `wit-component`'s emitter exactly).
//!
//! Wire shape:
//!
//!   ┌─ fixup core module ─────────────────────────────────────────┐
//!   │ types: one (func ...) per UNIQUE preview1-import signature  │
//!   │   (matches the shim's type list, in the same order)         │
//!   │ imports:                                                    │
//!   │   "" "0" func sig0                  (adapter export 0)      │
//!   │   "" "1" func sig1                  (adapter export 1)      │
//!   │   …                                                         │
//!   │   "" "\$imports" table funcref      (the shim's table)      │
//!   │ elem 0: active (table 0, offset i32.const 0)                │
//!   │   funcs: [0, 1, 2, …, N-1]                                  │
//!   └─────────────────────────────────────────────────────────────┘
//!
//! Slot order matches `shim.zig`'s slot order — same i'th index
//! everywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

const wtypes = @import("../../types.zig");
const leb = @import("../../leb128.zig");
const Slot = @import("shim.zig").Slot;

pub const Error = error{OutOfMemory};

/// Build the fixup core wasm bytes.
///
/// The slots must match the shim's slots — same length, same order,
/// same signatures — because the fixup pairs imported adapter func
/// i with shim table slot i.
pub fn build(gpa: Allocator, slots: []const Slot) Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

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

    // type section
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(unique_sigs.items.len));
        for (unique_sigs.items) |s| {
            try body.append(gpa, 0x60);
            try writeU32Leb(gpa, &body, @intCast(s.params.len));
            for (s.params) |p| try body.append(gpa, valTypeByte(p));
            try writeU32Leb(gpa, &body, @intCast(s.results.len));
            for (s.results) |r| try body.append(gpa, valTypeByte(r));
        }
        try writeSection(gpa, &out, 0x01, body.items);
    }

    // import section: N funcs, then the table (matching wit-
    // component's order so func indexspace is 0..N-1 for the
    // imported adapter funcs).
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(slots.len + 1));

        var name_buf: [16]u8 = undefined;
        for (sig_idx_for_slot, 0..) |t, i| {
            try writeU32Leb(gpa, &body, 0);
            const name = std.fmt.bufPrint(&name_buf, "{d}", .{i}) catch unreachable;
            try writeU32Leb(gpa, &body, @intCast(name.len));
            try body.appendSlice(gpa, name);
            try body.append(gpa, 0x00); // import desc: func
            try writeU32Leb(gpa, &body, t);
        }

        try writeU32Leb(gpa, &body, 0); // module ""
        const tbl_field = "$imports";
        try writeU32Leb(gpa, &body, @intCast(tbl_field.len));
        try body.appendSlice(gpa, tbl_field);
        try body.append(gpa, 0x01); // import desc: table
        try body.append(gpa, 0x70); // funcref
        try body.append(gpa, 0x01); // min/max present
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        try writeU32Leb(gpa, &body, @intCast(slots.len));

        try writeSection(gpa, &out, 0x02, body.items);
    }

    // element section: one active elem segment that initialises
    // table 0 starting at offset 0 with funcs 0..N-1.
    if (slots.len > 0) {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try body.append(gpa, 0x01); // 1 segment
        // flags = 0: active, table 0, funcref via funcidx
        try body.append(gpa, 0x00);
        // offset: i32.const 0; end
        try body.append(gpa, 0x41);
        try writeS32Leb(gpa, &body, 0);
        try body.append(gpa, 0x0b);
        // funcidx vector
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        for (0..slots.len) |i| try writeU32Leb(gpa, &body, @intCast(i));
        try writeSection(gpa, &out, 0x09, body.items);
    }

    return out.toOwnedSlice(gpa);
}

// ── helpers (mirrored from shim.zig — kept private here to avoid
// growing a shared util surface for two-call use) ──────────────────────────

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
        else => 0x7f,
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

    // Only the table import (no funcs, no element segment).
    try testing.expectEqual(@as(usize, 1), module.imports.items.len);
    try testing.expectEqual(wtypes.ExternalKind.table, module.imports.items[0].kind);
    try testing.expectEqualStrings("$imports", module.imports.items[0].field_name);
    try testing.expectEqual(@as(usize, 0), module.elem_segments.items.len);
}

test "build: one i32->i32 slot — N funcs + table imports + active elem" {
    const i32_p = [_]wtypes.ValType{.i32};
    const i32_r = [_]wtypes.ValType{.i32};
    const slots = [_]Slot{
        .{ .params = &i32_p, .results = &i32_r },
    };
    const bytes = try build(testing.allocator, &slots);
    defer testing.allocator.free(bytes);

    var module = try reader.readModule(testing.allocator, bytes);
    defer module.deinit();

    // N func imports + 1 table import.
    try testing.expectEqual(@as(usize, 2), module.imports.items.len);
    try testing.expectEqual(wtypes.ExternalKind.func, module.imports.items[0].kind);
    try testing.expectEqualStrings("0", module.imports.items[0].field_name);
    try testing.expectEqual(wtypes.ExternalKind.table, module.imports.items[1].kind);
    try testing.expectEqualStrings("$imports", module.imports.items[1].field_name);

    try testing.expectEqual(@as(usize, 1), module.funcs.items.len); // imported only
    try testing.expectEqual(@as(usize, 1), module.elem_segments.items.len);
    // No start function — the active elem runs at instantiation time.
    try testing.expect(module.start_var == null);
}
