//! `wabt component new` — wrap a core wasm module (with embedded
//! component-type metadata) into a top-level WebAssembly component.
//!
//! Drop-in subset of `wasm-tools component new` for the wamr build
//! pipeline:
//!
//!   wabt component new [-o <out>] [--skip-validation]
//!                      [--adapt <name>=<adapter.wasm>] <input.wasm>
//!
//! The input core wasm must already have a `component-type:<world>`
//! custom section produced by `wabt component embed` (or
//! `wasm-tools component embed`).
//!
//! Two paths:
//!
//! 1. **Plain wrap** (no `--adapt`): for each export interface in the
//!    world, build a core-instance alias for the matching
//!    `<iface>#<func>` export, a component-level func type matching
//!    the interface's signature, a `(canon lift)`, an instance
//!    bundling the lifted funcs, and a top-level export under the
//!    qualified interface name. Suitable for plain reactor-style
//!    cores like the wamr `zig-adder` fixture.
//!
//! 2. **Adapter splice** (`--adapt wasi_snapshot_preview1=<a.wasm>`):
//!    delegate to `wabt.component.adapter.adapter.splice`, which
//!    composes the embed core with the given preview1→component
//!    adapter into a four- or five-core-module component (shim,
//!    embed, adapter, fixup, optional `__main_module__` fallback)
//!    and lifts `wasi:cli/run` for top-level export. Mirrors
//!    `wasm-tools component new --adapt …` and unblocks the
//!    `zig-hello`, `zig-calculator-cmd`, and `mixed-zig-rust-calc`
//!    wamr command-component fixtures.

const std = @import("std");
const wabt = @import("wabt");

const ctypes = wabt.component.types;
const writer = wabt.component.writer;
const metadata_decode = wabt.component.wit.metadata_decode;

pub const usage =
    \\Usage: wabt component new [options] <input.wasm>
    \\
    \\Wrap a core wasm module (with embedded component-type metadata)
    \\into a top-level component.
    \\
    \\The input must already have a `component-type:<world>` custom
    \\section, as produced by `wabt component embed` or
    \\`wasm-tools component embed`.
    \\
    \\Options:
    \\  -o, --output <file>     Output file (default: <input>.component.wasm)
    \\      --skip-validation   Skip post-encoding component validation
    \\      --adapt <n>=<file>  Splice in a wasi-preview1 adapter (e.g.
    \\                          --adapt wasi_snapshot_preview1=path/to/adapter.wasm)
    \\  -h, --help              Show this help
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var output_file: ?[]const u8 = null;
    var skip_validation: bool = false;
    var input_path: ?[]const u8 = null;
    var adapt_name: ?[]const u8 = null;
    var adapt_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else if (std.mem.eql(u8, arg, "--skip-validation")) {
            skip_validation = true;
        } else if (std.mem.eql(u8, arg, "--adapt")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: --adapt requires an argument of the form <name>=<file>\n", .{});
                std.process.exit(1);
            }
            const spec = sub_args[i];
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                std.debug.print("error: --adapt expects <name>=<file>, got '{s}'\n", .{spec});
                std.process.exit(1);
            };
            if (adapt_name != null) {
                std.debug.print("error: only one --adapt is supported\n", .{});
                std.process.exit(1);
            }
            adapt_name = spec[0..eq];
            adapt_file = spec[eq + 1 ..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'. Use `wabt help component`.\n", .{arg});
            std.process.exit(1);
        } else {
            if (input_path != null) {
                std.debug.print("error: unexpected positional argument '{s}'\n", .{arg});
                std.process.exit(1);
            }
            input_path = arg;
        }
    }

    const in_path = input_path orelse {
        std.debug.print("error: component new requires <input.wasm>. Use `wabt help component`.\n", .{});
        std.process.exit(1);
    };

    const core_bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        in_path,
        alloc,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(core_bytes);

    const out_path = output_file orelse blk: {
        if (std.mem.endsWith(u8, in_path, ".wasm")) {
            const stem = in_path[0 .. in_path.len - 5];
            break :blk std.fmt.allocPrint(alloc, "{s}.component.wasm", .{stem}) catch in_path;
        }
        break :blk std.fmt.allocPrint(alloc, "{s}.component.wasm", .{in_path}) catch in_path;
    };

    const out_bytes = blk: {
        if (adapt_name) |aname| {
            const adp_path = adapt_file.?;
            const adp_bytes = std.Io.Dir.cwd().readFileAlloc(
                init.io,
                adp_path,
                alloc,
                std.Io.Limit.limited(wabt.max_input_file_size),
            ) catch |err| {
                std.debug.print("error: cannot read adapter '{s}': {any}\n", .{ adp_path, err });
                std.process.exit(1);
            };
            defer alloc.free(adp_bytes);
            break :blk wabt.component.adapter.adapter.splice(alloc, core_bytes, adp_bytes, aname) catch |err| {
                std.debug.print("error: splicing adapter '{s}': {s}\n", .{ aname, @errorName(err) });
                std.process.exit(1);
            };
        }
        break :blk buildComponent(alloc, core_bytes) catch |err| {
            std.debug.print("error: building component: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    };
    defer alloc.free(out_bytes);

    if (!skip_validation) {
        // Component-level structural validation: round-trip through
        // the loader. A semantic validator (canon-ABI, type-checking
        // imports against exports) is on the wit-resolve todo.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        _ = wabt.component.loader.load(out_bytes, arena.allocator()) catch |err| {
            std.debug.print("error: post-encoding validation failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = out_bytes,
    }) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

/// Construct the wrapping component bytes from a core module that
/// has an embedded `component-type:<world>` custom section.
pub fn buildComponent(alloc: std.mem.Allocator, core_bytes: []const u8) ![]u8 {
    const found = (try metadata_decode.extractFromCoreWasm(core_bytes)) orelse
        return error.MissingComponentTypeSection;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const decoded = try metadata_decode.decode(ar, found.payload);

    // Strip the `component-type:*` custom sections from the core
    // module — they're metadata for `component new`, not part of the
    // module that goes inside the wrapping component.
    const stripped_core = try stripComponentTypeSections(ar, core_bytes);

    // ── Build component AST.
    var core_modules = try ar.alloc(ctypes.CoreModule, 1);
    core_modules[0] = .{ .data = stripped_core };

    var core_instances = try ar.alloc(ctypes.CoreInstanceExpr, 1);
    core_instances[0] = .{ .instantiate = .{ .module_idx = 0, .args = &.{} } };

    // For each export interface, emit an alias per func, a type def
    // per func, a canon lift per func, and a component instance
    // bundling them. Imports are deferred.
    var aliases = std.ArrayListUnmanaged(ctypes.Alias).empty;
    var types = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    var canons = std.ArrayListUnmanaged(ctypes.Canon).empty;
    var instances = std.ArrayListUnmanaged(ctypes.InstanceExpr).empty;
    var exports = std.ArrayListUnmanaged(ctypes.ExportDecl).empty;

    var comp_instance_idx: u32 = 0;
    for (decoded.externs) |ext| {
        if (!ext.is_export) continue; // imports TBD
        var inline_exports = std.ArrayListUnmanaged(ctypes.InlineExport).empty;
        for (ext.funcs) |fn_ref| {
            const core_func_export_name = try std.fmt.allocPrint(ar, "{s}#{s}", .{ ext.qualified_name, fn_ref.name });
            try aliases.append(ar, .{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = 0,
                .name = core_func_export_name,
            } });
            const core_func_idx: u32 = @intCast(aliases.items.len - 1);

            try types.append(ar, .{ .func = fn_ref.sig });
            const type_idx: u32 = @intCast(types.items.len - 1);

            try canons.append(ar, .{ .lift = .{
                .core_func_idx = core_func_idx,
                .type_idx = type_idx,
                .opts = &.{},
            } });
            const lifted_func_idx: u32 = @intCast(canons.items.len - 1);

            try inline_exports.append(ar, .{
                .name = fn_ref.name,
                .sort_idx = .{ .sort = .func, .idx = lifted_func_idx },
            });
        }
        try instances.append(ar, .{ .exports = try inline_exports.toOwnedSlice(ar) });
        try exports.append(ar, .{
            .name = ext.qualified_name,
            .desc = .{ .instance = 0 },
            .sort_idx = .{ .sort = .instance, .idx = comp_instance_idx },
        });
        comp_instance_idx += 1;
    }

    const comp: ctypes.Component = .{
        .core_modules = core_modules,
        .core_instances = core_instances,
        .core_types = &.{},
        .components = &.{},
        .instances = try instances.toOwnedSlice(ar),
        .aliases = try aliases.toOwnedSlice(ar),
        .types = try types.toOwnedSlice(ar),
        .canons = try canons.toOwnedSlice(ar),
        .imports = &.{},
        .exports = try exports.toOwnedSlice(ar),
    };
    return writer.encode(alloc, &comp);
}

/// Walk core wasm sections, dropping every `component-type:*` custom
/// section. Returns a freshly-allocated slice that borrows nothing.
fn stripComponentTypeSections(alloc: std.mem.Allocator, core_bytes: []const u8) ![]u8 {
    if (core_bytes.len < 8) return error.InvalidCoreModule;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidCoreModule;

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, core_bytes[0..8]);

    var i: usize = 8;
    while (i < core_bytes.len) {
        const id = core_bytes[i];
        i += 1;
        const sz = try readU32Leb(core_bytes, i);
        i += sz.bytes_read;
        if (i + sz.value > core_bytes.len) return error.InvalidCoreModule;
        const body = core_bytes[i .. i + sz.value];
        i += sz.value;

        if (id == 0) {
            const n = try readU32Leb(body, 0);
            const name_len = n.value;
            if (n.bytes_read + name_len > body.len) return error.InvalidCoreModule;
            const sec_name = body[n.bytes_read .. n.bytes_read + name_len];
            if (std.mem.startsWith(u8, sec_name, "component-type:")) continue;
        }
        try out.append(alloc, id);
        try writeU32Leb(alloc, &out, sz.value);
        try out.appendSlice(alloc, body);
    }
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
        if ((b & 0x80) == 0) return .{ .value = result, .bytes_read = i + 1 - start };
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
const metadata_encode = wabt.component.wit.metadata_encode;
const loader = wabt.component.loader;

test "buildComponent: builds a wrapping component for the adder fixture" {
    // Synthesize an embedded core wasm by hand: minimal core module
    // exporting `docs:adder/add@0.1.0#add` (i32, i32) -> i32, with
    // a `component-type:adder` custom section appended.
    const core_only = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        // type section: 1 type — (func (param i32 i32) (result i32))
        0x01, 0x07,
        0x01,
        0x60, 0x02, 0x7f, 0x7f,
        0x01, 0x7f,
        // function section: 1 func of type 0
        0x03, 0x02,
        0x01, 0x00,
        // export section: 1 export (1+22 name, 1 byte sort, 1 byte idx)
        0x07, 25,
        0x01,
        23, 'd', 'o', 'c', 's', ':', 'a', 'd', 'd', 'e', 'r', '/', 'a', 'd', 'd', '@', '0', '.', '1', '.', '0', '#', 'a', 'd', 'd',
        0x00, 0x00,
        // code section: 1 body
        0x0a, 0x09,
        0x01,
        0x07, 0x00,
        0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
    };

    // Compute the component-type:adder payload.
    const ct_payload = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\    add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\    export add;
        \\}
    , "adder");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, &core_only);
    const cs_name = "component-type:adder";
    var cs_body = std.ArrayListUnmanaged(u8).empty;
    defer cs_body.deinit(testing.allocator);
    try writeU32Leb(testing.allocator, &cs_body, @intCast(cs_name.len));
    try cs_body.appendSlice(testing.allocator, cs_name);
    try cs_body.appendSlice(testing.allocator, ct_payload);
    try core_with_ct.append(testing.allocator, 0);
    try writeU32Leb(testing.allocator, &core_with_ct, @intCast(cs_body.items.len));
    try core_with_ct.appendSlice(testing.allocator, cs_body.items);

    const comp_bytes = try buildComponent(testing.allocator, core_with_ct.items);
    defer testing.allocator.free(comp_bytes);

    // Component preamble check.
    try testing.expect(comp_bytes.len > 16);
    try testing.expectEqualSlices(u8, "\x00asm", comp_bytes[0..4]);
    try testing.expectEqual(@as(u8, 0x0d), comp_bytes[4]); // version
    try testing.expectEqual(@as(u8, 0x01), comp_bytes[6]); // layer

    // Round-trip through loader: structure should match.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());
    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    try testing.expectEqual(@as(usize, 1), loaded.core_instances.len);
    try testing.expectEqual(@as(usize, 1), loaded.aliases.len);
    try testing.expectEqual(@as(usize, 1), loaded.types.len);
    try testing.expectEqual(@as(usize, 1), loaded.canons.len);
    try testing.expectEqual(@as(usize, 1), loaded.instances.len);
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings("docs:adder/add@0.1.0", loaded.exports[0].name);
}

test "buildComponent: rejects core wasm without component-type section" {
    const bare = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    try testing.expectError(error.MissingComponentTypeSection, buildComponent(testing.allocator, &bare));
}
