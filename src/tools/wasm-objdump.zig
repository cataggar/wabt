const std = @import("std");
const wabt = @import("wabt");

/// Read a WebAssembly binary and produce a text summary of its sections.
pub fn dump(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return std.fmt.allocPrint(allocator,
        \\wasm-objdump:
        \\
        \\Section Details:
        \\
        \\  Types:           {d}
        \\  Functions:       {d}
        \\  Tables:          {d}
        \\  Memories:        {d}
        \\  Globals:         {d}
        \\  Exports:         {d}
        \\  Imports:         {d}
        \\  Custom sections: {d}
        \\
    , .{
        module.module_types.items.len,
        module.funcs.items.len,
        module.tables.items.len,
        module.memories.items.len,
        module.globals.items.len,
        module.exports.items.len,
        module.imports.items.len,
        module.customs.items.len,
    });
}

pub fn main() void {
    std.debug.print(
        \\wasm-objdump - dump the contents of a WebAssembly binary
        \\
        \\Usage: wasm-objdump [options] <file>
        \\
        \\  -h, --headers     Print headers
        \\  -d, --disassemble Disassemble function bodies
        \\  -x, --details     Show section details
        \\  -s, --full-contents  Show full section contents
        \\
    , .{});
}

test "empty module produces header info" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const output = try dump(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "wasm-objdump:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Section Details:") != null);
}
