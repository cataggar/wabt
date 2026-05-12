const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt spec run [options] <file.wast>
    \\
    \\Run a WebAssembly spec test (.wast file).
    \\
    \\Options:
    \\
;

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

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var input_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("no input file specified. Use `wabt spec run help` for usage.\n", .{});
        return;
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
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

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
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
