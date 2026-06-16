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
const lift_types = wabt.component.wit.lift_types;

pub const usage =
    \\Usage: wabt component new [options] <core.wasm>
    \\
    \\Wrap a core wasm module into a top-level WebAssembly component.
    \\
    \\The core must carry `component-type:<world>` metadata. Provide it
    \\either by:
    \\  * letting `component new` embed it on the fly from a WIT package
    \\    — `--wit <path>`, or a `wit/` directory in the cwd if present —
    \\    collapsing `wabt component embed` + `wabt component new` into a
    \\    single call; or
    \\  * pre-embedding with `wabt component embed` (or
    \\    `wasm-tools component embed`) and passing a core that already
    \\    has the section (no WIT path / no `wit/` directory).
    \\
    \\Options:
    \\  -o, --output <file>     Output file. Default: `<name>.wasm` when the
    \\                          input is `<name>.core.wasm`, else
    \\                          `<input>.component.wasm`.
    \\      --wit <path>        WIT package to embed (a `.wit` file or a
    \\                          directory). Defaults to `wit/` in the cwd
    \\                          when that directory exists.
    \\  -w, --world <name>      World to embed from the WIT. Required only
    \\                          when the WIT defines more than one world; with
    \\                          exactly one world it is selected automatically.
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
    var world_arg: ?[]const u8 = null;
    var wit_arg: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--wit")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            wit_arg = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--world")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            world_arg = sub_args[i];
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
                std.debug.print("error: unexpected positional argument '{s}'. Use `wabt component new help`.\n", .{arg});
                std.process.exit(1);
            }
            input_path = arg;
        }
    }

    const in_path = input_path orelse {
        std.debug.print("error: component new requires <core.wasm>. Use `wabt component new help`.\n", .{});
        std.process.exit(1);
    };

    // Resolve the WIT path to embed from (collapsing `component embed`
    // + `component new` into one call): use `--wit <path>` when given,
    // else default to a `wit/` directory in the cwd if one exists.
    // When neither resolves, the core is assumed to already carry a
    // `component-type:<world>` section (the pre-embedded path).
    const default_wit_dir = "wit";
    const wit_path: ?[]const u8 = wit_arg orelse blk: {
        const stat = std.Io.Dir.cwd().statFile(init.io, default_wit_dir, .{}) catch break :blk null;
        if (stat.kind == .directory) break :blk default_wit_dir;
        break :blk null;
    };

    if (wit_path == null and world_arg != null) {
        std.debug.print("error: --world set but no WIT to embed from (pass --wit <path> or add a 'wit/' directory).\n", .{});
        std.process.exit(1);
    }

    const raw_core_bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        in_path,
        alloc,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(raw_core_bytes);

    // When a WIT path is resolved, embed the `component-type:<world>`
    // section first (the same work `wabt component embed` does), so a
    // plain core compiled by zig/etc. can be turned into a component
    // in a single call.
    const embedded_owned: ?[]u8 = if (wit_path) |wp|
        embedWorld(init, alloc, wp, world_arg, raw_core_bytes)
    else
        null;
    defer if (embedded_owned) |b| alloc.free(b);
    const core_bytes: []const u8 = embedded_owned orelse raw_core_bytes;

    const out_path = output_file orelse blk: {
        // A `<name>.core.wasm` input yields `<name>.wasm` — the core
        // and component are the same artifact minus the `.core` tag.
        if (std.mem.endsWith(u8, in_path, ".core.wasm")) {
            const stem = in_path[0 .. in_path.len - ".core.wasm".len];
            break :blk std.fmt.allocPrint(alloc, "{s}.wasm", .{stem}) catch in_path;
        }
        if (std.mem.endsWith(u8, in_path, ".wasm")) {
            const stem = in_path[0 .. in_path.len - 5];
            break :blk std.fmt.allocPrint(alloc, "{s}.component.wasm", .{stem}) catch in_path;
        }
        break :blk std.fmt.allocPrint(alloc, "{s}.component.wasm", .{in_path}) catch in_path;
    };
    // Free the derived default path (skip when it's `output_file`, which
    // we borrow, or the `catch in_path` OOM fallback).
    defer if (output_file == null and out_path.ptr != in_path.ptr) alloc.free(out_path);

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

/// Embed a `component-type:<world>` custom section into `core_bytes`
/// from the WIT at `wit_path` — the same work `wabt component embed`
/// does, so `component new` can wrap a plain core in one call. The
/// world is `world_arg` when given, else the WIT's sole world (an
/// informative error is printed if zero or multiple worlds exist).
/// Returns freshly-allocated embedded bytes; exits on error.
fn embedWorld(
    init: std.process.Init,
    alloc: std.mem.Allocator,
    wit_path: []const u8,
    world_arg: ?[]const u8,
    core_bytes: []const u8,
) []u8 {
    const wit = wabt.component.wit;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const resolver = wit.resolver.parseLayout(ar, init.io, wit_path) catch |err| {
        std.debug.print("error: parsing WIT layout '{s}': {s}\n", .{ wit_path, @errorName(err) });
        std.process.exit(1);
    };

    const world_name = world_arg orelse blk: {
        if (wit.embed.autoselectWorld(resolver.main)) |name| break :blk name;
        const names = wit.embed.worldNames(ar, resolver.main) catch &.{};
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
            for (names, 0..) |n, idx| {
                if (idx != 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{n});
            }
            std.debug.print("\n", .{});
        }
        std.process.exit(1);
    };

    var ediag: wit.metadata_encode.EncodeDiagnostic = .{};
    const ct_payload = wit.metadata_encode.encodeWorldFromResolverWithDiag(alloc, resolver, world_name, &ediag) catch |err| {
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

    const section_name = std.fmt.allocPrint(alloc, "component-type:{s}", .{world_name}) catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer alloc.free(section_name);

    return wit.embed.embedCustomSection(alloc, core_bytes, section_name, ct_payload) catch |err| {
        std.debug.print("error: embedding world '{s}': {s}\n", .{ world_name, @errorName(err) });
        std.process.exit(1);
    };
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

/// A wired import's name plus the canonical-ABI core signature its
/// `canon.lower` is guaranteed to produce. `module` is the import
/// instance's qualified name (e.g. `wasi:http/types@0.2.6`); `field`
/// is the canonical method-encoded func name (e.g.
/// `[static]response-outparam.set`).
const ExpectedImportSig = struct {
    module: []const u8,
    field: []const u8,
    params: []const wabt.types.ValType,
    results: []const wabt.types.ValType,
};

/// Validate that the guest core module's declared import signature for
/// each wired func matches the canonical-ABI lowering wabt provides for
/// it. A mismatch means the produced component cannot link on a
/// spec-compliant host (e.g. wasmtime rejects it at load with a core
/// type mismatch), so fail early with an actionable diagnostic instead
/// of emitting a component that only crashes at runtime. See #244: a
/// guest that flattens an `error-code`-bearing import without the
/// canonical `i64` widening trips exactly this check.
fn validateGuestImportSigs(
    gpa: std.mem.Allocator,
    core_bytes: []const u8,
    expected: []const ExpectedImportSig,
) !void {
    if (expected.len == 0) return;
    var owned = core_imports.extract(gpa, core_bytes) catch return;
    defer owned.deinit();
    for (expected) |e| {
        const declared = findDeclaredImportSig(owned.interface, e.module, e.field) orelse continue;
        if (valTypesEql(declared.params, e.params) and valTypesEql(declared.results, e.results)) continue;
        printImportSigMismatch(e, declared);
        return error.CoreImportSignatureMismatch;
    }
}

fn findDeclaredImportSig(
    iface: core_imports.CoreInterface,
    module: []const u8,
    field: []const u8,
) ?core_imports.FuncSig {
    for (iface.imports) |im| {
        if (im.kind == .func and im.sig != null and
            std.mem.eql(u8, im.module_name, module) and
            std.mem.eql(u8, im.field_name, field))
            return im.sig.?;
    }
    return null;
}

fn valTypesEql(a: []const wabt.types.ValType, b: []const wabt.types.ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn debugPrintCoreSig(params: []const wabt.types.ValType, results: []const wabt.types.ValType) void {
    std.debug.print("(func", .{});
    for (params) |p| std.debug.print(" (param {s})", .{@tagName(p)});
    for (results) |r| std.debug.print(" (result {s})", .{@tagName(r)});
    std.debug.print(")", .{});
}

fn printImportSigMismatch(e: ExpectedImportSig, declared: core_imports.FuncSig) void {
    std.debug.print(
        "error: core import signature mismatch for `{s}` of `{s}`\n  expected (canonical ABI lowering): ",
        .{ e.field, e.module },
    );
    debugPrintCoreSig(e.params, e.results);
    std.debug.print("\n  found (declared by core module):   ", .{});
    debugPrintCoreSig(declared.params, declared.results);
    std.debug.print(
        "\n  hint: the core module's guest bindings flatten this import incorrectly; " ++
            "regenerate them so the signature matches the canonical ABI.\n",
        .{},
    );
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

// ── Resource built-in intrinsic imports (cataggar/wabt#248) ─────────
//
// A guest core module can import the canonical resource built-ins
// directly, e.g.
//   (import "wasi:io/streams@0.2.6" "[resource-drop]output-stream"
//           (func (param i32)))
// These are NOT WIT-declared methods (they never appear in
// `ext.funcs`), so the normal method-wiring path leaves them dangling
// and the produced component is rejected at instantiation
// ("does not export an item named `[resource-drop]output-stream`").
// We recognise them and wire each to a
// `canon resource.{drop,new,rep} <resource-type>` placed in the same
// import bundle, exactly as wit-component / wasm-tools do.

const IntrinsicKind = enum { drop, new, rep };

const ResourceIntrinsic = struct {
    /// Import module name == the bundle key fed to the main core
    /// module's `(with …)` arg.
    module: []const u8,
    /// Full canonical field name (e.g. `[resource-drop]output-stream`)
    /// — used verbatim as the bundle's inline-export name so it
    /// satisfies the guest's core import.
    field: []const u8,
    /// Bare resource name (e.g. `output-stream`).
    resource: []const u8,
    kind: IntrinsicKind,
};

/// Classify a core import field name as a resource built-in intrinsic.
/// Returns null for ordinary names and the method-encoded forms
/// (`[method]…`, `[static]…`, `[constructor]…`) which are real WIT
/// funcs handled by the normal wiring path.
fn classifyResourceIntrinsic(field: []const u8) ?struct {
    kind: IntrinsicKind,
    resource: []const u8,
} {
    const Pre = struct { p: []const u8, k: IntrinsicKind };
    const pres = [_]Pre{
        .{ .p = "[resource-drop]", .k = .drop },
        .{ .p = "[resource-new]", .k = .new },
        .{ .p = "[resource-rep]", .k = .rep },
    };
    for (pres) |pre| {
        if (std.mem.startsWith(u8, field, pre.p)) {
            return .{ .kind = pre.k, .resource = field[pre.p.len..] };
        }
    }
    return null;
}

/// Scan the guest core module's imports for resource built-in
/// intrinsics. Returns `ar`-owned copies. A core that fails to parse
/// yields an empty list (the downstream loader surfaces the real
/// error).
fn collectResourceIntrinsics(
    ar: std.mem.Allocator,
    core_bytes: []const u8,
) ![]const ResourceIntrinsic {
    const owned = core_imports.extract(ar, core_bytes) catch return &.{};
    var list = std.ArrayListUnmanaged(ResourceIntrinsic).empty;
    for (owned.interface.imports) |im| {
        if (im.kind != .func) continue;
        const c = classifyResourceIntrinsic(im.field_name) orelse continue;
        try list.append(ar, .{
            .module = try ar.dupe(u8, im.module_name),
            .field = try ar.dupe(u8, im.field_name),
            .resource = try ar.dupe(u8, c.resource),
            .kind = c.kind,
        });
    }
    return list.toOwnedSlice(ar);
}

/// The canonical-ABI core signature a resource built-in intrinsic
/// import must have (#251). All take the rep/handle `i32`; `new` and
/// `rep` also return an `i32`, `drop` returns nothing.
fn intrinsicExpectedSig(it: ResourceIntrinsic) ExpectedImportSig {
    const param_i32 = &[_]wabt.types.ValType{.i32};
    const result_i32 = &[_]wabt.types.ValType{.i32};
    const no_results = &[_]wabt.types.ValType{};
    return .{
        .module = it.module,
        .field = it.field,
        .params = param_i32,
        .results = if (it.kind == .drop) no_results else result_i32,
    };
}

/// Validate each resource intrinsic import's declared core signature
/// against its fixed canonical-ABI shape, reusing the #244 diagnostic.
/// A mismatch (e.g. `[resource-drop]<R>` declared with a result) means
/// the produced component can't link on a spec host, so fail early.
fn validateResourceIntrinsicSigs(
    alloc: std.mem.Allocator,
    ar: std.mem.Allocator,
    core_bytes: []const u8,
    intrinsics: []const ResourceIntrinsic,
) !void {
    if (intrinsics.len == 0) return;
    var expected = std.ArrayListUnmanaged(ExpectedImportSig).empty;
    for (intrinsics) |it| try expected.append(ar, intrinsicExpectedSig(it));
    try validateGuestImportSigs(alloc, core_bytes, expected.items);
}

/// A resource intrinsic resolved against the world's imports: which
/// import instance provides the resource type (the `alias
/// instance_export sort=type` source the canon operand needs).
const ResolvedIntrinsic = struct {
    field: []const u8,
    resource: []const u8,
    kind: IntrinsicKind,
    /// Component-instance index of the import that declares `resource`
    /// as a sub_resource.
    owner_inst_idx: u32,
};

/// Group resource intrinsics by the import shape whose qualified name
/// equals the intrinsic's module (the bundle that feeds the main core
/// module under that name). Validates that the bundle namespace is an
/// imported interface and that the named resource is provided by some
/// imported interface; otherwise fails with an actionable error (#248
/// decision: hard error, never silently leave the import dangling).
fn resolveResourceIntrinsicsByShape(
    ar: std.mem.Allocator,
    intrinsics: []const ResourceIntrinsic,
    shape_qnames: []const []const u8,
    resource_owner: *const std.StringHashMapUnmanaged([]const u8),
    import_inst_idx_for: *const std.StringHashMapUnmanaged(u32),
) ![]const []const ResolvedIntrinsic {
    var by_shape = try ar.alloc(std.ArrayListUnmanaged(ResolvedIntrinsic), shape_qnames.len);
    for (by_shape) |*l| l.* = .empty;
    for (intrinsics) |it| {
        var shape_idx: ?usize = null;
        for (shape_qnames, 0..) |q, i| {
            if (std.mem.eql(u8, q, it.module)) {
                shape_idx = i;
                break;
            }
        }
        const si = shape_idx orelse {
            std.debug.print(
                "error: core import `{s}` of `{s}` is a resource intrinsic, " ++
                    "but `{s}` is not an imported interface in the world\n",
                .{ it.field, it.module, it.module },
            );
            return error.UnresolvedResourceIntrinsic;
        };
        const owner_qname = resource_owner.get(it.resource) orelse {
            std.debug.print(
                "error: core import `{s}` of `{s}` references resource `{s}`, " ++
                    "which no imported interface in the world provides\n",
                .{ it.field, it.module, it.resource },
            );
            return error.UnresolvedResourceIntrinsic;
        };
        const owner_inst_idx = import_inst_idx_for.get(owner_qname) orelse {
            std.debug.print(
                "error: core import `{s}` of `{s}` references resource `{s}`, " ++
                    "whose providing interface `{s}` was not wired as an import instance\n",
                .{ it.field, it.module, it.resource, owner_qname },
            );
            return error.UnresolvedResourceIntrinsic;
        };
        try by_shape[si].append(ar, .{
            .field = it.field,
            .resource = it.resource,
            .kind = it.kind,
            .owner_inst_idx = owner_inst_idx,
        });
    }
    var out = try ar.alloc([]const ResolvedIntrinsic, shape_qnames.len);
    for (by_shape, 0..) |*l, i| out[i] = try l.toOwnedSlice(ar);
    return out;
}

fn canonForIntrinsic(kind: IntrinsicKind, type_idx: u32) ctypes.Canon {
    return switch (kind) {
        .drop => .{ .resource_drop = type_idx },
        .new => .{ .resource_new = type_idx },
        .rep => .{ .resource_rep = type_idx },
    };
}

// ── Guest-implemented (exported) resources (cataggar/wabt#250) ──────
//
// A guest core module can *define* a resource exported by one of its
// interfaces. Then it:
//   * exports a destructor core func `<iface>#[dtor]<resource>` (only
//     when the WIT resource declares one), and
//   * imports the canonical built-ins it uses to manage its own
//     handles — `[resource-new]<R>` / `[resource-rep]<R>` /
//     `[resource-drop]<R>` — from the module `[export]<iface>`.
// The wrapping component must declare the exported resource type
// (with its destructor wired through the shim so the host can call
// back into the guest), export it from the interface instance, and
// satisfy those `[export]…` intrinsic imports with `canon
// resource.{new,rep,drop}` referencing the *exported* resource type.
// Matches `wit-component` / `wasm-tools` (see validation.rs
// `match_wit_resource_dtor`, encoding.rs `ShimKind::ResourceDtor`).

/// Module-name prefix a guest uses for intrinsics that operate on a
/// resource it exports (e.g. `[export]docs:demo/i@0.1.0`).
const export_intrinsic_prefix = "[export]";

/// A resource defined by an exported interface of the guest.
const ExportedResource = struct {
    /// Qualified name of the exporting interface (the export
    /// instance's name, e.g. `docs:demo/i@0.1.0`).
    ext_qualified: []const u8,
    /// Bare resource WIT name (e.g. `thing`).
    name: []const u8,
    /// Core-export name of the guest's destructor, or null when the
    /// resource declares no destructor.
    dtor_export: ?[]const u8,
};

/// True iff the core module exports a *func* named `name`. Scans the
/// export section only; a parse failure is reported (callers gate on
/// it for dtor detection where a missing export simply means "no
/// destructor").
fn coreExportsFunc(core_bytes: []const u8, name: []const u8) !bool {
    if (core_bytes.len < 8) return error.InvalidCoreModule;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidCoreModule;

    var i: usize = 8;
    while (i < core_bytes.len) {
        const id = core_bytes[i];
        i += 1;
        const sz = try readU32Leb(core_bytes, i);
        i += sz.bytes_read;
        if (i + sz.value > core_bytes.len) return error.InvalidCoreModule;
        const body = core_bytes[i .. i + sz.value];
        i += sz.value;
        if (id != 7) continue; // export section

        var p: usize = 0;
        const n = try readU32Leb(body, p);
        p += n.bytes_read;
        var k: u32 = 0;
        while (k < n.value) : (k += 1) {
            const nl = try readU32Leb(body, p);
            p += nl.bytes_read;
            if (p + nl.value > body.len) return error.InvalidCoreModule;
            const ename = body[p .. p + nl.value];
            p += nl.value;
            if (p >= body.len) return error.InvalidCoreModule;
            const kind = body[p];
            p += 1;
            const idx = try readU32Leb(body, p);
            p += idx.bytes_read;
            if (kind == 0 and std.mem.eql(u8, ename, name)) return true;
        }
        break;
    }
    return false;
}

/// Collect every resource defined by an exported interface, detecting
/// each one's guest-exported destructor (if any). `ar`-owned copies.
fn collectExportedResources(
    ar: std.mem.Allocator,
    decoded: metadata_decode.DecodedWorld,
    stripped_core: []const u8,
) ![]const ExportedResource {
    var list = std.ArrayListUnmanaged(ExportedResource).empty;
    for (decoded.externs) |ext| {
        if (!ext.is_export) continue;
        for (ext.type_slots) |slot| switch (slot) {
            .sub_resource => |name| {
                const dtor_name = try std.fmt.allocPrint(
                    ar,
                    "{s}#[dtor]{s}",
                    .{ ext.qualified_name, name },
                );
                const has_dtor = coreExportsFunc(stripped_core, dtor_name) catch false;
                try list.append(ar, .{
                    .ext_qualified = ext.qualified_name,
                    .name = try ar.dupe(u8, name),
                    .dtor_export = if (has_dtor) dtor_name else null,
                });
            },
            else => {},
        };
    }
    return list.toOwnedSlice(ar);
}

/// One resource built-in intrinsic that operates on a guest-exported
/// resource (`[export]<iface>` module). Grouped by `module` so each
/// distinct `(with "[export]<iface>" …)` arg gets one bundle.
const ExportSideIntrinsic = struct {
    /// Full `[export]<iface>` module name — the `(with …)` arg key.
    module: []const u8,
    /// Canonical field name (e.g. `[resource-new]thing`).
    field: []const u8,
    /// Bare resource name (e.g. `thing`).
    resource: []const u8,
    kind: IntrinsicKind,
};

/// Partition collected intrinsics into import-side (resolved against
/// imported interfaces by the existing `resolveResourceIntrinsicsByShape`)
/// and export-side (`[export]<iface>` module, operating on a
/// guest-exported resource). Export-side intrinsics must name a
/// resource that some exported interface defines; otherwise it is a
/// hard error (never leave the guest import dangling).
fn partitionResourceIntrinsics(
    ar: std.mem.Allocator,
    intrinsics: []const ResourceIntrinsic,
    exported: []const ExportedResource,
) !struct {
    import_side: []const ResourceIntrinsic,
    export_side: []const ExportSideIntrinsic,
} {
    var imp = std.ArrayListUnmanaged(ResourceIntrinsic).empty;
    var exp = std.ArrayListUnmanaged(ExportSideIntrinsic).empty;
    for (intrinsics) |it| {
        if (std.mem.startsWith(u8, it.module, export_intrinsic_prefix)) {
            var found = false;
            for (exported) |er| {
                if (std.mem.eql(u8, er.name, it.resource)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print(
                    "error: core import `{s}` of `{s}` is an exported-resource " ++
                        "intrinsic, but no exported interface defines resource `{s}`\n",
                    .{ it.field, it.module, it.resource },
                );
                return error.UnresolvedResourceIntrinsic;
            }
            try exp.append(ar, .{
                .module = it.module,
                .field = it.field,
                .resource = it.resource,
                .kind = it.kind,
            });
        } else {
            try imp.append(ar, it);
        }
    }
    return .{
        .import_side = try imp.toOwnedSlice(ar),
        .export_side = try exp.toOwnedSlice(ar),
    };
}

/// Group export-side intrinsics by their `[export]<iface>` module so
/// each distinct module yields one inline-exports bundle + one main
/// `(with …)` arg. Preserves first-seen module order.
fn groupExportSideByModule(
    ar: std.mem.Allocator,
    export_side: []const ExportSideIntrinsic,
) ![]const []const ExportSideIntrinsic {
    var modules = std.ArrayListUnmanaged([]const u8).empty;
    var groups = std.ArrayListUnmanaged(std.ArrayListUnmanaged(ExportSideIntrinsic)).empty;
    for (export_side) |it| {
        var gi: ?usize = null;
        for (modules.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, it.module)) {
                gi = i;
                break;
            }
        }
        const idx = gi orelse blk: {
            try modules.append(ar, it.module);
            try groups.append(ar, .empty);
            break :blk groups.items.len - 1;
        };
        try groups.items[idx].append(ar, it);
    }
    var out = try ar.alloc([]const ExportSideIntrinsic, groups.items.len);
    for (groups.items, 0..) |*g, i| out[i] = try g.toOwnedSlice(ar);
    return out;
}

/// Deterministic import-arg name a nested export-interface component
/// uses for the resource type `rname` it re-exports.
fn nestedTypeImportName(ar: std.mem.Allocator, rname: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ar, "import-type-{s}", .{rname});
}

/// Deterministic import-arg name for the `j`-th func. Kebab-valid:
/// the index is glued to the word (`import-func0`), since a
/// `-`-separated label segment may not begin with a digit.
fn nestedFuncImportName(ar: std.mem.Allocator, j: usize) ![]const u8 {
    return std.fmt.allocPrint(ar, "import-func{d}", .{j});
}

/// Transcription context for a nested export-interface component: maps
/// each `own`/`borrow` handle to a hoisted defined handle type
/// referencing the target resource type index (`res_target`) in the
/// nested component, and hoists compound value types via `addType`.
/// Handle types are hoisted (not inlined) to match `wit-component`'s
/// encoding, which the validator expects.
const NestedResolveCtx = struct {
    ar: std.mem.Allocator,
    ext_slots: []const metadata_decode.TypeSlot,
    types: *std.ArrayListUnmanaged(ctypes.TypeDef),
    order: *std.ArrayListUnmanaged(ctypes.SectionEntry),
    ty: *u32,
    res_target: *std.StringHashMapUnmanaged(u32),

    pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
        try self.types.append(self.ar, td);
        try self.order.append(self.ar, .{ .kind = .type, .start = @intCast(self.types.items.len - 1), .count = 1 });
        const idx = self.ty.*;
        self.ty.* += 1;
        return idx;
    }

    pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
        return switch (v) {
            .own => |k| .{ .type_idx = try self.hoistHandle(k, .own) },
            .borrow => |k| .{ .type_idx = try self.hoistHandle(k, .borrow) },
            else => v,
        };
    }

    fn hoistHandle(self: @This(), slot: u32, comptime kind: enum { own, borrow }) lift_types.Error!u32 {
        const name = metadata_decode.resourceNameForSlot(self.ext_slots, slot) orelse
            return error.UnresolvedResource;
        const res = self.res_target.get(name) orelse return error.UnresolvedResource;
        const vt: ctypes.ValType = switch (kind) {
            .own => .{ .own = res },
            .borrow => .{ .borrow = res },
        };
        return self.addType(.{ .val = vt });
    }
};

/// Build a nested sub-component that re-exports an interface defining
/// resources, performing the type-export binding the component model
/// requires (a resource used by an exported func must be *named* in
/// that instance's type). Mirrors `wit-component`'s emitter:
///
///   (component
///     (import "import-type-R"  (type (sub resource)))     ; type 0
///     …func types vs imported R…
///     (import "import-func-j"  (func <ty>))               ; func j
///     (export "R" (type 0))                               ; new exported R
///     …func types vs exported R…
///     (export "<fn>" (func j) (func <ty>)))               ; re-ascribed
///
/// The outer component instantiates this with the top-level resource
/// type and the lifted funcs as args (see callers). `res_names` are the
/// resources this interface defines, in a stable order.
fn buildExportInterfaceComponent(
    ar: std.mem.Allocator,
    ext: metadata_decode.WorldExtern,
    res_names: []const []const u8,
) !*ctypes.Component {
    var types = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    var imports = std.ArrayListUnmanaged(ctypes.ImportDecl).empty;
    var exports = std.ArrayListUnmanaged(ctypes.ExportDecl).empty;
    var order = std.ArrayListUnmanaged(ctypes.SectionEntry).empty;
    var ty: u32 = 0;

    var imp_res = std.StringHashMapUnmanaged(u32).empty;
    var exp_res = std.StringHashMapUnmanaged(u32).empty;

    // 1. Import each resource type as a `(sub resource)`.
    for (res_names) |rn| {
        try imports.append(ar, .{
            .name = try nestedTypeImportName(ar, rn),
            .desc = .{ .type = .sub_resource },
        });
        try order.append(ar, .{ .kind = .import, .start = @intCast(imports.items.len - 1), .count = 1 });
        try imp_res.put(ar, rn, ty);
        ty += 1;
    }

    // 2. Import each func, typed against the imported resources.
    {
        for (ext.funcs, 0..) |f, j| {
            const ctx = NestedResolveCtx{
                .ar = ar,
                .ext_slots = ext.type_slots,
                .types = &types,
                .order = &order,
                .ty = &ty,
                .res_target = &imp_res,
            };
            const sig = try lift_types.transcribeFuncSig(ar, ctx, ext.type_slots, f.sig);
            try types.append(ar, .{ .func = sig });
            try order.append(ar, .{ .kind = .type, .start = @intCast(types.items.len - 1), .count = 1 });
            const ft = ty;
            ty += 1;
            try imports.append(ar, .{
                .name = try nestedFuncImportName(ar, j),
                .desc = .{ .func = ft },
            });
            try order.append(ar, .{ .kind = .import, .start = @intCast(imports.items.len - 1), .count = 1 });
        }
    }

    // 3. Export each resource type, binding a fresh exported resource.
    for (res_names) |rn| {
        const src = imp_res.get(rn).?;
        try exports.append(ar, .{
            .name = rn,
            .sort_idx = .{ .sort = .type, .idx = src },
            .desc = .{ .type = .{ .eq = src } },
        });
        try order.append(ar, .{ .kind = .@"export", .start = @intCast(exports.items.len - 1), .count = 1 });
        try exp_res.put(ar, rn, ty);
        ty += 1;
    }

    // 4. Re-export each func, typed against the exported resources.
    for (ext.funcs, 0..) |f, j| {
        const ctx = NestedResolveCtx{
            .ar = ar,
            .ext_slots = ext.type_slots,
            .types = &types,
            .order = &order,
            .ty = &ty,
            .res_target = &exp_res,
        };
        const sig = try lift_types.transcribeFuncSig(ar, ctx, ext.type_slots, f.sig);
        try types.append(ar, .{ .func = sig });
        try order.append(ar, .{ .kind = .type, .start = @intCast(types.items.len - 1), .count = 1 });
        const ft = ty;
        ty += 1;
        try exports.append(ar, .{
            .name = f.name,
            .sort_idx = .{ .sort = .func, .idx = @intCast(j) },
            .desc = .{ .func = ft },
        });
        try order.append(ar, .{ .kind = .@"export", .start = @intCast(exports.items.len - 1), .count = 1 });
    }

    const comp = try ar.create(ctypes.Component);
    comp.* = .{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = try types.toOwnedSlice(ar),
        .canons = &.{},
        .imports = try imports.toOwnedSlice(ar),
        .exports = try exports.toOwnedSlice(ar),
        .section_order = try order.toOwnedSlice(ar),
    };
    return comp;
}

/// Synthetic core-import module prefixes that name a component-model
/// async built-in family (cataggar/wabt#263). These are wired to `canon`
/// core funcs in a dedicated pre-pass, distinct from real interface
/// imports (and from the `[export]<iface>` resource-intrinsic modules).
const async_intrinsic_prefixes = [_][]const u8{
    "[task-return]",
    "[stream]",
    "[future]",
    "[error-context]",
    "[waitable-set]",
    "[waitable]",
    "[backpressure]",
    "[task]",
    "[subtask]",
    "[context]",
};

fn isAsyncIntrinsicModule(module: []const u8) bool {
    for (async_intrinsic_prefixes) |p| {
        if (std.mem.startsWith(u8, module, p)) return true;
    }
    return false;
}

/// Parsed `[context]` intrinsic field, formatted `<op>-<ty>-<slot>`
/// (e.g. `get-i32-0`, `set-i64-3`). `is_set` selects `context.set` over
/// `context.get`; `ty` is the slot's core valtype and `slot` its index.
const ContextField = struct { is_set: bool, ty: ctypes.CoreValType, slot: u32 };

fn parseContextField(field: []const u8) ?ContextField {
    const is_set = std.mem.startsWith(u8, field, "set-");
    const is_get = std.mem.startsWith(u8, field, "get-");
    if (!is_set and !is_get) return null;
    const rest = field[4..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const ty_str = rest[0..dash];
    const ty: ctypes.CoreValType = if (std.mem.eql(u8, ty_str, "i32"))
        .i32
    else if (std.mem.eql(u8, ty_str, "i64"))
        .i64
    else if (std.mem.eql(u8, ty_str, "f32"))
        .f32
    else if (std.mem.eql(u8, ty_str, "f64"))
        .f64
    else
        return null;
    const slot = std.fmt.parseInt(u32, rest[dash + 1 ..], 10) catch return null;
    return .{ .is_set = is_set, .ty = ty, .slot = slot };
}

/// True if an import interface's instance-type body exports a named type
/// (e.g. a `use`d enum like `wasi:cli/types`'s `error-code`). Such
/// type-only imports define types other imports' bodies reference via
/// cross-iface aliases, so they must be imported (not skipped) for the
/// rebase to resolve.
fn instProvidesType(decls: []const ctypes.Decl) bool {
    for (decls) |d| switch (d) {
        .@"export" => |e| if (e.desc == .type) return true,
        else => {},
    };
    return false;
}

/// Map a WIT primitive type name to a component `ValType`. Returns null
/// for non-primitive / unknown names.
fn primValType(name: []const u8) ?ctypes.ValType {
    const Pair = struct { n: []const u8, v: ctypes.ValType };
    const prims = [_]Pair{
        .{ .n = "bool", .v = .bool },   .{ .n = "s8", .v = .s8 },     .{ .n = "u8", .v = .u8 },
        .{ .n = "s16", .v = .s16 },     .{ .n = "u16", .v = .u16 },   .{ .n = "s32", .v = .s32 },
        .{ .n = "u32", .v = .u32 },     .{ .n = "s64", .v = .s64 },   .{ .n = "u64", .v = .u64 },
        .{ .n = "f32", .v = .f32 },     .{ .n = "f64", .v = .f64 },   .{ .n = "char", .v = .char },
        .{ .n = "string", .v = .string },
    };
    for (prims) |p| if (std.mem.eql(u8, p.n, name)) return p.v;
    return null;
}

/// Parse the element type from a `stream<T>` / `future<T>` spec (the part
/// of a `[stream]`/`[future]` import module after the family prefix).
/// Only primitive element types are supported for now; returns null
/// otherwise so the caller can reject the intrinsic with a clear error.
fn parseAsyncElement(spec: []const u8) ?ctypes.ValType {
    const lt = std.mem.indexOfScalar(u8, spec, '<') orelse return null;
    const gt = std.mem.lastIndexOfScalar(u8, spec, '>') orelse return null;
    if (gt <= lt + 1) return null;
    return primValType(spec[lt + 1 .. gt]);
}

/// True if the core imports any memory-opt async intrinsic
/// (`stream.read`/`.write`, `future.read`/`.write`) — these need
/// `(memory)`/`(realloc)` canon opts pointing at the main instance,
/// forcing the shim/fixup path.
fn coreNeedsAsyncMemOpShim(ar: std.mem.Allocator, core_bytes: []const u8) bool {
    if (core_imports.extract(ar, core_bytes)) |oi| {
        for (oi.interface.imports) |im| {
            if (im.kind != .func) continue;
            if (std.mem.startsWith(u8, im.module_name, "[stream]") and
                (std.mem.eql(u8, im.field_name, "read") or std.mem.eql(u8, im.field_name, "write")))
                return true;
            if (std.mem.startsWith(u8, im.module_name, "[future]") and
                (std.mem.eql(u8, im.field_name, "read") or std.mem.eql(u8, im.field_name, "write")))
                return true;
            if (std.mem.startsWith(u8, im.module_name, "[waitable-set]") and
                (std.mem.eql(u8, im.field_name, "wait") or std.mem.eql(u8, im.field_name, "poll")))
                return true;
            if (std.mem.eql(u8, im.module_name, "[error-context]") and
                (std.mem.eql(u8, im.field_name, "new") or std.mem.eql(u8, im.field_name, "debug-message")))
                return true;
        }
    } else |_| {}
    return false;
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
            .world_decls = decoded.world_decls,
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

    // ── #253: an exported func whose lift needs `(memory)` / `(realloc)`
    //    / string-encoding / `(post-return)` (its sig reaches
    //    string/list/indirect) also requires the shim/fixup path, which
    //    aliases `memory` + `cabi_realloc`. Scan exported funcs too.
    if (!any_func_needs_opts) {
        outer: for (decoded.externs) |ext| {
            if (!ext.is_export) continue;
            const resolver = wabt.component.adapter.abi.TypeResolver{
                .inst_decls = ext.inst_decls,
                .world_decls = decoded.world_decls,
            };
            for (ext.funcs) |fn_ref| {
                const ftr = wabt.component.adapter.abi.FuncTypeRef{
                    .func = fn_ref.sig,
                    .resolver = resolver,
                };
                if (wabt.component.adapter.abi.liftNeedsOpts(
                    wabt.component.adapter.abi.classifyFuncLift(ftr),
                )) {
                    any_func_needs_opts = true;
                    break :outer;
                }
            }
        }
    }

    // ── #250: collect guest-defined (exported) resources. A resource
    //    with a destructor forces the shim/fixup path: its `(type
    //    (resource … (dtor …)))` references a core func that only
    //    exists once main is instantiated, but main's `[resource-new]`
    //    / `[resource-rep]` imports reference that resource type — a
    //    forward-reference cycle that the shim trampoline breaks
    //    (exactly as wit-component's `ShimKind::ResourceDtor`).
    //    Dtor-less exported resources have no cycle and stay on the
    //    fast path.
    const exported_resources = try collectExportedResources(ar, decoded, stripped_core);
    var any_exported_dtor = false;
    for (exported_resources) |er| {
        if (er.dtor_export != null) {
            any_exported_dtor = true;
            break;
        }
    }

    if (any_func_needs_opts or any_exported_dtor or coreNeedsAsyncMemOpShim(ar, stripped_core)) {
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

    // Validate the guest's declared core import sigs against the
    // canonical lowering before wiring them (mirrors the shim path's
    // Phase 2.9 / #244). Funcs wired here lower with empty canon opts
    // but still flatten per the canonical ABI, so a guest that
    // mis-flattens (e.g. a `u64` param declared as `i32`) is caught
    // early with an actionable diff instead of a host load failure.
    {
        const abi = wabt.component.adapter.abi;
        var expected = std.ArrayListUnmanaged(ExpectedImportSig).empty;
        for (import_shapes.items, 0..) |shape, i| {
            const resolver = abi.TypeResolver{
                .inst_decls = shape.inst_decls,
                .world_decls = decoded.world_decls,
            };
            for (wired_funcs_by_shape[i]) |fn_ref| {
                const lowered = try abi.lowerCoreSig(ar, .{ .func = fn_ref.sig, .resolver = resolver });
                try expected.append(ar, .{
                    .module = shape.qualified_name,
                    .field = fn_ref.name,
                    .params = lowered.params,
                    .results = lowered.results,
                });
            }
        }
        try validateGuestImportSigs(alloc, stripped_core, expected.items);
    }
    const import_inst_count: u32 = @intCast(imports.items.len);

    // ── #250: declare each guest-defined (exported) resource type.
    //    On the fast path every exported resource is dtor-less (a
    //    destructor forces the shim path above), so the type carries
    //    no destructor. `own`/`borrow` refs in exported func sigs and
    //    the `[export]…` `resource.{new,rep,drop}` intrinsics below
    //    resolve to these slots.
    var exported_resource_type_idx = std.StringHashMapUnmanaged(u32).empty;
    for (exported_resources) |er| {
        if (exported_resource_type_idx.contains(er.name)) continue;
        try types.append(ar, .{ .resource = .{ .destructor = null } });
        try Section.appendType(&order, ar, types.items.len);
        try exported_resource_type_idx.put(ar, er.name, comp_type_idx);
        comp_type_idx += 1;
    }

    // ── #248/#250: resolve resource built-in intrinsic imports
    //    (`[resource-drop|new|rep]<R>`). Import-side intrinsics group
    //    by the import shape whose bundle feeds the main core module;
    //    export-side intrinsics (`[export]<iface>` module) operate on
    //    a guest-defined resource and resolve to the exported resource
    //    type declared above.
    const intrinsics = try collectResourceIntrinsics(ar, stripped_core);
    // #251: validate the intrinsics' declared core import sigs against
    // their fixed canonical-ABI shapes before wiring them.
    try validateResourceIntrinsicSigs(alloc, ar, stripped_core, intrinsics);
    const parts = try partitionResourceIntrinsics(ar, intrinsics, exported_resources);
    const shape_qnames = try ar.alloc([]const u8, import_shapes.items.len);
    for (import_shapes.items, 0..) |s, i| shape_qnames[i] = s.qualified_name;
    const intrinsics_by_shape = try resolveResourceIntrinsicsByShape(
        ar,
        parts.import_side,
        shape_qnames,
        &resource_owner,
        &import_inst_idx_for,
    );
    const export_groups = try groupExportSideByModule(ar, parts.export_side);
    // Resource-name → component type idx of the alias from its
    // providing import instance. Shared across the intrinsic canons
    // emitted in Phase 2.5.
    var intrinsic_resource_alias = std.StringHashMapUnmanaged(u32).empty;

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
        const drops = intrinsics_by_shape[i];
        if (wired.len == 0 and drops.len == 0) continue;
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
        if (wired.len > 0) {
            try order.append(ar, .{
                .kind = .canon,
                .start = @intCast(canons.items.len - wired.len),
                .count = @intCast(wired.len),
            });
        }

        // 2.5. #248: resource built-in intrinsics for this namespace.
        //   Each `[resource-drop|new|rep]<R>` gets a resource-type
        //   alias from its providing import instance plus a `canon
        //   resource.{drop,new,rep}` core func. These need no canon
        //   opts, so they slot cleanly into the fast path; the bundle
        //   below exposes each under its canonical field name.
        const intrinsic_core_idxs = try ar.alloc(u32, drops.len);
        for (drops, 0..) |d, di| {
            const type_idx = intrinsic_resource_alias.get(d.resource) orelse blk: {
                try aliases.append(ar, .{ .instance_export = .{
                    .sort = .type,
                    .instance_idx = d.owner_inst_idx,
                    .name = d.resource,
                } });
                try Section.appendAlias(&order, ar, aliases.items.len);
                const idx = comp_type_idx;
                comp_type_idx += 1;
                try intrinsic_resource_alias.put(ar, d.resource, idx);
                break :blk idx;
            };
            try canons.append(ar, canonForIntrinsic(d.kind, type_idx));
            try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
            intrinsic_core_idxs[di] = core_func_idx;
            core_func_idx += 1;
        }

        // 3. core_instance.exports bundle for this import.
        const bundle_exports = try ar.alloc(ctypes.CoreInlineExport, wired.len + drops.len);
        for (wired, 0..) |fn_ref, fi| {
            bundle_exports[fi] = .{
                .name = fn_ref.name,
                .sort_idx = .{
                    .sort = .func,
                    .idx = lowered_core_func_idx_base + @as(u32, @intCast(fi)),
                },
            };
        }
        for (drops, 0..) |d, di| {
            bundle_exports[wired.len + di] = .{
                .name = d.field,
                .sort_idx = .{ .sort = .func, .idx = intrinsic_core_idxs[di] },
            };
        }
        try core_instances.append(ar, .{ .exports = bundle_exports });
        bundles_by_shape[i] = .{ .core_inst_idx = @intCast(core_instances.items.len - 1) };
    }

    // ── #250: export-side resource intrinsic bundles. Each
    //    `[export]<iface>` module the guest imports from gets one
    //    bundle of `canon resource.{new,rep,drop} <exported R type>`
    //    core funcs, fed to the main instance under that module name
    //    so the guest's own handle-management imports are satisfied.
    const ExportBundle = struct { module: []const u8, core_inst_idx: u32 };
    var export_bundles = std.ArrayListUnmanaged(ExportBundle).empty;
    for (export_groups) |group| {
        const bundle_exports = try ar.alloc(ctypes.CoreInlineExport, group.len);
        for (group, 0..) |it, gi| {
            const type_idx = exported_resource_type_idx.get(it.resource).?;
            try canons.append(ar, canonForIntrinsic(it.kind, type_idx));
            try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
            bundle_exports[gi] = .{
                .name = it.field,
                .sort_idx = .{ .sort = .func, .idx = core_func_idx },
            };
            core_func_idx += 1;
        }
        try core_instances.append(ar, .{ .exports = bundle_exports });
        try export_bundles.append(ar, .{
            .module = group[0].module,
            .core_inst_idx = @intCast(core_instances.items.len - 1),
        });
    }

    // ── P3 async-intrinsic bundles (cataggar/wabt#263).
    //    Synthetic intrinsic import modules the guest core uses for the
    //    component-model async built-ins, each wired to `canon` core funcs
    //    in a bundle fed to the main instance under the module name —
    //    mirroring the resource-intrinsic bundles above but keyed by the
    //    synthetic module rather than an imported interface. The bundle +
    //    canons must precede the main instance so its `(with …)` arg can
    //    reference the bundle.
    //
    //    Handled now: `[task-return]<export>` → `canon task.return`;
    //    `[stream]stream<T>` → `canon stream.{new,drop-readable,drop-
    //    writable}` over a hoisted `(stream T)` type; `[future]future<T>`
    //    → `canon future.{new,drop-readable,drop-writable}` over a hoisted
    //    `(future T)` type. Ops needing `(memory)`/`(realloc)` opts
    //    (`stream.read`/`.write`, `future.read`/`.write`,
    //    `error-context.*`) require the main instance's memory — a
    //    forward-reference that needs the shim/fixup path — and are
    //    rejected here with `error.UnsupportedAsyncIntrinsic`.
    const AsyncBundle = struct { module: []const u8, core_inst_idx: u32 };
    var async_bundles = std.ArrayListUnmanaged(AsyncBundle).empty;
    {
        // lift_types builder ctx: hoists result typedefs into the
        // component type section.
        const AsyncTypeCtx = struct {
            ar: std.mem.Allocator,
            types: *std.ArrayListUnmanaged(ctypes.TypeDef),
            order: *std.ArrayListUnmanaged(ctypes.SectionEntry),
            comp_type_idx: *u32,
            pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
                try self.types.append(self.ar, td);
                try Section.appendType(self.order, self.ar, self.types.items.len);
                const idx = self.comp_type_idx.*;
                self.comp_type_idx.* += 1;
                return idx;
            }
            pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
                _ = self;
                return v;
            }
        };

        // Group intrinsic imports by synthetic module (preserving first-
        // seen order); a module like `[stream]stream<u8>` carries several
        // fields (`new`, `drop-writable`, …) that share one bundle.
        const ModuleGroup = struct {
            module: []const u8,
            fields: std.ArrayListUnmanaged([]const u8),
        };
        var groups = std.ArrayListUnmanaged(ModuleGroup).empty;
        if (core_imports.extract(ar, stripped_core)) |oi| {
            for (oi.interface.imports) |im| {
                if (im.kind != .func) continue;
                if (!isAsyncIntrinsicModule(im.module_name)) continue;
                var gi: ?usize = null;
                for (groups.items, 0..) |grp, k| {
                    if (std.mem.eql(u8, grp.module, im.module_name)) {
                        gi = k;
                        break;
                    }
                }
                if (gi == null) {
                    try groups.append(ar, .{ .module = try ar.dupe(u8, im.module_name), .fields = .empty });
                    gi = groups.items.len - 1;
                }
                try groups.items[gi.?].fields.append(ar, try ar.dupe(u8, im.field_name));
            }
        } else |_| {}

        // `stream<T>` spec → component `(stream T)` type idx (shared by all
        // canons over the same element type).
        var stream_type_idx = std.StringHashMapUnmanaged(u32).empty;
        // `future<T>` spec → component `(future T)` type idx (same sharing).
        var future_type_idx = std.StringHashMapUnmanaged(u32).empty;

        for (groups.items) |grp| {
            var bundle_exports = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;

            if (std.mem.startsWith(u8, grp.module, "[task-return]")) {
                // `[task-return]<iface>#<fn>` → result types of that export.
                const export_ref = grp.module["[task-return]".len..];
                const hash = std.mem.lastIndexOfScalar(u8, export_ref, '#') orelse
                    return error.UnsupportedAsyncIntrinsic;
                const iface_name = export_ref[0..hash];
                const fn_name = export_ref[hash + 1 ..];
                const ctx = AsyncTypeCtx{ .ar = ar, .types = &types, .order = &order, .comp_type_idx = &comp_type_idx };
                var results: ctypes.FuncType.ResultList = .none;
                var found_export = false;
                find: for (decoded.externs) |ext| {
                    if (!ext.is_export) continue;
                    if (!std.mem.eql(u8, ext.qualified_name, iface_name)) continue;
                    for (ext.funcs) |fn_ref| {
                        if (!std.mem.eql(u8, fn_ref.name, fn_name)) continue;
                        results = switch (fn_ref.sig.results) {
                            .none => .none,
                            .unnamed => |v| .{ .unnamed = try lift_types.transcribeValType(ar, ctx, ext.type_slots, v) },
                            .named => |named| n: {
                                const dst = try ar.alloc(ctypes.NamedValType, named.len);
                                for (named, 0..) |nv, k| dst[k] = .{
                                    .name = nv.name,
                                    .type = try lift_types.transcribeValType(ar, ctx, ext.type_slots, nv.type),
                                };
                                break :n .{ .named = dst };
                            },
                        };
                        found_export = true;
                        break :find;
                    }
                }
                if (!found_export) return error.UnsupportedAsyncIntrinsic;
                for (grp.fields.items) |field| {
                    try canons.append(ar, .{ .task_return = .{ .results = results, .opts = &.{} } });
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[stream]")) {
                const spec = grp.module["[stream]".len..]; // e.g. `stream<u8>`
                const elem = parseAsyncElement(spec) orelse return error.UnsupportedAsyncIntrinsic;
                const ty_idx = stream_type_idx.get(spec) orelse blk: {
                    try types.append(ar, .{ .stream = .{ .element = elem } });
                    try Section.appendType(&order, ar, types.items.len);
                    const idx = comp_type_idx;
                    comp_type_idx += 1;
                    try stream_type_idx.put(ar, spec, idx);
                    break :blk idx;
                };
                for (grp.fields.items) |field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field, "new"))
                        .{ .stream_new = ty_idx }
                    else if (std.mem.eql(u8, field, "drop-readable"))
                        .{ .stream_drop_readable = ty_idx }
                    else if (std.mem.eql(u8, field, "drop-writable"))
                        .{ .stream_drop_writable = ty_idx }
                    else
                        // `read`/`write`/`cancel-*` need `(memory)` opts.
                        return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[future]")) {
                const spec = grp.module["[future]".len..]; // e.g. `future<u8>`
                const elem = parseAsyncElement(spec) orelse return error.UnsupportedAsyncIntrinsic;
                const ty_idx = future_type_idx.get(spec) orelse blk: {
                    try types.append(ar, .{ .future = .{ .element = elem } });
                    try Section.appendType(&order, ar, types.items.len);
                    const idx = comp_type_idx;
                    comp_type_idx += 1;
                    try future_type_idx.put(ar, spec, idx);
                    break :blk idx;
                };
                for (grp.fields.items) |field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field, "new"))
                        .{ .future_new = ty_idx }
                    else if (std.mem.eql(u8, field, "drop-readable"))
                        .{ .future_drop_readable = ty_idx }
                    else if (std.mem.eql(u8, field, "drop-writable"))
                        .{ .future_drop_writable = ty_idx }
                    else
                        // `read`/`write`/`cancel-*` need `(memory)` opts.
                        return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[waitable-set]")) {
                // `new` / `drop` are no-memory; `wait`/`poll` need
                // `(memory)` opts and so only reach the shim/fixup path.
                for (grp.fields.items) |field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field, "new"))
                        .waitable_set_new
                    else if (std.mem.eql(u8, field, "drop"))
                        .waitable_set_drop
                    else
                        return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[waitable]")) {
                for (grp.fields.items) |field| {
                    if (!std.mem.eql(u8, field, "join")) return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, .waitable_join);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[backpressure]")) {
                for (grp.fields.items) |field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field, "inc"))
                        .backpressure_inc
                    else if (std.mem.eql(u8, field, "dec"))
                        .backpressure_dec
                    else
                        return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[task]")) {
                for (grp.fields.items) |field| {
                    if (!std.mem.eql(u8, field, "cancel")) return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, .task_cancel);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[subtask]")) {
                for (grp.fields.items) |field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field, "drop"))
                        .subtask_drop
                    else if (std.mem.eql(u8, field, "cancel"))
                        .{ .subtask_cancel = false }
                    else if (std.mem.eql(u8, field, "cancel-async"))
                        .{ .subtask_cancel = true }
                    else
                        return error.UnsupportedAsyncIntrinsic;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else if (std.mem.startsWith(u8, grp.module, "[context]")) {
                for (grp.fields.items) |field| {
                    const cf = parseContextField(field) orelse return error.UnsupportedAsyncIntrinsic;
                    const canon: ctypes.Canon = if (cf.is_set)
                        .{ .context_set = .{ .ty = cf.ty, .slot = cf.slot } }
                    else
                        .{ .context_get = .{ .ty = cf.ty, .slot = cf.slot } };
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    try bundle_exports.append(ar, .{ .name = field, .sort_idx = .{ .sort = .func, .idx = core_func_idx } });
                    core_func_idx += 1;
                }
            } else {
                // `[error-context]` (always needs the shim path for its
                // memory ops): not wired in this no-shim path.
                return error.UnsupportedAsyncIntrinsic;
            }

            try core_instances.append(ar, .{ .exports = try bundle_exports.toOwnedSlice(ar) });
            try async_bundles.append(ar, .{ .module = grp.module, .core_inst_idx = @intCast(core_instances.items.len - 1) });
        }
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
    for (export_bundles.items) |eb| {
        try main_args.append(ar, .{ .name = eb.module, .instance_idx = eb.core_inst_idx });
    }
    for (async_bundles.items) |ab| {
        try main_args.append(ar, .{ .name = ab.module, .instance_idx = ab.core_inst_idx });
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
        exported_resource_type_idx: *std.StringHashMapUnmanaged(u32),
        hoist_keys: *std.ArrayListUnmanaged(HandleKey),
        hoist_idxs: *std.ArrayListUnmanaged(u32),
        comp_type_idx: *u32,
        order: *std.ArrayListUnmanaged(ctypes.SectionEntry),

        fn resourceAlias(self: @This(), name: []const u8) !u32 {
            // #250: a guest-defined (exported) resource resolves to the
            // resource type declared in this component — no import
            // alias needed.
            if (self.exported_resource_type_idx.get(name)) |idx| return idx;
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
            return lift_types.transcribeValType(self.ar, self, self.ext_slots, v);
        }

        /// Append a defined type to the component type section and
        /// return its component-level type index. Used by the shared
        /// `lift_types` transcriber to hoist compound value types.
        pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
            try self.types.append(self.ar, td);
            try Section.appendType(self.order, self.ar, self.types.items.len);
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            return slot;
        }

        /// Resolve a leaf value type the transcriber doesn't hoist:
        /// resource handles become defined handle types via
        /// `hoistHandle`; anything else passes through unchanged.
        pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
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
            return .{ .params = params, .results = results, .is_async = sig.is_async };
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
        is_async: bool,
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
            .exported_resource_type_idx = &exported_resource_type_idx,
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
                .is_async = fn_ref.sig.is_async,
            });
        }
        try ext_export_start.append(ar, .{ .ext = ext, .start = start });
    }

    // ── Canon lifts and instance exprs: appended to flat lists,
    //    section_order entries appended after.
    const lifts_start: u32 = @intCast(canons.items.len);
    for (captured_funcs.items) |cf| {
        // An `async func` export lifts with the `async` canon option;
        // its async-ness reached us via the `[async]` declarator name
        // (see metadata_decode), surfaced as `fn_ref.sig.is_async`.
        const opts: []const ctypes.CanonOpt = if (cf.is_async)
            try ar.dupe(ctypes.CanonOpt, &.{.async_})
        else
            &.{};
        try canons.append(ar, .{ .lift = .{
            .core_func_idx = cf.core_func_alias_idx,
            .type_idx = cf.func_type_idx,
            .opts = opts,
        } });
    }
    const lifts_count: u32 = @as(u32, @intCast(canons.items.len)) - lifts_start;

    var nested_components = std.ArrayListUnmanaged(*ctypes.Component).empty;
    for (ext_export_start.items, 0..) |es, ei| {
        const end: u32 = if (ei + 1 < ext_export_start.items.len)
            ext_export_start.items[ei + 1].start
        else
            @intCast(captured_funcs.items.len);
        const fn_count = end - es.start;

        // Resources this interface defines (stable order).
        var res_names = std.ArrayListUnmanaged([]const u8).empty;
        for (exported_resources) |er| {
            if (std.mem.eql(u8, er.ext_qualified, es.ext.qualified_name)) try res_names.append(ar, er.name);
        }

        // Each lifted func's component-func index.
        const func_comp_idx = try ar.alloc(u32, fn_count);
        for (0..fn_count) |i| {
            func_comp_idx[i] = comp_func_idx;
            comp_func_idx += 1;
        }

        if (res_names.items.len == 0) {
            // Resource-free interface: a flat inline-export instance is
            // sufficient (the pre-#250 behaviour).
            var inline_exports = try ar.alloc(ctypes.InlineExport, fn_count);
            for (0..fn_count) |i| {
                const cf = captured_funcs.items[es.start + i];
                inline_exports[i] = .{
                    .name = cf.fn_name,
                    .sort_idx = .{ .sort = .func, .idx = func_comp_idx[i] },
                };
            }
            try instances.append(ar, .{ .exports = inline_exports });
        } else {
            // #250: interface defines resources → instantiate a nested
            // sub-component that re-exports them with the required
            // type-export binding (see buildExportInterfaceComponent).
            const nested = try buildExportInterfaceComponent(ar, es.ext, res_names.items);
            try nested_components.append(ar, nested);
            const comp_idx: u32 = @intCast(nested_components.items.len - 1);
            var args = std.ArrayListUnmanaged(ctypes.InstantiateArg).empty;
            for (res_names.items) |rn| {
                try args.append(ar, .{
                    .name = try nestedTypeImportName(ar, rn),
                    .sort_idx = .{ .sort = .type, .idx = exported_resource_type_idx.get(rn).? },
                });
            }
            for (0..fn_count) |i| {
                try args.append(ar, .{
                    .name = try nestedFuncImportName(ar, i),
                    .sort_idx = .{ .sort = .func, .idx = func_comp_idx[i] },
                });
            }
            try instances.append(ar, .{ .instantiate = .{
                .component_idx = comp_idx,
                .args = try args.toOwnedSlice(ar),
            } });
        }
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
    if (nested_components.items.len > 0) {
        try order.append(ar, .{ .kind = .component, .start = 0, .count = @intCast(nested_components.items.len) });
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
        .components = try nested_components.toOwnedSlice(ar),
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
/// (cataggar/wabt#203), a guest-defined resource has a destructor
/// (#250), or the guest imports a memory-opt P3 async intrinsic
/// (`stream.read`/`.write`, `error-context.new`/`.debug-message` — #263).
/// All three share the same forward-reference cycle (the canon needs
/// main's `memory`/`realloc`, but main needs the canon's core func as a
/// `(with …)` arg) and are broken with the same trampoline pattern.
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
/// Cross-iface handle refs in imported func sigs are rebased
/// before the body is transplanted: each `alias outer (type 1 K)`
/// in the body resolves into the metadata's world body at slot K,
/// which (when the encoder emitted it for a `use src.{T};` clause,
/// the only case currently in scope) is an
/// `alias instance_export sort=type inst=I name=N`. The wrapping
/// component emits a matching top-level
/// `alias instance_export sort=type, instance_idx=<wrapping inst
/// for I>, name=N`, then the body's outer-alias is rewritten to
/// point at that new top-level slot (cataggar/wabt#206). The "K
/// resolves to a direct typedef" case is currently passed through
/// unchanged — the wabt encoder doesn't produce it.
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
        if (rs.items.len == 0 and ext.funcs.len == 0 and !instProvidesType(ext.inst_decls)) continue;
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
    //    decls bind. The resolver is seeded with the decoded world
    //    decls so outer-aliased compound types (e.g. a cross-iface
    //    `use`d `error-code` variant) resolve to their real
    //    definition; otherwise they'd fall back to scalar-handle and
    //    silently drop required canon-lower opts like `realloc`
    //    (#234). Genuinely unresolvable idxs still fall back to the
    //    scalar-handle shape, which is correct for resource handles.
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
            .world_decls = decoded.world_decls,
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

    // ── Phase 2.9: validate the guest's declared core import sigs
    //    against the canonical lowering we're about to provide. A
    //    mismatch (e.g. #244's `error-code` flattened without the
    //    canonical `i64`) would otherwise produce a component that
    //    only fails to link at host load; fail early with a diff.
    {
        var expected = std.ArrayListUnmanaged(ExpectedImportSig).empty;
        for (import_shapes.items, 0..) |shape, i| {
            for (wired_by_shape[i]) |w| try expected.append(ar, .{
                .module = shape.qualified_name,
                .field = w.fn_ref.name,
                .params = w.slot_params,
                .results = w.slot_results,
            });
        }
        try validateGuestImportSigs(alloc, stripped_core, expected.items);
    }

    // ── #250: guest-defined (exported) resources. Each one with a
    //    destructor needs a shim trampoline slot (sig `(i32)->()`) so
    //    its `(type (resource … (dtor …)))` can reference a core func
    //    before the main module is instantiated; the fixup later
    //    patches that slot to call main's real destructor export.
    const exported_resources = try collectExportedResources(ar, decoded, stripped_core);
    var dtor_resources = std.ArrayListUnmanaged(ExportedResource).empty;
    for (exported_resources) |er| {
        if (er.dtor_export != null) try dtor_resources.append(ar, er);
    }
    const dtor_count: u32 = @intCast(dtor_resources.items.len);

    // ── #263: async-intrinsic analysis. Group the synthetic intrinsic
    //    import modules (`[task-return]<export>`, `[stream]stream<T>`)
    //    and classify each field as no-memory (task.return, stream.new /
    //    drop-readable / drop-writable — direct canons) or memory-opt
    //    (stream.read / .write — need `(memory)`/`(realloc)` opts, so they
    //    route through a shim trampoline like the lowered imports). The
    //    mem-op fields contribute extra shim slots after the dtor slots.
    const AsyncField = struct {
        name: []const u8,
        is_mem_op: bool,
        mem_op_slot: u32 = 0,
        satisfy_core_idx: u32 = 0,
    };
    const AsyncFamily = enum { task_return, stream, future, error_context, waitable_set, waitable, backpressure, task, subtask, context };
    const AsyncGroup = struct {
        module: []const u8,
        family: AsyncFamily,
        elem: ctypes.ValType,
        export_ref: []const u8,
        fields: []AsyncField,
        stream_type_idx: u32 = 0,
        results: ctypes.FuncType.ResultList = .none,
    };
    const stream_rw_params = [_]wtypes.ValType{ .i32, .i32, .i32 };
    const i32x2_params = [_]wtypes.ValType{ .i32, .i32 };
    const i32_results = [_]wtypes.ValType{.i32};
    var async_group_list = std.ArrayListUnmanaged(AsyncGroup).empty;
    var async_memop_slots = std.ArrayListUnmanaged(shim_mod.Slot).empty;
    if (core_imports.extract(ar, stripped_core)) |oi| {
        var modnames = std.ArrayListUnmanaged([]const u8).empty;
        var modfields = std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)).empty;
        for (oi.interface.imports) |im| {
            if (im.kind != .func) continue;
            if (!isAsyncIntrinsicModule(im.module_name)) continue;
            var gi: ?usize = null;
            for (modnames.items, 0..) |m, k| if (std.mem.eql(u8, m, im.module_name)) {
                gi = k;
                break;
            };
            if (gi == null) {
                try modnames.append(ar, try ar.dupe(u8, im.module_name));
                try modfields.append(ar, .empty);
                gi = modnames.items.len - 1;
            }
            try modfields.items[gi.?].append(ar, try ar.dupe(u8, im.field_name));
        }
        for (modnames.items, 0..) |module, mi| {
            const fsrc = modfields.items[mi].items;
            const fields = try ar.alloc(AsyncField, fsrc.len);
            if (std.mem.startsWith(u8, module, "[task-return]")) {
                for (fsrc, 0..) |f, k| fields[k] = .{ .name = f, .is_mem_op = false };
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .task_return,
                    .elem = .u8,
                    .export_ref = module["[task-return]".len..],
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[stream]")) {
                const elem = parseAsyncElement(module["[stream]".len..]) orelse
                    return error.UnsupportedAsyncIntrinsic;
                for (fsrc, 0..) |f, k| {
                    const mem_op = std.mem.eql(u8, f, "read") or std.mem.eql(u8, f, "write");
                    const no_mem = std.mem.eql(u8, f, "new") or
                        std.mem.eql(u8, f, "drop-readable") or std.mem.eql(u8, f, "drop-writable");
                    if (!mem_op and !no_mem) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = mem_op };
                    if (mem_op) {
                        fields[k].mem_op_slot = @intCast(async_memop_slots.items.len);
                        try async_memop_slots.append(ar, .{ .params = &stream_rw_params, .results = &i32_results });
                    }
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .stream,
                    .elem = elem,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[future]")) {
                const elem = parseAsyncElement(module["[future]".len..]) orelse
                    return error.UnsupportedAsyncIntrinsic;
                for (fsrc, 0..) |f, k| {
                    const mem_op = std.mem.eql(u8, f, "read") or std.mem.eql(u8, f, "write");
                    const no_mem = std.mem.eql(u8, f, "new") or
                        std.mem.eql(u8, f, "drop-readable") or std.mem.eql(u8, f, "drop-writable");
                    if (!mem_op and !no_mem) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = mem_op };
                    if (mem_op) {
                        fields[k].mem_op_slot = @intCast(async_memop_slots.items.len);
                        // future.read/write lower to (handle, ptr)->i32 — no
                        // count param (a future carries a single value).
                        try async_memop_slots.append(ar, .{ .params = &i32x2_params, .results = &i32_results });
                    }
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .future,
                    .elem = elem,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.eql(u8, module, "[error-context]")) {
                for (fsrc, 0..) |f, k| {
                    // new(ptr,len)->handle and debug-message(handle,retptr)
                    // read/write guest memory → mem-op; drop is no-memory.
                    const is_new = std.mem.eql(u8, f, "new");
                    const is_dm = std.mem.eql(u8, f, "debug-message");
                    const is_drop = std.mem.eql(u8, f, "drop");
                    if (!is_new and !is_dm and !is_drop) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = is_new or is_dm };
                    if (is_new) {
                        fields[k].mem_op_slot = @intCast(async_memop_slots.items.len);
                        try async_memop_slots.append(ar, .{ .params = &i32x2_params, .results = &i32_results });
                    } else if (is_dm) {
                        fields[k].mem_op_slot = @intCast(async_memop_slots.items.len);
                        try async_memop_slots.append(ar, .{ .params = &i32x2_params, .results = &.{} });
                    }
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .error_context,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[waitable-set]")) {
                for (fsrc, 0..) |f, k| {
                    // wait/poll write an event payload to a retptr → mem-op;
                    // new/drop are no-memory.
                    const mem_op = std.mem.eql(u8, f, "wait") or std.mem.eql(u8, f, "poll");
                    const no_mem = std.mem.eql(u8, f, "new") or std.mem.eql(u8, f, "drop");
                    if (!mem_op and !no_mem) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = mem_op };
                    if (mem_op) {
                        fields[k].mem_op_slot = @intCast(async_memop_slots.items.len);
                        // waitable-set.wait/poll lower to (set, event-ptr)->i32.
                        try async_memop_slots.append(ar, .{ .params = &i32x2_params, .results = &i32_results });
                    }
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .waitable_set,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[waitable]")) {
                for (fsrc, 0..) |f, k| {
                    if (!std.mem.eql(u8, f, "join")) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = false };
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .waitable,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[backpressure]")) {
                for (fsrc, 0..) |f, k| {
                    if (!std.mem.eql(u8, f, "inc") and !std.mem.eql(u8, f, "dec"))
                        return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = false };
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .backpressure,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[task]")) {
                for (fsrc, 0..) |f, k| {
                    if (!std.mem.eql(u8, f, "cancel")) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = false };
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .task,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[subtask]")) {
                for (fsrc, 0..) |f, k| {
                    if (!std.mem.eql(u8, f, "drop") and
                        !std.mem.eql(u8, f, "cancel") and
                        !std.mem.eql(u8, f, "cancel-async"))
                        return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = false };
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .subtask,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else if (std.mem.startsWith(u8, module, "[context]")) {
                for (fsrc, 0..) |f, k| {
                    if (parseContextField(f) == null) return error.UnsupportedAsyncIntrinsic;
                    fields[k] = .{ .name = f, .is_mem_op = false };
                }
                try async_group_list.append(ar, .{
                    .module = module,
                    .family = .context,
                    .elem = .u8,
                    .export_ref = "",
                    .fields = fields,
                });
            } else {
                // [future] / [waitable-set] / [waitable]
                return error.UnsupportedAsyncIntrinsic;
            }
        }
    } else |_| {}
    const async_groups = try async_group_list.toOwnedSlice(ar);
    const async_memop_count: u32 = @intCast(async_memop_slots.items.len);

    // ── Phase 3: build shim + fixup core wasm bytes. Slots are the
    //    wired imported funcs followed by one trampoline per dtor'd
    //    exported resource.
    const i32_slot = [_]wtypes.ValType{.i32};
    const shim_slots = try ar.alloc(shim_mod.Slot, total_wired + dtor_count + async_memop_count);
    {
        var k: usize = 0;
        for (wired_by_shape) |wired| for (wired) |w| {
            shim_slots[k] = .{ .params = w.slot_params, .results = w.slot_results };
            k += 1;
        };
        var d: usize = 0;
        while (d < dtor_count) : (d += 1) {
            shim_slots[total_wired + d] = .{ .params = &i32_slot, .results = &.{} };
        }
        // #263: async mem-op intrinsic slots follow the dtor slots, in
        // the order assigned during the async analysis above.
        for (async_memop_slots.items, 0..) |slot, j| {
            shim_slots[total_wired + dtor_count + j] = slot;
        }
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
    //    metadata's encoded body verbatim where possible. Cross-iface
    //    `alias outer (type 1 K)` decls inside the body reference
    //    slots in the metadata's world body — a scope we don't
    //    reconstruct verbatim in the wrapping component. Rebase
    //    those refs by walking the body, emitting top-level
    //    `alias instance_export sort=type` decls at the wrapping
    //    component level, and rewriting each `alias outer` to
    //    point at the new top-level slot (cataggar/wabt#206).
    //
    // To make the rebase work irrespective of shape iteration order
    // (a body in shape `i` may reference a type owned by shape `j`
    // with `j > i`), populate `import_inst_idx_for` for all shapes
    // first.
    var import_inst_idx_for = std.StringHashMapUnmanaged(u32).empty;
    for (import_shapes.items, 0..) |shape, i| {
        try import_inst_idx_for.put(ar, shape.qualified_name, @intCast(i));
    }

    // World-body resolution tables. The metadata's encoded world
    // body is the outer scope `alias outer (type 1 K)` body refs
    // resolve against.
    //
    // * `world_inst_qname[wii]` — qualified name of the instance
    //   import/export at world-body instance-index slot `wii`.
    // * `world_type_kind[K]`    — kind of the world-body type-index
    //   slot at position K. Only `.alias_instance_export` is
    //   rebased; everything else passes through.
    const WorldTypeKind = union(enum) {
        alias_instance_export: struct { world_inst_idx: u32, name: []const u8 },
        other,
    };
    var world_inst_qname = std.ArrayListUnmanaged([]const u8).empty;
    var world_type_kind = std.ArrayListUnmanaged(WorldTypeKind).empty;
    for (decoded.world_decls) |d| switch (d) {
        .type => try world_type_kind.append(ar, .other),
        .core_type => try world_type_kind.append(ar, .other),
        .alias => |a| switch (a) {
            .instance_export => |ie| if (ie.sort == .type) {
                try world_type_kind.append(ar, .{ .alias_instance_export = .{
                    .world_inst_idx = ie.instance_idx,
                    .name = ie.name,
                } });
            },
            .outer => |o| if (o.sort == .type) {
                try world_type_kind.append(ar, .other);
            },
        },
        .import => |im| switch (im.desc) {
            .instance => try world_inst_qname.append(ar, im.name),
            else => {},
        },
        .@"export" => |e| switch (e.desc) {
            .instance => try world_inst_qname.append(ar, e.name),
            else => {},
        },
    };

    // Cache: `<wrapping_inst_idx>::<name>` → new top-level
    // type-index slot. Reused across shapes — a single source type
    // referenced by multiple downstream bodies emits one alias.
    var rebase_cache = std.StringHashMapUnmanaged(u32).empty;

    const RebaseCtx = struct {
        ar: std.mem.Allocator,
        world_inst_qname: []const []const u8,
        world_type_kind: []const WorldTypeKind,
        import_inst_idx_for: *std.StringHashMapUnmanaged(u32),
        rebase_cache: *std.StringHashMapUnmanaged(u32),
        aliases: *std.ArrayListUnmanaged(ctypes.Alias),
        order: *std.ArrayListUnmanaged(ctypes.SectionEntry),
        comp_type_idx: *u32,

        /// Resolve `(world_inst_idx, name)` to a top-level
        /// type-index slot, emitting the alias if not cached.
        /// Returns `null` if the target's owning iface wasn't
        /// imported into the wrapping component.
        fn rebaseTarget(self: *@This(), wii: u32, name: []const u8) !?u32 {
            if (wii >= self.world_inst_qname.len) return null;
            const src_qname = self.world_inst_qname[wii];
            const wrapping_inst_idx = self.import_inst_idx_for.get(src_qname) orelse return null;
            const cache_key = try std.fmt.allocPrint(self.ar, "{d}::{s}", .{ wrapping_inst_idx, name });
            if (self.rebase_cache.get(cache_key)) |slot| return slot;
            try self.aliases.append(self.ar, .{ .instance_export = .{
                .sort = .type,
                .instance_idx = wrapping_inst_idx,
                .name = name,
            } });
            try self.order.append(self.ar, .{
                .kind = .alias,
                .start = @intCast(self.aliases.items.len - 1),
                .count = 1,
            });
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            try self.rebase_cache.put(self.ar, cache_key, slot);
            return slot;
        }

        /// Walk `body`, rewriting each cross-iface alias decl to
        /// point at a wrapping-component-scope slot. Returns a
        /// freshly-allocated decl slice with the same length and
        /// the same body-local type-indexspace shape.
        fn rebaseInstDecls(self: *@This(), body: []const ctypes.Decl) ![]ctypes.Decl {
            const out = try self.ar.alloc(ctypes.Decl, body.len);
            for (body, 0..) |d, i| {
                out[i] = blk: switch (d) {
                    .alias => |a| switch (a) {
                        .outer => |o| {
                            if (o.sort != .type or o.outer_count != 1) break :blk d;
                            if (o.idx >= self.world_type_kind.len) break :blk d;
                            switch (self.world_type_kind[o.idx]) {
                                .alias_instance_export => |ie| {
                                    const new_slot = (try self.rebaseTarget(ie.world_inst_idx, ie.name)) orelse break :blk d;
                                    break :blk .{ .alias = .{ .outer = .{
                                        .sort = .type,
                                        .outer_count = 1,
                                        .idx = new_slot,
                                    } } };
                                },
                                .other => break :blk d,
                            }
                        },
                        .instance_export => |ie| {
                            // Body-side `alias instance_export
                            // sort=type` references the outer
                            // (world) instance indexspace. Rebase
                            // identically; rewrite as an
                            // `alias outer` pointing at the new
                            // top-level slot.
                            if (ie.sort != .type) break :blk d;
                            const new_slot = (try self.rebaseTarget(ie.instance_idx, ie.name)) orelse break :blk d;
                            break :blk .{ .alias = .{ .outer = .{
                                .sort = .type,
                                .outer_count = 1,
                                .idx = new_slot,
                            } } };
                        },
                    },
                    else => d,
                };
            }
            return out;
        }
    };

    var rebase_ctx = RebaseCtx{
        .ar = ar,
        .world_inst_qname = world_inst_qname.items,
        .world_type_kind = world_type_kind.items,
        .import_inst_idx_for = &import_inst_idx_for,
        .rebase_cache = &rebase_cache,
        .aliases = &aliases,
        .order = &order,
        .comp_type_idx = &comp_type_idx,
    };

    for (import_shapes.items) |shape| {
        const rebased = try rebase_ctx.rebaseInstDecls(shape.inst_decls);
        try types.append(ar, .{ .instance = .{ .decls = rebased } });
        try Section.appendType(&order, ar, types.items.len);
        const inst_type_idx = comp_type_idx;
        comp_type_idx += 1;
        try imports.append(ar, .{
            .name = shape.qualified_name,
            .desc = .{ .instance = inst_type_idx },
        });
        try order.append(ar, .{ .kind = .import, .start = @intCast(imports.items.len - 1), .count = 1 });
    }
    const import_inst_count: u32 = @intCast(imports.items.len);

    // ── #248/#250: resolve resource built-in intrinsic imports.
    //    Import-side group by import shape; export-side (`[export]…`)
    //    operate on a guest-defined resource.
    const intrinsics = try collectResourceIntrinsics(ar, stripped_core);
    // #251: validate the intrinsics' declared core import sigs against
    // their fixed canonical-ABI shapes before wiring them.
    try validateResourceIntrinsicSigs(alloc, ar, stripped_core, intrinsics);
    const parts = try partitionResourceIntrinsics(ar, intrinsics, exported_resources);
    const shape_qnames = try ar.alloc([]const u8, import_shapes.items.len);
    for (import_shapes.items, 0..) |s, i| shape_qnames[i] = s.qualified_name;
    const intrinsics_by_shape = try resolveResourceIntrinsicsByShape(
        ar,
        parts.import_side,
        shape_qnames,
        &resource_owner,
        &import_inst_idx_for,
    );
    const export_groups = try groupExportSideByModule(ar, parts.export_side);
    var intrinsic_resource_alias = std.StringHashMapUnmanaged(u32).empty;
    // #250: resource name → component type idx of the exported
    // resource type declared below (Step 2.5).
    var exported_resource_type_idx = std.StringHashMapUnmanaged(u32).empty;

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

    // Emit the shim instance as its own core-instance section now, so
    // the stub aliases that follow (which reference it) validate
    // against an already-defined core instance. The writer emits
    // sections strictly in `order` sequence, so a single core-instance
    // section at the end would place every instance *after* the alias
    // sections that name them — invalid (#234).
    try order.append(ar, .{ .kind = .core_instance, .start = shim_inst_idx, .count = 1 });

    // Step 2: alias the shim's stubs by name ("0","1",…) as core
    // funcs. These become the source funcs for the per-shape
    // bundles that satisfy main's `(with …)` args. The last
    // `dtor_count` stubs are the destructor trampolines (#250).
    const shim_stub_core_idx_base = core_func_idx;
    {
        var k: u32 = 0;
        while (k < total_wired + dtor_count + async_memop_count) : (k += 1) {
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
    const dtor_stub_core_base = shim_stub_core_idx_base + total_wired;
    // #263: async mem-op stub core funcs follow the dtor stubs.
    const async_memop_stub_core_base = dtor_stub_core_base + dtor_count;

    // ── #250 Step 2.5: declare each guest-defined (exported) resource
    //    type. A dtor'd resource references its shim destructor stub
    //    (aliased above) as a core func; the fixup later patches that
    //    stub to call main's real `<iface>#[dtor]<R>` export. These
    //    types must precede the export-side intrinsic canons and the
    //    Phase 5 lifted func types that reference them.
    for (exported_resources) |er| {
        if (exported_resource_type_idx.contains(er.name)) continue;
        var dtor_idx: ?u32 = null;
        if (er.dtor_export != null) {
            for (dtor_resources.items, 0..) |dr, d| {
                if (std.mem.eql(u8, dr.name, er.name)) {
                    dtor_idx = dtor_stub_core_base + @as(u32, @intCast(d));
                    break;
                }
            }
        }
        try types.append(ar, .{ .resource = .{ .destructor = dtor_idx } });
        try Section.appendType(&order, ar, types.items.len);
        try exported_resource_type_idx.put(ar, er.name, comp_type_idx);
        comp_type_idx += 1;
    }

    // ── #248: emit a resource-type alias + `canon resource.{drop,
    //    new,rep}` per resource intrinsic. These need no canon opts
    //    and don't reference main's memory/realloc, so — unlike the
    //    method lowers (Phase 4f) — they can be emitted *before* the
    //    main bundle and placed directly into it; no shim/fixup
    //    trampoline is required. Their core funcs follow the shim
    //    stubs in the core-func indexspace.
    const intrinsic_core_idx_by_shape = try ar.alloc([]u32, import_shapes.items.len);
    for (intrinsics_by_shape, 0..) |drops, si| {
        const idxs = try ar.alloc(u32, drops.len);
        for (drops, 0..) |d, di| {
            const type_idx = intrinsic_resource_alias.get(d.resource) orelse blk: {
                try aliases.append(ar, .{ .instance_export = .{
                    .sort = .type,
                    .instance_idx = d.owner_inst_idx,
                    .name = d.resource,
                } });
                try Section.appendAlias(&order, ar, aliases.items.len);
                const idx = comp_type_idx;
                comp_type_idx += 1;
                try intrinsic_resource_alias.put(ar, d.resource, idx);
                break :blk idx;
            };
            try canons.append(ar, canonForIntrinsic(d.kind, type_idx));
            try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
            idxs[di] = core_func_idx;
            core_func_idx += 1;
        }
        intrinsic_core_idx_by_shape[si] = idxs;
    }

    // ── #250: export-side resource intrinsics. `canon resource.{new,
    //    rep,drop} <exported R type>` referencing the resource types
    //    declared in Step 2.5; their core funcs follow the import-side
    //    intrinsics. Grouped into a bundle per `[export]<iface>` below.
    const export_group_core_idxs = try ar.alloc([]u32, export_groups.len);
    for (export_groups, 0..) |group, gi| {
        const idxs = try ar.alloc(u32, group.len);
        for (group, 0..) |it, j| {
            const type_idx = exported_resource_type_idx.get(it.resource).?;
            try canons.append(ar, canonForIntrinsic(it.kind, type_idx));
            try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
            idxs[j] = core_func_idx;
            core_func_idx += 1;
        }
        export_group_core_idxs[gi] = idxs;
    }

    // ── #263: async-intrinsic canons. No-memory ops (task.return,
    //    stream.{new,drop-readable,drop-writable}) are emitted now as
    //    direct core funcs; memory-opt ops (stream.read/.write) are
    //    satisfied by their shim stub here, with the real `(memory)`
    //    canon emitted in Phase 4f.2 and patched in by the fixup.
    const AsyncTypeCtx = struct {
        ar: std.mem.Allocator,
        types: *std.ArrayListUnmanaged(ctypes.TypeDef),
        order: *std.ArrayListUnmanaged(ctypes.SectionEntry),
        comp_type_idx: *u32,
        pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
            try self.types.append(self.ar, td);
            try Section.appendType(self.order, self.ar, self.types.items.len);
            const idx = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            return idx;
        }
        pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
            _ = self;
            return v;
        }
    };
    for (async_groups) |*grp| {
        switch (grp.family) {
            .stream => {
                try types.append(ar, .{ .stream = .{ .element = grp.elem } });
                try Section.appendType(&order, ar, types.items.len);
                grp.stream_type_idx = comp_type_idx;
                comp_type_idx += 1;
                for (grp.fields) |*field| {
                    if (field.is_mem_op) {
                        field.satisfy_core_idx = async_memop_stub_core_base + field.mem_op_slot;
                        continue;
                    }
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field.name, "new"))
                        .{ .stream_new = grp.stream_type_idx }
                    else if (std.mem.eql(u8, field.name, "drop-readable"))
                        .{ .stream_drop_readable = grp.stream_type_idx }
                    else
                        .{ .stream_drop_writable = grp.stream_type_idx };
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .future => {
                try types.append(ar, .{ .future = .{ .element = grp.elem } });
                try Section.appendType(&order, ar, types.items.len);
                grp.stream_type_idx = comp_type_idx;
                comp_type_idx += 1;
                for (grp.fields) |*field| {
                    if (field.is_mem_op) {
                        field.satisfy_core_idx = async_memop_stub_core_base + field.mem_op_slot;
                        continue;
                    }
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field.name, "new"))
                        .{ .future_new = grp.stream_type_idx }
                    else if (std.mem.eql(u8, field.name, "drop-readable"))
                        .{ .future_drop_readable = grp.stream_type_idx }
                    else
                        .{ .future_drop_writable = grp.stream_type_idx };
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .waitable_set => {
                for (grp.fields) |*field| {
                    if (field.is_mem_op) {
                        field.satisfy_core_idx = async_memop_stub_core_base + field.mem_op_slot;
                        continue;
                    }
                    // `new` / `drop` are no-memory; `wait`/`poll` are mem-op.
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field.name, "new"))
                        .waitable_set_new
                    else
                        .waitable_set_drop;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .waitable => {
                for (grp.fields) |*field| {
                    // only `join`, no-memory.
                    try canons.append(ar, .waitable_join);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .error_context => {
                for (grp.fields) |*field| {
                    if (field.is_mem_op) {
                        field.satisfy_core_idx = async_memop_stub_core_base + field.mem_op_slot;
                        continue;
                    }
                    // only `drop` is no-memory.
                    try canons.append(ar, .error_context_drop);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .task_return => {
                const export_ref = grp.export_ref;
                const hash = std.mem.lastIndexOfScalar(u8, export_ref, '#') orelse
                    return error.UnsupportedAsyncIntrinsic;
                const iface_name = export_ref[0..hash];
                const fn_name = export_ref[hash + 1 ..];
                const ctx = AsyncTypeCtx{ .ar = ar, .types = &types, .order = &order, .comp_type_idx = &comp_type_idx };
                var results: ctypes.FuncType.ResultList = .none;
                var found_export = false;
                find2: for (decoded.externs) |ext| {
                    if (!ext.is_export) continue;
                    if (!std.mem.eql(u8, ext.qualified_name, iface_name)) continue;
                    for (ext.funcs) |fn_ref| {
                        if (!std.mem.eql(u8, fn_ref.name, fn_name)) continue;
                        results = switch (fn_ref.sig.results) {
                            .none => .none,
                            .unnamed => |v| .{ .unnamed = try lift_types.transcribeValType(ar, ctx, ext.type_slots, v) },
                            .named => |named| nb: {
                                const dst = try ar.alloc(ctypes.NamedValType, named.len);
                                for (named, 0..) |nv, kk| dst[kk] = .{
                                    .name = nv.name,
                                    .type = try lift_types.transcribeValType(ar, ctx, ext.type_slots, nv.type),
                                };
                                break :nb .{ .named = dst };
                            },
                        };
                        found_export = true;
                        break :find2;
                    }
                }
                if (!found_export) return error.UnsupportedAsyncIntrinsic;
                grp.results = results;
                for (grp.fields) |*field| {
                    try canons.append(ar, .{ .task_return = .{ .results = results, .opts = &.{} } });
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .backpressure => {
                for (grp.fields) |*field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field.name, "inc"))
                        .backpressure_inc
                    else
                        .backpressure_dec;
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .task => {
                for (grp.fields) |*field| {
                    // only `cancel`, no-memory.
                    try canons.append(ar, .task_cancel);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .subtask => {
                for (grp.fields) |*field| {
                    const canon: ctypes.Canon = if (std.mem.eql(u8, field.name, "drop"))
                        .subtask_drop
                    else if (std.mem.eql(u8, field.name, "cancel-async"))
                        .{ .subtask_cancel = true }
                    else
                        .{ .subtask_cancel = false };
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
            .context => {
                for (grp.fields) |*field| {
                    const cf = parseContextField(field.name) orelse return error.UnsupportedAsyncIntrinsic;
                    const canon: ctypes.Canon = if (cf.is_set)
                        .{ .context_set = .{ .ty = cf.ty, .slot = cf.slot } }
                    else
                        .{ .context_get = .{ .ty = cf.ty, .slot = cf.slot } };
                    try canons.append(ar, canon);
                    try order.append(ar, .{ .kind = .canon, .start = @intCast(canons.items.len - 1), .count = 1 });
                    field.satisfy_core_idx = core_func_idx;
                    core_func_idx += 1;
                }
            },
        }
    }

    // Step 3: per import shape, build an inline-exports bundle
    // mapping each wired func's canonical method name to its shim
    // stub (plus any #248 resource intrinsics to their direct core
    // funcs). Bundle indices live in the core-instance indexspace.
    var bundle_for_main_args = std.ArrayListUnmanaged(ctypes.CoreInstantiateArg).empty;
    {
        var stub_cursor: u32 = shim_stub_core_idx_base;
        for (import_shapes.items, 0..) |shape, i| {
            const wired = wired_by_shape[i];
            const drops = intrinsics_by_shape[i];
            if (wired.len == 0 and drops.len == 0) continue;
            const bundle_exports = try ar.alloc(ctypes.CoreInlineExport, wired.len + drops.len);
            for (wired, 0..) |w, fi| {
                bundle_exports[fi] = .{
                    .name = w.fn_ref.name,
                    .sort_idx = .{ .sort = .func, .idx = stub_cursor },
                };
                stub_cursor += 1;
            }
            for (drops, 0..) |d, di| {
                bundle_exports[wired.len + di] = .{
                    .name = d.field,
                    .sort_idx = .{ .sort = .func, .idx = intrinsic_core_idx_by_shape[i][di] },
                };
            }
            try core_instances.append(ar, .{ .exports = bundle_exports });
            const bundle_inst_idx: u32 = @intCast(core_instances.items.len - 1);
            try bundle_for_main_args.append(ar, .{
                .name = shape.qualified_name,
                .instance_idx = bundle_inst_idx,
            });
        }
        // #250: one bundle per `[export]<iface>` module.
        for (export_groups, 0..) |group, gi| {
            const bundle_exports = try ar.alloc(ctypes.CoreInlineExport, group.len);
            for (group, 0..) |it, j| {
                bundle_exports[j] = .{
                    .name = it.field,
                    .sort_idx = .{ .sort = .func, .idx = export_group_core_idxs[gi][j] },
                };
            }
            try core_instances.append(ar, .{ .exports = bundle_exports });
            try bundle_for_main_args.append(ar, .{
                .name = group[0].module,
                .instance_idx = @intCast(core_instances.items.len - 1),
            });
        }
        // #263: one bundle per async-intrinsic module; each field maps to
        // its satisfying core func (a direct canon for no-memory ops, a
        // shim stub for memory-opt ops).
        for (async_groups) |grp| {
            const be = try ar.alloc(ctypes.CoreInlineExport, grp.fields.len);
            for (grp.fields, 0..) |field, k| {
                be[k] = .{ .name = field.name, .sort_idx = .{ .sort = .func, .idx = field.satisfy_core_idx } };
            }
            try core_instances.append(ar, .{ .exports = be });
            try bundle_for_main_args.append(ar, .{
                .name = grp.module,
                .instance_idx = @intCast(core_instances.items.len - 1),
            });
        }
    }

    // Step 4: instantiate main with the per-shape bundles as args.
    try core_instances.append(ar, .{ .instantiate = .{
        .module_idx = 0,
        .args = try bundle_for_main_args.toOwnedSlice(ar),
    } });
    const main_core_inst_idx: u32 = @intCast(core_instances.items.len - 1);

    // Flush the per-shape bundles + main instance as a core-instance
    // section before the memory/realloc aliases (Phase 4d) and the
    // `$imports` table alias (Phase 4e) that reference them (#234).
    try order.append(ar, .{
        .kind = .core_instance,
        .start = shim_inst_idx + 1,
        .count = main_core_inst_idx - shim_inst_idx,
    });

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

    // ── #263 Phase 4f.2: real memory-opt async canons (stream.read /
    //    .write, future.read / .write, error-context.new / .debug-message)
    //    with `(memory)` / `(realloc)` opts pointing at main. Emitted in
    //    mem-op-slot order so slot j ↔ `async_memop_real_core_base + j`;
    //    the fixup (Phase 4g) patches each shim stub to call these.
    const async_memop_real_core_base = core_func_idx;
    {
        const memop_start: u32 = @intCast(canons.items.len);
        const mem_realloc = [_]ctypes.CanonOpt{ .{ .memory = memory_core_idx }, .{ .realloc = realloc_core_idx } };
        for (async_groups) |grp| {
            for (grp.fields) |field| {
                if (!field.is_mem_op) continue;
                const canon: ctypes.Canon = switch (grp.family) {
                    .stream => blk: {
                        const opts = try ar.dupe(ctypes.CanonOpt, &.{.{ .memory = memory_core_idx }});
                        break :blk if (std.mem.eql(u8, field.name, "write"))
                            .{ .stream_write = .{ .type_idx = grp.stream_type_idx, .opts = opts } }
                        else
                            .{ .stream_read = .{ .type_idx = grp.stream_type_idx, .opts = opts } };
                    },
                    .future => blk: {
                        const opts = try ar.dupe(ctypes.CanonOpt, &.{.{ .memory = memory_core_idx }});
                        break :blk if (std.mem.eql(u8, field.name, "write"))
                            .{ .future_write = .{ .type_idx = grp.stream_type_idx, .opts = opts } }
                        else
                            .{ .future_read = .{ .type_idx = grp.stream_type_idx, .opts = opts } };
                    },
                    .error_context => blk: {
                        const opts = try ar.dupe(ctypes.CanonOpt, &mem_realloc);
                        break :blk if (std.mem.eql(u8, field.name, "new"))
                            .{ .error_context_new = opts }
                        else
                            .{ .error_context_debug_message = opts };
                    },
                    .waitable_set => if (std.mem.eql(u8, field.name, "poll"))
                        // wait/poll carry a bare memory index (not a CanonOpt
                        // list); cancellable=false for a plain blocking wait.
                        .{ .waitable_set_poll = .{ .cancellable = false, .memory = memory_core_idx } }
                    else
                        .{ .waitable_set_wait = .{ .cancellable = false, .memory = memory_core_idx } },
                    .waitable => unreachable, // waitable.join is never mem-op
                    .task_return => unreachable, // task.return is never mem-op
                    .backpressure => unreachable, // backpressure.inc/dec are never mem-op
                    .task => unreachable, // task.cancel is never mem-op
                    .subtask => unreachable, // subtask.drop/cancel are never mem-op
                    .context => unreachable, // context.get/set are never mem-op
                };
                try canons.append(ar, canon);
                core_func_idx += 1;
            }
        }
        const memop_count: u32 = @as(u32, @intCast(canons.items.len)) - memop_start;
        if (memop_count > 0) {
            try order.append(ar, .{ .kind = .canon, .start = memop_start, .count = memop_count });
        }
    }
    //    `<iface>#[dtor]<R>` as core funcs. The fixup writes these into
    //    the shim table slots so the destructor trampolines forward to
    //    the guest's real destructors.
    const dtor_main_core_base = core_func_idx;
    for (dtor_resources.items) |dr| {
        try aliases.append(ar, .{ .instance_export = .{
            .sort = .{ .core = .func },
            .instance_idx = main_core_inst_idx,
            .name = dr.dtor_export.?,
        } });
        try Section.appendAlias(&order, ar, aliases.items.len);
        core_func_idx += 1;
    }

    // ── Phase 4g: build the fixup module's args bundle. Maps each
    //    slot's stable name ("0","1",…) to the lowered core func at
    //    `lowered_core_idx_base + i` (and each destructor slot to
    //    main's real dtor export), plus `$imports` → the shim's
    //    table. Then instantiate fixup with this bundle.
    {
        const bundle_size = total_wired + dtor_count + async_memop_count + 1;
        const bundle = try ar.alloc(ctypes.CoreInlineExport, bundle_size);
        var k: u32 = 0;
        while (k < total_wired) : (k += 1) {
            const name = try std.fmt.allocPrint(ar, "{d}", .{k});
            bundle[k] = .{
                .name = name,
                .sort_idx = .{ .sort = .func, .idx = lowered_core_idx_base + k },
            };
        }
        var d: u32 = 0;
        while (d < dtor_count) : (d += 1) {
            const name = try std.fmt.allocPrint(ar, "{d}", .{total_wired + d});
            bundle[total_wired + d] = .{
                .name = name,
                .sort_idx = .{ .sort = .func, .idx = dtor_main_core_base + d },
            };
        }
        // #263: async mem-op slots → their real `(memory)` canon funcs.
        var a: u32 = 0;
        while (a < async_memop_count) : (a += 1) {
            const name = try std.fmt.allocPrint(ar, "{d}", .{total_wired + dtor_count + a});
            bundle[total_wired + dtor_count + a] = .{
                .name = name,
                .sort_idx = .{ .sort = .func, .idx = async_memop_real_core_base + a },
            };
        }
        bundle[total_wired + dtor_count + async_memop_count] = .{
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

    // Final core-instance section: the fixup-args bundle + fixup
    // instance (Phase 4g). It follows the canon.lower section (Phase
    // 4f) because the fixup args reference the lowered core funcs, and
    // follows the `$imports` alias (Phase 4e) (#234).
    try order.append(ar, .{
        .kind = .core_instance,
        .start = main_core_inst_idx + 1,
        .count = @as(u32, @intCast(core_instances.items.len)) - (main_core_inst_idx + 1),
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
        exported_resource_type_idx: *std.StringHashMapUnmanaged(u32),
        hoist_keys: *std.ArrayListUnmanaged(HandleKey),
        hoist_idxs: *std.ArrayListUnmanaged(u32),
        comp_type_idx: *u32,
        order: *std.ArrayListUnmanaged(ctypes.SectionEntry),

        fn resourceAlias(self: @This(), name: []const u8) !u32 {
            // #250: guest-defined (exported) resource → its declared
            // resource type in this component.
            if (self.exported_resource_type_idx.get(name)) |idx| return idx;
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
            return lift_types.transcribeValType(self.ar, self, self.ext_slots, v);
        }

        /// Append a defined type to the component type section and
        /// return its component-level type index. Used by the shared
        /// `lift_types` transcriber to hoist compound value types.
        pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
            try self.types.append(self.ar, td);
            try Section.appendType(self.order, self.ar, self.types.items.len);
            const slot = self.comp_type_idx.*;
            self.comp_type_idx.* += 1;
            return slot;
        }

        /// Resolve a leaf value type the transcriber doesn't hoist:
        /// resource handles become defined handle types via
        /// `hoistHandle`; anything else passes through unchanged.
        pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
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
            return .{ .params = params, .results = results, .is_async = sig.is_async };
        }
    };

    const CapturedFunc = struct {
        ext_qualified: []const u8,
        fn_name: []const u8,
        func_type_idx: u32,
        core_func_alias_idx: u32,
        lift_opts: abi.LiftOpts,
        post_return_core_idx: ?u32,
        is_async: bool,
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
            .exported_resource_type_idx = &exported_resource_type_idx,
            .hoist_keys = &hoist_keys,
            .hoist_idxs = &hoist_idxs,
            .comp_type_idx = &comp_type_idx,
            .order = &order,
        };
        const start: u32 = @intCast(captured_funcs.items.len);
        const lift_resolver = abi.TypeResolver{
            .inst_decls = ext.inst_decls,
            .world_decls = decoded.world_decls,
        };
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

            // #253: lift options for this exported func, plus an
            // optional `(post-return cabi_post_<name>)` when its result
            // needs cleanup and the guest exports the matching
            // `cabi_post_*` core func.
            const lift_opts = abi.classifyFuncLift(.{ .func = fn_ref.sig, .resolver = lift_resolver });
            var post_idx: ?u32 = null;
            if (lift_opts.needs_post_return) {
                const cabi_post_name = try std.fmt.allocPrint(ar, "cabi_post_{s}", .{core_func_export_name});
                if (coreExportsFunc(stripped_core, cabi_post_name) catch false) {
                    try aliases.append(ar, .{ .instance_export = .{
                        .sort = .{ .core = .func },
                        .instance_idx = main_core_inst_idx,
                        .name = cabi_post_name,
                    } });
                    try Section.appendAlias(&order, ar, aliases.items.len);
                    post_idx = core_func_idx;
                    core_func_idx += 1;
                }
            }

            try captured_funcs.append(ar, .{
                .ext_qualified = ext.qualified_name,
                .fn_name = fn_ref.name,
                .func_type_idx = func_type_idx,
                .core_func_alias_idx = cf_idx,
                .lift_opts = lift_opts,
                .post_return_core_idx = post_idx,
                .is_async = fn_ref.sig.is_async,
            });
        }
        try ext_export_start.append(ar, .{ .ext = ext, .start = start });
    }

    const lifts_start: u32 = @intCast(canons.items.len);
    for (captured_funcs.items) |cf| {
        var opts = try wabt.component.adapter.adapter.buildCanonLiftOpts(
            ar,
            cf.lift_opts,
            memory_core_idx,
            realloc_core_idx,
            cf.post_return_core_idx,
        );
        // #263: async exports lift with the `async` canon option.
        if (cf.is_async) {
            const ext_opts = try ar.alloc(ctypes.CanonOpt, opts.len + 1);
            @memcpy(ext_opts[0..opts.len], opts);
            ext_opts[opts.len] = .async_;
            opts = ext_opts;
        }
        try canons.append(ar, .{ .lift = .{
            .core_func_idx = cf.core_func_alias_idx,
            .type_idx = cf.func_type_idx,
            .opts = opts,
        } });
    }
    const lifts_count: u32 = @as(u32, @intCast(canons.items.len)) - lifts_start;

    var nested_components = std.ArrayListUnmanaged(*ctypes.Component).empty;
    for (ext_export_start.items, 0..) |es, ei| {
        const end: u32 = if (ei + 1 < ext_export_start.items.len)
            ext_export_start.items[ei + 1].start
        else
            @intCast(captured_funcs.items.len);
        const fn_count = end - es.start;

        var res_names = std.ArrayListUnmanaged([]const u8).empty;
        for (exported_resources) |er| {
            if (std.mem.eql(u8, er.ext_qualified, es.ext.qualified_name)) try res_names.append(ar, er.name);
        }

        const func_comp_idx = try ar.alloc(u32, fn_count);
        for (0..fn_count) |i| {
            func_comp_idx[i] = comp_func_idx;
            comp_func_idx += 1;
        }

        if (res_names.items.len == 0) {
            var inline_exports = try ar.alloc(ctypes.InlineExport, fn_count);
            for (0..fn_count) |i| {
                const cf = captured_funcs.items[es.start + i];
                inline_exports[i] = .{
                    .name = cf.fn_name,
                    .sort_idx = .{ .sort = .func, .idx = func_comp_idx[i] },
                };
            }
            try instances.append(ar, .{ .exports = inline_exports });
        } else {
            // #250: interface defines resources → nested sub-component
            // performing the required type-export binding.
            const nested = try buildExportInterfaceComponent(ar, es.ext, res_names.items);
            try nested_components.append(ar, nested);
            const comp_idx: u32 = @intCast(nested_components.items.len - 1);
            var args = std.ArrayListUnmanaged(ctypes.InstantiateArg).empty;
            for (res_names.items) |rn| {
                try args.append(ar, .{
                    .name = try nestedTypeImportName(ar, rn),
                    .sort_idx = .{ .sort = .type, .idx = exported_resource_type_idx.get(rn).? },
                });
            }
            for (0..fn_count) |i| {
                try args.append(ar, .{
                    .name = try nestedFuncImportName(ar, i),
                    .sort_idx = .{ .sort = .func, .idx = func_comp_idx[i] },
                });
            }
            try instances.append(ar, .{ .instantiate = .{
                .component_idx = comp_idx,
                .args = try args.toOwnedSlice(ar),
            } });
        }
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
    if (nested_components.items.len > 0) {
        try order.append(ar, .{ .kind = .component, .start = 0, .count = @intCast(nested_components.items.len) });
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
        .components = try nested_components.toOwnedSlice(ar),
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

test "buildComponent #206: cross-iface use in imported method body triggers outer-alias rebase" {
    // Reproducer for #206 (follow-up to #203). One imported iface
    // (`api`) `use`s a resource from another imported iface
    // (`streams`); its method's `string` param forces shim/fixup.
    // The encoded `api` body contains an
    // `alias outer (type 1 K)` whose K points at the metadata's
    // world body — a scope the wrapping component doesn't
    // reconstruct verbatim. Before this fix the body lift was
    // dangling; after the fix the wrapping component emits a
    // top-level `alias instance_export sort=.type` from the
    // `streams` import instance and rewrites the body's outer
    // alias to point at that new top-level slot.
    //
    // Synth core wasm: identical layout to #203a (handle export +
    // memory + cabi_realloc), reused for convenience. The `api`
    // import's wired `consume` func is unused by the core but
    // still gets a canon.lower + shim slot.
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
        \\package docs:demo@0.1.0;
        \\
        \\interface streams {
        \\    resource input-stream { }
        \\}
        \\
        \\interface api {
        \\    use streams.{input-stream};
        \\    consume: func(name: string) -> own<input-stream>;
        \\}
        \\
        \\interface incoming-handler {
        \\    handle: func();
        \\}
        \\
        \\world demo {
        \\    import streams;
        \\    import api;
        \\    export incoming-handler;
        \\}
    , "demo");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:demo";
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

    // (1) Shim/fixup path — three core modules.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);

    // (2) Two instance imports — `streams` (idx 0) + `api` (idx 1).
    try testing.expectEqual(@as(usize, 2), loaded.imports.len);
    try testing.expectEqualStrings("docs:demo/streams@0.1.0", loaded.imports[0].name);
    try testing.expectEqualStrings("docs:demo/api@0.1.0", loaded.imports[1].name);

    // (3) A top-level `alias instance_export sort=.type` rebased
    // from `streams` exposes `input-stream` at wrapping-component
    // scope. This is the alias the rebase pass emits so the
    // `api` body's `alias outer` no longer dangles.
    var saw_rebased_alias = false;
    var rebased_alias_slot: ?u32 = null;
    for (loaded.type_indexspace, 0..) |contrib, slot| {
        if (contrib != .alias) continue;
        const a = loaded.aliases[contrib.alias];
        if (a != .instance_export) continue;
        const ie = a.instance_export;
        if (ie.sort == .type and
            ie.instance_idx == 0 and
            std.mem.eql(u8, ie.name, "input-stream"))
        {
            saw_rebased_alias = true;
            rebased_alias_slot = @intCast(slot);
        }
    }
    try testing.expect(saw_rebased_alias);
    try testing.expect(rebased_alias_slot != null);

    // (4) The `api` body's `alias outer (type 1 K)` decls have
    // been rewritten: K now points at a wrapping-component slot
    // whose contributor is an `alias instance_export sort=.type`
    // (i.e. the rebased alias from (3)), not at a dangling
    // metadata-world-body slot.
    const api_inst_type_idx = loaded.imports[1].desc.instance;
    const api_inst_contrib = loaded.type_indexspace[api_inst_type_idx];
    try testing.expect(api_inst_contrib == .type_def);
    const api_inst_td = loaded.types[api_inst_contrib.type_def];
    try testing.expect(api_inst_td == .instance);
    var saw_rebased_body_outer = false;
    for (api_inst_td.instance.decls) |d| switch (d) {
        .alias => |a| switch (a) {
            .outer => |o| {
                if (o.sort != .type) continue;
                try testing.expectEqual(@as(u32, 1), o.outer_count);
                // The rewritten idx must land on the top-level
                // rebased alias slot — both the value and the
                // contributor kind must match.
                try testing.expect(o.idx < loaded.type_indexspace.len);
                const contrib = loaded.type_indexspace[o.idx];
                try testing.expect(contrib == .alias);
                const top_alias = loaded.aliases[contrib.alias];
                try testing.expect(top_alias == .instance_export);
                try testing.expect(top_alias.instance_export.sort == .type);
                try testing.expectEqualStrings("input-stream", top_alias.instance_export.name);
                try testing.expectEqual(@as(u32, 0), top_alias.instance_export.instance_idx);
                saw_rebased_body_outer = true;
            },
            else => {},
        },
        else => {},
    };
    try testing.expect(saw_rebased_body_outer);

    // (5) `consume` is wired with full canon-lower opts (string
    // param forces memory + utf8 encoding; the `own<input-stream>`
    // result is a scalar handle so no realloc needed). At least
    // one canon.lower carries memory + string_encoding.
    var saw_consume_opts = false;
    for (loaded.canons) |c| switch (c) {
        .lower => |l| {
            var has_memory = false;
            var has_encoding = false;
            for (l.opts) |o| switch (o) {
                .memory => has_memory = true,
                .string_encoding => has_encoding = true,
                else => {},
            };
            if (has_memory and has_encoding) saw_consume_opts = true;
        },
        else => {},
    };
    try testing.expect(saw_consume_opts);
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
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/http", .dst_rel = "wit" },
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/cli", .dst_rel = "wit/deps/cli" },
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/clocks", .dst_rel = "wit/deps/clocks" },
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/filesystem", .dst_rel = "wit/deps/filesystem" },
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/io", .dst_rel = "wit/deps/io" },
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/random", .dst_rel = "wit/deps/random" },
        .{ .src_dir = "src/component/wit/wasi-canon/0.2.6/sockets", .dst_rel = "wit/deps/sockets" },
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

    // (#206) Cross-iface alias rebase: every `alias outer (type 1
    // K)` decl inside any transplanted imported instance-type body
    // resolves into the wrapping-component typespace (not into the
    // dangling metadata-world-body typespace it referred to before
    // the rebase pass). For each imported instance type body in
    // the wrapping component, walk its decls and assert each
    // `alias outer` lands on a top-level slot whose contributor is
    // a `alias instance_export sort=.type` from an instance import
    // of the wrapping component.
    //
    // We also assert that at least one such rebased outer-alias
    // exists — the canonical wasi-http proxy world has dozens of
    // `use` clauses across `wasi:http/*`, so the rebase must have
    // fired on this fixture.
    var n_rebased: usize = 0;
    for (loaded.imports) |imp| {
        if (imp.desc != .instance) continue;
        const inst_type_idx = imp.desc.instance;
        if (inst_type_idx >= loaded.type_indexspace.len) continue;
        const contrib = loaded.type_indexspace[inst_type_idx];
        if (contrib != .type_def) continue;
        const td = loaded.types[contrib.type_def];
        if (td != .instance) continue;
        for (td.instance.decls) |d| switch (d) {
            .alias => |a| switch (a) {
                .outer => |o| {
                    if (o.sort != .type) continue;
                    try testing.expectEqual(@as(u32, 1), o.outer_count);
                    try testing.expect(o.idx < loaded.type_indexspace.len);
                    const tgt = loaded.type_indexspace[o.idx];
                    try testing.expect(tgt == .alias);
                    const top_alias = loaded.aliases[tgt.alias];
                    try testing.expect(top_alias == .instance_export);
                    try testing.expect(top_alias.instance_export.sort == .type);
                    try testing.expect(top_alias.instance_export.instance_idx < loaded.imports.len);
                    n_rebased += 1;
                },
                else => {},
            },
            else => {},
        };
    }
    try testing.expect(n_rebased > 0);
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

// ── #208: `poll_oneoff` export presence + GC-pass survival ─────────────────
// wasi-libc + Zig stdlib pull `poll_oneoff` in via standard startup
// imports; the adapter must export it (even as an ENOSYS stub) so
// `gc.run`'s required-export seeding succeeds and `wabt component
// new` doesn't bail out with `error.MissingRequiredExport`.

test "builtin_adapter: command exports poll_oneoff with the canonical preview1 signature (#208)" {
    var owned = try core_imports.extract(testing.allocator, builtin_adapter.wasi_preview1_command_wasm);
    defer owned.deinit();

    const e = owned.interface.findExport("poll_oneoff") orelse {
        return error.PollOneoffMissingFromCommandAdapter;
    };
    try testing.expect(e.kind == .func);
    const sig = e.sig.?;
    // poll_oneoff(in_ptr, out_ptr, nsubscriptions, nevents_ptr) -> errno
    // Core-wasm shape: (i32, i32, i32, i32) -> i32.
    try testing.expectEqual(@as(usize, 4), sig.params.len);
    for (sig.params) |p| try testing.expectEqual(wabt.types.ValType.i32, p);
    try testing.expectEqual(@as(usize, 1), sig.results.len);
    try testing.expectEqual(wabt.types.ValType.i32, sig.results[0]);
}

test "builtin_adapter: reactor exports poll_oneoff with the canonical preview1 signature (#208)" {
    var owned = try core_imports.extract(testing.allocator, builtin_adapter.wasi_preview1_reactor_wasm);
    defer owned.deinit();

    const e = owned.interface.findExport("poll_oneoff") orelse {
        return error.PollOneoffMissingFromReactorAdapter;
    };
    try testing.expect(e.kind == .func);
    const sig = e.sig.?;
    try testing.expectEqual(@as(usize, 4), sig.params.len);
    for (sig.params) |p| try testing.expectEqual(wabt.types.ValType.i32, p);
    try testing.expectEqual(@as(usize, 1), sig.results.len);
    try testing.expectEqual(wabt.types.ValType.i32, sig.results[0]);
}

test "builtin_adapter: gc.run satisfies a poll_oneoff requirement (regression for #208)" {
    // Concrete repro of issue #208's failing path: an embed that
    // imports `wasi_snapshot_preview1.poll_oneoff` causes the
    // splicer to seed `gc.run`'s required-export set with
    // `"poll_oneoff"`. Before this fix the adapter had no
    // `poll_oneoff` export and `gc.run` returned
    // `error.MissingRequiredExport` immediately. With the ENOSYS
    // stub in place gc.run must succeed AND the survival-set
    // bytes must re-load cleanly.
    const gc = wabt.component.adapter.gc;
    const required = [_][]const u8{"poll_oneoff"};

    const out_cmd = try gc.run(
        testing.allocator,
        builtin_adapter.wasi_preview1_command_wasm,
        &required,
    );
    defer testing.allocator.free(out_cmd);
    try testing.expect(out_cmd.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm", out_cmd[0..4]);

    const out_rx = try gc.run(
        testing.allocator,
        builtin_adapter.wasi_preview1_reactor_wasm,
        &required,
    );
    defer testing.allocator.free(out_rx);
    try testing.expect(out_rx.len > 8);
    try testing.expectEqualSlices(u8, "\x00asm", out_rx[0..4]);
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

test "buildComponent #222: resource methods survive in wrapping component's imported instance body" {
    // Reproducer for #222 — `wabt component new` was dropping
    // `[method]X.Y` exports from imported interface bodies. The
    // user-visible case: `wasi:io/poll@0.2.6`'s `pollable` resource
    // came through with no methods at all (just the type-def and
    // the iface-level `poll` function), making the wrapping
    // component's import shape narrower than what the embed's
    // component-type metadata declared.
    //
    // Synth core: handle export + memory + cabi_realloc (identical
    // shape to #203a). The list<borrow<...>> param on `poll`
    // forces the shim/fixup path, which is where the narrowing
    // lives — `buildComponentShimFixup` Phase 4a copies
    // `shape.inst_decls` verbatim through `rebaseInstDecls`, so
    // the surfacing of all method exports here is the regression
    // pin.
    const core_only = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 14, 2,
        0x60, 0x02, 0x7f, 0x7f, 0x00,
        0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,
        0x03, 3, 2, 0, 1,
        0x05, 3, 1, 0x00, 0x01,
        0x07, 51, 3,
        23, 'w', 'a', 's', 'i', ':', 'i', 'o', '/', 'p', 'o', 'l', 'l',
        '@', '0', '.', '2', '.', '6', '#', 'p', 'o', 'l', 'l',
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
        \\package wasi:io@0.2.6;
        \\
        \\interface poll {
        \\    resource pollable {
        \\        ready: func() -> bool;
        \\        block: func();
        \\    }
        \\    poll: func(in: list<borrow<pollable>>) -> list<u32>;
        \\}
        \\
        \\interface streams {
        \\    use poll.{pollable};
        \\    resource input-stream {
        \\        subscribe: func() -> pollable;
        \\    }
        \\}
        \\
        \\world demo {
        \\    import poll;
        \\    import streams;
        \\    export poll;
        \\}
    , "demo");
    defer testing.allocator.free(ct_payload);

    var core_with_ct = std.ArrayListUnmanaged(u8).empty;
    defer core_with_ct.deinit(testing.allocator);
    try core_with_ct.appendSlice(testing.allocator, core_only[0..core_only.len]);
    const cs_name = "component-type:demo";
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

    // Exactly two imports — wasi:io/poll@0.2.6 + wasi:io/streams@0.2.6.
    // The wasi:io/poll body must carry the full canonical set of
    // decls (the `pollable` resource export + BOTH method exports
    // + the iface-level `poll` export). The bug pre-#222 narrowed
    // the wasi:io/poll body to just `pollable` + `poll`, dropping
    // the methods — because `wasi:io/poll` is reachable via the
    // `streams` body's `use poll.{pollable}` clause, the wrapping
    // emit path uses a narrowed pruning view here.
    try testing.expectEqual(@as(usize, 2), loaded.imports.len);
    var poll_inst_type_idx: ?u32 = null;
    for (loaded.imports) |im| {
        if (std.mem.eql(u8, im.name, "wasi:io/poll@0.2.6")) {
            poll_inst_type_idx = im.desc.instance;
        }
    }
    try testing.expect(poll_inst_type_idx != null);
    const contrib = loaded.type_indexspace[poll_inst_type_idx.?];
    try testing.expect(contrib == .type_def);
    const td = loaded.types[contrib.type_def];
    try testing.expect(td == .instance);

    var saw_pollable = false;
    var saw_ready = false;
    var saw_block = false;
    var saw_poll = false;
    for (td.instance.decls) |d| switch (d) {
        .@"export" => |e| {
            if (std.mem.eql(u8, e.name, "pollable") and e.desc == .type) saw_pollable = true;
            if (std.mem.eql(u8, e.name, "[method]pollable.ready") and e.desc == .func) saw_ready = true;
            if (std.mem.eql(u8, e.name, "[method]pollable.block") and e.desc == .func) saw_block = true;
            if (std.mem.eql(u8, e.name, "poll") and e.desc == .func) saw_poll = true;
        },
        else => {},
    };
    try testing.expect(saw_pollable);
    try testing.expect(saw_ready);
    try testing.expect(saw_block);
    try testing.expect(saw_poll);
}

/// Hand-build a minimal core wasm with a single func import of the
/// given param val types and no results (`(module.field) -> ()`).
/// Only the type + import sections are emitted, which is all
/// `core_imports.extract` needs to read the declared import sig. Name
/// and section lengths stay < 128 bytes so single-byte LEBs suffice.
fn buildCoreWithFuncImport(
    alloc: std.mem.Allocator,
    module: []const u8,
    field: []const u8,
    params: []const wabt.types.ValType,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    const writeSection = struct {
        fn f(buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, id: u8, body: []const u8) !void {
            std.debug.assert(body.len < 0x80);
            try buf.append(a, id);
            try buf.append(a, @intCast(body.len));
            try buf.appendSlice(a, body);
        }
    }.f;

    // Type section: 1 type `(params...) -> ()`.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(alloc);
        try b.append(alloc, 0x01); // type count
        try b.append(alloc, 0x60); // func form
        std.debug.assert(params.len < 0x80);
        try b.append(alloc, @intCast(params.len));
        for (params) |p| try b.append(alloc, @intCast(@intFromEnum(p)));
        try b.append(alloc, 0x00); // 0 results
        try writeSection(&out, alloc, 0x01, b.items);
    }
    // Import section: `module.field` func with type idx 0.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(alloc);
        try b.append(alloc, 0x01); // import count
        try b.append(alloc, @intCast(module.len));
        try b.appendSlice(alloc, module);
        try b.append(alloc, @intCast(field.len));
        try b.appendSlice(alloc, field);
        try b.append(alloc, 0x00); // desc: func
        try b.append(alloc, 0x00); // type idx 0
        try writeSection(&out, alloc, 0x02, b.items);
    }
    return out.toOwnedSlice(alloc);
}

test "validateGuestImportSigs: all-i32 error-code import is rejected (#244)" {
    // The guest declaring `[static]response-outparam.set` with an
    // all-`i32` `error-code` flattening is non-canonical and only
    // links on lenient hosts; wabt must reject it early rather than
    // emit a component that fails to load on wasmtime.
    const I = wabt.types.ValType.i32;
    const L = wabt.types.ValType.i64;
    const module = "wasi:http/types@0.2.6";
    const field = "[static]response-outparam.set";

    // The canonical core sig wabt lowers to (i64 at index 4).
    const canonical = [_]wabt.types.ValType{ I, I, I, I, L, I, I, I, I };
    const expected = [_]ExpectedImportSig{.{
        .module = module,
        .field = field,
        .params = &canonical,
        .results = &.{},
    }};

    // Guest declares all-i32: must be rejected.
    {
        const wrong = [_]wabt.types.ValType{ I, I, I, I, I, I, I, I, I };
        const core = try buildCoreWithFuncImport(testing.allocator, module, field, &wrong);
        defer testing.allocator.free(core);
        try testing.expectError(
            error.CoreImportSignatureMismatch,
            validateGuestImportSigs(testing.allocator, core, &expected),
        );
    }
    // Guest declares the canonical sig: accepted.
    {
        const core = try buildCoreWithFuncImport(testing.allocator, module, field, &canonical);
        defer testing.allocator.free(core);
        try validateGuestImportSigs(testing.allocator, core, &expected);
    }
    // Import wabt doesn't wire (absent from `expected`) is ignored.
    {
        const wrong = [_]wabt.types.ValType{ I, I, I, I, I, I, I, I, I };
        const core = try buildCoreWithFuncImport(testing.allocator, module, field, &wrong);
        defer testing.allocator.free(core);
        try validateGuestImportSigs(testing.allocator, core, &.{});
    }
}

// ── #248: resource built-in intrinsic import wiring tests ───────────

/// Assemble a core wasm module from WAT text and append a
/// `component-type:<world>` custom section encoding `wit_src`. Caller
/// owns the returned bytes.
fn buildCoreFromWat(
    alloc: std.mem.Allocator,
    wat_src: []const u8,
    wit_src: []const u8,
    world: []const u8,
) ![]u8 {
    var module = try wabt.text.Parser.parseModule(alloc, wat_src);
    defer module.deinit();
    const core_only = try wabt.binary.writer.writeModule(alloc, &module);
    defer alloc.free(core_only);

    const ct_payload = try metadata_encode.encodeWorldFromSource(alloc, wit_src, world);
    defer alloc.free(ct_payload);

    const cs_name = try std.fmt.allocPrint(alloc, "component-type:{s}", .{world});
    defer alloc.free(cs_name);

    var cs_body = std.ArrayListUnmanaged(u8).empty;
    defer cs_body.deinit(alloc);
    try writeU32Leb(alloc, &cs_body, @intCast(cs_name.len));
    try cs_body.appendSlice(alloc, cs_name);
    try cs_body.appendSlice(alloc, ct_payload);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, core_only);
    try out.append(alloc, 0); // custom section id
    try writeU32Leb(alloc, &out, @intCast(cs_body.items.len));
    try out.appendSlice(alloc, cs_body.items);
    return out.toOwnedSlice(alloc);
}

/// True if any core-instance inline-exports bundle exports `name` as a
/// core func.
fn bundleExportsFunc(loaded: anytype, name: []const u8) bool {
    for (loaded.core_instances) |ci| switch (ci) {
        .exports => |exps| for (exps) |e| {
            if (e.sort_idx.sort == .func and std.mem.eql(u8, e.name, name)) return true;
        },
        else => {},
    };
    return false;
}

fn countResourceDrops(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .resource_drop => n += 1,
        else => {},
    };
    return n;
}

fn mainWithArgFor(loaded: anytype, name: []const u8) bool {
    for (loaded.core_instances) |ci| switch (ci) {
        .instantiate => |inst| for (inst.args) |arg| {
            if (std.mem.eql(u8, arg.name, name)) return true;
        },
        else => {},
    };
    return false;
}

fn countTaskReturns(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .task_return => n += 1,
        else => {},
    };
    return n;
}

fn anyAsyncLift(loaded: anytype) bool {
    for (loaded.canons) |c| switch (c) {
        .lift => |l| for (l.opts) |o| switch (o) {
            .async_ => return true,
            else => {},
        },
        else => {},
    };
    return false;
}

test "buildComponent #263: async run export wires task.return + async lift" {
    // A guest exporting `wasi:cli/run`-style `run: async func() -> result`
    // and importing the `[task-return]<export>` async intrinsic must get
    // (1) an async `canon lift` for the export, (2) a `canon task.return`
    // whose result type is the export's, and (3) a `(with …)` arg feeding
    // the task.return bundle to the main core instance under the intrinsic
    // module name. Validated at runtime on wasmtime 46.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run") (call 0 (i32.const 0)))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 1), countTaskReturns(loaded));
    try testing.expect(anyAsyncLift(loaded));
    try testing.expect(mainWithArgFor(loaded, "[task-return]local:p/run@0.1.0#run"));
    try testing.expect(bundleExportsFunc(loaded, "task-return"));
}

fn countStreamCanons(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .stream_new, .stream_drop_readable, .stream_drop_writable => n += 1,
        else => {},
    };
    return n;
}

fn anyStreamType(loaded: anytype) bool {
    for (loaded.types) |t| switch (t) {
        .stream => |s| if (s.element != null and s.element.? == .u8) return true,
        else => {},
    };
    return false;
}

test "buildComponent #263: [stream]stream<u8> wires stream.new/drop canons + a stream type" {
    // A guest exporting an async `run` that creates a `stream<u8>` and
    // drops both ends imports the no-memory `[stream]stream<u8>`
    // intrinsics. wabt must hoist a `(stream u8)` type, emit `canon
    // stream.{new,drop-readable,drop-writable}` over it, and feed the
    // bundle under the `[stream]stream<u8>` module. Runs on wasmtime 46.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[stream]stream<u8>" "new" (func (result i64)))
        \\  (import "[stream]stream<u8>" "drop-readable" (func (param i32)))
        \\  (import "[stream]stream<u8>" "drop-writable" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expect(anyStreamType(loaded));
    try testing.expectEqual(@as(usize, 3), countStreamCanons(loaded));
    try testing.expect(mainWithArgFor(loaded, "[stream]stream<u8>"));
    try testing.expect(bundleExportsFunc(loaded, "new"));
    try testing.expect(bundleExportsFunc(loaded, "drop-writable"));
}

fn countStreamWrite(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .stream_write => n += 1,
        else => {},
    };
    return n;
}

test "buildComponent #263: stream.write routes through shim/fixup (memory-opt)" {
    // `stream.write` needs `(memory)` opts pointing at the main instance
    // — a forward-reference broken by the shim/fixup trampoline. The
    // produced component must have 3 core modules (main + shim + fixup),
    // a `canon stream.write` over the hoisted `(stream u8)` type, and the
    // `[stream]stream<u8>` bundle fed to main. Runs on wasmtime 46.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[stream]stream<u8>" "new" (func (result i64)))
        \\  (import "[stream]stream<u8>" "write" (func (param i32 i32 i32) (result i32)))
        \\  (import "[stream]stream<u8>" "drop-writable" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // main + shim + fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expect(anyStreamType(loaded));
    try testing.expectEqual(@as(usize, 1), countStreamWrite(loaded));
    try testing.expect(anyAsyncLift(loaded));
    try testing.expect(mainWithArgFor(loaded, "[stream]stream<u8>"));
    try testing.expect(mainWithArgFor(loaded, "[task-return]local:p/run@0.1.0#run"));
}

fn countFutureCanons(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .future_new, .future_drop_readable, .future_drop_writable => n += 1,
        else => {},
    };
    return n;
}

fn anyFutureType(loaded: anytype) bool {
    for (loaded.types) |t| switch (t) {
        .future => |f| if (f.element != null and f.element.? == .u8) return true,
        else => {},
    };
    return false;
}

fn countFutureWrite(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .future_write => n += 1,
        else => {},
    };
    return n;
}

test "buildComponent #264: [future]future<u8> wires future.new/drop canons + a future type" {
    // Mirror of the `[stream]` no-memory case (#263): a guest creating a
    // `future<u8>` and dropping both ends imports the no-memory
    // `[future]future<u8>` intrinsics. wabt must hoist a `(future u8)`
    // type, emit `canon future.{new,drop-readable,drop-writable}` over it,
    // and feed the bundle under the `[future]future<u8>` module.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[future]future<u8>" "new" (func (result i64)))
        \\  (import "[future]future<u8>" "drop-readable" (func (param i32)))
        \\  (import "[future]future<u8>" "drop-writable" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expect(anyFutureType(loaded));
    try testing.expectEqual(@as(usize, 3), countFutureCanons(loaded));
    try testing.expect(mainWithArgFor(loaded, "[future]future<u8>"));
    try testing.expect(bundleExportsFunc(loaded, "new"));
    try testing.expect(bundleExportsFunc(loaded, "drop-writable"));
}

test "buildComponent #264: future.write routes through shim/fixup (memory-opt)" {
    // `future.write` needs `(memory)` opts pointing at the main instance
    // — the same forward-reference broken by the shim/fixup trampoline as
    // `stream.write`. Its lowered core sig is `(param i32 i32) (result
    // i32)` (handle, ptr; no count). The produced component must have 3
    // core modules (main + shim + fixup), a `canon future.write` over the
    // hoisted `(future u8)` type, and the `[future]future<u8>` bundle.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[future]future<u8>" "new" (func (result i64)))
        \\  (import "[future]future<u8>" "write" (func (param i32 i32) (result i32)))
        \\  (import "[future]future<u8>" "drop-writable" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // main + shim + fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expect(anyFutureType(loaded));
    try testing.expectEqual(@as(usize, 1), countFutureWrite(loaded));
    try testing.expect(anyAsyncLift(loaded));
    try testing.expect(mainWithArgFor(loaded, "[future]future<u8>"));
    try testing.expect(mainWithArgFor(loaded, "[task-return]local:p/run@0.1.0#run"));
}

test "buildComponent #263: full streaming hello (stdout write-via-stream + cross-iface)" {
    // The end-to-end wasip3 command shape: an async `run` that writes to
    // stdout via `write-via-stream(stream<u8>) -> future<result<_,
    // error-code>>`. Exercises (1) a type-only `types` import providing
    // the `use`d `error-code` enum (cross-iface alias rebasing), (2) a
    // future-returning import func lowered through the shim, and (3) the
    // `[stream]`/`[task-return]` intrinsics. This exact shape prints
    // "hello from wasi 0.3" on wasmtime 46.
    const wit =
        \\package local:io@0.1.0;
        \\
        \\interface types {
        \\    enum error-code { oops }
        \\}
        \\
        \\interface out {
        \\    use types.{error-code};
        \\    write-via-stream: func(data: stream<u8>) -> future<result<_, error-code>>;
        \\}
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    import out;
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[stream]stream<u8>" "new" (func (result i64)))
        \\  (import "[stream]stream<u8>" "write" (func (param i32 i32 i32) (result i32)))
        \\  (import "[stream]stream<u8>" "drop-writable" (func (param i32)))
        \\  (import "local:io/out@0.1.0" "write-via-stream" (func (param i32) (result i32)))
        \\  (import "[task-return]local:io/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:io/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // shim/fixup (stream.write is memory-opt).
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expect(anyStreamType(loaded));
    try testing.expectEqual(@as(usize, 1), countStreamWrite(loaded));
    try testing.expect(anyAsyncLift(loaded));
    // The future-returning stdout import is lowered + wired.
    try testing.expect(mainWithArgFor(loaded, "local:io/out@0.1.0"));
    // The type-only `types` import is included so error-code resolves.
    try testing.expect(mainWithArgFor(loaded, "[stream]stream<u8>"));
}

fn countErrorContextCanons(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .error_context_new, .error_context_debug_message, .error_context_drop => n += 1,
        else => {},
    };
    return n;
}

test "buildComponent #263: error-context.new routes through shim/fixup; drop direct" {
    // `error-context.new` reads a message from guest memory ⇒ memory-opt    // ⇒ shim/fixup; `error-context.drop` is no-memory ⇒ a direct canon.
    // Runs on wasmtime 46.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[error-context]" "new" (func (param i32 i32) (result i32)))
        \\  (import "[error-context]" "drop" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    // one error-context.new + one error-context.drop.
    try testing.expectEqual(@as(usize, 2), countErrorContextCanons(loaded));
    try testing.expect(mainWithArgFor(loaded, "[error-context]"));
}

fn countWaitableCanons(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .waitable_set_new, .waitable_set_wait, .waitable_set_poll, .waitable_set_drop, .waitable_join => n += 1,
        else => {},
    };
    return n;
}

fn countWaitableSetWait(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .waitable_set_wait => n += 1,
        else => {},
    };
    return n;
}

test "buildComponent #265: [waitable-set] new/wait/drop + [waitable] join wires canons" {
    // Awaiting an async op: `waitable-set.new`/`.drop` and `waitable.join`
    // are no-memory direct canons; `waitable-set.wait` writes an event to a
    // retptr ⇒ memory-opt ⇒ shim/fixup. The component must have 3 core
    // modules (main + shim + fixup), all four waitable canons, and the
    // `[waitable-set]`/`[waitable]` bundles fed to main.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[waitable-set]" "new" (func (result i32)))
        \\  (import "[waitable-set]" "wait" (func (param i32 i32) (result i32)))
        \\  (import "[waitable-set]" "drop" (func (param i32)))
        \\  (import "[waitable]" "join" (func (param i32 i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // main + shim + fixup (waitable-set.wait is memory-opt).
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    // new + wait + drop + join.
    try testing.expectEqual(@as(usize, 4), countWaitableCanons(loaded));
    try testing.expectEqual(@as(usize, 1), countWaitableSetWait(loaded));
    try testing.expect(mainWithArgFor(loaded, "[waitable-set]"));
    try testing.expect(mainWithArgFor(loaded, "[waitable]"));
    try testing.expect(bundleExportsFunc(loaded, "wait"));
    try testing.expect(bundleExportsFunc(loaded, "join"));
}

fn countControlCanons(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .backpressure_inc, .backpressure_dec, .task_cancel, .subtask_drop => n += 1,
        else => {},
    };
    return n;
}

test "buildComponent #267: [backpressure]/[task]/[subtask] no-mem control canons wire (fast path)" {
    // backpressure.inc/.dec, task.cancel, and subtask.drop are all no-memory
    // direct canons (like waitable.join). With no mem-op intrinsic and no
    // exported destructor the guest stays on the fast path: one core module,
    // each intrinsic bundle fed to main under its synthetic module name.
    // This exact shape was validated on wasmtime 46 (`wasmtime compile` with
    // `-W component-model-async{,-stackful,-more-async-builtins}`).
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[backpressure]" "inc" (func))
        \\  (import "[backpressure]" "dec" (func))
        \\  (import "[task]" "cancel" (func))
        \\  (import "[subtask]" "drop" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run") (call 0 (i32.const 0)))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // No mem-op / dtor ⇒ fast path ⇒ a single (main) core module.
    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    // backpressure.inc + backpressure.dec + task.cancel + subtask.drop.
    try testing.expectEqual(@as(usize, 4), countControlCanons(loaded));
    try testing.expect(mainWithArgFor(loaded, "[backpressure]"));
    try testing.expect(mainWithArgFor(loaded, "[task]"));
    try testing.expect(mainWithArgFor(loaded, "[subtask]"));
    try testing.expect(bundleExportsFunc(loaded, "inc"));
    try testing.expect(bundleExportsFunc(loaded, "dec"));
    try testing.expect(bundleExportsFunc(loaded, "cancel"));
    try testing.expect(bundleExportsFunc(loaded, "drop"));
}

test "buildComponent #267: control canons also wire through the shim/fixup path" {
    // Adding a memory-opt intrinsic (waitable-set.wait) routes the build
    // through the shim/fixup path; the no-mem control canons must still wire
    // there (classification + emission arms), alongside main+shim+fixup.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[backpressure]" "inc" (func))
        \\  (import "[task]" "cancel" (func))
        \\  (import "[subtask]" "drop" (func (param i32)))
        \\  (import "[waitable-set]" "wait" (func (param i32 i32) (result i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // waitable-set.wait is mem-op ⇒ main + shim + fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    // backpressure.inc + task.cancel + subtask.drop.
    try testing.expectEqual(@as(usize, 3), countControlCanons(loaded));
    try testing.expect(mainWithArgFor(loaded, "[backpressure]"));
    try testing.expect(mainWithArgFor(loaded, "[task]"));
    try testing.expect(mainWithArgFor(loaded, "[subtask]"));
    try testing.expect(bundleExportsFunc(loaded, "inc"));
    try testing.expect(bundleExportsFunc(loaded, "cancel"));
}

fn countSubtaskCancelCanons(loaded: anytype) usize {
    var n: usize = 0;
    for (loaded.canons) |c| switch (c) {
        .subtask_cancel => n += 1,
        else => {},
    };
    return n;
}

test "buildComponent #267: subtask.cancel + context.get/set operand-carrying canons wire (fast path)" {
    // subtask.cancel carries an async? flag (field `cancel` ⇒ blocking,
    // `cancel-async` ⇒ async); context.get/set carry a core valtype + slot
    // encoded in the field (`get-i32-0`). All four are no-memory direct
    // canons. Validated on wasmtime 46 (`wasmtime compile` with
    // `-W component-model-async{,-stackful,-more-async-builtins}`).
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[subtask]" "cancel" (func (param i32) (result i32)))
        \\  (import "[subtask]" "cancel-async" (func (param i32) (result i32)))
        \\  (import "[context]" "get-i32-0" (func (result i32)))
        \\  (import "[context]" "set-i32-0" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run") (call 0 (i32.const 0)))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    // `cancel` (async=false) + `cancel-async` (async=true).
    try testing.expectEqual(@as(usize, 2), countSubtaskCancelCanons(loaded));

    var saw_get = false;
    var saw_set = false;
    var saw_async_cancel = false;
    var saw_sync_cancel = false;
    for (loaded.canons) |c| switch (c) {
        .context_get => |cx| if (cx.ty == .i32 and cx.slot == 0) {
            saw_get = true;
        },
        .context_set => |cx| if (cx.ty == .i32 and cx.slot == 0) {
            saw_set = true;
        },
        .subtask_cancel => |is_async| if (is_async) {
            saw_async_cancel = true;
        } else {
            saw_sync_cancel = true;
        },
        else => {},
    };
    try testing.expect(saw_get);
    try testing.expect(saw_set);
    try testing.expect(saw_sync_cancel);
    try testing.expect(saw_async_cancel);

    try testing.expect(mainWithArgFor(loaded, "[subtask]"));
    try testing.expect(mainWithArgFor(loaded, "[context]"));
    try testing.expect(bundleExportsFunc(loaded, "cancel"));
    try testing.expect(bundleExportsFunc(loaded, "get-i32-0"));
    try testing.expect(bundleExportsFunc(loaded, "set-i32-0"));
}

test "buildComponent #267: operand-carrying canons also wire through the shim/fixup path" {
    // A mem-op intrinsic (waitable-set.wait) forces the shim/fixup path; the
    // no-mem subtask.cancel and context.get/set canons must still wire there.
    const wit =
        \\package local:p@0.1.0;
        \\
        \\interface run {
        \\    run: async func() -> result;
        \\}
        \\
        \\world hello {
        \\    export run;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[task-return]local:p/run@0.1.0#run" "task-return" (func (param i32)))
        \\  (import "[subtask]" "cancel" (func (param i32) (result i32)))
        \\  (import "[context]" "get-i32-0" (func (result i32)))
        \\  (import "[context]" "set-i32-0" (func (param i32)))
        \\  (import "[waitable-set]" "wait" (func (param i32 i32) (result i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
        \\  (func (export "local:p/run@0.1.0#run"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "hello");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // waitable-set.wait is mem-op ⇒ main + shim + fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expectEqual(@as(usize, 1), countSubtaskCancelCanons(loaded));

    var saw_get = false;
    var saw_set = false;
    for (loaded.canons) |c| switch (c) {
        .context_get => saw_get = true,
        .context_set => saw_set = true,
        else => {},
    };
    try testing.expect(saw_get);
    try testing.expect(saw_set);
    try testing.expect(mainWithArgFor(loaded, "[subtask]"));
    try testing.expect(mainWithArgFor(loaded, "[context]"));
}

test "buildComponent #248: drop-only namespace wires canon resource.drop into the bundle" {
    // A guest that only `[resource-drop]`s a handle (no methods on the
    // interface) previously left the core import dangling, so the
    // produced component was rejected at instantiation. The namespace
    // must still get a bundle + `(with …)` arg carrying a `canon
    // resource.drop`.
    const wit =
        \\package test:drop@0.1.0;
        \\
        \\interface streams {
        \\    resource output-stream;
        \\}
        \\
        \\interface runner {
        \\    go: func();
        \\}
        \\
        \\world w {
        \\    import streams;
        \\    export runner;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "test:drop/streams@0.1.0" "[resource-drop]output-stream" (func (param i32)))
        \\  (func (export "test:drop/runner@0.1.0#go"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // Fast path: a single core module (no shim/fixup machinery).
    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    // Exactly one `canon resource.drop`.
    try testing.expectEqual(@as(usize, 1), countResourceDrops(loaded));
    // A bundle exposes the intrinsic under its canonical field name.
    try testing.expect(bundleExportsFunc(loaded, "[resource-drop]output-stream"));
    // The main core instance is fed that bundle under the namespace.
    try testing.expect(mainWithArgFor(loaded, "test:drop/streams@0.1.0"));
}

test "buildComponent #248: drop wired alongside a handle-only method (fast path)" {
    const wit =
        \\package test:drop@0.1.0;
        \\
        \\interface streams {
        \\    resource output-stream {
        \\        get-id: func() -> u32;
        \\    }
        \\}
        \\
        \\interface runner {
        \\    go: func();
        \\}
        \\
        \\world w {
        \\    import streams;
        \\    export runner;
        \\}
    ;
    // `get-id` lowers to `(param i32 /*self*/) (result i32)`.
    const wat =
        \\(module
        \\  (import "test:drop/streams@0.1.0" "[method]output-stream.get-id" (func (param i32) (result i32)))
        \\  (import "test:drop/streams@0.1.0" "[resource-drop]output-stream" (func (param i32)))
        \\  (func (export "test:drop/runner@0.1.0#go"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    try testing.expectEqual(@as(usize, 1), countResourceDrops(loaded));
    try testing.expect(bundleExportsFunc(loaded, "[resource-drop]output-stream"));
    try testing.expect(bundleExportsFunc(loaded, "[method]output-stream.get-id"));
    try testing.expect(mainWithArgFor(loaded, "test:drop/streams@0.1.0"));
}

test "buildComponent #248: drop wired on the shim/fixup path (string method forces opts)" {
    const wit =
        \\package test:drop@0.1.0;
        \\
        \\interface streams {
        \\    resource output-stream {
        \\        write: func(data: string) -> u32;
        \\    }
        \\}
        \\
        \\interface runner {
        \\    go: func();
        \\}
        \\
        \\world w {
        \\    import streams;
        \\    export runner;
        \\}
    ;
    // `write` lowers to `(param i32 /*self*/ i32 i32 /*string ptr,len*/)
    // (result i32)` and needs memory + realloc + string-encoding opts,
    // forcing the shim/fixup path. The core must export `memory` +
    // `cabi_realloc` for that path.
    const wat =
        \\(module
        \\  (import "test:drop/streams@0.1.0" "[method]output-stream.write" (func (param i32 i32 i32) (result i32)))
        \\  (import "test:drop/streams@0.1.0" "[resource-drop]output-stream" (func (param i32)))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\  (func (export "test:drop/runner@0.1.0#go"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // Shim/fixup path: main + shim + fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expectEqual(@as(usize, 1), countResourceDrops(loaded));
    try testing.expect(bundleExportsFunc(loaded, "[resource-drop]output-stream"));
    try testing.expect(mainWithArgFor(loaded, "test:drop/streams@0.1.0"));
}

test "buildComponent #248: drop of an unknown resource is a hard error" {
    const wit =
        \\package test:drop@0.1.0;
        \\
        \\interface streams {
        \\    resource output-stream;
        \\}
        \\
        \\interface runner {
        \\    go: func();
        \\}
        \\
        \\world w {
        \\    import streams;
        \\    export runner;
        \\}
    ;
    // `ghost` is not a resource provided by any imported interface.
    const wat =
        \\(module
        \\  (import "test:drop/streams@0.1.0" "[resource-drop]ghost" (func (param i32)))
        \\  (func (export "test:drop/runner@0.1.0#go"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    try testing.expectError(error.UnresolvedResourceIntrinsic, buildComponent(testing.allocator, core));
}

// ── #250: guest-implemented (exported) resource tests ──────────────

fn countCanon(loaded: anytype, comptime tag: @TypeOf(.enum_literal)) usize {
    var n: usize = 0;
    for (loaded.canons) |c| {
        if (std.meta.activeTag(c) == tag) n += 1;
    }
    return n;
}

/// True if any top-level instance, or any nested sub-component,
/// exports a *type* named `name`.
fn instanceExportsType(loaded: anytype, name: []const u8) bool {
    for (loaded.instances) |inst| switch (inst) {
        .exports => |exps| for (exps) |e| {
            if (e.sort_idx.sort == .type and std.mem.eql(u8, e.name, name)) return true;
        },
        else => {},
    };
    for (loaded.components) |child| {
        for (child.exports) |e| {
            const si = e.sort_idx orelse continue;
            if (si.sort == .type and std.mem.eql(u8, e.name, name)) return true;
        }
    }
    return false;
}

/// True if the component declares at least one resource type def with
/// (`with_dtor`) or without a destructor.
fn hasResourceTypeDef(loaded: anytype, with_dtor: bool) bool {
    for (loaded.types) |t| switch (t) {
        .resource => |r| if ((r.destructor != null) == with_dtor) return true,
        else => {},
    };
    return false;
}

/// Counts of each canon-lift option kind across every `.lift` canon.
const LiftOptCounts = struct { memory: usize, realloc: usize, string_encoding: usize, post_return: usize };
fn liftOptCounts(loaded: anytype) LiftOptCounts {
    var c = LiftOptCounts{ .memory = 0, .realloc = 0, .string_encoding = 0, .post_return = 0 };
    for (loaded.canons) |canon| switch (canon) {
        .lift => |l| for (l.opts) |o| switch (o) {
            .memory => c.memory += 1,
            .realloc => c.realloc += 1,
            .string_encoding => c.string_encoding += 1,
            .post_return => c.post_return += 1,
            .async_, .callback => {},
        },
        else => {},
    };
    return c;
}

test "buildComponent #250: dtor-less exported resource (fast path)" {
    // A guest that *defines* an exported resource with no destructor:
    // a constructor + a method, plus the `[resource-new]`/
    // `[resource-rep]` intrinsics it imports from `[export]<iface>`.
    // No destructor → no forward-reference cycle → fast path.
    const wit =
        \\package test:res@0.1.0;
        \\
        \\interface things {
        \\    resource thing {
        \\        constructor(x: u32);
        \\        get: func() -> u32;
        \\    }
        \\}
        \\
        \\world w {
        \\    export things;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[export]test:res/things@0.1.0" "[resource-new]thing" (func (param i32) (result i32)))
        \\  (import "[export]test:res/things@0.1.0" "[resource-rep]thing" (func (param i32) (result i32)))
        \\  (func (export "test:res/things@0.1.0#[constructor]thing") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[method]thing.get") (param i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // Fast path: single core module (no shim/fixup).
    try testing.expectEqual(@as(usize, 1), loaded.core_modules.len);
    // Exported resource type declared without a destructor.
    try testing.expect(hasResourceTypeDef(loaded, false));
    // resource.new + resource.rep wired (one each).
    try testing.expectEqual(@as(usize, 1), countCanon(loaded, .resource_new));
    try testing.expectEqual(@as(usize, 1), countCanon(loaded, .resource_rep));
    // The guest's `[export]…` intrinsic imports are satisfied.
    try testing.expect(bundleExportsFunc(loaded, "[resource-new]thing"));
    try testing.expect(bundleExportsFunc(loaded, "[resource-rep]thing"));
    try testing.expect(mainWithArgFor(loaded, "[export]test:res/things@0.1.0"));
    // The exported interface instance exposes the resource type.
    try testing.expect(instanceExportsType(loaded, "thing"));
}

test "buildComponent #250: exported resource with destructor (shim/fixup path)" {
    // A guest defining an exported resource *with* a destructor. The
    // destructor forces the shim/fixup path: the resource type's dtor
    // references a shim trampoline that the fixup patches to call the
    // guest's real `#[dtor]thing` export.
    const wit =
        \\package test:res@0.1.0;
        \\
        \\interface things {
        \\    resource thing {
        \\        constructor(x: u32);
        \\        get: func() -> u32;
        \\    }
        \\}
        \\
        \\world w {
        \\    export things;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[export]test:res/things@0.1.0" "[resource-new]thing" (func (param i32) (result i32)))
        \\  (import "[export]test:res/things@0.1.0" "[resource-rep]thing" (func (param i32) (result i32)))
        \\  (func (export "test:res/things@0.1.0#[constructor]thing") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[method]thing.get") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[dtor]thing") (param i32))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // Shim/fixup path: main + shim + fixup.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    // Exported resource type declared *with* a destructor.
    try testing.expect(hasResourceTypeDef(loaded, true));
    try testing.expectEqual(@as(usize, 1), countCanon(loaded, .resource_new));
    try testing.expectEqual(@as(usize, 1), countCanon(loaded, .resource_rep));
    try testing.expect(bundleExportsFunc(loaded, "[resource-new]thing"));
    try testing.expect(bundleExportsFunc(loaded, "[resource-rep]thing"));
    try testing.expect(mainWithArgFor(loaded, "[export]test:res/things@0.1.0"));
    try testing.expect(instanceExportsType(loaded, "thing"));
}

test "buildComponent #250: exported-resource intrinsic for an unknown resource is a hard error" {
    const wit =
        \\package test:res@0.1.0;
        \\
        \\interface things {
        \\    resource thing {
        \\        get: func() -> u32;
        \\    }
        \\}
        \\
        \\world w {
        \\    export things;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[export]test:res/things@0.1.0" "[resource-new]ghost" (func (param i32) (result i32)))
        \\  (func (export "test:res/things@0.1.0#[method]thing.get") (param i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    try testing.expectError(error.UnresolvedResourceIntrinsic, buildComponent(testing.allocator, core));
}

test "buildComponent #250: rich resource interface (ctor, method, method->own, static, free func) on shim path" {
    // Exercises the nested-component transcription across func shapes:
    // a constructor, a borrow-self method, a method returning `own`,
    // a static method over two borrows, and an interface-level free
    // function returning `own`. The destructor forces the shim path.
    const wit =
        \\package test:res@0.1.0;
        \\
        \\interface things {
        \\    resource thing {
        \\        constructor(x: u32);
        \\        get: func() -> u32;
        \\        clone: func() -> thing;
        \\        merge: static func(a: borrow<thing>, b: borrow<thing>) -> thing;
        \\    }
        \\    make: func(v: u32) -> thing;
        \\}
        \\
        \\world w {
        \\    export things;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[export]test:res/things@0.1.0" "[resource-new]thing" (func (param i32) (result i32)))
        \\  (import "[export]test:res/things@0.1.0" "[resource-rep]thing" (func (param i32) (result i32)))
        \\  (func (export "test:res/things@0.1.0#[constructor]thing") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[method]thing.get") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[method]thing.clone") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[static]thing.merge") (param i32 i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#make") (param i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[dtor]thing") (param i32))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expect(hasResourceTypeDef(loaded, true));
    try testing.expectEqual(@as(usize, 1), countCanon(loaded, .resource_new));
    try testing.expectEqual(@as(usize, 1), countCanon(loaded, .resource_rep));
    try testing.expect(instanceExportsType(loaded, "thing"));
    // One nested sub-component re-exports the whole interface.
    try testing.expect(loaded.components.len == 1);
}

// ── #251: resource intrinsic core-import signature validation ───────

test "buildComponent #251: [resource-drop] declared with a result is rejected" {
    // The canonical ABI fixes `[resource-drop]<R>` at `(func (param i32))`.
    // A guest that declares it with an extra `(result i32)` must fail
    // early with the #244 diagnostic, not at host link time.
    const wit =
        \\package test:drop@0.1.0;
        \\
        \\interface streams {
        \\    resource output-stream;
        \\}
        \\
        \\interface runner {
        \\    go: func();
        \\}
        \\
        \\world w {
        \\    import streams;
        \\    export runner;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "test:drop/streams@0.1.0" "[resource-drop]output-stream" (func (param i32) (result i32)))
        \\  (func (export "test:drop/runner@0.1.0#go"))
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    try testing.expectError(error.CoreImportSignatureMismatch, buildComponent(testing.allocator, core));
}

test "buildComponent #251: [resource-new] declared without a result is rejected" {
    // `[resource-new]<R>` is fixed at `(func (param i32) (result i32))`.
    // Here the guest owns `thing` (export side) and mis-declares the
    // intrinsic with no result.
    const wit =
        \\package test:res@0.1.0;
        \\
        \\interface things {
        \\    resource thing {
        \\        get: func() -> u32;
        \\    }
        \\}
        \\
        \\world w {
        \\    export things;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[export]test:res/things@0.1.0" "[resource-new]thing" (func (param i32)))
        \\  (func (export "test:res/things@0.1.0#[method]thing.get") (param i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);

    try testing.expectError(error.CoreImportSignatureMismatch, buildComponent(testing.allocator, core));
}

// ── #253: canon-lift options for exported funcs needing string lifting ──

test "buildComponent #253: exported func taking a string lifts with memory+realloc" {
    const wit =
        \\package test:g@0.1.0;
        \\
        \\interface greeter {
        \\    take: func(s: string);
        \\}
        \\
        \\world w {
        \\    export greeter;
        \\}
    ;
    const wat =
        \\(module
        \\  (func (export "test:g/greeter@0.1.0#take") (param i32 i32))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);
    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    // String param forces the shim/fixup path.
    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    const c = liftOptCounts(loaded);
    try testing.expectEqual(@as(usize, 1), c.memory);
    try testing.expectEqual(@as(usize, 1), c.realloc); // for the incoming string param
    try testing.expectEqual(@as(usize, 1), c.string_encoding);
    try testing.expectEqual(@as(usize, 0), c.post_return); // no result to clean up
}

test "buildComponent #253: exported func returning a string lifts with memory+post-return" {
    const wit =
        \\package test:g@0.1.0;
        \\
        \\interface greeter {
        \\    make: func() -> string;
        \\}
        \\
        \\world w {
        \\    export greeter;
        \\}
    ;
    const wat =
        \\(module
        \\  (func (export "test:g/greeter@0.1.0#make") (result i32) i32.const 0)
        \\  (func (export "cabi_post_test:g/greeter@0.1.0#make") (param i32))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);
    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    const c = liftOptCounts(loaded);
    try testing.expectEqual(@as(usize, 1), c.memory);
    try testing.expectEqual(@as(usize, 0), c.realloc); // no string params
    try testing.expectEqual(@as(usize, 1), c.string_encoding);
    try testing.expectEqual(@as(usize, 1), c.post_return); // frees the returned string
}

test "buildComponent #253: string-in/string-out export lifts with all four opts" {
    const wit =
        \\package test:g@0.1.0;
        \\
        \\interface greeter {
        \\    greet: func(name: string) -> string;
        \\}
        \\
        \\world w {
        \\    export greeter;
        \\}
    ;
    const wat =
        \\(module
        \\  (func (export "test:g/greeter@0.1.0#greet") (param i32 i32) (result i32) i32.const 0)
        \\  (func (export "cabi_post_test:g/greeter@0.1.0#greet") (param i32))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);
    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    const c = liftOptCounts(loaded);
    try testing.expectEqual(@as(usize, 1), c.memory);
    try testing.expectEqual(@as(usize, 1), c.realloc);
    try testing.expectEqual(@as(usize, 1), c.string_encoding);
    try testing.expectEqual(@as(usize, 1), c.post_return);
}

test "buildComponent #253: resource method taking/returning a string (with #250) builds + lifts opts" {
    // The motivating case: a guest-defined resource whose method takes
    // and returns a string. Combines the #250 nested re-export + dtor
    // shim wiring with #253 lift options (incl. post-return).
    const wit =
        \\package test:res@0.1.0;
        \\
        \\interface things {
        \\    resource thing {
        \\        constructor(name: string);
        \\        greet: func(greeting: string) -> string;
        \\    }
        \\}
        \\
        \\world w {
        \\    export things;
        \\}
    ;
    const wat =
        \\(module
        \\  (import "[export]test:res/things@0.1.0" "[resource-new]thing" (func (param i32) (result i32)))
        \\  (import "[export]test:res/things@0.1.0" "[resource-rep]thing" (func (param i32) (result i32)))
        \\  (func (export "test:res/things@0.1.0#[constructor]thing") (param i32 i32) (result i32) i32.const 0)
        \\  (func (export "test:res/things@0.1.0#[method]thing.greet") (param i32 i32 i32) (result i32) i32.const 0)
        \\  (func (export "cabi_post_test:res/things@0.1.0#[method]thing.greet") (param i32))
        \\  (func (export "test:res/things@0.1.0#[dtor]thing") (param i32))
        \\  (memory (export "memory") 1)
        \\  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) i32.const 0)
        \\)
    ;
    const core = try buildCoreFromWat(testing.allocator, wat, wit, "w");
    defer testing.allocator.free(core);
    const comp_bytes = try buildComponent(testing.allocator, core);
    defer testing.allocator.free(comp_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const loaded = try loader.load(comp_bytes, arena.allocator());

    try testing.expectEqual(@as(usize, 3), loaded.core_modules.len);
    try testing.expect(hasResourceTypeDef(loaded, true)); // dtor'd resource
    try testing.expect(loaded.components.len == 1); // nested re-export
    const c = liftOptCounts(loaded);
    try testing.expect(c.memory >= 1);
    try testing.expect(c.realloc >= 1);
    try testing.expect(c.string_encoding >= 1);
    try testing.expect(c.post_return >= 1); // greet's returned string
}
