const std = @import("std");
const wabt = @import("wabt");

/// Validate a WASM binary module.
/// Reads the binary, then runs the validator over the resulting module.
pub fn validateBytes(allocator: std.mem.Allocator, wasm_bytes: []const u8) !void {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});
}

pub fn main() void {
    std.debug.print(
        \\wasm-validate — validate a WebAssembly binary
        \\
        \\Usage: wasm-validate [options] <file>
        \\
        \\  -h, --help            Show this help message
        \\
    , .{});
}

test "validate minimal module" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try validateBytes(std.testing.allocator, &wasm);
}

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, validateBytes(std.testing.allocator, &bad));
}

test "reject truncated input" {
    const truncated = [_]u8{ 0x00, 0x61 };
    try std.testing.expectError(error.UnexpectedEof, validateBytes(std.testing.allocator, &truncated));
}
