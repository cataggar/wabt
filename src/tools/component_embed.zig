//! `wabt component embed` — embed a `component-type` custom section
//! into a core wasm so it can be wrapped into a component.
//!
//! Drop-in replacement for the subset of `wasm-tools component embed`
//! exercised by `cataggar/wamr/build.zig`:
//!
//!   wabt component embed [-w <world>] [-o <out>] <wit-path> <core.wasm>
//!
//! `<wit-path>` is a `.wit` file or a directory containing `.wit`
//! files. When a directory is given, all top-level `.wit` files are
//! concatenated into a single source for parsing. (Subdirectories
//! such as `deps/` — used by `wasm-tools` for multi-package
//! resolution — are deferred to the `wit-resolve` todo.)
//!
//! The output is the original core wasm with a `component-type:<world>`
//! custom section appended. Existing custom sections with the same
//! name are dropped first to avoid duplicates.

const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt component embed [options] <wit-path> <core.wasm>
    \\
    \\Embed a `component-type` custom section into a core wasm so that
    \\`wabt component new` (or `wasm-tools component new`) can wrap it
    \\into a component.
    \\
    \\<wit-path> is a `.wit` file or a directory of `.wit` files.
    \\
    \\Options:
    \\  -w, --world <name>      World to embed (required if the WIT defines
    \\                          more than one world)
    \\  -o, --output <file>     Output file (default: <input>.embed.wasm)
    \\  -h, --help              Show this help
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var world_arg: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--world")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            world_arg = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'. Use `wabt help component`.\n", .{arg});
            std.process.exit(1);
        } else {
            if (pos_count >= positionals.len) {
                std.debug.print("error: unexpected positional argument '{s}'. Use `wabt help component`.\n", .{arg});
                std.process.exit(1);
            }
            positionals[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        std.debug.print("error: component embed requires <wit-path> and <core.wasm>. Use `wabt help component`.\n", .{});
        std.process.exit(1);
    }

    const wit_path = positionals[0].?;
    const core_path = positionals[1].?;

    const source = readWitSource(alloc, init.io, wit_path) catch |err| {
        std.debug.print("error: reading WIT '{s}': {any}\n", .{ wit_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var diag: wabt.component.wit.parser.ParseDiagnostic = .{};
    const doc = wabt.component.wit.parser.parse(arena.allocator(), source, &diag) catch |err| {
        std.debug.print("error: parsing WIT: {s} at offset {d}: {s}\n", .{ @errorName(err), diag.span.start, diag.msg });
        std.process.exit(1);
    };

    const world_name = world_arg orelse autoselectWorld(doc) orelse {
        std.debug.print("error: --world is required (no unique world found in WIT)\n", .{});
        std.process.exit(1);
    };

    const ct_payload = wabt.component.wit.metadata_encode.encodeWorld(alloc, doc, world_name) catch |err| {
        std.debug.print("error: encoding world '{s}': {s}\n", .{ world_name, @errorName(err) });
        std.process.exit(1);
    };
    defer alloc.free(ct_payload);

    const core_bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        core_path,
        alloc,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ core_path, err });
        std.process.exit(1);
    };
    defer alloc.free(core_bytes);

    const section_name = std.fmt.allocPrint(alloc, "component-type:{s}", .{world_name}) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(section_name);

    const embedded = embedCustomSection(alloc, core_bytes, section_name, ct_payload) catch |err| {
        std.debug.print("error: embedding custom section: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(embedded);

    const out_path = output_file orelse blk: {
        if (std.mem.endsWith(u8, core_path, ".wasm")) {
            const stem = core_path[0 .. core_path.len - 5];
            break :blk std.fmt.allocPrint(alloc, "{s}.embed.wasm", .{stem}) catch core_path;
        }
        break :blk std.fmt.allocPrint(alloc, "{s}.embed.wasm", .{core_path}) catch core_path;
    };

    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = embedded,
    }) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

/// Read a `.wit` path. If `path` is a directory, concatenate all
/// top-level `.wit` files (sorted by name for determinism).
fn readWitSource(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return err;
    if (stat.kind == .directory) {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var entries = std.ArrayListUnmanaged([]const u8).empty;
        defer {
            for (entries.items) |e| alloc.free(e);
            entries.deinit(alloc);
        }
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wit")) continue;
            try entries.append(alloc, try alloc.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, entries.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        var combined = std.ArrayListUnmanaged(u8).empty;
        defer combined.deinit(alloc);
        for (entries.items) |name| {
            const full = try std.fs.path.join(alloc, &.{ path, name });
            defer alloc.free(full);
            const buf = try std.Io.Dir.cwd().readFileAlloc(io, full, alloc, std.Io.Limit.limited(wabt.max_input_file_size));
            defer alloc.free(buf);
            try combined.appendSlice(alloc, buf);
            try combined.append(alloc, '\n');
        }
        return try combined.toOwnedSlice(alloc);
    }
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(wabt.max_input_file_size));
}

/// If exactly one world is defined in the document, return its name.
fn autoselectWorld(doc: wabt.component.wit.ast.Document) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (doc.items) |it| {
        if (it == .world) {
            if (found != null) return null;
            found = it.world.name;
        }
    }
    return found;
}

/// Append a custom section with `name` and `payload` to a core wasm
/// binary. Existing custom sections with the same name are dropped.
fn embedCustomSection(
    alloc: std.mem.Allocator,
    core_bytes: []const u8,
    name: []const u8,
    payload: []const u8,
) ![]u8 {
    if (core_bytes.len < 8) return error.InvalidCoreModule;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidCoreModule;

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);

    // Copy preamble.
    try out.appendSlice(alloc, core_bytes[0..8]);

    var i: usize = 8;
    while (i < core_bytes.len) {
        if (i >= core_bytes.len) break;
        const id = core_bytes[i];
        i += 1;
        const size_res = readU32Leb(core_bytes, i) catch return error.InvalidCoreModule;
        const sec_size = size_res.value;
        i += size_res.bytes_read;
        if (i + sec_size > core_bytes.len) return error.InvalidCoreModule;
        const body = core_bytes[i .. i + sec_size];
        i += sec_size;

        if (id == 0) {
            // Custom section: read its name and skip if it matches.
            const n_res = readU32Leb(body, 0) catch return error.InvalidCoreModule;
            const name_len = n_res.value;
            if (n_res.bytes_read + name_len > body.len) return error.InvalidCoreModule;
            const sec_name = body[n_res.bytes_read .. n_res.bytes_read + name_len];
            if (std.mem.eql(u8, sec_name, name)) continue;
        }
        // Re-emit unchanged.
        try out.append(alloc, id);
        try writeU32Leb(alloc, &out, sec_size);
        try out.appendSlice(alloc, body);
    }

    // Append the new custom section.
    var body = std.ArrayListUnmanaged(u8).empty;
    defer body.deinit(alloc);
    try writeU32Leb(alloc, &body, @intCast(name.len));
    try body.appendSlice(alloc, name);
    try body.appendSlice(alloc, payload);

    try out.append(alloc, 0);
    try writeU32Leb(alloc, &out, @intCast(body.items.len));
    try out.appendSlice(alloc, body.items);

    return try out.toOwnedSlice(alloc);
}

const LebRead = struct { value: u32, bytes_read: usize };

fn readU32Leb(buf: []const u8, start: usize) !LebRead {
    var result: u32 = 0;
    var shift: u5 = 0;
    var i: usize = start;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        result |= @as(u32, b & 0x7f) << shift;
        if ((b & 0x80) == 0) {
            return .{ .value = result, .bytes_read = i + 1 - start };
        }
        if (shift >= 25) return error.LebOverflow;
        shift += 7;
    }
    return error.LebTruncated;
}

fn writeU32Leb(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) !void {
    var x = v;
    while (true) {
        var b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) b |= 0x80;
        try out.append(alloc, b);
        if (x == 0) break;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "embedCustomSection: appends section to a minimal core module" {
    const core = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    const payload = [_]u8{ 0x42, 0x00 };
    const out = try embedCustomSection(testing.allocator, &core, "component-type:t", &payload);
    defer testing.allocator.free(out);
    try testing.expect(out.len > core.len);
    // Custom section starts after the preamble; first byte of section is id=0.
    try testing.expectEqual(@as(u8, 0), out[8]);
}

test "embedCustomSection: replaces existing same-name custom section" {
    // preamble + custom section "x" with payload "old"
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x05, // section id=0, size=5
        0x01, 'x', // name length=1, name="x"
        'o', 'l', 'd', // payload "old"
    };
    const new_payload = "new!";
    const out = try embedCustomSection(testing.allocator, &core, "x", new_payload);
    defer testing.allocator.free(out);
    // The original custom should be gone; only one section should
    // remain, and it should hold "new!" as its payload.
    try testing.expect(out.len > 8);
    // Section starts at out[8], id=0, size LEB, name LEB, name, payload
    try testing.expectEqual(@as(u8, 0), out[8]);
    // size LEB single byte: 1 (name len) + 1 (name) + 4 (payload) = 6
    try testing.expectEqual(@as(u8, 6), out[9]);
    try testing.expectEqual(@as(u8, 1), out[10]);
    try testing.expectEqual(@as(u8, 'x'), out[11]);
    try testing.expectEqualStrings("new!", out[12..16]);
}

test "embedCustomSection: end-to-end with adder world" {
    const wit_source =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\    add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\    export add;
        \\}
    ;
    const ct = try wabt.component.wit.metadata_encode.encodeWorldFromSource(
        testing.allocator,
        wit_source,
        "adder",
    );
    defer testing.allocator.free(ct);

    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    const out = try embedCustomSection(testing.allocator, &core, "component-type:adder", ct);
    defer testing.allocator.free(out);

    // Should be: preamble (8) + custom section (1 id + LEB size + name LEB + name (20) + ct).
    try testing.expect(out.len > core.len + ct.len);
    try testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", out[0..8]);
    try testing.expectEqual(@as(u8, 0), out[8]); // custom section id
}
