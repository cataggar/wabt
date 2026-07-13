//! WASI preview1 → component adapter splicer.
//!
//! Top-level entry point: `splice(gpa, embed_bytes, adapter_bytes,
//! adapter_name) ![]u8`. Mirrors `wasm-tools component new --adapt
//! wasi_snapshot_preview1=<file>`. Output is structurally
//! equivalent to the `wasm-tools` reference but not byte-identical
//! (we lay out sections in our own order and defer adapter GC).
//!
//! Architecture (all four core modules embedded in the wrapping
//! component):
//!
//!     ┌─ shim ─┐  trampoline funcs that index into `$imports`
//!     │        │  table — patched by fixup at start time.
//!     ├─ embed │  (the user's program; imports
//!     │        │  `wasi_snapshot_preview1.<name>` from the shim).
//!     ├─adapter│  preview1 → component adapter; imports
//!     │        │  `__main_module__.<name>` from embed, `env.memory`
//!     │        │  from embed, and one inline-instance per WASI
//!     │        │  namespace (component `canon lower`'d).
//!     └─ fixup ┘  imports shim's `$imports` table, imports the
//!                 adapter's preview1 exports + canon-lowered indirect
//!                 wasi imports, and stores them into the shim table
//!                 via an active element segment.
//!
//! See plan.md for the full choreography and the dissection of
//! `/tmp/tiny_component.wasm` (wasm-tools reference output for
//! zig-hello).

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const writer = @import("../writer.zig");
const wtypes = @import("../../types.zig");

const decode = @import("decode.zig");
const types_import = @import("types_import.zig");
const core_imports = @import("core_imports.zig");
const shim = @import("shim.zig");
const fixup = @import("fixup.zig");
const abi = @import("abi.zig");
const gc = @import("gc.zig");
const world_gc = @import("world_gc.zig");
const metadata_decode = @import("../wit/metadata_decode.zig");
const lift_types = @import("../wit/lift_types.zig");
const type_walk = @import("../type_walk.zig");
const resource_intrinsics = @import("../resource_intrinsics.zig");
const leb = @import("../../leb128.zig");

pub const SpliceError = error{
    OutOfMemory,
    NotCoreWasm,
    InvalidAdapterCore,
    MissingEncodedWorld,
    UnsupportedAdapterShape,
    AdapterMissingRunExport,
    AdapterMissingPreview1Export,
    EmbedMissingRequiredExport,
    EmbedMissingCabiRealloc,
    AdapterMissingReallocExport,
    FuncNotFound,
    NotAFuncExport,
    UnsupportedShape,
    ValueTooLarge,
    LebOverflow,
    LebTruncated,
    // Reader/GC errors that can surface during the new GC pass.
    InvalidMagic,
    InvalidVersion,
    UnexpectedEof,
    InvalidSection,
    InvalidType,
    InvalidLimits,
    TooManyLocals,
    SectionTooLarge,
    FunctionCodeMismatch,
    UnsupportedOpcode,
    InvalidBody,
    MissingRequiredExport,
    InvalidIndex,
    // Multi-adapter errors.
    NoAdapters,
    MissingPrimaryAdapter,
    AmbiguousPrimaryAdapter,
    AdapterNamespaceCollision,
    SecondaryAdapterUnsupported,
    // Reactor-shape errors.
    MissingEmbedMetadata,
    InvalidComponentType,
    // Metadata-backed embed-extra import errors.
    InvalidEmbedMetadata,
    EmbedMetadataNamespaceNotFound,
    EmbedMetadataVersionMismatch,
    EmbedMetadataFunctionNotFound,
    EmbedMetadataFunctionMalformed,
    EmbedMetadataResourceNotFound,
    EmbedMetadataAliasMalformed,
    EmbedMetadataAliasCycle,
    EmbedImportSignatureMismatch,
    EmbedResourceIntrinsicSignatureMismatch,
    EmbedImportedResourceNewUnsupported,
    EmbedImportedResourceRepUnsupported,
    AdapterImportedResourceNewUnsupported,
    AdapterImportedResourceRepUnsupported,
    EmbedResourceMetadataRequired,
    EmbedImportFieldConflict,
} || writer.EncodeError;

/// One preview1-style adapter to splice in. `name` is the core
/// import module name the embed uses to refer to this adapter (e.g.
/// `wasi_snapshot_preview1`); `bytes` is the adapter core wasm.
pub const Adapter = struct {
    name: []const u8,
    bytes: []const u8,
};

/// Splice an embed against one or more preview1-style adapters into
/// a wrapping component. Mirrors the `wasm-tools component new
/// --adapt name1=… --adapt name2=…` surface; adapters are
/// instantiated in declaration order. Exactly one adapter must
/// declare a `wasi:cli/run` export.
///
/// Caller frees the returned slice via `gpa`.
pub fn spliceMany(gpa: Allocator, embed_bytes: []const u8, adapters: []const Adapter) ![]u8 {
    if (adapters.len == 0) return error.NoAdapters;
    if (adapters.len == 1) {
        return splice(gpa, embed_bytes, adapters[0].bytes, adapters[0].name);
    }
    return spliceN(gpa, embed_bytes, adapters);
}

/// Single-adapter splice. Preserved as a thin wrapper around the
/// canonical implementation for backward compatibility and for the
/// (common) N=1 path's byte-equivalence.
pub fn splice(
    gpa: Allocator,
    embed_bytes: []const u8,
    adapter_bytes: []const u8,
    adapter_name: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // ── Phase A.0: GC the adapter core wasm ────────────────────────────────
    //
    // Mirror `wit-component/src/gc.rs`: parse the adapter, walk the
    // call graph from the preview1 exports the embed actually
    // imports plus the adapter's `wasi:cli/run` entry point, drop
    // every func/global/table/elem/data/import that's unreachable.
    // This shrinks the embedded adapter core wasm dramatically.
    const required_exports = try computeRequiredAdapterExports(a, embed_bytes, adapter_bytes, adapter_name);
    const gc_bytes_initial = try gc.run(gpa, adapter_bytes, required_exports);
    defer gpa.free(gc_bytes_initial);

    // ── Phase A.1: GC the encoded-world AST ────────────────────────────────
    //
    // The core-wasm GC drops dead functions but the wrapping
    // component's top-level imports come from the adapter's encoded
    // world body, which still type-declares every WASI namespace the
    // adapter ships. Compute the live namespace set from the GC'd
    // adapter's actual core imports, prune the encoded-world AST to
    // match (renumbering instance / type indices for the surviving
    // subset), then splice the pruned encoded-world bytes back into
    // the adapter core wasm so the embedded module advertises only
    // what it imports.
    const pristine_world = try decode.parseFromAdapterCore(a, gc_bytes_initial);
    var pristine_iface = try core_imports.extract(gpa, gc_bytes_initial);
    defer pristine_iface.deinit();

    const live_namespaces = try collectLiveNamespaces(a, pristine_iface.interface);
    const live_methods_adapter = try collectLiveMethodsByNamespace(a, pristine_iface.interface);
    const live_methods_by_namespace = try augmentLiveMethodsByNamespaceWithEmbed(a, live_methods_adapter, embed_bytes);
    const live_export_names = try collectLiveExportNames(a, pristine_world);

    const gc_world_result = try world_gc.gcWorld(a, pristine_world, live_namespaces, live_methods_by_namespace, live_export_names);
    const gc_bytes = try world_gc.replaceEncodedWorldSection(a, gc_bytes_initial, gc_world_result.payload_bytes);

    // ── Phase A: decode + classify ─────────────────────────────────────────
    const world = gc_world_result.world;

    var adapter_owned = try core_imports.extract(gpa, gc_bytes);
    defer adapter_owned.deinit();
    var embed_owned = try core_imports.extract(gpa, embed_bytes);
    defer embed_owned.deinit();

    const hoisted = try types_import.hoist(a, world);

    // Decode once while the embed's component-type section is still
    // attached. When present this metadata is authoritative for both
    // reactor exports and direct component imports; malformed metadata
    // must not silently fall back to flattened core signatures.
    const embed_metadata = try decodeEmbedMetadata(a, embed_bytes);

    const preview1_slots = try collectPreview1Slots(a, embed_owned.interface, adapter_name);
    const buckets = try classifyAdapterImports(a, adapter_owned.interface, world, hoisted);
    const indirect_slots = try collectIndirectSlots(a, buckets);

    // Embed-extra slots (cataggar/wabt#230). One slot per func the
    // embed imports from a non-WASI, non-`env`, non-`__main_module__`
    // namespace. Their shim trampolines are appended after the
    // primary's indirect slots; the fixup module's table-population
    // pass canon.lowers each one with opts referencing main_inst's
    // memory + cabi_realloc.
    const embed_extra_plan = try buildEmbedExtraImportPlan(
        a,
        embed_owned.interface,
        embed_metadata,
        adapter_name,
        &.{},
        hoisted,
    );
    const embed_extra_slot_infos = embed_extra_plan.slot_infos;
    const embed_extra_slot_base: u32 = @intCast(preview1_slots.len + indirect_slots.len);

    var all_slots = try a.alloc(shim.Slot, preview1_slots.len + indirect_slots.len + embed_extra_slot_infos.len);
    for (preview1_slots, 0..) |p1, i| {
        all_slots[i] = .{ .params = p1.params, .results = p1.results };
    }
    @memcpy(all_slots[preview1_slots.len..][0..indirect_slots.len], indirect_slots);
    for (embed_extra_slot_infos, 0..) |info, i| {
        const resolver = abi.TypeResolver{ .inst_decls = info.inst_decls, .world_decls = info.world_decls };
        const ftr = abi.FuncTypeRef{ .func = info.func_type, .resolver = resolver };
        const lowered = try abi.lowerCoreSig(a, ftr);
        all_slots[preview1_slots.len + indirect_slots.len + i] = .{
            .params = lowered.params,
            .results = lowered.results,
        };
    }

    // ── Phase B: build shim + fixup core modules ──────────────────────────
    const shim_bytes = try shim.build(a, all_slots);
    const fixup_bytes = try fixup.build(a, all_slots);

    // ── Phase C: assemble + encode ────────────────────────────────────────
    return try assemble(.{
        .gpa = gpa,
        .arena = a,
        .embed_bytes = try stripComponentTypeSections(a, embed_bytes),
        .adapter_bytes = gc_bytes,
        .shim_bytes = shim_bytes,
        .fixup_bytes = fixup_bytes,
        .adapter_name = adapter_name,
        .world = world,
        .hoisted = hoisted,
        .embed_iface = embed_owned.interface,
        .adapter_iface = adapter_owned.interface,
        .preview1_slots = preview1_slots,
        .buckets = buckets,
        .shape = detectShape(adapter_owned.interface),
        .embed_metadata = embed_metadata,
        .embed_extra_plan = embed_extra_plan,
        .embed_extra_slot_base = embed_extra_slot_base,
    });
}

/// Multi-adapter splice (N >= 2). Routes the primary (the unique
/// adapter declaring `wasi:cli/run@…`) through the existing single-
/// adapter pipeline and layers each secondary's bare host-shim
/// exports through the shim/fixup table alongside the primary's
/// preview1 slots.
///
/// Restrictions for #114 — see plan.md and #116:
///   * exactly one adapter declares `wasi:cli/run@…` (the primary);
///   * each secondary imports only `env.<x>` (no WASI namespaces, no
///     `__main_module__.<x>`).
fn spliceN(gpa: Allocator, embed_bytes: []const u8, adapters: []const Adapter) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // ── Identify primary + validate secondaries ────────────────────────────
    const primary_idx = try findPrimaryAdapter(a, adapters);
    const primary = adapters[primary_idx];

    // Pre-validate every secondary against the bare-shim contract
    // before doing any GC / decode work; surfaces a clean error
    // before any expensive operations.
    for (adapters, 0..) |ad, i| {
        if (i == primary_idx) continue;
        try validateBareShimSecondary(a, ad);
    }

    // ── Phase A.0: GC the primary core wasm ────────────────────────────────
    const primary_required = try computeRequiredAdapterExports(a, embed_bytes, primary.bytes, primary.name);
    const primary_gc_initial = try gc.run(gpa, primary.bytes, primary_required);
    defer gpa.free(primary_gc_initial);

    // ── Phase A.1: GC the primary's encoded-world AST ──────────────────────
    const pristine_world = try decode.parseFromAdapterCore(a, primary_gc_initial);
    var pristine_iface = try core_imports.extract(gpa, primary_gc_initial);
    defer pristine_iface.deinit();

    const live_namespaces = try collectLiveNamespaces(a, pristine_iface.interface);
    const live_methods_adapter = try collectLiveMethodsByNamespace(a, pristine_iface.interface);
    const live_methods_by_namespace = try augmentLiveMethodsByNamespaceWithEmbed(a, live_methods_adapter, embed_bytes);
    const live_export_names = try collectLiveExportNames(a, pristine_world);

    const gc_world_result = try world_gc.gcWorld(a, pristine_world, live_namespaces, live_methods_by_namespace, live_export_names);
    const primary_gc_bytes = try world_gc.replaceEncodedWorldSection(a, primary_gc_initial, gc_world_result.payload_bytes);

    // ── Phase A: decode + classify (primary only) ──────────────────────────
    const world = gc_world_result.world;

    var primary_owned = try core_imports.extract(gpa, primary_gc_bytes);
    defer primary_owned.deinit();
    var embed_owned = try core_imports.extract(gpa, embed_bytes);
    defer embed_owned.deinit();

    const hoisted = try types_import.hoist(a, world);

    const embed_metadata = try decodeEmbedMetadata(a, embed_bytes);

    const preview1_slots = try collectPreview1Slots(a, embed_owned.interface, primary.name);
    const buckets = try classifyAdapterImports(a, primary_owned.interface, world, hoisted);
    const indirect_slots = try collectIndirectSlots(a, buckets);

    // ── Phase A.2: GC each secondary + collect its slots ───────────────────
    // Secondary required exports are the bare names the embed imports
    // under `<sec.name>.<x>`. (No `<iface>#…` exports — that's the
    // primary's role.)
    const SecondaryOwned = struct {
        owned: core_imports.Owned,
        gc_bytes: []const u8,
        slots: []const Preview1Slot,
    };
    const secondaries_owned = try a.alloc(SecondaryOwned, adapters.len - 1);
    var sec_i: usize = 0;
    var total_secondary_slots: u32 = 0;
    for (adapters, 0..) |ad, i| {
        if (i == primary_idx) continue;
        const sec_required = try computeBareSecondaryRequiredExports(a, embed_bytes, ad.name);
        const sec_gc = try gc.run(gpa, ad.bytes, sec_required);
        // Note: we deliberately don't `defer gpa.free(sec_gc)` here
        // because the bytes need to live until `assemble` consumes
        // them. We free them all at the end of this function.
        const sec_owned = try core_imports.extract(gpa, sec_gc);
        const slots = try collectPreview1Slots(a, embed_owned.interface, ad.name);
        secondaries_owned[sec_i] = .{ .owned = sec_owned, .gc_bytes = sec_gc, .slots = slots };
        total_secondary_slots += @intCast(slots.len);
        sec_i += 1;
    }
    defer for (secondaries_owned) |*s| {
        gpa.free(s.gc_bytes);
        s.owned.deinit();
    };

    // ── Build SecondaryInputs (with slot_offsets) ──────────────────────────
    const secondary_inputs = try a.alloc(SecondaryInputs, secondaries_owned.len);
    {
        var slot_cursor: u32 = @intCast(preview1_slots.len);
        var k: usize = 0;
        for (adapters, 0..) |ad, i| {
            if (i == primary_idx) continue;
            secondary_inputs[k] = .{
                .name = ad.name,
                .bytes = secondaries_owned[k].gc_bytes,
                .iface = secondaries_owned[k].owned.interface,
                .slots = secondaries_owned[k].slots,
                .slot_offset = slot_cursor,
            };
            slot_cursor += @intCast(secondaries_owned[k].slots.len);
            k += 1;
        }
    }

    // ── Phase B: build shim + fixup with the COMBINED slot table ───────────
    //
    // Slot layout:
    //   [0..P)              primary preview1
    //   [P..P+ΣS)           per-secondary bare exports
    //   [P+ΣS..P+ΣS+I)      primary indirect WASI imports (canon.lowered)
    //   [P+ΣS+I..P+ΣS+I+E)  embed-extra non-WASI imports
    //                       (canon.lowered, cataggar/wabt#230)
    const secondary_names = try a.alloc([]const u8, secondary_inputs.len);
    for (secondary_inputs, secondary_names) |sin, *out_name| out_name.* = sin.name;
    const embed_extra_plan = try buildEmbedExtraImportPlan(
        a,
        embed_owned.interface,
        embed_metadata,
        primary.name,
        secondary_names,
        hoisted,
    );
    const embed_extra_slot_infos = embed_extra_plan.slot_infos;
    const embed_extra_slot_base: u32 = @intCast(preview1_slots.len + total_secondary_slots + indirect_slots.len);

    var all_slots = try a.alloc(shim.Slot, preview1_slots.len + total_secondary_slots + indirect_slots.len + embed_extra_slot_infos.len);
    for (preview1_slots, 0..) |p1, i| {
        all_slots[i] = .{ .params = p1.params, .results = p1.results };
    }
    {
        var cursor: usize = preview1_slots.len;
        for (secondary_inputs) |sin| {
            for (sin.slots) |s| {
                all_slots[cursor] = .{ .params = s.params, .results = s.results };
                cursor += 1;
            }
        }
    }
    @memcpy(all_slots[preview1_slots.len + total_secondary_slots ..][0..indirect_slots.len], indirect_slots);
    for (embed_extra_slot_infos, 0..) |info, i| {
        const resolver = abi.TypeResolver{ .inst_decls = info.inst_decls, .world_decls = info.world_decls };
        const ftr = abi.FuncTypeRef{ .func = info.func_type, .resolver = resolver };
        const lowered = try abi.lowerCoreSig(a, ftr);
        all_slots[embed_extra_slot_base + i] = .{
            .params = lowered.params,
            .results = lowered.results,
        };
    }

    const shim_bytes = try shim.build(a, all_slots);
    const fixup_bytes = try fixup.build(a, all_slots);

    // ── Phase C: assemble + encode ─────────────────────────────────────────
    return try assemble(.{
        .gpa = gpa,
        .arena = a,
        .embed_bytes = try stripComponentTypeSections(a, embed_bytes),
        .adapter_bytes = primary_gc_bytes,
        .shim_bytes = shim_bytes,
        .fixup_bytes = fixup_bytes,
        .adapter_name = primary.name,
        .world = world,
        .hoisted = hoisted,
        .embed_iface = embed_owned.interface,
        .adapter_iface = primary_owned.interface,
        .preview1_slots = preview1_slots,
        .buckets = buckets,
        .shape = detectShape(primary_owned.interface),
        .secondaries = secondary_inputs,
        .embed_metadata = embed_metadata,
        .embed_extra_plan = embed_extra_plan,
        .embed_extra_slot_base = embed_extra_slot_base,
    });
}

/// Find the primary adapter — the unique one with at least one
/// non-`env` core import. Bare-shim secondaries import only
/// `env.<x>` (validated separately by `validateBareShimSecondary`),
/// so the primary is the **complement** of the secondary partition.
///
/// This signal works for both shapes:
///   * **command** primary — imports `__main_module__.<x>` and a
///     WASI namespace (e.g. `wasi:cli/stdout@…`);
///   * **reactor** primary — imports a WASI namespace but no
///     `__main_module__`.
///
/// Returns:
///   * `MissingPrimaryAdapter` if every adapter is `env`-only;
///   * `AmbiguousPrimaryAdapter` if more than one has non-`env`
///     imports.
fn findPrimaryAdapter(arena: Allocator, adapters: []const Adapter) SpliceError!usize {
    var primary_idx: ?usize = null;
    for (adapters, 0..) |ad, i| {
        const owned = try core_imports.extract(arena, ad.bytes);
        var has_non_env = false;
        for (owned.interface.imports) |im| {
            if (!std.mem.eql(u8, im.module_name, "env")) {
                has_non_env = true;
                break;
            }
        }
        if (has_non_env) {
            if (primary_idx != null) return error.AmbiguousPrimaryAdapter;
            primary_idx = i;
        }
    }
    return primary_idx orelse error.MissingPrimaryAdapter;
}

/// Validate that an adapter is a bare-shim secondary: every core
/// import has `module_name == "env"`. Reject anything else with
/// `error.SecondaryAdapterUnsupported` — `__main_module__`,
/// `wasi:*`, and any other host module imports require the
/// reactor/library plumbing tracked in #116.
fn validateBareShimSecondary(arena: Allocator, ad: Adapter) SpliceError!void {
    const owned = try core_imports.extract(arena, ad.bytes);
    for (owned.interface.imports) |im| {
        if (!std.mem.eql(u8, im.module_name, "env")) {
            return error.SecondaryAdapterUnsupported;
        }
    }
}

/// Compute the required core-wasm exports a secondary must keep
/// alive after GC: every name the embed imports under
/// `<secondary.name>.<x>`. Secondaries don't have `<iface>#…`
/// exports.
fn computeBareSecondaryRequiredExports(
    arena: Allocator,
    embed_bytes: []const u8,
    secondary_name: []const u8,
) SpliceError![]const []const u8 {
    const owned_embed = try core_imports.extract(arena, embed_bytes);
    var out = std.ArrayListUnmanaged([]const u8).empty;
    for (owned_embed.interface.imports) |im| {
        if (im.kind != .func) continue;
        if (!std.mem.eql(u8, im.module_name, secondary_name)) continue;
        const name = try arena.dupe(u8, im.field_name);
        try out.append(arena, name);
    }
    return out.toOwnedSlice(arena);
}

/// Collect the set of unique component-instance import names from the
/// GC'd adapter's actual core wasm imports. These are the WASI
/// namespaces (e.g. `wasi:cli/environment@0.2.6`) the adapter still
/// uses after core-wasm GC; everything else can be pruned from the
/// encoded world. Excludes the synthetic `env` and `__main_module__`
/// modules which are wired separately in `assemble`.
fn collectLiveNamespaces(
    arena: Allocator,
    adapter_iface: core_imports.CoreInterface,
) SpliceError![]const []const u8 {
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(arena);
    var out = std.ArrayListUnmanaged([]const u8).empty;
    for (adapter_iface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, "env")) continue;
        if (std.mem.eql(u8, im.module_name, "__main_module__")) continue;
        const gop = try seen.getOrPut(arena, im.module_name);
        if (!gop.found_existing) try out.append(arena, im.module_name);
    }
    return out.toOwnedSlice(arena);
}

/// For each live WASI namespace, collect the set of canon-ABI lowered
/// names the GC'd adapter still imports from it. Each name is one of:
///
///   * `[method]<resource>.<name>`
///   * `[static]<resource>.<name>`
///   * `[constructor]<resource>`
///   * `[resource-drop]<resource>` / `[resource-new]<resource>` /
///     `[resource-rep]<resource>`
///   * a bare iface-level function name (no `[…]` prefix).
///
/// These match the corresponding `.@"export" '<name>'` decls inside
/// each namespace's instance-type body in the encoded world. Any
/// `[*]<resource>*` form contributes `<resource>` to the per-namespace
/// resource set so that resource-only dependencies (e.g. an embed
/// that only `resource-drop`s a handle without calling any method) are
/// still anchored.
fn collectLiveMethodsByNamespace(
    arena: Allocator,
    adapter_iface: core_imports.CoreInterface,
) SpliceError![]const world_gc.LiveMethodSet {
    const NamespaceBuilder = struct {
        namespace: []const u8,
        methods: std.ArrayListUnmanaged([]const u8),
        method_seen: std.StringHashMapUnmanaged(void),
        type_exports: std.ArrayListUnmanaged([]const u8),
        type_export_seen: std.StringHashMapUnmanaged(void),
    };

    var by_ns = std.StringArrayHashMapUnmanaged(NamespaceBuilder).empty;
    defer by_ns.deinit(arena);

    for (adapter_iface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, "env")) continue;
        if (std.mem.eql(u8, im.module_name, "__main_module__")) continue;

        const gop = try by_ns.getOrPut(arena, im.module_name);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .namespace = im.module_name,
            .methods = .empty,
            .method_seen = .empty,
            .type_exports = .empty,
            .type_export_seen = .empty,
        };
        const b = gop.value_ptr;

        const method_gop = try b.method_seen.getOrPut(arena, im.field_name);
        if (!method_gop.found_existing) try b.methods.append(arena, im.field_name);

        if (extractResourceName(im.field_name)) |rname| {
            const t_gop = try b.type_export_seen.getOrPut(arena, rname);
            if (!t_gop.found_existing) try b.type_exports.append(arena, rname);
        }
    }

    var out = try arena.alloc(world_gc.LiveMethodSet, by_ns.count());
    var i: usize = 0;
    var it = by_ns.iterator();
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{
            .namespace = entry.value_ptr.namespace,
            .methods = try entry.value_ptr.methods.toOwnedSlice(arena),
            .type_exports = try entry.value_ptr.type_exports.toOwnedSlice(arena),
        };
    }
    return out;
}

/// Augment a `live_methods_by_namespace` set with methods + type
/// exports declared by the embed's `component-type:<world>` custom
/// section. Mirrors `wit-component`'s policy: every iface the user's
/// WIT names as an import is kept verbatim in the wrapping
/// component's instance-type body — its declared methods are the
/// contract the user wrote and must survive the adapter-driven GC
/// regardless of which lowered names the adapter happened to need
/// (cataggar/wabt#222).
///
/// Returns `base` unchanged when the embed has no component-type
/// section, or when decoding it fails (we fall back to the adapter-
/// derived view rather than failing the splice).
fn augmentLiveMethodsByNamespaceWithEmbed(
    arena: Allocator,
    base: []const world_gc.LiveMethodSet,
    embed_bytes: []const u8,
) SpliceError![]const world_gc.LiveMethodSet {
    const NamespaceBuilder = struct {
        namespace: []const u8,
        methods: std.ArrayListUnmanaged([]const u8),
        method_seen: std.StringHashMapUnmanaged(void),
        type_exports: std.ArrayListUnmanaged([]const u8),
        type_export_seen: std.StringHashMapUnmanaged(void),
    };

    var by_ns = std.StringArrayHashMapUnmanaged(NamespaceBuilder).empty;
    defer by_ns.deinit(arena);

    // Seed from the adapter-derived view.
    for (base) |s| {
        const gop = try by_ns.getOrPut(arena, s.namespace);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .namespace = s.namespace,
            .methods = .empty,
            .method_seen = .empty,
            .type_exports = .empty,
            .type_export_seen = .empty,
        };
        const b = gop.value_ptr;
        for (s.methods) |m| {
            const mg = try b.method_seen.getOrPut(arena, m);
            if (!mg.found_existing) try b.methods.append(arena, m);
        }
        for (s.type_exports) |t| {
            const tg = try b.type_export_seen.getOrPut(arena, t);
            if (!tg.found_existing) try b.type_exports.append(arena, t);
        }
    }

    // Decode the embed's component-type. Absent / malformed → fall
    // back to the adapter-derived view unchanged.
    const found = metadata_decode.extractFromCoreWasm(embed_bytes) catch
        return finalizeLiveSet(arena, &by_ns);
    const ct = found orelse return finalizeLiveSet(arena, &by_ns);

    const decoded = metadata_decode.decode(arena, ct.payload) catch
        return finalizeLiveSet(arena, &by_ns);

    // For each embed-declared import, add every `.@"export"` name
    // its instance-type body declares. Methods (`.@"export" func`)
    // contribute to `methods`; type exports (`.@"export" type`)
    // contribute to `type_exports`. The encoded names match the
    // canonical lowered form (e.g. `[method]pollable.ready`,
    // `pollable`), so they line up 1:1 with `gcInstanceBody`'s
    // name-match seeding.
    for (decoded.externs) |ext| {
        if (ext.is_export) continue;

        const gop = try by_ns.getOrPut(arena, ext.qualified_name);
        if (!gop.found_existing) gop.value_ptr.* = .{
            .namespace = ext.qualified_name,
            .methods = .empty,
            .method_seen = .empty,
            .type_exports = .empty,
            .type_export_seen = .empty,
        };
        const b = gop.value_ptr;

        for (ext.inst_decls) |d| switch (d) {
            .@"export" => |e| switch (e.desc) {
                .func => {
                    const mg = try b.method_seen.getOrPut(arena, e.name);
                    if (!mg.found_existing) try b.methods.append(arena, e.name);
                },
                .type => {
                    const tg = try b.type_export_seen.getOrPut(arena, e.name);
                    if (!tg.found_existing) try b.type_exports.append(arena, e.name);
                },
                else => {},
            },
            else => {},
        };
    }

    return finalizeLiveSet(arena, &by_ns);
}

fn finalizeLiveSet(
    arena: Allocator,
    by_ns: anytype,
) SpliceError![]const world_gc.LiveMethodSet {
    var out = try arena.alloc(world_gc.LiveMethodSet, by_ns.count());
    var i: usize = 0;
    var it = by_ns.iterator();
    while (it.next()) |entry| : (i += 1) {
        out[i] = .{
            .namespace = entry.value_ptr.namespace,
            .methods = try entry.value_ptr.methods.toOwnedSlice(arena),
            .type_exports = try entry.value_ptr.type_exports.toOwnedSlice(arena),
        };
    }
    return out;
}

/// Recover the resource name from a canon-ABI lowered field name.
/// Returns null for bare iface-level functions (no `[<tag>]` prefix).
fn extractResourceName(field_name: []const u8) ?[]const u8 {
    if (field_name.len == 0 or field_name[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, field_name, ']') orelse return null;
    const tag = field_name[1..close];
    const rest = field_name[close + 1 ..];
    if (std.mem.eql(u8, tag, "method") or std.mem.eql(u8, tag, "static")) {
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
        return rest[0..dot];
    }
    if (std.mem.eql(u8, tag, "constructor") or
        std.mem.eql(u8, tag, "resource-drop") or
        std.mem.eql(u8, tag, "resource-new") or
        std.mem.eql(u8, tag, "resource-rep"))
    {
        return rest;
    }
    return null;
}

/// All world body exports are live by construction — the splicer
/// always lifts them at the wrapping component's top level.
fn collectLiveExportNames(
    arena: Allocator,
    world: decode.AdapterWorld,
) SpliceError![]const []const u8 {
    const out = try arena.alloc([]const u8, world.exports.len);
    for (world.exports, out) |e, *o| o.* = e.name;
    return out;
}

/// Compute the export-name set the adapter must keep alive for the
/// embed to function. Pre-conditions:
///
///   * Every embed import whose `module_name == adapter_name` (e.g.
///     `wasi_snapshot_preview1`) must be matched by an adapter
///     export of the same field name.
///   * The adapter's `wasi:cli/run@<ver>#run` export — the entry
///     point the wrapping component lifts — must survive.
///   * `cabi_import_realloc` is preserved opportunistically by
///     `gc.run` if exported.
fn computeRequiredAdapterExports(
    arena: Allocator,
    embed_bytes: []const u8,
    adapter_bytes: []const u8,
    adapter_name: []const u8,
) SpliceError![]const []const u8 {
    // `core_imports.extract` allocates via `gpa` (its first arg). We
    // pass the splice arena so deinit is a no-op; the underlying
    // `Module` and its byte-slice strings stay alive for the rest of
    // the splice.
    const owned_embed = try core_imports.extract(arena, embed_bytes);
    const owned_adapter = try core_imports.extract(arena, adapter_bytes);

    var out = std.ArrayListUnmanaged([]const u8).empty;

    // Embed → adapter preview1 imports. The adapter exports each
    // preview1 syscall under its bare field name (e.g. `fd_write`),
    // not the qualified `wasi_snapshot_preview1.fd_write` import
    // notation, so we strip the module name.
    for (owned_embed.interface.imports) |im| {
        if (im.kind != .func) continue;
        if (!std.mem.eql(u8, im.module_name, adapter_name)) continue;
        const name = try arena.dupe(u8, im.field_name);
        try out.append(arena, name);
    }

    // The adapter's `wasi:cli/run@<ver>#run` (or any other instance
    // member export). Adapter exports use the syntax
    // `<iface>#<name>` for instance member exports — pick those so
    // the adapter's lifted entry point survives GC.
    for (owned_adapter.interface.exports) |ex| {
        if (std.mem.indexOfScalar(u8, ex.name, '#') == null) continue;
        const dup = try arena.dupe(u8, ex.name);
        try out.append(arena, dup);
    }

    return out.toOwnedSlice(arena);
}

// ── Slot / bucket collection ──────────────────────────────────────────────

const Preview1Slot = struct {
    name: []const u8,
    params: []const wtypes.ValType,
    results: []const wtypes.ValType,
};

fn collectPreview1Slots(
    arena: Allocator,
    embed_iface: core_imports.CoreInterface,
    adapter_name: []const u8,
) SpliceError![]const Preview1Slot {
    var out = std.ArrayListUnmanaged(Preview1Slot).empty;
    for (embed_iface.imports) |im| {
        if (im.kind != .func) continue;
        if (!std.mem.eql(u8, im.module_name, adapter_name)) continue;
        const sig = im.sig orelse continue;
        try out.append(arena, .{
            .name = im.field_name,
            .params = sig.params,
            .results = sig.results,
        });
    }
    return out.toOwnedSlice(arena);
}

const AdapterResourceDrop = struct {
    field_name: []const u8,
    resource_name: []const u8,
};

const IndirectFunc = struct {
    name: []const u8,
    /// Slot index in `shim_slots`, RELATIVE to the start of the
    /// indirect block (i.e. excluding preview1 slots). Filled in.
    slot_idx: u32 = 0,
    cls: abi.Classification,
    ftr: abi.FuncTypeRef,
};

const DirectFunc = struct {
    name: []const u8,
    cls: abi.Classification,
    ftr: abi.FuncTypeRef,
};

const NamespaceBucket = struct {
    name: []const u8,
    instance_idx: u32,
    body_type_idx: u32,
    resource_drops: []AdapterResourceDrop,
    indirect_funcs: []IndirectFunc,
    direct_funcs: []DirectFunc,
};

fn classifyAdapterImports(
    arena: Allocator,
    adapter_iface: core_imports.CoreInterface,
    world: decode.AdapterWorld,
    hoisted: types_import.Hoisted,
) SpliceError![]NamespaceBucket {
    var bucket_names = std.ArrayListUnmanaged([]const u8).empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(arena);

    for (adapter_iface.imports) |im| {
        if (im.kind != .func) continue;
        if (std.mem.eql(u8, im.module_name, "env")) continue;
        if (std.mem.eql(u8, im.module_name, "__main_module__")) continue;
        const gop = try seen.getOrPut(arena, im.module_name);
        if (!gop.found_existing) try bucket_names.append(arena, im.module_name);
    }

    const buckets = try arena.alloc(NamespaceBucket, bucket_names.items.len);

    for (bucket_names.items, 0..) |bn, bi| {
        var resource_drops = std.ArrayListUnmanaged(AdapterResourceDrop).empty;
        var ind_list = std.ArrayListUnmanaged(IndirectFunc).empty;
        var dir_list = std.ArrayListUnmanaged(DirectFunc).empty;

        const slot = findInstanceSlot(hoisted, bn) orelse return error.UnsupportedAdapterShape;

        for (adapter_iface.imports) |im| {
            if (im.kind != .func) continue;
            if (!std.mem.eql(u8, im.module_name, bn)) continue;
            if (resource_intrinsics.classify(im.field_name)) |intrinsic| {
                const sig = im.sig orelse return error.UnsupportedAdapterShape;
                intrinsic.kind.validateCoreSignature(sig.params, sig.results) catch
                    return error.EmbedResourceIntrinsicSignatureMismatch;
                switch (intrinsic.kind) {
                    .drop => {},
                    .new => return error.AdapterImportedResourceNewUnsupported,
                    .rep => return error.AdapterImportedResourceRepUnsupported,
                }
                try resource_drops.append(arena, .{
                    .field_name = im.field_name,
                    .resource_name = intrinsic.resource,
                });
                continue;
            }

            const ftr = abi.findFuncImport(world, slot.type_idx, im.field_name) catch
                return error.UnsupportedAdapterShape;
            const cls = abi.classifyFunc(ftr);
            switch (cls.class) {
                .direct => try dir_list.append(arena, .{
                    .name = im.field_name,
                    .cls = cls,
                    .ftr = ftr,
                }),
                .indirect => try ind_list.append(arena, .{
                    .name = im.field_name,
                    .cls = cls,
                    .ftr = ftr,
                }),
            }
        }

        buckets[bi] = .{
            .name = bn,
            .instance_idx = slot.instance_idx,
            .body_type_idx = slot.type_idx,
            .resource_drops = try resource_drops.toOwnedSlice(arena),
            .indirect_funcs = try ind_list.toOwnedSlice(arena),
            .direct_funcs = try dir_list.toOwnedSlice(arena),
        };
    }

    var slot_cursor: u32 = 0;
    for (buckets) |*b| {
        for (b.indirect_funcs) |*f| {
            f.slot_idx = slot_cursor;
            slot_cursor += 1;
        }
    }
    return buckets;
}

fn findInstanceSlot(h: types_import.Hoisted, name: []const u8) ?types_import.InstanceSlot {
    for (h.instances) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn collectIndirectSlots(arena: Allocator, buckets: []const NamespaceBucket) SpliceError![]shim.Slot {
    var out = std.ArrayListUnmanaged(shim.Slot).empty;
    for (buckets) |b| {
        for (b.indirect_funcs) |f| {
            const sig = try abi.lowerCoreSig(arena, f.ftr);
            try out.append(arena, .{ .params = sig.params, .results = sig.results });
        }
    }
    return out.toOwnedSlice(arena);
}

fn arenaDup(arena: Allocator, src: []const u8) SpliceError![]u8 {
    const buf = try arena.alloc(u8, src.len);
    @memcpy(buf, src);
    return buf;
}

// ── Component assembly ────────────────────────────────────────────────────

const Inputs = struct {
    gpa: Allocator,
    arena: Allocator,
    embed_bytes: []const u8,
    adapter_bytes: []const u8,
    shim_bytes: []const u8,
    fixup_bytes: []const u8,
    adapter_name: []const u8,
    world: decode.AdapterWorld,
    hoisted: types_import.Hoisted,
    embed_iface: core_imports.CoreInterface,
    adapter_iface: core_imports.CoreInterface,
    preview1_slots: []const Preview1Slot,
    buckets: []NamespaceBucket,
    /// Adapter shape — drives whether `assemble()` emits the
    /// command-style `__main_module__` plumbing + run sub-component
    /// (`.command`) or the reactor per-export-interface lift loop
    /// (`.reactor`). Defaults to `.command` for backward compatibility
    /// with tests that don't set it explicitly.
    shape: Shape = .command,
    /// Pre-decoded embed metadata for the reactor branch. Populated
    /// by `splice`/`spliceN` from the embed's `component-type:*`
    /// custom section before that section is stripped from
    /// `embed_bytes`. Required only when `shape == .reactor`; the
    /// reactor branch reads it to recover per-export-interface
    /// FuncTypes for canon-lift.
    embed_metadata: ?metadata_decode.DecodedWorld = null,
    /// Optional secondary "bare-shim" adapters layered alongside the
    /// primary. Each secondary contributes additional slots to the
    /// shim/fixup table (located at
    /// `[primary preview1 | secondary[0] | … | secondary[N-1] | primary indirect]`)
    /// and one extra core module + core instance in the assembled
    /// component. Empty for the single-adapter case.
    secondaries: []const SecondaryInputs = &.{},
    /// Arena-owned authoritative plan for the embed's direct component
    /// imports. It is shared by slot construction and assembly so the
    /// two phases cannot disagree about ordering or intrinsic fields.
    /// Its ordinary `slot_infos` map 1:1 to shim slots at
    /// `embed_extra_slot_base + i`; resource intrinsics are excluded.
    embed_extra_plan: EmbedExtraImportPlan = .{},
    /// Global shim-table offset where this splice's embed-extra
    /// slots start. Computed in `splice`/`spliceN` as
    /// `preview1.len + Σ(secondaries) + indirect.len`.
    embed_extra_slot_base: u32 = 0,
};

/// Adapter shape, mirroring the wit-component reference encoder's
/// `command` / `reactor` distinction. `library` is deferred to #127.
///
///   * `.command`  — the adapter declares `wasi:cli/run@…` and
///     drives the embed via `__main_module__._start`. The
///     wrapping component lifts a single `wasi:cli/run` export.
///   * `.reactor`  — the adapter has no `<iface>#name` exports and
///     no `__main_module__.<x>` imports. The wrapping component
///     lifts each `<iface>#<func>` export the **embed** declares
///     into one top-level instance per export interface.
pub const Shape = enum { command, reactor };

/// Classify an adapter's core wasm shape from its exports. The
/// presence of any `<iface>#<name>`-shaped export means the
/// adapter implements a `wasi:cli/run`-style lifted entry —
/// command shape. Their absence means the adapter is a passive
/// preview1→component bridge whose entry points live in the
/// embed — reactor shape.
pub fn detectShape(iface: core_imports.CoreInterface) Shape {
    for (iface.exports) |ex| {
        if (std.mem.indexOfScalar(u8, ex.name, '#') != null) return .command;
    }
    return .reactor;
}

/// Per-secondary data needed by `assemble`. Built by `spliceN`.
pub const SecondaryInputs = struct {
    name: []const u8,
    /// Already-GC'd core wasm bytes.
    bytes: []const u8,
    iface: core_imports.CoreInterface,
    /// Preview1-style export slots — names this secondary exports
    /// that the embed imports under `<name>.<x>`. Treated identically
    /// to primary preview1 slots downstream.
    slots: []const Preview1Slot,
    /// Position in the combined shim/fixup slot table where this
    /// secondary's slots begin. Used by `assemble` when emitting
    /// shim alias names (`{slot_total}`) for each export.
    slot_offset: u32,
};

/// `Builder` accumulates per-section arrays + section_order entries
/// + running indexspace cursors. Every "add…" returns the
/// indexspace position of the freshly added item so the caller can
/// reference it from later items (canons, instantiate args, etc.).
const Builder = struct {
    arena: Allocator,

    types: std.ArrayListUnmanaged(ctypes.TypeDef) = .empty,
    aliases: std.ArrayListUnmanaged(ctypes.Alias) = .empty,
    imports: std.ArrayListUnmanaged(ctypes.ImportDecl) = .empty,
    core_modules: std.ArrayListUnmanaged(ctypes.CoreModule) = .empty,
    core_instances: std.ArrayListUnmanaged(ctypes.CoreInstanceExpr) = .empty,
    canons: std.ArrayListUnmanaged(ctypes.Canon) = .empty,
    components: std.ArrayListUnmanaged(*ctypes.Component) = .empty,
    instances: std.ArrayListUnmanaged(ctypes.InstanceExpr) = .empty,
    exports: std.ArrayListUnmanaged(ctypes.ExportDecl) = .empty,
    section_order: std.ArrayListUnmanaged(ctypes.SectionEntry) = .empty,

    /// Indexspace cursors. Updated as items are appended.
    type_cursor: u32 = 0,
    instance_cursor: u32 = 0,
    func_cursor: u32 = 0,
    core_func_cursor: u32 = 0,
    core_table_cursor: u32 = 0,
    core_mem_cursor: u32 = 0,

    /// Add a section_order entry for the most recent append. Merges
    /// with the previous entry if same kind + contiguous range.
    fn addSection(self: *Builder, kind: ctypes.SectionKind, start: u32) !void {
        if (self.section_order.items.len > 0) {
            const last = &self.section_order.items[self.section_order.items.len - 1];
            if (last.kind == kind and last.start + last.count == start) {
                last.count += 1;
                return;
            }
        }
        try self.section_order.append(self.arena, .{ .kind = kind, .start = start, .count = 1 });
    }

    fn addType(self: *Builder, td: ctypes.TypeDef) !u32 {
        const start: u32 = @intCast(self.types.items.len);
        try self.types.append(self.arena, td);
        try self.addSection(.type, start);
        const idx = self.type_cursor;
        self.type_cursor += 1;
        return idx;
    }

    fn addAlias(self: *Builder, al: ctypes.Alias) !u32 {
        const start: u32 = @intCast(self.aliases.items.len);
        try self.aliases.append(self.arena, al);
        try self.addSection(.alias, start);

        const sort: ctypes.Sort = switch (al) {
            .instance_export => |ie| ie.sort,
            .outer => |o| o.sort,
        };
        return switch (sort) {
            .core => |cs| switch (cs) {
                .func => blk: {
                    const i = self.core_func_cursor;
                    self.core_func_cursor += 1;
                    break :blk i;
                },
                .table => blk: {
                    const i = self.core_table_cursor;
                    self.core_table_cursor += 1;
                    break :blk i;
                },
                .memory => blk: {
                    const i = self.core_mem_cursor;
                    self.core_mem_cursor += 1;
                    break :blk i;
                },
                else => 0,
            },
            .func => blk: {
                const i = self.func_cursor;
                self.func_cursor += 1;
                break :blk i;
            },
            .type => blk: {
                const i = self.type_cursor;
                self.type_cursor += 1;
                break :blk i;
            },
            .instance => blk: {
                const i = self.instance_cursor;
                self.instance_cursor += 1;
                break :blk i;
            },
            else => 0,
        };
    }

    fn addCoreModule(self: *Builder, m: ctypes.CoreModule) !u32 {
        const start: u32 = @intCast(self.core_modules.items.len);
        try self.core_modules.append(self.arena, m);
        try self.addSection(.core_module, start);
        return start;
    }

    fn addCoreInstance(self: *Builder, e: ctypes.CoreInstanceExpr) !u32 {
        const start: u32 = @intCast(self.core_instances.items.len);
        try self.core_instances.append(self.arena, e);
        try self.addSection(.core_instance, start);
        return start;
    }

    fn addCanon(self: *Builder, c: ctypes.Canon) !u32 {
        const start: u32 = @intCast(self.canons.items.len);
        try self.canons.append(self.arena, c);
        try self.addSection(.canon, start);
        switch (c) {
            .lift => {
                const i = self.func_cursor;
                self.func_cursor += 1;
                return i;
            },
            .lower, .resource_drop, .resource_new, .resource_rep, .future_new, .future_read, .future_write, .future_cancel_read, .future_cancel_write, .future_drop_readable, .future_drop_writable, .stream_new, .stream_read, .stream_write, .stream_cancel_read, .stream_cancel_write, .stream_drop_readable, .stream_drop_writable, .error_context_new, .error_context_debug_message, .error_context_drop, .task_return, .waitable_set_new, .waitable_set_wait, .waitable_set_poll, .waitable_set_drop, .waitable_join, .task_cancel, .subtask_cancel, .subtask_drop, .context_get, .context_set, .backpressure_inc, .backpressure_dec, .thread_yield => {
                const i = self.core_func_cursor;
                self.core_func_cursor += 1;
                return i;
            },
        }
    }

    fn addNestedComponent(self: *Builder, c: *ctypes.Component) !u32 {
        const start: u32 = @intCast(self.components.items.len);
        try self.components.append(self.arena, c);
        try self.addSection(.component, start);
        return start;
    }

    fn addInstance(self: *Builder, e: ctypes.InstanceExpr) !u32 {
        const start: u32 = @intCast(self.instances.items.len);
        try self.instances.append(self.arena, e);
        try self.addSection(.instance, start);
        const idx = self.instance_cursor;
        self.instance_cursor += 1;
        return idx;
    }

    fn addExport(self: *Builder, e: ctypes.ExportDecl) !void {
        const start: u32 = @intCast(self.exports.items.len);
        try self.exports.append(self.arena, e);
        try self.addSection(.@"export", start);
    }

    /// Append a top-level component-level import. The caller is
    /// responsible for any preceding type defs the import references.
    /// Returns the indexspace position the import lives at, in the
    /// indexspace it occupies (instance / func / type / component
    /// depending on `desc`). For `.instance` desc, returns the
    /// instance-indexspace position.
    fn addImport(self: *Builder, im: ctypes.ImportDecl) !u32 {
        const start: u32 = @intCast(self.imports.items.len);
        try self.imports.append(self.arena, im);
        try self.addSection(.import, start);
        return switch (im.desc) {
            .instance => blk: {
                const i = self.instance_cursor;
                self.instance_cursor += 1;
                break :blk i;
            },
            .func => blk: {
                const i = self.func_cursor;
                self.func_cursor += 1;
                break :blk i;
            },
            .type => blk: {
                const i = self.type_cursor;
                self.type_cursor += 1;
                break :blk i;
            },
            else => 0,
        };
    }
};

/// Adapter-side context for the shared `lift_types` transcriber: it
/// hoists compound value types via the `Builder` and leaves resource
/// handles / aliased `use`d types untouched (the reactor lift path
/// doesn't rewrite those — preserving pre-#246 behaviour).
const ReactorLiftCtx = struct {
    b: *Builder,

    pub fn addType(self: @This(), td: ctypes.TypeDef) lift_types.Error!u32 {
        return self.b.addType(td);
    }

    pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) lift_types.Error!ctypes.ValType {
        _ = self;
        return v;
    }
};

fn assemble(in: Inputs) ![]u8 {
    const a = in.arena;

    var b = Builder{ .arena = a };

    // ── Step 1: hoisted body decls ──────────────────────────────────────
    // We adopt the hoisted slices directly (no copy) and EXTEND them
    // with our additions. The hoisted body's section_order is included
    // verbatim except we DROP `.@"export"` entries — those represent
    // the world body's `(export "wasi:cli/run@<ver>" instance)` decl
    // which the splicer replaces with a top-level instance export.
    try b.types.appendSlice(a, in.hoisted.types);
    try b.aliases.appendSlice(a, in.hoisted.aliases);
    try b.imports.appendSlice(a, in.hoisted.imports);
    b.type_cursor = in.hoisted.type_count;
    b.instance_cursor = @intCast(in.hoisted.instances.len);
    for (in.hoisted.section_order) |se| {
        if (se.kind == .@"export") continue;
        try b.section_order.append(a, se);
    }

    // The hoisted body's `imports` field becomes the wrapping
    // component's `imports[]`. It's referenced by section_order
    // entries with kind=.import, which we keep as-is.

    // ── Step 2: NEW types for canon-lift run ──────────────────────────
    // (result), (func () -> result)
    const run_result_type_idx = try b.addType(.{ .result = .{ .ok = null, .err = null } });
    const run_func_type_idx = try b.addType(.{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = run_result_type_idx } },
    } });

    // ── Step 3: core modules (main=0, adapter=1, shim=2, fixup=3, …) ──
    const main_module_idx = try b.addCoreModule(.{ .data = in.embed_bytes });
    const adapter_module_idx = try b.addCoreModule(.{ .data = in.adapter_bytes });
    const shim_module_idx = try b.addCoreModule(.{ .data = in.shim_bytes });
    const fixup_module_idx = try b.addCoreModule(.{ .data = in.fixup_bytes });

    // One core module per secondary adapter, in declaration order.
    const secondary_module_idxs = try a.alloc(u32, in.secondaries.len);
    for (in.secondaries, secondary_module_idxs) |sec, *out| {
        out.* = try b.addCoreModule(.{ .data = sec.bytes });
    }

    // ── Step 4: shim instance ────────────────────────────────────────
    const shim_inst = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = shim_module_idx,
        .args = &.{},
    } });

    // ── Step 5: preview1 inline-export instance for embed (primary) ──
    var preview1_inline = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;
    for (in.preview1_slots, 0..) |p1, i| {
        const stub_name = try std.fmt.allocPrint(a, "{d}", .{i});
        const f_idx = try b.addAlias(.{ .instance_export = .{
            .sort = .{ .core = .func },
            .instance_idx = shim_inst,
            .name = stub_name,
        } });
        try preview1_inline.append(a, .{
            .name = p1.name,
            .sort_idx = .{ .sort = .func, .idx = f_idx },
        });
    }
    const preview1_inst = try b.addCoreInstance(.{ .exports = try preview1_inline.toOwnedSlice(a) });

    // ── Step 5a: per-secondary inline-export instance for embed ──────
    // Each secondary contributes a slice of slots in the combined
    // shim/fixup table at `[sec.slot_offset, sec.slot_offset + sec.slots.len)`.
    // We build one inline-export instance per secondary that aliases
    // those shim slots under the secondary's bare export names; the
    // embed will be instantiated with each as `<sec.name> = …`.
    const secondary_preview1_insts = try a.alloc(u32, in.secondaries.len);
    for (in.secondaries, secondary_preview1_insts) |sec, *out| {
        var inline_exps = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;
        for (sec.slots, 0..) |s, j| {
            const slot_total: u32 = sec.slot_offset + @as(u32, @intCast(j));
            const stub_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
            const f_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = shim_inst,
                .name = stub_name,
            } });
            try inline_exps.append(a, .{
                .name = s.name,
                .sort_idx = .{ .sort = .func, .idx = f_idx },
            });
        }
        out.* = try b.addCoreInstance(.{ .exports = try inline_exps.toOwnedSlice(a) });
    }

    // ── Step 5b: lift non-WASI embed imports to component imports ─────
    // The embed may import core funcs from namespaces beyond the
    // WASI adapter (e.g. `docs:adder/add@0.1.0` for the calculator
    // fixture). These don't go through the adapter — instead, lift
    // each module-level group to a top-level component instance
    // import, alias each func through the shim's trampoline table
    // (so the fixup module can canon.lower with proper opts after
    // main_inst is created — cataggar/wabt#230), and bundle the
    // trampoline aliases into an inline-export instance the embed
    // consumes directly.
    var embed_extra_iface_inst_for_ns = std.StringHashMapUnmanaged(u32).empty;
    const embed_extra_args = try buildEmbedExtraImports(&b, a, in, shim_inst, &embed_extra_iface_inst_for_ns);

    // ── Step 6: instantiate main with primary + secondaries + extras ─
    const main_args = try a.alloc(
        ctypes.CoreInstantiateArg,
        1 + in.secondaries.len + embed_extra_args.len,
    );
    main_args[0] = .{ .name = in.adapter_name, .instance_idx = preview1_inst };
    for (in.secondaries, secondary_preview1_insts, 0..) |sec, sec_inst, i| {
        main_args[1 + i] = .{ .name = sec.name, .instance_idx = sec_inst };
    }
    for (embed_extra_args, 0..) |ea, i| {
        main_args[1 + in.secondaries.len + i] = .{ .name = ea.name, .instance_idx = ea.inst_idx };
    }
    const main_inst = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = main_module_idx,
        .args = main_args,
    } });

    // ── Step 7: env (memory) and __main_module__ inline instances ────
    const memory_idx = try b.addAlias(.{ .instance_export = .{
        .sort = .{ .core = .memory },
        .instance_idx = main_inst,
        .name = "memory",
    } });
    const env_inst = blk: {
        const exps = try a.alloc(ctypes.CoreInlineExport, 1);
        exps[0] = .{ .name = "memory", .sort_idx = .{ .sort = .memory, .idx = memory_idx } };
        break :blk try b.addCoreInstance(.{ .exports = exps });
    };

    // The standard wasmtime preview1 adapters import `__main_module__.<f>` for
    // functions they need from the embed: command adapters import the entry
    // point (`_start`), and *both* command and reactor adapters import
    // `__main_module__.cabi_realloc` so the adapter can allocate lists/strings in
    // the guest's memory while translating preview1<->preview2. Wire every such
    // import to the embed's matching export (or a generated fallback module for
    // anything the embed lacks). Adapters with no `__main_module__` imports skip
    // this plumbing entirely. Gating on the import set (not the command/reactor
    // shape) is required for the reactor adapter — see cataggar/wabt#327.
    var has_main_module_imports = false;
    for (in.adapter_iface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, "__main_module__")) {
            has_main_module_imports = true;
            break;
        }
    }
    const main_module_inst: ?u32 = if (has_main_module_imports) blk: {
        // Mirror the wasm-tools reference: alias every __main_module__
        // import the adapter requires. If the embed has a matching
        // export, alias the embed. Otherwise alias the fallback module.
        var exps = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;

        // Determine if we need a fallback core module (i.e. any
        // __main_module__ import the embed lacks). Currently that's
        // typically `cabi_realloc` for embeds that don't export it.
        var needs_fallback = false;
        for (in.adapter_iface.imports) |im| {
            if (im.kind != .func) continue;
            if (!std.mem.eql(u8, im.module_name, "__main_module__")) continue;
            if (in.embed_iface.findExport(im.field_name) == null) {
                needs_fallback = true;
                break;
            }
        }

        var fallback_inst: u32 = undefined;
        if (needs_fallback) {
            const fallback_bytes = try buildMainModuleFallback(a, in.adapter_iface);
            const fallback_module_idx = try b.addCoreModule(.{ .data = fallback_bytes });
            // The fallback imports `env.memory` when it has to provide
            // a working `cabi_realloc`. Always pass `env = env_inst`
            // — modules that don't import env simply ignore the arg.
            const fb_args = try a.alloc(ctypes.CoreInstantiateArg, 1);
            fb_args[0] = .{ .name = "env", .instance_idx = env_inst };
            fallback_inst = try b.addCoreInstance(.{ .instantiate = .{
                .module_idx = fallback_module_idx,
                .args = fb_args,
            } });
        }

        for (in.adapter_iface.imports) |im| {
            if (im.kind != .func) continue;
            if (!std.mem.eql(u8, im.module_name, "__main_module__")) continue;
            const have_in_embed = in.embed_iface.findExport(im.field_name) != null;
            const src_inst = if (have_in_embed) main_inst else fallback_inst;
            const f_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = src_inst,
                .name = im.field_name,
            } });
            try exps.append(a, .{
                .name = im.field_name,
                .sort_idx = .{ .sort = .func, .idx = f_idx },
            });
        }
        break :blk try b.addCoreInstance(.{ .exports = try exps.toOwnedSlice(a) });
    } else null;

    // ── Step 7b: instantiate each secondary core module ──────────────
    // Secondaries are bare-shim host modules: they import only
    // `env.<x>` (validated upstream by `validateBareShimSecondary`).
    // Instantiate each with `env = env_inst` so the embed's
    // `<sec.name>.<x>` imports — which we already routed through the
    // shim — can resolve to real funcs once fixup runs.
    const secondary_insts = try a.alloc(u32, in.secondaries.len);
    for (secondary_module_idxs, secondary_insts) |mod_idx, *out| {
        const sec_args = try a.alloc(ctypes.CoreInstantiateArg, 1);
        sec_args[0] = .{ .name = "env", .instance_idx = env_inst };
        out.* = try b.addCoreInstance(.{ .instantiate = .{
            .module_idx = mod_idx,
            .args = sec_args,
        } });
    }

    const total_secondary_slots: u32 = blk: {
        var sum: u32 = 0;
        for (in.secondaries) |s| sum += @intCast(s.slots.len);
        break :blk sum;
    };

    // ── Step 8: per-namespace bundles ────────────────────────────────
    var bucket_inst_idx = try a.alloc(u32, in.buckets.len);
    for (in.buckets, 0..) |*bucket, bi| {
        var bundle = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;

        for (bucket.resource_drops) |drop| {
            const t_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .type,
                .instance_idx = bucket.instance_idx,
                .name = drop.resource_name,
            } });
            const cf_idx = try b.addCanon(.{ .resource_drop = t_idx });
            try bundle.append(a, .{
                .name = drop.field_name,
                .sort_idx = .{ .sort = .func, .idx = cf_idx },
            });
        }

        for (bucket.direct_funcs) |df| {
            const f_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .func,
                .instance_idx = bucket.instance_idx,
                .name = df.name,
            } });
            const cf_idx = try b.addCanon(.{ .lower = .{
                .func_idx = f_idx,
                .opts = &.{},
            } });
            try bundle.append(a, .{
                .name = df.name,
                .sort_idx = .{ .sort = .func, .idx = cf_idx },
            });
        }

        for (bucket.indirect_funcs) |idf| {
            const slot_total: u32 = @as(u32, @intCast(in.preview1_slots.len)) + total_secondary_slots + idf.slot_idx;
            const slot_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
            const cf_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = shim_inst,
                .name = slot_name,
            } });
            try bundle.append(a, .{
                .name = idf.name,
                .sort_idx = .{ .sort = .func, .idx = cf_idx },
            });
        }

        bucket_inst_idx[bi] = try b.addCoreInstance(.{ .exports = try bundle.toOwnedSlice(a) });
    }

    // ── Step 9: instantiate adapter ──────────────────────────────────
    var adapter_args = std.ArrayListUnmanaged(ctypes.CoreInstantiateArg).empty;
    try adapter_args.append(a, .{ .name = "env", .instance_idx = env_inst });
    if (main_module_inst) |mmi| {
        try adapter_args.append(a, .{ .name = "__main_module__", .instance_idx = mmi });
    }
    for (in.buckets, 0..) |bk, bi| {
        try adapter_args.append(a, .{ .name = bk.name, .instance_idx = bucket_inst_idx[bi] });
    }
    const adapter_inst = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = adapter_module_idx,
        .args = try adapter_args.toOwnedSlice(a),
    } });

    // ── Step 10: fixup bundle ────────────────────────────────────────
    // Realloc opt sources. Two distinct sources:
    //   * Indirect WASI canon.lowers run from inside the adapter's
    //     code; they encode results into the *adapter*'s memory via
    //     the adapter's `cabi_import_realloc`.
    //   * Embed-extra canon.lowers run from inside main's code; they
    //     encode results into *main*'s memory via main's
    //     `cabi_realloc`. (cataggar/wabt#230)
    var any_realloc = false;
    for (in.buckets) |bk| for (bk.indirect_funcs) |idf| {
        if (idf.cls.opts.realloc) any_realloc = true;
    };

    var realloc_idx: u32 = 0;
    if (any_realloc) {
        if (in.adapter_iface.findExport("cabi_import_realloc") == null) {
            return error.AdapterMissingReallocExport;
        }
        realloc_idx = try b.addAlias(.{ .instance_export = .{
            .sort = .{ .core = .func },
            .instance_idx = adapter_inst,
            .name = "cabi_import_realloc",
        } });
    }

    var any_main_realloc = false;
    for (in.embed_extra_plan.slot_infos) |info| {
        if (info.opts.realloc) any_main_realloc = true;
    }
    var main_realloc_idx: u32 = 0;
    if (any_main_realloc) {
        if (in.embed_iface.findExport("cabi_realloc") == null) {
            return error.EmbedMissingCabiRealloc;
        }
        main_realloc_idx = try b.addAlias(.{ .instance_export = .{
            .sort = .{ .core = .func },
            .instance_idx = main_inst,
            .name = "cabi_realloc",
        } });
    }

    var fixup_inline = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;

    // shim's $imports table.
    const table_idx = try b.addAlias(.{ .instance_export = .{
        .sort = .{ .core = .table },
        .instance_idx = shim_inst,
        .name = "$imports",
    } });
    try fixup_inline.append(a, .{
        .name = "$imports",
        .sort_idx = .{ .sort = .table, .idx = table_idx },
    });

    // Funcs 0..P-1: adapter exports for embed's preview1 imports.
    for (in.preview1_slots, 0..) |p1, i| {
        if (in.adapter_iface.findExport(p1.name) == null) {
            return error.AdapterMissingPreview1Export;
        }
        const f_idx = try b.addAlias(.{ .instance_export = .{
            .sort = .{ .core = .func },
            .instance_idx = adapter_inst,
            .name = p1.name,
        } });
        const slot_name = try std.fmt.allocPrint(a, "{d}", .{i});
        try fixup_inline.append(a, .{
            .name = slot_name,
            .sort_idx = .{ .sort = .func, .idx = f_idx },
        });
    }

    // Funcs P..P+ΣS-1: per-secondary bare exports. Each secondary's
    // `slots` list maps positionally onto its already-instantiated
    // core instance's exports.
    for (in.secondaries, secondary_insts) |sec, sec_inst| {
        for (sec.slots, 0..) |s, j| {
            if (sec.iface.findExport(s.name) == null) {
                return error.AdapterMissingPreview1Export;
            }
            const f_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .{ .core = .func },
                .instance_idx = sec_inst,
                .name = s.name,
            } });
            const slot_total: u32 = sec.slot_offset + @as(u32, @intCast(j));
            const slot_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
            try fixup_inline.append(a, .{
                .name = slot_name,
                .sort_idx = .{ .sort = .func, .idx = f_idx },
            });
        }
    }

    // Funcs P+ΣS..P+ΣS+I-1: canon lower(memory, [realloc],
    // [string-encoding]) of each indirect adapter wasi import.
    {
        var indirect_idx: u32 = 0;
        for (in.buckets) |bk| {
            for (bk.indirect_funcs) |idf| {
                const f_idx = try b.addAlias(.{ .instance_export = .{
                    .sort = .func,
                    .instance_idx = bk.instance_idx,
                    .name = idf.name,
                } });
                const opts = try buildCanonLowerOpts(a, idf.cls.opts, memory_idx, realloc_idx, false);
                const cf_idx = try b.addCanon(.{ .lower = .{
                    .func_idx = f_idx,
                    .opts = opts,
                } });
                const slot_total: u32 = @as(u32, @intCast(in.preview1_slots.len)) + total_secondary_slots + indirect_idx;
                const slot_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
                try fixup_inline.append(a, .{
                    .name = slot_name,
                    .sort_idx = .{ .sort = .func, .idx = cf_idx },
                });
                indirect_idx += 1;
            }
        }
    }

    // Funcs P+ΣS+I..P+ΣS+I+E-1: canon lower(memory, [realloc],
    // [string-encoding]) of each embed-extra non-WASI import.
    // The lowered funcs use main_inst's memory + cabi_realloc so
    // strings/lists they pass back land in the embed's memory.
    // (cataggar/wabt#230 — pre-fix these were lowered with empty
    // opts inside `buildEmbedExtraImports`, which validated only
    // for primitive-only sigs; routing them through the fixup
    // table breaks the forward-reference cycle.)
    for (in.embed_extra_plan.slot_infos, 0..) |info, i| {
        const iface_inst_idx = embed_extra_iface_inst_for_ns.get(info.ns) orelse
            return error.UnsupportedShape;
        const f_idx = try b.addAlias(.{ .instance_export = .{
            .sort = .func,
            .instance_idx = iface_inst_idx,
            .name = info.fn_name,
        } });
        const opts = try buildCanonLowerOpts(a, info.opts, memory_idx, main_realloc_idx, false);
        const cf_idx = try b.addCanon(.{ .lower = .{
            .func_idx = f_idx,
            .opts = opts,
        } });
        const slot_total: u32 = in.embed_extra_slot_base + @as(u32, @intCast(i));
        const slot_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
        try fixup_inline.append(a, .{
            .name = slot_name,
            .sort_idx = .{ .sort = .func, .idx = cf_idx },
        });
    }

    const fixup_bundle_inst = try b.addCoreInstance(.{ .exports = try fixup_inline.toOwnedSlice(a) });

    // Instantiate fixup with bundle as `""` namespace.
    const fixup_args = try a.alloc(ctypes.CoreInstantiateArg, 1);
    fixup_args[0] = .{ .name = "", .instance_idx = fixup_bundle_inst };
    _ = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = fixup_module_idx,
        .args = fixup_args,
    } });

    // ── Step 11: top-level lift + export ─────────────────────────────
    //
    // Command shape: canon-lift the adapter's `wasi:cli/run@<ver>#run`
    // export, wrap it in an inline sub-component re-exporting it as
    // `run`, and emit a single top-level `(export "wasi:cli/run@…"
    // instance N)`.
    //
    // Reactor shape: lift each `<iface>#<func>` export the embed
    // declares from the embed core instance, bundle per-interface
    // into a component instance, emit one `(export "<iface>"
    // instance N)` per interface.
    if (in.shape == .command) {
        const run_ie = try findRunInstanceExport(in.hoisted, a);
        if (in.adapter_iface.findExport(run_ie.core_export_name) == null) {
            return error.AdapterMissingRunExport;
        }
        const run_core_func_idx = try b.addAlias(.{ .instance_export = .{
            .sort = .{ .core = .func },
            .instance_idx = adapter_inst,
            .name = run_ie.core_export_name,
        } });
        const lifted_run_func_idx = try b.addCanon(.{ .lift = .{
            .core_func_idx = run_core_func_idx,
            .type_idx = run_func_type_idx,
            .opts = &.{},
        } });

        const sub = try buildRunSubComponent(a);
        const sub_idx = try b.addNestedComponent(sub);

        const sub_args = try a.alloc(ctypes.InstantiateArg, 1);
        sub_args[0] = .{
            .name = "import-func-run",
            .sort_idx = .{ .sort = .func, .idx = lifted_run_func_idx },
        };
        const wrap_inst_idx = try b.addInstance(.{ .instantiate = .{
            .component_idx = sub_idx,
            .args = sub_args,
        } });

        try b.addExport(.{
            .name = run_ie.qualified_name,
            .desc = .{ .instance = run_ie.body_type_idx },
            .sort_idx = .{ .sort = .instance, .idx = wrap_inst_idx },
        });
    } else {
        // Reactor needs the embed's `component-type:*` custom section
        // for the export interface signatures — without it we can't
        // produce a typed top-level export. The section is stripped
        // from `in.embed_bytes` before assemble runs, so callers
        // pre-decode and supply via `in.embed_metadata`.
        const decoded = in.embed_metadata orelse return error.MissingEmbedMetadata;

        // Ensure there's at least one export — a reactor with no
        // exports is degenerate (would produce a wrapping component
        // with no top-level export, equivalent to a library shape
        // tracked in #127).
        var any_export = false;
        for (decoded.externs) |ext| if (ext.is_export) {
            any_export = true;
            break;
        };
        if (!any_export) return error.UnsupportedAdapterShape;

        for (decoded.externs) |ext| {
            if (!ext.is_export) continue;

            // Per-func: alias `<iface>#<func>` from the embed core
            // instance, build the component func type, canon-lift,
            // append to the per-interface inline-export bundle.
            var inline_exports = std.ArrayListUnmanaged(ctypes.InlineExport).empty;
            for (ext.funcs) |fn_ref| {
                const core_export_name = try std.fmt.allocPrint(a, "{s}#{s}", .{ ext.qualified_name, fn_ref.name });
                if (in.embed_iface.findExport(core_export_name) == null) {
                    return error.EmbedMissingRequiredExport;
                }
                const core_func_idx = try b.addAlias(.{ .instance_export = .{
                    .sort = .{ .core = .func },
                    .instance_idx = main_inst,
                    .name = core_export_name,
                } });
                const rewritten_sig = try lift_types.transcribeFuncSig(
                    a,
                    ReactorLiftCtx{ .b = &b },
                    ext.type_slots,
                    fn_ref.sig,
                );
                const ftype_idx = try b.addType(.{ .func = rewritten_sig });
                const lifted_idx = try b.addCanon(.{ .lift = .{
                    .core_func_idx = core_func_idx,
                    .type_idx = ftype_idx,
                    .opts = &.{},
                } });
                try inline_exports.append(a, .{
                    .name = fn_ref.name,
                    .sort_idx = .{ .sort = .func, .idx = lifted_idx },
                });
            }
            const iface_inst_idx = try b.addInstance(.{ .exports = try inline_exports.toOwnedSlice(a) });

            // The wrapping component's `(export …)` is emitted in
            // un-ascribed form (`desc = .instance = 0`) so the
            // loader re-derives the instance type from the
            // sort_idx-pointed instance — matches the
            // `component_new.zig::buildComponent` (no-adapter) path
            // and round-trips through `loader.load`. A proper
            // instance-type ascription falls out of #127's
            // world-merge work.
            try b.addExport(.{
                .name = ext.qualified_name,
                .desc = .{ .instance = 0 },
                .sort_idx = .{ .sort = .instance, .idx = iface_inst_idx },
            });
        }
    }

    // ── Encode ───────────────────────────────────────────────────────
    const comp = ctypes.Component{
        .core_modules = try b.core_modules.toOwnedSlice(a),
        .core_instances = try b.core_instances.toOwnedSlice(a),
        .core_types = &.{},
        .components = try b.components.toOwnedSlice(a),
        .instances = try b.instances.toOwnedSlice(a),
        .aliases = try b.aliases.toOwnedSlice(a),
        .types = try b.types.toOwnedSlice(a),
        .canons = try b.canons.toOwnedSlice(a),
        .imports = try b.imports.toOwnedSlice(a),
        .exports = try b.exports.toOwnedSlice(a),
        .section_order = try b.section_order.toOwnedSlice(a),
    };

    return writer.encode(in.gpa, &comp);
}

/// Build the `CanonOpt[]` slice for a `canon.lower` derived from the
/// canonical-ABI classification of an imported func. Both the
/// adapter splicer and the plain-wrap path (`component new`) need
/// this — `memory` + `cabi_realloc` come from the main core
/// instance regardless of whether the splicer is involved.
pub fn buildCanonLowerOpts(
    arena: Allocator,
    o: abi.FuncOpts,
    memory_core_idx: u32,
    realloc_core_idx: u32,
    is_async: bool,
) error{OutOfMemory}![]const ctypes.CanonOpt {
    var n: usize = 0;
    if (o.memory) n += 1;
    if (o.realloc) n += 1;
    if (o.string_encoding) n += 1;
    if (is_async) n += 1;

    const opts = try arena.alloc(ctypes.CanonOpt, n);
    var i: usize = 0;
    if (o.memory) {
        opts[i] = .{ .memory = memory_core_idx };
        i += 1;
    }
    if (o.realloc) {
        opts[i] = .{ .realloc = realloc_core_idx };
        i += 1;
    }
    if (o.string_encoding) {
        opts[i] = .{ .string_encoding = .utf8 };
        i += 1;
    }
    if (is_async) {
        opts[i] = .async_;
        i += 1;
    }
    return opts;
}

/// Build the `canon lift` option list for an exported func. Mirrors
/// `buildCanonLowerOpts` but uses `abi.LiftOpts` and adds an optional
/// `(post-return <cabi_post_…>)`. Emission order matches
/// `wit-component`: memory, realloc, string-encoding, post-return.
pub fn buildCanonLiftOpts(
    arena: Allocator,
    o: abi.LiftOpts,
    memory_core_idx: u32,
    realloc_core_idx: u32,
    post_return_core_idx: ?u32,
) error{OutOfMemory}![]const ctypes.CanonOpt {
    var n: usize = 0;
    if (o.memory) n += 1;
    if (o.realloc) n += 1;
    if (o.string_encoding) n += 1;
    if (post_return_core_idx != null) n += 1;

    const opts = try arena.alloc(ctypes.CanonOpt, n);
    var i: usize = 0;
    if (o.memory) {
        opts[i] = .{ .memory = memory_core_idx };
        i += 1;
    }
    if (o.realloc) {
        opts[i] = .{ .realloc = realloc_core_idx };
        i += 1;
    }
    if (o.string_encoding) {
        opts[i] = .{ .string_encoding = .utf8 };
        i += 1;
    }
    if (post_return_core_idx) |p| {
        opts[i] = .{ .post_return = p };
        i += 1;
    }
    return opts;
}

const RunInstanceExport = struct {
    qualified_name: []const u8,
    core_export_name: []const u8,
    body_type_idx: u32,
};

fn findRunInstanceExport(h: types_import.Hoisted, arena: Allocator) SpliceError!RunInstanceExport {
    for (h.exports) |e| {
        if (std.mem.startsWith(u8, e.name, "wasi:cli/run")) {
            return .{
                .qualified_name = e.name,
                .core_export_name = try std.fmt.allocPrint(arena, "{s}#run", .{e.name}),
                .body_type_idx = e.type_idx,
            };
        }
    }
    return error.AdapterMissingRunExport;
}

// ── Sub-component construction ────────────────────────────────────────────

/// Build the inline sub-component that wraps a single imported func
/// and re-exports it as `run`. Mirrors wit-component's layout:
///
///   (component
///     (type (;0;) (result))
///     (type (;1;) (func (result 0)))
///     (import "import-func-run" (func (;0;) (type (eq 1))))
///     (export (;1;) "run" (func 0)))
fn buildRunSubComponent(arena: Allocator) SpliceError!*ctypes.Component {
    const types_arr = try arena.alloc(ctypes.TypeDef, 2);
    types_arr[0] = .{ .result = .{ .ok = null, .err = null } };
    types_arr[1] = .{ .func = .{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 0 } },
    } };

    const imports = try arena.alloc(ctypes.ImportDecl, 1);
    imports[0] = .{ .name = "import-func-run", .desc = .{ .func = 1 } };

    const exports = try arena.alloc(ctypes.ExportDecl, 1);
    exports[0] = .{
        .name = "run",
        .desc = .{ .func = 1 },
        .sort_idx = .{ .sort = .func, .idx = 0 },
    };

    const c = try arena.create(ctypes.Component);
    c.* = .{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = types_arr,
        .canons = &.{},
        .imports = imports,
        .exports = exports,
    };
    return c;
}

// ── Embed extra (non-WASI) imports ────────────────────────────────────────

const EmbedExtraArg = struct {
    /// Module name as the embed declared it (becomes the `<with>`
    /// name on the embed's instantiation).
    name: []const u8,
    /// Core instance idx of the inline-export bundle satisfying it.
    inst_idx: u32,
};

/// Per-func metadata for an embed-extra namespace import.
///
/// Precomputed in `splice()` / `spliceN()` so the slot order is
/// stable across (a) the shim trampoline table built in Phase B,
/// (b) `buildEmbedExtraImports`'s shim-trampoline alias loop, and
/// (c) the fixup phase's `canon.lower` loop. The `i`th entry in
/// `embed_extra_slot_infos` corresponds to shim slot
/// `embed_extra_slot_base + i`.
///
/// Each slot ultimately carries one `canon.lower(func, opts)` that
/// the fixup module writes into the shim's `$imports` table at that
/// slot's offset (mirror of the WASI-indirect canon.lower routing
/// in Step 10 of `assemble`). Routing embed-extras through the
/// fixup table lets us emit the lower AFTER `main_inst`'s memory +
/// `cabi_realloc` are aliased — required for any embed-extra func
/// whose sig reaches `string`/`list`/records (cataggar/wabt#230).
pub const EmbedExtraSlotInfo = struct {
    ns: []const u8,
    fn_name: []const u8,
    /// FuncType the embed declared in its `component-type:<world>`
    /// (or synthesized from the core wasm sig as a fallback).
    func_type: ctypes.FuncType,
    /// Classification opts derived from `func_type`.
    opts: abi.FuncOpts,
    /// Iface body decls (for the abi.TypeResolver — empty when the
    /// embed lacks a component-type section).
    inst_decls: []const ctypes.Decl,
    /// The embed's encoded world body decls — the outer scope the
    /// `abi.TypeResolver` walks to resolve cross-iface `(alias outer
    /// 1 K)` references (e.g. `wasi:http/outgoing-handler.handle`
    /// reaching `error-code` in `wasi:http/types`). Without it the
    /// resolver falls back to scalar-handle and drops required
    /// canon-lower opts like `realloc` (cataggar/wabt#234).
    world_decls: []const ctypes.Decl,
};

const EmbedExtraIntrinsic = struct {
    field_name: []const u8,
    resource_name: []const u8,
};

const EmbedExtraFieldPlan = union(enum) {
    /// Index in `EmbedExtraImportPlan.slot_infos`.
    ordinary_slot: u32,
    intrinsic: EmbedExtraIntrinsic,
};

const EmbedExtraNamespacePlan = struct {
    name: []const u8,
    /// Present when an encoded WIT world authoritatively declares this
    /// import. Null is reserved for metadata-free legacy core modules.
    metadata_ext: ?metadata_decode.WorldExtern = null,
    /// Core fields in first-declaration order. Exact duplicates with
    /// the same validated contract are represented only once.
    fields: []const EmbedExtraFieldPlan = &.{},
};

const EmbedExtraImportPlan = struct {
    namespaces: []const EmbedExtraNamespacePlan = &.{},
    /// Ordinary funcs only. Resource intrinsics deliberately have no
    /// shim slot and therefore cannot be canon.lower'd in Step 10.
    slot_infos: []const EmbedExtraSlotInfo = &.{},
};

fn decodeEmbedMetadata(
    arena: Allocator,
    embed_bytes: []const u8,
) SpliceError!?metadata_decode.DecodedWorld {
    const payload = decode.extractEncodedWorld(embed_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEmbedMetadata,
    };
    const bytes = payload orelse return null;
    return metadata_decode.decode(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidEmbedMetadata,
    };
}

fn isEmbedExtraModule(
    name: []const u8,
    adapter_name: []const u8,
    secondary_names: []const []const u8,
) bool {
    if (std.mem.eql(u8, name, adapter_name) or
        std.mem.eql(u8, name, "env") or
        std.mem.eql(u8, name, "__main_module__"))
    {
        return false;
    }
    for (secondary_names) |secondary| {
        if (std.mem.eql(u8, name, secondary)) return false;
    }
    return true;
}

fn namespaceWithoutVersion(name: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, name, '@') orelse return name;
    return name[0..at];
}

fn sameNamespaceIgnoringVersion(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, namespaceWithoutVersion(a), namespaceWithoutVersion(b));
}

fn metadataFuncType(
    ext: metadata_decode.WorldExtern,
    name: []const u8,
) SpliceError!ctypes.FuncType {
    var found: ?ctypes.FuncType = null;
    for (ext.funcs) |func| {
        if (!std.mem.eql(u8, func.name, name)) continue;
        if (found != null) return error.EmbedMetadataFunctionMalformed;
        found = func.sig;
    }
    const ft = found orelse return error.EmbedMetadataFunctionNotFound;

    // `DecodedWorld.funcs` is derived from these raw exports. Check
    // that the identity-bearing body still has exactly one matching
    // func export rather than trusting a malformed/ambiguous alias.
    var export_count: usize = 0;
    for (ext.inst_decls) |decl| switch (decl) {
        .@"export" => |e| {
            if (e.desc == .func and std.mem.eql(u8, e.name, name))
                export_count += 1;
        },
        else => {},
    };
    if (export_count != 1) return error.EmbedMetadataFunctionMalformed;
    return ft;
}

fn metadataHasFunc(ext: metadata_decode.WorldExtern, name: []const u8) bool {
    for (ext.funcs) |func| {
        if (std.mem.eql(u8, func.name, name)) return true;
    }
    return false;
}

fn metadataHasTypeExport(ext: metadata_decode.WorldExtern, name: []const u8) bool {
    var count: usize = 0;
    for (ext.inst_decls) |decl| switch (decl) {
        .@"export" => |e| {
            if (e.desc == .type and std.mem.eql(u8, e.name, name))
                count += 1;
        },
        else => {},
    };
    return count == 1;
}

fn metadataHasDeclaredResource(
    ext: metadata_decode.WorldExtern,
    name: []const u8,
) SpliceError!bool {
    var count: usize = 0;
    for (ext.inst_decls) |decl| switch (decl) {
        .@"export" => |e| {
            if (e.desc == .type and e.desc.type == .sub_resource and
                std.mem.eql(u8, e.name, name))
            {
                count += 1;
            }
        },
        else => {},
    };
    if (count > 1) return error.EmbedImportFieldConflict;
    return count == 1;
}

fn synthesizePrimitiveFuncType(
    arena: Allocator,
    sig: core_imports.FuncSig,
) SpliceError!ctypes.FuncType {
    const params = try arena.alloc(ctypes.NamedValType, sig.params.len);
    for (sig.params, 0..) |param, i| {
        params[i] = .{
            .name = try std.fmt.allocPrint(arena, "p{d}", .{i}),
            .type = coreToCompValType(param) orelse
                return error.EmbedImportSignatureMismatch,
        };
    }
    const results: ctypes.FuncType.ResultList = if (sig.results.len == 0)
        .none
    else if (sig.results.len == 1)
        .{ .unnamed = coreToCompValType(sig.results[0]) orelse
            return error.EmbedImportSignatureMismatch }
    else blk: {
        const named = try arena.alloc(ctypes.NamedValType, sig.results.len);
        for (sig.results, 0..) |result, i| {
            named[i] = .{
                .name = try std.fmt.allocPrint(arena, "r{d}", .{i}),
                .type = coreToCompValType(result) orelse
                    return error.EmbedImportSignatureMismatch,
            };
        }
        break :blk .{ .named = named };
    };
    return .{ .params = params, .results = results };
}

fn coreSigMatches(
    declared: core_imports.FuncSig,
    params: []const wtypes.ValType,
    results: []const wtypes.ValType,
) bool {
    return std.mem.eql(wtypes.ValType, declared.params, params) and
        std.mem.eql(wtypes.ValType, declared.results, results);
}

const MetadataDependencyState = enum { ready, blocked };

const MetadataAliasTarget = struct {
    world_inst_idx: u32,
    name: []const u8,
};

fn metadataAliasTarget(
    tables: WorldTypeTables,
    alias: ctypes.Alias,
) SpliceError!MetadataAliasTarget {
    return switch (alias) {
        .outer => |outer| blk: {
            if (outer.sort != .type or outer.outer_count != 1 or
                outer.idx >= tables.type_kind.len)
            {
                return error.EmbedMetadataAliasMalformed;
            }
            break :blk switch (tables.type_kind[outer.idx]) {
                .alias_instance_export => |target| .{
                    .world_inst_idx = target.world_inst_idx,
                    .name = target.name,
                },
                .other => return error.EmbedMetadataAliasMalformed,
            };
        },
        // Metadata encoders also use this compact body-side form to
        // refer directly to an instance in the outer world scope.
        .instance_export => |ie| {
            if (ie.sort != .type) return error.EmbedMetadataAliasMalformed;
            return .{ .world_inst_idx = ie.instance_idx, .name = ie.name };
        },
    };
}

fn metadataDependenciesReady(
    md: metadata_decode.DecodedWorld,
    tables: WorldTypeTables,
    ext: metadata_decode.WorldExtern,
    import_index: *const std.StringHashMapUnmanaged(usize),
    emitted: []const bool,
    hoisted: types_import.Hoisted,
) SpliceError!MetadataDependencyState {
    for (ext.inst_decls) |decl| {
        const target = switch (decl) {
            .alias => |alias| try metadataAliasTarget(tables, alias),
            else => continue,
        };
        if (target.world_inst_idx >= tables.inst_qname.len)
            return error.EmbedMetadataAliasMalformed;
        const provider_name = tables.inst_qname[target.world_inst_idx];
        const provider_idx = import_index.get(provider_name) orelse
            return error.EmbedMetadataAliasMalformed;
        const provider = md.externs[provider_idx];
        if (provider.is_export or !metadataHasTypeExport(provider, target.name))
            return error.EmbedMetadataAliasMalformed;
        if (findInstanceSlot(hoisted, provider_name) == null and
            !emitted[provider_idx])
        {
            return .blocked;
        }
    }
    return .ready;
}

fn orderMetadataImports(
    arena: Allocator,
    md: metadata_decode.DecodedWorld,
    hoisted: types_import.Hoisted,
) SpliceError![]const metadata_decode.WorldExtern {
    // Map qualified import names to their DecodedWorld index. Exact
    // names (including versions) are the identity key throughout.
    var import_index = std.StringHashMapUnmanaged(usize).empty;
    defer import_index.deinit(arena);
    var import_count: usize = 0;
    for (md.externs, 0..) |ext, i| {
        if (ext.is_export) continue;
        const gop = try import_index.getOrPut(arena, ext.qualified_name);
        if (gop.found_existing) return error.EmbedImportFieldConflict;
        gop.value_ptr.* = i;
        import_count += 1;
    }

    const tables = try buildWorldTypeTables(arena, md.world_decls);
    const emitted = try arena.alloc(bool, md.externs.len);
    @memset(emitted, false);
    var ordered = std.ArrayListUnmanaged(metadata_decode.WorldExtern).empty;
    try ordered.ensureTotalCapacity(arena, import_count);

    while (ordered.items.len < import_count) {
        var made_progress = false;
        for (md.externs, 0..) |ext, i| {
            if (ext.is_export or emitted[i]) continue;
            if (try metadataDependenciesReady(
                md,
                tables,
                ext,
                &import_index,
                emitted,
                hoisted,
            ) == .blocked) continue;
            emitted[i] = true;
            ordered.appendAssumeCapacity(ext);
            made_progress = true;
        }
        if (!made_progress) return error.EmbedMetadataAliasCycle;
    }
    return ordered.toOwnedSlice(arena);
}

/// Build one arena-owned plan shared by shim-slot collection and
/// component assembly. With metadata, every WIT import body is kept
/// intact and ordered after its cross-interface type providers.
/// Without metadata, only ordinary primitive funcs use the legacy
/// synthesis fallback; resource intrinsics are a hard error.
fn buildEmbedExtraImportPlan(
    arena: Allocator,
    embed_iface: core_imports.CoreInterface,
    embed_metadata: ?metadata_decode.DecodedWorld,
    adapter_name: []const u8,
    secondary_names: []const []const u8,
    hoisted: types_import.Hoisted,
) SpliceError!EmbedExtraImportPlan {
    var core_names = std.ArrayListUnmanaged([]const u8).empty;
    var core_name_seen = std.StringHashMapUnmanaged(void).empty;
    defer core_name_seen.deinit(arena);

    for (embed_iface.imports) |im| {
        if (im.kind != .func) continue;
        if (!isEmbedExtraModule(im.module_name, adapter_name, secondary_names)) continue;
        const gop = try core_name_seen.getOrPut(arena, im.module_name);
        if (!gop.found_existing) try core_names.append(arena, im.module_name);
    }

    const NamespaceSeed = struct {
        name: []const u8,
        ext: ?metadata_decode.WorldExtern,
    };
    var seeds = std.ArrayListUnmanaged(NamespaceSeed).empty;

    if (embed_metadata) |md| {
        const ordered = try orderMetadataImports(arena, md, hoisted);
        for (core_names.items) |core_name| {
            var exact = false;
            var version_mismatch = false;
            for (ordered) |ext| {
                if (std.mem.eql(u8, ext.qualified_name, core_name)) {
                    exact = true;
                    break;
                }
                if (sameNamespaceIgnoringVersion(ext.qualified_name, core_name))
                    version_mismatch = true;
            }
            if (!exact) {
                if (version_mismatch) return error.EmbedMetadataVersionMismatch;
                return error.EmbedMetadataNamespaceNotFound;
            }
        }
        for (ordered) |ext| {
            try seeds.append(arena, .{ .name = ext.qualified_name, .ext = ext });
        }
    } else {
        for (core_names.items) |name| {
            try seeds.append(arena, .{ .name = name, .ext = null });
        }
    }

    var slot_infos = std.ArrayListUnmanaged(EmbedExtraSlotInfo).empty;
    const namespaces = try arena.alloc(EmbedExtraNamespacePlan, seeds.items.len);
    for (seeds.items, namespaces) |seed, *namespace| {
        var fields = std.ArrayListUnmanaged(EmbedExtraFieldPlan).empty;
        var field_seen = std.StringHashMapUnmanaged(void).empty;
        defer field_seen.deinit(arena);

        for (embed_iface.imports) |im| {
            if (im.kind != .func) continue;
            if (!isEmbedExtraModule(im.module_name, adapter_name, secondary_names)) continue;
            if (!std.mem.eql(u8, im.module_name, seed.name)) continue;
            const declared = im.sig orelse return error.EmbedImportSignatureMismatch;

            if (resource_intrinsics.classify(im.field_name)) |intrinsic| {
                intrinsic.kind.validateCoreSignature(declared.params, declared.results) catch
                    return error.EmbedResourceIntrinsicSignatureMismatch;
                switch (intrinsic.kind) {
                    .drop => {},
                    .new => return error.EmbedImportedResourceNewUnsupported,
                    .rep => return error.EmbedImportedResourceRepUnsupported,
                }
                const ext = seed.ext orelse return error.EmbedResourceMetadataRequired;
                if (intrinsic.resource.len == 0 or
                    !(try metadataHasDeclaredResource(ext, intrinsic.resource)))
                {
                    return error.EmbedMetadataResourceNotFound;
                }
                if (metadataHasFunc(ext, im.field_name))
                    return error.EmbedImportFieldConflict;

                const gop = try field_seen.getOrPut(arena, im.field_name);
                if (gop.found_existing) continue;
                try fields.append(arena, .{ .intrinsic = .{
                    .field_name = im.field_name,
                    .resource_name = intrinsic.resource,
                } });
                continue;
            }

            const canonical_decls: []const ctypes.Decl = if (seed.ext) |ext|
                ext.inst_decls
            else
                &.{};
            const world_decls: []const ctypes.Decl = if (embed_metadata) |md|
                md.world_decls
            else
                &.{};
            const ft = if (seed.ext) |ext|
                try metadataFuncType(ext, im.field_name)
            else
                try synthesizePrimitiveFuncType(arena, declared);
            const resolver = abi.TypeResolver{
                .inst_decls = canonical_decls,
                .world_decls = world_decls,
            };
            const ftr = abi.FuncTypeRef{ .func = ft, .resolver = resolver };
            const lowered = abi.lowerCoreSig(arena, ftr) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return if (seed.ext != null)
                    error.EmbedMetadataFunctionMalformed
                else
                    error.EmbedImportSignatureMismatch,
            };
            if (!coreSigMatches(declared, lowered.params, lowered.results))
                return error.EmbedImportSignatureMismatch;

            const gop = try field_seen.getOrPut(arena, im.field_name);
            if (gop.found_existing) continue;

            const cls = abi.classifyFunc(ftr);
            const slot_idx: u32 = @intCast(slot_infos.items.len);
            try slot_infos.append(arena, .{
                .ns = seed.name,
                .fn_name = im.field_name,
                .func_type = ft,
                .opts = cls.opts,
                .inst_decls = canonical_decls,
                .world_decls = world_decls,
            });
            try fields.append(arena, .{ .ordinary_slot = slot_idx });
        }

        namespace.* = .{
            .name = seed.name,
            .metadata_ext = seed.ext,
            .fields = try fields.toOwnedSlice(arena),
        };
    }
    return .{
        .namespaces = namespaces,
        .slot_infos = try slot_infos.toOwnedSlice(arena),
    };
}

/// Materialize the shared import plan. Metadata-backed bodies are
/// transplanted whole (after strict cross-interface alias rebasing);
/// legacy metadata-free bodies are synthesized from primitive sigs.
/// Ordinary funcs use shim slots, while resource drops directly
/// contribute canon resource.drop operations to the satisfying core bundle.
fn buildEmbedExtraImports(
    b: *Builder,
    a: Allocator,
    in: Inputs,
    shim_inst: u32,
    iface_inst_idx_for_ns: *std.StringHashMapUnmanaged(u32),
) SpliceError![]const EmbedExtraArg {
    var out = std.ArrayListUnmanaged(EmbedExtraArg).empty;

    for (in.embed_extra_plan.namespaces) |namespace| {
        const imp_inst_idx: u32 = if (findInstanceSlot(in.hoisted, namespace.name)) |slot|
            slot.instance_idx
        else blk: {
            var inst_decls = std.ArrayListUnmanaged(ctypes.Decl).empty;
            if (namespace.metadata_ext) |ext| {
                const rebased = try rebaseCanonicalInstBody(
                    b,
                    a,
                    in,
                    ext.inst_decls,
                    iface_inst_idx_for_ns,
                );
                // The full metadata body is retained. Identity cloning
                // preserves every local declaration/type relationship.
                const decls = rebased;
                const slot_count = countInstBodyTypeSlots(decls);
                const identity_remap = try a.alloc(u32, @max(slot_count, 1));
                for (identity_remap, 0..) |*x, i| x.* = @intCast(i);
                for (decls) |d| {
                    try inst_decls.append(a, try type_walk.cloneDecl(a, d, identity_remap, &.{}));
                }
            } else {
                // Compatibility path for metadata-free primitive
                // imports. Intrinsics were rejected while planning.
                var local_type_idx: u32 = 0;
                for (namespace.fields) |field| {
                    const slot_idx = switch (field) {
                        .ordinary_slot => |idx| idx,
                        .intrinsic => unreachable,
                    };
                    const info = in.embed_extra_plan.slot_infos[slot_idx];
                    try inst_decls.append(a, .{ .type = .{ .func = info.func_type } });
                    const ftype_idx = local_type_idx;
                    local_type_idx += 1;
                    try inst_decls.append(a, .{ .@"export" = .{
                        .name = info.fn_name,
                        .desc = .{ .func = ftype_idx },
                    } });
                }
            }

            const inst_type_idx = try b.addType(.{ .instance = .{
                .decls = try inst_decls.toOwnedSlice(a),
            } });
            break :blk try b.addImport(.{
                .name = namespace.name,
                .desc = .{ .instance = inst_type_idx },
            });
        };
        try iface_inst_idx_for_ns.put(a, namespace.name, imp_inst_idx);

        // Metadata-only type providers need a component import but no
        // core `(with …)` argument.
        if (namespace.fields.len == 0) continue;

        var inline_exps = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;
        var resource_type_for_name = std.StringHashMapUnmanaged(u32).empty;
        defer resource_type_for_name.deinit(a);
        for (namespace.fields) |field| switch (field) {
            .ordinary_slot => |slot_idx| {
                const info = in.embed_extra_plan.slot_infos[slot_idx];
                const slot_total = in.embed_extra_slot_base + slot_idx;
                const slot_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
                const f_idx = try b.addAlias(.{ .instance_export = .{
                    .sort = .{ .core = .func },
                    .instance_idx = shim_inst,
                    .name = slot_name,
                } });
                try inline_exps.append(a, .{
                    .name = info.fn_name,
                    .sort_idx = .{ .sort = .func, .idx = f_idx },
                });
            },
            .intrinsic => |intrinsic| {
                const gop = try resource_type_for_name.getOrPut(a, intrinsic.resource_name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try b.addAlias(.{ .instance_export = .{
                        .sort = .type,
                        .instance_idx = imp_inst_idx,
                        .name = intrinsic.resource_name,
                    } });
                }
                const canon_idx = try b.addCanon(.{ .resource_drop = gop.value_ptr.* });
                try inline_exps.append(a, .{
                    .name = intrinsic.field_name,
                    .sort_idx = .{ .sort = .func, .idx = canon_idx },
                });
            },
        };

        const bundle_inst = try b.addCoreInstance(.{ .exports = try inline_exps.toOwnedSlice(a) });
        try out.append(a, .{ .name = namespace.name, .inst_idx = bundle_inst });
    }

    return out.toOwnedSlice(a);
}

fn coreToCompValType(v: wtypes.ValType) ?ctypes.ValType {
    return switch (v) {
        .i32 => .u32,
        .i64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
        else => null,
    };
}

/// Classification of a type-allocating world-body slot, used to
/// rebase cross-iface `(alias outer 1 K)` references inside
/// embed-extra instance bodies.
const WorldTypeKind = union(enum) {
    /// Slot K is an `alias instance-export sort=type inst=I name=N`
    /// — type `N` exported by world-import instance `I`.
    alias_instance_export: struct { world_inst_idx: u32, name: []const u8 },
    other,
};

/// World-body resolution tables derived from the embed metadata's
/// encoded world body: `inst_qname[I]` is the namespace of the
/// world-body instance import/export at instance index `I`;
/// `type_kind[K]` classifies the K-th type-allocating world-body slot.
const WorldTypeTables = struct {
    inst_qname: []const []const u8,
    type_kind: []const WorldTypeKind,
};

fn buildWorldTypeTables(
    a: Allocator,
    world_decls: []const ctypes.Decl,
) SpliceError!WorldTypeTables {
    var inst_qname = std.ArrayListUnmanaged([]const u8).empty;
    var type_kind = std.ArrayListUnmanaged(WorldTypeKind).empty;
    for (world_decls) |d| switch (d) {
        .type => try type_kind.append(a, .other),
        .core_type => {},
        .alias => |al| switch (al) {
            .instance_export => |ie| if (ie.sort == .type) try type_kind.append(a, .{
                .alias_instance_export = .{ .world_inst_idx = ie.instance_idx, .name = ie.name },
            }),
            .outer => |o| if (o.sort == .type) try type_kind.append(a, .other),
        },
        .import => |im| switch (im.desc) {
            .instance => try inst_qname.append(a, im.name),
            .type => try type_kind.append(a, .other),
            else => {},
        },
        .@"export" => |e| switch (e.desc) {
            .instance => try inst_qname.append(a, e.name),
            .type => try type_kind.append(a, .other),
            else => {},
        },
    };
    return .{
        .inst_qname = try inst_qname.toOwnedSlice(a),
        .type_kind = try type_kind.toOwnedSlice(a),
    };
}

/// Rebase the cross-iface `(alias outer 1 K)` decls in an embed-extra
/// instance-type body onto the wrapping component's matching imported
/// instances, returning a new body that is valid to emit as a
/// top-level instance type. Each such alias references a type slot K
/// in the embed metadata's world body that resolves to an
/// `alias instance-export sort=type inst=I name=N` — i.e. type `N`
/// exported by world-import instance `I`. We find the wrapping
/// component's instance for `I`'s namespace (adapter-hoisted or
/// embed-extra), emit a fresh top-level
/// `alias instance-export sort=type instance=<idx> name=N` via `b`,
/// and rewrite the body's `(alias outer 1 K)` to
/// `(alias outer 1 <new-top-level-type-slot>)`. Mirrors
/// `component_new.rebaseInstDecls`.
///
/// Metadata is authoritative on this path: every malformed or
/// unresolved alias is an explicit splice failure, never a signal to
/// synthesize primitive types.
fn rebaseCanonicalInstBody(
    b: *Builder,
    a: Allocator,
    in: Inputs,
    body: []const ctypes.Decl,
    iface_inst_idx_for_ns: *std.StringHashMapUnmanaged(u32),
) SpliceError![]const ctypes.Decl {
    const md = in.embed_metadata orelse return error.InvalidEmbedMetadata;
    const tables = try buildWorldTypeTables(a, md.world_decls);

    const out = try a.alloc(ctypes.Decl, body.len);
    for (body, 0..) |d, i| {
        switch (d) {
            .alias => |alias| {
                const target = try metadataAliasTarget(tables, alias);
                if (target.world_inst_idx >= tables.inst_qname.len)
                    return error.EmbedMetadataAliasMalformed;
                const src_ns = tables.inst_qname[target.world_inst_idx];
                var provider: ?metadata_decode.WorldExtern = null;
                for (md.externs) |ext| {
                    if (ext.is_export or
                        !std.mem.eql(u8, ext.qualified_name, src_ns)) continue;
                    if (provider != null)
                        return error.EmbedMetadataAliasMalformed;
                    provider = ext;
                }
                if (provider == null or
                    !metadataHasTypeExport(provider.?, target.name))
                {
                    return error.EmbedMetadataAliasMalformed;
                }
                const inst_idx: u32 = if (findInstanceSlot(in.hoisted, src_ns)) |slot|
                    slot.instance_idx
                else if (iface_inst_idx_for_ns.get(src_ns)) |idx|
                    idx
                else
                    return error.EmbedMetadataAliasMalformed;
                const new_slot = try b.addAlias(.{ .instance_export = .{
                    .sort = .type,
                    .instance_idx = inst_idx,
                    .name = target.name,
                } });
                out[i] = .{ .alias = .{ .outer = .{
                    .sort = .type,
                    .outer_count = 1,
                    .idx = new_slot,
                } } };
            },
            else => out[i] = d,
        }
    }
    return out;
}

/// Count the local-type-slot allocations in an instance-body decl
/// list. Mirrors `world_gc.allocatesWorldBodyTypeSlot` semantics
/// at depth 1: every `.type` decl and every type-sort `.alias`
/// (whether `instance_export` or `outer`) bumps the local component
/// type indexspace by one. Core types occupy a separate indexspace. Used to size the
/// identity remap passed to `type_walk.cloneDecl` in
/// `buildEmbedExtraImports`.
fn countInstBodyTypeSlots(decls: []const ctypes.Decl) u32 {
    var n: u32 = 0;
    for (decls) |d| switch (d) {
        .type => n += 1,
        .core_type => {},
        .alias => |a| {
            const sort: ctypes.Sort = switch (a) {
                .instance_export => |ie| ie.sort,
                .outer => |o| o.sort,
            };
            if (sort == .type) n += 1;
        },
        .import => |im| if (im.desc == .type) {
            n += 1;
        },
        .@"export" => |e| if (e.desc == .type) {
            n += 1;
        },
    };
    return n;
}

/// Synthesize a tiny core module that exports trapping versions of
/// every `__main_module__.<name>` import the adapter requires that
/// the embed doesn't already export.
///
/// For embeds that don't export `cabi_realloc` (very common — Zig
/// and Rust wasip1 builds usually don't), the adapter still imports
/// it as a code dependency. We materialise a trap stub: when the
/// adapter actually invokes it (which only happens when call args
/// or results need realloc'd buffers, neither of which is exercised
/// by hello-world style programs), the trap surfaces as a clean
/// runtime error rather than silent miscompilation.
// ── Main-module fallback synthesizer ──────────────────────────────────────
fn buildMainModuleFallback(arena: Allocator, adapter_iface: core_imports.CoreInterface) SpliceError![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    try out.appendSlice(arena, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    var unique_sigs = std.ArrayListUnmanaged(core_imports.FuncSig).empty;
    var sig_for_export = std.ArrayListUnmanaged(struct {
        name: []const u8,
        sig_idx: u32,
    }).empty;

    for (adapter_iface.imports) |im| {
        if (im.kind != .func) continue;
        if (!std.mem.eql(u8, im.module_name, "__main_module__")) continue;
        const sig = im.sig orelse continue;

        var found: ?u32 = null;
        for (unique_sigs.items, 0..) |u, i| {
            if (sigEql(u, sig)) {
                found = @intCast(i);
                break;
            }
        }
        const idx = found orelse blk: {
            const i: u32 = @intCast(unique_sigs.items.len);
            try unique_sigs.append(arena, sig);
            break :blk i;
        };
        try sig_for_export.append(arena, .{ .name = im.field_name, .sig_idx = idx });
    }

    if (sig_for_export.items.len == 0) {
        // Nothing to synthesize. Caller shouldn't have asked.
        try writeSection(arena, &out, 0x01, &.{0x00});
        return out.toOwnedSlice(arena);
    }

    // Detect whether any export is `cabi_realloc`. When present we
    // emit a working `realloc_via_memory_grow` body (using an
    // imported `env.memory`) so that adapter code paths which
    // legitimately call `cabi_realloc` (e.g. canon-lifting list-typed
    // returns from wasi:io APIs) get a real allocation instead of
    // trapping. Mirrors `wit-component/src/gc.rs:realloc_via_memory_grow`.
    const cabi_realloc_idx: ?u32 = blk: {
        for (sig_for_export.items, 0..) |se, i| {
            if (std.mem.eql(u8, se.name, "cabi_realloc")) break :blk @intCast(i);
        }
        break :blk null;
    };
    const needs_memory = cabi_realloc_idx != null;

    // type section
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(unique_sigs.items.len));
        for (unique_sigs.items) |s| {
            try body.append(arena, 0x60);
            try writeU32Leb(arena, &body, @intCast(s.params.len));
            for (s.params) |p| try body.append(arena, valTypeByte(p));
            try writeU32Leb(arena, &body, @intCast(s.results.len));
            for (s.results) |r| try body.append(arena, valTypeByte(r));
        }
        try writeSection(arena, &out, 0x01, body.items);
    }

    // import section: env.memory (only when a working cabi_realloc
    // is being emitted).
    if (needs_memory) {
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, 1); // one import
        const mod_name = "env";
        try writeU32Leb(arena, &body, @intCast(mod_name.len));
        try body.appendSlice(arena, mod_name);
        const field_name = "memory";
        try writeU32Leb(arena, &body, @intCast(field_name.len));
        try body.appendSlice(arena, field_name);
        try body.append(arena, 0x02); // memory desc
        try body.append(arena, 0x00); // limits: min only
        try writeU32Leb(arena, &body, 0); // initial pages
        try writeSection(arena, &out, 0x02, body.items);
    }

    // function section: one func per export, all using its sig idx
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(sig_for_export.items.len));
        for (sig_for_export.items) |se| try writeU32Leb(arena, &body, se.sig_idx);
        try writeSection(arena, &out, 0x03, body.items);
    }

    // export section
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(sig_for_export.items.len));
        for (sig_for_export.items, 0..) |se, fi| {
            try writeU32Leb(arena, &body, @intCast(se.name.len));
            try body.appendSlice(arena, se.name);
            try body.append(arena, 0x00); // export desc: func
            try writeU32Leb(arena, &body, @intCast(fi));
        }
        try writeSection(arena, &out, 0x07, body.items);
    }

    // code section: trap stub for everything except cabi_realloc,
    // which gets a working `realloc_via_memory_grow` body.
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(sig_for_export.items.len));
        for (sig_for_export.items, 0..) |_, i| {
            if (cabi_realloc_idx != null and i == cabi_realloc_idx.?) {
                const fb = reallocViaMemoryGrowBody();
                try writeU32Leb(arena, &body, @intCast(fb.len));
                try body.appendSlice(arena, &fb);
            } else {
                // body: locals_count=0 (LEB 0), unreachable (0x00), end (0x0b)
                const fb = [_]u8{ 0x00, 0x00, 0x0b };
                try writeU32Leb(arena, &body, @intCast(fb.len));
                try body.appendSlice(arena, &fb);
            }
        }
        try writeSection(arena, &out, 0x0a, body.items);
    }

    return out.toOwnedSlice(arena);
}

fn sigEql(a: core_imports.FuncSig, b: core_imports.FuncSig) bool {
    return std.mem.eql(wtypes.ValType, a.params, b.params) and
        std.mem.eql(wtypes.ValType, a.results, b.results);
}

/// Body bytes for a `cabi_realloc(i32, i32, i32, i32) -> i32` that
/// only honors fresh page-sized allocations (panics otherwise).
/// Mirrors `wit-component/src/gc.rs::realloc_via_memory_grow`.
///
/// One i32 local is declared to hold the `memory.grow` result before
/// the bounds-check trap branch (params 0-3 are old_ptr, old_len,
/// align, new_len; local 4 is the grow result).
fn reallocViaMemoryGrowBody() [51]u8 {
    return [_]u8{
        // locals: 1 group of 1 i32
        0x01, 0x01, 0x7f,
        // assert old_ptr (local 0) == 0
        0x41, 0x00, 0x20,
        0x00, 0x47, 0x04,
        0x40, 0x00, 0x0b,
        // assert old_len (local 1) == 0
        0x41, 0x00, 0x20,
        0x01, 0x47, 0x04,
        0x40, 0x00, 0x0b,
        // assert new_len (local 3) == 65536
        0x41, 0x80, 0x80,
        0x04, 0x20, 0x03,
        0x47, 0x04, 0x40,
        0x00, 0x0b,
        // memory.grow 0 → local.tee 4
        0x41,
        0x01, 0x40, 0x00,
        0x22, 0x04,
        // check grow result == -1 → unreachable
        0x41,
        0x7f, 0x46, 0x04,
        0x40, 0x00, 0x0b,
        // return local.get 4 << 16
        0x20, 0x04, 0x41,
        0x10, 0x74,
        0x0b, // function end
    };
}

fn valTypeByte(v: wtypes.ValType) u8 {
    return switch (v) {
        .i32 => 0x7f,
        .i64 => 0x7e,
        .f32 => 0x7d,
        .f64 => 0x7c,
        else => 0x7f,
    };
}

fn writeSection(arena: Allocator, out: *std.ArrayListUnmanaged(u8), id: u8, body: []const u8) SpliceError!void {
    try out.append(arena, id);
    try writeU32Leb(arena, out, @intCast(body.len));
    try out.appendSlice(arena, body);
}

// ── Custom-section stripping ──────────────────────────────────────────────

/// Strip `component-type:*` custom sections from a core wasm binary.
fn stripComponentTypeSections(arena: Allocator, core_bytes: []const u8) SpliceError![]u8 {
    if (core_bytes.len < 8) return error.InvalidAdapterCore;
    if (!std.mem.eql(u8, core_bytes[0..4], "\x00asm")) return error.InvalidAdapterCore;

    var out = std.ArrayListUnmanaged(u8).empty;
    try out.appendSlice(arena, core_bytes[0..8]);

    var i: usize = 8;
    while (i < core_bytes.len) {
        const id = core_bytes[i];
        i += 1;
        const sz = try readU32Leb(core_bytes, i);
        i += sz.bytes_read;
        if (i + sz.value > core_bytes.len) return error.InvalidAdapterCore;
        const body = core_bytes[i .. i + sz.value];
        i += sz.value;

        if (id == 0 and body.len > 0) {
            const n = readU32Leb(body, 0) catch return error.InvalidAdapterCore;
            if (n.bytes_read + n.value <= body.len) {
                const sec_name = body[n.bytes_read .. n.bytes_read + n.value];
                if (std.mem.startsWith(u8, sec_name, "component-type:")) continue;
            }
        }
        try out.append(arena, id);
        try writeU32Leb(arena, &out, sz.value);
        try out.appendSlice(arena, body);
    }
    return out.toOwnedSlice(arena);
}

const LebRead = struct { value: u32, bytes_read: usize };

fn readU32Leb(buf: []const u8, start: usize) SpliceError!LebRead {
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

fn writeU32Leb(arena: Allocator, out: *std.ArrayListUnmanaged(u8), v: u32) SpliceError!void {
    var x = v;
    while (true) {
        var byte: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x != 0) byte |= 0x80;
        try out.append(arena, byte);
        if (x == 0) break;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "stripComponentTypeSections: drops component-type custom, keeps others" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = std.ArrayListUnmanaged(u8).empty;
    try src.appendSlice(arena, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // custom section "component-type:wit-bindgen:0.43.0:foo:encoded world"
    {
        const name = "component-type:wit-bindgen:0.43.0:foo:encoded world";
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(name.len));
        try body.appendSlice(arena, name);
        try body.appendSlice(arena, "payload");
        try writeSection(arena, &src, 0x00, body.items);
    }
    // unrelated custom section "name"
    {
        const name = "name";
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(name.len));
        try body.appendSlice(arena, name);
        try body.appendSlice(arena, "\x00\x00");
        try writeSection(arena, &src, 0x00, body.items);
    }
    // unrelated bare custom "component-type" (intentionally NOT prefixed
    // with "component-type:" — strip should leave it alone).
    {
        const name = "component-type";
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(name.len));
        try body.appendSlice(arena, name);
        try body.appendSlice(arena, "embed-payload");
        try writeSection(arena, &src, 0x00, body.items);
    }

    const stripped = try stripComponentTypeSections(arena, src.items);

    // Magic + version preserved.
    try testing.expectEqualSlices(u8, src.items[0..8], stripped[0..8]);
    // The dropped section's payload should not appear.
    try testing.expect(std.mem.indexOf(u8, stripped, "wit-bindgen") == null);
    // The kept sections' payloads should both still appear.
    try testing.expect(std.mem.indexOf(u8, stripped, "name") != null);
    try testing.expect(std.mem.indexOf(u8, stripped, "embed-payload") != null);
}

test "stripComponentTypeSections: rejects non-core bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidAdapterCore, stripComponentTypeSections(arena, "not-wasm"));
}

test "buildMainModuleFallback: synthesizes trapping export per __main_module__ import" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const realloc_params = [_]wtypes.ValType{ .i32, .i32, .i32, .i32 };
    const realloc_results = [_]wtypes.ValType{.i32};
    const start_params = [_]wtypes.ValType{};
    const start_results = [_]wtypes.ValType{};
    const imports = [_]core_imports.ImportEntry{
        .{
            .module_name = "__main_module__",
            .field_name = "cabi_realloc",
            .kind = .func,
            .sig = .{ .params = &realloc_params, .results = &realloc_results },
        },
        .{
            .module_name = "__main_module__",
            .field_name = "_start",
            .kind = .func,
            .sig = .{ .params = &start_params, .results = &start_results },
        },
        // Non-__main_module__ imports must be ignored.
        .{
            .module_name = "wasi:cli/environment@0.2.6",
            .field_name = "get-environment",
            .kind = .func,
            .sig = .{ .params = &start_params, .results = &start_results },
        },
    };
    const iface = core_imports.CoreInterface{
        .imports = &imports,
        .exports = &.{},
    };

    const wasm = try buildMainModuleFallback(arena, iface);

    // The result is a valid core wasm and re-parses through core_imports.
    var owned = try core_imports.extract(testing.allocator, wasm);
    defer owned.deinit();

    // Two exports, one per __main_module__ import; their sigs match.
    try testing.expectEqual(@as(usize, 2), owned.interface.exports.len);

    const realloc_e = owned.interface.findExport("cabi_realloc") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(wtypes.ExternalKind.func, realloc_e.kind);
    try testing.expect(realloc_e.sig != null);
    try testing.expectEqualSlices(wtypes.ValType, &realloc_params, realloc_e.sig.?.params);
    try testing.expectEqualSlices(wtypes.ValType, &realloc_results, realloc_e.sig.?.results);

    const start_e = owned.interface.findExport("_start") orelse return error.TestUnexpectedResult;
    try testing.expect(start_e.sig != null);
    try testing.expectEqual(@as(usize, 0), start_e.sig.?.params.len);
    try testing.expectEqual(@as(usize, 0), start_e.sig.?.results.len);

    // The unrelated wasi import must NOT have been turned into an export.
    try testing.expect(owned.interface.findExport("get-environment") == null);
}

test "coreToCompValType: maps numeric wasm types to component analogues" {
    try testing.expectEqual(ctypes.ValType.u32, coreToCompValType(.i32));
    try testing.expectEqual(ctypes.ValType.u64, coreToCompValType(.i64));
    try testing.expectEqual(ctypes.ValType.f32, coreToCompValType(.f32));
    try testing.expectEqual(ctypes.ValType.f64, coreToCompValType(.f64));
}

// ── End-to-end synthetic splice ──────────────────────────────────────────

const test_fixtures = @import("test_fixtures.zig");
const loader = @import("../loader.zig");

test "splice: end-to-end on synthetic mock adapter + embed" {
    const a = testing.allocator;

    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbed(a);
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // The wrapping component lifts exactly one top-level export — the
    // `wasi:cli/run@…` instance — regardless of what the adapter
    // declared internally.
    try testing.expectEqual(@as(usize, 1), comp.exports.len);
    try testing.expect(std.mem.startsWith(u8, comp.exports[0].name, "wasi:cli/run@"));
    try testing.expect(comp.exports[0].desc == .instance);

    // Top-level imports surface every live WASI namespace post-GC.
    // The fixture's adapter imports exactly one
    // (`wasi:cli/stdout@0.1.0`); every other namespace declared by
    // the encoded world should have been pruned because no canon-lower
    // import in the GC'd adapter references it.
    var saw_stdout = false;
    for (comp.imports) |im| {
        if (std.mem.eql(u8, im.name, test_fixtures.STDOUT_NAMESPACE)) {
            saw_stdout = true;
            try testing.expect(im.desc == .instance);
        }
    }
    try testing.expect(saw_stdout);

    // Inner core modules: shim + embed + adapter + fixup. The
    // optional `__main_module__` fallback is only emitted when the
    // adapter imports something from `__main_module__` that the embed
    // does not export. Our synthetic embed exports `_start` (matching
    // the adapter's only `__main_module__` import) so the fallback
    // is omitted.
    try testing.expectEqual(@as(usize, 4), comp.core_modules.len);
}

test "spliceMany: end-to-end on synthetic primary + bare secondary adapter pair" {
    const a = testing.allocator;

    const primary_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(primary_bytes);
    const secondary_bytes = try test_fixtures.buildBareSecondaryAdapter(a);
    defer a.free(secondary_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithSecondary(a);
    defer a.free(embed_bytes);

    const adapters = [_]Adapter{
        .{ .name = "wasi_snapshot_preview1", .bytes = primary_bytes },
        .{ .name = test_fixtures.SECONDARY_NAME, .bytes = secondary_bytes },
    };
    const out = try spliceMany(a, embed_bytes, &adapters);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // Exactly one top-level export — the lifted `wasi:cli/run@…`
    // instance from the primary. Secondaries don't contribute
    // top-level exports.
    try testing.expectEqual(@as(usize, 1), comp.exports.len);
    try testing.expect(std.mem.startsWith(u8, comp.exports[0].name, "wasi:cli/run@"));

    // Top-level imports include the primary's live WASI namespace.
    // Secondaries don't surface a top-level import — they're
    // wired through inline-export instances under their adapter
    // name, which the embed binds to internally.
    var saw_stdout = false;
    for (comp.imports) |im| {
        if (std.mem.eql(u8, im.name, test_fixtures.STDOUT_NAMESPACE)) {
            saw_stdout = true;
        }
    }
    try testing.expect(saw_stdout);

    // Inner core modules: shim + embed + primary + fixup + secondary.
    // The synthetic embed exports `_start`, matching the primary's
    // `__main_module__._start` import, so the fallback core module
    // is not emitted. The secondary's only import is `env.memory`,
    // which the primary supplies via its env_inst.
    try testing.expectEqual(@as(usize, 5), comp.core_modules.len);
}

test "splice: end-to-end on synthetic reactor adapter + reactor embed" {
    const a = testing.allocator;

    const adapter_bytes = try test_fixtures.buildSyntheticReactorAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticReactorEmbed(a);
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // Reactor: one top-level export per embed export interface.
    // Our synthetic embed exports the single `docs:counter/api@…`
    // interface, so exactly one instance export and NO
    // `wasi:cli/run@…` (this is the visible reactor signature).
    try testing.expectEqual(@as(usize, 1), comp.exports.len);
    try testing.expectEqualStrings(test_fixtures.REACTOR_API_NAMESPACE, comp.exports[0].name);
    try testing.expect(comp.exports[0].desc == .instance);
    for (comp.exports) |ex| {
        try testing.expect(!std.mem.startsWith(u8, ex.name, "wasi:cli/run@"));
    }

    // Top-level imports surface live WASI namespaces post-GC. The
    // reactor adapter imports exactly one (`wasi:cli/stdout@…`).
    var saw_stdout = false;
    for (comp.imports) |im| {
        if (std.mem.eql(u8, im.name, test_fixtures.STDOUT_NAMESPACE)) {
            saw_stdout = true;
            try testing.expect(im.desc == .instance);
        }
    }
    try testing.expect(saw_stdout);

    // Inner core modules: shim + embed + adapter + fixup. NO
    // `__main_module__` fallback module — the reactor adapter has
    // zero `__main_module__.<x>` imports, so Step 7's fallback
    // path is skipped entirely.
    try testing.expectEqual(@as(usize, 4), comp.core_modules.len);
}

test "spliceMany: end-to-end on reactor primary + bare secondary adapter pair" {
    const a = testing.allocator;

    const primary_bytes = try test_fixtures.buildSyntheticReactorAdapter(a);
    defer a.free(primary_bytes);
    const secondary_bytes = try test_fixtures.buildBareSecondaryAdapter(a);
    defer a.free(secondary_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticReactorEmbedWithSecondary(a);
    defer a.free(embed_bytes);

    const adapters = [_]Adapter{
        .{ .name = "wasi_snapshot_preview1", .bytes = primary_bytes },
        .{ .name = test_fixtures.SECONDARY_NAME, .bytes = secondary_bytes },
    };
    const out = try spliceMany(a, embed_bytes, &adapters);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // Reactor primary + secondary: exactly one top-level export
    // (the embed's single export interface) — no `wasi:cli/run@…`.
    try testing.expectEqual(@as(usize, 1), comp.exports.len);
    try testing.expectEqualStrings(test_fixtures.REACTOR_API_NAMESPACE, comp.exports[0].name);

    // Inner core modules: shim + embed + primary + fixup + secondary.
    try testing.expectEqual(@as(usize, 5), comp.core_modules.len);
}

test "splice: accepts a reactor-shaped adapter that imports __main_module__" {
    const a = testing.allocator;

    // Hand-roll a "fake reactor" adapter: no `<iface>#name` exports
    // (so `detectShape` classifies it `.reactor`) but it imports
    // `__main_module__._start`. The standard wasmtime preview1
    // adapters (command *and* reactor) import from `__main_module__`
    // (e.g. `cabi_realloc`), so assemble() Step 7 must wire those
    // imports to the embed's exports (or a generated fallback),
    // rather than reject the adapter. See cataggar/wabt#327.
    //
    // The fixture is otherwise structurally valid: env.memory +
    // wasi:cli/stdout.flush imports keep the GC happy, fd_write +
    // cabi_import_realloc satisfy the embed's preview1 import.
    var ad = std.ArrayListUnmanaged(u8).empty;
    defer ad.deinit(a);
    try ad.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // Type section: () -> i32, () -> ()
    try ad.appendSlice(a, &.{ 0x01, 0x08, 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x00 });

    // Import section: env.memory, __main_module__._start, wasi:cli/stdout.flush
    {
        var imp = std.ArrayListUnmanaged(u8).empty;
        defer imp.deinit(a);
        try imp.append(a, 0x03);
        // env.memory
        try imp.appendSlice(a, &.{ 3, 'e', 'n', 'v', 6, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00, 0x00 });
        // __main_module__._start (typeidx 1)
        try imp.appendSlice(a, &.{ 15, '_', '_', 'm', 'a', 'i', 'n', '_', 'm', 'o', 'd', 'u', 'l', 'e', '_', '_', 6, '_', 's', 't', 'a', 'r', 't', 0x00, 0x01 });
        // wasi:cli/stdout@0.1.0.flush (typeidx 0)
        const ns = "wasi:cli/stdout@0.1.0";
        try imp.append(a, @intCast(ns.len));
        try imp.appendSlice(a, ns);
        try imp.appendSlice(a, &.{ 5, 'f', 'l', 'u', 's', 'h', 0x00, 0x00 });
        try ad.append(a, 0x02);
        var len_buf: [5]u8 = undefined;
        const n = leb.writeU32Leb128(&len_buf, @intCast(imp.items.len));
        try ad.appendSlice(a, len_buf[0..n]);
        try ad.appendSlice(a, imp.items);
    }
    // Function section: 2 funcs, type 0
    try ad.appendSlice(a, &.{ 0x03, 0x03, 0x02, 0x00, 0x00 });
    // Export section: fd_write (func 2), cabi_import_realloc (func 3)
    // Imported funcs: _start (idx 0), stdout.flush (idx 1).
    {
        var exp = std.ArrayListUnmanaged(u8).empty;
        defer exp.deinit(a);
        try exp.append(a, 0x02);
        try exp.appendSlice(a, &.{ 8, 'f', 'd', '_', 'w', 'r', 'i', 't', 'e', 0x00, 0x02 });
        try exp.appendSlice(a, &.{ 19, 'c', 'a', 'b', 'i', '_', 'i', 'm', 'p', 'o', 'r', 't', '_', 'r', 'e', 'a', 'l', 'l', 'o', 'c', 0x00, 0x03 });
        try ad.append(a, 0x07);
        var len_buf: [5]u8 = undefined;
        const n = leb.writeU32Leb128(&len_buf, @intCast(exp.items.len));
        try ad.appendSlice(a, len_buf[0..n]);
        try ad.appendSlice(a, exp.items);
    }
    // Code section: 2 bodies
    // body 0 (fd_write): call $0 (_start); call $1 (stdout.flush); drop; i32.const 0; end
    //   — calls both imports so neither gets GC'd.
    // body 1 (cabi_import_realloc): i32.const 0; end
    try ad.appendSlice(a, &.{
        0x0a, 0x10, 0x02,
        0x09, 0x00, 0x10,
        0x00, 0x10, 0x01,
        0x1a, 0x41, 0x00,
        0x0b, 0x04, 0x00,
        0x41, 0x00, 0x0b,
    });

    // Encoded-world custom section — splice() parses this early, so
    // we must supply one even though the test will reject the shape
    // before it's used.
    const metadata_encode = @import("../wit/metadata_encode.zig");
    const ct = try metadata_encode.encodeWorldFromSource(a, "package wasi:cli@0.1.0;\ninterface stdout { flush: func() -> u32; }\nworld reactor { import stdout; }", "reactor");
    defer a.free(ct);

    const sec_name = "component-type:wasi:cli@0.1.0:reactor:encoded world";
    var name_leb_buf: [5]u8 = undefined;
    const name_leb_n = leb.writeU32Leb128(&name_leb_buf, @intCast(sec_name.len));
    const body_len = name_leb_n + sec_name.len + ct.len;

    try ad.append(a, 0x00);
    var size_leb_buf: [5]u8 = undefined;
    const size_leb_n = leb.writeU32Leb128(&size_leb_buf, @intCast(body_len));
    try ad.appendSlice(a, size_leb_buf[0..size_leb_n]);
    try ad.appendSlice(a, name_leb_buf[0..name_leb_n]);
    try ad.appendSlice(a, sec_name);
    try ad.appendSlice(a, ct);

    const embed_bytes = try test_fixtures.buildSyntheticReactorEmbed(a);
    defer a.free(embed_bytes);

    // A reactor adapter that imports `__main_module__.<f>` is now spliced
    // (the import is wired to the embed export or a generated fallback),
    // not rejected. See cataggar/wabt#327.
    const out = try splice(a, embed_bytes, ad.items, "wasi_snapshot_preview1");
    defer a.free(out);
    try testing.expect(out.len > 0);
}

test "spliceMany: rejects zero non-env-import adapters" {
    const a = testing.allocator;

    const secondary_bytes = try test_fixtures.buildBareSecondaryAdapter(a);
    defer a.free(secondary_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithSecondary(a);
    defer a.free(embed_bytes);

    const adapters = [_]Adapter{
        .{ .name = test_fixtures.SECONDARY_NAME, .bytes = secondary_bytes },
        .{ .name = "another", .bytes = secondary_bytes },
    };
    try testing.expectError(error.MissingPrimaryAdapter, spliceMany(a, embed_bytes, &adapters));
}

test "spliceMany: rejects two non-env-import adapters" {
    const a = testing.allocator;

    const primary_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(primary_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithSecondary(a);
    defer a.free(embed_bytes);

    const adapters = [_]Adapter{
        .{ .name = "wasi_snapshot_preview1", .bytes = primary_bytes },
        .{ .name = "second_run", .bytes = primary_bytes },
    };
    try testing.expectError(error.AmbiguousPrimaryAdapter, spliceMany(a, embed_bytes, &adapters));
}

test "spliceMany: rejects two adapters with non-env imports" {
    const a = testing.allocator;

    const primary_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(primary_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithSecondary(a);
    defer a.free(embed_bytes);

    // Hand-roll a tiny adapter that imports `__main_module__.x`
    // — under the post-#116 partition, ANY non-`env` import makes
    // an adapter a primary candidate, so this collides with the
    // synthetic primary and surfaces `AmbiguousPrimaryAdapter`.
    const bad = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // Type section: () -> ()
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // Import section: __main_module__.x — func type 0
        0x02, 0x15,
        0x01, 15,   '_',  '_',  'm',  'a',  'i',  'n',
        '_',  'm',  'o',  'd',  'u',  'l',  'e',  '_',
        '_',  1,    'x',  0x00, 0x00,
        // Function section: 1 defined func, type 0
        0x03, 0x02, 0x01,
        0x00,
        // Export section: bare-name "thing" -> func 1
        0x07, 0x09, 0x01, 5,    't',  'h',  'i',
        'n',  'g',  0x00, 0x01,
        // Code section: empty body (just end)
        0x0a, 0x04, 0x01, 0x02,
        0x00, 0x0b,
    };

    const adapters = [_]Adapter{
        .{ .name = "wasi_snapshot_preview1", .bytes = primary_bytes },
        .{ .name = test_fixtures.SECONDARY_NAME, .bytes = &bad },
    };
    try testing.expectError(error.AmbiguousPrimaryAdapter, spliceMany(a, embed_bytes, &adapters));
}

test "augmentLiveMethodsByNamespaceWithEmbed #222: embed-declared methods join adapter live set" {
    // Regression for cataggar/wabt#222.
    //
    // The wasmtime upstream preview1 adapter's core wasm imports
    // only `[resource-drop]pollable` and `poll` from
    // `wasi:io/poll@0.2.6` — not the `[method]pollable.*` methods.
    // Pre-fix, `world_gc.gcInstanceBody` consequently dropped both
    // methods from the wrapping component's `wasi:io/poll`
    // instance-type body, even when the user's embed component-type
    // declared the canonical interface (resource pollable with
    // `ready` + `block` methods + iface-level `poll`).
    //
    // The fix: also seed the live set from the embed's
    // `component-type:<world>` custom section so every method the
    // user's WIT declares for an imported iface survives GC.
    //
    // This unit test mirrors that scenario in isolation:
    //
    //   * `base`: simulates `collectLiveMethodsByNamespace`'s
    //     output for the wasmtime adapter — only `poll` + the
    //     resource-drop appear under `wasi:io/poll@0.2.6`.
    //   * Build a synthetic embed with a `component-type` custom
    //     section whose world declares
    //     `import wasi:io/poll@0.2.6` carrying the canonical
    //     `pollable.ready` + `pollable.block` methods.
    //   * After `augmentLiveMethodsByNamespaceWithEmbed` the
    //     namespace's `methods` set contains all four (adapter
    //     contributions union embed contributions).
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ns = "wasi:io/poll@0.2.6";
    const adapter_methods = [_][]const u8{ "[resource-drop]pollable", "poll" };
    const adapter_type_exports = [_][]const u8{"pollable"};

    const base = [_]world_gc.LiveMethodSet{
        .{
            .namespace = ns,
            .methods = &adapter_methods,
            .type_exports = &adapter_type_exports,
        },
    };

    const ct_payload = try metadata_encode_for_test.encodeWorldFromSource(a,
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
        \\world demo {
        \\    import poll;
        \\}
    , "demo");
    defer a.free(ct_payload);

    var embed = std.ArrayListUnmanaged(u8).empty;
    defer embed.deinit(a);
    try embed.appendSlice(a, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    const cs_name = "component-type:demo";
    var cs_body = std.ArrayListUnmanaged(u8).empty;
    defer cs_body.deinit(a);
    try writeU32Leb(a, &cs_body, @intCast(cs_name.len));
    try cs_body.appendSlice(a, cs_name);
    try cs_body.appendSlice(a, ct_payload);
    try embed.append(a, 0x00);
    try writeU32Leb(a, &embed, @intCast(cs_body.items.len));
    try embed.appendSlice(a, cs_body.items);

    const augmented = try augmentLiveMethodsByNamespaceWithEmbed(arena, &base, embed.items);

    // Locate the wasi:io/poll entry in the result.
    var idx: ?usize = null;
    for (augmented, 0..) |s, i| if (std.mem.eql(u8, s.namespace, ns)) {
        idx = i;
    };
    try testing.expect(idx != null);
    const entry = augmented[idx.?];

    // Adapter-derived methods survive verbatim.
    var has_drop = false;
    var has_poll = false;
    // Embed-derived methods are now present too.
    var has_ready = false;
    var has_block = false;
    for (entry.methods) |m| {
        if (std.mem.eql(u8, m, "[resource-drop]pollable")) has_drop = true;
        if (std.mem.eql(u8, m, "poll")) has_poll = true;
        if (std.mem.eql(u8, m, "[method]pollable.ready")) has_ready = true;
        if (std.mem.eql(u8, m, "[method]pollable.block")) has_block = true;
    }
    try testing.expect(has_drop);
    try testing.expect(has_poll);
    try testing.expect(has_ready);
    try testing.expect(has_block);

    // `pollable` type-export remains a type anchor.
    var has_pollable = false;
    for (entry.type_exports) |t| if (std.mem.eql(u8, t, "pollable")) {
        has_pollable = true;
    };
    try testing.expect(has_pollable);
}

test "augmentLiveMethodsByNamespaceWithEmbed: empty embed falls back to base unchanged" {
    // No component-type custom section on the embed → the function
    // must return the base set verbatim. Same applies if the
    // embed has malformed metadata (we treat that as "no useful
    // signal" rather than failing the splice).
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ns = "wasi:io/poll@0.2.6";
    const adapter_methods = [_][]const u8{"poll"};
    const adapter_type_exports = [_][]const u8{"pollable"};

    const base = [_]world_gc.LiveMethodSet{
        .{
            .namespace = ns,
            .methods = &adapter_methods,
            .type_exports = &adapter_type_exports,
        },
    };

    const empty_embed = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const augmented = try augmentLiveMethodsByNamespaceWithEmbed(arena, &base, &empty_embed);
    try testing.expectEqual(@as(usize, 1), augmented.len);
    try testing.expectEqualStrings(ns, augmented[0].namespace);
    try testing.expectEqual(@as(usize, 1), augmented[0].methods.len);
    try testing.expectEqualStrings("poll", augmented[0].methods[0]);
    try testing.expectEqualStrings("pollable", augmented[0].type_exports[0]);
}

const metadata_encode_for_test = @import("../wit/metadata_encode.zig");

test "splice #228: embed's iface body Defined() decls survive in wrapping component's import body" {
    // Reproducer for cataggar/wabt#228.
    //
    // The embed's `component-type:<world>` custom section declares
    // an import iface `docs:demo/api` whose `compute` func returns
    // a `result<u32, u32>`. Pre-fix the splicer's
    // `buildEmbedExtraImports` only emitted `Type(Func)` + `Export`
    // decls per imported func, dropping the supporting
    // `Type(Defined(Result))` typedef the FuncType's `type_idx`
    // operand pointed at. The wrapping component then had the
    // local-type-index of the Result-typedef out of bounds, and
    // wasm-tools rejected with `unknown type N: type index out of
    // bounds`.
    //
    // Post-fix the canonical-body path clones the embed's iface
    // body verbatim (Defined Result + Func + Export), preserving
    // every local type-slot operand. This test asserts the three
    // canonical decls survive in the wrapping component's iface
    // body in the right order with consistent local-type-idx refs.
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithExtraDefinedImport(a);
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // Find the wrapping component's `docs:demo/api@0.1.0` import.
    var maybe_inst_idx: ?u32 = null;
    for (comp.imports) |im| {
        if (std.mem.eql(u8, im.name, test_fixtures.EXTRA_DEFINED_NAMESPACE)) {
            try testing.expect(im.desc == .instance);
            maybe_inst_idx = im.desc.instance;
        }
    }
    try testing.expect(maybe_inst_idx != null);

    const contrib = comp.type_indexspace[maybe_inst_idx.?];
    try testing.expect(contrib == .type_def);
    const td = comp.types[contrib.type_def];
    try testing.expect(td == .instance);

    // The iface body must carry the full canonical shape:
    //   [0] Type(Defined Result)
    //   [1] Type(Func)
    //   [2] Export "compute" desc=.func=<slot pointing at [1]>
    //
    // And the Func's results=Unnamed(Type(0)) must resolve to the
    // Defined Result at slot 0 (NOT dangle past the body's local
    // type-index range).
    const decls = td.instance.decls;
    try testing.expectEqual(@as(usize, 3), decls.len);

    // decl[0]: Defined Result typedef.
    try testing.expect(decls[0] == .type);
    try testing.expect(decls[0].type == .result);

    // decl[1]: Func typedef whose result type is `Unnamed(Type(0))`.
    try testing.expect(decls[1] == .type);
    try testing.expect(decls[1].type == .func);
    const ft = decls[1].type.func;
    try testing.expect(ft.results == .unnamed);
    try testing.expect(ft.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 0), ft.results.unnamed.type_idx);

    // decl[2]: Export "compute" pointing at the Func at slot 1.
    try testing.expect(decls[2] == .@"export");
    const e = decls[2].@"export";
    try testing.expectEqualStrings("compute", e.name);
    try testing.expect(e.desc == .func);
    try testing.expectEqual(@as(u32, 1), e.desc.func);
}

test "splice #230: embed-extra canon.lower carries memory + string_encoding opts for string-using sigs" {
    // Regression for cataggar/wabt#230.
    //
    // Pre-fix `buildEmbedExtraImports` emitted `canon.lower` with
    // `opts = &.{}` BEFORE `main_inst` was created — so even when
    // the embed-extra func sig needed `memory` / `realloc` /
    // `string-encoding` opts, those refs couldn't be wired
    // (forward-reference cycle). The resulting comp.wasm failed
    // `wasm-tools validate` at the canon-lower site for any func
    // whose sig reached `string`/`list`/records.
    //
    // Post-fix embed-extra funcs route through the existing
    // shim/fixup table (mirror of the WASI-indirect path). The
    // fixup phase emits `canon.lower` AFTER `main_inst`'s memory
    // + `cabi_realloc` aliases are available, so the lower carries
    // the right opts.
    //
    // The fixture's `compute: func(s: string) -> singleton`
    // (where `record singleton { a: u32 }`) classifies as needing
    // memory + string_encoding (string param) but not realloc
    // (result is flat). The shim/fixup routing is exercised
    // regardless — every embed-extra func goes through the table
    // post-#230, with opts derived per func.
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithExtraStringImport(a);
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // Find the canon.lower for compute. Its opts list must include
    // `memory` and `string_encoding`. (Realloc is NOT expected for
    // this sig — the singleton record flat-returns as i32.)
    var saw_lower_with_opts = false;
    for (comp.canons) |c| switch (c) {
        .lower => |l| {
            var has_memory = false;
            var has_string_encoding = false;
            for (l.opts) |o| switch (o) {
                .memory => has_memory = true,
                .string_encoding => has_string_encoding = true,
                else => {},
            };
            if (has_memory and has_string_encoding) saw_lower_with_opts = true;
        },
        else => {},
    };
    try testing.expect(saw_lower_with_opts);

    // The wrapping component's `docs:opts/api` import body is
    // alias-free + canonical (carries the `record singleton`
    // Defined typedef — also covers the #228 type-closure path
    // for the string-using case).
    var saw_record_decl = false;
    for (comp.imports) |im| {
        if (!std.mem.eql(u8, im.name, test_fixtures.EXTRA_STRING_NAMESPACE)) continue;
        const contrib = comp.type_indexspace[im.desc.instance];
        if (contrib != .type_def) continue;
        const td = comp.types[contrib.type_def];
        if (td != .instance) continue;
        for (td.instance.decls) |d| switch (d) {
            .type => |tt| if (tt == .record) {
                saw_record_decl = true;
            },
            else => {},
        };
    }
    try testing.expect(saw_record_decl);
}

test "splice #241: resource-bearing embed-extra import keeps own/borrow/option (not flattened to u32)" {
    // Regression for cataggar/wabt#241.
    //
    // A component built from an embed whose WIT imports a resource-
    // bearing interface (the minimal shape of `wasi:http/types` /
    // `wasi:io/poll`) was malformed: the wrapping component's import
    // instance-type body for that namespace lost its resource type
    // definitions and had every method param flattened to bare `u32`
    // — `borrow<R>` self handles, `own<R>` constructor results, and
    // `option<string>` args all collapsed — so `wasm-tools validate`
    // rejected it with `[constructor]… should return (own $T)`.
    //
    // Root cause: `buildEmbedExtraImports` fell back to per-func
    // primitive synthesis (`coreToCompValType`) for namespaces the
    // adapter does not hoist when the canonical-body path returned
    // null. The fix preserves the embed's canonical instance body
    // (resource defs + own/borrow/option typedefs) verbatim.
    //
    // This test splices the resource fixture and asserts the
    // wrapping component's `docs:res/api@0.1.0` import body still
    // carries (1) a `(type (sub resource))` export, (2) an `own`
    // handle typedef (the constructor result), (3) a `borrow` handle
    // typedef (the method self), and (4) an `option` typedef (the
    // `option<string>` arg) — none of which survive the lossy
    // primitive fallback.
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithResourceImport(a);
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    // Locate the wrapping component's `docs:res/api@0.1.0` import.
    var maybe_inst_idx: ?u32 = null;
    for (comp.imports) |im| {
        if (std.mem.eql(u8, im.name, test_fixtures.EXTRA_RESOURCE_NAMESPACE)) {
            try testing.expect(im.desc == .instance);
            maybe_inst_idx = im.desc.instance;
        }
    }
    try testing.expect(maybe_inst_idx != null);

    const contrib = comp.type_indexspace[maybe_inst_idx.?];
    try testing.expect(contrib == .type_def);
    const td = comp.types[contrib.type_def];
    try testing.expect(td == .instance);
    const decls = td.instance.decls;

    // Scan the body for the typed decls the lossy fallback would drop.
    var has_sub_resource = false;
    var has_own = false;
    var has_borrow = false;
    var has_option = false;
    var ctor_func_slot: ?u32 = null;

    // Build the body's local type-slot table (1:1 with type-allocating
    // decls) so we can resolve `[constructor]thing`'s func result.
    var slots = std.ArrayListUnmanaged(?ctypes.TypeDef).empty;
    for (decls) |d| switch (d) {
        .type => |t| {
            switch (t) {
                .val => |v| switch (v) {
                    .own => has_own = true,
                    .borrow => has_borrow = true,
                    else => {},
                },
                .option => has_option = true,
                else => {},
            }
            try slots.append(arena.allocator(), t);
        },
        .alias => |al| {
            const sort: ctypes.Sort = switch (al) {
                .instance_export => |ie| ie.sort,
                .outer => |o| o.sort,
            };
            if (sort == .type) try slots.append(arena.allocator(), null);
        },
        .@"export" => |e| switch (e.desc) {
            .type => |tb| {
                if (tb == .sub_resource) has_sub_resource = true;
                try slots.append(arena.allocator(), null);
            },
            .func => |fidx| {
                if (std.mem.eql(u8, e.name, test_fixtures.EXTRA_RESOURCE_CTOR)) ctor_func_slot = fidx;
            },
            else => {},
        },
        else => {},
    };

    // (1) Resource type definition survives.
    try testing.expect(has_sub_resource);
    // (2)+(3) own + borrow handle typedefs survive (constructor result +
    // method self), proving params were NOT flattened to bare u32.
    try testing.expect(has_own);
    try testing.expect(has_borrow);
    // (4) the `option<string>` arg survives as an option typedef.
    try testing.expect(has_option);

    // Precise check for defect #2: `[constructor]thing`'s func result
    // resolves to an `own<thing>` handle, not a plain scalar.
    try testing.expect(ctor_func_slot != null);
    const ctor_td = slots.items[ctor_func_slot.?] orelse unreachable;
    try testing.expect(ctor_td == .func);
    const res = ctor_td.func.results;
    try testing.expect(res == .unnamed);
    const res_vt: ctypes.ValType = switch (res.unnamed) {
        .type_idx => |k| blk: {
            const slot_td = slots.items[k] orelse break :blk res.unnamed;
            break :blk if (slot_td == .val) slot_td.val else res.unnamed;
        },
        else => res.unnamed,
    };
    try testing.expect(res_vt == .own);
}

fn testImportInstanceBody(
    comp: *const ctypes.Component,
    name: []const u8,
) ?[]const ctypes.Decl {
    for (comp.imports) |im| {
        if (!std.mem.eql(u8, im.name, name) or im.desc != .instance) continue;
        if (im.desc.instance >= comp.type_indexspace.len) return null;
        const contributor = comp.type_indexspace[im.desc.instance];
        if (contributor != .type_def or contributor.type_def >= comp.types.len) return null;
        const td = comp.types[contributor.type_def];
        if (td != .instance) return null;
        return td.instance.decls;
    }
    return null;
}

fn testCoreBundleContaining(
    comp: *const ctypes.Component,
    field: []const u8,
) ?[]const ctypes.CoreInlineExport {
    for (comp.core_instances) |instance| switch (instance) {
        .exports => |exports| {
            for (exports) |e| {
                if (std.mem.eql(u8, e.name, field)) return exports;
            }
        },
        else => {},
    };
    return null;
}

fn testImportedInstanceIndex(
    comp: *const ctypes.Component,
    import_idx: u32,
) ?u32 {
    for (comp.comp_instance_indexspace, 0..) |contributor, idx| switch (contributor) {
        .import => |candidate| if (candidate == import_idx) return @intCast(idx),
        else => {},
    };
    return null;
}

fn testExpectImportedResourceAlias(
    comp: *const ctypes.Component,
    type_idx: u32,
    instance_idx: u32,
    resource_name: []const u8,
) !void {
    if (type_idx >= comp.type_indexspace.len) return error.TestUnexpectedResult;
    const contributor = comp.type_indexspace[type_idx];
    if (contributor != .alias or contributor.alias >= comp.aliases.len)
        return error.TestUnexpectedResult;
    const alias = comp.aliases[contributor.alias];
    if (alias != .instance_export) return error.TestUnexpectedResult;
    try testing.expect(alias.instance_export.sort == .type);
    try testing.expectEqual(instance_idx, alias.instance_export.instance_idx);
    try testing.expectEqualStrings(resource_name, alias.instance_export.name);
}

fn testInstanceBodyTypeSlots(
    allocator: Allocator,
    decls: []const ctypes.Decl,
) ![]const ?ctypes.TypeDef {
    var slots = std.ArrayListUnmanaged(?ctypes.TypeDef).empty;
    for (decls) |decl| switch (decl) {
        .type => |ty| try slots.append(allocator, ty),
        .alias => |alias| {
            const sort: ctypes.Sort = switch (alias) {
                .instance_export => |ie| ie.sort,
                .outer => |outer| outer.sort,
            };
            if (sort == .type) try slots.append(allocator, null);
        },
        .import => |im| if (im.desc == .type) {
            try slots.append(allocator, null);
        },
        .@"export" => |ex| if (ex.desc == .type) {
            try slots.append(allocator, null);
        },
        .core_type => {},
    };
    return slots.toOwnedSlice(allocator);
}

fn testEmptyHoisted() types_import.Hoisted {
    return .{
        .types = &.{},
        .imports = &.{},
        .aliases = &.{},
        .section_order = &.{},
        .instances = &.{},
        .exports = &.{},
        .type_count = 0,
    };
}

test "adapter imported resources wire drop and reject new and rep during classification" {
    const source =
        \\package fixtures:adapter-resources@0.1.0;
        \\interface store { resource blob; }
        \\world adapter { import store; }
    ;
    const ct = try metadata_encode_for_test.encodeWorldFromSource(
        testing.allocator,
        source,
        "adapter",
    );
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const world = try decode.parse(ar, ct);
    const hoisted = try types_import.hoist(ar, world);
    const namespace = hoisted.instances[0].name;
    const one_i32 = [_]wtypes.ValType{.i32};

    const drop_imports = [_]core_imports.ImportEntry{.{
        .module_name = namespace,
        .field_name = "[resource-drop]blob",
        .kind = .func,
        .sig = .{ .params = &one_i32, .results = &.{} },
    }};
    const buckets = try classifyAdapterImports(
        ar,
        .{ .imports = &drop_imports, .exports = &.{} },
        world,
        hoisted,
    );
    try testing.expectEqual(@as(usize, 1), buckets.len);
    try testing.expectEqual(@as(usize, 1), buckets[0].resource_drops.len);
    try testing.expectEqualStrings("[resource-drop]blob", buckets[0].resource_drops[0].field_name);
    try testing.expectEqualStrings("blob", buckets[0].resource_drops[0].resource_name);
    try testing.expectEqual(@as(usize, 0), buckets[0].direct_funcs.len);
    try testing.expectEqual(@as(usize, 0), buckets[0].indirect_funcs.len);

    const cases = [_]struct {
        field_name: []const u8,
        expected: anyerror,
    }{
        .{
            .field_name = "[resource-new]blob",
            .expected = error.AdapterImportedResourceNewUnsupported,
        },
        .{
            .field_name = "[resource-rep]blob",
            .expected = error.AdapterImportedResourceRepUnsupported,
        },
    };
    for (cases) |case| {
        const imports = [_]core_imports.ImportEntry{.{
            .module_name = namespace,
            .field_name = case.field_name,
            .kind = .func,
            .sig = .{ .params = &one_i32, .results = &one_i32 },
        }};
        try testing.expectError(
            case.expected,
            classifyAdapterImports(
                ar,
                .{ .imports = &imports, .exports = &.{} },
                world,
                hoisted,
            ),
        );
    }
}

test "buildWorldTypeTables keeps core and component type index spaces separate" {
    const decls = [_]ctypes.Decl{
        .{ .core_type = .{ .func = .{ .params = &.{}, .results = &.{} } } },
        .{ .alias = .{ .instance_export = .{
            .sort = .type,
            .instance_idx = 4,
            .name = "item",
        } } },
    };
    const tables = try buildWorldTypeTables(testing.allocator, &decls);
    defer testing.allocator.free(tables.inst_qname);
    defer testing.allocator.free(tables.type_kind);

    try testing.expectEqual(@as(usize, 1), tables.type_kind.len);
    const target = try metadataAliasTarget(tables, .{ .outer = .{
        .sort = .type,
        .outer_count = 1,
        .idx = 0,
    } });
    try testing.expectEqual(@as(u32, 4), target.world_inst_idx);
    try testing.expectEqualStrings("item", target.name);
    try testing.expectEqual(@as(u32, 1), countInstBodyTypeSlots(&decls));
}

test "splice #328: imported resource new and rep are rejected before assembly" {
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithDirectResourceImports(a);
    defer a.free(embed_bytes);

    // The full fixture declares rep before new, so splice reports rep
    // rather than emitting an invalid canon resource.rep.
    try testing.expectError(
        error.EmbedImportedResourceRepUnsupported,
        splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1"),
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var owned = try core_imports.extract(a, embed_bytes);
    defer owned.deinit();
    const payload = (try decode.extractEncodedWorld(embed_bytes)) orelse
        return error.TestUnexpectedResult;
    const md = try metadata_decode.decode(ar, payload);

    // Exercise new independently so both invalid imported-resource
    // operations have a precise planning error.
    var new_import: ?core_imports.ImportEntry = null;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, test_fixtures.DIRECT_RESOURCE_NAMESPACE) and
            std.mem.eql(u8, im.field_name, test_fixtures.DIRECT_RESOURCE_NEW))
        {
            new_import = im;
            break;
        }
    }
    const only_new = [_]core_imports.ImportEntry{
        new_import orelse return error.TestUnexpectedResult,
    };
    try testing.expectError(
        error.EmbedImportedResourceNewUnsupported,
        buildEmbedExtraImportPlan(
            ar,
            .{ .imports = &only_new, .exports = &.{} },
            md,
            "wasi_snapshot_preview1",
            &.{},
            testEmptyHoisted(),
        ),
    );
}

test "splice #328: resource-only metadata import has no shim slot and keeps its full instance body" {
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithDirectResourceImportsVariant(
        a,
        .resource_only,
    );
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    const body = testImportInstanceBody(&comp, test_fixtures.DIRECT_RESOURCE_NAMESPACE) orelse
        return error.TestUnexpectedResult;
    var has_method = false;
    for (body) |decl| switch (decl) {
        .@"export" => |e| if (std.mem.eql(
            u8,
            e.name,
            test_fixtures.DIRECT_RESOURCE_METHOD,
        )) {
            has_method = true;
        },
        else => {},
    };
    try testing.expect(has_method);

    const bundle = testCoreBundleContaining(&comp, test_fixtures.DIRECT_RESOURCE_DROP) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), bundle.len);
    const contributor = comp.core_func_indexspace[bundle[0].sort_idx.idx];
    try testing.expect(contributor == .canon);
    try testing.expect(comp.canons[contributor.canon] == .resource_drop);
}

test "splice #328: cross-interface imported resource identity survives direct-import wiring" {
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticReactorAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes =
        try test_fixtures.buildSyntheticReactorEmbedWithCrossInterfaceImports(a);
    defer a.free(embed_bytes);

    var embed_owned = try core_imports.extract(a, embed_bytes);
    defer embed_owned.deinit();
    var core_provider_pos: ?usize = null;
    var core_consumer_pos: ?usize = null;
    for (embed_owned.interface.imports, 0..) |im, idx| {
        if (std.mem.eql(
            u8,
            im.module_name,
            test_fixtures.CROSS_INTERFACE_PROVIDER_NAMESPACE,
        ) and core_provider_pos == null) {
            core_provider_pos = idx;
        }
        if (std.mem.eql(
            u8,
            im.module_name,
            test_fixtures.CROSS_INTERFACE_CONSUMER_NAMESPACE,
        ) and core_consumer_pos == null) {
            core_consumer_pos = idx;
        }
    }
    try testing.expect(
        (core_consumer_pos orelse return error.TestUnexpectedResult) <
            (core_provider_pos orelse return error.TestUnexpectedResult),
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const payload = (try decode.extractEncodedWorld(embed_bytes)) orelse
        return error.TestUnexpectedResult;
    const md = try metadata_decode.decode(ar, payload);
    var metadata_provider_pos: ?usize = null;
    var metadata_consumer_pos: ?usize = null;
    for (md.externs, 0..) |ext, idx| {
        if (std.mem.eql(
            u8,
            ext.qualified_name,
            test_fixtures.CROSS_INTERFACE_PROVIDER_NAMESPACE,
        )) metadata_provider_pos = idx;
        if (std.mem.eql(
            u8,
            ext.qualified_name,
            test_fixtures.CROSS_INTERFACE_CONSUMER_NAMESPACE,
        )) metadata_consumer_pos = idx;
    }
    try testing.expect(
        (metadata_provider_pos orelse return error.TestUnexpectedResult) <
            (metadata_consumer_pos orelse return error.TestUnexpectedResult),
    );

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);
    const comp = try loader.load(out, ar);

    // The reactor path exports only the fixture's guest interface.
    try testing.expectEqual(@as(usize, 1), comp.exports.len);
    try testing.expectEqualStrings(
        test_fixtures.CROSS_INTERFACE_GUEST_NAMESPACE,
        comp.exports[0].name,
    );
    try testing.expect(comp.exports[0].desc == .instance);

    var provider_count: usize = 0;
    var consumer_count: usize = 0;
    var provider_import_pos: ?usize = null;
    var consumer_import_pos: ?usize = null;
    var provider_import_idx: ?u32 = null;
    for (comp.imports, 0..) |im, idx| {
        if (sameNamespaceIgnoringVersion(
            im.name,
            test_fixtures.CROSS_INTERFACE_PROVIDER_NAMESPACE,
        )) {
            try testing.expectEqualStrings(
                test_fixtures.CROSS_INTERFACE_PROVIDER_NAMESPACE,
                im.name,
            );
            try testing.expect(im.desc == .instance);
            provider_count += 1;
            provider_import_pos = idx;
            provider_import_idx = @intCast(idx);
        }
        if (sameNamespaceIgnoringVersion(
            im.name,
            test_fixtures.CROSS_INTERFACE_CONSUMER_NAMESPACE,
        )) {
            try testing.expectEqualStrings(
                test_fixtures.CROSS_INTERFACE_CONSUMER_NAMESPACE,
                im.name,
            );
            try testing.expect(im.desc == .instance);
            consumer_count += 1;
            consumer_import_pos = idx;
        }
    }
    try testing.expectEqual(@as(usize, 1), provider_count);
    try testing.expectEqual(@as(usize, 1), consumer_count);
    try testing.expect(
        (provider_import_pos orelse return error.TestUnexpectedResult) <
            (consumer_import_pos orelse return error.TestUnexpectedResult),
    );
    const provider_instance_idx = testImportedInstanceIndex(
        &comp,
        provider_import_idx orelse return error.TestUnexpectedResult,
    ) orelse return error.TestUnexpectedResult;

    const provider_body = testImportInstanceBody(
        &comp,
        test_fixtures.CROSS_INTERFACE_PROVIDER_NAMESPACE,
    ) orelse return error.TestUnexpectedResult;
    const consumer_body = testImportInstanceBody(
        &comp,
        test_fixtures.CROSS_INTERFACE_CONSUMER_NAMESPACE,
    ) orelse return error.TestUnexpectedResult;

    var provider_ctor_slot: ?u32 = null;
    var provider_method_slot: ?u32 = null;
    var provider_has_sub_resource = false;
    for (provider_body) |decl| switch (decl) {
        .@"export" => |ex| {
            try testing.expect(!std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_DROP,
            ));
            if (std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_RESOURCE,
            )) {
                try testing.expect(ex.desc == .type);
                try testing.expect(ex.desc.type == .sub_resource);
                provider_has_sub_resource = true;
            } else if (std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_CTOR,
            )) {
                try testing.expect(ex.desc == .func);
                provider_ctor_slot = ex.desc.func;
            } else if (std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_METHOD,
            )) {
                try testing.expect(ex.desc == .func);
                provider_method_slot = ex.desc.func;
            }
        },
        else => {},
    };
    try testing.expect(provider_has_sub_resource);

    const provider_slots = try testInstanceBodyTypeSlots(ar, provider_body);
    try testing.expectEqual(@as(usize, 7), provider_slots.len);
    const provider_own = provider_slots[1] orelse return error.TestUnexpectedResult;
    try testing.expect(provider_own == .val and provider_own.val == .own);
    try testing.expectEqual(@as(u32, 0), provider_own.val.own);
    const provider_borrow = provider_slots[3] orelse return error.TestUnexpectedResult;
    try testing.expect(provider_borrow == .val and provider_borrow.val == .borrow);
    try testing.expectEqual(@as(u32, 0), provider_borrow.val.borrow);
    const provider_list = provider_slots[4] orelse return error.TestUnexpectedResult;
    try testing.expect(provider_list == .list);
    try testing.expect(provider_list.list.element == .u8);
    const provider_result = provider_slots[5] orelse return error.TestUnexpectedResult;
    try testing.expect(provider_result == .result);
    try testing.expect(provider_result.result.ok.? == .string);
    try testing.expect(provider_result.result.err.? == .u32);

    const provider_ctor =
        provider_slots[provider_ctor_slot orelse return error.TestUnexpectedResult] orelse
        return error.TestUnexpectedResult;
    try testing.expect(provider_ctor == .func);
    try testing.expectEqual(@as(usize, 1), provider_ctor.func.params.len);
    try testing.expect(provider_ctor.func.params[0].type == .string);
    try testing.expect(provider_ctor.func.results == .unnamed);
    try testing.expect(provider_ctor.func.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 1), provider_ctor.func.results.unnamed.type_idx);

    const provider_method =
        provider_slots[provider_method_slot orelse return error.TestUnexpectedResult] orelse
        return error.TestUnexpectedResult;
    try testing.expect(provider_method == .func);
    try testing.expectEqual(@as(usize, 2), provider_method.func.params.len);
    try testing.expect(provider_method.func.params[0].type == .type_idx);
    try testing.expectEqual(@as(u32, 3), provider_method.func.params[0].type.type_idx);
    try testing.expect(provider_method.func.params[1].type == .type_idx);
    try testing.expectEqual(@as(u32, 4), provider_method.func.params[1].type.type_idx);
    try testing.expect(provider_method.func.results == .unnamed);
    try testing.expect(provider_method.func.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 5), provider_method.func.results.unnamed.type_idx);

    var consumer_outer: ?ctypes.Alias = null;
    var consumer_func_slot: ?u32 = null;
    var consumer_resource_eq = false;
    for (consumer_body) |decl| switch (decl) {
        .alias => |alias| consumer_outer = alias,
        .@"export" => |ex| {
            try testing.expect(!std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_DROP,
            ));
            if (std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_RESOURCE,
            )) {
                try testing.expect(ex.desc == .type);
                try testing.expect(ex.desc.type == .eq);
                try testing.expectEqual(@as(u32, 0), ex.desc.type.eq);
                consumer_resource_eq = true;
            } else if (std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_FUNC,
            )) {
                try testing.expect(ex.desc == .func);
                consumer_func_slot = ex.desc.func;
            }
        },
        else => {},
    };
    try testing.expect(consumer_resource_eq);
    const outer_alias = consumer_outer orelse return error.TestUnexpectedResult;
    try testing.expect(outer_alias == .outer);
    try testing.expect(outer_alias.outer.sort == .type);
    try testing.expectEqual(@as(u32, 1), outer_alias.outer.outer_count);
    try testExpectImportedResourceAlias(
        &comp,
        outer_alias.outer.idx,
        provider_instance_idx,
        test_fixtures.CROSS_INTERFACE_RESOURCE,
    );

    const consumer_slots = try testInstanceBodyTypeSlots(ar, consumer_body);
    try testing.expectEqual(@as(usize, 6), consumer_slots.len);
    const consumer_borrow = consumer_slots[2] orelse return error.TestUnexpectedResult;
    try testing.expect(consumer_borrow == .val and consumer_borrow.val == .borrow);
    try testing.expectEqual(@as(u32, 1), consumer_borrow.val.borrow);
    const consumer_list = consumer_slots[3] orelse return error.TestUnexpectedResult;
    try testing.expect(consumer_list == .list);
    try testing.expect(consumer_list.list.element == .u8);
    const consumer_result = consumer_slots[4] orelse return error.TestUnexpectedResult;
    try testing.expect(consumer_result == .result);
    try testing.expect(consumer_result.result.ok.? == .type_idx);
    try testing.expectEqual(@as(u32, 3), consumer_result.result.ok.?.type_idx);
    try testing.expect(consumer_result.result.err.? == .string);
    const consumer_func =
        consumer_slots[consumer_func_slot orelse return error.TestUnexpectedResult] orelse
        return error.TestUnexpectedResult;
    try testing.expect(consumer_func == .func);
    try testing.expectEqual(@as(usize, 2), consumer_func.func.params.len);
    try testing.expect(consumer_func.func.params[0].type == .type_idx);
    try testing.expectEqual(@as(u32, 2), consumer_func.func.params[0].type.type_idx);
    try testing.expect(consumer_func.func.params[1].type == .string);
    try testing.expect(consumer_func.func.results == .unnamed);
    try testing.expect(consumer_func.func.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 4), consumer_func.func.results.unnamed.type_idx);

    // Resource drops are core glue only: no component instance type,
    // component inline instance, top-level export, or component-func
    // alias advertises the synthetic field.
    for (comp.types) |ty| if (ty == .instance) {
        for (ty.instance.decls) |decl| switch (decl) {
            .@"export" => |ex| try testing.expect(!std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_DROP,
            )),
            else => {},
        };
    };
    for (comp.instances) |instance| switch (instance) {
        .exports => |exports| for (exports) |ex| {
            try testing.expect(!std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_DROP,
            ));
        },
        else => {},
    };
    for (comp.exports) |ex| {
        try testing.expect(!std.mem.eql(
            u8,
            ex.name,
            test_fixtures.CROSS_INTERFACE_DROP,
        ));
    }
    for (comp.aliases) |alias| switch (alias) {
        .instance_export => |ie| if (ie.sort == .func) {
            try testing.expect(!std.mem.eql(
                u8,
                ie.name,
                test_fixtures.CROSS_INTERFACE_DROP,
            ));
        },
        else => {},
    };

    var lower_count: usize = 0;
    var resource_drop_count: usize = 0;
    var resource_new_count: usize = 0;
    var resource_rep_count: usize = 0;
    var drop_type_idx: ?u32 = null;
    for (comp.canons) |canon| switch (canon) {
        .lower => lower_count += 1,
        .resource_drop => |idx| {
            resource_drop_count += 1;
            drop_type_idx = idx;
        },
        .resource_new => resource_new_count += 1,
        .resource_rep => resource_rep_count += 1,
        else => {},
    };
    // One adapter lower plus the three ordinary direct imports. The
    // resource drop consumes neither a fourth direct-import lower nor
    // a fifth shim slot.
    try testing.expectEqual(@as(usize, 4), lower_count);
    try testing.expectEqual(@as(usize, 1), resource_drop_count);
    try testing.expectEqual(@as(usize, 0), resource_new_count);
    try testing.expectEqual(@as(usize, 0), resource_rep_count);
    try testExpectImportedResourceAlias(
        &comp,
        drop_type_idx orelse return error.TestUnexpectedResult,
        provider_instance_idx,
        test_fixtures.CROSS_INTERFACE_RESOURCE,
    );

    var drop_core_export_count: usize = 0;
    for (comp.core_instances) |instance| switch (instance) {
        .exports => |exports| for (exports) |ex| {
            if (!std.mem.eql(
                u8,
                ex.name,
                test_fixtures.CROSS_INTERFACE_DROP,
            )) continue;
            drop_core_export_count += 1;
            try testing.expect(ex.sort_idx.sort == .func);
            const contributor = comp.core_func_indexspace[ex.sort_idx.idx];
            try testing.expect(contributor == .canon);
            const canon = comp.canons[contributor.canon];
            try testing.expect(canon == .resource_drop);
            try testing.expectEqual(drop_type_idx.?, canon.resource_drop);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), drop_core_export_count);

    var shim_module_count: usize = 0;
    var shim_func_slot_count: usize = 0;
    for (comp.core_modules) |module| {
        var owned = try core_imports.extract(a, module.data);
        defer owned.deinit();
        const table_export = owned.interface.findExport("$imports") orelse continue;
        try testing.expect(table_export.kind == .table);
        shim_module_count += 1;
        for (owned.interface.exports) |ex| {
            if (ex.kind != .func) continue;
            _ = std.fmt.parseUnsigned(u32, ex.name, 10) catch continue;
            shim_func_slot_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), shim_module_count);
    try testing.expectEqual(@as(usize, 4), shim_func_slot_count);
}

test "splice #328: metadata inconsistencies are explicit hard failures" {
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);

    const cases = [_]struct {
        variant: test_fixtures.DirectResourceEmbedVariant,
        expected: anyerror,
    }{
        .{ .variant = .version_mismatch, .expected = error.EmbedMetadataVersionMismatch },
        .{ .variant = .unknown_resource, .expected = error.EmbedMetadataResourceNotFound },
        .{ .variant = .unknown_function, .expected = error.EmbedMetadataFunctionNotFound },
        .{
            .variant = .malformed_intrinsic_signature,
            .expected = error.EmbedResourceIntrinsicSignatureMismatch,
        },
    };
    for (cases) |case| {
        const embed_bytes = try test_fixtures.buildSyntheticEmbedWithDirectResourceImportsVariant(
            a,
            case.variant,
        );
        defer a.free(embed_bytes);
        try testing.expectError(
            case.expected,
            splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1"),
        );
    }
}

test "splice #328: ordinary metadata-backed imports are planned and ABI checked" {
    const a = testing.allocator;
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithDirectResourceImports(a);
    defer a.free(embed_bytes);

    var owned = try core_imports.extract(a, embed_bytes);
    defer owned.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const imports = try ar.dupe(core_imports.ImportEntry, owned.interface.imports);
    const payload = (try decode.extractEncodedWorld(embed_bytes)) orelse
        return error.TestUnexpectedResult;
    const md = try metadata_decode.decode(ar, payload);

    var ordinary = std.ArrayListUnmanaged(core_imports.ImportEntry).empty;
    for (imports) |im| {
        if (std.mem.eql(u8, im.module_name, test_fixtures.DIRECT_RESOURCE_NAMESPACE) and
            resource_intrinsics.classify(im.field_name) == null)
        {
            try ordinary.append(ar, im);
        }
    }
    const plan = try buildEmbedExtraImportPlan(
        ar,
        .{ .imports = ordinary.items, .exports = owned.interface.exports },
        md,
        "wasi_snapshot_preview1",
        &.{},
        testEmptyHoisted(),
    );
    try testing.expectEqual(@as(usize, 3), plan.slot_infos.len);
    try testing.expect(plan.namespaces.len > 0);

    for (imports) |*im| {
        if (std.mem.eql(u8, im.module_name, test_fixtures.DIRECT_RESOURCE_NAMESPACE) and
            std.mem.eql(u8, im.field_name, test_fixtures.DIRECT_RESOURCE_FUNC))
        {
            // Metadata says `ping: func() -> u32`; deliberately give
            // the flattened core import an extra parameter.
            im.sig = .{ .params = &.{.i32}, .results = &.{.i32} };
        }
    }
    try testing.expectError(
        error.EmbedImportSignatureMismatch,
        buildEmbedExtraImportPlan(
            ar,
            .{ .imports = imports, .exports = owned.interface.exports },
            md,
            "wasi_snapshot_preview1",
            &.{},
            testEmptyHoisted(),
        ),
    );
}

test "splice #328: resource names and duplicate intrinsic fields are namespace scoped" {
    const source =
        \\package fixtures:twins@0.1.0;
        \\interface left { resource item; }
        \\interface right { resource item; }
        \\world twins { import left; import right; }
    ;
    const ct = try metadata_encode_for_test.encodeWorldFromSource(
        testing.allocator,
        source,
        "twins",
    );
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const md = try metadata_decode.decode(ar, ct);
    const one_i32 = [_]wtypes.ValType{.i32};
    const imports = [_]core_imports.ImportEntry{
        .{
            .module_name = "fixtures:twins/left@0.1.0",
            .field_name = "[resource-drop]item",
            .kind = .func,
            .sig = .{ .params = &one_i32, .results = &.{} },
        },
        // Exact duplicate: one satisfying core export is sufficient.
        .{
            .module_name = "fixtures:twins/left@0.1.0",
            .field_name = "[resource-drop]item",
            .kind = .func,
            .sig = .{ .params = &one_i32, .results = &.{} },
        },
        .{
            .module_name = "fixtures:twins/right@0.1.0",
            .field_name = "[resource-drop]item",
            .kind = .func,
            .sig = .{ .params = &one_i32, .results = &.{} },
        },
    };
    const plan = try buildEmbedExtraImportPlan(
        ar,
        .{ .imports = &imports, .exports = &.{} },
        md,
        "wasi_snapshot_preview1",
        &.{},
        testEmptyHoisted(),
    );
    try testing.expectEqual(@as(usize, 2), plan.namespaces.len);
    try testing.expectEqual(@as(usize, 0), plan.slot_infos.len);
    try testing.expectEqual(@as(usize, 1), plan.namespaces[0].fields.len);
    try testing.expectEqual(@as(usize, 1), plan.namespaces[1].fields.len);

    var conflicting = imports;
    conflicting[1].sig = .{ .params = &one_i32, .results = &one_i32 };
    try testing.expectError(
        error.EmbedResourceIntrinsicSignatureMismatch,
        buildEmbedExtraImportPlan(
            ar,
            .{ .imports = &conflicting, .exports = &.{} },
            md,
            "wasi_snapshot_preview1",
            &.{},
            testEmptyHoisted(),
        ),
    );

    try testing.expectError(
        error.EmbedResourceMetadataRequired,
        buildEmbedExtraImportPlan(
            ar,
            .{ .imports = imports[0..1], .exports = &.{} },
            null,
            "wasi_snapshot_preview1",
            &.{},
            testEmptyHoisted(),
        ),
    );
}

test "splice #328: metadata-free primitive embed-extra compatibility is unchanged" {
    const a = testing.allocator;
    const adapter_bytes = try test_fixtures.buildSyntheticAdapter(a);
    defer a.free(adapter_bytes);
    const embed_bytes = try test_fixtures.buildSyntheticEmbedWithDirectResourceImportsVariant(
        a,
        .metadata_free_primitive,
    );
    defer a.free(embed_bytes);

    const out = try splice(a, embed_bytes, adapter_bytes, "wasi_snapshot_preview1");
    defer a.free(out);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const comp = try loader.load(out, arena.allocator());

    const body = testImportInstanceBody(&comp, test_fixtures.DIRECT_RESOURCE_NAMESPACE) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), body.len);
    try testing.expect(body[0] == .type and body[0].type == .func);
    try testing.expect(body[0].type.func.results == .unnamed);
    try testing.expect(body[0].type.func.results.unnamed == .u32);
    try testing.expect(body[1] == .@"export");
    try testing.expectEqualStrings(test_fixtures.DIRECT_RESOURCE_FUNC, body[1].@"export".name);
}
