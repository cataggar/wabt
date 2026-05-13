//! Decode a `component-type:<world>` custom section payload back
//! into a structured world description.
//!
//! Inverse of `metadata_encode.zig`. Walks the embedded component AST
//! produced by the loader and recovers, for each world extern:
//!
//!   * whether it's an import or export,
//!   * the qualified interface name (`<ns>:<pkg>/<iface>[@<ver>]`),
//!   * the list of funcs in the interface, with their full
//!     component-level signatures.
//!
//! MVP-scoped: the on-wire shape recognised is
//! (component-type wrapper → world component-type → instance-type
//! per interface → func type per func). Decls the encoder emits to
//! surface cross-interface `use` clauses (world-body
//! `alias instance-export`s; interface-body
//! `alias outer (type 1 K)` + `export "T" (type (eq L))` mirror
//! pairs) and to introduce resources / compound typedefs
//! (`export "R" (type (sub resource))`, `(type record/variant/…)`
//! + `export "N" (type (eq L))`) are walked past transparently —
//! they don't surface as world externs or as funcs, but their
//! presence no longer trips `error.UnsupportedShape`. Resource
//! handles inside func signatures are returned as their raw
//! `ValType.own` / `.borrow` type-index references; resolving
//! those back to qualified names is a follow-up.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ctypes = @import("../types.zig");
const loader = @import("../loader.zig");

pub const DecodeError = error{
    InvalidComponentType,
    UnsupportedShape,
    OutOfMemory,
} || loader.LoadError;

pub const FuncRef = struct {
    /// Func name within the interface (e.g. `add`).
    name: []const u8,
    /// Component-level signature. `ValType.type_idx` / `.own` /
    /// `.borrow` payloads reference slots in the enclosing
    /// `WorldExtern.type_slots`. Resource-handle references are
    /// resolved during decode (resolved to `.own` / `.borrow` at
    /// the resource binding's slot); compound-type references
    /// stay as `.type_idx` pointing at a `TypeSlot.typedef` entry.
    sig: ctypes.FuncType,
};

/// Per-slot view of an interface body's type-index space.
///
/// `decodeInterfaceBody` walks the body in declaration order and
/// allocates one `TypeSlot` per type-allocating decl. The on-wire
/// type-index used in `ValType.type_idx` / `.own` / `.borrow`
/// payloads inside the captured func sigs maps directly into this
/// slice.
pub const TypeSlot = union(enum) {
    /// `.alias outer (type N K)` — points at slot `K` in an outer
    /// scope (typically the world body). Anonymous in the
    /// interface scope.
    alias_outer: u32,
    /// `.alias instance-export` (sort=type) — references a named
    /// type export of an instance in the outer scope.
    alias_instance_export: struct {
        instance_idx: u32,
        name: []const u8,
    },
    /// `.@"export"` decl with `.type.eq{target}` desc — binds
    /// `name` to a slot that mirrors `target`. Used for
    /// `use`-imported types and named compound typedefs.
    export_eq: struct { name: []const u8, target: u32 },
    /// `.@"export"` decl with `.type.sub_resource` desc — local
    /// `resource R {}` declaration. Carries the resource's WIT
    /// name.
    sub_resource: []const u8,
    /// Hoisted value-type def (`.type = .val …`). The encoder
    /// emits these for `own<R>` / `borrow<R>` references and for
    /// bare primitive type-defs inside an interface body.
    val: ctypes.ValType,
    /// Any other typedef body — record / variant / enum / flags /
    /// option / result / list / tuple / resource / func /
    /// component / instance. Stored verbatim so consumers can
    /// inspect compound-type shapes themselves.
    typedef: ctypes.TypeDef,
};

pub const WorldExtern = struct {
    is_export: bool,
    /// Qualified name on the wire (e.g. `docs:adder/add@0.1.0`).
    qualified_name: []const u8,
    /// Interface-body type-index space, in slot-allocation order.
    /// `ValType.type_idx` / `.own` / `.borrow` payloads inside
    /// `funcs[].sig` reference indices into this slice.
    type_slots: []const TypeSlot,
    /// Funcs declared by the interface this extern references.
    funcs: []const FuncRef,
    /// Raw on-wire instance-type body decls. 1:1 with `type_slots`
    /// for the type-allocating decls (every `.type`/`.alias`/`.@"export" type`
    /// decl bumps the body-local type-index space by one) plus the
    /// `.@"export" func` decls that name the captured funcs. Useful
    /// when a consumer needs to transplant the body verbatim into a
    /// new component or build a typed view over it (e.g. the
    /// canonical-ABI `flatten` pass in `src/component/adapter/abi.zig`
    /// resolves `.type_idx` refs against exactly this slice).
    ///
    /// Cross-iface `alias outer` and `alias instance_export` decls
    /// inside this body reference scopes that exist in the encoded
    /// `component-type` payload's world body; consumers transplanting
    /// the body elsewhere must rebase those refs (or restrict
    /// themselves to bodies that don't contain them).
    inst_decls: []const ctypes.Decl,
};

pub const DecodedWorld = struct {
    /// Bare world name, e.g. `adder`.
    name: []const u8,
    /// Qualified world name on the wire, e.g. `docs:adder/adder@0.1.0`.
    qualified_name: []const u8,
    /// All world externs (imports and exports), in declaration order.
    externs: []const WorldExtern,
    /// Raw on-wire world body decls. The outer scope that
    /// `WorldExtern.inst_decls`'s `alias outer (type 1 K)` references
    /// resolve against. Lets consumers transplanting an interface
    /// body into a new component rebase those cross-iface refs
    /// (per `cataggar/wabt#206`).
    ///
    /// In declaration order: alternating `.type (instance …)` slots,
    /// `.import` / `.export` decls (one per `WorldExtern`), and
    /// `.alias instance_export sort=type` decls the encoder splices
    /// in for `use src.{T};` clauses.
    world_decls: []const ctypes.Decl,
};

/// Return the WIT-visible name of the resource bound at `slot`,
/// or null if the slot doesn't carry a name. A resource's
/// canonical name is on its `.sub_resource` slot (locally
/// declared) or `.export_eq` slot (use-imported) — both carry the
/// WIT name directly. Alias slots are anonymous in the local
/// interface scope.
pub fn resourceNameForSlot(slots: []const TypeSlot, slot: u32) ?[]const u8 {
    if (slot >= slots.len) return null;
    return switch (slots[slot]) {
        .sub_resource => |name| name,
        .export_eq => |e| e.name,
        else => null,
    };
}

/// Decode the given `component-type` custom-section payload.
/// All returned slices borrow from `arena`.
pub fn decode(arena: Allocator, ct_payload: []const u8) DecodeError!DecodedWorld {
    const comp = try loader.load(ct_payload, arena);
    if (comp.types.len == 0) return error.InvalidComponentType;

    // The outermost type is a component-type with two decls:
    //   decl[0] = type = component-type (the world itself)
    //   decl[1] = export "<ns>:<pkg>/<world>[@<ver>]" component 0
    if (comp.types[0] != .component) return error.UnsupportedShape;
    const outer = comp.types[0].component;
    if (outer.decls.len < 2) return error.UnsupportedShape;
    if (outer.decls[0] != .type or outer.decls[0].type != .component) return error.UnsupportedShape;
    if (outer.decls[1] != .@"export") return error.UnsupportedShape;
    const world_qualified = outer.decls[1].@"export".name;

    const world_body = outer.decls[0].type.component;

    // Walk world body. Logical content is (type=instance,
    // import|export) pairs, but the encoder also splices `.alias`
    // instance-export decls between pairs whenever a consuming
    // interface has a `use src.{T};` clause
    // (metadata_encode.zig:190-201). Those aliases are transparent
    // to this decoder — they bump the on-wire type-index but don't
    // introduce a new world extern.
    var externs = std.ArrayListUnmanaged(WorldExtern).empty;
    var i: usize = 0;
    while (i < world_body.decls.len) {
        const decl = world_body.decls[i];
        if (decl == .alias) {
            i += 1;
            continue;
        }
        if (decl != .type or decl.type != .instance) return error.UnsupportedShape;
        const inst_type = decl.type.instance;
        // Find the matching import|export decl, skipping any alias
        // decls the encoder may have spliced in between.
        var j: usize = i + 1;
        while (j < world_body.decls.len and world_body.decls[j] == .alias) : (j += 1) {}
        if (j >= world_body.decls.len) return error.UnsupportedShape;
        const next = world_body.decls[j];
        var is_export: bool = undefined;
        var qualified_name: []const u8 = undefined;
        switch (next) {
            .@"export" => |e| {
                is_export = true;
                qualified_name = e.name;
            },
            .import => |im| {
                is_export = false;
                qualified_name = im.name;
            },
            else => return error.UnsupportedShape,
        }
        const body = try decodeInterfaceBody(arena, inst_type);
        try externs.append(arena, .{
            .is_export = is_export,
            .qualified_name = qualified_name,
            .type_slots = body.type_slots,
            .funcs = body.funcs,
            .inst_decls = inst_type.decls,
        });
        i = j + 1;
    }

    // Bare world name is the part after `/` (and before `@`) of the
    // qualified name. Top-level export's name *would* give us the
    // bare form, but it's also derivable.
    const bare = bareName(world_qualified);

    return .{
        .name = bare,
        .qualified_name = world_qualified,
        .externs = try externs.toOwnedSlice(arena),
        .world_decls = world_body.decls,
    };
}

const DecodedInterface = struct {
    type_slots: []const TypeSlot,
    funcs: []const FuncRef,
};

fn decodeInterfaceBody(arena: Allocator, inst: ctypes.InstanceTypeDecl) DecodeError!DecodedInterface {
    // Walk in declaration order, allocating one TypeSlot per
    // type-allocating decl. `.@"export"` with `.func` desc is the
    // only decl that does NOT allocate a type slot (it allocates a
    // func slot we don't track). Func sigs are captured at their
    // `.type=.func` slot and held aside for post-walk resolution
    // — references inside the sig may point at slots that haven't
    // been seen yet on a strict left-to-right walk, but the
    // encoder always hoists referenced slots BEFORE the func that
    // uses them, so a single-pass slot table is sufficient.
    var slots = std.ArrayListUnmanaged(TypeSlot).empty;
    const CapturedFunc = struct { slot: u32, sig: ctypes.FuncType, name: []const u8 };
    var captured = std.ArrayListUnmanaged(CapturedFunc).empty;

    var j: usize = 0;
    while (j < inst.decls.len) {
        const d = inst.decls[j];
        switch (d) {
            .alias => |a| {
                switch (a) {
                    .outer => |o| {
                        if (o.sort != .type) return error.UnsupportedShape;
                        try slots.append(arena, .{ .alias_outer = o.idx });
                    },
                    .instance_export => |ie| {
                        if (ie.sort != .type) return error.UnsupportedShape;
                        try slots.append(arena, .{ .alias_instance_export = .{
                            .instance_idx = ie.instance_idx,
                            .name = ie.name,
                        } });
                    },
                }
                j += 1;
            },
            .@"export" => |e| {
                switch (e.desc) {
                    .type => |tb| switch (tb) {
                        .eq => |target| {
                            try slots.append(arena, .{ .export_eq = .{
                                .name = e.name,
                                .target = target,
                            } });
                        },
                        .sub_resource => {
                            try slots.append(arena, .{ .sub_resource = e.name });
                        },
                    },
                    .func => |func_type_idx| {
                        // No type-slot allocation. The export must
                        // refer to a `.type=.func` slot we already
                        // captured — promote that captured entry
                        // to a `FuncRef` under this export's name.
                        // (We currently require the export to
                        // immediately follow its func type def, so
                        // the latest captured entry matches; the
                        // encoder never interleaves.)
                        if (captured.items.len == 0) return error.UnsupportedShape;
                        const last = &captured.items[captured.items.len - 1];
                        if (last.slot != func_type_idx) return error.UnsupportedShape;
                        if (last.name.len != 0) return error.UnsupportedShape;
                        last.name = e.name;
                    },
                    else => return error.UnsupportedShape,
                }
                j += 1;
            },
            .type => |td| {
                const slot_idx: u32 = @intCast(slots.items.len);
                switch (td) {
                    .val => |v| try slots.append(arena, .{ .val = v }),
                    .func => |sig| {
                        try slots.append(arena, .{ .typedef = td });
                        try captured.append(arena, .{
                            .slot = slot_idx,
                            .sig = sig,
                            .name = "",
                        });
                    },
                    else => try slots.append(arena, .{ .typedef = td }),
                }
                j += 1;
            },
            else => return error.UnsupportedShape,
        }
    }

    // Resolve captured func sigs against the completed slot table.
    var funcs = try arena.alloc(FuncRef, captured.items.len);
    for (captured.items, 0..) |c, idx| {
        if (c.name.len == 0) return error.UnsupportedShape;
        funcs[idx] = .{
            .name = c.name,
            .sig = try resolveFuncSig(arena, slots.items, c.sig),
        };
    }

    return .{
        .type_slots = try slots.toOwnedSlice(arena),
        .funcs = funcs,
    };
}

/// Rewrite every `ValType.type_idx` reference in `sig` according
/// to the rules in the module doc — chase aliases and `eq{}`
/// mirrors; substitute `.own` / `.borrow` / primitives inline
/// when the chain terminates at a `.val` slot.
fn resolveFuncSig(arena: Allocator, slots: []const TypeSlot, sig: ctypes.FuncType) DecodeError!ctypes.FuncType {
    const params = try arena.alloc(ctypes.NamedValType, sig.params.len);
    for (sig.params, 0..) |p, i| {
        params[i] = .{ .name = p.name, .type = resolveValType(slots, p.type) };
    }
    const results: ctypes.FuncType.ResultList = switch (sig.results) {
        .none => .none,
        .unnamed => |v| .{ .unnamed = resolveValType(slots, v) },
        .named => |named| blk: {
            const dst = try arena.alloc(ctypes.NamedValType, named.len);
            for (named, 0..) |nv, i| {
                dst[i] = .{ .name = nv.name, .type = resolveValType(slots, nv.type) };
            }
            break :blk .{ .named = dst };
        },
    };
    return .{ .params = params, .results = results };
}

fn resolveValType(slots: []const TypeSlot, vt: ctypes.ValType) ctypes.ValType {
    return switch (vt) {
        .type_idx => |n| resolveSlotRef(slots, n),
        // Resource handles encoded as bare `.own` / `.borrow` are
        // already in the canonical resolved form; chase the slot
        // they point at to land on the underlying resource binding.
        .own => |n| .{ .own = chaseResourceSlot(slots, n) },
        .borrow => |n| .{ .borrow = chaseResourceSlot(slots, n) },
        else => vt,
    };
}

/// Resolve a `ValType.type_idx = n` payload to its canonical
/// form. Chases alias / eq slots, substituting `.val` slots
/// inline. Compound-typedef destinations stay as `.type_idx`
/// (now pointing at the resolved slot).
fn resolveSlotRef(slots: []const TypeSlot, n: u32) ctypes.ValType {
    var cur = n;
    var hops: usize = 0;
    while (hops < slots.len) : (hops += 1) {
        if (cur >= slots.len) return .{ .type_idx = cur };
        switch (slots[cur]) {
            .alias_outer, .alias_instance_export => return .{ .type_idx = cur },
            .export_eq => |e| {
                if (e.target == cur) return .{ .type_idx = cur };
                cur = e.target;
            },
            .sub_resource => return .{ .type_idx = cur },
            .val => |v| return switch (v) {
                .type_idx => |n2| resolveSlotRef(slots, n2),
                .own => |r| .{ .own = chaseResourceSlot(slots, r) },
                .borrow => |r| .{ .borrow = chaseResourceSlot(slots, r) },
                else => v,
            },
            .typedef => return .{ .type_idx = cur },
        }
    }
    return .{ .type_idx = cur };
}

/// Resolve `.own = n` / `.borrow = n` references to their
/// canonical resource binding slot. The encoder emits
/// `.val .own = K` where K is already the named slot
/// (`.sub_resource` for a local resource, `.export_eq` for a
/// `use`-imported one) — we keep it as-is. Only follow through
/// raw outer aliases that have no naming binding of their own.
fn chaseResourceSlot(slots: []const TypeSlot, n: u32) u32 {
    if (n >= slots.len) return n;
    switch (slots[n]) {
        .alias_outer, .alias_instance_export => {
            // Anonymous alias to an outer slot — look ahead in
            // the local slot table for an `.export_eq` whose
            // target is this slot, which is the encoder's
            // canonical naming binding for `use`-imported types.
            for (slots, 0..) |s, i| switch (s) {
                .export_eq => |e| if (e.target == n) return @intCast(i),
                else => {},
            };
            return n;
        },
        else => return n,
    }
}

fn bareName(qualified: []const u8) []const u8 {
    // Strip everything before `/` (the package prefix). Strip `@<version>`.
    var name = qualified;
    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        name = name[slash + 1 ..];
    }
    if (std.mem.indexOfScalar(u8, name, '@')) |at| {
        name = name[0..at];
    }
    return name;
}

/// Locate `component-type:<world>` custom sections in a core wasm and
/// return the world name + payload of the (single) match. Returns
/// `null` if no such section exists. If multiple sections are
/// present (rare), the first wins.
pub fn extractFromCoreWasm(core_bytes: []const u8) !?struct {
    world_name: []const u8,
    payload: []const u8,
} {
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

        if (id == 0) {
            const n = try readU32Leb(body, 0);
            const name_len = n.value;
            if (n.bytes_read + name_len > body.len) return error.InvalidCoreModule;
            const sec_name = body[n.bytes_read .. n.bytes_read + name_len];
            const prefix = "component-type:";
            if (std.mem.startsWith(u8, sec_name, prefix)) {
                return .{
                    .world_name = sec_name[prefix.len..],
                    .payload = body[n.bytes_read + name_len ..],
                };
            }
        }
    }
    return null;
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

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const metadata_encode = @import("metadata_encode.zig");

test "decode: round-trip adder world" {
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
    const ct = try metadata_encode.encodeWorldFromSource(testing.allocator, wit_source, "adder");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try decode(arena.allocator(), ct);

    try testing.expectEqualStrings("adder", w.name);
    try testing.expectEqualStrings("docs:adder/adder@0.1.0", w.qualified_name);
    try testing.expectEqual(@as(usize, 1), w.externs.len);
    try testing.expect(w.externs[0].is_export);
    try testing.expectEqualStrings("docs:adder/add@0.1.0", w.externs[0].qualified_name);
    try testing.expectEqual(@as(usize, 1), w.externs[0].funcs.len);
    try testing.expectEqualStrings("add", w.externs[0].funcs[0].name);
    try testing.expectEqual(@as(usize, 2), w.externs[0].funcs[0].sig.params.len);
    try testing.expectEqualStrings("x", w.externs[0].funcs[0].sig.params[0].name);
    try testing.expect(w.externs[0].funcs[0].sig.params[0].type == .u32);
    try testing.expect(w.externs[0].funcs[0].sig.results == .unnamed);
    try testing.expect(w.externs[0].funcs[0].sig.results.unnamed == .u32);
}

test "decode #191: world with cross-interface `use` and resources" {
    // Reproducer from cataggar/wabt#191. The encoder splices
    // `.alias` decls at the world level (for each `use`-imported
    // type) and `.alias` + `.@"export" type=eq` mirror pairs +
    // `.@"export" type=sub_resource` decls inside the interface
    // bodies. Before the fix, every one of those tripped
    // `error.UnsupportedShape`.
    const wit_source =
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
    ;
    const ct = try metadata_encode.encodeWorldFromSource(testing.allocator, wit_source, "http-hello");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try decode(arena.allocator(), ct);

    try testing.expectEqualStrings("http-hello", w.name);
    try testing.expectEqualStrings("wasi:http/http-hello@0.2.6", w.qualified_name);
    try testing.expectEqual(@as(usize, 2), w.externs.len);

    // extern 0: import wasi:http/types@0.2.6 — resources only, no funcs.
    try testing.expect(!w.externs[0].is_export);
    try testing.expectEqualStrings("wasi:http/types@0.2.6", w.externs[0].qualified_name);
    try testing.expectEqual(@as(usize, 0), w.externs[0].funcs.len);

    // extern 1: export wasi:http/incoming-handler@0.2.6 — one func
    // `handle(request: own<R>, response-out: own<R>) -> ()`.
    try testing.expect(w.externs[1].is_export);
    try testing.expectEqualStrings("wasi:http/incoming-handler@0.2.6", w.externs[1].qualified_name);
    try testing.expectEqual(@as(usize, 1), w.externs[1].funcs.len);

    const f = w.externs[1].funcs[0];
    try testing.expectEqualStrings("handle", f.name);
    try testing.expectEqual(@as(usize, 2), f.sig.params.len);
    try testing.expectEqualStrings("request", f.sig.params[0].name);
    // Resource handles are resolved during decode: `own<R>` ref
    // chains land on the resource binding slot in `type_slots`,
    // which a consumer can name via `resourceNameForSlot`.
    try testing.expect(f.sig.params[0].type == .own);
    try testing.expectEqualStrings(
        "incoming-request",
        resourceNameForSlot(w.externs[1].type_slots, f.sig.params[0].type.own).?,
    );
    try testing.expectEqualStrings("response-out", f.sig.params[1].name);
    try testing.expect(f.sig.params[1].type == .own);
    try testing.expectEqualStrings(
        "response-outparam",
        resourceNameForSlot(w.externs[1].type_slots, f.sig.params[1].type.own).?,
    );
    try testing.expect(f.sig.results == .none);

    // `type_slots` is populated and exposes at least one named
    // resource binding per use-imported resource.
    try testing.expect(w.externs[1].type_slots.len > 0);
    var seen_in_req = false;
    var seen_out = false;
    for (w.externs[1].type_slots) |s| switch (s) {
        .export_eq => |e| {
            if (std.mem.eql(u8, e.name, "incoming-request")) seen_in_req = true;
            if (std.mem.eql(u8, e.name, "response-outparam")) seen_out = true;
        },
        .sub_resource => |n| {
            if (std.mem.eql(u8, n, "incoming-request")) seen_in_req = true;
            if (std.mem.eql(u8, n, "response-outparam")) seen_out = true;
        },
        else => {},
    };
    try testing.expect(seen_in_req);
    try testing.expect(seen_out);
}

test "decode #194: local resource borrow/own round-trips" {
    // Self-contained reproducer for #194 acceptance: a resource
    // declared in the same interface as its consumer. The
    // encoder emits `.@"export" .type.sub_resource` for the
    // resource, then hoists `.val .borrow=<slot>` /
    // `.val .own=<slot>` decls before the func that uses them.
    const wit_source =
        \\package docs:demo@0.1.0;
        \\
        \\interface i {
        \\    resource r {}
        \\    f: func(x: borrow<r>) -> own<r>;
        \\}
        \\
        \\world w {
        \\    export i;
        \\}
    ;
    const ct = try metadata_encode.encodeWorldFromSource(testing.allocator, wit_source, "w");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), ct);

    try testing.expectEqual(@as(usize, 1), decoded.externs.len);
    const ext = decoded.externs[0];
    try testing.expectEqual(@as(usize, 1), ext.funcs.len);
    const f = ext.funcs[0];
    try testing.expectEqualStrings("f", f.name);
    try testing.expectEqual(@as(usize, 1), f.sig.params.len);
    try testing.expect(f.sig.params[0].type == .borrow);
    try testing.expectEqualStrings(
        "r",
        resourceNameForSlot(ext.type_slots, f.sig.params[0].type.borrow).?,
    );
    try testing.expect(f.sig.results == .unnamed);
    try testing.expect(f.sig.results.unnamed == .own);
    try testing.expectEqualStrings(
        "r",
        resourceNameForSlot(ext.type_slots, f.sig.results.unnamed.own).?,
    );
}

test "decode #194: primitive params stay primitive after resolution" {
    // Regression guard: the post-walk substitution pass must not
    // turn primitives into spurious `.type_idx` refs. Mirrors the
    // adder shape with explicit assertions on the canonical
    // primitive ValTypes.
    const wit_source =
        \\package docs:adder@0.1.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
        \\world adder { export add; }
    ;
    const ct = try metadata_encode.encodeWorldFromSource(testing.allocator, wit_source, "adder");
    defer testing.allocator.free(ct);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try decode(arena.allocator(), ct);

    const f = w.externs[0].funcs[0];
    try testing.expect(f.sig.params[0].type == .u32);
    try testing.expect(f.sig.params[1].type == .u32);
    try testing.expect(f.sig.results.unnamed == .u32);
}

test "extractFromCoreWasm: finds custom section" {
    const core = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x07,
        0x05, // name length=5
        'h', 'e', 'l', 'l', 'o',
    } ++ [_]u8{0x00};
    const found = try extractFromCoreWasm(&core);
    try testing.expect(found == null); // name doesn't match prefix

    const core2 = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x00, 0x13, // section id=0, size=19
        0x10, // name len=16 ("component-type:w")
        'c', 'o', 'm', 'p', 'o', 'n', 'e', 'n', 't', '-', 't', 'y', 'p', 'e', ':', 'w',
        0xAA, 0xBB,
    };
    const f2 = try extractFromCoreWasm(&core2);
    try testing.expect(f2 != null);
    try testing.expectEqualStrings("w", f2.?.world_name);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, f2.?.payload);
}
