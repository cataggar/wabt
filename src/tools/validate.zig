const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt validate [options] <file.wasm>
    \\
    \\Validate a WebAssembly binary.  Both core modules
    \\(preamble \0asm 01 00 00 00) and components
    \\(preamble \0asm 0d 00 01 00) are accepted.
    \\
    \\Options:
    \\  -h, --help   Show this help
    \\
;

pub const ValidateError = error{ UnexpectedEof, InvalidMagic };

/// Validate a WebAssembly binary.  Detects the preamble (core vs.
/// component) and dispatches to the appropriate validator:
///
///   * core wasm (`\0asm 01 00 00 00`) → `binary.reader` + `Validator`
///   * component (`\0asm 0d 00 01 00`) → `component.loader.load`
///
/// For components, "loaded successfully" is the validation criterion
/// — the loader does structural parsing of every section and rejects
/// malformed binaries.  This matches the `wasm-tools validate`
/// behaviour exercised by `wamr/build.zig`'s `installAndValidate`.
pub fn validateBytes(allocator: std.mem.Allocator, wasm_bytes: []const u8) !void {
    if (wasm_bytes.len < 8) return error.UnexpectedEof;
    if (!std.mem.eql(u8, wasm_bytes[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6d })) {
        return error.InvalidMagic;
    }
    const layer_word = std.mem.readInt(u32, wasm_bytes[4..8], .little);
    if (layer_word == 0x0001_000d) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = try wabt.component.loader.load(wasm_bytes, arena.allocator());
        return;
    }

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

test "validate minimal component" {
    // Component preamble only: \0asm 0d 00 01 00 (component magic + version)
    const component = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    try validateBytes(std.testing.allocator, &component);
}

test "validate component built end-to-end" {
    // Encode a minimal but well-formed component (one custom section)
    // through wabt.component.writer, then round-trip via validateBytes.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const customs = try ar.alloc(wabt.component.types.CustomSection, 1);
    customs[0] = .{ .name = "producers", .payload = &.{} };
    const component: wabt.component.types.Component = .{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = &.{},
        .canons = &.{},
        .imports = &.{},
        .exports = &.{},
        .custom_sections = customs,
    };
    const bytes = try wabt.component.writer.encode(ar, &component);
    try validateBytes(std.testing.allocator, bytes);
}

test "validate rejects unknown layer/version" {
    // Magic OK but version is neither core (0x00000001) nor component
    // (0x000d0001) — should bubble up the loader's InvalidVersion.
    const bad = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x99, 0x00, 0x01, 0x00 };
    try std.testing.expectError(error.InvalidVersion, validateBytes(std.testing.allocator, &bad));
}
