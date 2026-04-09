const std = @import("std");
const wabt = @import("wabt");

/// Convert WebAssembly binary bytes to text format (fuzz-friendly wrapper).
pub fn fuzzWasm2Wat(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    return wabt.text.Writer.writeModule(allocator, &module);
}

pub fn main() void {
    std.debug.print("wasm2wat-fuzz - fuzz target for wasm to wat conversion\n", .{});
}

test "empty module fuzz target works" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const wat = try fuzzWasm2Wat(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "module") != null);
}
