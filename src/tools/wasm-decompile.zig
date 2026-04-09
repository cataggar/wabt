const std = @import("std");
const wabt = @import("wabt");

/// Read a WebAssembly binary and produce pseudo-code via Decompiler.
pub fn decompile(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    return wabt.Decompiler.decompile(allocator, &module);
}

pub fn main() void {
    std.debug.print(
        \\wasm-decompile - decompile a WebAssembly binary
        \\
        \\Usage: wasm-decompile [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{});
}

test "empty module produces minimal output" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const output = try decompile(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "// Module:") != null);
}
