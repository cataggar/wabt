const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt text print [options] <file.wasm>
    \\
    \\Print a WebAssembly binary as WebAssembly text format.
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: stdout)
    \\  -h, --help            Show this help
    \\
;

/// Convert WASM binary to WAT text format.
/// Reads the binary module and serializes it as WAT text.
pub fn convert(allocator: std.mem.Allocator, wasm_bytes: []const u8) ![]u8 {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    return wabt.text.Writer.writeModule(allocator, &module);
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
        std.debug.print("error: no input file. Use `wabt help print` for usage.\n", .{});
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

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "convert minimal wasm module" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const wat = try convert(std.testing.allocator, &wasm);
    defer std.testing.allocator.free(wat);
    try std.testing.expect(std.mem.startsWith(u8, wat, "(module"));
}

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, convert(std.testing.allocator, &bad));
}
