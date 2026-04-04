const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm-decompile — decompile a WebAssembly binary
        \\
        \\Usage: wasm-decompile [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{});
    _ = wabt;
}
