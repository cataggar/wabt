const std = @import("std");
const wabt = @import("wabt");

/// Read a WebAssembly binary and produce a text summary of its sections.
pub fn dump(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return std.fmt.allocPrint(allocator,
        \\wasm-objdump:
        \\
        \\Section Details:
        \\
        \\  Types:           {d}
        \\  Functions:       {d}
        \\  Tables:          {d}
        \\  Memories:        {d}
        \\  Globals:         {d}
        \\  Exports:         {d}
        \\  Imports:         {d}
        \\  Custom sections: {d}
        \\
    , .{
        module.module_types.items.len,
        module.funcs.items.len,
        module.tables.items.len,
        module.memories.items.len,
        module.globals.items.len,
        module.exports.items.len,
        module.imports.items.len,
        module.customs.items.len,
    });
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
                \\wasm-objdump {s} dump the contents of a WebAssembly binary
                \\
                \\Usage: wasm-objdump [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\  -o, --output <file>   Output file (default: stdout)
                \\
            , .{wabt.version});
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_file = args_it.next();
        } else if (arg[0] != '-') {
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

    const output = dump(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(output);

    if (output_file) |out_path| {
        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = output }) catch |err| {
            std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
            std.process.exit(1);
        };
    } else {
        std.fs.File.stdout().writeAll(output) catch {};
    }
}

test "empty module produces header info" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const output = try dump(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "wasm-objdump:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Section Details:") != null);
}
