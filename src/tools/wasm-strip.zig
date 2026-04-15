const std = @import("std");
const wabt = @import("wabt");

/// Strip custom sections from a WebAssembly binary.
pub fn strip(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    module.customs.clearRetainingCapacity();
    return wabt.binary.writer.writeModule(allocator, &module);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args_it = try init.minimal.args.iterateAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.next();

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\wasm-strip {s} strip custom sections from a WebAssembly binary
                \\
                \\Usage: wasm-strip [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\  -o, --output <file>   Output file (default: overwrite input)
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

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    const wasm = strip(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(wasm);

    const out_path = output_file orelse in_path;
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = wasm }) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

test "module with custom section is stripped" {
    const wasm_with_custom = &[_]u8{
        0x00, 0x61, 0x73, 0x6d, // magic
        0x01, 0x00, 0x00, 0x00, // version
        0x00, // custom section id
        0x05, // section size = 5
        0x04, // name length = 4
        't',  'e',  's',  't', // name = "test"
    };
    const result = try strip(std.testing.allocator, wasm_with_custom);
    defer std.testing.allocator.free(result);

    // Re-read and verify no custom sections remain
    var module = try wabt.binary.reader.readModule(std.testing.allocator, result);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 0), module.customs.items.len);
}
