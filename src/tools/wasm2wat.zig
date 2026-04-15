const std = @import("std");
const wabt = @import("wabt");

/// Convert WASM binary to WAT text format.
/// Reads the binary module and serializes it as WAT text.
pub fn convert(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return wabt.text.Writer.writeModule(allocator, &module);
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
                \\wasm2wat {s} translate WebAssembly binary to text format
                \\
                \\Usage: wasm2wat [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\  -o, --output <file>   Output file (default: stdout)
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

    const wat = convert(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(wat);

    if (output_file) |out_path| {
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = wat }) catch |err| {
            std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
            std.process.exit(1);
        };
    } else {
        std.Io.File.stdout().writeStreamingAll(init.io, wat) catch {};
    }
}

test "convert minimal wasm module" {
    // Minimal valid wasm: magic + version
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const wat = try convert(std.testing.allocator, &wasm);
    defer std.testing.allocator.free(wat);
    try std.testing.expect(std.mem.startsWith(u8, wat, "(module"));
}

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, convert(std.testing.allocator, &bad));
}
