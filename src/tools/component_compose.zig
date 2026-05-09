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
const type_walk = wabt.component.type_walk;

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

    const num_unresolved: u32 = @intCast(link.unresolved.len);
    const num_providers: u32 = @intCast(provider_bytes.len);
    const num_bindings: u32 = @intCast(link.bindings.len);

    // ── Wrapper prologue: build the interleaved type / alias / import
    //    section sequence that establishes the wrapper's outer type
    //    indexspace before the consumer/provider components are
    //    declared.
    //
    //    Pre-fix bug 1 (#115/#118, fixed in #119): the wrapper used
    //    to emit an `import` section with `desc.instance(N)`
    //    referencing the *consumer's* type idx N — but the wrapper
    //    had no types[] section at all, producing a malformed
    //    component (id 0x0a precedes id 0x07 on every emission).
    //
    //    Pre-fix bug 2 (#121): the wrapper copied only the import's
    //    immediately-referenced TypeDef, leaving its body's outer
    //    aliases (`(alias outer 1 X)`) and depth-0 valtype refs
    //    pointing at consumer-typespace idxs that were never
    //    materialised in the wrapper. wasm-tools rejected the result
    //    with "type index out of bounds".
    //
    //    Pre-fix bug 3 (#129): the wrapper substituted an empty
    //    instance type for every consumer type-indexspace slot whose
    //    contributor was an outer-level alias decl, so depth-1 outer
    //    aliases inside cloned instance-type bodies (`(alias outer 1
    //    N)`) lost their resource binding. wasm-tools rejected the
    //    result with "type index N is not a resource type".
    //
    //    Fix: walk the consumer's `type_indexspace` in encounter
    //    order, restricted to slots reachable from unresolved
    //    imports, and emit each closure slot as a *cloned type def*
    //    (for `.type_def` contributors) or a *replicated alias decl*
    //    (for `.alias` contributors). After each emitted type def,
    //    bubble up any unresolved instance-typed import whose desc
    //    references that exact slot — this preserves the consumer's
    //    `type N → import (instance (type N)) → alias …` interleaving
    //    pattern that wt-component output relies on. ──
    const prologue = try buildWrapperPrologue(ar, &consumer, link);
    const types_list_items = prologue.types;
    const aliases_prologue = prologue.aliases;
    const imports_arr = prologue.imports;
    const prologue_section_entries = prologue.section_entries;
    const num_prologue_aliases: u32 = @intCast(aliases_prologue.len);

    // ── Nested components: consumer at idx 0, providers at idx 1..N.
    //    Each is wrapped in a passthrough Component AST whose
    //    `raw_bytes` field carries the original encoding, which the
    //    writer emits verbatim. ──
    const components_arr = try ar.alloc(*ctypes.Component, 1 + provider_bytes.len);
    {
        const cons_ptr = try ar.create(ctypes.Component);
        cons_ptr.* = passthroughComponent(consumer_bytes);
        components_arr[0] = cons_ptr;
    }
    for (provider_bytes, 0..) |pb, i| {
        const p_ptr = try ar.create(ctypes.Component);
        p_ptr.* = passthroughComponent(pb);
        components_arr[i + 1] = p_ptr;
    }

    // ── Instances. We emit two instance sections (providers, then
    //    consumer); the slice below holds them in declaration order
    //    and `section_order` slices them apart. ──
    var instances_list = std.ArrayListUnmanaged(ctypes.InstanceExpr).empty;
    for (0..num_providers) |p_local| {
        const comp_idx: u32 = @intCast(p_local + 1);
        try instances_list.append(ar, .{ .instantiate = .{
            .component_idx = comp_idx,
            .args = &.{},
        } });
    }

    // After the import section + component sections + instance #1 +
    // alias #1, the component-instance indexspace is:
    //   imports[0..num_unresolved-1]               idxs 0..num_unresolved-1
    //   provider instances (instance section #1)   idxs num_unresolved..num_unresolved+num_providers-1
    //   binding aliases    (alias    section #1)   idxs num_unresolved+num_providers..
    //                                                   num_unresolved+num_providers+num_bindings-1
    //
    // Consumer args: pass each binding by its alias idx, plus pass
    // each bubbled-up unresolved import through under its original
    // name so the consumer is fully satisfied at instantiation time.
    // (The pre-fix code only passed bindings, leaving any bubbled
    // import unsupplied — a separate latent bug in the same path.)
    const consumer_args = try ar.alloc(
        ctypes.InstantiateArg,
        link.bindings.len + link.unresolved.len,
    );
    for (link.bindings, 0..) |b, i| {
        const alias_inst_idx: u32 = num_unresolved + num_providers + @as(u32, @intCast(i));
        consumer_args[i] = .{
            .name = b.name,
            .sort_idx = .{ .sort = .instance, .idx = alias_inst_idx },
        };
    }
    for (link.unresolved, 0..) |u_idx, i| {
        consumer_args[link.bindings.len + i] = .{
            .name = consumer.imports[u_idx].name,
            .sort_idx = .{ .sort = .instance, .idx = @as(u32, @intCast(i)) },
        };
    }
    try instances_list.append(ar, .{ .instantiate = .{
        .component_idx = 0,
        .args = consumer_args,
    } });
    const consumer_inst_idx: u32 = num_unresolved + num_providers + num_bindings;

    // ── Aliases. Prologue aliases (resource bindings replicated from
    //    the consumer) come first so prologue section_entries can
    //    address them by raw idx. Then bindings (resolve providers),
    //    then export-aliases (re-export consumer outputs). ──
    var aliases_list = std.ArrayListUnmanaged(ctypes.Alias).empty;
    try aliases_list.appendSlice(ar, aliases_prologue);
    for (link.bindings) |b| {
        // Provider was instantiated at instance idx
        // num_unresolved + b.provider_idx (imports come before
        // instances in the indexspace; the pre-fix code didn't
        // account for that contribution and was off-by-N when any
        // import bubbled up alongside a binding).
        const provider_inst_idx: u32 = num_unresolved + b.provider_idx;
        try aliases_list.append(ar, .{ .instance_export = .{
            .sort = .instance,
            .instance_idx = provider_inst_idx,
            .name = b.name,
        } });
    }

    // ── Re-export consumer's exports. Each export needs (a) an
    //    alias from the consumer instance to a wrapper-local slot,
    //    and (b) an `export` decl referencing that slot. ──
    var exports_list = std.ArrayListUnmanaged(ctypes.ExportDecl).empty;
    var instance_counter: u32 = consumer_inst_idx + 1;
    var func_counter: u32 = 0;
    var component_counter: u32 = 0;
    var type_counter: u32 = @intCast(types_list_items.len);
    var value_counter: u32 = 0;
    var core_func_counter: u32 = 0;
    var core_module_counter: u32 = 0;

    for (consumer.exports) |exp| {
        const sort_idx_in = exp.sort_idx orelse synthSortFromExport(exp);
        try aliases_list.append(ar, .{ .instance_export = .{
            .sort = sort_idx_in.sort,
            .instance_idx = consumer_inst_idx,
            .name = exp.name,
        } });

        const slot_idx: u32 = switch (sort_idx_in.sort) {
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
            .core => |cs| switch (cs) {
                .func => blk: {
                    const v = core_func_counter;
                    core_func_counter += 1;
                    break :blk v;
                },
                .module => blk: {
                    const v = core_module_counter;
                    core_module_counter += 1;
                    break :blk v;
                },
                else => 0,
            },
        };

        try exports_list.append(ar, .{
            .name = exp.name,
            .desc = unascribedReexportDesc(sort_idx_in.sort, slot_idx, exp.desc),
            .sort_idx = .{ .sort = sort_idx_in.sort, .idx = slot_idx },
        });
    }

    // ── Section emission order:
    //     prologue (interleaved type / alias / import per the
    //       consumer's encounter order, restricted to the closure of
    //       slots reachable from unresolved imports),
    //     component×(N+1),
    //     instance #1 (providers), alias (bindings),
    //     instance #2 (consumer), alias (export aliases),
    //     export.
    //   The component-instance indexspace fills forward-only — each
    //   section only references slots produced by earlier sections.
    //   The wrapper's outer type indexspace is filled by the prologue
    //   chunks; everything from `.component` onward leaves it
    //   untouched. ──
    var section_order = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    try section_order.appendSlice(ar, prologue_section_entries);
    try section_order.append(ar, .{
        .kind = .component,
        .start = 0,
        .count = @intCast(components_arr.len),
    });
    if (num_providers > 0) try section_order.append(ar, .{
        .kind = .instance,
        .start = 0,
        .count = num_providers,
    });
    if (num_bindings > 0) try section_order.append(ar, .{
        .kind = .alias,
        .start = num_prologue_aliases,
        .count = num_bindings,
    });
    try section_order.append(ar, .{
        .kind = .instance,
        .start = num_providers,
        .count = 1,
    });
    if (consumer.exports.len > 0) try section_order.append(ar, .{
        .kind = .alias,
        .start = num_prologue_aliases + num_bindings,
        .count = @intCast(consumer.exports.len),
    });
    if (exports_list.items.len > 0) try section_order.append(ar, .{
        .kind = .@"export",
        .start = 0,
        .count = @intCast(exports_list.items.len),
    });

    const wrapper: ctypes.Component = .{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = components_arr,
        .instances = instances_list.items,
        .aliases = aliases_list.items,
        .types = types_list_items,
        .canons = &.{},
        .imports = imports_arr,
        .exports = exports_list.items,
        .section_order = section_order.items,
    };

    return writer.encode(alloc, &wrapper);
}

/// Look up the TypeDef the consumer's type-indexspace slot `type_idx`
/// resolves to, falling back through several materialization shapes.
/// Returns null if the slot exists only as an import/alias contribution
/// (in which case the caller must replicate the contributor decl in the
/// wrapper rather than substituting an empty instance type — see #129).
fn lookupConsumerType(c: *const ctypes.Component, type_idx: u32) ?ctypes.TypeDef {
    if (c.type_indexspace.len > 0) {
        if (type_idx >= c.type_indexspace.len) return null;
        const contributor = c.type_indexspace[type_idx];
        const local = switch (contributor) {
            .type_def => |idx| idx,
            .import, .alias => return null,
        };
        if (local >= c.types.len) return null;
        return c.types[local];
    }
    if (type_idx >= c.types.len) return null;
    return c.types[type_idx];
}

/// Build a stub `Component` whose `raw_bytes` carry the original
/// encoding. The writer skips re-serialization for this shape and
/// emits the bytes verbatim — the only way to faithfully preserve
/// the inner component's section interleaving.
fn passthroughComponent(bytes: []const u8) ctypes.Component {
    return .{
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
        .raw_bytes = bytes,
    };
}

/// Result of building the wrapping component's prologue — the
/// interleaved type / alias / import section sequence that
/// establishes the wrapper's outer type indexspace before the
/// consumer/provider components are declared.
const Prologue = struct {
    /// Cloned consumer TypeDefs in encounter order, ready to assign
    /// to `Component.types`. Each TypeDef's body has been deep-cloned
    /// with all depth-0 operands renumbered through `type_remap`.
    types: []const ctypes.TypeDef,
    /// Replicated consumer alias decls (sort `.type`,
    /// `instance_export` form) in encounter order, ready to be the
    /// *prefix* of `Component.aliases` — bindings + export-aliases
    /// follow.
    aliases: []const ctypes.Alias,
    /// Bubbled-up unresolved consumer imports in the order they should
    /// appear in `Component.imports`. Each desc has been deep-cloned
    /// with its type-idx operands renumbered through `type_remap`.
    imports: []const ctypes.ImportDecl,
    /// Section-emission entries for the prologue, interleaving
    /// `.type` / `.alias` / `.import` sections in the consumer's
    /// encounter order. Concatenated into the wrapper's overall
    /// `section_order`.
    section_entries: []const ctypes.SectionEntry,
    /// Mapping `consumer.type_indexspace[X]` → wrapper outer type
    /// indexspace idx. Slots not in the closure remain `SENTINEL`
    /// (max u32). Sized to fit any legal idx the cloner might
    /// encounter (max of `consumer.type_indexspace.len`,
    /// `consumer.types.len`, and the highest BFS-encountered idx).
    type_remap: []const u32,
};

const SENTINEL_TYPE_IDX: u32 = std.math.maxInt(u32);

/// Build the wrapping component's prologue: walk the consumer's
/// `type_indexspace` in encounter order, restricted to slots
/// reachable from `link.unresolved` imports, and emit each closure
/// slot as a cloned type def (`.type_def` contributors) or a
/// replicated alias decl (`.alias` contributors). After each emitted
/// slot, bubble up any unresolved instance-typed import whose desc
/// references that exact slot — preserving the consumer's
/// `type N → import (instance (type N)) → alias …` interleaving
/// pattern that wt-component output relies on.
///
/// Forward-only references hold by virtue of walking the consumer in
/// encounter order: a well-formed component only has type-def bodies
/// referencing earlier type-indexspace slots, only has imports'
/// descs referencing earlier type-indexspace slots, and only has
/// aliases' instance-idx operands referencing earlier
/// instance-indexspace slots.
fn buildWrapperPrologue(
    arena: std.mem.Allocator,
    consumer: *const ctypes.Component,
    link: compose.Plan,
) !Prologue {
    // Map: consumer.imports idx → position within `link.unresolved`.
    // Aliases of sort `.type` whose source instance is an unresolved
    // consumer instance import remap their `instance_idx` through
    // this table to the wrapper-instance idx the bubbled-up import
    // occupies. Only `.instance`-desc imports contribute to the
    // wrapper's instance indexspace, but we record all entries so the
    // caller can detect non-instance unresolved imports.
    var unres_pos = std.AutoHashMapUnmanaged(u32, u32).empty;
    var inst_slot_for_unres_imp = std.AutoHashMapUnmanaged(u32, u32).empty;
    var inst_count: u32 = 0;
    for (link.unresolved, 0..) |imp_idx, k| {
        try unres_pos.put(arena, imp_idx, @intCast(k));
        const imp = consumer.imports[imp_idx];
        if (imp.desc == .instance) {
            try inst_slot_for_unres_imp.put(arena, imp_idx, inst_count);
            inst_count += 1;
        }
    }

    // Map: consumer type-indexspace idx → unresolved consumer.imports
    // idx whose `.instance` desc references that slot. Used to bubble
    // up each unresolved instance import right after its referenced
    // type slot, preserving the consumer's interleaving.
    var imp_for_type_idx = std.AutoHashMapUnmanaged(u32, u32).empty;
    for (link.unresolved) |imp_idx| {
        const imp = consumer.imports[imp_idx];
        if (imp.desc == .instance) {
            try imp_for_type_idx.put(arena, imp.desc.instance, imp_idx);
        }
    }

    // ── BFS the closure of consumer-typespace idxs reachable from
    //    every unresolved import's desc. Only `.type_def` contributor
    //    slots have a body to walk; `.alias` and `.import` slots are
    //    terminal at this level. ──
    var queue = std.ArrayListUnmanaged(u32).empty;
    var in_closure = std.AutoHashMapUnmanaged(u32, void).empty;
    var max_idx: u32 = 0;

    for (link.unresolved) |u_idx| {
        const imp = consumer.imports[u_idx];
        var seeds = std.ArrayListUnmanaged(u32).empty;
        try type_walk.collectExternDescRefs(arena, imp.desc, &seeds);
        for (seeds.items) |s| {
            if ((try in_closure.fetchPut(arena, s, {})) == null) {
                try queue.append(arena, s);
                if (s > max_idx) max_idx = s;
            }
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        const td = lookupConsumerType(consumer, cur) orelse continue;
        var refs = std.ArrayListUnmanaged(u32).empty;
        try type_walk.collectTypeDefRefs(arena, td, &refs, 0);
        for (refs.items) |r| {
            if ((try in_closure.fetchPut(arena, r, {})) == null) {
                try queue.append(arena, r);
                if (r > max_idx) max_idx = r;
            }
        }
    }

    // remap covers every consumer-typespace idx that could be
    // operand to a depth-0 ref in any cloned body. Size it to
    // accommodate the consumer's indexspace, its types[], and the
    // highest BFS-encountered idx (which may sit *past* the
    // indexspace for hand-built fixtures with `types: &.{}` whose
    // imports still cite a numeric type idx).
    var remap_len: usize = consumer.type_indexspace.len;
    if (consumer.types.len > remap_len) remap_len = consumer.types.len;
    if (in_closure.count() > 0 and @as(usize, max_idx) + 1 > remap_len) {
        remap_len = @as(usize, max_idx) + 1;
    }
    const remap = try arena.alloc(u32, remap_len);
    @memset(remap, SENTINEL_TYPE_IDX);

    // ── Walk the consumer type-indexspace in encounter order. For
    //    each closure slot, emit either a cloned type def or a
    //    replicated alias. After each slot, bubble up any unresolved
    //    instance-typed import whose desc references it. Adjacent
    //    same-kind emissions chunk into a single SectionEntry. ──
    var types_out = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    var aliases_out = std.ArrayListUnmanaged(ctypes.Alias).empty;
    var imports_out = std.ArrayListUnmanaged(ctypes.ImportDecl).empty;
    var section_entries = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    var emitted_imp = std.AutoHashMapUnmanaged(u32, void).empty;

    var emitter: PrologueEmitter = .{
        .entries = &section_entries,
        .arena = arena,
    };

    // Walk every slot up to the highest referenced one — that covers
    // the consumer's full type-indexspace plus any out-of-bounds idxs
    // (hand-built fixtures whose imports cite a numeric slot not
    // backed by an actual contributor).
    const N: usize = blk: {
        var n: usize = consumer.type_indexspace.len;
        if (consumer.types.len > n) n = consumer.types.len;
        if (in_closure.count() > 0 and @as(usize, max_idx) + 1 > n) {
            n = @as(usize, max_idx) + 1;
        }
        break :blk n;
    };

    for (0..N) |k_usize| {
        const k: u32 = @intCast(k_usize);
        if (in_closure.contains(k)) {
            // Pick the contributor: real loaded components have a
            // populated `type_indexspace`; hand-built fixtures
            // synthesize a `.type_def(k)` mapping straight into
            // `consumer.types[]` (or fall back to an empty instance
            // type if even that's out of range).
            const contrib: ctypes.TypeContributor = if (k < consumer.type_indexspace.len)
                consumer.type_indexspace[k]
            else
                .{ .type_def = k };

            switch (contrib) {
                .type_def => |local| {
                    const td: ctypes.TypeDef = if (local < consumer.types.len)
                        consumer.types[local]
                    else
                        // Hand-built fixtures (e.g. tests with
                        // `types: &.{}`) declare imports referencing
                        // slots not materialised in `types[]`.
                        // Substitute an empty instance type — keeps
                        // the wrapper structurally valid; real
                        // compose inputs always supply the type.
                        .{ .instance = .{ .decls = &.{} } };
                    if (k < remap.len) remap[k] = @intCast(types_out.items.len + aliases_out.items.len);
                    try emitter.note(.type, @intCast(types_out.items.len));
                    try types_out.append(arena, try type_walk.cloneTypeDef(arena, td, remap, 0));
                },
                .alias => |alias_idx| {
                    if (alias_idx >= consumer.aliases.len) return error.UnsupportedComposeShape;
                    const orig = consumer.aliases[alias_idx];
                    const remapped = try remapAliasToWrapper(arena, orig, &inst_slot_for_unres_imp, consumer);
                    if (k < remap.len) remap[k] = @intCast(types_out.items.len + aliases_out.items.len);
                    try emitter.note(.alias, @intCast(aliases_out.items.len));
                    try aliases_out.append(arena, remapped);
                },
                .import => return error.UnsupportedComposeShape,
            }
        }

        // After the type slot, bubble up any unresolved instance
        // import whose desc references this exact slot. The wrapper
        // import's desc references the wrapper-side idx that the
        // closure slot just emitted — which `remap[k]` resolves to.
        if (imp_for_type_idx.get(k)) |imp_idx| {
            const orig_imp = consumer.imports[imp_idx];
            try emitter.note(.import, @intCast(imports_out.items.len));
            try imports_out.append(arena, .{
                .name = try arena.dupe(u8, orig_imp.name),
                .desc = try type_walk.cloneExternDesc(arena, orig_imp.desc, remap, 0),
            });
            try emitted_imp.put(arena, imp_idx, {});
        }
    }

    // Bubble up any remaining unresolved imports the interleaved walk
    // didn't already emit — non-instance descs (e.g. `.func`), or
    // `.instance` descs whose referenced slot is past `N` (shouldn't
    // happen in well-formed inputs, defensive).
    for (link.unresolved) |imp_idx| {
        if (emitted_imp.contains(imp_idx)) continue;
        const orig_imp = consumer.imports[imp_idx];
        try emitter.note(.import, @intCast(imports_out.items.len));
        try imports_out.append(arena, .{
            .name = try arena.dupe(u8, orig_imp.name),
            .desc = try type_walk.cloneExternDesc(arena, orig_imp.desc, remap, 0),
        });
    }

    try emitter.flush();

    return .{
        .types = types_out.items,
        .aliases = aliases_out.items,
        .imports = imports_out.items,
        .section_entries = section_entries.items,
        .type_remap = remap,
    };
}

/// Run-length-encodes a sequence of single-element section emissions
/// into `SectionEntry` chunks (adjacent same-kind emissions merge
/// into one entry, so the writer emits one physical section per
/// chunk rather than one per element).
const PrologueEmitter = struct {
    entries: *std.ArrayListUnmanaged(ctypes.SectionEntry),
    arena: std.mem.Allocator,
    cur_kind: ?ctypes.SectionKind = null,
    cur_start: u32 = 0,
    cur_count: u32 = 0,

    fn note(self: *PrologueEmitter, kind: ctypes.SectionKind, start: u32) !void {
        if (self.cur_kind) |k| {
            if (k == kind) {
                self.cur_count += 1;
                return;
            }
            try self.flush();
        }
        self.cur_kind = kind;
        self.cur_start = start;
        self.cur_count = 1;
    }

    fn flush(self: *PrologueEmitter) !void {
        if (self.cur_count > 0) {
            try self.entries.append(self.arena, .{
                .kind = self.cur_kind.?,
                .start = self.cur_start,
                .count = self.cur_count,
            });
        }
        self.cur_kind = null;
        self.cur_count = 0;
    }
};

/// Replicate a consumer alias decl at the wrapper level. Currently
/// only handles `.instance_export` aliases of sort `.type` whose
/// source instance is an unresolved consumer instance import —
/// those are the only shape wt-component output emits at the outer
/// level (resource bindings into the type indexspace). Anything
/// else fails closed with `error.UnsupportedComposeShape`.
fn remapAliasToWrapper(
    arena: std.mem.Allocator,
    orig: ctypes.Alias,
    inst_slot_for_unres_imp: *const std.AutoHashMapUnmanaged(u32, u32),
    consumer: *const ctypes.Component,
) !ctypes.Alias {
    return switch (orig) {
        .instance_export => |ie| blk: {
            if (ie.sort != .type) return error.UnsupportedComposeShape;
            // The alias references a consumer instance idx. Walk
            // comp_instance_indexspace to find the source — must be
            // an unresolved consumer instance import we've bubbled
            // up; anything else (resolved import / consumer-internal
            // instance / nested alias chain) isn't supported here.
            if (ie.instance_idx >= consumer.comp_instance_indexspace.len) return error.UnsupportedComposeShape;
            const contrib = consumer.comp_instance_indexspace[ie.instance_idx];
            const wrap_inst = switch (contrib) {
                .import => |imp_idx| inst_slot_for_unres_imp.get(imp_idx) orelse return error.UnsupportedComposeShape,
                .instance, .alias => return error.UnsupportedComposeShape,
            };
            break :blk .{ .instance_export = .{
                .sort = ie.sort,
                .instance_idx = wrap_inst,
                .name = try arena.dupe(u8, ie.name),
            } };
        },
        // Top-level outer aliases reach an enclosing scope above the
        // wrapper component — a shape wabt's compose doesn't model.
        .outer => return error.UnsupportedComposeShape,
    };
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

/// Re-export from the wrapper's outer indexspace. The consumer's
/// `desc` carries a type bound that references the consumer's type
/// indexspace (e.g. `(instance N)` where N is a consumer-side type
/// idx). The wrapper's type space holds only the BFS closure of types
/// reachable from unresolved **imports** — consumer export type
/// bounds are never materialised, so emitting `desc` verbatim
/// produces an out-of-bounds type reference at the wrapper's export
/// section (#132).
///
/// `wasm-tools compose` solves this by emitting the un-ascribed
/// (`ty: None`) form: the export's type is re-derived at validation
/// time from the alias target's sort+name. This matches.
///
/// `writer.descMatchesSort` returns true — and the writer takes the
/// 0x00 un-ascribed path — exactly when:
///   * sort=.instance / .func / .component AND desc is `.X(0)`, or
///   * sort=.type AND desc is `.type(.eq(slot_idx))`.
///
/// For sorts without an un-ascribed encoding (`.value`, `.core.*`,
/// `.module`) we keep the original desc — those paths don't trigger
/// #132 in any embed shape we produce.
fn unascribedReexportDesc(
    sort: ctypes.Sort,
    slot_idx: u32,
    original: ctypes.ExternDesc,
) ctypes.ExternDesc {
    return switch (sort) {
        .instance => .{ .instance = 0 },
        .func => .{ .func = 0 },
        .component => .{ .component = 0 },
        .type => .{ .type = .{ .eq = slot_idx } },
        .value, .core => original,
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
    // Bug 1 regression: the wrapper used to emit `import` (id 0x0a)
    // before any `type` (id 0x07) section, so the import's
    // `.instance(0)` desc referenced a type idx that didn't exist in
    // the wrapper. The fix copies the consumer's referenced type
    // into the wrapper's `types[]` and emits type-before-import.
    try testing.expect(loaded.types.len >= 1);
    try testing.expectEqual(ctypes.ExternDesc{ .instance = 0 }, loaded.imports[0].desc);
    // Direct byte-level check: section 0x07 must precede section
    // 0x0a in the encoded output.
    const ty_pos = std.mem.indexOfScalar(u8, composed[8..], 0x07) orelse
        return error.MissingTypeSection;
    const im_pos = std.mem.indexOfScalar(u8, composed[8..], 0x0a) orelse
        return error.MissingImportSection;
    try testing.expect(ty_pos < im_pos);
}

test "composeBinaries: bubbled import passes through to consumer instantiation" {
    // Regression for the related "consumer instantiated with unmet
    // imports left unsupplied" bug: the wrapper must pass each
    // bubbled-up import through as an `(arg)` to the consumer's
    // instantiation. Without this the inner consumer would fail to
    // resolve its imports at runtime even though the wrapping
    // component validates structurally.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:cli/stdout@0.2.6", .desc = .{ .instance = 0 } },
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

    // Wrapper has 1 instance section entry (the consumer
    // instantiation). The provider count is zero so there's no
    // separate provider-instantiation section.
    try testing.expectEqual(@as(usize, 1), loaded.instances.len);
    const inst = loaded.instances[0];
    try testing.expect(inst == .instantiate);
    try testing.expectEqual(@as(u32, 0), inst.instantiate.component_idx);
    // The consumer expected 1 instance arg ("wasi:cli/stdout@0.2.6"),
    // sourced from the wrapper's bubbled-up import (instance idx 0
    // in the wrapper's component-instance indexspace).
    try testing.expectEqual(@as(usize, 1), inst.instantiate.args.len);
    try testing.expectEqualStrings("wasi:cli/stdout@0.2.6", inst.instantiate.args[0].name);
    try testing.expect(inst.instantiate.args[0].sort_idx.sort == .instance);
    try testing.expectEqual(@as(u32, 0), inst.instantiate.args[0].sort_idx.idx);
}

test "composeBinaries: multi-package consumer + provider end-to-end" {
    // Mirrors the wamr `zig-calculator-cmd` topology: a consumer
    // component imports `docs:adder/add@0.1.0` from a sibling
    // package, and a provider component exports the same qualified
    // interface. Composing the two should fully bind the import
    // (zero leftover imports) — exactly the case Track #4 of the
    // multi-package PR is meant to enable.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const qname = "docs:adder/add@0.1.0";

    // Provider: one instance export under the qualified name.
    const prov_inst_exps = [_]ctypes.InlineExport{};
    const prov_instances = [_]ctypes.InstanceExpr{
        .{ .exports = &prov_inst_exps },
    };
    const prov_exports = [_]ctypes.ExportDecl{
        .{
            .name = qname,
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

    // Consumer: imports the same qualified name, no exports.
    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = qname, .desc = .{ .instance = 0 } },
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

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());

    // Cross-package import should be fully resolved by the provider.
    try testing.expectEqual(@as(usize, 0), loaded.imports.len);
    // Both components nested + bound through an alias.
    try testing.expectEqual(@as(usize, 2), loaded.components.len);
    try testing.expectEqual(@as(usize, 2), loaded.instances.len);
    try testing.expectEqual(@as(usize, 1), loaded.aliases.len);
}

test "composeBinaries: copies transitive type deps when bubbling up instance import" {
    // Consumer with two top-level types:
    //   types[0] = func(x: u32) -> u32         (the underlying "add")
    //   types[1] = instance {
    //                (alias outer 1 0)         ; pull func from outer
    //                (export "add" (func (type 0)))
    //              }
    // imports[0].desc = .instance(1)
    //
    // Pre-fix bug (#121): only types[1] would be copied into the
    // wrapper, leaving its body's outer-alias-1-0 pointing at a
    // wrapper-type-0 that didn't exist. Post-fix: BFS pulls in
    // types[0] too, topo-sort puts it first, and the body's outer
    // alias is remapped to the wrapper's renumbered idx.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const params = [_]ctypes.NamedValType{.{ .name = "x", .type = .u32 }};
    const func_type = ctypes.TypeDef{ .func = .{
        .params = &params,
        .results = .{ .unnamed = .u32 },
    } };

    const inst_decls = [_]ctypes.Decl{
        .{ .alias = .{ .outer = .{
            .sort = .type,
            .outer_count = 1,
            .idx = 0,
        } } },
        .{ .@"export" = .{
            .name = "add",
            .desc = .{ .func = 0 },
        } },
    };
    const inst_type = ctypes.TypeDef{ .instance = .{ .decls = &inst_decls } };

    const types = [_]ctypes.TypeDef{ func_type, inst_type };
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "ns:pkg/iface@0.1.0", .desc = .{ .instance = 1 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &imports, .exports = &.{},
    };
    const consumer_bytes = try writer.encode(ar, &consumer);

    const empty_providers: []const []u8 = &.{};
    const composed = try composeBinaries(testing.allocator, consumer_bytes, empty_providers);
    defer testing.allocator.free(composed);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());

    // Both types must be present in the wrapper (transitive closure).
    try testing.expect(loaded.types.len >= 2);

    // The bubbled-up import must reference an instance type slot
    // that exists in the wrapper.
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expect(loaded.imports[0].desc == .instance);
    const inst_idx = loaded.imports[0].desc.instance;
    try testing.expect(inst_idx < loaded.types.len);

    // The instance's body must contain an outer-alias whose `idx` is
    // strictly less than `inst_idx` — so the alias resolves to a
    // wrapper type already declared at that point (the spec's
    // forward-only-references rule).
    try testing.expect(loaded.types[inst_idx] == .instance);
    const body = loaded.types[inst_idx].instance.decls;
    var found_outer_alias = false;
    for (body) |d| {
        if (d != .alias) continue;
        if (d.alias != .outer) continue;
        if (d.alias.outer.sort != .type) continue;
        if (d.alias.outer.outer_count != 1) continue;
        try testing.expect(d.alias.outer.idx < inst_idx);
        found_outer_alias = true;
    }
    try testing.expect(found_outer_alias);
}

test "composeBinaries: emits closure types in encounter order with remap" {
    // Consumer declares the func dep FIRST (idx 0) and the instance
    // SECOND (idx 1) — well-formed forward-only encoding, identical
    // to what real component encoders produce. The wrapper must
    // preserve encounter order *and* remap the instance body's
    // outer-alias to the func's wrapper slot.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const params = [_]ctypes.NamedValType{.{ .name = "x", .type = .u32 }};
    const func_type = ctypes.TypeDef{ .func = .{
        .params = &params,
        .results = .{ .unnamed = .u32 },
    } };

    // Body refs outer-1-0 → consumer-typespace-0 (the func, declared
    // *before* the instance in source order — forward-only).
    const inst_decls = [_]ctypes.Decl{
        .{ .alias = .{ .outer = .{
            .sort = .type,
            .outer_count = 1,
            .idx = 0,
        } } },
        .{ .@"export" = .{
            .name = "add",
            .desc = .{ .func = 0 },
        } },
    };
    const inst_type = ctypes.TypeDef{ .instance = .{ .decls = &inst_decls } };

    // Func at idx 0, instance at idx 1 — forward-only dep order.
    const types = [_]ctypes.TypeDef{ func_type, inst_type };
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "ns:pkg/iface@0.1.0", .desc = .{ .instance = 1 } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &imports, .exports = &.{},
    };
    const consumer_bytes = try writer.encode(ar, &consumer);

    const empty_providers: []const []u8 = &.{};
    const composed = try composeBinaries(testing.allocator, consumer_bytes, empty_providers);
    defer testing.allocator.free(composed);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());

    try testing.expectEqual(@as(usize, 2), loaded.types.len);
    // Encounter order: func at wrapper-idx 0, instance at wrapper-idx 1.
    try testing.expect(loaded.types[0] == .func);
    try testing.expect(loaded.types[1] == .instance);

    // The bubbled-up import desc must follow the renumbering: the
    // instance lives at wrapper-idx 1.
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expect(loaded.imports[0].desc == .instance);
    try testing.expectEqual(@as(u32, 1), loaded.imports[0].desc.instance);

    // The instance body's outer alias must point at wrapper-idx 0
    // (the func), reflecting the remap (consumer-idx 0 → wrapper-idx 0
    // is identity here, but the cloner still has to walk it).
    const body = loaded.types[1].instance.decls;
    var found_alias = false;
    for (body) |d| {
        if (d != .alias) continue;
        if (d.alias != .outer) continue;
        if (d.alias.outer.sort != .type) continue;
        try testing.expectEqual(@as(u32, 1), d.alias.outer.outer_count);
        try testing.expectEqual(@as(u32, 0), d.alias.outer.idx);
        found_alias = true;
    }
    try testing.expect(found_alias);
}

test "composeBinaries: replicates alias-of-instance-export resource binding (#129)" {
    // Consumer shape that mirrors wt-component output for
    // `wasi:io/streams`: a resource declared inside an imported
    // instance type, then aliased into the consumer's outer type
    // indexspace, then referenced by a *later* instance-type body's
    // outer-alias decl. The wrapper's prologue must replicate the
    // alias decl rather than substituting an empty placeholder, or
    // the cloned body's `(alias outer 1 N)` will resolve to a
    // non-resource type and fail validation.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // type 0 = instance { export "error" (type (sub resource)) }
    const error_decls = [_]ctypes.Decl{
        .{ .@"export" = .{
            .name = "error",
            .desc = .{ .type = .sub_resource },
        } },
    };
    const error_inst_type = ctypes.TypeDef{ .instance = .{ .decls = &error_decls } };

    // type 2 = instance whose body refs outer 1 1 — that's the alias
    // slot we replicate (the resource pulled into the outer
    // typespace).
    const streams_decls = [_]ctypes.Decl{
        .{ .alias = .{ .outer = .{
            .sort = .type,
            .outer_count = 1,
            .idx = 1, // the alias-of-instance-export resource binding
        } } },
        .{ .@"export" = .{
            .name = "with-error",
            .desc = .{ .type = .{ .eq = 0 } }, // local idx 0 inside the instance body == the aliased resource
        } },
    };
    const streams_inst_type = ctypes.TypeDef{ .instance = .{ .decls = &streams_decls } };

    // Consumer: types[0] = error-instance-type; types[1] = streams-instance-type.
    // type_indexspace shape (binary-encoded order):
    //   0 → .type_def(0)  = error-instance-type
    //   1 → .alias(0)     = "alias export <error-import-instance> 'error' (type)"
    //   2 → .type_def(1)  = streams-instance-type
    // imports: 0 = wasi:io/error (instance (type 0)), 1 = wasi:io/streams (instance (type 2)).
    const types = [_]ctypes.TypeDef{ error_inst_type, streams_inst_type };
    const aliases = [_]ctypes.Alias{
        .{ .instance_export = .{
            .sort = .type,
            .instance_idx = 0, // wasi:io/error import (consumer comp_instance_indexspace[0])
            .name = "error",
        } },
    };
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.0", .desc = .{ .instance = 0 } },
        .{ .name = "wasi:io/streams@0.2.0", .desc = .{ .instance = 2 } },
    };
    const section_order = [_]ctypes.SectionEntry{
        .{ .kind = .type, .start = 0, .count = 1 }, // type 0 (error)
        .{ .kind = .import, .start = 0, .count = 1 }, // import error
        .{ .kind = .alias, .start = 0, .count = 1 }, // alias error → outer typespace
        .{ .kind = .type, .start = 1, .count = 1 }, // type 1 (streams)
        .{ .kind = .import, .start = 1, .count = 1 }, // import streams
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &.{}, .aliases = &aliases,
        .types = &types, .canons = &.{},
        .imports = &imports, .exports = &.{},
        .section_order = &section_order,
    };
    const consumer_bytes = try writer.encode(ar, &consumer);

    const empty_providers: []const []u8 = &.{};
    const composed = try composeBinaries(testing.allocator, consumer_bytes, empty_providers);
    defer testing.allocator.free(composed);

    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());

    // Wrapper must have replicated the alias as an outer-level alias
    // decl with sort `.type` and instance_idx pointing at the bubbled
    // import for wasi:io/error (wrapper-instance idx 0).
    var found_alias_decl = false;
    for (loaded.aliases) |a| {
        switch (a) {
            .instance_export => |ie| {
                if (ie.sort != .type) continue;
                if (!std.mem.eql(u8, ie.name, "error")) continue;
                try testing.expectEqual(@as(u32, 0), ie.instance_idx);
                found_alias_decl = true;
            },
            else => {},
        }
    }
    try testing.expect(found_alias_decl);

    // Wrapper must have bubbled up both unresolved imports.
    var found_error_imp = false;
    var found_streams_imp = false;
    for (loaded.imports) |imp| {
        if (std.mem.eql(u8, imp.name, "wasi:io/error@0.2.0")) found_error_imp = true;
        if (std.mem.eql(u8, imp.name, "wasi:io/streams@0.2.0")) found_streams_imp = true;
    }
    try testing.expect(found_error_imp);
    try testing.expect(found_streams_imp);
}

test "composeBinaries: re-export desc is un-ascribed (#132)" {
    // Regression for #132: the wrapper used to copy each consumer
    // export's `desc` verbatim into the wrapper's export decl. The
    // desc carries a type bound (e.g. `(instance N)`) referencing
    // the consumer's type indexspace — but the wrapper only
    // materialises types reachable from unresolved **imports**, so
    // the desc's idx dangled past the wrapper's type space. Validators
    // rejected the result with "unknown type N: type index out of
    // bounds" at the export section.
    //
    // Fix: substitute a sort-matched un-ascribed desc placeholder so
    // the writer's `descMatchesSort` returns true and emits the 0x00
    // form (`ty: None` in `wasm-tools dump`).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Consumer: no imports, one instance export whose desc references
    // a high consumer-side type idx (99) — far past the wrapper's
    // (empty) type space. The export's sort_idx is the consumer's
    // own instance idx (synthesized by the writer's loader).
    const cons_instances = [_]ctypes.InstanceExpr{.{ .exports = &.{} }};
    const cons_exports = [_]ctypes.ExportDecl{
        .{
            .name = "wasi:cli/run@0.2.6",
            .desc = .{ .instance = 99 },
            .sort_idx = .{ .sort = .instance, .idx = 0 },
        },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{}, .core_types = &.{},
        .components = &.{}, .instances = &cons_instances, .aliases = &.{},
        .types = &.{}, .canons = &.{}, .imports = &.{}, .exports = &cons_exports,
    };
    const consumer_bytes = try writer.encode(ar, &consumer);

    const empty_providers: []const []u8 = &.{};
    const composed = try composeBinaries(testing.allocator, consumer_bytes, empty_providers);
    defer testing.allocator.free(composed);

    // Round-trips through our own loader.
    var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena2.deinit();
    const loaded = try loader.load(composed, arena2.allocator());
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings("wasi:cli/run@0.2.6", loaded.exports[0].name);
    try testing.expect(loaded.exports[0].desc == .instance);
    // Un-ascribed form (0x00 after sort_idx) is the only path through
    // the loader that yields `desc.instance == 0` here — the consumer
    // had stamped the original desc with idx 99, so any round-trip
    // through the explicit (0x01) form would surface that 99 in the
    // loaded desc. Seeing 0 proves the writer took the 0x00 path,
    // which is exactly what wasm-tools-compose does (`ty: None`).
    try testing.expectEqual(@as(u32, 0), loaded.exports[0].desc.instance);
}
