const std = @import("std");
const wabt = @import("wabt");

/// Parse WAT source and write it back (identity transform / desugaring).
pub fn desugar(allocator: std.mem.Allocator, wat_source: []const u8) ![]u8 {
    var module = try wabt.text.Parser.parseModule(allocator, wat_source);
    defer module.deinit();
    return wabt.text.Writer.writeModule(allocator, &module);
}

pub fn main() void {
    std.debug.print(
        \\wat-desugar - remove syntactic sugar from WebAssembly text
        \\
        \\Usage: wat-desugar [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{});
}

test "empty module round-trips" {
    const wat = try desugar(std.testing.allocator, "(module)");
    defer std.testing.allocator.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "module") != null);
}
