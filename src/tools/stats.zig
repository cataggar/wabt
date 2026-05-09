const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt module stats [options] <file.wasm>
    \\
    \\Print module statistics for a WebAssembly binary.
    \\
    \\Options:
    \\  -h, --help   Show this help
    \\
;

/// Statistics about a WebAssembly module.
pub const Stats = struct {
    types: usize,
    funcs: usize,
    tables: usize,
    memories: usize,
    globals: usize,
    exports: usize,
    imports: usize,
    customs: usize,
    data_segments: usize,
    elem_segments: usize,
};

/// Read a WebAssembly binary and compute statistics.
pub fn stats(allocator: std.mem.Allocator, wasm_bytes: []const u8) !Stats {
    var module = try wabt.binary.reader.readModule(allocator, wasm_bytes);
    defer module.deinit();
    return .{
        .types = module.module_types.items.len,
        .funcs = module.funcs.items.len,
        .tables = module.tables.items.len,
        .memories = module.memories.items.len,
        .globals = module.globals.items.len,
        .exports = module.exports.items.len,
        .imports = module.imports.items.len,
        .customs = module.customs.items.len,
        .data_segments = module.data_segments.items.len,
        .elem_segments = module.elem_segments.items.len,
    };
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
        std.debug.print("error: no input file. Use `wabt help stats` for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    const s = stats(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };

    const output = std.fmt.allocPrint(alloc,
        \\Section Details:
        \\  Types:           {d}
        \\  Functions:       {d}
        \\  Tables:          {d}
        \\  Memories:        {d}
        \\  Globals:         {d}
        \\  Exports:         {d}
        \\  Imports:         {d}
        \\  Custom sections: {d}
        \\  Data segments:   {d}
        \\  Elem segments:   {d}
        \\
    , .{ s.types, s.funcs, s.tables, s.memories, s.globals, s.exports, s.imports, s.customs, s.data_segments, s.elem_segments }) catch {
        std.debug.print("error: out of memory\n", .{});
        std.process.exit(1);
    };
    defer alloc.free(output);

    std.Io.File.stdout().writeStreamingAll(init.io, output) catch {};
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "empty module returns zero stats" {
    const empty_wasm = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const s = try stats(std.testing.allocator, empty_wasm);
    try std.testing.expectEqual(@as(usize, 0), s.funcs);
    try std.testing.expectEqual(@as(usize, 0), s.types);
    try std.testing.expectEqual(@as(usize, 0), s.exports);
}
