const std = @import("std");
const wabt = @import("wabt");

/// Read a WebAssembly binary and interpret it (stub).
pub fn interpret(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return std.fmt.allocPrint(allocator, "interpreted: {d} functions\n", .{module.funcs.items.len});
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var args_it = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.next();

    var input_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\wasm-interp {s} interpret a WebAssembly binary
                \\
                \\Usage: wasm-interp [options] <file>
                \\
                \\  -h, --help         Show this help message
                \\  --run-all-exports  Run all exported functions
                \\
            , .{wabt.version});
            return;
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

    const output = interpret(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(output);

    std.fs.File.stdout().writeAll(output) catch {};
}

test "empty module runs" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const result = try interpret(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "interpreted") != null);
}
