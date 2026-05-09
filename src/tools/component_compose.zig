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

    // ── Wrapper types: copy each unresolved import's referenced type
    //    (and its transitive deps) from the consumer into our local
    //    types[] so the bubbled-up imports + every nested outer-alias
    //    inside their bodies still resolves to a wrapper-local idx.
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
    //    Fix: BFS the transitive consumer-typespace-idx closure from
    //    each unresolved import's desc, topologically sort it so each
    //    emitted type's body only references strictly smaller
    //    wrapper indices, then deep-clone every TypeDef through a
    //    consumer→wrapper remap so all depth-0 operands (including
    //    body-level outer aliases inside instance types) hit the
    //    wrapper's renumbered indexspace. ──
    const wrapper_types = try buildWrapperTypes(ar, &consumer, link.unresolved);
    const types_list_items = wrapper_types.types;
    const type_remap_table = wrapper_types.remap;

    // ── Wrapper imports: rewrite each bubbled-up desc to point at
    //    wrapper-local type idxs via the same remap table. Names are
    //    preserved so downstream callers see the same import set the
    //    consumer had. ──
    const imports_arr = try ar.alloc(ctypes.ImportDecl, num_unresolved);
    for (link.unresolved, 0..) |u_idx, i| {
        const imp = consumer.imports[u_idx];
        imports_arr[i] = .{
            .name = imp.name,
            .desc = try type_walk.cloneExternDesc(ar, imp.desc, type_remap_table, 0),
        };
    }

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

    // ── Aliases. Two alias sections: bindings (resolve providers)
    //    then export-aliases (re-export consumer outputs). ──
    var aliases_list = std.ArrayListUnmanaged(ctypes.Alias).empty;
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
            .desc = exp.desc,
            .sort_idx = .{ .sort = sort_idx_in.sort, .idx = slot_idx },
        });
    }

    // ── Section emission order:
    //     type, import, component×(N+1),
    //     instance #1 (providers), alias #1 (bindings),
    //     instance #2 (consumer), alias #2 (export aliases),
    //     export.
    //   The component-instance indexspace fills forward-only — each
    //   section only references slots produced by earlier sections. ──
    var section_order = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    if (types_list_items.len > 0) try section_order.append(ar, .{
        .kind = .type,
        .start = 0,
        .count = @intCast(types_list_items.len),
    });
    if (imports_arr.len > 0) try section_order.append(ar, .{
        .kind = .import,
        .start = 0,
        .count = @intCast(imports_arr.len),
    });
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
        .start = 0,
        .count = num_bindings,
    });
    try section_order.append(ar, .{
        .kind = .instance,
        .start = num_providers,
        .count = 1,
    });
    if (consumer.exports.len > 0) try section_order.append(ar, .{
        .kind = .alias,
        .start = num_bindings,
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
/// (in which case the caller can substitute an empty instance type as
/// a structurally-valid placeholder).
fn lookupConsumerType(c: *const ctypes.Component, type_idx: u32) ?ctypes.TypeDef {
    if (c.type_indexspace.len > 0) {
        if (type_idx >= c.type_indexspace.len) return null;
        const local = c.type_indexspace[type_idx] orelse return null;
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

/// Result of building the wrapping component's `types[]` section
/// from the unresolved imports' transitive type-dependency closure.
const WrapperTypes = struct {
    /// Topologically-ordered TypeDefs ready to assign to
    /// `Component.types`. Each TypeDef's body has been deep-cloned
    /// with all depth-0 operands renumbered through `remap`.
    types: []const ctypes.TypeDef,
    /// Mapping `consumer.type_indexspace[X]` → wrapper-types[]-idx.
    /// Slots not in the closure remain `SENTINEL` (max u32). The
    /// table is sized to fit any legal idx the cloner might encounter
    /// (max of consumer.type_indexspace.len and consumer.types.len).
    remap: []const u32,
};

const SENTINEL_TYPE_IDX: u32 = std.math.maxInt(u32);

/// Build the wrapping component's `types[]` from the closure of
/// consumer-typespace idxs reachable from `unresolved`'s imports.
///
/// Algorithm:
///
///   1. **Seed.** For every unresolved import, collect every type-idx
///      operand its `ExternDesc` carries (via `type_walk`).
///   2. **BFS expand.** For each idx in the queue, resolve to its
///      consumer TypeDef (`lookupConsumerType`), walk it at depth 0
///      to gather every type-idx the body references at depth 0,
///      enqueue any new ones.
///   3. **Topo sort.** DFS post-order over the closure: emit a node
///      after all its in-closure deps are emitted. Cycles cannot
///      occur in well-formed components but we detect and bail with
///      a stable order if one slips through (tolerant — the
///      validator will catch it downstream anyway).
///   4. **Clone + remap.** For each closure idx in topo order, build
///      the consumer→wrapper remap entry, then clone its TypeDef
///      via `type_walk.cloneTypeDef(td, remap, depth=0)`. Slots
///      whose `lookupConsumerType` returns null fall back to an
///      empty instance type — same behaviour the pre-fix code had,
///      kept so hand-built fixtures with `types: &.{}` still round-
///      trip.
fn buildWrapperTypes(
    arena: std.mem.Allocator,
    consumer: *const ctypes.Component,
    unresolved: []const u32,
) !WrapperTypes {
    // ── Step 1+2: BFS the closure of consumer-typespace idxs ───────
    var queue = std.ArrayListUnmanaged(u32).empty;
    var in_closure = std.AutoHashMapUnmanaged(u32, void).empty;
    var max_idx: u32 = 0;

    for (unresolved) |u_idx| {
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

    // ── Step 3: DFS post-order topo sort ──────────────────────────
    const order = try arena.alloc(u32, queue.items.len);
    var order_len: usize = 0;
    var visiting = std.AutoHashMapUnmanaged(u32, void).empty;
    var visited = std.AutoHashMapUnmanaged(u32, void).empty;

    for (queue.items) |seed| {
        try topoVisit(arena, consumer, seed, &visiting, &visited, order, &order_len);
    }

    // ── Step 4: clone + remap in topo order ───────────────────────
    const types = try arena.alloc(ctypes.TypeDef, order_len);
    // First pass: assign wrapper-idxs so refs from later types
    // resolve. (DFS post-order already guarantees deps come first,
    // so we can also fill remap in a single pass — done up-front
    // here for symmetry with the cycle-tolerance bail-out path.)
    for (order[0..order_len], 0..) |consumer_idx, wrapper_idx| {
        if (consumer_idx < remap.len) remap[consumer_idx] = @intCast(wrapper_idx);
    }
    // Second pass: clone bodies through the now-complete remap.
    for (order[0..order_len], 0..) |consumer_idx, wrapper_idx| {
        const td = lookupConsumerType(consumer, consumer_idx) orelse blk: {
            // Hand-built fixtures (e.g. tests with `types: &.{}`)
            // declare imports referencing slots not materialised in
            // `types[]`. Substitute an empty instance type — keeps
            // the wrapper structurally valid; real compose inputs
            // always supply the type.
            break :blk ctypes.TypeDef{ .instance = .{ .decls = &.{} } };
        };
        types[wrapper_idx] = try type_walk.cloneTypeDef(arena, td, remap, 0);
    }

    return .{ .types = types, .remap = remap };
}

/// DFS post-order visit. Skips already-visited nodes and tolerates
/// cycles by bailing on back-edges (the cyclic node is dropped from
/// the order; downstream validators will catch any resulting
/// invalidity).
fn topoVisit(
    arena: std.mem.Allocator,
    consumer: *const ctypes.Component,
    node: u32,
    visiting: *std.AutoHashMapUnmanaged(u32, void),
    visited: *std.AutoHashMapUnmanaged(u32, void),
    order: []u32,
    order_len: *usize,
) !void {
    if (visited.contains(node)) return;
    if (visiting.contains(node)) return; // back-edge — break the cycle
    try visiting.put(arena, node, {});

    if (lookupConsumerType(consumer, node)) |td| {
        var refs = std.ArrayListUnmanaged(u32).empty;
        try type_walk.collectTypeDefRefs(arena, td, &refs, 0);
        for (refs.items) |r| {
            try topoVisit(arena, consumer, r, visiting, visited, order, order_len);
        }
    }

    _ = visiting.remove(node);
    try visited.put(arena, node, {});
    order[order_len.*] = node;
    order_len.* += 1;
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

test "composeBinaries: emits types in topological order" {
    // Same shape as the previous test but consumer declares the
    // instance type FIRST (idx 0) and the func dep SECOND (idx 1).
    // The wrapper must topologically reorder them so each emitted
    // type's body only references strictly smaller wrapper indices.
    // The bubbled-up import's desc must follow the renumbering.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const params = [_]ctypes.NamedValType{.{ .name = "x", .type = .u32 }};
    const func_type = ctypes.TypeDef{ .func = .{
        .params = &params,
        .results = .{ .unnamed = .u32 },
    } };

    // Body refs outer-1-1 → consumer-typespace-1 (the func, declared
    // *after* the instance in source order).
    const inst_decls = [_]ctypes.Decl{
        .{ .alias = .{ .outer = .{
            .sort = .type,
            .outer_count = 1,
            .idx = 1,
        } } },
        .{ .@"export" = .{
            .name = "add",
            .desc = .{ .func = 0 },
        } },
    };
    const inst_type = ctypes.TypeDef{ .instance = .{ .decls = &inst_decls } };

    // Instance at idx 0, func at idx 1 — reverse of dep order.
    const types = [_]ctypes.TypeDef{ inst_type, func_type };
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "ns:pkg/iface@0.1.0", .desc = .{ .instance = 0 } },
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
    // Topo sort must hoist the func dep ahead of the instance so the
    // instance's outer alias resolves to a strictly smaller idx.
    try testing.expect(loaded.types[0] == .func);
    try testing.expect(loaded.types[1] == .instance);

    // The bubbled-up import desc must follow the renumbering: the
    // instance now lives at wrapper-idx 1, not consumer-idx 0.
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expect(loaded.imports[0].desc == .instance);
    try testing.expectEqual(@as(u32, 1), loaded.imports[0].desc.instance);

    // The instance body's outer alias must point at wrapper-idx 0
    // (the func), reflecting the renumber.
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
