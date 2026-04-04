const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm2c — translate WebAssembly binary to C source
        \\
        \\Usage: wasm2c [options] <file>
        \\
        \\  -o, --output <file>   Output C file
        \\  -n, --module-name     Module name (default: derived from filename)
        \\
    , .{});
    _ = wabt;
}
