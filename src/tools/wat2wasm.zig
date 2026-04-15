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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args_it = try init.minimal.args.iterateAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.next(); // skip program name

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\wat2wasm {s} translate WebAssembly text format to binary
                \\
                \\Usage: wat2wasm [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\  -o, --output <file>   Output file (default: <input>.wasm)
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

    const wasm = convert(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(wasm);

    const out_path = output_file orelse blk: {
        // Replace .wat with .wasm
        if (std.mem.endsWith(u8, in_path, ".wat")) {
            const stem = in_path[0 .. in_path.len - 4];
            break :blk std.fmt.allocPrint(alloc, "{s}.wasm", .{stem}) catch in_path;
        }
        break :blk std.fmt.allocPrint(alloc, "{s}.wasm", .{in_path}) catch in_path;
    };

    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(init.io, .{ .sub_path = out_path, .data = wasm }) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
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
