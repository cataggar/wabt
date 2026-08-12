/// LEB128 (Little Endian Base 128) encoding/decoding for WebAssembly.
///
/// Each byte uses 7 data bits (0-6) and 1 continuation bit (7).
/// If bit 7 is set, more bytes follow. Values are built LSB-first.
const std = @import("std");
const testing = std.testing;

// Maximum bytes needed for LEB128-encoded values.
pub const max_u32_bytes = 5;
pub const max_u64_bytes = 10;
pub const max_s32_bytes = 5;
pub const max_s33_bytes = 5;
pub const max_s64_bytes = 10;

pub const ReadError = error{ Overflow, UnexpectedEnd };

pub const ReadU32Result = struct { value: u32, bytes_read: usize };
pub const ReadU64Result = struct { value: u64, bytes_read: usize };
pub const ReadS32Result = struct { value: i32, bytes_read: usize };
pub const ReadS33Result = struct { value: i64, bytes_read: usize };
pub const ReadS64Result = struct { value: i64, bytes_read: usize };

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub fn readU32Leb128(bytes: []const u8) ReadError!ReadU32Result {
    var result: u32 = 0;
    var shift: u5 = 0;
    for (bytes, 0..) |byte, i| {
        if (i >= max_u32_bytes) return error.Overflow;

        const payload: u32 = @as(u32, byte & 0x7f);

        // On the last possible byte only the low 4 bits may be used.
        if (shift == 28 and payload > 0x0f) return error.Overflow;

        result |= payload << shift;
        if (byte & 0x80 == 0) {
            return .{ .value = result, .bytes_read = i + 1 };
        }
        shift +|= 7;
    }
    return error.UnexpectedEnd;
}

pub fn readU64Leb128(bytes: []const u8) ReadError!ReadU64Result {
    var result: u64 = 0;
    var shift: u7 = 0;
    for (bytes, 0..) |byte, i| {
        if (i >= max_u64_bytes) return error.Overflow;

        const payload: u64 = @as(u64, byte & 0x7f);

        if (shift == 63 and payload > 0x01) return error.Overflow;

        result |= payload << @intCast(shift);
        if (byte & 0x80 == 0) {
            return .{ .value = result, .bytes_read = i + 1 };
        }
        shift +|= 7;
    }
    return error.UnexpectedEnd;
}

pub fn readS32Leb128(bytes: []const u8) ReadError!ReadS32Result {
    var result: u32 = 0;
    var shift: u5 = 0;
    var last_byte: u8 = undefined;
    for (bytes, 0..) |byte, i| {
        if (i >= max_s32_bytes) return error.Overflow;

        const payload: u32 = @as(u32, byte & 0x7f);

        // On the 5th byte (shift==28) the valid signed range is 0x00..0x07
        // (positive) or 0x78..0x7f (negative sign-extended).
        if (shift == 28) {
            const top: u8 = byte & 0x7f;
            if (top != top & 0x07 and top < 0x78) return error.Overflow;
        }

        result |= payload << shift;
        last_byte = byte;
        if (byte & 0x80 == 0) {
            // Sign-extend if the sign bit of the last byte is set.
            if (shift < 31 and (last_byte & 0x40) != 0) {
                result |= @as(u32, 0xffffffff) << (shift +| 7);
            }
            return .{
                .value = @bitCast(result),
                .bytes_read = i + 1,
            };
        }
        shift +|= 7;
    }
    return error.UnexpectedEnd;
}

/// Read an s33: the signed LEB128 the binary format uses for a block
/// signature and for a heap type, where a non-negative value is a type index
/// and a negative one names a value type or an abstract heap type.
///
/// 33 bits fit in five bytes, so a sixth is not padding but a malformed
/// encoding, and the fifth byte carries only the 33rd bit: bits 34 and 35
/// must repeat the sign in bit 33, which leaves the payload `0x00..0x0f` when
/// non-negative and `0x70..0x7f` when negative. Reading these as an s64
/// instead accepted encodings up to ten bytes wide, and `readS32Leb128`
/// rejects the top of the range as an overflow, so neither is a substitute.
pub fn readS33Leb128(bytes: []const u8) ReadError!ReadS33Result {
    var result: u64 = 0;
    var shift: u6 = 0;
    for (bytes, 0..) |byte, i| {
        if (i >= max_s33_bytes) return error.Overflow;

        const payload: u64 = @as(u64, byte & 0x7f);

        if (shift == 28) {
            const top: u8 = byte & 0x7f;
            if (top > 0x0f and top < 0x70) return error.Overflow;
        }

        result |= payload << shift;
        if (byte & 0x80 == 0) {
            // Sign-extend if the sign bit of the last byte is set.
            if (byte & 0x40 != 0) result |= ~@as(u64, 0) << (shift +| 7);
            return .{
                .value = @bitCast(result),
                .bytes_read = i + 1,
            };
        }
        shift +|= 7;
    }
    return error.UnexpectedEnd;
}

pub fn readS64Leb128(bytes: []const u8) ReadError!ReadS64Result {
    var result: u64 = 0;
    var shift: u7 = 0;
    var last_byte: u8 = undefined;
    for (bytes, 0..) |byte, i| {
        if (i >= max_s64_bytes) return error.Overflow;

        const payload: u64 = @as(u64, byte & 0x7f);

        if (shift == 63) {
            const top: u8 = byte & 0x7f;
            if (top != 0x00 and top != 0x7f) return error.Overflow;
        }

        result |= payload << @intCast(shift);
        last_byte = byte;
        if (byte & 0x80 == 0) {
            if (shift < 63 and (last_byte & 0x40) != 0) {
                result |= @as(u64, 0xffffffffffffffff) << @intCast(shift +| 7);
            }
            return .{
                .value = @bitCast(result),
                .bytes_read = i + 1,
            };
        }
        shift +|= 7;
    }
    return error.UnexpectedEnd;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub fn writeU32Leb128(buf: []u8, value: u32) usize {
    var val = value;
    var i: usize = 0;
    while (true) {
        const byte: u8 = @truncate(val & 0x7f);
        val >>= 7;
        if (val == 0) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

pub fn writeU64Leb128(buf: []u8, value: u64) usize {
    var val = value;
    var i: usize = 0;
    while (true) {
        const byte: u8 = @truncate(val & 0x7f);
        val >>= 7;
        if (val == 0) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

pub fn writeS32Leb128(buf: []u8, value: i32) usize {
    var val: u32 = @bitCast(value);
    var i: usize = 0;
    while (true) {
        const byte: u8 = @truncate(val & 0x7f);
        val = @bitCast(@as(i32, @bitCast(val)) >> 7);
        // Done when remaining bits are all sign-extension of the current byte.
        const done = (val == 0 and byte & 0x40 == 0) or
            (val == 0xffffffff and byte & 0x40 != 0);
        if (done) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

pub fn writeS64Leb128(buf: []u8, value: i64) usize {
    var val: u64 = @bitCast(value);
    var i: usize = 0;
    while (true) {
        const byte: u8 = @truncate(val & 0x7f);
        val = @bitCast(@as(i64, @bitCast(val)) >> 7);
        const done = (val == 0 and byte & 0x40 == 0) or
            (val == 0xffffffffffffffff and byte & 0x40 != 0);
        if (done) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Fixed-length writing (always 5 bytes for u32)
// ---------------------------------------------------------------------------

pub fn writeFixedU32Leb128(buf: *[5]u8, value: u32) void {
    var val = value;
    for (0..4) |i| {
        buf[i] = @as(u8, @truncate(val & 0x7f)) | 0x80;
        val >>= 7;
    }
    buf[4] = @truncate(val & 0x7f);
}

// ---------------------------------------------------------------------------
// Length queries
// ---------------------------------------------------------------------------

pub fn u32Leb128Length(value: u32) usize {
    var val = value;
    var len: usize = 0;
    while (true) {
        val >>= 7;
        len += 1;
        if (val == 0) return len;
    }
}

pub fn u64Leb128Length(value: u64) usize {
    var val = value;
    var len: usize = 0;
    while (true) {
        val >>= 7;
        len += 1;
        if (val == 0) return len;
    }
}

// ===========================================================================
// Tests
// ===========================================================================

test "readU32Leb128 single byte zero" {
    const r = try readU32Leb128(&.{0x00});
    try testing.expectEqual(@as(u32, 0), r.value);
    try testing.expectEqual(@as(usize, 1), r.bytes_read);
}

test "readU32Leb128 single byte 127" {
    const r = try readU32Leb128(&.{0x7f});
    try testing.expectEqual(@as(u32, 127), r.value);
    try testing.expectEqual(@as(usize, 1), r.bytes_read);
}

test "readU32Leb128 two bytes 128" {
    const r = try readU32Leb128(&.{ 0x80, 0x01 });
    try testing.expectEqual(@as(u32, 128), r.value);
    try testing.expectEqual(@as(usize, 2), r.bytes_read);
}

test "readU32Leb128 two bytes 16383" {
    const r = try readU32Leb128(&.{ 0xff, 0x7f });
    try testing.expectEqual(@as(u32, 16383), r.value);
    try testing.expectEqual(@as(usize, 2), r.bytes_read);
}

test "readU32Leb128 three bytes 16384" {
    const r = try readU32Leb128(&.{ 0x80, 0x80, 0x01 });
    try testing.expectEqual(@as(u32, 16384), r.value);
    try testing.expectEqual(@as(usize, 3), r.bytes_read);
}

test "readU32Leb128 max u32" {
    const r = try readU32Leb128(&.{ 0xff, 0xff, 0xff, 0xff, 0x0f });
    try testing.expectEqual(@as(u32, 0xffffffff), r.value);
    try testing.expectEqual(@as(usize, 5), r.bytes_read);
}

test "readU32Leb128 overflow" {
    try testing.expectError(error.Overflow, readU32Leb128(&.{ 0xff, 0xff, 0xff, 0xff, 0x1f }));
}

test "readU32Leb128 unexpected end" {
    try testing.expectError(error.UnexpectedEnd, readU32Leb128(&.{0x80}));
    try testing.expectError(error.UnexpectedEnd, readU32Leb128(&.{}));
}

test "readS32Leb128 zero" {
    const r = try readS32Leb128(&.{0x00});
    try testing.expectEqual(@as(i32, 0), r.value);
    try testing.expectEqual(@as(usize, 1), r.bytes_read);
}

test "readS32Leb128 minus one" {
    const r = try readS32Leb128(&.{0x7f});
    try testing.expectEqual(@as(i32, -1), r.value);
    try testing.expectEqual(@as(usize, 1), r.bytes_read);
}

test "readS32Leb128 minus 128" {
    const r = try readS32Leb128(&.{ 0x80, 0x7f });
    try testing.expectEqual(@as(i32, -128), r.value);
    try testing.expectEqual(@as(usize, 2), r.bytes_read);
}

test "readS32Leb128 positive 64" {
    const r = try readS32Leb128(&.{0x40});
    // 0x40 has bit 6 set → sign-extended to negative: -64
    try testing.expectEqual(@as(i32, -64), r.value);
}

test "readS32Leb128 positive 63" {
    const r = try readS32Leb128(&.{0x3f});
    try testing.expectEqual(@as(i32, 63), r.value);
}

test "readS32Leb128 min i32" {
    const r = try readS32Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x78 });
    try testing.expectEqual(@as(i32, -2147483648), r.value);
    try testing.expectEqual(@as(usize, 5), r.bytes_read);
}

test "readS32Leb128 max i32" {
    const r = try readS32Leb128(&.{ 0xff, 0xff, 0xff, 0xff, 0x07 });
    try testing.expectEqual(@as(i32, 2147483647), r.value);
    try testing.expectEqual(@as(usize, 5), r.bytes_read);
}

test "readS33Leb128 reads the values an s33 can hold" {
    const cases = [_]struct { bytes: []const u8, value: i64, len: usize }{
        .{ .bytes = &.{0x00}, .value = 0, .len = 1 },
        .{ .bytes = &.{0x3f}, .value = 63, .len = 1 },
        .{ .bytes = &.{0x40}, .value = -64, .len = 1 },
        .{ .bytes = &.{0x7f}, .value = -1, .len = 1 },
        // The abstract heap types: `func` is -0x10, `noexn` is -0x17.
        .{ .bytes = &.{0x70}, .value = -0x10, .len = 1 },
        .{ .bytes = &.{0x69}, .value = -0x17, .len = 1 },
        .{ .bytes = &.{ 0xc0, 0x00 }, .value = 64, .len = 2 },
        .{ .bytes = &.{ 0xcd, 0x00 }, .value = 77, .len = 2 },
        // The ends of the range: -2^32 and 2^32-1.
        .{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x70 }, .value = -4294967296, .len = 5 },
        .{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, .value = 4294967295, .len = 5 },
    };
    for (cases) |c| {
        const r = try readS33Leb128(c.bytes);
        try testing.expectEqual(c.value, r.value);
        try testing.expectEqual(c.len, r.bytes_read);
    }
}

test "readS33Leb128 pads to five bytes but no further" {
    // Padding within the width is legal, and wasm-tools accepts it.
    const padded = try readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x00 });
    try testing.expectEqual(@as(i64, 0), padded.value);
    try testing.expectEqual(@as(usize, 5), padded.bytes_read);

    // A sixth byte is not padding: 33 bits do not reach it. Reading an s33
    // as an s64 accepted up to ten bytes, so a block signature or a heap
    // type could be written in a form no other tool admits.
    try testing.expectError(error.Overflow, readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }));
    try testing.expectError(
        error.Overflow,
        readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }),
    );
}

test "readS33Leb128 rejects a fifth byte that overflows 33 bits" {
    // On the fifth byte only bit 33 is left, so bits 34 and 35 have to
    // repeat its sign: the payload is 0x00..0x0f or 0x70..0x7f.
    try testing.expectError(error.Overflow, readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x10 }));
    try testing.expectError(error.Overflow, readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x20 }));
    try testing.expectError(error.Overflow, readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x6f }));
    _ = try readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x0f });
    _ = try readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x70 });
}

test "readS33Leb128 reports a truncated encoding" {
    try testing.expectError(error.UnexpectedEnd, readS33Leb128(&.{}));
    try testing.expectError(error.UnexpectedEnd, readS33Leb128(&.{0x80}));
    try testing.expectError(error.UnexpectedEnd, readS33Leb128(&.{ 0x80, 0x80, 0x80, 0x80 }));
}

test "readS33Leb128 agrees with readS64Leb128 wherever both are defined" {
    // The two differ only in width; within five bytes the value must match,
    // which is what makes the narrower reader a safe replacement.
    var buf: [max_s64_bytes]u8 = undefined;
    const values = [_]i64{ 0, 1, -1, 63, -64, 64, 77, 127, -128, 8191, -8192, 2147483647, -2147483648, 4294967295, -4294967296 };
    for (values) |v| {
        const n = writeS64Leb128(&buf, v);
        if (n > max_s33_bytes) continue;
        const wide = try readS64Leb128(buf[0..n]);
        const narrow = try readS33Leb128(buf[0..n]);
        try testing.expectEqual(wide.value, narrow.value);
        try testing.expectEqual(wide.bytes_read, narrow.bytes_read);
    }
}

test "readU64Leb128 max u64" {
    const r = try readU64Leb128(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 });
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), r.value);
    try testing.expectEqual(@as(usize, 10), r.bytes_read);
}

test "readU64Leb128 overflow" {
    try testing.expectError(error.Overflow, readU64Leb128(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x03 }));
}

test "readS64Leb128 minus one" {
    const r = try readS64Leb128(&.{0x7f});
    try testing.expectEqual(@as(i64, -1), r.value);
}

test "readS64Leb128 min i64" {
    const r = try readS64Leb128(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f });
    try testing.expectEqual(@as(i64, -9223372036854775808), r.value);
    try testing.expectEqual(@as(usize, 10), r.bytes_read);
}

test "readS64Leb128 max i64" {
    const r = try readS64Leb128(&.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 });
    try testing.expectEqual(@as(i64, 9223372036854775807), r.value);
    try testing.expectEqual(@as(usize, 10), r.bytes_read);
}

test "writeU32Leb128" {
    var buf: [max_u32_bytes]u8 = undefined;

    try testing.expectEqual(@as(usize, 1), writeU32Leb128(&buf, 0));
    try testing.expectEqual(@as(u8, 0x00), buf[0]);

    try testing.expectEqual(@as(usize, 1), writeU32Leb128(&buf, 127));
    try testing.expectEqual(@as(u8, 0x7f), buf[0]);

    try testing.expectEqual(@as(usize, 2), writeU32Leb128(&buf, 128));
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf[0..2]);

    try testing.expectEqual(@as(usize, 5), writeU32Leb128(&buf, 0xffffffff));
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, &buf);
}

test "writeS32Leb128" {
    var buf: [max_s32_bytes]u8 = undefined;

    try testing.expectEqual(@as(usize, 1), writeS32Leb128(&buf, 0));
    try testing.expectEqual(@as(u8, 0x00), buf[0]);

    try testing.expectEqual(@as(usize, 1), writeS32Leb128(&buf, -1));
    try testing.expectEqual(@as(u8, 0x7f), buf[0]);

    const n = writeS32Leb128(&buf, -128);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x7f }, buf[0..n]);

    const n2 = writeS32Leb128(&buf, -2147483648);
    try testing.expectEqual(@as(usize, 5), n2);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80, 0x80, 0x78 }, buf[0..n2]);
}

test "writeU64Leb128" {
    var buf: [max_u64_bytes]u8 = undefined;
    const n = writeU64Leb128(&buf, 0xffffffffffffffff);
    try testing.expectEqual(@as(usize, 10), n);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, buf[0..n]);
}

test "writeS64Leb128" {
    var buf: [max_s64_bytes]u8 = undefined;

    try testing.expectEqual(@as(usize, 1), writeS64Leb128(&buf, 0));
    try testing.expectEqual(@as(u8, 0x00), buf[0]);

    try testing.expectEqual(@as(usize, 1), writeS64Leb128(&buf, -1));
    try testing.expectEqual(@as(u8, 0x7f), buf[0]);

    const n = writeS64Leb128(&buf, -9223372036854775808);
    try testing.expectEqual(@as(usize, 10), n);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f }, buf[0..n]);
}

test "writeFixedU32Leb128" {
    var buf: [5]u8 = undefined;

    writeFixedU32Leb128(&buf, 0);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80, 0x80, 0x00 }, &buf);

    writeFixedU32Leb128(&buf, 1);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x80, 0x80, 0x80, 0x00 }, &buf);

    writeFixedU32Leb128(&buf, 0xffffffff);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff, 0x0f }, &buf);
}

test "u32Leb128Length" {
    try testing.expectEqual(@as(usize, 1), u32Leb128Length(0));
    try testing.expectEqual(@as(usize, 1), u32Leb128Length(127));
    try testing.expectEqual(@as(usize, 2), u32Leb128Length(128));
    try testing.expectEqual(@as(usize, 2), u32Leb128Length(16383));
    try testing.expectEqual(@as(usize, 3), u32Leb128Length(16384));
    try testing.expectEqual(@as(usize, 5), u32Leb128Length(0xffffffff));
}

test "u64Leb128Length" {
    try testing.expectEqual(@as(usize, 1), u64Leb128Length(0));
    try testing.expectEqual(@as(usize, 1), u64Leb128Length(127));
    try testing.expectEqual(@as(usize, 10), u64Leb128Length(0xffffffffffffffff));
}

test "round trip u32" {
    var buf: [max_u32_bytes]u8 = undefined;
    const values = [_]u32{ 0, 1, 127, 128, 255, 16383, 16384, 0x7fffffff, 0xffffffff };
    for (values) |v| {
        const n = writeU32Leb128(&buf, v);
        const r = try readU32Leb128(buf[0..n]);
        try testing.expectEqual(v, r.value);
        try testing.expectEqual(n, r.bytes_read);
    }
}

test "round trip u64" {
    var buf: [max_u64_bytes]u8 = undefined;
    const values = [_]u64{ 0, 1, 127, 128, 0xffffffff, 0x100000000, 0xffffffffffffffff };
    for (values) |v| {
        const n = writeU64Leb128(&buf, v);
        const r = try readU64Leb128(buf[0..n]);
        try testing.expectEqual(v, r.value);
        try testing.expectEqual(n, r.bytes_read);
    }
}

test "round trip s32" {
    var buf: [max_s32_bytes]u8 = undefined;
    const values = [_]i32{ 0, 1, -1, 63, -64, 127, -128, 8191, -8192, 2147483647, -2147483648 };
    for (values) |v| {
        const n = writeS32Leb128(&buf, v);
        const r = try readS32Leb128(buf[0..n]);
        try testing.expectEqual(v, r.value);
        try testing.expectEqual(n, r.bytes_read);
    }
}

test "round trip s64" {
    var buf: [max_s64_bytes]u8 = undefined;
    const values = [_]i64{ 0, 1, -1, 63, -64, 2147483647, -2147483648, 9223372036854775807, -9223372036854775808 };
    for (values) |v| {
        const n = writeS64Leb128(&buf, v);
        const r = try readS64Leb128(buf[0..n]);
        try testing.expectEqual(v, r.value);
        try testing.expectEqual(n, r.bytes_read);
    }
}

test "writeFixedU32Leb128 round trip" {
    var buf: [5]u8 = undefined;
    const values = [_]u32{ 0, 1, 127, 128, 16384, 0xffffffff };
    for (values) |v| {
        writeFixedU32Leb128(&buf, v);
        const r = try readU32Leb128(&buf);
        try testing.expectEqual(v, r.value);
        try testing.expectEqual(@as(usize, 5), r.bytes_read);
    }
}

test "u32Leb128Length matches writeU32Leb128" {
    var buf: [max_u32_bytes]u8 = undefined;
    const values = [_]u32{ 0, 1, 127, 128, 16383, 16384, 0x1fffff, 0xfffffff, 0xffffffff };
    for (values) |v| {
        const written = writeU32Leb128(&buf, v);
        try testing.expectEqual(written, u32Leb128Length(v));
    }
}
