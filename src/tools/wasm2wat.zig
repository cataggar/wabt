const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm2wat — translate WebAssembly binary to text format
        \\
        \\Usage: wasm2wat [options] <file>
        \\
        \\  -o, --output <file>   Output file (default: stdout)
        \\      --no-debug-names  Ignore debug names in binary
        \\
    , .{});
    _ = wabt;
}
