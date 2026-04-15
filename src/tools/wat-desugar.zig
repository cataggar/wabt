const std = @import("std");
const wabt = @import("wabt");

/// Parse WAT source and write it back (identity transform / desugaring).
pub fn desugar(allocator: std.mem.Allocator, wat_source: []const u8) ![]u8 {
    var module = try wabt.text.Parser.parseModule(allocator, wat_source);
    defer module.deinit();
    return wabt.text.Writer.writeModule(allocator, &module);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    var args_it = try init.minimal.args.iterateAllocator(alloc);
    defer args_it.deinit();
    _ = args_it.next();

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\wat-desugar {s} remove syntactic sugar from WebAssembly text
                \\
                \\Usage: wat-desugar [options] <file>
                \\
                \\  -h, --help            Show this help message
                \\  -o, --output <file>   Output file (default: stdout)
                \\
            , .{wabt.version});
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_file = args_it.next();
        } else {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use --help for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    const output = desugar(alloc, source) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        std.process.exit(1);
    };
    defer alloc.free(output);

    if (output_file) |out_path| {
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = output }) catch |err| {
            std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
            std.process.exit(1);
        };
    } else {
        std.Io.File.stdout().writeStreamingAll(init.io, output) catch {};
    }
}

test "empty module round-trips" {
    const wat = try desugar(std.testing.allocator, "(module)");
    defer std.testing.allocator.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "module") != null);
}
