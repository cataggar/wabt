//! `wabt module optimize` — run behavior-preserving optimizations on a core
//! WebAssembly module.
//!
//! Runs a fixed, deterministic sequence of IR passes via `wabt.Optimizer`:
//!   1. Constant folding (i32/i64 arithmetic, bitwise, shift/rotate, comparisons)
//!   2. Control-flow simplification (nop removal, constant-condition if/br_if, trivial blocks)
//!   3. Dead-code elimination (unreachable instructions after unconditional transfers)
//!   4. Dead-function removal (unreachable defined functions with index remapping)
//!
//! Both the input and output binaries are validated. Custom sections are
//! rejected by default (`--strip-custom` opts in to discarding them).

const builtin = @import("builtin");
const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt module optimize [options] <file.wasm> -o <output.wasm>
    \\
    \\Run behavior-preserving optimizations on a core WebAssembly module:
    \\  1. Constant folding (i32/i64 arithmetic, bitwise, shift/rotate, comparisons)
    \\  2. Control-flow simplification (nop removal, constant-condition if/br_if, trivial blocks)
    \\  3. Dead-code elimination (unreachable instructions after unconditional transfers)
    \\  4. Dead-function removal (unreachable defined functions with index remapping)
    \\
    \\Input and output modules are validated. Custom sections are rejected by
    \\default because transformations invalidate code offsets and function indices;
    \\pass --strip-custom to discard custom sections explicitly.
    \\
    \\Options:
    \\  -o, --output <file>   Output file (required; must not alias input file)
    \\  --strip-custom        Strip custom sections before optimizing
    \\
;

/// Optimize a core WebAssembly module binary using `wabt.Optimizer`.
pub fn optimizeBytes(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    options: wabt.Optimizer.Options,
) wabt.Optimizer.Error![]u8 {
    return wabt.Optimizer.optimize(allocator, wasm_bytes, options);
}

/// Returns true when `in_path` and `out_path` refer to the same path string
/// or the same existing filesystem object.
pub fn pathsAlias(io: std.Io, in_path: []const u8, out_path: []const u8) bool {
    if (std.mem.eql(u8, in_path, out_path)) return true;

    const cwd = std.Io.Dir.cwd();

    var path_buf: [2 * std.fs.max_path_bytes + 512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&path_buf);
    if (cwd.realPathFileAlloc(io, in_path, fba.allocator())) |in_real| {
        if (cwd.realPathFileAlloc(io, out_path, fba.allocator())) |out_real| {
            if (std.mem.eql(u8, in_real, out_real)) return true;
        } else |_| {}
    } else |_| {}

    const in_stat = cwd.statFile(io, in_path, .{}) catch return false;
    const out_stat = cwd.statFile(io, out_path, .{}) catch return false;
    if (in_stat.inode != 0 and
        in_stat.inode == out_stat.inode and
        in_stat.size == out_stat.size and
        std.meta.eql(in_stat.mtime, out_stat.mtime) and
        std.meta.eql(in_stat.ctime, out_stat.ctime))
    {
        return true;
    }

    return false;
}

pub const ParsedCommand = union(enum) {
    help,
    optimize: struct {
        input_file: []const u8,
        output_file: []const u8,
        options: wabt.Optimizer.Options,
    },
};

pub fn parseArgs(
    sub_args: []const []const u8,
    stderr: *std.Io.Writer,
) error{InvalidArgs}!ParsedCommand {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        return .help;
    }

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var options: wabt.Optimizer.Options = .{};

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                stderr.print("error: {s} requires an argument\n", .{arg}) catch {};
                return error.InvalidArgs;
            }
            output_file = sub_args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            const val = arg["--output=".len..];
            if (val.len == 0) {
                stderr.print("error: --output requires an argument\n", .{}) catch {};
                return error.InvalidArgs;
            }
            output_file = val;
        } else if (std.mem.eql(u8, arg, "--strip-custom")) {
            options.custom_sections = .strip;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            stderr.print(
                "error: unknown option '{s}'. Use 'wabt module optimize help' for usage.\n",
                .{arg},
            ) catch {};
            return error.InvalidArgs;
        } else {
            if (input_file != null) {
                stderr.print(
                    "error: unexpected positional argument '{s}'. Use 'wabt module optimize help' for usage.\n",
                    .{arg},
                ) catch {};
                return error.InvalidArgs;
            }
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        stderr.print("error: no input file. Use 'wabt module optimize help' for usage.\n", .{}) catch {};
        return error.InvalidArgs;
    };

    const out_path = output_file orelse {
        stderr.print("error: optimize requires -o <output.wasm>. Use 'wabt module optimize help' for usage.\n", .{}) catch {};
        return error.InvalidArgs;
    };

    return .{
        .optimize = .{
            .input_file = in_path,
            .output_file = out_path,
            .options = options,
        },
    };
}

/// Write `data` to a sibling temporary file in the same directory as `out_path`
/// and atomically rename it into place.
pub fn writeOutputAtomic(
    io: std.Io,
    allocator: std.mem.Allocator,
    out_path: []const u8,
    data: []const u8,
) !void {
    if (out_path.len == 0 or std.fs.path.isSep(out_path[out_path.len - 1])) {
        return error.InvalidOutputPath;
    }
    const out_name = std.fs.path.basename(out_path);
    if (out_name.len == 0 or std.mem.eql(u8, out_name, ".") or std.mem.eql(u8, out_name, "..")) {
        return error.InvalidOutputPath;
    }
    const parent_path = std.fs.path.dirname(out_path) orelse ".";
    var parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{});
    defer parent.close(io);

    var random: [16]u8 = undefined;
    var tmp_name: ?[]u8 = null;
    var tmp_file: ?std.Io.File = null;
    for (0..64) |_| {
        try io.randomSecure(&random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const candidate = try std.fmt.allocPrint(
            allocator,
            ".wabt-optimize-{s}.tmp",
            .{suffix},
        );
        const file = parent.createFile(io, candidate, .{
            .exclusive = true,
            .permissions = if (builtin.os.tag == .windows)
                .default_file
            else
                @fromBackingInt(@intCast(0o600)),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        tmp_name = candidate;
        tmp_file = file;
        break;
    }

    const staged_name = tmp_name orelse return error.PathAlreadyExists;
    defer allocator.free(staged_name);
    var file = tmp_file.?;
    var file_closed = false;
    var published = false;
    defer {
        if (!file_closed) file.close(io);
        if (!published) parent.deleteFile(io, staged_name) catch {};
    }

    try file.writeStreamingAll(io, data);
    file.close(io);
    file_closed = true;

    try std.Io.Dir.rename(parent, staged_name, parent, out_name, io);
    published = true;
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.Writer.fixed(&err_buf);
    const parsed = parseArgs(sub_args, &err_writer) catch {
        std.debug.print("{s}", .{err_buf[0..err_writer.end]});
        std.process.exit(1);
    };

    const cmd = switch (parsed) {
        .help => {
            writeStdout(init.io, usage);
            return;
        },
        .optimize => |opt| opt,
    };

    const in_path = cmd.input_file;
    const out_path = cmd.output_file;

    if (pathsAlias(init.io, in_path, out_path)) {
        std.debug.print(
            "error: output file '{s}' must not alias input file '{s}'\n",
            .{ out_path, in_path },
        );
        std.process.exit(1);
    }

    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        in_path,
        alloc,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    const optimized = optimizeBytes(alloc, source, cmd.options) catch |err| {
        switch (err) {
            error.CustomSectionsPresent => std.debug.print(
                "error: '{s}' contains custom sections; pass --strip-custom to discard custom sections before optimizing ({any})\n",
                .{ in_path, err },
            ),
            error.ComponentNotSupported => std.debug.print(
                "error: '{s}' is a WebAssembly component; 'wabt module optimize' only supports core modules (see 'wabt component' for component commands) ({any})\n",
                .{ in_path, err },
            ),
            error.UnsupportedFeature => std.debug.print(
                "error: '{s}' uses an unsupported WebAssembly feature ({any})\n",
                .{ in_path, err },
            ),
            error.UnsupportedOpcode => std.debug.print(
                "error: '{s}' uses an unsupported WebAssembly opcode ({any})\n",
                .{ in_path, err },
            ),
            error.InvalidInput => std.debug.print(
                "error: '{s}' is not a valid core WebAssembly module ({any})\n",
                .{ in_path, err },
            ),
            error.InvalidOutput => std.debug.print(
                "error: internal optimizer error: optimized module failed validation ({any})\n",
                .{err},
            ),
            error.OutOfMemory => std.debug.print(
                "error: out of memory ({any})\n",
                .{err},
            ),
        }
        std.process.exit(1);
    };
    defer alloc.free(optimized);

    writeOutputAtomic(init.io, alloc, out_path, optimized) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "parseArgs handles help subword and valid options" {
    var err_buf: [512]u8 = undefined;
    var err_writer = std.Io.Writer.fixed(&err_buf);

    const help_res = try parseArgs(&.{"help"}, &err_writer);
    try std.testing.expect(help_res == .help);

    err_writer = std.Io.Writer.fixed(&err_buf);
    const basic = try parseArgs(&.{ "in.wasm", "-o", "out.wasm" }, &err_writer);
    try std.testing.expectEqualStrings("in.wasm", basic.optimize.input_file);
    try std.testing.expectEqualStrings("out.wasm", basic.optimize.output_file);
    try std.testing.expectEqual(wabt.Optimizer.CustomSectionPolicy.reject, basic.optimize.options.custom_sections);

    err_writer = std.Io.Writer.fixed(&err_buf);
    const strip_eq = try parseArgs(&.{ "--strip-custom", "--output=out2.wasm", "in2.wasm" }, &err_writer);
    try std.testing.expectEqualStrings("in2.wasm", strip_eq.optimize.input_file);
    try std.testing.expectEqualStrings("out2.wasm", strip_eq.optimize.output_file);
    try std.testing.expectEqual(wabt.Optimizer.CustomSectionPolicy.strip, strip_eq.optimize.options.custom_sections);
}

test "parseArgs rejects missing input, missing output, unknown flags, and extra positionals" {
    var err_buf: [512]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&err_buf);
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "-o", "out.wasm" }, &w));
        try std.testing.expect(std.mem.indexOf(u8, err_buf[0..w.end], "error: no input file.") != null);
    }
    {
        var w = std.Io.Writer.fixed(&err_buf);
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{"in.wasm"}, &w));
        try std.testing.expect(std.mem.indexOf(u8, err_buf[0..w.end], "error: optimize requires -o <output.wasm>.") != null);
    }
    {
        var w = std.Io.Writer.fixed(&err_buf);
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "in.wasm", "-o" }, &w));
        try std.testing.expect(std.mem.indexOf(u8, err_buf[0..w.end], "error: -o requires an argument") != null);
    }
    {
        var w = std.Io.Writer.fixed(&err_buf);
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "-O2", "in.wasm", "-o", "out.wasm" }, &w));
        try std.testing.expect(std.mem.indexOf(u8, err_buf[0..w.end], "error: unknown option '-O2'.") != null);
    }
    {
        var w = std.Io.Writer.fixed(&err_buf);
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "--help", "in.wasm", "-o", "out.wasm" }, &w));
        try std.testing.expect(std.mem.indexOf(u8, err_buf[0..w.end], "error: unknown option '--help'.") != null);
    }
    {
        var w = std.Io.Writer.fixed(&err_buf);
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "a.wasm", "b.wasm", "-o", "out.wasm" }, &w));
        try std.testing.expect(std.mem.indexOf(u8, err_buf[0..w.end], "error: unexpected positional argument 'b.wasm'.") != null);
    }
}

test "pathsAlias detects identical strings and canonical filesystem aliases" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    try std.testing.expect(pathsAlias(io, "same.wasm", "same.wasm"));
    try std.testing.expect(!pathsAlias(io, "nonexistent-a.wasm", "nonexistent-b.wasm"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "mod.wasm", .data = "\x00asm\x01\x00\x00\x00" });

    const dir_real = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_real);
    const file_rel = try std.fmt.allocPrint(alloc, "{s}/mod.wasm", .{dir_real});
    defer alloc.free(file_rel);
    const dot_rel = try std.fmt.allocPrint(alloc, "{s}/./mod.wasm", .{dir_real});
    defer alloc.free(dot_rel);
    const other_rel = try std.fmt.allocPrint(alloc, "{s}/other.wasm", .{dir_real});
    defer alloc.free(other_rel);

    try std.testing.expect(pathsAlias(io, file_rel, dot_rel));
    try std.testing.expect(!pathsAlias(io, file_rel, other_rel));
}

test "optimizeBytes delegates to wabt.Optimizer.optimize" {
    const alloc = std.testing.allocator;
    const empty_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    const out = try optimizeBytes(alloc, &empty_wasm, .{});
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u8, &empty_wasm, out);

    const component_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    try std.testing.expectError(
        error.ComponentNotSupported,
        optimizeBytes(alloc, &component_wasm, .{}),
    );
}

test "writeOutputAtomic writes file and leaves no temporary files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const dir_real = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_real);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out.wasm", .{dir_real});
    defer alloc.free(out_path);

    const empty_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try writeOutputAtomic(io, alloc, out_path, &empty_wasm);

    const read_back = try std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .limited(64));
    defer alloc.free(read_back);
    try std.testing.expectEqualSlices(u8, &empty_wasm, read_back);

    var iter = tmp.dir.iterate();
    while (try iter.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".wabt-optimize-"));
    }
}
