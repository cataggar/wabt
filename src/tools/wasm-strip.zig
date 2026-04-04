const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm-strip — strip custom sections from a WebAssembly binary
        \\
        \\Usage: wasm-strip [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: overwrite input)
        \\
    , .{});
    _ = wabt;
}
