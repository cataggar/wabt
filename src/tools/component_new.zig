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
//! 1. **Plain wrap** (no `--adapt` and no preview1 imports): for each
//!    export interface in the world, build a core-instance alias for
//!    the matching `<iface>#<func>` export, a component-level func
//!    type matching the interface's signature, a `(canon lift)`, an
//!    instance bundling the lifted funcs, and a top-level export
//!    under the qualified interface name. Suitable for plain
//!    reactor-style cores like the wamr `zig-adder` fixture.
//!
//! 2. **Adapter splice** (`--adapt wasi_snapshot_preview1=<a.wasm>`):
//!    delegate to `wabt.component.adapter.adapter.splice`, which
//!    composes the embed core with the given preview1→component
//!    adapter into a four- or five-core-module component (shim,
//!    embed, adapter, fixup, optional `__main_module__` fallback).
//!
//!    The wabt CLI also bakes in its own wasi-preview1 → preview2
//!    adapter. If the core module declares any
//!    `wasi_snapshot_preview1.*` import and the user did NOT pass a
//!    matching `--adapt wasi_snapshot_preview1=<file>`, the splice
//!    path is used automatically with the built-in adapter bytes.
//!    Pass `--no-builtin-adapter` to disable this auto-attach.
//!
//!    Two adapter shapes are supported transparently — `splice`
//!    classifies via `detectShape`:
//!      * **command** (the wamr `zig-hello` / `zig-calculator-cmd`
//!        / `mixed-zig-rust-calc` fixtures): the adapter declares
//!        `wasi:cli/run@…` and the wrapping component lifts a
//!        single `wasi:cli/run` top-level export.
//!      * **reactor**: the adapter has no `<iface>#name` exports
//!        and no `__main_module__` imports; the wrapping component
//!        emits one top-level export per `<iface>#<func>` export
//!        the embed declares.
//!
//!    Multi-adapter splicing (`--adapt` repeated): the **primary**
//!    is the unique adapter with at least one non-`env` core
//!    import. Remaining adapters are treated as bare host-shim
//!    secondaries (every import must be `env.<x>`).
//!
//!    Mirrors `wasm-tools component new --adapt …`.

const std = @import("std");
const wabt = @import("wabt");
const builtin_adapter = @import("builtin_adapter");

const ctypes = wabt.component.types;
const writer = wabt.component.writer;
const metadata_decode = wabt.component.wit.metadata_decode;
const core_imports = wabt.component.adapter.core_imports;

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
    \\      --adapt <n>=<file>  Splice in an adapter (may repeat). The
    \\                          primary is the unique adapter with at
    \\                          least one non-`env` core import; the
    \\                          remaining adapters must import only
    \\                          `env.<x>` (bare host-shim restriction).
    \\                          Both command-shape (lifts wasi:cli/run)
    \\                          and reactor-shape (lifts each
    \\                          <iface>#<func>) primaries are supported
    \\                          and detected automatically.
    \\      --no-builtin-adapter
    \\                          Disable the auto-attached built-in
    \\                          wasi-preview1 → preview2 adapter. By
    \\                          default, if the input core imports any
    \\                          `wasi_snapshot_preview1.*` symbol and
    \\                          no `--adapt wasi_snapshot_preview1=...`
    \\                          was supplied, the CLI's embedded
    \\                          adapter is spliced in transparently.
    \\
;

const AdapterSpec = struct { name: []const u8, file: []const u8 };

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var output_file: ?[]const u8 = null;
    var skip_validation: bool = false;
    var no_builtin_adapter: bool = false;
    var input_path: ?[]const u8 = null;
    var adapts = std.ArrayListUnmanaged(AdapterSpec).empty;
    defer adapts.deinit(alloc);

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
        } else if (std.mem.eql(u8, arg, "--skip-validation")) {
            skip_validation = true;
        } else if (std.mem.eql(u8, arg, "--no-builtin-adapter")) {
            no_builtin_adapter = true;
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
            try adapts.append(alloc, .{ .name = spec[0..eq], .file = spec[eq + 1 ..] });
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'. Use `wabt component new help`.\n", .{arg});
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
        std.debug.print("error: component new requires <input.wasm>. Use `wabt component new help`.\n", .{});
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

    // Auto-attach the built-in wasi-preview1 → preview2 adapter when
    // the core imports preview1 and the user didn't already supply
    // one. Treated as a synthetic `--adapt wasi_snapshot_preview1=...`
    // prepended to the user's list so the existing splice path runs
    // unchanged.
    const auto_attach_builtin = !no_builtin_adapter and
        !userSuppliedAdapter(adapts.items, "wasi_snapshot_preview1") and
        coreImportsModule(alloc, core_bytes, "wasi_snapshot_preview1");

    const out_bytes = blk: {
        if (adapts.items.len > 0 or auto_attach_builtin) {
            const Adapter = wabt.component.adapter.adapter.Adapter;
            const total = adapts.items.len + @intFromBool(auto_attach_builtin);
            const adapter_list = alloc.alloc(Adapter, total) catch unreachable;
            defer {
                for (adapter_list) |ad| alloc.free(ad.bytes);
                alloc.free(adapter_list);
            }
            var slot: usize = 0;
            if (auto_attach_builtin) {
                // Pick command-shape vs reactor-shape based on whether
                // the embed core exports `_start`. Matches
                // wit-component's auto-detection (cataggar/wabt#167).
                // Dupe so the existing free-loop in `defer` can
                // uniformly release every adapter's bytes.
                const builtin_bytes = pickBuiltinAdapter(alloc, core_bytes);
                adapter_list[slot] = .{
                    .name = "wasi_snapshot_preview1",
                    .bytes = alloc.dupe(u8, builtin_bytes) catch unreachable,
                };
                slot += 1;
            }
            for (adapts.items) |spec| {
                const adp_bytes = std.Io.Dir.cwd().readFileAlloc(
                    init.io,
                    spec.file,
                    alloc,
                    std.Io.Limit.limited(wabt.max_input_file_size),
                ) catch |err| {
                    std.debug.print("error: cannot read adapter '{s}': {any}\n", .{ spec.file, err });
                    std.process.exit(1);
                };
                adapter_list[slot] = .{ .name = spec.name, .bytes = adp_bytes };
                slot += 1;
            }
            break :blk wabt.component.adapter.adapter.spliceMany(alloc, core_bytes, adapter_list) catch |err| {
                std.debug.print("error: splicing adapters: {s}\n", .{@errorName(err)});
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

fn userSuppliedAdapter(adapts: []const AdapterSpec, needle: []const u8) bool {
    for (adapts) |spec| {
        if (std.mem.eql(u8, spec.name, needle)) return true;
    }
    return false;
}

/// Returns true iff `core_bytes` is a core wasm module declaring at
/// least one import whose module name equals `module_name`. Returns
/// false on parse failure so a malformed input still falls through to
/// the existing splice / buildComponent error path with a clearer
/// message.
fn coreImportsModule(
    alloc: std.mem.Allocator,
    core_bytes: []const u8,
    module_name: []const u8,
) bool {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const owned = core_imports.extract(arena.allocator(), core_bytes) catch return false;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, module_name)) return true;
    }
    return false;
}

/// Result of inspecting the embed core for `_start`. `parse_error`
/// is preserved separately so `pickBuiltinAdapter` can fall back to
/// the command adapter for malformed cores (matching pre-#167
/// behavior), while a cleanly-parsing core that simply omits
/// `_start` selects the reactor adapter.
const StartExportProbe = enum { yes, no, parse_error };

fn probeStartExport(alloc: std.mem.Allocator, core_bytes: []const u8) StartExportProbe {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const owned = core_imports.extract(arena.allocator(), core_bytes) catch return .parse_error;
    const ex = owned.interface.findExport("_start") orelse return .no;
    return if (ex.kind == .func) .yes else .no;
}

/// Pick the bundled wasi-preview1 → preview2 adapter shape for an
/// auto-attach. Mirrors wit-component's heuristic: an embed that
/// exports `_start` is a command-shape program (the adapter's `$run`
/// calls back into `_start`); a cleanly-parsing embed without
/// `_start` is treated as reactor-shape, where the wrapping
/// component lifts the embed's own exports directly. A malformed
/// core falls back to the command adapter so the downstream splice
/// produces the same error message it did pre-#167. Tracked under
/// cataggar/wabt#167.
fn pickBuiltinAdapter(alloc: std.mem.Allocator, core_bytes: []const u8) []const u8 {
    return switch (probeStartExport(alloc, core_bytes)) {
        .yes, .parse_error => builtin_adapter.wasi_preview1_command_wasm,
        .no => builtin_adapter.wasi_preview1_reactor_wasm,
    };
}

/// Conservative predicate: does this imported func's sig fit the
/// #202-scope shape (all `own`/`borrow` slots resolve to a resource
/// bound LOCAL to the same import's instance-type body; no compound
/// types, no value-type refs requiring cross-iface alias plumbing)?
///
/// Funcs that don't pass this check are silently skipped from the
/// import-wiring pass — the wrapping component is still valid (the
/// core wasm's matching import is left dangling, same as before #202),
/// but those calls will fall through to wamr's no-op stub. Lifting
/// the restriction is tracked under #203 along with the memory +
/// cabi_realloc opts that string/list lowering needs anyway.
fn sigFitsImportBody(
    sig: ctypes.FuncType,
    ext_slots: []const metadata_decode.TypeSlot,
    local_resource_idx: *std.StringHashMapUnmanaged(u32),
) bool {
    const checkVT = struct {
        fn run(
            v: ctypes.ValType,
            slots: []const metadata_decode.TypeSlot,
            local: *std.StringHashMapUnmanaged(u32),
        ) bool {
            return switch (v) {
                .own, .borrow => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(slots, k) orelse
                        break :blk false;
                    break :blk local.contains(name);
                },
                // Compound types and outer-scope type_idx refs would
                // require `alias outer` plumbing inside the body.
                .type_idx => false,
                else => true,
            };
        }
    }.run;

    for (sig.params) |p| if (!checkVT(p.type, ext_slots, local_resource_idx)) return false;
    switch (sig.results) {
        .none => {},
        .unnamed => |v| if (!checkVT(v, ext_slots, local_resource_idx)) return false,
        .named => |named| for (named) |nv| {
            if (!checkVT(nv.type, ext_slots, local_resource_idx)) return false;
        },
    }
    return true;
}

/// Rewrite a `FuncType`'s value-type tree so `own`/`borrow` references
/// in its `.ext_slots` form land on the body-local type-index slot
/// where the named resource was bound via a `sub_resource` export
/// declarator. Used to construct the func-type declarators that live
/// inside an instance-type body for an imported interface — the
/// surrounding body's local type-index space is the only scope those
/// handle refs can validly target.
///
/// Callers must gate with `sigFitsImportBody` before invoking; this
/// helper returns `error.UnresolvedResource` for any slot that doesn't
/// reduce to a locally-bound resource.
fn rewriteSigForInstanceBody(
    ar: std.mem.Allocator,
    sig: ctypes.FuncType,
    ext_slots: []const metadata_decode.TypeSlot,
    local_resource_idx: *std.StringHashMapUnmanaged(u32),
) !ctypes.FuncType {
    const rewriteVT = struct {
        fn run(
            v: ctypes.ValType,
            slots: []const metadata_decode.TypeSlot,
            local: *std.StringHashMapUnmanaged(u32),
        ) !ctypes.ValType {
            return switch (v) {
                .own => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(slots, k) orelse
                        return error.UnresolvedResource;
                    const idx = local.get(name) orelse return error.UnresolvedResource;
                    break :blk .{ .own = idx };
                },
                .borrow => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(slots, k) orelse
                        return error.UnresolvedResource;
                    const idx = local.get(name) orelse return error.UnresolvedResource;
                    break :blk .{ .borrow = idx };
                },
                else => v,
            };
        }
    }.run;

    const params = try ar.alloc(ctypes.NamedValType, sig.params.len);
    for (sig.params, 0..) |p, i| {
        params[i] = .{
            .name = p.name,
            .type = try rewriteVT(p.type, ext_slots, local_resource_idx),
        };
    }
    const results: ctypes.FuncType.ResultList = switch (sig.results) {
        .none => .none,
        .unnamed => |v| .{ .unnamed = try rewriteVT(v, ext_slots, local_resource_idx) },
        .named => |named| n: {
            const dst = try ar.alloc(ctypes.NamedValType, named.len);
            for (named, 0..) |nv, i| {
                dst[i] = .{
                    .name = nv.name,
                    .type = try rewriteVT(nv.type, ext_slots, local_resource_idx),
                };
            }
            break :n .{ .named = dst };
        },
    };
    return .{ .params = params, .results = results };
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

    // ── Phase 1: collect resource-providing and func-bearing imports.
    //
    // For each `is_export=false` extern, record the
    // (qualified_name -> [resource names], [funcs], ext_slots) shape so
    // we can emit an instance-type import that lets the exported funcs
    // reach those resources by name AND can lower the imported funcs
    // back into the core wasm. Cross-extern resource names must be
    // unique within a world; ambiguity is a user-facing error (#198
    // scope is the wasi-http reproducer pattern, which uses unique
    // names — wider scoping is a follow-up). Imports with neither
    // resources nor funcs are skipped (no surface to wire).
    var resource_owner = std.StringHashMapUnmanaged([]const u8).empty;
    const ImportShape = struct {
        qualified_name: []const u8,
        resources: []const []const u8,
        funcs: []const metadata_decode.FuncRef,
        ext_slots: []const metadata_decode.TypeSlot,
        inst_decls: []const ctypes.Decl,
    };
    var import_shapes = std.ArrayListUnmanaged(ImportShape).empty;
    for (decoded.externs) |ext| {
        if (ext.is_export) continue;
        var rs = std.ArrayListUnmanaged([]const u8).empty;
        for (ext.type_slots) |slot| switch (slot) {
            .sub_resource => |name| try rs.append(ar, name),
            else => {},
        };
        if (rs.items.len == 0 and ext.funcs.len == 0) continue;
        const owned = try rs.toOwnedSlice(ar);
        try import_shapes.append(ar, .{
            .qualified_name = ext.qualified_name,
            .resources = owned,
            .funcs = ext.funcs,
            .ext_slots = ext.type_slots,
            .inst_decls = ext.inst_decls,
        });
        for (owned) |name| {
            const gop = try resource_owner.getOrPut(ar, name);
            if (gop.found_existing) return error.AmbiguousResourceName;
            gop.value_ptr.* = ext.qualified_name;
        }
    }

    // ── Phase 1.5: classify every imported func to decide whether
    //    canon.lower needs the `(memory <main>) + (realloc <cabi>)`
    //    options bundle. Funcs whose sigs reach `string`/`list` (or
    //    multi-result indirect lowering) need the opts; everything
    //    else (handle-only, primitives, enum) lowers cleanly with
    //    `.opts = &.{}` via the #202 fast path.
    //
    // Computing this upfront lets us avoid the shim/fixup
    // machinery entirely when no func needs it — keeping the #202
    // reproducer's wire output bit-identical, and avoiding the
    // forward-reference cycle on `(memory main_inst …)` aliases
    // that the shim/fixup pattern exists to break.
    var any_func_needs_opts = false;
    for (import_shapes.items) |shape| {
        const resolver = wabt.component.adapter.abi.TypeResolver{
            .inst_decls = shape.inst_decls,
            .world_decls = &.{},
        };
        for (shape.funcs) |fn_ref| {
            const ftr = wabt.component.adapter.abi.FuncTypeRef{
                .func = fn_ref.sig,
                .resolver = resolver,
            };
            const cls = wabt.component.adapter.abi.classifyFunc(ftr);
            if (cls.opts.memory or cls.opts.realloc or cls.opts.string_encoding) {
                any_func_needs_opts = true;
                break;
            }
        }
        if (any_func_needs_opts) break;
    }

    if (any_func_needs_opts) {
        return try buildComponentShimFixup(alloc, ar, decoded, stripped_core);
    }

    // ── Build component AST.
    var core_modules = try ar.alloc(ctypes.CoreModule, 1);
    core_modules[0] = .{ .data = stripped_core };

    // Core instances list: each `is_export=false` import that has funcs
    // contributes one inline-exports bundle (built in Phase 2.5 below);
    // the main core-module instantiation is appended last. The main
    // instance's index is therefore `K = bundles.len`, where K is
    // computed once Phase 2.5 has run.
    var core_instances = std.ArrayListUnmanaged(ctypes.CoreInstanceExpr).empty;

    var aliases = std.ArrayListUnmanaged(ctypes.Alias).empty;
    var types = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    var canons = std.ArrayListUnmanaged(ctypes.Canon).empty;
    var instances = std.ArrayListUnmanaged(ctypes.InstanceExpr).empty;
    var exports = std.ArrayListUnmanaged(ctypes.ExportDecl).empty;
    var imports = std.ArrayListUnmanaged(ctypes.ImportDecl).empty;

    // Component-level type-index counter. Bumped whenever a type or
    // type-sort alias is emitted; consulted to know the wire index
    // any newly-allocated slot will receive.
    var comp_type_idx: u32 = 0;
    // Section emission order — appended to as items are inserted so
    // the on-wire layout exactly matches insertion order. Avoids
    // section_order batching surprises (resource aliases must be
    // adjacent to the hoisted typedefs that reference them).
    var order = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    const Section = struct {
        fn appendType(o: *std.ArrayListUnmanaged(ctypes.SectionEntry), ar2: std.mem.Allocator, types_len: usize) !void {
            try o.append(ar2, .{ .kind = .type, .start = @intCast(types_len - 1), .count = 1 });
        }
        fn appendAlias(o: *std.ArrayListUnmanaged(ctypes.SectionEntry), ar2: std.mem.Allocator, aliases_len: usize) !void {
            try o.append(ar2, .{ .kind = .alias, .start = @intCast(aliases_len - 1), .count = 1 });
        }
    };

    // ── Phase 2: emit instance-type + import for each
    //    resource-providing or func-bearing import. Records the
    //    component-instance index allocated to the import for later
    //    aliasing, and remembers exactly which funcs got wired in so
    //    Phase 2.5 lowers the same subset.
    //
    // The instance-type body lists, in order:
    //   1. an `.@"export" sub_resource` decl per imported resource
    //      (bumps the body-local type-index space by 1 each);
    //   2. a `.type func` decl per imported func that fits the
    //      conservative import-body shape (handles + primitives only),
    //      with the func's sig rewritten so `own`/`borrow` slots
    //      resolve against the body-local sub_resource slots (bumps
    //      the body-local type-index space by 1 each);
    //   3. an `.@"export" func` decl per such imported func, naming
    //      the func and pointing at its body-local type-index.
    //
    // Funcs that don't fit (cross-iface handle refs, compound types,
    // anything needing string/list lowering) are silently skipped.
    // The core wasm's matching import is left dangling for now,
    // exactly as before #202; #203 picks up the rest.
    var import_inst_idx_for = std.StringHashMapUnmanaged(u32).empty;
    var wired_funcs_by_shape = try ar.alloc(
        []const metadata_decode.FuncRef,
        import_shapes.items.len,
    );
    for (import_shapes.items, 0..) |shape, i| {
        // resource_name → body-local type-index (where the
        // sub_resource export binds it). Built as we emit them.
        var local_resource_idx = std.StringHashMapUnmanaged(u32).empty;

        var inst_decls = std.ArrayListUnmanaged(ctypes.Decl).empty;
        var local_type_idx: u32 = 0;
        for (shape.resources) |name| {
            try inst_decls.append(ar, .{ .@"export" = .{
                .name = name,
                .desc = .{ .type = .sub_resource },
            } });
            try local_resource_idx.put(ar, name, local_type_idx);
            local_type_idx += 1;
        }
        var wired = std.ArrayListUnmanaged(metadata_decode.FuncRef).empty;
        for (shape.funcs) |fn_ref| {
            if (!sigFitsImportBody(fn_ref.sig, shape.ext_slots, &local_resource_idx)) continue;
            const rewritten = try rewriteSigForInstanceBody(
                ar,
                fn_ref.sig,
                shape.ext_slots,
                &local_resource_idx,
            );
            try inst_decls.append(ar, .{ .type = .{ .func = rewritten } });
            const ft_local_idx = local_type_idx;
            local_type_idx += 1;
            try inst_decls.append(ar, .{ .@"export" = .{
                .name = fn_ref.name,
                .desc = .{ .func = ft_local_idx },
            } });
            try wired.append(ar, fn_ref);
        }
        wired_funcs_by_shape[i] = try wired.toOwnedSlice(ar);

        try types.append(ar, .{ .instance = .{ .decls = try inst_decls.toOwnedSlice(ar) } });
        try Section.appendType(&order, ar, types.items.len);
        const inst_type_idx = comp_type_idx;
        comp_type_idx += 1;
        try imports.append(ar, .{
            .name = shape.qualified_name,
            .desc = .{ .instance = inst_type_idx },
        });
        try order.append(ar, .{ .kind = .import, .start = @intCast(imports.items.len - 1), .count = 1 });
        try import_inst_idx_for.put(ar, shape.qualified_name, @intCast(i));
    }
    const import_inst_count: u32 = @intCast(imports.items.len);

    // ── Phase 2.5: wire each imported func through to the core wasm.
    //
    // Per imported func, emit (in this order):
    //   * `alias instance_export sort=.func` from the import instance,
    //     producing a component-level func indexspace slot;
    //   * `canon lower` of that component func into a core func.
    //
    // Then, per import that contributed funcs, emit a
    // `core_instance.exports` inline-exports bundle keyed by the func's
    // canonical method-encoded name (e.g. `[constructor]fields`). The
    // bundle's core-instance index is later referenced by the main
    // core-module instantiation's `(with …)` args, completing the
    // wire-up.
    //
    // `canon.lower.opts` is intentionally empty for now; wiring
    // memory + cabi_realloc opts is tracked under #203 (it requires
    // the wasm-tools shim/fixup trampoline pattern to break the
    // forward-reference cycle between the lowers and the main core
    // instance's exports).
    var comp_func_idx: u32 = 0;
    var core_func_idx: u32 = 0;
    // Per-import bundles, by import-shape index. `null` when the
    // import has no funcs to lower.
    const Bundle = struct { core_inst_idx: u32 };
    var bundles_by_shape = try ar.alloc(?Bundle, import_shapes.items.len);
    for (bundles_by_shape) |*b| b.* = null;

    for (import_shapes.items, 0..) |_, i| {
        const wired = wired_funcs_by_shape[i];
        if (wired.len == 0) continue;
        const import_inst_idx: u32 = @intCast(i);
        // 1. alias.instance_export(.func) per imported func.
        const fn_comp_func_idx_base = comp_func_idx;
        for (wired) |fn_ref| {
            try aliases.append(ar, .{ .instance_export = .{
                .sort = .func,
                .instance_idx = import_inst_idx,
                .name = fn_ref.name,
            } });
            try Section.appendAlias(&order, ar, aliases.items.len);
            comp_func_idx += 1;
        }
        // 2. canon.lower per imported func.
        const lowered_core_func_idx_base = core_func_idx;
        for (wired, 0..) |_, fi| {
            try canons.append(ar, .{ .lower = .{
                .func_idx = fn_comp_func_idx_base + @as(u32, @intCast(fi)),
                .opts = &.{},
            } });
            core_func_idx += 1;
        }
        try order.append(ar, .{
            .kind = .canon,
            .start = @intCast(canons.items.len - wired.len),
            .count = @intCast(wired.len),
        });

        // 3. core_instance.exports bundle for this import.
        const bundle_exports = try ar.alloc(ctypes.CoreInlineExport, wired.len);
        for (wired, 0..) |fn_ref, fi| {
            bundle_exports[fi] = .{
                .name = fn_ref.name,
                .sort_idx = .{
                    .sort = .func,
                    .idx = lowered_core_func_idx_base + @as(u32, @intCast(fi)),
                },
            };
        }
        try core_instances.append(ar, .{ .exports = bundle_exports });
        bundles_by_shape[i] = .{ .core_inst_idx = @intCast(core_instances.items.len - 1) };
    }

    // ── Main core_module + main core_instance.instantiate.
    //
    // The main instance's index in the core-instance indexspace is
    // `main_core_inst_idx`, which equals the number of inline-exports
    // bundles emitted in Phase 2.5. The `(with …)` args feed each
    // bundle into the core module under the import's qualified name.
    try order.append(ar, .{ .kind = .core_module, .start = 0, .count = 1 });

    var main_args = std.ArrayListUnmanaged(ctypes.CoreInstantiateArg).empty;
    for (import_shapes.items, 0..) |shape, i| {
        if (bundles_by_shape[i]) |b| {
            try main_args.append(ar, .{
                .name = shape.qualified_name,
                .instance_idx = b.core_inst_idx,
            });
        }
    }
    try core_instances.append(ar, .{ .instantiate = .{
        .module_idx = 0,
        .args = try main_args.toOwnedSlice(ar),
    } });
    const main_core_inst_idx: u32 = @intCast(core_instances.items.len - 1);
    // One contiguous `.core_instance` section covering bundles + main.
    try order.append(ar, .{
        .kind = .core_instance,
        .start = 0,
        .count = @intCast(core_instances.items.len),
    });

    // ── Phase 3: walk export externs, hoisting resource handles
    //    referenced by their func sigs.
    //
    // Cache of resource-name -> component-level type idx of the
    // alias from the providing import instance. Reused across
    // exports referencing the same resource.
    var resource_alias_idx = std.StringHashMapUnmanaged(u32).empty;
    // Cache of (resource_name, handle_kind) -> component-level type
    // idx of the hoisted `(type (own/borrow alias_slot))` typedef.
    // Reused across funcs/exports referencing the same handle.
    const HandleKind = enum { own, borrow };
    const HandleKey = struct { name: []const u8, kind: HandleKind };
    var hoist_keys = std.ArrayListUnmanaged(HandleKey).empty;
    var hoist_idxs = std.ArrayListUnmanaged(u32).empty;

    const HandleResolver = struct {
        ar: std.mem.Allocator,
        ext_slots: []const metadata_decode.TypeSlot,
        types: *std.ArrayListUnmanaged(ctypes.TypeDef),
        aliases: *std.ArrayListUnmanaged(ctypes.Alias),
        resource_owner: *std.StringHashMapUnmanaged([]const u8),
        import_inst_idx_for: *std.StringHashMapUnmanaged(u32),
        resource_alias_idx: *std.StringHashMapUnmanaged(u32),
        hoist_keys: *std.ArrayListUnmanaged(HandleKey),
        hoist_idxs: *std.ArrayListUnmanaged(u32),
        comp_type_idx: *u32,
        order: *std.ArrayListUnmanaged(ctypes.SectionEntry),

        fn resourceAlias(self: @This(), name: []const u8) !u32 {
            if (self.resource_alias_idx.get(name)) |idx| return idx;
            const owner = self.resource_owner.get(name) orelse return error.UnresolvedResource;
            const inst_idx = self.import_inst_idx_for.get(owner) orelse return error.UnresolvedResource;
            try self.aliases.append(self.ar, .{ .instance_export = .{
                .sort = .type,
                .instance_idx = inst_idx,
                .name = name,
            } });
            try Section.appendAlias(self.order, self.ar, self.aliases.items.len);
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            try self.resource_alias_idx.put(self.ar, name, slot);
            return slot;
        }

        fn hoistHandle(self: @This(), name: []const u8, kind: HandleKind) !u32 {
            for (self.hoist_keys.items, 0..) |k, i| {
                if (k.kind == kind and std.mem.eql(u8, k.name, name)) {
                    return self.hoist_idxs.items[i];
                }
            }
            const alias_slot = try self.resourceAlias(name);
            const vt: ctypes.ValType = switch (kind) {
                .own => .{ .own = alias_slot },
                .borrow => .{ .borrow = alias_slot },
            };
            try self.types.append(self.ar, .{ .val = vt });
            try Section.appendType(self.order, self.ar, self.types.items.len);
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            try self.hoist_keys.append(self.ar, .{ .name = name, .kind = kind });
            try self.hoist_idxs.append(self.ar, slot);
            return slot;
        }

        fn rewriteValType(self: @This(), v: ctypes.ValType) !ctypes.ValType {
            return switch (v) {
                .own => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(self.ext_slots, k) orelse return error.UnresolvedResource;
                    break :blk .{ .type_idx = try self.hoistHandle(name, .own) };
                },
                .borrow => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(self.ext_slots, k) orelse return error.UnresolvedResource;
                    break :blk .{ .type_idx = try self.hoistHandle(name, .borrow) };
                },
                else => v,
            };
        }

        fn rewriteSig(self: @This(), sig: ctypes.FuncType) !ctypes.FuncType {
            const params = try self.ar.alloc(ctypes.NamedValType, sig.params.len);
            for (sig.params, 0..) |p, i| {
                params[i] = .{ .name = p.name, .type = try self.rewriteValType(p.type) };
            }
            const results: ctypes.FuncType.ResultList = switch (sig.results) {
                .none => .none,
                .unnamed => |v| .{ .unnamed = try self.rewriteValType(v) },
                .named => |named| n: {
                    const dst = try self.ar.alloc(ctypes.NamedValType, named.len);
                    for (named, 0..) |nv, i| {
                        dst[i] = .{ .name = nv.name, .type = try self.rewriteValType(nv.type) };
                    }
                    break :n .{ .named = dst };
                },
            };
            return .{ .params = params, .results = results };
        }
    };

    // For each export interface, emit (in this order):
    //   * resource type aliases (lazily, on first reference);
    //   * hoisted (own/borrow) typedefs (lazily, on first reference);
    //   * func types referencing the hoisted slots;
    //   * core func aliases for each func's core export;
    //   * canon lifts;
    //   * an inline-export instance bundling the lifted funcs;
    //   * a top-level export of that instance.
    //
    // The per-func emission keeps the alias/own pair adjacent to the
    // func type it serves; canon lifts and instances accumulate
    // across exports and are flushed once at the end via section_order
    // so the type/alias/func indexspaces grow monotonically.
    const CapturedFunc = struct {
        ext_qualified: []const u8,
        fn_name: []const u8,
        func_type_idx: u32,
        core_func_alias_idx: u32,
    };
    var captured_funcs = std.ArrayListUnmanaged(CapturedFunc).empty;
    var ext_export_start = std.ArrayListUnmanaged(struct {
        ext: metadata_decode.WorldExtern,
        start: u32,
    }).empty;
    // Core-func index counter is shared with Phase 2.5: `canon.lower`
    // bumped it once per imported func, and now each
    // `.alias instance_export` with `sort = .{.core = .func}` bumps it
    // once per exported func. Together they keep the core-func
    // indexspace strictly positional across both phases. The component
    // func indexspace (`comp_func_idx`) is likewise carried over —
    // Phase 2.5's func aliases already populated indices `0..M-1`, so
    // the lifts emitted here land at `M..M+exported_funcs-1`.

    for (decoded.externs) |ext| {
        if (!ext.is_export) continue;
        const resolver = HandleResolver{
            .ar = ar,
            .ext_slots = ext.type_slots,
            .types = &types,
            .aliases = &aliases,
            .resource_owner = &resource_owner,
            .import_inst_idx_for = &import_inst_idx_for,
            .resource_alias_idx = &resource_alias_idx,
            .hoist_keys = &hoist_keys,
            .hoist_idxs = &hoist_idxs,
            .comp_type_idx = &comp_type_idx,
            .order = &order,
        };
        const start: u32 = @intCast(captured_funcs.items.len);
        for (ext.funcs) |fn_ref| {
            const rewritten = try resolver.rewriteSig(fn_ref.sig);
            try types.append(ar, .{ .func = rewritten });
            try Section.appendType(&order, ar, types.items.len);
            const func_type_idx = comp_type_idx;
            comp_type_idx += 1;

            const core_func_export_name = try std.fmt.allocPrint(ar, "{s}#{s}", .{ ext.qualified_name, fn_ref.name });
            try aliases.append(ar, .{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = main_core_inst_idx,
                .name = core_func_export_name,
            } });
            try Section.appendAlias(&order, ar, aliases.items.len);
            const cf_idx = core_func_idx;
            core_func_idx += 1;

            try captured_funcs.append(ar, .{
                .ext_qualified = ext.qualified_name,
                .fn_name = fn_ref.name,
                .func_type_idx = func_type_idx,
                .core_func_alias_idx = cf_idx,
            });
        }
        try ext_export_start.append(ar, .{ .ext = ext, .start = start });
    }

    // ── Canon lifts and instance exprs: appended to flat lists,
    //    section_order entries appended after.
    const lifts_start: u32 = @intCast(canons.items.len);
    for (captured_funcs.items) |cf| {
        try canons.append(ar, .{ .lift = .{
            .core_func_idx = cf.core_func_alias_idx,
            .type_idx = cf.func_type_idx,
            .opts = &.{},
        } });
    }
    const lifts_count: u32 = @as(u32, @intCast(canons.items.len)) - lifts_start;

    for (ext_export_start.items, 0..) |es, ei| {
        const end: u32 = if (ei + 1 < ext_export_start.items.len)
            ext_export_start.items[ei + 1].start
        else
            @intCast(captured_funcs.items.len);
        const fn_count = end - es.start;
        var inline_exports = try ar.alloc(ctypes.InlineExport, fn_count);
        for (0..fn_count) |i| {
            const cf = captured_funcs.items[es.start + i];
            inline_exports[i] = .{
                .name = cf.fn_name,
                .sort_idx = .{ .sort = .func, .idx = comp_func_idx },
            };
            comp_func_idx += 1;
        }
        try instances.append(ar, .{ .exports = inline_exports });
        const inst_idx = import_inst_count + @as(u32, @intCast(ei));
        try exports.append(ar, .{
            .name = es.ext.qualified_name,
            .desc = .{ .instance = 0 },
            .sort_idx = .{ .sort = .instance, .idx = inst_idx },
        });
    }

    if (lifts_count > 0) {
        try order.append(ar, .{ .kind = .canon, .start = lifts_start, .count = lifts_count });
    }
    if (instances.items.len > 0) {
        try order.append(ar, .{ .kind = .instance, .start = 0, .count = @intCast(instances.items.len) });
    }
    if (exports.items.len > 0) {
        try order.append(ar, .{ .kind = .@"export", .start = 0, .count = @intCast(exports.items.len) });
    }

    const comp: ctypes.Component = .{
        .core_modules = core_modules,
        .core_instances = try core_instances.toOwnedSlice(ar),
        .core_types = &.{},
        .components = &.{},
        .instances = try instances.toOwnedSlice(ar),
        .aliases = try aliases.toOwnedSlice(ar),
        .types = try types.toOwnedSlice(ar),
        .canons = try canons.toOwnedSlice(ar),
        .imports = try imports.toOwnedSlice(ar),
        .exports = try exports.toOwnedSlice(ar),
        .section_order = try order.toOwnedSlice(ar),
    };
    return writer.encode(alloc, &comp);
}

/// Shim/fixup path of `buildComponent`: emitted when at least one
/// imported func needs `(memory)` + `(realloc)` canon-lower opts to
/// lower its string / list / multi-result params or results
/// (cataggar/wabt#203).
///
/// The forward-reference cycle — canon.lower needs the main
/// instance's `memory` / `cabi_realloc` exports, but the main
/// instance needs the lowered funcs as `(with …)` args — is broken
/// with the wasm-tools shim/fixup trampoline pattern:
///
///   1. `shim` core module exposes one trapping trampoline per
///      lowered func, all `call_indirect`-ing through a funcref
///      table also exported as `$imports`.
///   2. Instantiate shim. Per-import shim-stub bundles bind the
///      main module's imports to the shim's stubs by canonical
///      method name (`[constructor]fields`, `[method]fields.append`,
///      …).
///   3. Instantiate main with those bundles as `(with …)` args.
///      Main's `memory` + `cabi_realloc` are now reachable.
///   4. Alias main's memory and cabi_realloc, then emit
///      `canon.lower` per wired func with the opts pointing at them.
///   5. `fixup` core module has an active element segment that
///      populates the shim's `$imports` table from offset 0 with
///      the lowered funcs.
///   6. Instantiate fixup with `(with "" <bundle of lowered funcs +
///      shim.$imports>)`. The active elem fires on instantiation,
///      patching every shim stub to call the real lowered func.
///
/// Cross-iface handle refs in imported func sigs are still
/// skipped here — the verbatim body lift assumes the body's
/// `alias outer` / `alias instance_export` references resolve
/// against an outer scope that we don't currently reconstruct.
/// Lifting that restriction is a separate follow-up.
fn buildComponentShimFixup(
    alloc: std.mem.Allocator,
    ar: std.mem.Allocator,
    decoded: metadata_decode.DecodedWorld,
    stripped_core: []const u8,
) ![]u8 {
    const abi = wabt.component.adapter.abi;
    const shim_mod = wabt.component.adapter.shim;
    const fixup_mod = wabt.component.adapter.fixup;
    const wtypes = wabt.types;

    const core_exports = try probeCoreExports(stripped_core);
    const memory_export_name = core_exports.memory_name orelse return error.MissingCoreExportMemory;
    const realloc_export_name = core_exports.realloc_name orelse return error.MissingCabiRealloc;

    // ── Phase 1: re-collect import shapes (same as the fast path).
    var resource_owner = std.StringHashMapUnmanaged([]const u8).empty;
    const ImportShape = struct {
        qualified_name: []const u8,
        resources: []const []const u8,
        funcs: []const metadata_decode.FuncRef,
        ext_slots: []const metadata_decode.TypeSlot,
        inst_decls: []const ctypes.Decl,
    };
    var import_shapes = std.ArrayListUnmanaged(ImportShape).empty;
    for (decoded.externs) |ext| {
        if (ext.is_export) continue;
        var rs = std.ArrayListUnmanaged([]const u8).empty;
        for (ext.type_slots) |slot| switch (slot) {
            .sub_resource => |name| try rs.append(ar, name),
            else => {},
        };
        if (rs.items.len == 0 and ext.funcs.len == 0) continue;
        const owned = try rs.toOwnedSlice(ar);
        try import_shapes.append(ar, .{
            .qualified_name = ext.qualified_name,
            .resources = owned,
            .funcs = ext.funcs,
            .ext_slots = ext.type_slots,
            .inst_decls = ext.inst_decls,
        });
        for (owned) |name| {
            const gop = try resource_owner.getOrPut(ar, name);
            if (gop.found_existing) return error.AmbiguousResourceName;
            gop.value_ptr.* = ext.qualified_name;
        }
    }

    // ── Phase 2: classify each imported func + compute its lowered
    //    core signature. A func is "wired" (gets a canon.lower +
    //    shim slot) iff its body lift would be valid — i.e. its sig
    //    doesn't reach types that the instance-type body's alias
    //    decls bind. For #203 minimum scope we just call
    //    classifyFunc with an empty world_decls; the resolver
    //    falls back to scalar-handle for any unresolvable type idx,
    //    which is the correct ABI shape for resource handles but
    //    silently wrong for outer-aliased compound types. The
    //    follow-up that wires cross-iface refs into the body also
    //    flips this to a hard skip.
    const WiredFunc = struct {
        fn_ref: metadata_decode.FuncRef,
        opts: abi.FuncOpts,
        slot_params: []const wtypes.ValType,
        slot_results: []const wtypes.ValType,
    };
    var wired_by_shape = try ar.alloc([]WiredFunc, import_shapes.items.len);
    var total_wired: u32 = 0;
    for (import_shapes.items, 0..) |shape, i| {
        var list = std.ArrayListUnmanaged(WiredFunc).empty;
        const resolver = abi.TypeResolver{
            .inst_decls = shape.inst_decls,
            .world_decls = &.{},
        };
        for (shape.funcs) |fn_ref| {
            const ftr = abi.FuncTypeRef{ .func = fn_ref.sig, .resolver = resolver };
            const cls = abi.classifyFunc(ftr);
            const lowered = try abi.lowerCoreSig(ar, ftr);
            try list.append(ar, .{
                .fn_ref = fn_ref,
                .opts = cls.opts,
                .slot_params = lowered.params,
                .slot_results = lowered.results,
            });
        }
        wired_by_shape[i] = try list.toOwnedSlice(ar);
        total_wired += @intCast(wired_by_shape[i].len);
    }

    // ── Phase 3: build shim + fixup core wasm bytes.
    const shim_slots = try ar.alloc(shim_mod.Slot, total_wired);
    {
        var k: usize = 0;
        for (wired_by_shape) |wired| for (wired) |w| {
            shim_slots[k] = .{ .params = w.slot_params, .results = w.slot_results };
            k += 1;
        };
    }
    const shim_bytes = try shim_mod.build(ar, shim_slots);
    const fixup_bytes = try fixup_mod.build(ar, shim_slots);

    // ── Phase 4: build the wrapping component AST.
    //
    // core_modules: [main(0), shim(1), fixup(2)].
    const core_modules = try ar.alloc(ctypes.CoreModule, 3);
    core_modules[0] = .{ .data = stripped_core };
    core_modules[1] = .{ .data = shim_bytes };
    core_modules[2] = .{ .data = fixup_bytes };

    var core_instances = std.ArrayListUnmanaged(ctypes.CoreInstanceExpr).empty;
    var aliases = std.ArrayListUnmanaged(ctypes.Alias).empty;
    var types = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    var canons = std.ArrayListUnmanaged(ctypes.Canon).empty;
    var instances = std.ArrayListUnmanaged(ctypes.InstanceExpr).empty;
    var exports = std.ArrayListUnmanaged(ctypes.ExportDecl).empty;
    var imports = std.ArrayListUnmanaged(ctypes.ImportDecl).empty;
    var comp_type_idx: u32 = 0;
    var order = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    const Section = struct {
        fn appendType(o: *std.ArrayListUnmanaged(ctypes.SectionEntry), arx: std.mem.Allocator, n: usize) !void {
            try o.append(arx, .{ .kind = .type, .start = @intCast(n - 1), .count = 1 });
        }
        fn appendAlias(o: *std.ArrayListUnmanaged(ctypes.SectionEntry), arx: std.mem.Allocator, n: usize) !void {
            try o.append(arx, .{ .kind = .alias, .start = @intCast(n - 1), .count = 1 });
        }
    };

    // ── Phase 4a: emit instance-type + import per shape using the
    //    metadata's encoded body verbatim. Resource sub_resource
    //    exports live inside it already; func type defs + named
    //    `.@"export" func` decls too. The body's local type-index
    //    space matches the func sigs' slot refs by construction.
    var import_inst_idx_for = std.StringHashMapUnmanaged(u32).empty;
    for (import_shapes.items, 0..) |shape, i| {
        try types.append(ar, .{ .instance = .{ .decls = shape.inst_decls } });
        try Section.appendType(&order, ar, types.items.len);
        const inst_type_idx = comp_type_idx;
        comp_type_idx += 1;
        try imports.append(ar, .{
            .name = shape.qualified_name,
            .desc = .{ .instance = inst_type_idx },
        });
        try order.append(ar, .{ .kind = .import, .start = @intCast(imports.items.len - 1), .count = 1 });
        try import_inst_idx_for.put(ar, shape.qualified_name, @intCast(i));
    }
    const import_inst_count: u32 = @intCast(imports.items.len);

    // ── Phase 4b: alias each wired imported func into the
    //    component-level func indexspace. These slots become the
    //    `func_idx` operand of `canon.lower` in Phase 4f.
    var comp_func_idx: u32 = 0;
    const FuncAlias = struct { comp_func_idx: u32 };
    var func_alias_by_shape = try ar.alloc([]FuncAlias, import_shapes.items.len);
    for (import_shapes.items, 0..) |_, i| {
        const wired = wired_by_shape[i];
        var slots = try ar.alloc(FuncAlias, wired.len);
        for (wired, 0..) |w, fi| {
            try aliases.append(ar, .{ .instance_export = .{
                .sort = .func,
                .instance_idx = @intCast(i),
                .name = w.fn_ref.name,
            } });
            try Section.appendAlias(&order, ar, aliases.items.len);
            slots[fi] = .{ .comp_func_idx = comp_func_idx };
            comp_func_idx += 1;
        }
        func_alias_by_shape[i] = slots;
    }

    // ── Phase 4c: emit core modules section then start core_instance.
    try order.append(ar, .{ .kind = .core_module, .start = 0, .count = 3 });

    // Core-func index space: shim contributes `total_wired` stubs
    // when we alias them below; main exports + lowered funcs follow.
    var core_func_idx: u32 = 0;
    // Core-instance index counter — drives every `instance_idx`
    // payload that follows.
    //
    // Step 1: instantiate shim (no args).
    try core_instances.append(ar, .{ .instantiate = .{ .module_idx = 1, .args = &.{} } });
    const shim_inst_idx: u32 = @intCast(core_instances.items.len - 1);

    // Step 2: alias the shim's N stubs by name ("0","1",…) as core
    // funcs. These become the source funcs for the per-shape
    // bundles that satisfy main's `(with …)` args.
    const shim_stub_core_idx_base = core_func_idx;
    {
        var k: u32 = 0;
        while (k < total_wired) : (k += 1) {
            const name = try std.fmt.allocPrint(ar, "{d}", .{k});
            try aliases.append(ar, .{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = shim_inst_idx,
                .name = name,
            } });
            try Section.appendAlias(&order, ar, aliases.items.len);
            core_func_idx += 1;
        }
    }

    // Step 3: per import shape, build an inline-exports bundle
    // mapping each wired func's canonical method name to its shim
    // stub. Bundle indices live in the core-instance indexspace.
    var bundle_for_main_args = std.ArrayListUnmanaged(ctypes.CoreInstantiateArg).empty;
    {
        var stub_cursor: u32 = shim_stub_core_idx_base;
        for (import_shapes.items, 0..) |shape, i| {
            const wired = wired_by_shape[i];
            if (wired.len == 0) continue;
            const bundle_exports = try ar.alloc(ctypes.CoreInlineExport, wired.len);
            for (wired, 0..) |w, fi| {
                bundle_exports[fi] = .{
                    .name = w.fn_ref.name,
                    .sort_idx = .{ .sort = .func, .idx = stub_cursor },
                };
                stub_cursor += 1;
            }
            try core_instances.append(ar, .{ .exports = bundle_exports });
            const bundle_inst_idx: u32 = @intCast(core_instances.items.len - 1);
            try bundle_for_main_args.append(ar, .{
                .name = shape.qualified_name,
                .instance_idx = bundle_inst_idx,
            });
        }
    }

    // Step 4: instantiate main with the per-shape bundles as args.
    try core_instances.append(ar, .{ .instantiate = .{
        .module_idx = 0,
        .args = try bundle_for_main_args.toOwnedSlice(ar),
    } });
    const main_core_inst_idx: u32 = @intCast(core_instances.items.len - 1);

    // ── Phase 4d: alias `memory` + `cabi_realloc` from main —
    //    these are the canon.lower opts targets.
    try aliases.append(ar, .{ .instance_export = .{
        .sort = .{ .core = .memory },
        .instance_idx = main_core_inst_idx,
        .name = memory_export_name,
    } });
    try Section.appendAlias(&order, ar, aliases.items.len);
    const memory_core_idx: u32 = 0; // first core-memory we alias

    try aliases.append(ar, .{ .instance_export = .{
        .sort = .{ .core = .func },
        .instance_idx = main_core_inst_idx,
        .name = realloc_export_name,
    } });
    try Section.appendAlias(&order, ar, aliases.items.len);
    const realloc_core_idx: u32 = core_func_idx;
    core_func_idx += 1;

    // ── Phase 4e: alias the shim's `$imports` table. Used as the
    //    `$imports` import of the fixup module's args bundle.
    try aliases.append(ar, .{ .instance_export = .{
        .sort = .{ .core = .table },
        .instance_idx = shim_inst_idx,
        .name = "$imports",
    } });
    try Section.appendAlias(&order, ar, aliases.items.len);
    const shim_table_core_idx: u32 = 0; // first core-table we alias

    // ── Phase 4f: canon.lower per wired func with opts pointing
    //    at the memory + cabi_realloc indices aliased in Phase 4d.
    const lowered_core_idx_base = core_func_idx;
    {
        const lowers_start: u32 = @intCast(canons.items.len);
        for (wired_by_shape, 0..) |wired, si| {
            for (wired, 0..) |w, fi| {
                const opts = try wabt.component.adapter.adapter.buildCanonLowerOpts(
                    ar,
                    w.opts,
                    memory_core_idx,
                    realloc_core_idx,
                );
                try canons.append(ar, .{ .lower = .{
                    .func_idx = func_alias_by_shape[si][fi].comp_func_idx,
                    .opts = opts,
                } });
                core_func_idx += 1;
            }
        }
        const lowers_count: u32 = @as(u32, @intCast(canons.items.len)) - lowers_start;
        if (lowers_count > 0) {
            try order.append(ar, .{ .kind = .canon, .start = lowers_start, .count = lowers_count });
        }
    }

    // ── Phase 4g: build the fixup module's args bundle. Maps each
    //    slot's stable name ("0","1",…) to the lowered core func at
    //    `lowered_core_idx_base + i`, plus `$imports` → the shim's
    //    table. Then instantiate fixup with this bundle.
    {
        const bundle_size = total_wired + 1;
        const bundle = try ar.alloc(ctypes.CoreInlineExport, bundle_size);
        var k: u32 = 0;
        while (k < total_wired) : (k += 1) {
            const name = try std.fmt.allocPrint(ar, "{d}", .{k});
            bundle[k] = .{
                .name = name,
                .sort_idx = .{ .sort = .func, .idx = lowered_core_idx_base + k },
            };
        }
        bundle[total_wired] = .{
            .name = "$imports",
            .sort_idx = .{ .sort = .table, .idx = shim_table_core_idx },
        };
        try core_instances.append(ar, .{ .exports = bundle });
        const fixup_args_idx: u32 = @intCast(core_instances.items.len - 1);

        const fixup_args = try ar.alloc(ctypes.CoreInstantiateArg, 1);
        fixup_args[0] = .{ .name = "", .instance_idx = fixup_args_idx };
        try core_instances.append(ar, .{ .instantiate = .{
            .module_idx = 2,
            .args = fixup_args,
        } });
    }

    try order.append(ar, .{
        .kind = .core_instance,
        .start = 0,
        .count = @intCast(core_instances.items.len),
    });

    // ── Phase 5: export-side. Mirrors the #202 fast path: walk
    //    `is_export=true` externs, hoist their resource handles via
    //    the same HandleResolver, emit `canon.lift` per func, and a
    //    top-level instance export per ext. The only difference is
    //    that `instance_idx` for the `alias instance_export
    //    sort=core(.func)` calls is `main_core_inst_idx` (not
    //    literal 0) — same generalisation as #202.
    var resource_alias_idx = std.StringHashMapUnmanaged(u32).empty;
    const HandleKind = enum { own, borrow };
    const HandleKey = struct { name: []const u8, kind: HandleKind };
    var hoist_keys = std.ArrayListUnmanaged(HandleKey).empty;
    var hoist_idxs = std.ArrayListUnmanaged(u32).empty;

    const HandleResolver = struct {
        ar: std.mem.Allocator,
        ext_slots: []const metadata_decode.TypeSlot,
        types: *std.ArrayListUnmanaged(ctypes.TypeDef),
        aliases: *std.ArrayListUnmanaged(ctypes.Alias),
        resource_owner: *std.StringHashMapUnmanaged([]const u8),
        import_inst_idx_for: *std.StringHashMapUnmanaged(u32),
        resource_alias_idx: *std.StringHashMapUnmanaged(u32),
        hoist_keys: *std.ArrayListUnmanaged(HandleKey),
        hoist_idxs: *std.ArrayListUnmanaged(u32),
        comp_type_idx: *u32,
        order: *std.ArrayListUnmanaged(ctypes.SectionEntry),

        fn resourceAlias(self: @This(), name: []const u8) !u32 {
            if (self.resource_alias_idx.get(name)) |idx| return idx;
            const owner = self.resource_owner.get(name) orelse return error.UnresolvedResource;
            const inst_idx = self.import_inst_idx_for.get(owner) orelse return error.UnresolvedResource;
            try self.aliases.append(self.ar, .{ .instance_export = .{
                .sort = .type,
                .instance_idx = inst_idx,
                .name = name,
            } });
            try Section.appendAlias(self.order, self.ar, self.aliases.items.len);
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            try self.resource_alias_idx.put(self.ar, name, slot);
            return slot;
        }

        fn hoistHandle(self: @This(), name: []const u8, kind: HandleKind) !u32 {
            for (self.hoist_keys.items, 0..) |k, i| {
                if (k.kind == kind and std.mem.eql(u8, k.name, name)) {
                    return self.hoist_idxs.items[i];
                }
            }
            const alias_slot = try self.resourceAlias(name);
            const vt: ctypes.ValType = switch (kind) {
                .own => .{ .own = alias_slot },
                .borrow => .{ .borrow = alias_slot },
            };
            try self.types.append(self.ar, .{ .val = vt });
            try Section.appendType(self.order, self.ar, self.types.items.len);
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            try self.hoist_keys.append(self.ar, .{ .name = name, .kind = kind });
            try self.hoist_idxs.append(self.ar, slot);
            return slot;
        }

        fn rewriteValType(self: @This(), v: ctypes.ValType) !ctypes.ValType {
            return switch (v) {
                .own => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(self.ext_slots, k) orelse return error.UnresolvedResource;
                    break :blk .{ .type_idx = try self.hoistHandle(name, .own) };
                },
                .borrow => |k| blk: {
                    const name = metadata_decode.resourceNameForSlot(self.ext_slots, k) orelse return error.UnresolvedResource;
                    break :blk .{ .type_idx = try self.hoistHandle(name, .borrow) };
                },
                else => v,
            };
        }

        fn rewriteSig(self: @This(), sig: ctypes.FuncType) !ctypes.FuncType {
            const params = try self.ar.alloc(ctypes.NamedValType, sig.params.len);
            for (sig.params, 0..) |p, i| {
                params[i] = .{ .name = p.name, .type = try self.rewriteValType(p.type) };
            }
            const results: ctypes.FuncType.ResultList = switch (sig.results) {
                .none => .none,
                .unnamed => |v| .{ .unnamed = try self.rewriteValType(v) },
                .named => |named| n: {
                    const dst = try self.ar.alloc(ctypes.NamedValType, named.len);
                    for (named, 0..) |nv, i| {
                        dst[i] = .{ .name = nv.name, .type = try self.rewriteValType(nv.type) };
                    }
                    break :n .{ .named = dst };
                },
            };
            return .{ .params = params, .results = results };
        }
    };

    const CapturedFunc = struct {
        ext_qualified: []const u8,
        fn_name: []const u8,
        func_type_idx: u32,
        core_func_alias_idx: u32,
    };
    var captured_funcs = std.ArrayListUnmanaged(CapturedFunc).empty;
    var ext_export_start = std.ArrayListUnmanaged(struct {
        ext: metadata_decode.WorldExtern,
        start: u32,
    }).empty;

    for (decoded.externs) |ext| {
        if (!ext.is_export) continue;
        const resolver = HandleResolver{
            .ar = ar,
            .ext_slots = ext.type_slots,
            .types = &types,
            .aliases = &aliases,
            .resource_owner = &resource_owner,
            .import_inst_idx_for = &import_inst_idx_for,
            .resource_alias_idx = &resource_alias_idx,
            .hoist_keys = &hoist_keys,
            .hoist_idxs = &hoist_idxs,
            .comp_type_idx = &comp_type_idx,
            .order = &order,
        };
        const start: u32 = @intCast(captured_funcs.items.len);
        for (ext.funcs) |fn_ref| {
            const rewritten = try resolver.rewriteSig(fn_ref.sig);
            try types.append(ar, .{ .func = rewritten });
            try Section.appendType(&order, ar, types.items.len);
            const func_type_idx = comp_type_idx;
            comp_type_idx += 1;

            const core_func_export_name = try std.fmt.allocPrint(ar, "{s}#{s}", .{ ext.qualified_name, fn_ref.name });
            try aliases.append(ar, .{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = main_core_inst_idx,
                .name = core_func_export_name,
            } });
            try Section.appendAlias(&order, ar, aliases.items.len);
            const cf_idx = core_func_idx;
            core_func_idx += 1;

            try captured_funcs.append(ar, .{
                .ext_qualified = ext.qualified_name,
                .fn_name = fn_ref.name,
                .func_type_idx = func_type_idx,
                .core_func_alias_idx = cf_idx,
            });
        }
        try ext_export_start.append(ar, .{ .ext = ext, .start = start });
    }

    const lifts_start: u32 = @intCast(canons.items.len);
    for (captured_funcs.items) |cf| {
        try canons.append(ar, .{ .lift = .{
            .core_func_idx = cf.core_func_alias_idx,
            .type_idx = cf.func_type_idx,
            .opts = &.{},
        } });
    }
    const lifts_count: u32 = @as(u32, @intCast(canons.items.len)) - lifts_start;

    for (ext_export_start.items, 0..) |es, ei| {
        const end: u32 = if (ei + 1 < ext_export_start.items.len)
            ext_export_start.items[ei + 1].start
        else
            @intCast(captured_funcs.items.len);
        const fn_count = end - es.start;
        var inline_exports = try ar.alloc(ctypes.InlineExport, fn_count);
        for (0..fn_count) |i| {
            const cf = captured_funcs.items[es.start + i];
            inline_exports[i] = .{
                .name = cf.fn_name,
                .sort_idx = .{ .sort = .func, .idx = comp_func_idx },
            };
            comp_func_idx += 1;
        }
        try instances.append(ar, .{ .exports = inline_exports });
        const inst_idx = import_inst_count + @as(u32, @intCast(ei));
        try exports.append(ar, .{
            .name = es.ext.qualified_name,
            .desc = .{ .instance = 0 },
            .sort_idx = .{ .sort = .instance, .idx = inst_idx },
        });
    }

    if (lifts_count > 0) {
        try order.append(ar, .{ .kind = .canon, .start = lifts_start, .count = lifts_count });
    }
    if (instances.items.len > 0) {
        try order.append(ar, .{ .kind = .instance, .start = 0, .count = @intCast(instances.items.len) });
    }
    if (exports.items.len > 0) {
        try order.append(ar, .{ .kind = .@"export", .start = 0, .count = @intCast(exports.items.len) });
    }

    const comp: ctypes.Component = .{
        .core_modules = core_modules,
        .core_instances = try core_instances.toOwnedSlice(ar),
        .core_types = &.{},
        .components = &.{},
        .instances = try instances.toOwnedSlice(ar),
        .aliases = try aliases.toOwnedSlice(ar),
        .types = try types.toOwnedSlice(ar),
        .canons = try canons.toOwnedSlice(ar),
        .imports = try imports.toOwnedSlice(ar),
        .exports = try exports.toOwnedSlice(ar),
        .section_order = try order.toOwnedSlice(ar),
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

/// Discover the `memory` and `cabi_realloc` exports of a stripped
/// core wasm module. Both are needed to lower imported component
/// methods that take or return `string` / `list` — the canon.lower
/// op references them via `(memory <main_inst.memory>)` +
/// `(realloc <main_inst.cabi_realloc>)`.
///
/// Scans the core wasm's export section only (assumes the
/// `component-type:*` custom sections have already been stripped).
/// Returns null for either field if the export is absent — callers
/// gate on these to decide whether shim+fixup wiring is even
/// possible.
const CoreExports = struct {
    /// Name under which the core module exports its memory, or null
    /// if no memory export was found.
    memory_name: ?[]const u8,
    /// Name under which the core module exports its `cabi_realloc`
    /// func, or null if no func export with that name exists.
    realloc_name: ?[]const u8,
};

fn probeCoreExports(core_bytes: []const u8) !CoreExports {
    if (core_bytes.len < 8) return error.InvalidCoreModule;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidCoreModule;

    var memory_name: ?[]const u8 = null;
    var realloc_name: ?[]const u8 = null;

    var i: usize = 8;
    while (i < core_bytes.len) {
        const id = core_bytes[i];
        i += 1;
        const sz = try readU32Leb(core_bytes, i);
        i += sz.bytes_read;
        if (i + sz.value > core_bytes.len) return error.InvalidCoreModule;
        const body = core_bytes[i .. i + sz.value];
        i += sz.value;

        // Section ID 7 = export section.
        if (id != 7) continue;

        var p: usize = 0;
        const n = try readU32Leb(body, p);
        p += n.bytes_read;
        var k: u32 = 0;
        while (k < n.value) : (k += 1) {
            const nl = try readU32Leb(body, p);
            p += nl.bytes_read;
            if (p + nl.value > body.len) return error.InvalidCoreModule;
            const name = body[p .. p + nl.value];
            p += nl.value;
            if (p >= body.len) return error.InvalidCoreModule;
            const kind = body[p];
            p += 1;
            const idx = try readU32Leb(body, p);
            p += idx.bytes_read;
            // export kinds: 0=func, 1=table, 2=memory, 3=global, 4=tag.
            switch (kind) {
                0 => if (std.mem.eql(u8, name, "cabi_realloc")) {
                    realloc_name = name;
                },
                2 => if (memory_name == null) {
                    // First memory export wins; canonical convention
                    // is "memory" but a malformed name shouldn't trip
                    // the probe — the canon.lower opt references the
                    // memory by core-memory index, not by name.
                    memory_name = name;
                },
                else => {},
            }
        }
        break;
    }

    return .{ .memory_name = memory_name, .realloc_name = realloc_name };
}

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

test "buildComponent #198: wraps cross-iface-use resources with import + alias + hoist" {
    // Mirrors the #191 reproducer end-to-end: the world imports a
    // resource-providing interface and exports another interface
    // whose func uses those resources via `use` + `own<R>`. Before
    // #198, buildComponent placed the decoded `.own = N` refs
    // verbatim into the wrapping component's flat type list, where
    // N indexed the originating iface body's slots — producing
    // dangling type refs that `wasm-tools validate` rejected.
    //
    // Synth core module: exports
    // `wasi:http/incoming-handler@0.2.6#handle` taking two i32s.
    // Name length: 39 bytes.
    const core_only = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        // type section: 1 type — (func (param i32 i32))
        0x01, 0x06, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x00,
        // function section: 1 func of type 0
        0x03, 0x02, 0x01, 0x00,
        // export section: 1 export
        //   body = 1(count) + 1(name_len) + 39(name) + 1(sort) + 1(idx) = 43
        0x07, 43, 0x01,
        39, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 'i', 'n', 'c', 'o', 'm', 'i', 'n', 'g', '-',
        'h', 'a', 'n', 'd', 'l', 'e', 'r', '@', '0', '.',
        '2', '.', '6', '#', 'h', 'a', 'n', 'd', 'l', 'e',
        0x00, 0x00,
        // code section: 1 body
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };

    const ct_payload = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package wasi:http@0.2.6;
        \\
        \\interface types {
        \\    resource incoming-request {}
        \\    resource response-outparam {}
        \\}
        \\
        \\interface incoming-handler {
        \\    use types.{incoming-request, response-outparam};
        \\    handle: func(request: incoming-request, response-out: response-outparam);
        \\}
        \\
        \\world http-hello {
        \\    import types;
        \\    export incoming-handler;
        \\}
    , "http-hello");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:http-hello";
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // 1 import for the resource-providing interface.
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expectEqualStrings("wasi:http/types@0.2.6", loaded.imports[0].name);
    try testing.expect(loaded.imports[0].desc == .instance);

    // The import references an instance type whose decls are two
    // sub_resource exports for incoming-request + response-outparam.
    const inst_type_idx = loaded.imports[0].desc.instance;
    try testing.expect(inst_type_idx < loaded.type_indexspace.len);
    const inst_contrib = loaded.type_indexspace[inst_type_idx];
    try testing.expect(inst_contrib == .type_def);
    const inst_td = loaded.types[inst_contrib.type_def];
    try testing.expect(inst_td == .instance);
    const inst_decls = inst_td.instance.decls;
    try testing.expectEqual(@as(usize, 2), inst_decls.len);
    var saw_in_req = false;
    var saw_out = false;
    for (inst_decls) |d| switch (d) {
        .@"export" => |e| switch (e.desc) {
            .type => |tb| switch (tb) {
                .sub_resource => {
                    if (std.mem.eql(u8, e.name, "incoming-request")) saw_in_req = true;
                    if (std.mem.eql(u8, e.name, "response-outparam")) saw_out = true;
                },
                else => return error.UnexpectedTypeBound,
            },
            else => return error.UnexpectedExportDesc,
        },
        else => return error.UnexpectedInstanceDecl,
    };
    try testing.expect(saw_in_req);
    try testing.expect(saw_out);

    // 2 type-sort aliases (one per imported resource) + 1
    // core-func-sort alias (for the handle export).
    try testing.expectEqual(@as(usize, 3), loaded.aliases.len);
    var type_alias_count: usize = 0;
    var core_func_alias_count: usize = 0;
    for (loaded.aliases) |a| switch (a) {
        .instance_export => |ie| switch (ie.sort) {
            .type => type_alias_count += 1,
            .core => |cs| if (cs == .func) {
                core_func_alias_count += 1;
            },
            else => {},
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), type_alias_count);
    try testing.expectEqual(@as(usize, 1), core_func_alias_count);

    // 1 export for the lifted interface.
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings("wasi:http/incoming-handler@0.2.6", loaded.exports[0].name);
    try testing.expect(loaded.exports[0].desc == .instance);

    // Canon lift count: one per exported func.
    try testing.expectEqual(@as(usize, 1), loaded.canons.len);
    try testing.expect(loaded.canons[0] == .lift);
    // The lift's func type's params must reference hoisted typedefs
    // (.type_idx) — NOT raw .own/.borrow. Resolve through to confirm
    // each landed on a `(type (own <alias_slot>))`.
    const lift = loaded.canons[0].lift;
    try testing.expect(lift.type_idx < loaded.type_indexspace.len);
    const ft_contrib = loaded.type_indexspace[lift.type_idx];
    try testing.expect(ft_contrib == .type_def);
    const ft = loaded.types[ft_contrib.type_def];
    try testing.expect(ft == .func);
    const fsig = ft.func;
    try testing.expectEqual(@as(usize, 2), fsig.params.len);
    for (fsig.params) |p| {
        try testing.expect(p.type == .type_idx);
        try testing.expect(p.type.type_idx < loaded.type_indexspace.len);
        const own_contrib = loaded.type_indexspace[p.type.type_idx];
        try testing.expect(own_contrib == .type_def);
        const hoisted = loaded.types[own_contrib.type_def];
        try testing.expect(hoisted == .val);
        try testing.expect(hoisted.val == .own);
    }
}

test "buildComponent #202: emits canon.lower + with-args for imported interface methods" {
    // Reproducer from cataggar/wabt#202: an imported resource method
    // (here `[constructor]fields` returning `own<fields>`) must be
    // wired through the wrapping component into the core wasm's
    // matching import. Before #202, `core_instances[0].instantiate.args`
    // was empty and no `canon.lower` was emitted, so the core import
    // dangled and wamr's interpreter quietly returned 0.
    //
    // Synth core module: 1 type `(func -> i32)`, 1 type
    // `(func i32 i32 -> )`, 1 import
    // `wasi:http/types@0.2.6.[constructor]fields` (type 1), 1 defined
    // func of type 2, 1 export
    // `wasi:http/incoming-handler@0.2.6#handle` (defined func idx 1).
    const core_only = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        // type section: 3 types
        //   body = 1(count) + 3(type 0: (func)) + 4(type 1: (func -> i32))
        //   + 5(type 2: (func i32 i32 -> )) = 13
        0x01, 13, 3,
        0x60, 0x00, 0x00,
        0x60, 0x00, 0x01, 0x7f,
        0x60, 0x02, 0x7f, 0x7f, 0x00,
        // import section: 1 import — wasi:http/types@0.2.6 . [constructor]fields : (func -> i32)
        //   entry = 22(module: 1+21) + 20(field: 1+19) + 1(kind) + 1(typeidx) = 44
        //   body  = 1(count) + 44 = 45
        0x02, 45, 1,
        21, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 't', 'y', 'p', 'e', 's', '@', '0', '.', '2', '.', '6',
        19, '[', 'c', 'o', 'n', 's', 't', 'r', 'u', 'c', 't',
        'o', 'r', ']', 'f', 'i', 'e', 'l', 'd', 's',
        0x00, 1,
        // function section: 1 func of type 2 (the handle)
        0x03, 2, 1, 2,
        // export section: handle export (defined-func idx 1)
        //   entry = 40(name: 1+39) + 1(sort) + 1(idx) = 42
        //   body  = 1(count) + 42 = 43
        0x07, 43, 1,
        39, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 'i', 'n', 'c', 'o', 'm', 'i', 'n', 'g', '-',
        'h', 'a', 'n', 'd', 'l', 'e', 'r', '@', '0', '.',
        '2', '.', '6', '#', 'h', 'a', 'n', 'd', 'l', 'e',
        0x00, 1,
        // code section: 1 body (nop)
        0x0a, 4, 1, 2, 0x00, 0x0b,
    };

    const ct_payload = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package wasi:http@0.2.6;
        \\
        \\interface types {
        \\    resource fields {
        \\        constructor();
        \\    }
        \\    resource incoming-request {}
        \\    resource response-outparam {}
        \\}
        \\
        \\interface incoming-handler {
        \\    use types.{incoming-request, response-outparam};
        \\    handle: func(request: incoming-request, response-out: response-outparam);
        \\}
        \\
        \\world http-hello {
        \\    import types;
        \\    export incoming-handler;
        \\}
    , "http-hello");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:http-hello";
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // (1) Single instance-import for wasi:http/types@0.2.6, whose
    // instance-type body now includes a func-bound export for
    // `[constructor]fields` in addition to the three sub_resource
    // declarators #198 already verified.
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expectEqualStrings("wasi:http/types@0.2.6", loaded.imports[0].name);
    try testing.expect(loaded.imports[0].desc == .instance);
    const inst_type_idx = loaded.imports[0].desc.instance;
    const inst_contrib = loaded.type_indexspace[inst_type_idx];
    try testing.expect(inst_contrib == .type_def);
    const inst_td = loaded.types[inst_contrib.type_def];
    try testing.expect(inst_td == .instance);
    var saw_ctor_func_export = false;
    var saw_fields_sub = false;
    for (inst_td.instance.decls) |d| switch (d) {
        .@"export" => |e| switch (e.desc) {
            .type => |tb| if (tb == .sub_resource and std.mem.eql(u8, e.name, "fields")) {
                saw_fields_sub = true;
            },
            .func => if (std.mem.eql(u8, e.name, "[constructor]fields")) {
                saw_ctor_func_export = true;
            },
            else => {},
        },
        else => {},
    };
    try testing.expect(saw_fields_sub);
    try testing.expect(saw_ctor_func_export);

    // (2) A component-level alias pulls `[constructor]fields` into the
    // wrapping component's func indexspace, sourced from the types
    // import instance (component-instance idx 0).
    var saw_ctor_alias = false;
    for (loaded.aliases) |a| switch (a) {
        .instance_export => |ie| if (ie.sort == .func and
            std.mem.eql(u8, ie.name, "[constructor]fields") and
            ie.instance_idx == 0)
        {
            saw_ctor_alias = true;
        },
        else => {},
    };
    try testing.expect(saw_ctor_alias);

    // (3) Exactly one canon.lower (for the constructor) and one
    // canon.lift (for the handle export). The lower's func_idx must
    // resolve back to an imported func — i.e. it must point at a
    // component func indexspace slot whose contributor is an alias.
    var n_lower: usize = 0;
    var n_lift: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .lower => n_lower += 1,
        .lift => n_lift += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), n_lower);
    try testing.expectEqual(@as(usize, 1), n_lift);

    // (4) Two core instances: an inline-exports bundle (idx 0) and
    // the main instantiation (idx 1). The bundle exposes
    // `[constructor]fields` as a core func; the main carries one
    // `(with …)` arg sourcing it.
    try testing.expectEqual(@as(usize, 2), loaded.core_instances.len);
    try testing.expect(loaded.core_instances[0] == .exports);
    var saw_bundle_ctor = false;
    for (loaded.core_instances[0].exports) |ie| {
        if (std.mem.eql(u8, ie.name, "[constructor]fields") and ie.sort_idx.sort == .func) {
            saw_bundle_ctor = true;
        }
    }
    try testing.expect(saw_bundle_ctor);

    try testing.expect(loaded.core_instances[1] == .instantiate);
    const main_inst = loaded.core_instances[1].instantiate;
    try testing.expectEqual(@as(u32, 0), main_inst.module_idx);
    try testing.expectEqual(@as(usize, 1), main_inst.args.len);
    try testing.expectEqualStrings("wasi:http/types@0.2.6", main_inst.args[0].name);
    try testing.expectEqual(@as(u32, 0), main_inst.args[0].instance_idx);

    // (5) The handle export remains intact — Phase 3 still hooks the
    // exported func onto the main core instance (now idx 1, not 0).
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings(
        "wasi:http/incoming-handler@0.2.6",
        loaded.exports[0].name,
    );

    // (6) #203 regression: the #202 reproducer must keep using the
    // no-opts fast path — every canon.lower opts list is empty and
    // there's exactly 1 core module (no shim/fixup machinery).
    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    for (loaded.canons) |c| switch (c) {
        .lower => |l| try testing.expectEqual(@as(usize, 0), l.opts.len),
        else => {},
    };
}

test "buildComponent #203a: string/list params trigger shim+fixup + opts" {
    // Reproducer for #203: an imported method whose sig contains
    // `string` and `list` forces canon.lower to take memory +
    // realloc + string-encoding opts. The wrapping component emits
    // the shim+fixup trampoline pattern to break the
    // forward-reference cycle between canon.lower (which needs
    // main's memory/cabi_realloc exports) and main's instantiation
    // (which needs the lowered funcs as `(with …)` args).
    //
    // Synth core wasm: exports `wasi:http/incoming-handler@0.2.6#handle`
    // plus the `memory` + `cabi_realloc` exports the shim/fixup
    // path requires.
    const core_only = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 14, 2,
        0x60, 0x02, 0x7f, 0x7f, 0x00,
        0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
        0x03, 3, 2, 0, 1,
        0x05, 3, 1, 0x00, 0x01,
        0x07, 67, 3,
        39, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 'i', 'n', 'c', 'o', 'm', 'i', 'n', 'g', '-',
        'h', 'a', 'n', 'd', 'l', 'e', 'r', '@', '0', '.',
        '2', '.', '6', '#', 'h', 'a', 'n', 'd', 'l', 'e',
        0x00, 0,
        6, 'm', 'e', 'm', 'o', 'r', 'y',
        0x02, 0,
        12, 'c', 'a', 'b', 'i', '_', 'r', 'e', 'a', 'l', 'l', 'o', 'c',
        0x00, 1,
        0x0a, 9, 2,
        2, 0x00, 0x0b,
        4, 0x00, 0x41, 0x00, 0x0b,
    };

    const ct_payload = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package wasi:http@0.2.6;
        \\
        \\interface types {
        \\    resource fields {
        \\        constructor();
        \\        append: func(name: string, value: list<u8>) -> string;
        \\    }
        \\    resource incoming-request {}
        \\    resource response-outparam {}
        \\}
        \\
        \\interface incoming-handler {
        \\    use types.{incoming-request, response-outparam};
        \\    handle: func(request: incoming-request, response-out: response-outparam);
        \\}
        \\
        \\world http-hello {
        \\    import types;
        \\    export incoming-handler;
        \\}
    , "http-hello");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:http-hello";
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // (1) Three core modules: main, shim, fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);

    // (2) At least one canon.lower carries memory + realloc +
    // string_encoding opts. The constructor (handle-only) lowers
    // without opts; append takes `string` + `list<u8>` and returns
    // `string`, forcing all three.
    var saw_full_opts = false;
    var saw_string_encoding_utf8 = false;
    for (loaded.canons) |c| switch (c) {
        .lower => |l| {
            var has_memory = false;
            var has_realloc = false;
            var has_encoding = false;
            for (l.opts) |o| switch (o) {
                .memory => has_memory = true,
                .realloc => has_realloc = true,
                .string_encoding => |enc| {
                    has_encoding = true;
                    if (enc == .utf8) saw_string_encoding_utf8 = true;
                },
                else => {},
            };
            if (has_memory and has_realloc and has_encoding) saw_full_opts = true;
        },
        else => {},
    };
    try testing.expect(saw_full_opts);
    try testing.expect(saw_string_encoding_utf8);

    // (3) Core-instance topology: shim, per-iface bundle (1),
    // main, fixup-args bundle, fixup. With one funcful import
    // shape that's 5 entries total.
    try testing.expectEqual(@as(usize, 5), loaded.core_instances.len);
    try testing.expect(loaded.core_instances[0] == .instantiate);
    try testing.expectEqual(@as(u32, 1), loaded.core_instances[0].instantiate.module_idx);
    try testing.expect(loaded.core_instances[4] == .instantiate);
    try testing.expectEqual(@as(u32, 2), loaded.core_instances[4].instantiate.module_idx);

    // (4) The handle export survives intact.
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings(
        "wasi:http/incoming-handler@0.2.6",
        loaded.exports[0].name,
    );
}

test "buildComponent #203b: handle-only world stays on no-opts fast path" {
    // Verifies that a world whose imported funcs touch only handles
    // + primitives skips the shim/fixup machinery entirely. Same
    // WIT shape as the #202 reproducer but asserts the negative
    // side: no extra core modules, no extra core instances, no
    // canon.lower opts.
    const core_only = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 13, 3,
        0x60, 0x00, 0x00,
        0x60, 0x00, 0x01, 0x7f,
        0x60, 0x02, 0x7f, 0x7f, 0x00,
        0x02, 45, 1,
        21, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 't', 'y', 'p', 'e', 's', '@', '0', '.', '2', '.', '6',
        19, '[', 'c', 'o', 'n', 's', 't', 'r', 'u', 'c', 't',
        'o', 'r', ']', 'f', 'i', 'e', 'l', 'd', 's',
        0x00, 1,
        0x03, 2, 1, 2,
        0x07, 43, 1,
        39, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 'i', 'n', 'c', 'o', 'm', 'i', 'n', 'g', '-',
        'h', 'a', 'n', 'd', 'l', 'e', 'r', '@', '0', '.',
        '2', '.', '6', '#', 'h', 'a', 'n', 'd', 'l', 'e',
        0x00, 1,
        0x0a, 4, 1, 2, 0x00, 0x0b,
    };

    const ct_payload = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package wasi:http@0.2.6;
        \\
        \\interface types {
        \\    resource fields { constructor(); }
        \\    resource incoming-request {}
        \\    resource response-outparam {}
        \\}
        \\
        \\interface incoming-handler {
        \\    use types.{incoming-request, response-outparam};
        \\    handle: func(request: incoming-request, response-out: response-outparam);
        \\}
        \\
        \\world http-hello {
        \\    import types;
        \\    export incoming-handler;
        \\}
    , "http-hello");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:http-hello";
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    // Fast path emits: 1 inline-export bundle + 1 main = 2 core instances.
    try testing.expectEqual(@as(usize, 2), loaded.core_instances.len);
    // No canon.lower opts: handle-only sigs.
    for (loaded.canons) |c| switch (c) {
        .lower => |l| try testing.expectEqual(@as(usize, 0), l.opts.len),
        else => {},
    };
}

test "buildComponent #203c: shim/fixup needed but core lacks memory export → error" {
    // Same WIT as #203a (forces shim/fixup), but the synth core
    // wasm omits both `memory` and `cabi_realloc`. The classifier
    // routes to the shim/fixup path, which then can't satisfy its
    // memory/realloc opts and must surface a clear error rather
    // than silently emitting unwirable canon.lower entries.
    const core_only = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 43, 0x01,
        39, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 'i', 'n', 'c', 'o', 'm', 'i', 'n', 'g', '-',
        'h', 'a', 'n', 'd', 'l', 'e', 'r', '@', '0', '.',
        '2', '.', '6', '#', 'h', 'a', 'n', 'd', 'l', 'e',
        0x00, 0x00,
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };

    const ct_payload = try metadata_encode.encodeWorldFromSource(testing.allocator,
        \\package wasi:http@0.2.6;
        \\
        \\interface types {
        \\    resource fields {
        \\        constructor();
        \\        append: func(name: string, value: list<u8>) -> string;
        \\    }
        \\    resource incoming-request {}
        \\    resource response-outparam {}
        \\}
        \\
        \\interface incoming-handler {
        \\    use types.{incoming-request, response-outparam};
        \\    handle: func(request: incoming-request, response-out: response-outparam);
        \\}
        \\
        \\world http-hello {
        \\    import types;
        \\    export incoming-handler;
        \\}
    , "http-hello");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:http-hello";
    var cs_body = std.ArrayListUnmanaged(u8).empty;
    defer cs_body.deinit(testing.allocator);
    try writeU32Leb(testing.allocator, &cs_body, @intCast(cs_name.len));
    try cs_body.appendSlice(testing.allocator, cs_name);
    try cs_body.appendSlice(testing.allocator, ct_payload);
    try core_with_ct.append(testing.allocator, 0);
    try writeU32Leb(testing.allocator, &core_with_ct, @intCast(cs_body.items.len));
    try core_with_ct.appendSlice(testing.allocator, cs_body.items);

    try testing.expectError(
        error.MissingCoreExportMemory,
        buildComponent(testing.allocator, core_with_ct.items),
    );
}

test "buildComponent #195p5: canonical wasi-http proxy world e2e" {
    // Phase 5 acceptance for #195: pointing wabt at the canonical
    // wasi-http@0.2.6 WIT layout + a Zig stub exporting
    // `wasi:http/incoming-handler@0.2.6#handle` round-trips through
    // metadata_encode (with include expansion + implicit imports +
    // type topo-sort) and buildComponent (with resource hoisting,
    // #199) into a binary whose component-level type indexspace is
    // sound.
    //
    // The vendored canonical files live at src/component/wit/wasi-canon/
    // (added in #200 / Phase 1). We assemble a temp WIT tree at test
    // time and drive the embed + new pipeline against a synthesised
    // core wasm exporting the proxy world's lifted func.
    const wit_resolver = wabt.component.wit.resolver;
    const wit_encode = wabt.component.wit.metadata_encode;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const alloc = ar.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    try tmp.dir.createDirPath(io, "wit");
    try tmp.dir.createDirPath(io, "wit/deps");

    const pkgs = [_]struct { src_dir: []const u8, dst_rel: []const u8 }{
        .{ .src_dir = "src/component/wit/wasi-canon/http", .dst_rel = "wit" },
        .{ .src_dir = "src/component/wit/wasi-canon/cli", .dst_rel = "wit/deps/cli" },
        .{ .src_dir = "src/component/wit/wasi-canon/clocks", .dst_rel = "wit/deps/clocks" },
        .{ .src_dir = "src/component/wit/wasi-canon/filesystem", .dst_rel = "wit/deps/filesystem" },
        .{ .src_dir = "src/component/wit/wasi-canon/io", .dst_rel = "wit/deps/io" },
        .{ .src_dir = "src/component/wit/wasi-canon/random", .dst_rel = "wit/deps/random" },
        .{ .src_dir = "src/component/wit/wasi-canon/sockets", .dst_rel = "wit/deps/sockets" },
    };
    for (pkgs) |pkg| {
        try tmp.dir.createDirPath(io, pkg.dst_rel);
        var src = try cwd.openDir(io, pkg.src_dir, .{ .iterate = true });
        defer src.close(io);
        var it = src.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wit")) continue;
            const src_path = try std.fs.path.join(alloc, &.{ pkg.src_dir, entry.name });
            const buf = try cwd.readFileAlloc(io, src_path, alloc, std.Io.Limit.limited(1 << 20));
            const dst_path = try std.fs.path.join(alloc, &.{ pkg.dst_rel, entry.name });
            try tmp.dir.writeFile(io, .{ .sub_path = dst_path, .data = buf });
        }
    }

    const tmp_wit = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/wit", .{tmp.sub_path});
    const res = try wit_resolver.parseLayout(alloc, io, tmp_wit);

    // Encode the proxy world's component-type metadata.
    const ct_payload = try wit_encode.encodeWorldFromResolver(testing.allocator, res, "proxy");
    defer testing.allocator.free(ct_payload);
    try testing.expect(ct_payload.len > 0);

    // Synthesise a core wasm exporting
    // `wasi:http/incoming-handler@0.2.6#handle (i32, i32) -> ()`
    // plus the `memory` + `cabi_realloc` exports any wasi:p2
    // proxy ships, since wasi:http's imported methods take
    // `string`/`list` args and so trip the #203 shim/fixup
    // emission path which canon.lower's against both.
    const core_only = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 2 types
        //   type 0: (func i32 i32) -> ()             — handle
        //   type 1: (func i32 i32 i32 i32) -> i32    — cabi_realloc
        0x01, 14, 2,
        0x60, 0x02, 0x7f, 0x7f, 0x00,
        0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
        // function section: 2 funcs
        0x03, 3, 2, 0, 1,
        // memory section: 1 memory, initial=1 page, no max
        0x05, 3, 1, 0x00, 0x01,
        // export section: handle, memory, cabi_realloc
        //   body = 1(count) + 42(handle) + 9(memory) + 15(cabi) = 67
        0x07, 67, 3,
        39, 'w', 'a', 's', 'i', ':', 'h', 't', 't', 'p',
        '/', 'i', 'n', 'c', 'o', 'm', 'i', 'n', 'g', '-',
        'h', 'a', 'n', 'd', 'l', 'e', 'r', '@', '0', '.',
        '2', '.', '6', '#', 'h', 'a', 'n', 'd', 'l', 'e',
        0x00, 0,
        6, 'm', 'e', 'm', 'o', 'r', 'y',
        0x02, 0,
        12, 'c', 'a', 'b', 'i', '_', 'r', 'e', 'a', 'l', 'l', 'o', 'c',
        0x00, 1,
        // code section: 2 bodies
        //   handle:        size=2, locals=0, end
        //   cabi_realloc:  size=4, locals=0, i32.const 0, end
        0x0a, 9, 2,
        2, 0x00, 0x0b,
        4, 0x00, 0x41, 0x00, 0x0b,
    };
    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:proxy";
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
    try testing.expect(comp_bytes.len > 0);

    // The wrapping component must parse cleanly. Validators
    // (wasm-tools) accept this binary in interactive runs; this
    // in-process check uses the wabt loader as a smoke-test
    // proxy to keep the test self-contained.
    const loaded = try loader.load(comp_bytes, alloc);
    try testing.expect(loaded.imports.len >= 1);
    try testing.expect(loaded.exports.len >= 1);
    // The exported instance must be the proxy world's
    // incoming-handler export.
    var saw_export = false;
    for (loaded.exports) |e| {
        if (std.mem.indexOf(u8, e.name, "wasi:http/incoming-handler@0.2.6") != null) {
            saw_export = true;
            break;
        }
    }
    try testing.expect(saw_export);
}

test "buildComponent: rejects core wasm without component-type section" {
    const bare = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    try testing.expectError(error.MissingComponentTypeSection, buildComponent(testing.allocator, &bare));
}

test "coreImportsModule: detects wasi_snapshot_preview1 import" {
    // Hand-rolled core wasm: 1 type `(func)`, 1 import
    // `wasi_snapshot_preview1.fd_write` of that type. Import section
    // body is: count(1) + LEB(22)+"wasi_snapshot_preview1"(22) +
    // LEB(8)+"fd_write"(8) + kind(1) + typeidx(1) = 35 bytes = 0x23.
    const core = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        // type section: 1 type — (func)
        0x01, 0x04,
        0x01,
        0x60, 0x00, 0x00,
        // import section: 1 import — wasi_snapshot_preview1.fd_write (func type 0)
        0x02, 0x23,
        0x01,
        22, 'w', 'a', 's', 'i', '_', 's', 'n', 'a', 'p', 's', 'h', 'o', 't', '_', 'p', 'r', 'e', 'v', 'i', 'e', 'w', '1',
        8, 'f', 'd', '_', 'w', 'r', 'i', 't', 'e',
        0x00, 0x00,
    };
    try testing.expect(coreImportsModule(testing.allocator, &core, "wasi_snapshot_preview1"));
    try testing.expect(!coreImportsModule(testing.allocator, &core, "env"));
}

test "coreImportsModule: bare core with no imports returns false" {
    const bare = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    try testing.expect(!coreImportsModule(testing.allocator, &bare, "wasi_snapshot_preview1"));
}

test "coreImportsModule: malformed input returns false (no crash)" {
    const garbage = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try testing.expect(!coreImportsModule(testing.allocator, &garbage, "wasi_snapshot_preview1"));
}

test "userSuppliedAdapter: detects matching name" {
    const adapts = [_]AdapterSpec{
        .{ .name = "other", .file = "x.wasm" },
        .{ .name = "wasi_snapshot_preview1", .file = "y.wasm" },
    };
    try testing.expect(userSuppliedAdapter(&adapts, "wasi_snapshot_preview1"));
    try testing.expect(!userSuppliedAdapter(&adapts, "missing"));
    try testing.expect(!userSuppliedAdapter(&[_]AdapterSpec{}, "wasi_snapshot_preview1"));
}

test "builtin_adapter: embedded adapter wasm is a valid wasm preamble" {
    const bytes = builtin_adapter.wasi_preview1_command_wasm;
    try testing.expect(bytes.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "builtin_adapter: embedded reactor adapter wasm is a valid wasm preamble" {
    const bytes = builtin_adapter.wasi_preview1_reactor_wasm;
    try testing.expect(bytes.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "builtin_adapter: command artifact's encoded world declares wasi:cli/run export" {
    const adapter_decode = wabt.component.adapter.decode;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const world = try adapter_decode.parseFromAdapterCore(
        arena.allocator(),
        builtin_adapter.wasi_preview1_command_wasm,
    );
    // Command shape: exactly one export — `wasi:cli/run@0.2.6` —
    // since the wrapping component lifts the adapter's `$run` body
    // into a top-level `wasi:cli/run` instance.
    try testing.expectEqual(@as(usize, 1), world.exports.len);
    try testing.expect(std.mem.startsWith(u8, world.exports[0].name, "wasi:cli/run@"));
}

test "builtin_adapter: reactor artifact's encoded world declares no exports (no wasi:cli/run)" {
    const adapter_decode = wabt.component.adapter.decode;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const world = try adapter_decode.parseFromAdapterCore(
        arena.allocator(),
        builtin_adapter.wasi_preview1_reactor_wasm,
    );
    // Reactor shape: the wrapping component lifts the embed's own
    // exports directly (e.g. `wasi:http/incoming-handler.handle`),
    // so the adapter declares no `wasi:cli/run` (or any other)
    // export. Tracked under cataggar/wabt#167.
    try testing.expectEqual(@as(usize, 0), world.exports.len);
}

test "builtin_adapter: reactor world imports the same preview2 surface as command (minus the run export)" {
    const adapter_decode = wabt.component.adapter.decode;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cmd_world = try adapter_decode.parseFromAdapterCore(
        arena.allocator(),
        builtin_adapter.wasi_preview1_command_wasm,
    );
    const rx_world = try adapter_decode.parseFromAdapterCore(
        arena.allocator(),
        builtin_adapter.wasi_preview1_reactor_wasm,
    );

    // Same import count + same import names in the same order.
    // `world reactor` in `preview1.wit` mirrors `world command`
    // verbatim (minus the trailing `export wasi:cli/run@0.2.6;`),
    // so the encoded world's import surface must match byte-for-byte.
    try testing.expectEqual(cmd_world.imports.len, rx_world.imports.len);
    for (cmd_world.imports, rx_world.imports) |c, r| {
        try testing.expectEqualStrings(c.name, r.name);
    }
}

test "probeStartExport: core with `_start` func export -> .yes" {
    // Hand-rolled core wasm:
    //   - type 0: (func)
    //   - 1 func (typeidx 0)
    //   - export "_start" func 0
    //   - code: 1 body, empty (just `end`)
    const core = [_]u8{
        // preamble
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: 1 type — (func)
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function section: 1 func, type 0
        0x03, 0x02, 0x01, 0x00,
        // export section: 1 export — "_start" func 0
        0x07, 0x0a, 0x01, 6, '_', 's', 't', 'a', 'r', 't', 0x00, 0x00,
        // code section: 1 body — `(end)`
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    try testing.expectEqual(StartExportProbe.yes, probeStartExport(testing.allocator, &core));
}

test "probeStartExport: core without `_start` export -> .no" {
    // Same shape as above but exports `other` instead of `_start`.
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x09, 0x01, 5, 'o', 't', 'h', 'e', 'r', 0x00, 0x00,
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    try testing.expectEqual(StartExportProbe.no, probeStartExport(testing.allocator, &core));
}

test "probeStartExport: bare core wasm preamble -> .no" {
    const bare = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
    };
    try testing.expectEqual(StartExportProbe.no, probeStartExport(testing.allocator, &bare));
}

test "probeStartExport: malformed input -> .parse_error" {
    const garbage = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try testing.expectEqual(StartExportProbe.parse_error, probeStartExport(testing.allocator, &garbage));
}

test "pickBuiltinAdapter: command core selects command-shape adapter" {
    // Re-use the `_start` export fixture from probeStartExport.
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x0a, 0x01, 6, '_', 's', 't', 'a', 'r', 't', 0x00, 0x00,
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    const picked = pickBuiltinAdapter(testing.allocator, &core);
    try testing.expectEqual(builtin_adapter.wasi_preview1_command_wasm.ptr, picked.ptr);
}

test "pickBuiltinAdapter: reactor core (no _start) selects reactor-shape adapter" {
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x09, 0x01, 5, 'o', 't', 'h', 'e', 'r', 0x00, 0x00,
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    const picked = pickBuiltinAdapter(testing.allocator, &core);
    try testing.expectEqual(builtin_adapter.wasi_preview1_reactor_wasm.ptr, picked.ptr);
}

test "pickBuiltinAdapter: malformed core falls back to command-shape adapter" {
    const garbage = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const picked = pickBuiltinAdapter(testing.allocator, &garbage);
    try testing.expectEqual(builtin_adapter.wasi_preview1_command_wasm.ptr, picked.ptr);
}
