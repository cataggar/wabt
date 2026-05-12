const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt module objdump [options] <file.wasm>
    \\
    \\Dump information about sections in a WebAssembly binary.
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: stdout)
    \\
;

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

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else if (arg.len > 0 and arg[0] != '-') {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use `wabt module objdump help` for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
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
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = output }) catch |err| {
            std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
            std.process.exit(1);
        };
    } else {
        std.Io.File.stdout().writeStreamingAll(init.io, output) catch {};
    }
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "empty module produces header info" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const output = try dump(std.testing.allocator, empty_wasm);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "wasm-objdump:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Section Details:") != null);
}
