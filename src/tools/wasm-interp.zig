const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm-interp — interpret a WebAssembly binary
        \\
        \\Usage: wasm-interp [options] <file>
        \\
        \\  --run-all-exports  Run all exported functions
        \\  --wasi             Enable WASI support
        \\
    , .{});
    _ = wabt;
}
