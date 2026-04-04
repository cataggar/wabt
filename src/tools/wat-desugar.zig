const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wat-desugar — remove syntactic sugar from WebAssembly text
        \\
        \\Usage: wat-desugar [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{});
    _ = wabt;
}
