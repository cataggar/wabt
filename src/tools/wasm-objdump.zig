const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wasm-objdump — dump the contents of a WebAssembly binary
        \\
        \\Usage: wasm-objdump [options] <file>
        \\
        \\  -h, --headers     Print headers
        \\  -d, --disassemble Disassemble function bodies
        \\  -x, --details     Show section details
        \\  -s, --full-contents  Show full section contents
        \\
    , .{});
    _ = wabt;
}
