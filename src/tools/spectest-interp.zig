const std = @import("std");
const wabt = @import("wabt");

/// Run a WebAssembly spec test (.wast): parse commands and return results.
pub fn runSpecTest(allocator: std.mem.Allocator, wast_source: []const u8) wabt.wast_runner.Result {
    return wabt.wast_runner.run(allocator, wast_source);
}

/// Run a single binary module through validation (legacy entry point).
pub fn runBinaryValidation(allocator: std.mem.Allocator, wasm_bytes: []const u8) !bool {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    wabt.Validator.validate(&module, .{}) catch return false;
    return true;
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var args_it = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.next(); // skip program name

    var input_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\spectest-interp {s} - run WebAssembly spec tests (.wast)
                \\
                \\Usage: spectest-interp [options] <file.wast>
                \\
                \\  -h, --help   Show this help message
                \\
            , .{wabt.version});
            return;
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("no input file specified. Use --help for usage.\n", .{});
        return;
    };

    const source = std.fs.cwd().readFileAlloc(alloc, in_path, wabt.max_input_file_size) catch |err| {
        std.debug.print("cannot read '{s}': {any}\n", .{ in_path, err });
        return err;
    };
    defer alloc.free(source);

    const result = wabt.wast_runner.run(alloc, source);

    std.debug.print("{s}: {d} passed, {d} failed, {d} skipped ({d} total)\n", .{
        in_path,
        result.passed,
        result.failed,
        result.skipped,
        result.total(),
    });
}

test "basic binary validation stub" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const passed = try runBinaryValidation(std.testing.allocator, empty_wasm);
    try std.testing.expect(passed);
}

test "runSpecTest with assert_invalid" {
    const wast =
        \\(assert_invalid
        \\  (module (func) (export "a" (func 0)) (export "a" (func 0)))
        \\  "duplicate export name"
        \\)
    ;
    const result = runSpecTest(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}
