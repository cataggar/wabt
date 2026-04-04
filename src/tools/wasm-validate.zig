const std = @import("std");
const wabt = @import("wabt");

/// Validate a WASM binary module.
/// Reads the binary, then runs the validator over the resulting module.
pub fn validateBytes(allocator: std.mem.Allocator, wasm_bytes: []const u8) !void {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});
}

const usage =
    \\wasm-validate — validate a WebAssembly binary
    \\
    \\Usage: wasm-validate [options] <file>
    \\
    \\  -h, --help            Show this help message
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    _ = args_it.next(); // skip program name

    var input_file: ?[:0]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
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

    validateBytes(gpa, wasm_bytes) catch |err|
        std.process.fatal("validation failed: {t}", .{err});

    try std.Io.File.stderr().writeStreamingAll(io, "valid\n");
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
