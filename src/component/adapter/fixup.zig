//! Synthesize the wasi-preview1 adapter splicer's "fixup" core
//! module.
//!
//! The fixup is instantiated *last* inside the wrapping component
//! (after main + adapter). Its job is to write the adapter's
//! preview1 exports into the shim's funcref table so that calls
//! through the shim trampolines reach real adapter funcs instead of
//! trapping. Once the fixup's start function runs, the shim is
//! "fully wired".
//!
//! Wire shape:
//!
//!   ┌─ fixup core module ─────────────────────────────────────────┐
//!   │ types: one (func ...) per UNIQUE preview1-import signature  │
//!   │   (matches the shim's type list, in the same order)         │
//!   │ imports:                                                    │
//!   │   "" "$imports" table funcref       (the shim's table)      │
//!   │   "" "0" func sig0                  (adapter export 0)      │
//!   │   "" "1" func sig1                  (adapter export 1)      │
//!   │   …                                                         │
//!   │ elem 0: declarative funcref, [func 0, func 1, …]            │
//!   │   (declares every imported adapter func so ref.func is      │
//!   │    legal)                                                   │
//!   │ func N: the start function — body                           │
//!   │   for each i in 0..N:                                       │
//!   │     i32.const i                                             │
//!   │     ref.func i                                              │
//!   │     table.set 0                                             │
//!   │ start: func N                                               │
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
/// same signatures — because the fixup's start function pairs up
/// imported adapter func i with shim table slot i.
pub fn build(gpa: Allocator, slots: []const Slot) Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // Deduplicate sigs (parallel to shim's logic; we just need the
    // type table to match each imported func to a typeidx).
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
        // Plus the start func's () -> () type as the LAST entry.
        try writeU32Leb(gpa, &body, @intCast(unique_sigs.items.len + 1));
        for (unique_sigs.items) |s| {
            try body.append(gpa, 0x60);
            try writeU32Leb(gpa, &body, @intCast(s.params.len));
            for (s.params) |p| try body.append(gpa, valTypeByte(p));
            try writeU32Leb(gpa, &body, @intCast(s.results.len));
            for (s.results) |r| try body.append(gpa, valTypeByte(r));
        }
        try body.append(gpa, 0x60);
        try body.append(gpa, 0x00);
        try body.append(gpa, 0x00);
        try writeSection(gpa, &out, 0x01, body.items);
    }

    const start_type_idx: u32 = @intCast(unique_sigs.items.len);

    // import section: 1 table + N funcs
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(slots.len + 1));
        // table import: "" "$imports" funcref min/max=N
        try writeU32Leb(gpa, &body, 0); // module ""
        const tbl_field = "$imports";
        try writeU32Leb(gpa, &body, @intCast(tbl_field.len));
        try body.appendSlice(gpa, tbl_field);
        try body.append(gpa, 0x01); // import desc: table
        try body.append(gpa, 0x70); // funcref
        try body.append(gpa, 0x01); // min/max present
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        try writeU32Leb(gpa, &body, @intCast(slots.len));

        // func imports
        var name_buf: [16]u8 = undefined;
        for (sig_idx_for_slot, 0..) |t, i| {
            try writeU32Leb(gpa, &body, 0);
            const name = std.fmt.bufPrint(&name_buf, "{d}", .{i}) catch unreachable;
            try writeU32Leb(gpa, &body, @intCast(name.len));
            try body.appendSlice(gpa, name);
            try body.append(gpa, 0x00); // import desc: func
            try writeU32Leb(gpa, &body, t);
        }
        try writeSection(gpa, &out, 0x02, body.items);
    }

    // function section: 1 defined func (the start)
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try body.append(gpa, 0x01);
        try writeU32Leb(gpa, &body, start_type_idx);
        try writeSection(gpa, &out, 0x03, body.items);
    }

    // start section: idx of our start func (= N imported funcs)
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        try writeSection(gpa, &out, 0x08, body.items);
    }

    // element section: one declarative funcref segment listing every
    // imported func — needed so `ref.func i` is a valid expression in
    // the start body.
    if (slots.len > 0) {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try body.append(gpa, 0x01); // 1 segment
        // flags = 3 (declarative + uses elem kind, i.e. funcref of
        // funcidx). encoding: 0x03, elemkind=0x00 (funcref via
        // funcidx), then count + funcidxs.
        try body.append(gpa, 0x03);
        try body.append(gpa, 0x00);
        try writeU32Leb(gpa, &body, @intCast(slots.len));
        for (0..slots.len) |i| try writeU32Leb(gpa, &body, @intCast(i));
        try writeSection(gpa, &out, 0x09, body.items);
    }

    // code section: the start func body
    {
        var fn_body = std.ArrayListUnmanaged(u8).empty;
        defer fn_body.deinit(gpa);
        try fn_body.append(gpa, 0x00); // 0 local decls
        for (0..slots.len) |i| {
            try fn_body.append(gpa, 0x41); // i32.const
            try writeS32Leb(gpa, &fn_body, @intCast(i));
            try fn_body.append(gpa, 0xd2); // ref.func
            try writeU32Leb(gpa, &fn_body, @intCast(i));
            try fn_body.append(gpa, 0x26); // table.set
            try writeU32Leb(gpa, &fn_body, 0); // tableidx 0
        }
        try fn_body.append(gpa, 0x0b); // end

        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(gpa);
        try writeU32Leb(gpa, &body, 1); // 1 func
        try writeU32Leb(gpa, &body, @intCast(fn_body.items.len));
        try body.appendSlice(gpa, fn_body.items);
        try writeSection(gpa, &out, 0x0a, body.items);
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

    // Just the table import + 1 defined start func.
    try testing.expectEqual(@as(usize, 1), module.imports.items.len);
    try testing.expectEqual(wtypes.ExternalKind.table, module.imports.items[0].kind);
    try testing.expectEqualStrings("$imports", module.imports.items[0].field_name);
    try testing.expectEqual(@as(usize, 1), module.funcs.items.len);
    try testing.expect(module.start_var != null);
}

test "build: one i32->i32 slot — imports table + 1 func, start defined" {
    const i32_p = [_]wtypes.ValType{.i32};
    const i32_r = [_]wtypes.ValType{.i32};
    const slots = [_]Slot{
        .{ .params = &i32_p, .results = &i32_r },
    };
    const bytes = try build(testing.allocator, &slots);
    defer testing.allocator.free(bytes);

    var module = try reader.readModule(testing.allocator, bytes);
    defer module.deinit();

    // Table + 1 func import + 1 defined start.
    try testing.expectEqual(@as(usize, 2), module.imports.items.len);
    try testing.expectEqual(wtypes.ExternalKind.table, module.imports.items[0].kind);
    try testing.expectEqual(wtypes.ExternalKind.func, module.imports.items[1].kind);
    try testing.expectEqualStrings("0", module.imports.items[1].field_name);

    try testing.expectEqual(@as(usize, 2), module.funcs.items.len); // 1 imported + 1 defined
    try testing.expect(module.start_var != null);
    try testing.expectEqual(@as(u32, 1), module.start_var.?.index);

    // 1 element segment (declarative).
    try testing.expectEqual(@as(usize, 1), module.elem_segments.items.len);
}
