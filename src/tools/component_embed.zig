//! `wabt component embed` — embed a `component-type` custom section
//! into a core wasm so it can be wrapped into a component.
//!
//! Drop-in replacement for the subset of `wasm-tools component embed`
//! exercised by `cataggar/wamr/build.zig`:
//!
//!   wabt component embed [-w <world>] [-o <out>] <wit-path> <core.wasm>
//!
//! `<wit-path>` is one of:
//!
//!   * A single `.wit` file.
//!   * A directory of `.wit` files. Top-level `.wit` files are
//!     concatenated into a single "main" package; entries under
//!     `<dir>/deps/<pkg>/` (or `<dir>/deps/<pkg>.wit`) are parsed
//!     as sibling packages and made available for cross-package
//!     interface lookup. This matches the layout convention
//!     `wasm-tools` / `wit-bindgen` use, and lets a world `import
//!     docs:adder/add@0.1.0;` resolve against
//!     `<dir>/deps/adder/world.wit`.
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
    \\When a directory is given, sibling packages under <wit-path>/deps/
    \\are also parsed so qualified interface refs like
    \\`docs:adder/add@0.1.0` resolve correctly.
    \\
    \\Options:
    \\  -w, --world <name>      World to embed (required if the WIT defines
    \\                          more than one world)
    \\  -o, --output <file>     Output file (default: <input>.embed.wasm)
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var world_arg: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--world")) {
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
            std.debug.print("error: unknown option '{s}'. Use `wabt component embed help`.\n", .{arg});
            std.process.exit(1);
        } else {
            if (pos_count >= positionals.len) {
                std.debug.print("error: unexpected positional argument '{s}'. Use `wabt component embed help`.\n", .{arg});
                std.process.exit(1);
            }
            positionals[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        std.debug.print("error: component embed requires <wit-path> and <core.wasm>. Use `wabt component embed help`.\n", .{});
        std.process.exit(1);
    }

    const wit_path = positionals[0].?;
    const core_path = positionals[1].?;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const resolver = wabt.component.wit.resolver.parseLayout(ar, init.io, wit_path) catch |err| {
        std.debug.print("error: parsing WIT layout '{s}': {s}\n", .{ wit_path, @errorName(err) });
        std.process.exit(1);
    };

    const world_name = world_arg orelse resolveSoleWorld(ar, resolver.main, wit_path);

    var ediag: wabt.component.wit.metadata_encode.EncodeDiagnostic = .{};
    const ct_payload = wabt.component.wit.metadata_encode.encodeWorldFromResolverWithDiag(alloc, resolver, world_name, &ediag) catch |err| {
        if (err == error.UnknownInterface) {
            std.debug.print("error: encoding world '{s}': unknown interface '{s}'\n", .{ world_name, ediag.interface orelse "?" });
            if (ediag.referenced_by) |r| std.debug.print("        referenced by {s}\n", .{r});
            if (ediag.searched) |s| std.debug.print("        not found in {s}\n", .{s});
        } else {
            std.debug.print("error: encoding world '{s}': {s}\n", .{ world_name, @errorName(err) });
        }
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

    const embedded = wabt.component.wit.embed.embedCustomSection(alloc, core_bytes, section_name, ct_payload) catch |err| {
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

/// Resolve the sole world in `doc` (used when `--world` is omitted).
/// Exits with an informative error if zero or multiple worlds exist.
fn resolveSoleWorld(
    ar: std.mem.Allocator,
    doc: wabt.component.wit.ast.Document,
    wit_path: []const u8,
) []const u8 {
    if (wabt.component.wit.embed.autoselectWorld(doc)) |name| return name;

    const names = wabt.component.wit.embed.worldNames(ar, doc) catch &.{};
    if (names.len == 0) {
        std.debug.print(
            "error: no world found in WIT '{s}'. Define a `world` or pass --world <name>.\n",
            .{wit_path},
        );
    } else {
        std.debug.print(
            "error: WIT '{s}' defines {d} worlds; pass --world <name> to pick one.\n  available worlds: ",
            .{ wit_path, names.len },
        );
        for (names, 0..) |n, i| {
            if (i != 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{n});
        }
        std.debug.print("\n", .{});
    }
    std.process.exit(1);
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "embed end-to-end with adder world" {
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
    const out = try wabt.component.wit.embed.embedCustomSection(testing.allocator, &core, "component-type:adder", ct);
    defer testing.allocator.free(out);

    // Should be: preamble (8) + custom section (1 id + LEB size + name LEB + name (20) + ct).
    try testing.expect(out.len > core.len + ct.len);
    try testing.expectEqualSlices(u8, "\x00asm\x01\x00\x00\x00", out[0..8]);
    try testing.expectEqual(@as(u8, 0), out[8]); // custom section id
}

