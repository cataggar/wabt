//! WebAssembly binary format reader.
//!
//! Reads a .wasm binary file and produces a Module IR.
//! Implements the binary encoding specified in the WebAssembly spec.

const std = @import("std");
const Module = @import("../Module.zig").Module;

/// Magic number: \0asm
pub const magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
/// WebAssembly binary format version.
pub const version: u32 = 1;

/// Section IDs in the binary format.
pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    tag = 13,
};

pub const ReadError = error{
    InvalidMagic,
    InvalidVersion,
    UnexpectedEof,
    InvalidSection,
    InvalidLeb128,
    OutOfMemory,
};

/// Read a WebAssembly binary module from bytes.
pub fn readModule(allocator: std.mem.Allocator, bytes: []const u8) ReadError!Module {
    if (bytes.len < 8) return error.UnexpectedEof;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidMagic;
    const ver = std.mem.readInt(u32, bytes[4..8], .little);
    if (ver != version) return error.InvalidVersion;

    return Module.init(allocator);
    // TODO: parse sections
}

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, readModule(std.testing.allocator, &bad));
}

test "accept valid header" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var module = try readModule(std.testing.allocator, &header);
    defer module.deinit();
}
