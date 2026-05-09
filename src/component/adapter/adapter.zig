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

pub const SpliceError = error{
    OutOfMemory,
    NotCoreWasm,
    InvalidAdapterCore,
    MissingEncodedWorld,
    UnsupportedAdapterShape,
    AdapterMissingRunExport,
    AdapterMissingPreview1Export,
    EmbedMissingRequiredExport,
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
} || writer.EncodeError;

/// Splice a preview1 embed and an adapter into a wrapping component.
/// Caller frees the returned slice via `gpa`.
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
    const live_methods_by_namespace = try collectLiveMethodsByNamespace(a, pristine_iface.interface);
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

    // The embed may carry its own `component-type` custom section
    // (produced by `wasm-tools component embed --world …`). When
    // present we use its declared FuncTypes to preserve original
    // param names on lifted top-level imports. Absent (e.g. for a
    // raw zig-hello core wasm), we synthesize p0/p1 names from the
    // core sigs alone.
    const embed_world: ?decode.AdapterWorld = blk: {
        const ct = decode.extractEncodedWorld(embed_bytes) catch break :blk null;
        const payload = ct orelse break :blk null;
        break :blk decode.parse(a, payload) catch null;
    };

    const preview1_slots = try collectPreview1Slots(a, embed_owned.interface, adapter_name);
    const buckets = try classifyAdapterImports(a, adapter_owned.interface, world, hoisted);
    const indirect_slots = try collectIndirectSlots(a, buckets);

    var all_slots = try a.alloc(shim.Slot, preview1_slots.len + indirect_slots.len);
    for (preview1_slots, 0..) |p1, i| {
        all_slots[i] = .{ .params = p1.params, .results = p1.results };
    }
    @memcpy(all_slots[preview1_slots.len..], indirect_slots);

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
        .embed_world = embed_world,
        .hoisted = hoisted,
        .embed_iface = embed_owned.interface,
        .adapter_iface = adapter_owned.interface,
        .preview1_slots = preview1_slots,
        .buckets = buckets,
    });
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

const ResourceDrop = struct {
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
    resource_drops: []ResourceDrop,
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
        var rd_list = std.ArrayListUnmanaged(ResourceDrop).empty;
        var ind_list = std.ArrayListUnmanaged(IndirectFunc).empty;
        var dir_list = std.ArrayListUnmanaged(DirectFunc).empty;

        const slot = findInstanceSlot(hoisted, bn) orelse return error.UnsupportedAdapterShape;

        for (adapter_iface.imports) |im| {
            if (im.kind != .func) continue;
            if (!std.mem.eql(u8, im.module_name, bn)) continue;
            if (std.mem.startsWith(u8, im.field_name, "[resource-drop]")) {
                const rname = im.field_name["[resource-drop]".len..];
                try rd_list.append(arena, .{ .resource_name = rname });
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
            .resource_drops = try rd_list.toOwnedSlice(arena),
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
    embed_world: ?decode.AdapterWorld,
    hoisted: types_import.Hoisted,
    embed_iface: core_imports.CoreInterface,
    adapter_iface: core_imports.CoreInterface,
    preview1_slots: []const Preview1Slot,
    buckets: []NamespaceBucket,
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
            .lower, .resource_drop, .resource_new, .resource_rep => {
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

    // ── Step 3: core modules (main=0, adapter=1, shim=2, fixup=3) ─────
    const main_module_idx = try b.addCoreModule(.{ .data = in.embed_bytes });
    const adapter_module_idx = try b.addCoreModule(.{ .data = in.adapter_bytes });
    const shim_module_idx = try b.addCoreModule(.{ .data = in.shim_bytes });
    const fixup_module_idx = try b.addCoreModule(.{ .data = in.fixup_bytes });

    // ── Step 4: shim instance ────────────────────────────────────────
    const shim_inst = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = shim_module_idx,
        .args = &.{},
    } });

    // ── Step 5: preview1 inline-export instance for embed ────────────
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

    // ── Step 5b: lift non-WASI embed imports to component imports ─────
    // The embed may import core funcs from namespaces beyond the
    // WASI adapter (e.g. `docs:adder/add@0.1.0` for the calculator
    // fixture). These don't go through the adapter — instead, lift
    // each module-level group to a top-level component instance
    // import, alias each func, canon-lower it, and bundle into an
    // inline-export instance the embed can consume directly.
    const embed_extra_args = try buildEmbedExtraImports(&b, a, in);

    // ── Step 6: instantiate main with wasi_snapshot_preview1 + extras ─
    const main_args = try a.alloc(ctypes.CoreInstantiateArg, 1 + embed_extra_args.len);
    main_args[0] = .{ .name = in.adapter_name, .instance_idx = preview1_inst };
    for (embed_extra_args, 0..) |ea, i| {
        main_args[1 + i] = .{ .name = ea.name, .instance_idx = ea.inst_idx };
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

    // The adapter imports `__main_module__.<entry>` for whatever the
    // main module exports as its entry point. zig-hello / Rust's
    // wasip1 builds export `_start`. Pass through every export the
    // embed has of name we can find — but in practice this is the
    // single `_start` symbol. If your embed uses a different name,
    // expose all exports we can recognize; the adapter ignores
    // anything it doesn't import.
    const main_module_inst = blk: {
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
            fallback_inst = try b.addCoreInstance(.{ .instantiate = .{
                .module_idx = fallback_module_idx,
                .args = &.{},
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
    };

    // ── Step 8: per-namespace bundles ────────────────────────────────
    var bucket_inst_idx = try a.alloc(u32, in.buckets.len);
    for (in.buckets, 0..) |*bucket, bi| {
        var bundle = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;

        for (bucket.resource_drops) |rd| {
            const t_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .type,
                .instance_idx = bucket.instance_idx,
                .name = rd.resource_name,
            } });
            const cf_idx = try b.addCanon(.{ .resource_drop = t_idx });
            const ename = try std.fmt.allocPrint(a, "[resource-drop]{s}", .{rd.resource_name});
            try bundle.append(a, .{
                .name = ename,
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
            const slot_total: u32 = @as(u32, @intCast(in.preview1_slots.len)) + idf.slot_idx;
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
    try adapter_args.append(a, .{ .name = "__main_module__", .instance_idx = main_module_inst });
    for (in.buckets, 0..) |bk, bi| {
        try adapter_args.append(a, .{ .name = bk.name, .instance_idx = bucket_inst_idx[bi] });
    }
    const adapter_inst = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = adapter_module_idx,
        .args = try adapter_args.toOwnedSlice(a),
    } });

    // ── Step 10: fixup bundle ────────────────────────────────────────
    // Realloc opt source if any indirect canon-lower needs it.
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

    // Funcs P..P+I-1: canon lower(memory, [realloc], [string-encoding])
    // of each indirect adapter wasi import.
    {
        var indirect_idx: u32 = 0;
        for (in.buckets) |bk| {
            for (bk.indirect_funcs) |idf| {
                const f_idx = try b.addAlias(.{ .instance_export = .{
                    .sort = .func,
                    .instance_idx = bk.instance_idx,
                    .name = idf.name,
                } });
                const opts = try buildCanonLowerOpts(a, idf.cls.opts, memory_idx, realloc_idx);
                const cf_idx = try b.addCanon(.{ .lower = .{
                    .func_idx = f_idx,
                    .opts = opts,
                } });
                const slot_total: u32 = @as(u32, @intCast(in.preview1_slots.len)) + indirect_idx;
                const slot_name = try std.fmt.allocPrint(a, "{d}", .{slot_total});
                try fixup_inline.append(a, .{
                    .name = slot_name,
                    .sort_idx = .{ .sort = .func, .idx = cf_idx },
                });
                indirect_idx += 1;
            }
        }
    }

    const fixup_bundle_inst = try b.addCoreInstance(.{ .exports = try fixup_inline.toOwnedSlice(a) });

    // Instantiate fixup with bundle as `""` namespace.
    const fixup_args = try a.alloc(ctypes.CoreInstantiateArg, 1);
    fixup_args[0] = .{ .name = "", .instance_idx = fixup_bundle_inst };
    _ = try b.addCoreInstance(.{ .instantiate = .{
        .module_idx = fixup_module_idx,
        .args = fixup_args,
    } });

    // ── Step 11: canon lift of wasi:cli/run@<ver>#run ────────────────
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

    // ── Step 12: inline sub-component wrapping `run` ────────────────
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

    // ── Step 13: top-level export ────────────────────────────────────
    try b.addExport(.{
        .name = run_ie.qualified_name,
        .desc = .{ .instance = run_ie.body_type_idx },
        .sort_idx = .{ .sort = .instance, .idx = wrap_inst_idx },
    });

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

fn buildCanonLowerOpts(
    arena: Allocator,
    o: abi.FuncOpts,
    memory_core_idx: u32,
    realloc_core_idx: u32,
) SpliceError![]const ctypes.CanonOpt {
    var n: usize = 0;
    if (o.memory) n += 1;
    if (o.realloc) n += 1;
    if (o.string_encoding) n += 1;

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

/// For each non-WASI-adapter module the embed imports, synthesize a
/// top-level component instance import (with primitive-typed funcs
/// derived from the core wasm sigs), canon-lower each func, and
/// bundle the lowered funcs into a core instance the embed can
/// consume. Returns one `EmbedExtraArg` per such module.
///
/// Works for primitive-only signatures (i32/i64/f32/f64). Funcs
/// that need `string`/`list`/records cannot be expressed through
/// this synthesis; for those the user should `wasm-tools component
/// embed --world` first to embed a richer component-type and then
/// use the no-adapter path.
fn buildEmbedExtraImports(b: *Builder, a: Allocator, in: Inputs) SpliceError![]const EmbedExtraArg {
    // Collect distinct namespaces in declaration order, excluding
    // the adapter and the env / __main_module__ "alias" namespaces.
    var ns_names = std.ArrayListUnmanaged([]const u8).empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(a);

    for (in.embed_iface.imports) |im| {
        if (im.kind != .func) continue;
        if (std.mem.eql(u8, im.module_name, in.adapter_name)) continue;
        if (std.mem.eql(u8, im.module_name, "env")) continue;
        if (std.mem.eql(u8, im.module_name, "__main_module__")) continue;
        const gop = try seen.getOrPut(a, im.module_name);
        if (!gop.found_existing) try ns_names.append(a, im.module_name);
    }

    if (ns_names.items.len == 0) return &.{};

    var out = std.ArrayListUnmanaged(EmbedExtraArg).empty;

    for (ns_names.items) |ns| {
        // Gather funcs in this namespace.
        var funcs = std.ArrayListUnmanaged(struct {
            name: []const u8,
            sig: core_imports.FuncSig,
        }).empty;
        for (in.embed_iface.imports) |im| {
            if (im.kind != .func) continue;
            if (!std.mem.eql(u8, im.module_name, ns)) continue;
            const sig = im.sig orelse continue;
            try funcs.append(a, .{ .name = im.field_name, .sig = sig });
        }
        if (funcs.items.len == 0) continue;

        // Build the instance type: one (export "<name>" (func F))
        // per func, with each func having a fresh component-level
        // FuncType. Prefer pulling the FuncType verbatim from the
        // embed's component-type if available (preserves original
        // param names + non-primitive types). Otherwise synthesize
        // a p0/p1-named primitive sig from the core import sig.
        var inst_decls = std.ArrayListUnmanaged(ctypes.Decl).empty;
        var local_type_idx: u32 = 0;
        for (funcs.items) |f| {
            const ft: ctypes.FuncType = lookupEmbedFuncType(in.embed_world, ns, f.name) orelse blk_ft: {
                const params = try a.alloc(ctypes.NamedValType, f.sig.params.len);
                for (f.sig.params, 0..) |p, pi| {
                    const pname = try std.fmt.allocPrint(a, "p{d}", .{pi});
                    params[pi] = .{ .name = pname, .type = coreToCompValType(p) };
                }
                const results: ctypes.FuncType.ResultList = if (f.sig.results.len == 0) .none else blk: {
                    if (f.sig.results.len == 1) {
                        break :blk .{ .unnamed = coreToCompValType(f.sig.results[0]) };
                    }
                    const named = try a.alloc(ctypes.NamedValType, f.sig.results.len);
                    for (f.sig.results, 0..) |r, ri| {
                        const rname = try std.fmt.allocPrint(a, "r{d}", .{ri});
                        named[ri] = .{ .name = rname, .type = coreToCompValType(r) };
                    }
                    break :blk .{ .named = named };
                };
                break :blk_ft .{ .params = params, .results = results };
            };

            try inst_decls.append(a, .{ .type = .{ .func = ft } });
            const ftype_idx = local_type_idx;
            local_type_idx += 1;
            try inst_decls.append(a, .{ .@"export" = .{
                .name = f.name,
                .desc = .{ .func = ftype_idx },
            } });
        }

        const inst_type_idx = try b.addType(.{ .instance = .{
            .decls = try inst_decls.toOwnedSlice(a),
        } });
        const imp_inst_idx = try b.addImport(.{
            .name = ns,
            .desc = .{ .instance = inst_type_idx },
        });

        // For each func: alias from the imported instance, canon
        // lower (no opts — primitives only).
        var inline_exps = std.ArrayListUnmanaged(ctypes.CoreInlineExport).empty;
        for (funcs.items) |f| {
            const fn_idx = try b.addAlias(.{ .instance_export = .{
                .sort = .func,
                .instance_idx = imp_inst_idx,
                .name = f.name,
            } });
            const cf_idx = try b.addCanon(.{ .lower = .{
                .func_idx = fn_idx,
                .opts = &.{},
            } });
            try inline_exps.append(a, .{
                .name = f.name,
                .sort_idx = .{ .sort = .func, .idx = cf_idx },
            });
        }

        const bundle_inst = try b.addCoreInstance(.{ .exports = try inline_exps.toOwnedSlice(a) });
        try out.append(a, .{ .name = ns, .inst_idx = bundle_inst });
    }

    return out.toOwnedSlice(a);
}

fn coreToCompValType(v: wtypes.ValType) ctypes.ValType {
    return switch (v) {
        .i32 => .u32,
        .i64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
        else => .u32,
    };
}

/// Walk the embed's world body to find an exported func type by
/// `(namespace, func_name)`. Returns null if not present (e.g. the
/// embed has no `component-type` section, the namespace isn't an
/// instance import, or the export wasn't found).
fn lookupEmbedFuncType(maybe_world: ?decode.AdapterWorld, ns: []const u8, func_name: []const u8) ?ctypes.FuncType {
    const w = maybe_world orelse return null;
    for (w.imports) |im| {
        if (!std.mem.eql(u8, im.name, ns)) continue;
        const inst_td = resolveTypeIdxAtTopLevel(w.body_decls, im.body_type_idx) orelse return null;
        if (inst_td != .instance) return null;
        for (inst_td.instance.decls) |d| switch (d) {
            .@"export" => |e| {
                if (e.desc != .func) continue;
                if (!std.mem.eql(u8, e.name, func_name)) continue;
                const ftd = resolveTypeIdxAtTopLevel(inst_td.instance.decls, e.desc.func) orelse return null;
                if (ftd != .func) return null;
                return ftd.func;
            },
            else => {},
        };
        return null;
    }
    return null;
}

/// Walk a decl list and return the TypeDef at the given indexspace
/// position, following `(eq …)` aliases inside the same scope.
/// Used at "top level" (a world body or instance body) where there
/// is no outer alias chain to follow.
fn resolveTypeIdxAtTopLevel(decls: []const ctypes.Decl, target: u32) ?ctypes.TypeDef {
    var cursor: u32 = 0;
    for (decls) |d| switch (d) {
        .type => |td| {
            if (cursor == target) return td;
            cursor += 1;
        },
        .core_type => cursor += 1,
        .alias => |al| {
            const sort: ctypes.Sort = switch (al) {
                .instance_export => |ie| ie.sort,
                .outer => |o| o.sort,
            };
            if (sort == .type) {
                if (cursor == target) {
                    return switch (al) {
                        .outer => |o| if (o.sort == .type)
                            resolveTypeIdxAtTopLevel(decls, o.idx)
                        else
                            null,
                        else => null,
                    };
                }
                cursor += 1;
            }
        },
        .@"export" => |e| {
            if (e.desc == .type) {
                if (cursor == target) {
                    return switch (e.desc.type) {
                        .eq => |i| resolveTypeIdxAtTopLevel(decls, i),
                        .sub_resource => ctypes.TypeDef{ .resource = .{} },
                    };
                }
                cursor += 1;
            }
        },
        else => {},
    };
    return null;
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

    // code section: each body = `unreachable; end`
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(arena, &body, @intCast(sig_for_export.items.len));
        for (sig_for_export.items) |_| {
            // body: locals_count=0 (LEB 0), unreachable (0x00), end (0x0b)
            const fb = [_]u8{ 0x00, 0x00, 0x0b };
            try writeU32Leb(arena, &body, @intCast(fb.len));
            try body.appendSlice(arena, &fb);
        }
        try writeSection(arena, &out, 0x0a, body.items);
    }

    return out.toOwnedSlice(arena);
}

fn sigEql(a: core_imports.FuncSig, b: core_imports.FuncSig) bool {
    return std.mem.eql(wtypes.ValType, a.params, b.params) and
        std.mem.eql(wtypes.ValType, a.results, b.results);
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
