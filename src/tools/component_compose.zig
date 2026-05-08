//! `wabt component compose` — link a consumer component's imports to
//! one or more provider components' exports.
//!
//! Drop-in subset of `wasm-tools compose` for the wamr build pipeline:
//!
//!   wabt component compose [-d <provider.wasm>]... [-o <out>] [--skip-validation] <consumer.wasm>
//!
//! Resolution algorithm:
//!
//!   * Parse the consumer + each provider component.
//!   * For every import on the consumer, find the first provider
//!     whose export name equals the import name.
//!   * Emit a wrapping component that:
//!       - nests the consumer + each provider as `components[]`,
//!       - instantiates each provider once with no args (assumes
//!         providers themselves are self-contained — typical for the
//!         wamr `zig-adder` use case),
//!       - aliases the matched export of each provider instance,
//!       - instantiates the consumer, passing the matched aliases as
//!         instantiation args under the import names,
//!       - re-exports the consumer's exports under the same names.
//!   * Imports that have no matching provider export are bubbled up
//!     to the outer component as imports so the result remains
//!     well-typed.

const std = @import("std");
const wabt = @import("wabt");

const ctypes = wabt.component.types;
const writer = wabt.component.writer;
const loader = wabt.component.loader;
const compose = wabt.component.compose;

pub const usage =
    \\Usage: wabt component compose [options] <consumer.wasm>
    \\
    \\Link a consumer component's imports to one or more provider
    \\components' exports by interface name.
    \\
    \\Options:
    \\  -d, --define <file>     Provider component (repeatable)
    \\  -o, --output <file>     Output file (default: <input>.composed.wasm)
    \\      --skip-validation   Skip post-encoding component validation
    \\  -h, --help              Show this help
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var providers_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer providers_paths.deinit(alloc);
    var output_file: ?[]const u8 = null;
    var skip_validation: bool = false;
    var consumer_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--define")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires a path argument\n", .{arg});
                std.process.exit(1);
            }
            try providers_paths.append(alloc, sub_args[i]);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires a path argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else if (std.mem.eql(u8, arg, "--skip-validation")) {
            skip_validation = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'. Use `wabt help component`.\n", .{arg});
            std.process.exit(1);
        } else {
            if (consumer_path != null) {
                std.debug.print("error: unexpected positional '{s}'\n", .{arg});
                std.process.exit(1);
            }
            consumer_path = arg;
        }
    }

    const cons_path = consumer_path orelse {
        std.debug.print("error: component compose requires <consumer.wasm>. Use `wabt help component`.\n", .{});
        std.process.exit(1);
    };

    const consumer_bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        cons_path,
        alloc,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print("error: cannot read consumer '{s}': {any}\n", .{ cons_path, err });
        std.process.exit(1);
    };
    defer alloc.free(consumer_bytes);

    var provider_bytes = try alloc.alloc([]u8, providers_paths.items.len);
    defer {
        for (provider_bytes) |b| alloc.free(b);
        alloc.free(provider_bytes);
    }
    for (providers_paths.items, 0..) |p, idx| {
        provider_bytes[idx] = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            p,
            alloc,
            std.Io.Limit.limited(wabt.max_input_file_size),
        ) catch |err| {
            std.debug.print("error: cannot read provider '{s}': {any}\n", .{ p, err });
            std.process.exit(1);
        };
    }

    const out_path = output_file orelse blk: {
        if (std.mem.endsWith(u8, cons_path, ".wasm")) {
            const stem = cons_path[0 .. cons_path.len - 5];
            break :blk std.fmt.allocPrint(alloc, "{s}.composed.wasm", .{stem}) catch cons_path;
        }
        break :blk std.fmt.allocPrint(alloc, "{s}.composed.wasm", .{cons_path}) catch cons_path;
    };

    const out_bytes = composeBinaries(alloc, consumer_bytes, provider_bytes) catch |err| {
        std.debug.print("error: composing component: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(out_bytes);

    if (!skip_validation) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        _ = loader.load(out_bytes, arena.allocator()) catch |err| {
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

/// Build a composed component from raw consumer + provider bytes.
///
/// The wrapper structure (assembled directly, bypassing the AST so we
/// can emit interleaved instance/alias sections that the AST cannot
/// represent):
///
///   [imports]?           ← unmet consumer imports bubbled up
///   component[consumer]
///   component[provider 0..N-1]
///   instance: instantiate each provider (no args)
///   alias: per binding, alias provider-instance.<name> as instance
///   instance: instantiate consumer with bindings as args
///   alias: per consumer export, alias consumer-instance.<name>
///   export: re-export under same name
pub fn composeBinaries(
    alloc: std.mem.Allocator,
    consumer_bytes: []const u8,
    provider_bytes: []const []u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const consumer = try loader.load(consumer_bytes, ar);
    const providers = try ar.alloc(ctypes.Component, provider_bytes.len);
    for (provider_bytes, 0..) |b, i| providers[i] = try loader.load(b, ar);

    const provider_ptrs = try ar.alloc(*const ctypes.Component, providers.len);
    for (providers, 0..) |*p, i| provider_ptrs[i] = p;

    const link = try compose.plan(ar, &consumer, provider_ptrs);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);

    // Preamble.
    try out.appendSlice(alloc, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    // ── Bubble up unmet imports first. ──
    if (link.unresolved.len > 0) {
        var imp_body = std.ArrayListUnmanaged(u8).empty;
        defer imp_body.deinit(alloc);
        try writeU32Leb(alloc, &imp_body, @intCast(link.unresolved.len));
        for (link.unresolved) |idx| {
            const imp = consumer.imports[idx];
            try writeExternName(alloc, &imp_body, imp.name);
            try writeExternDesc(alloc, &imp_body, imp.desc);
        }
        try emitSection(alloc, &out, 0x0a, imp_body.items);
    }

    // ── Nested components: consumer at idx 0, providers at idx 1..N. ──
    try emitSection(alloc, &out, 0x04, consumer_bytes);
    for (provider_bytes) |p| try emitSection(alloc, &out, 0x04, p);

    const num_providers: u32 = @intCast(provider_bytes.len);

    // ── Instance section #1: instantiate each provider with no args. ──
    if (num_providers > 0) {
        var inst_body = std.ArrayListUnmanaged(u8).empty;
        defer inst_body.deinit(alloc);
        try writeU32Leb(alloc, &inst_body, num_providers);
        for (0..num_providers) |p_local| {
            const comp_idx: u32 = @intCast(p_local + 1); // consumer is at 0
            try inst_body.append(alloc, 0x00); // tag: instantiate
            try writeU32Leb(alloc, &inst_body, comp_idx);
            try writeU32Leb(alloc, &inst_body, 0); // 0 args
        }
        try emitSection(alloc, &out, 0x05, inst_body.items);
    }

    // ── Alias section #1: per binding, alias provider-instance.<name>. ──
    var binding_alias_idxs = std.ArrayListUnmanaged(u32).empty;
    if (link.bindings.len > 0) {
        var alias_body = std.ArrayListUnmanaged(u8).empty;
        defer alias_body.deinit(alloc);
        try writeU32Leb(alloc, &alias_body, @intCast(link.bindings.len));
        for (link.bindings) |b| {
            // alias = sort=instance(0x05) tag=instance_export(0x00) instance_idx name
            try alias_body.append(alloc, 0x05); // sort = instance
            try alias_body.append(alloc, 0x00); // tag: instance export
            try writeU32Leb(alloc, &alias_body, b.provider_idx);
            try writeU32Leb(alloc, &alias_body, @intCast(b.name.len));
            try alias_body.appendSlice(alloc, b.name);
            try binding_alias_idxs.append(ar, b.provider_idx); // alias idx == its position
        }
        try emitSection(alloc, &out, 0x06, alias_body.items);
    }

    // The component-instance index space now contains:
    //   0..N-1     = provider instances (from instance section #1)
    //   N..N+K-1   = aliased provider exports (from alias section #1)
    // The consumer is the next instance we declare (idx N+K).
    const consumer_inst_idx: u32 = num_providers + @as(u32, @intCast(link.bindings.len));

    // ── Instance section #2: instantiate consumer with bindings as args. ──
    {
        var inst_body = std.ArrayListUnmanaged(u8).empty;
        defer inst_body.deinit(alloc);
        try writeU32Leb(alloc, &inst_body, 1); // 1 instance entry
        try inst_body.append(alloc, 0x00); // tag: instantiate
        try writeU32Leb(alloc, &inst_body, 0); // component idx 0 (consumer)
        try writeU32Leb(alloc, &inst_body, @intCast(link.bindings.len)); // arg count
        for (link.bindings, 0..) |b, i| {
            const alias_inst_idx: u32 = num_providers + @as(u32, @intCast(i));
            try writeU32Leb(alloc, &inst_body, @intCast(b.name.len));
            try inst_body.appendSlice(alloc, b.name);
            // sortidx for arg: instance sort + alias_inst_idx
            try inst_body.append(alloc, 0x05); // instance
            try writeU32Leb(alloc, &inst_body, alias_inst_idx);
        }
        try emitSection(alloc, &out, 0x05, inst_body.items);
    }

    // ── Alias section #2 + Export section: re-export consumer's exports. ──
    if (consumer.exports.len > 0) {
        var alias_body = std.ArrayListUnmanaged(u8).empty;
        defer alias_body.deinit(alloc);
        try writeU32Leb(alloc, &alias_body, @intCast(consumer.exports.len));

        var exp_body = std.ArrayListUnmanaged(u8).empty;
        defer exp_body.deinit(alloc);
        try writeU32Leb(alloc, &exp_body, @intCast(consumer.exports.len));

        // Per-sort index counters for the slots produced by the
        // export-side aliases. The consumer-instance and the K
        // binding-alias slots already populated the instance space:
        //   instances: [provider 0..N-1, binding 0..K-1, consumer N+K]
        //   funcs/components/types/values: empty (so far in this wrapper).
        var instance_counter: u32 = num_providers + @as(u32, @intCast(link.bindings.len)) + 1;
        var func_counter: u32 = 0;
        var component_counter: u32 = 0;
        var type_counter: u32 = 0;
        var value_counter: u32 = 0;
        var core_func_counter: u32 = 0;
        var core_module_counter: u32 = 0;

        for (consumer.exports) |exp| {
            const sort_idx = exp.sort_idx orelse synthSortFromExport(exp);
            const sort_byte = sortToByte(sort_idx.sort);
            try alias_body.append(alloc, sort_byte);
            try alias_body.append(alloc, 0x00); // tag: instance export
            try writeU32Leb(alloc, &alias_body, consumer_inst_idx);
            try writeU32Leb(alloc, &alias_body, @intCast(exp.name.len));
            try alias_body.appendSlice(alloc, exp.name);

            const slot_idx: u32 = switch (sort_idx.sort) {
                .instance => blk: {
                    const v = instance_counter;
                    instance_counter += 1;
                    break :blk v;
                },
                .func => blk: {
                    const v = func_counter;
                    func_counter += 1;
                    break :blk v;
                },
                .component => blk: {
                    const v = component_counter;
                    component_counter += 1;
                    break :blk v;
                },
                .type => blk: {
                    const v = type_counter;
                    type_counter += 1;
                    break :blk v;
                },
                .value => blk: {
                    const v = value_counter;
                    value_counter += 1;
                    break :blk v;
                },
                .core => blk: {
                    // Core sub-sorts live in their own spaces; the
                    // alias contributes to the matching one.
                    if (sort_idx.sort.core == .func) {
                        const v = core_func_counter;
                        core_func_counter += 1;
                        break :blk v;
                    } else if (sort_idx.sort.core == .module) {
                        const v = core_module_counter;
                        core_module_counter += 1;
                        break :blk v;
                    } else {
                        break :blk 0;
                    }
                },
            };

            try writeExternName(alloc, &exp_body, exp.name);
            try exp_body.append(alloc, sort_byte);
            try writeU32Leb(alloc, &exp_body, slot_idx);
            try exp_body.append(alloc, 0x00); // un-ascribed desc
        }
        try emitSection(alloc, &out, 0x06, alias_body.items);
        try emitSection(alloc, &out, 0x0b, exp_body.items);
    }

    return out.toOwnedSlice(alloc);
}

fn sortToByte(s: ctypes.Sort) u8 {
    return switch (s) {
        .core => 0x00,
        .func => 0x01,
        .value => 0x02,
        .type => 0x03,
        .component => 0x04,
        .instance => 0x05,
    };
}

fn writeExternName(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    try out.append(alloc, 0x00); // plain-name prefix
    try writeU32Leb(alloc, out, @intCast(name.len));
    try out.appendSlice(alloc, name);
}

fn writeExternDesc(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), desc: ctypes.ExternDesc) !void {
    switch (desc) {
        .module => |idx| {
            try out.append(alloc, 0x00);
            try writeU32Leb(alloc, out, idx);
        },
        .func => |idx| {
            try out.append(alloc, 0x01);
            try writeU32Leb(alloc, out, idx);
        },
        .value => |v| {
            try out.append(alloc, 0x02);
            try writeU32Leb(alloc, out, v.type_idx);
        },
        .type => |bound| switch (bound) {
            .eq => |idx| {
                try out.append(alloc, 0x03);
                try out.append(alloc, 0x00);
                try writeU32Leb(alloc, out, idx);
            },
            .sub_resource => {
                try out.append(alloc, 0x03);
                try out.append(alloc, 0x01);
            },
        },
        .component => |idx| {
            try out.append(alloc, 0x04);
            try writeU32Leb(alloc, out, idx);
        },
        .instance => |idx| {
            try out.append(alloc, 0x05);
            try writeU32Leb(alloc, out, idx);
        },
    }
}

fn emitSection(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    id: u8,
    body: []const u8,
) !void {
    try out.append(alloc, id);
    try writeU32Leb(alloc, out, @intCast(body.len));
    try out.appendSlice(alloc, body);
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

fn synthSortFromExport(exp: ctypes.ExportDecl) ctypes.SortIdx {
    return switch (exp.desc) {
        .module => .{ .sort = .{ .core = .module }, .idx = 0 },
        .func => .{ .sort = .func, .idx = 0 },
        .value => .{ .sort = .value, .idx = 0 },
        .type => .{ .sort = .type, .idx = 0 },
        .component => .{ .sort = .component, .idx = 0 },
        .instance => .{ .sort = .instance, .idx = 0 },
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "composeBinaries: links consumer import to provider export end-to-end" {
    // Build a provider component with one instance export named
    // "docs:adder/add@0.1.0" (a func 'add' inside).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Provider: a minimal hand-built component that exposes one
    // empty instance export. We use the InstanceExpr exports form
    // so the writer doesn't need a core module to be present.
    const prov_inst_exps = [_]ctypes.InlineExport{};
    const prov_instances = [_]ctypes.InstanceExpr{
        .{ .exports = &prov_inst_exps },
    };
    const prov_exports = [_]ctypes.ExportDecl{
        .{
            .name = "docs:adder/add@0.1.0",
            .desc = .{ .instance = 0 },
            .sort_idx = .{ .sort = .instance, .idx = 0 },
        },
    };
    const provider: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &prov_instances, .aliases = &.{},
        .types = &.{}, .canons = &.{}, .imports = &.{}, .exports = &prov_exports,
    };
    const provider_bytes = try writer.encode(ar, &provider);

    // Consumer: imports the same name, exports nothing.
    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "docs:adder/add@0.1.0", .desc = .{ .instance = 0 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &.{}, .aliases = &.{},
        .types = &.{}, .canons = &.{}, .imports = &cons_imports, .exports = &.{},
    };
    const consumer_bytes = try writer.encode(ar, &consumer);

    var providers_buf = [_][]u8{provider_bytes};
    const composed = try composeBinaries(testing.allocator, consumer_bytes, providers_buf[0..]);
    defer testing.allocator.free(composed);

    // Sanity-check the wrapper structure.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());
    try testing.expectEqual(@as(usize, 2), loaded.components.len); // consumer + provider
    try testing.expectEqual(@as(usize, 2), loaded.instances.len); // provider inst + consumer inst
    try testing.expectEqual(@as(usize, 1), loaded.aliases.len); // the import binding
    try testing.expectEqual(@as(usize, 0), loaded.imports.len); // fully resolved
    try testing.expectEqual(@as(usize, 0), loaded.exports.len); // consumer had none
}

test "composeBinaries: bubbles up unmet imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:cli/environment@0.2.0", .desc = .{ .instance = 0 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &.{}, .aliases = &.{},
        .types = &.{}, .canons = &.{}, .imports = &cons_imports, .exports = &.{},
    };
    const consumer_bytes = try writer.encode(ar, &consumer);

    const empty_providers: []const []u8 = &.{};
    const composed = try composeBinaries(testing.allocator, consumer_bytes, empty_providers);
    defer testing.allocator.free(composed);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expectEqualStrings("wasi:cli/environment@0.2.0", loaded.imports[0].name);
}
