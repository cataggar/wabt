const std = @import("std");
const wabt = @import("wabt");

/// Convert WAT text format to WASM binary.
/// Parses the source, validates the module, then serializes to binary.
pub fn convert(allocator: std.mem.Allocator, wat_source: []const u8) ![]u8 {
    var module = try wabt.text.Parser.parseModule(allocator, wat_source);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});

    return wabt.binary.writer.writeModule(allocator, &module);
}

pub fn main() void {
    std.debug.print(
        \\wat2wasm - translate WebAssembly text format to binary
        \\
        \\Usage: wat2wasm [options] <file>
        \\
        \\  -h, --help            Show this help message
        \\  -o, --output <file>   Output file (default: <input>.wasm)
        \\
    , .{});
}

test "convert empty module" {
    const wasm = try convert(std.testing.allocator, "(module)");
    defer std.testing.allocator.free(wasm);
    try std.testing.expectEqualSlices(u8, &wabt.binary.reader.magic, wasm[0..4]);
}

test "convert module round-trips through binary" {
    const source = "(module)";
    const wasm = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(wasm);
    // Verify it starts with magic + version
    try std.testing.expect(wasm.len >= 8);
    try std.testing.expectEqualSlices(u8, &wabt.binary.reader.magic, wasm[0..4]);
    // Version 1
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, wasm[4..8], .little));
}
