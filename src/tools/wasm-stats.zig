const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm-stats — show statistics for a WebAssembly binary
        \\
        \\Usage: wasm-stats [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\
    , .{});
    _ = wabt;
}
