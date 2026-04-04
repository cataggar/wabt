//! WebAssembly binary format writer.
//!
//! Serializes a Module IR to the .wasm binary format.

const std = @import("std");
const Module = @import("../Module.zig").Module;
const reader = @import("reader.zig");

pub const WriteError = error{
    OutOfMemory,
};

/// Write a WebAssembly binary module to a buffer.
pub fn writeModule(allocator: std.mem.Allocator, module: *const Module) WriteError![]u8 {
    _ = module;
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Magic number and version
    try buf.appendSlice(&reader.magic);
    try buf.writer().writeInt(u32, reader.version, .little);

    // TODO: write sections

    return buf.toOwnedSlice();
}

test "write empty module" {
    const allocator = std.testing.allocator;
    var module = Module.init(allocator);
    defer module.deinit();

    const bytes = try writeModule(allocator, &module);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expect(std.mem.eql(u8, bytes[0..4], &reader.magic));
}
