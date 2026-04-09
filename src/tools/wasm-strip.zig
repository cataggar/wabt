const std = @import("std");
const wabt = @import("wabt");

/// Strip custom sections from a WebAssembly binary.
pub fn strip(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    module.customs.clearRetainingCapacity();
    return wabt.binary.writer.writeModule(allocator, &module);
}

pub fn main() void {
    std.debug.print(
        \\wasm-strip {s} - strip custom sections from a WebAssembly binary
        \\
        \\Usage: wasm-strip [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\
    , .{wabt.version});
}

test "module with custom section is stripped" {
    const wasm_with_custom = &[_]u8{
        0x00, 0x61, 0x73, 0x6d, // magic
        0x01, 0x00, 0x00, 0x00, // version
        0x00, // custom section id
        0x05, // section size = 5
        0x04, // name length = 4
        't',  'e',  's',  't', // name = "test"
    };
    const result = try strip(std.testing.allocator, wasm_with_custom);
    defer std.testing.allocator.free(result);

    // Re-read and verify no custom sections remain
    var module = try wabt.binary.reader.readModule(std.testing.allocator, result);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 0), module.customs.items.len);
}
