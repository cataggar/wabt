const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wat2wasm — translate WebAssembly text format to binary
        \\
        \\Usage: wat2wasm [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\  -v, --verbose         Verbose output
        \\      --debug-parser    Debug parser output
        \\
    , .{});
    _ = wabt;
}
