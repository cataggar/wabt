//! `wabt component objdump` — print a structural summary of a
//! WebAssembly Component Model binary.
//!
//! Mirrors `wabt module objdump` (src/tools/objdump.zig) but drives off
//! `wabt.component.loader.load(...)`. Because the loader drops custom
//! sections (src/component/loader.zig:171-174), we do a separate
//! lightweight section walk to also surface section-order and
//! custom-section names.

const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt component objdump [options] <file.wasm>
    \\
    \\Dump a structural summary of a WebAssembly Component Model binary.
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: stdout)
    \\
;

const wasm_magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
// Component preamble's layer byte (offset 6) is 0x01; core wasm uses 0x00.
const component_layer_byte: u8 = 0x01;

/// Returns true when `bytes` look like a Component Model binary
/// (`\x00asm` + layer byte 0x01).
pub fn looksLikeComponent(bytes: []const u8) bool {
    return bytes.len >= 8 and std.mem.eql(u8, bytes[0..4], &wasm_magic) and bytes[6] == component_layer_byte;
}

/// Section IDs per the Component Model binary spec — mirror of
/// `src/component/loader.zig`'s private `SectionId`. We keep a local
/// copy so this file can render labels without exposing the loader's
/// internal enum.
const SectionId = enum(u8) {
    custom = 0,
    core_module = 1,
    core_instance = 2,
    core_type = 3,
    component = 4,
    instance = 5,
    alias = 6,
    type = 7,
    canon = 8,
    start = 9,
    @"import" = 10,
    @"export" = 11,
    value = 12,

    fn label(self: SectionId) []const u8 {
        return switch (self) {
            .custom => "custom",
            .core_module => "core-module",
            .core_instance => "core-instance",
            .core_type => "core-type",
            .component => "component",
            .instance => "instance",
            .alias => "alias",
            .type => "type",
            .canon => "canon",
            .start => "start",
            .@"import" => "import",
            .@"export" => "export",
            .value => "value",
        };
    }
};

const WalkError = error{
    UnexpectedEnd,
    InvalidSectionId,
    InvalidSectionSize,
    Overflow,
    OutOfMemory,
};

/// Result of the lightweight section walk: ordered list of distinct
/// section IDs encountered (for the "Section order:" line) and the
/// names of every custom section (for the "Custom sections:" line).
const Walk = struct {
    section_order: []SectionId,
    custom_names: []const []const u8,
    custom_count: usize,
};

fn walkSections(allocator: std.mem.Allocator, bytes: []const u8) WalkError!Walk {
    if (bytes.len < 8) return error.UnexpectedEnd;

    var section_order: std.ArrayListUnmanaged(SectionId) = .empty;
    var seen = [_]bool{false} ** 13;
    var custom_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var custom_count: usize = 0;

    var pos: usize = 8;
    while (pos < bytes.len) {
        if (pos >= bytes.len) return error.UnexpectedEnd;
        const id_byte = bytes[pos];
        pos += 1;

        const leb = wabt.leb128.readU32Leb128(bytes[pos..]) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.UnexpectedEnd => return error.UnexpectedEnd,
        };
        pos += leb.bytes_read;
        const section_size: usize = leb.value;

        const section_start = pos;
        if (section_start + section_size > bytes.len) return error.InvalidSectionSize;
        const section_end = section_start + section_size;

        const id = std.enums.fromInt(SectionId, id_byte) orelse return error.InvalidSectionId;
        if (!seen[@intFromEnum(id)]) {
            seen[@intFromEnum(id)] = true;
            try section_order.append(allocator, id);
        }

        if (id == .custom) {
            custom_count += 1;
            // Custom section payload starts with a LEB-prefixed name.
            const name_leb = wabt.leb128.readU32Leb128(bytes[section_start..]) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.UnexpectedEnd => return error.UnexpectedEnd,
            };
            const name_len: usize = name_leb.value;
            const name_start = section_start + name_leb.bytes_read;
            if (name_start + name_len > section_end) return error.InvalidSectionSize;
            const name = bytes[name_start .. name_start + name_len];
            try custom_names.append(allocator, name);
        }

        pos = section_end;
    }

    return .{
        .section_order = try section_order.toOwnedSlice(allocator),
        .custom_names = try custom_names.toOwnedSlice(allocator),
        .custom_count = custom_count,
    };
}

pub const DumpError = error{
    InvalidMagic,
    InvalidVersion,
    UnexpectedEnd,
    InvalidSectionId,
    InvalidSectionSize,
    InvalidEncoding,
    UnsupportedFeature,
    OutOfMemory,
    Overflow,
    InvalidUtf8,
};

/// Render the objdump summary block for `bytes`. The returned slice is
/// owned by `allocator`.
pub fn dump(allocator: std.mem.Allocator, bytes: []const u8) DumpError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const comp = try wabt.component.loader.load(bytes, arena_alloc);
    const walk = walkSections(arena_alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.Overflow,
        error.UnexpectedEnd => return error.UnexpectedEnd,
        error.InvalidSectionId => return error.InvalidSectionId,
        error.InvalidSectionSize => return error.InvalidSectionSize,
    };

    var order_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (walk.section_order, 0..) |id, i| {
        if (i > 0) try order_buf.appendSlice(arena_alloc, ", ");
        try order_buf.appendSlice(arena_alloc, id.label());
    }

    var custom_buf: std.ArrayListUnmanaged(u8) = .empty;
    if (walk.custom_count > 0) {
        try custom_buf.appendSlice(arena_alloc, " (");
        for (walk.custom_names, 0..) |name, i| {
            if (i > 0) try custom_buf.appendSlice(arena_alloc, ", ");
            try custom_buf.appendSlice(arena_alloc, name);
        }
        try custom_buf.appendSlice(arena_alloc, ")");
    }

    return std.fmt.allocPrint(allocator,
        \\wabt component objdump:
        \\
        \\Section order:        {s}
        \\Core modules:         {d}
        \\Core instances:       {d}
        \\Core types:           {d}
        \\Nested components:    {d}
        \\Component instances:  {d}
        \\Component types:      {d}
        \\Aliases:              {d}
        \\Canonicals:           {d}
        \\Component imports:    {d}
        \\Component exports:    {d}
        \\Custom sections:      {d}{s}
        \\
    , .{
        order_buf.items,
        comp.core_modules.len,
        comp.core_instances.len,
        comp.core_types.len,
        comp.components.len,
        comp.instances.len,
        comp.types.len,
        comp.aliases.len,
        comp.canons.len,
        comp.imports.len,
        comp.exports.len,
        walk.custom_count,
        custom_buf.items,
    });
}

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else if (arg.len > 0 and arg[0] != '-') {
            input_file = arg;
        }
    }

    const in_path = input_file orelse {
        std.debug.print("error: no input file. Use `wabt component objdump help` for usage.\n", .{});
        std.process.exit(1);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, in_path, alloc, std.Io.Limit.limited(wabt.max_input_file_size)) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    const output = dump(alloc, source) catch |err| {
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

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

test "looksLikeComponent distinguishes core vs component preamble" {
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const comp = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    try std.testing.expect(!looksLikeComponent(&core));
    try std.testing.expect(looksLikeComponent(&comp));
    try std.testing.expect(!looksLikeComponent(&[_]u8{ 0x00, 0x61, 0x73, 0x6d }));
}

test "dump renders summary block for minimal component with one custom section" {
    // Hand-built minimal component: preamble + one custom section
    // whose name is "wit-component". Exercises the section walk and
    // the rendered block format end-to-end without depending on a
    // fixture file (which `@embedFile` cannot reach from this module's
    // package path).
    const bytes = [_]u8{
        // preamble — magic + (version=0x000d, layer=0x01)
        0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00,
        // custom section: id=0, size=14
        0x00, 0x0e,
        // name length=13 + "wit-component"
        0x0d, 'w', 'i', 't', '-', 'c', 'o', 'm', 'p', 'o', 'n', 'e', 'n', 't',
    };
    const out = try dump(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "wabt component objdump:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Section order:        custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Core modules:         0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Custom sections:      1 (wit-component)") != null);
}

test "dump rejects core wasm preamble" {
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidVersion, dump(std.testing.allocator, &core));
}
