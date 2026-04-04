//! WebAssembly opcodes.
//!
//! Each opcode maps to a WebAssembly instruction. Multi-byte opcodes
//! use a prefix byte followed by a LEB128-encoded index.

const std = @import("std");

/// Single-byte opcodes (0x00–0xFF).
pub const Code = enum(u8) {
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    @"if" = 0x04,
    @"else" = 0x05,
    end = 0x0b,
    br = 0x0c,
    br_if = 0x0d,
    br_table = 0x0e,
    @"return" = 0x0f,
    call = 0x10,
    call_indirect = 0x11,

    // Parametric
    drop = 0x1a,
    select = 0x1b,

    // Variable
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Memory
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2a,
    f64_load = 0x2b,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,

    // Constants
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // Comparison
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,

    // Arithmetic
    i32_add = 0x6a,
    i32_sub = 0x6b,
    i32_mul = 0x6c,

    _,
};

/// Prefix bytes for multi-byte opcodes.
pub const Prefix = enum(u8) {
    gc = 0xfb,
    simd = 0xfd,
    threads = 0xfe,
    misc = 0xfc,
};

test "opcode encoding" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(Code.@"unreachable"));
    try std.testing.expectEqual(@as(u8, 0x0b), @intFromEnum(Code.end));
    try std.testing.expectEqual(@as(u8, 0x41), @intFromEnum(Code.i32_const));
}
