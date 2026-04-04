const std = @import("std");
const wabt = @import("wabt");

/// Convert WAT text format to WASM binary.
/// Parses the source, validates the module, then serializes to binary.
pub fn convert(allocator: std.mem.Allocator, wat_source: []const u8) ![]u8 {
    var module = try wabt.text.Parser.parseModule(allocator, wat_source);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});

    return wabt.binary.writer.writeModule(allocator, &module);
}

const usage =
    \\wat2wasm — translate WebAssembly text format to binary
    \\
    \\Usage: wat2wasm [options] <file>
    \\
    \\  -h, --help            Show this help message
    \\  -o, --output <file>   Output file (default: <input>.wasm)
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

    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        in_path,
        gpa,
        .limited(10 * 1024 * 1024),
    ) catch |err|
        std.process.fatal("cannot open '{s}': {t}", .{ in_path, err });
    defer gpa.free(source);

    const wasm = convert(gpa, source) catch |err|
        std.process.fatal("failed to convert '{s}': {t}", .{ in_path, err });
    defer gpa.free(wasm);

    const out_path: []const u8 = if (output_file) |of| of else blk: {
        const stem: []const u8 = if (std.mem.endsWith(u8, in_path, ".wat"))
            in_path[0 .. in_path.len - 4]
        else
            in_path;
        break :blk std.fmt.allocPrint(init.arena.allocator(), "{s}.wasm", .{stem}) catch
            std.process.fatal("out of memory", .{});
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = wasm }) catch |err|
        std.process.fatal("cannot write '{s}': {t}", .{ out_path, err });
}

test "convert empty module" {
    const wasm = try convert(std.testing.allocator, "(module)");
    defer std.testing.allocator.free(wasm);
    try std.testing.expectEqualSlices(u8, &wabt.binary.reader.magic, wasm[0..4]);
}

test "convert module round-trips through binary" {
    const source = "(module)";
    const wasm = try convert(std.testing.allocator, source);
    defer std.testing.allocator.free(wasm);
    // Verify it starts with magic + version
    try std.testing.expect(wasm.len >= 8);
    try std.testing.expectEqualSlices(u8, &wabt.binary.reader.magic, wasm[0..4]);
    // Version 1
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, wasm[4..8], .little));
}
