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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    _ = args_it.next(); // skip program name

    var input_file: ?[:0]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io,
                \\spectest-interp — run WebAssembly spec tests (.wast)
                \\
                \\Usage: spectest-interp [options] <file.wast>
                \\
                \\  -h, --help   Show this help message
                \\
            );
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
        .limited(64 * 1024 * 1024),
    ) catch |err|
        std.process.fatal("cannot read '{s}': {t}", .{ in_path, err });
    defer gpa.free(source);

    const result = wabt.wast_runner.run(gpa, source);

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: {d} passed, {d} failed, {d} skipped ({d} total)\n", .{
        in_path,
        result.passed,
        result.failed,
        result.skipped,
        result.total(),
    }) catch "result overflow\n";
    try std.Io.File.stderr().writeStreamingAll(io, msg);
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
