const std = @import("std");
const wabt = @import("wabt");

/// Parse WAT source and produce a stub JSON representation of test commands.
pub fn wastToJson(allocator: std.mem.Allocator, wat_source: []const u8) ![]u8 {
    var module = try wabt.text.Parser.parseModule(allocator, wat_source);
    defer module.deinit();

    const wasm = try wabt.binary.writer.writeModule(allocator, &module);
    defer allocator.free(wasm);

    return std.fmt.allocPrint(allocator,
        \\{{"commands":[{{"type":"module","filename":"test.wasm","line":1}}]}}
        \\
    , .{});
}

pub fn main() void {
    std.debug.print(
        \\wast2json {s} translate WebAssembly spec test format to JSON
        \\
        \\Usage: wast2json [options] <file>
        \\
        \\  -o, --output <file>   Output JSON file
        \\
    , .{wabt.version});
}

test "empty module produces JSON with commands array" {
    const json = try wastToJson(std.testing.allocator, "(module)");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commands\"") != null);
}
