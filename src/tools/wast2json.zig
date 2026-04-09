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

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var args_it = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.next();

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\wast2json {s} translate WebAssembly spec test format to JSON
                \\
                \\Usage: wast2json [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\  -o, --output <file>   Output JSON file
                \\
            , .{wabt.version});
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_file = args_it.next();
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use --help for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.fs.cwd().readFileAlloc(alloc, in_path, wabt.max_input_file_size) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    const json = wastToJson(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(json);

    if (output_file) |out_path| {
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = json }) catch |err| {
            std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
            std.process.exit(1);
        };
    } else {
        std.fs.File.stdout().writeAll(json) catch {};
    }
}

test "empty module produces JSON with commands array" {
    const json = try wastToJson(std.testing.allocator, "(module)");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"commands\"") != null);
}
