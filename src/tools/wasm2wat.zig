const std = @import("std");
const wabt = @import("wabt");

/// Convert WASM binary to WAT text format.
/// Reads the binary module and serializes it as WAT text.
pub fn convert(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return wabt.text.Writer.writeModule(allocator, &module);
}

const usage =
    \\wasm2wat — translate WebAssembly binary to text format
    \\
    \\Usage: wasm2wat [options] <file>
    \\
    \\  -h, --help            Show this help message
    \\  -o, --output <file>   Output file (default: stdout)
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    _ = args_it.next(); // skip program name

    var input_file: ?[:0]const u8 = null;
    var output_file: ?[:0]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_file = args_it.next() orelse
                std.process.fatal("missing argument for '{s}'", .{arg});
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return;
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse
        std.process.fatal("no input file specified. Use --help for usage.", .{});

    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        in_path,
        gpa,
        .limited(10 * 1024 * 1024),
    ) catch |err|
        std.process.fatal("cannot open '{s}': {t}", .{ in_path, err });
    defer gpa.free(wasm_bytes);

    const wat = convert(gpa, wasm_bytes) catch |err|
        std.process.fatal("failed to convert '{s}': {t}", .{ in_path, err });
    defer gpa.free(wat);

    if (output_file) |out_path| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = wat }) catch |err|
            std.process.fatal("cannot write '{s}': {t}", .{ out_path, err });
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, wat);
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
