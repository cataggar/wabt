//! Transcribe a lifted **export** function signature's value types from
//! an embed interface body's local type-index space into the wrapping
//! component's type-index space.
//!
//! When `component new` lifts an export func (e.g. `wasi:cli/run`'s
//! `run: func() -> result`), any compound value type in the sig
//! (`result` / `option` / `variant` / `record` / `tuple` / `list`) is
//! decoded as a `ValType.type_idx = slot` pointing at a
//! `TypeSlot.typedef` in the *embed* body — an index that is undefined
//! (and usually colliding) in the wrapping component's type space.
//! Emitting it verbatim produces an invalid component
//! (`type index N is not a defined type`; cataggar/wabt#246).
//!
//! This pass hoists each such compound into a freshly-defined
//! component-level `TypeDef` (recursing into nested value types) and
//! rewrites the reference to the new component-level index, matching
//! what `wasm-tools component new` emits.
//!
//! It is generic over a `ctx` so it can drive either component-AST
//! builder. `ctx` must provide:
//!   * `fn addType(self, td: ctypes.TypeDef) Error!u32` — append a
//!     defined type, returning its component-level type index.
//!   * `fn rewriteLeaf(self, v: ctypes.ValType) Error!ctypes.ValType` —
//!     resolve a leaf the transcriber doesn't own: resource handles
//!     (`own`/`borrow`) and non-typedef `.type_idx` slots (aliased
//!     `use`d types). Implementations may pass through unchanged.

const std = @import("std");
const ctypes = @import("../types.zig");
const metadata_decode = @import("metadata_decode.zig");

pub const Error = error{ OutOfMemory, UnresolvedResource };

/// Transcribe a full func signature (params + results).
pub fn transcribeFuncSig(
    arena: std.mem.Allocator,
    ctx: anytype,
    ext_slots: []const metadata_decode.TypeSlot,
    sig: ctypes.FuncType,
) Error!ctypes.FuncType {
    const params = try arena.alloc(ctypes.NamedValType, sig.params.len);
    for (sig.params, 0..) |p, i| {
        params[i] = .{ .name = p.name, .type = try transcribeValType(arena, ctx, ext_slots, p.type) };
    }
    const results: ctypes.FuncType.ResultList = switch (sig.results) {
        .none => .none,
        .unnamed => |rv| .{ .unnamed = try transcribeValType(arena, ctx, ext_slots, rv) },
        .named => |named| n: {
            const dst = try arena.alloc(ctypes.NamedValType, named.len);
            for (named, 0..) |nv, i| {
                dst[i] = .{ .name = nv.name, .type = try transcribeValType(arena, ctx, ext_slots, nv.type) };
            }
            break :n .{ .named = dst };
        },
    };
    return .{ .params = params, .results = results, .is_async = sig.is_async };
}

/// Transcribe one value type. Compound `.type_idx` slots are hoisted
/// into defined component types (inner-first, so a hoisted type only
/// references already-defined ones); leaves are delegated to
/// `ctx.rewriteLeaf`.
pub fn transcribeValType(
    arena: std.mem.Allocator,
    ctx: anytype,
    ext_slots: []const metadata_decode.TypeSlot,
    v: ctypes.ValType,
) Error!ctypes.ValType {
    switch (v) {
        .type_idx => |slot| {
            if (slot < ext_slots.len) {
                switch (ext_slots[slot]) {
                    .typedef => |td| {
                        if (comptime @hasDecl(@TypeOf(ctx), "lookupType")) {
                            if (ctx.lookupType(slot)) |idx| return .{ .type_idx = idx };
                        }
                        const new_td = try transcribeTypeDef(arena, ctx, ext_slots, td);
                        const idx = try ctx.addType(new_td);
                        if (comptime @hasDecl(@TypeOf(ctx), "cacheType")) {
                            try ctx.cacheType(slot, idx);
                        }
                        return .{ .type_idx = idx };
                    },
                    .val => |vt| return try transcribeValType(arena, ctx, ext_slots, vt),
                    // alias / sub_resource slots are leaves the builder
                    // resolves (resource handle or aliased `use`d type).
                    else => return try ctx.rewriteLeaf(v),
                }
            }
            return try ctx.rewriteLeaf(v);
        },
        .own, .borrow => return try ctx.rewriteLeaf(v),
        // Primitives, and already-component-level compound refs, pass
        // through unchanged.
        else => return v,
    }
}

fn transcribeTypeDef(
    arena: std.mem.Allocator,
    ctx: anytype,
    ext_slots: []const metadata_decode.TypeSlot,
    td: ctypes.TypeDef,
) Error!ctypes.TypeDef {
    return switch (td) {
        .val => |vt| .{ .val = try transcribeValType(arena, ctx, ext_slots, vt) },
        .future => |f| .{ .future = .{ .element = if (f.element) |e| try transcribeValType(arena, ctx, ext_slots, e) else null } },
        .stream => |s| .{ .stream = .{ .element = if (s.element) |e| try transcribeValType(arena, ctx, ext_slots, e) else null } },
        .option => |o| .{ .option = .{ .inner = try transcribeValType(arena, ctx, ext_slots, o.inner) } },
        .list => |l| .{ .list = .{ .element = try transcribeValType(arena, ctx, ext_slots, l.element) } },
        .result => |r| .{ .result = .{
            .ok = if (r.ok) |okv| try transcribeValType(arena, ctx, ext_slots, okv) else null,
            .err = if (r.err) |errv| try transcribeValType(arena, ctx, ext_slots, errv) else null,
        } },
        .record => |rec| blk: {
            const fields = try arena.alloc(ctypes.Field, rec.fields.len);
            for (rec.fields, 0..) |f, i| {
                fields[i] = .{ .name = f.name, .type = try transcribeValType(arena, ctx, ext_slots, f.type) };
            }
            break :blk .{ .record = .{ .fields = fields } };
        },
        .tuple => |t| blk: {
            const fields = try arena.alloc(ctypes.ValType, t.fields.len);
            for (t.fields, 0..) |fty, i| {
                fields[i] = try transcribeValType(arena, ctx, ext_slots, fty);
            }
            break :blk .{ .tuple = .{ .fields = fields } };
        },
        .variant => |vv| blk: {
            const cases = try arena.alloc(ctypes.Case, vv.cases.len);
            for (vv.cases, 0..) |c, i| {
                cases[i] = .{
                    .name = c.name,
                    .type = if (c.type) |ct| try transcribeValType(arena, ctx, ext_slots, ct) else null,
                    .refines = c.refines,
                };
            }
            break :blk .{ .variant = .{ .cases = cases } };
        },
        // No nested value types to rewrite.
        .flags, .enum_, .resource, .func, .component, .instance => td,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Mock builder context: records each hoisted `TypeDef` and hands out
/// component-level indices starting at `base` (simulating pre-existing
/// component types such as imported instances).
const TestCtx = struct {
    added: *std.ArrayListUnmanaged(ctypes.TypeDef),
    arena: std.mem.Allocator,
    base: u32,

    pub fn addType(self: @This(), td: ctypes.TypeDef) Error!u32 {
        const idx = self.base + @as(u32, @intCast(self.added.items.len));
        try self.added.append(self.arena, td);
        return idx;
    }

    pub fn rewriteLeaf(self: @This(), v: ctypes.ValType) Error!ctypes.ValType {
        _ = self;
        return v;
    }
};

test "transcribeValType: bare result is hoisted to a defined type (#246)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const slots = try a.alloc(metadata_decode.TypeSlot, 1);
    slots[0] = .{ .typedef = .{ .result = .{ .ok = null, .err = null } } };

    var added = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    // base=1 simulates a component whose type 0 is an imported instance
    // type (exactly the #246 collision: `(func (result 0))`).
    const ctx = TestCtx{ .added = &added, .arena = a, .base = 1 };

    const out = try transcribeValType(a, ctx, slots, .{ .type_idx = 0 });
    try testing.expect(out == .type_idx);
    try testing.expectEqual(@as(u32, 1), out.type_idx); // defined type, not the colliding 0
    try testing.expectEqual(@as(usize, 1), added.items.len);
    try testing.expect(added.items[0] == .result);
    try testing.expect(added.items[0].result.ok == null);
    try testing.expect(added.items[0].result.err == null);
}

test "transcribeValType: nested compounds are hoisted inner-first" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // slot 0: option<u64>; slot 1: result<option<u64>, u32>
    const slots = try a.alloc(metadata_decode.TypeSlot, 2);
    slots[0] = .{ .typedef = .{ .option = .{ .inner = .u64 } } };
    slots[1] = .{ .typedef = .{ .result = .{ .ok = .{ .type_idx = 0 }, .err = .u32 } } };

    var added = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    const ctx = TestCtx{ .added = &added, .arena = a, .base = 0 };

    const out = try transcribeValType(a, ctx, slots, .{ .type_idx = 1 });
    // option must be defined (idx 0) before the result (idx 1) that refers to it.
    try testing.expectEqual(@as(u32, 1), out.type_idx);
    try testing.expectEqual(@as(usize, 2), added.items.len);
    try testing.expect(added.items[0] == .option);
    try testing.expect(added.items[1] == .result);
    try testing.expect(added.items[1].result.ok.? == .type_idx);
    try testing.expectEqual(@as(u32, 0), added.items[1].result.ok.?.type_idx);
    try testing.expect(added.items[1].result.err.? == .u32);
}

test "transcribeValType: variant case payloads are hoisted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // slot 0: option<string>; slot 1: variant { a, b(option<string>) }
    const slots = try a.alloc(metadata_decode.TypeSlot, 2);
    slots[0] = .{ .typedef = .{ .option = .{ .inner = .string } } };
    const cases = try a.alloc(ctypes.Case, 2);
    cases[0] = .{ .name = "a", .type = null };
    cases[1] = .{ .name = "b", .type = .{ .type_idx = 0 } };
    slots[1] = .{ .typedef = .{ .variant = .{ .cases = cases } } };

    var added = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    const ctx = TestCtx{ .added = &added, .arena = a, .base = 3 };

    const out = try transcribeValType(a, ctx, slots, .{ .type_idx = 1 });
    try testing.expectEqual(@as(u32, 4), out.type_idx); // option=3, variant=4
    try testing.expect(added.items[0] == .option);
    try testing.expect(added.items[1] == .variant);
    const v = added.items[1].variant;
    try testing.expect(v.cases[0].type == null);
    try testing.expect(v.cases[1].type.?.type_idx == 3);
}

test "transcribeValType: primitives pass through without hoisting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var added = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    const ctx = TestCtx{ .added = &added, .arena = a, .base = 5 };

    const out = try transcribeValType(a, ctx, &.{}, .u32);
    try testing.expect(out == .u32);
    try testing.expectEqual(@as(usize, 0), added.items.len);
}

test "transcribeFuncSig: () -> result yields a hoisted result return (#246)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const slots = try a.alloc(metadata_decode.TypeSlot, 1);
    slots[0] = .{ .typedef = .{ .result = .{ .ok = null, .err = null } } };

    var added = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    const ctx = TestCtx{ .added = &added, .arena = a, .base = 2 };

    const sig = ctypes.FuncType{
        .params = &.{},
        .results = .{ .unnamed = .{ .type_idx = 0 } },
    };
    const out = try transcribeFuncSig(a, ctx, slots, sig);
    try testing.expectEqual(@as(usize, 0), out.params.len);
    try testing.expect(out.results == .unnamed);
    try testing.expect(out.results.unnamed == .type_idx);
    try testing.expectEqual(@as(u32, 2), out.results.unnamed.type_idx);
    try testing.expectEqual(@as(usize, 1), added.items.len);
    try testing.expect(added.items[0] == .result);
}

test "transcribeFuncSig preserves async function types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var added = std.ArrayListUnmanaged(ctypes.TypeDef).empty;
    const ctx = TestCtx{
        .added = &added,
        .arena = arena.allocator(),
        .base = 0,
    };
    const out = try transcribeFuncSig(
        arena.allocator(),
        ctx,
        &.{},
        .{ .params = &.{}, .results = .none, .is_async = true },
    );
    try testing.expect(out.is_async);
}
