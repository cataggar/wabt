const std = @import("std");
const wabt = @import("wabt");

pub fn main() void {
    std.debug.print(
        \\wast2json — translate WebAssembly spec test format to JSON
        \\
        \\Usage: wast2json [options] <file>
        \\
        \\  -o, --output <file>   Output JSON file
        \\
    , .{});
    _ = wabt;
}
