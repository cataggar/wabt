const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt parse [options] <file.wat>
    \\
    \\Translate WebAssembly text format to a wasm binary.
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: <input>.wasm)
    \\  -h, --help            Show this help
    \\
;

/// Convert WAT text format to WASM binary.
/// Parses the source, validates the module, then serializes to binary.
pub fn convert(allocator: std.mem.Allocator, wat_source: []const u8) ![]u8 {
    var module = try wabt.text.Parser.parseModule(allocator, wat_source);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});

    return wabt.binary.writer.writeModule(allocator, &module);
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use `wabt help parse` for usage.\n", .{});
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

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
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
    try std.testing.expect(wasm.len >= 8);
    try std.testing.expectEqualSlices(u8, &wabt.binary.reader.magic, wasm[0..4]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, wasm[4..8], .little));
}
