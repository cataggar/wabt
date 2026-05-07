const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt validate [options] <file.wasm>
    \\
    \\Validate a WebAssembly binary.
    \\
    \\Options:
    \\  -h, --help   Show this help
    \\
;

/// Validate a WASM binary module.
/// Reads the binary, then runs the validator over the resulting module.
pub fn validateBytes(allocator: std.mem.Allocator, wasm_bytes: []const u8) !void {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var input_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(init.io, usage);
            return;
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use `wabt help validate` for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    validateBytes(alloc, source) catch |err| {
        std.debug.print("{s}: validation error: {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "validate minimal module" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try validateBytes(std.testing.allocator, &wasm);
}

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, validateBytes(std.testing.allocator, &bad));
}

test "reject truncated input" {
    const truncated = [_]u8{ 0x00, 0x61 };
    try std.testing.expectError(error.UnexpectedEof, validateBytes(std.testing.allocator, &truncated));
}
