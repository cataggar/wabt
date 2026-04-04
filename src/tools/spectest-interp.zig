const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\spectest-interp — run WebAssembly spec tests
        \\
        \\Usage: spectest-interp [options] <file>
        \\
        \\  -v, --verbose   Verbose output
        \\
    , .{});
    _ = wabt;
}
