const std = @import("std");
const wabt = @import("wabt");

/// Statistics about a WebAssembly module.
pub const Stats = struct {
    types: usize,
    funcs: usize,
    tables: usize,
    memories: usize,
    globals: usize,
    exports: usize,
    imports: usize,
    customs: usize,
    data_segments: usize,
    elem_segments: usize,
};

/// Read a WebAssembly binary and compute statistics.
pub fn stats(allocator: std.mem.Allocator, wasm_bytes: []const u8) !Stats {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    return .{
        .types = module.module_types.items.len,
        .funcs = module.funcs.items.len,
        .tables = module.tables.items.len,
        .memories = module.memories.items.len,
        .globals = module.globals.items.len,
        .exports = module.exports.items.len,
        .imports = module.imports.items.len,
        .customs = module.customs.items.len,
        .data_segments = module.data_segments.items.len,
        .elem_segments = module.elem_segments.items.len,
    };
}

pub fn main() void {
    std.debug.print(
        \\wasm-stats {s} show statistics for a WebAssembly binary
        \\
        \\Usage: wasm-stats [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{wabt.version});
}

test "empty module returns zero stats" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const s = try stats(std.testing.allocator, empty_wasm);
    try std.testing.expectEqual(@as(usize, 0), s.funcs);
    try std.testing.expectEqual(@as(usize, 0), s.types);
    try std.testing.expectEqual(@as(usize, 0), s.exports);
}
