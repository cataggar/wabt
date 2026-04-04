//! Core WebAssembly types.
//!
//! Value types, reference types, function signatures, limits,
//! memory/table/global types, and import/export descriptors.

const std = @import("std");

/// WebAssembly value types.
pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,
    funcref = 0x70,
    externref = 0x6f,
};

/// Limits with an optional maximum.
pub const Limits = struct {
    min: u32,
    max: ?u32 = null,
};

/// Function signature: parameter and result types.
pub const FuncType = struct {
    params: []const ValType = &.{},
    results: []const ValType = &.{},
};

/// Memory type.
pub const MemoryType = struct {
    limits: Limits,
    is_shared: bool = false,
};

/// Table type.
pub const TableType = struct {
    elem_type: ValType,
    limits: Limits,
};

/// Mutability of a global.
pub const Mutability = enum { immutable, mutable };

/// Global type.
pub const GlobalType = struct {
    val_type: ValType,
    mutability: Mutability = .immutable,
};

test "ValType encoding" {
    try std.testing.expectEqual(@as(u8, 0x7f), @intFromEnum(ValType.i32));
    try std.testing.expectEqual(@as(u8, 0x7e), @intFromEnum(ValType.i64));
}
