const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm-validate — validate a WebAssembly binary
        \\
        \\Usage: wasm-validate [options] <file>
        \\
        \\  --enable-exceptions   Enable exceptions proposal
        \\  --enable-threads      Enable threads proposal
        \\
    , .{});
    _ = wabt;
}
