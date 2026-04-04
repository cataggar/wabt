//! WebAssembly text format writer.
//!
//! Serializes a Module IR back to .wat text format.

const std = @import("std");
const Module = @import("../Module.zig").Module;

pub const WriteError = error{
    OutOfMemory,
};

/// Write a Module as WebAssembly text format.
pub fn writeModule(allocator: std.mem.Allocator, module: *const Module) WriteError![]u8 {
    _ = module;
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("(module");
    // TODO: write sections
    try buf.appendSlice(")\n");

    return buf.toOwnedSlice();
}

test "write empty module" {
    const allocator = std.testing.allocator;
    var module = Module.init(allocator);
    defer module.deinit();

    const wat = try writeModule(allocator, &module);
    defer allocator.free(wat);
    try std.testing.expect(std.mem.startsWith(u8, wat, "(module"));
}
