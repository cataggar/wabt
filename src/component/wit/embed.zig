//! Shared helpers for embedding a `component-type:<world>` custom
//! section into a core wasm. Used by both `wabt component embed` and
//! `wabt component new` (the latter embeds on the fly when given a WIT
//! path, collapsing the embed+new pipeline into a single call).

const std = @import("std");
const ast = @import("ast.zig");

/// Collect the names of every `world` item declared in a document, in
/// declaration order. Caller owns the returned slice.
pub fn worldNames(alloc: std.mem.Allocator, doc: ast.Document) ![]const []const u8 {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    errdefer names.deinit(alloc);
    for (doc.items) |it| {
        if (it == .world) try names.append(alloc, it.world.name);
    }
    return names.toOwnedSlice(alloc);
}

/// If exactly one world is defined in the document, return its name;
/// otherwise (zero or many) return null.
pub fn autoselectWorld(doc: ast.Document) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (doc.items) |it| {
        if (it == .world) {
            if (found != null) return null;
            found = it.world.name;
        }
    }
    return found;
}

/// Append a custom section with `name` and `payload` to a core wasm
/// binary. Existing custom sections with the same name are dropped so
/// re-embedding is idempotent. Caller owns the returned slice.
pub fn embedCustomSection(
    alloc: std.mem.Allocator,
    core_bytes: []const u8,
    name: []const u8,
    payload: []const u8,
) ![]u8 {
    if (core_bytes.len < 8) return error.InvalidCoreModule;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidCoreModule;

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);

    // Copy preamble.
    try out.appendSlice(alloc, core_bytes[0..8]);

    var i: usize = 8;
    while (i < core_bytes.len) {
        if (i >= core_bytes.len) break;
        const id = core_bytes[i];
        i += 1;
        const size_res = readU32Leb(core_bytes, i) catch return error.InvalidCoreModule;
        const sec_size = size_res.value;
        i += size_res.bytes_read;
        if (i + sec_size > core_bytes.len) return error.InvalidCoreModule;
        const body = core_bytes[i .. i + sec_size];
        i += sec_size;

        if (id == 0) {
            // Custom section: read its name and skip if it matches.
            const n_res = readU32Leb(body, 0) catch return error.InvalidCoreModule;
            const name_len = n_res.value;
            if (n_res.bytes_read + name_len > body.len) return error.InvalidCoreModule;
            const sec_name = body[n_res.bytes_read .. n_res.bytes_read + name_len];
            if (std.mem.eql(u8, sec_name, name)) continue;
        }
        // Re-emit unchanged.
        try out.append(alloc, id);
        try writeU32Leb(alloc, &out, sec_size);
        try out.appendSlice(alloc, body);
    }

    // Append the new custom section.
    var body = std.ArrayListUnmanaged(u8).empty;
    defer body.deinit(alloc);
    try writeU32Leb(alloc, &body, @intCast(name.len));
    try body.appendSlice(alloc, name);
    try body.appendSlice(alloc, payload);

    try out.append(alloc, 0);
    try writeU32Leb(alloc, &out, @intCast(body.items.len));
    try out.appendSlice(alloc, body.items);

    return try out.toOwnedSlice(alloc);
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

fn writeU32Leb(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) !void {
    var x = v;
    while (true) {
        var b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) b |= 0x80;
        try out.append(alloc, b);
        if (x == 0) break;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "embedCustomSection: appends section to a minimal core module" {
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    const payload = [_]u8{ 0x42, 0x00 };
    const out = try embedCustomSection(testing.allocator, &core, "component-type:w", &payload);
    defer testing.allocator.free(out);
    // preamble (8) + section id (1) + size leb (1) + name_len leb (1)
    // + name (15) + payload (2)
    try testing.expectEqual(@as(u8, 0x00), out[8]); // custom section id
    try testing.expect(std.mem.indexOf(u8, out, "component-type:w") != null);
}

test "embedCustomSection: replaces existing same-named section" {
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // existing custom section "component-type:w" with payload 0xAA
        0x00, 0x12, 0x10, 'c', 'o', 'm', 'p', 'o', 'n', 'e', 'n', 't', '-', 't', 'y', 'p', 'e', ':', 'w', 0xAA,
    };
    const payload = [_]u8{0xBB};
    const out = try embedCustomSection(testing.allocator, &core, "component-type:w", &payload);
    defer testing.allocator.free(out);
    // Only one occurrence of the name (the old section was dropped).
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "component-type:w")) |found| {
        count += 1;
        idx = found + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0xBB) != null);
    try testing.expect(std.mem.indexOfScalar(u8, out, 0xAA) == null);
}
