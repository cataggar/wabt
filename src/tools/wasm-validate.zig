const std = @import("std");
const wabt = @import("wabt");

/// Validate a WASM binary module.
/// Reads the binary, then runs the validator over the resulting module.
pub fn validateBytes(allocator: std.mem.Allocator, wasm_bytes: []const u8) !void {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();

    try wabt.Validator.validate(&module, .{});
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
                \\wasm-validate {s} validate a WebAssembly binary
                \\
                \\Usage: wasm-validate [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\
            , .{wabt.version});
            return;
        } else {
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

    validateBytes(alloc, source) catch |err| {
        std.debug.print("{s}: validation error: {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
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
