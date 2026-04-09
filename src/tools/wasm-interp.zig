const std = @import("std");
const wabt = @import("wabt");

/// Read a WebAssembly binary and interpret it (stub).
pub fn interpret(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return std.fmt.allocPrint(allocator, "interpreted: {d} functions\n", .{module.funcs.items.len});
}

pub fn main() void {
    std.debug.print(
        \\wasm-interp {s} - interpret a WebAssembly binary
        \\
        \\Usage: wasm-interp [options] <file>
        \\
        \\  --run-all-exports  Run all exported functions
        \\  --wasi             Enable WASI support
        \\
    , .{wabt.version});
}

test "empty module runs" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const result = try interpret(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "interpreted") != null);
}
