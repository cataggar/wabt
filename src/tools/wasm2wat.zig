const std = @import("std");
const wabt = @import("wabt");

/// Convert WASM binary to WAT text format.
/// Reads the binary module and serializes it as WAT text.
pub fn convert(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return wabt.text.Writer.writeModule(allocator, &module);
}

pub fn main() void {
    std.debug.print(
        \\wasm2wat {s} - translate WebAssembly binary to text format
        \\
        \\Usage: wasm2wat [options] <file>
        \\
        \\  -h, --help            Show this help message
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{wabt.version});
}

test "convert minimal wasm module" {
    // Minimal valid wasm: magic + version
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const wat = try convert(std.testing.allocator, &wasm);
    defer std.testing.allocator.free(wat);
    try std.testing.expect(std.mem.startsWith(u8, wat, "(module"));
}

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, convert(std.testing.allocator, &bad));
}
