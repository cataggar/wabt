//! Adapter shadow-stack initialization synthesis.
//!
//! Mirrors `wit-component/src/gc.rs` lines 640-778: after a GC pass
//! over the wasi-preview1 adapter, append a synthesized
//! `realloc_via_memory_grow` helper and an `allocate_stack` start
//! function. Without these, the adapter's `__stack_pointer` global
//! stays at zero, so iovec scratch storage lands at low memory and
//! writes silently no-op (or, under stricter runtimes, trap).
//!
//! Strategy (non-lazy path; the only one wabt currently uses):
//!
//!  * Find `__stack_pointer` (mut i32 global named `__stack_pointer`
//!    in the binary `name` section). No-op if absent.
//!  * Optionally find `allocation_state` (mut i32 global). If
//!    present, emit the lazy state-machine variant (unallocated →
//!    allocating → allocated) so re-entrant `cabi_realloc` calls
//!    from the main module don't recurse into stack allocation
//!    before it's set up. If absent, emit the bare allocation
//!    sequence.
//!  * Synthesize a local `realloc_via_memory_grow` function (it
//!    only accepts page-sized allocations and uses `memory.grow`),
//!    OR reuse an imported `__main_module__.cabi_realloc` when the
//!    embed exports it. The current splicer always falls through to
//!    the synthesized helper because wabt leaves the import in
//!    place (its `__main_module__` fallback module supplies trap
//!    stubs for embeds that don't export `cabi_realloc`).
//!  * Synthesize an `allocate_stack` function of type `() -> ()`.
//!  * Set the module's start var to `allocate_stack`'s new func
//!    index.
//!
//! The lazy "prepend `call $allocate_stack` to every adapter export"
//! variant (wit-component's `lazy_stack_init_index` path) is not
//! implemented here. It's an optimization that only kicks in when
//! the main module *does* export `cabi_realloc`, which is rare for
//! the wasip1 embeds wabt is built to wrap.

const std = @import("std");
const Allocator = std.mem.Allocator;
const leb128 = @import("../../leb128.zig");
const Mod = @import("../../Module.zig");
const wtypes = @import("../../types.zig");

pub const Error = error{ OutOfMemory, InvalidNameSection };

const PAGE_SIZE: u32 = 65536;

/// Augment `mod` in place with the synthesized stack-allocation
/// helpers and a `(start $allocate_stack)` directive. No-op if
/// the module has no `__stack_pointer` global.
pub fn augment(gpa: Allocator, mod: *Mod.Module) Error!void {
    const sp_idx = (try findMutI32Global(gpa, mod, "__stack_pointer")) orelse return;
    const state_idx = try findMutI32Global(gpa, mod, "allocation_state");

    const empty_type_idx = try findOrAddEmptyFuncType(gpa, mod);

    // Prefer the existing `__main_module__::cabi_realloc` import
    // when present — the caller's component-level wiring routes it
    // to either the embed's `cabi_realloc` or the fallback module's
    // `realloc_via_memory_grow` (see
    // `buildMainModuleFallback` in adapter.zig). Re-using it keeps
    // the GC'd adapter size minimal.
    //
    // Only when no cabi_realloc import exists do we synthesize a
    // local `realloc_via_memory_grow` for `allocate_stack` to call.
    const realloc_func_idx: u32 = if (findCabiReallocImportIdx(mod)) |idx|
        idx
    else blk: {
        const realloc_type_idx = try findOrAddReallocFuncType(gpa, mod);
        const idx: u32 = @intCast(mod.funcs.items.len);
        try appendDefinedFunc(gpa, mod, realloc_type_idx, &.{wtypes.ValType.i32}, try buildReallocViaMemoryGrowBody(gpa));
        break :blk idx;
    };

    const allocate_stack_idx: u32 = @intCast(mod.funcs.items.len);
    const body = try buildAllocateStackBody(gpa, realloc_func_idx, sp_idx, state_idx);
    try appendDefinedFunc(gpa, mod, empty_type_idx, &.{}, body);

    mod.start_var = .{ .index = allocate_stack_idx };
}

fn findCabiReallocImportIdx(mod: *const Mod.Module) ?u32 {
    var fidx: u32 = 0;
    for (mod.imports.items) |im| {
        if (im.kind != .func) continue;
        if (std.mem.eql(u8, im.module_name, "__main_module__") and
            std.mem.eql(u8, im.field_name, "cabi_realloc"))
        {
            return fidx;
        }
        fidx += 1;
    }
    return null;
}

// ── Name-section helpers ───────────────────────────────────────────────

fn findMutI32Global(gpa: Allocator, mod: *const Mod.Module, want_name: []const u8) Error!?u32 {
    var found_idx: ?u32 = null;
    for (mod.customs.items) |c| {
        if (!std.mem.eql(u8, c.name, "name")) continue;
        const idx = parseGlobalNameForMatch(c.data, want_name) catch return error.InvalidNameSection;
        if (idx) |i| {
            found_idx = i;
            break;
        }
    }
    const i = found_idx orelse return null;
    if (i >= mod.globals.items.len) return null;
    const g = mod.globals.items[i];
    if (g.type.val_type != .i32) return null;
    if (g.type.mutability != .mutable) return null;
    _ = gpa;
    return i;
}

/// Scan the `name` custom-section payload for the global subsection
/// (id 7) and return the index whose name matches `want`. Returns
/// `null` if no global subsection exists or if the name is not
/// listed.
fn parseGlobalNameForMatch(payload: []const u8, want: []const u8) !?u32 {
    var pos: usize = 0;
    while (pos < payload.len) {
        if (pos + 1 > payload.len) return error.InvalidNameSection;
        const sub_id = payload[pos];
        pos += 1;
        const size_r = leb128.readU32Leb128(payload[pos..]) catch return error.InvalidNameSection;
        pos += size_r.bytes_read;
        const sub_end = pos + size_r.value;
        if (sub_end > payload.len) return error.InvalidNameSection;
        defer pos = sub_end;
        if (sub_id != 7) continue;

        var sp: usize = pos;
        const count_r = leb128.readU32Leb128(payload[sp..sub_end]) catch return error.InvalidNameSection;
        sp += count_r.bytes_read;
        var i: u32 = 0;
        while (i < count_r.value) : (i += 1) {
            const idx_r = leb128.readU32Leb128(payload[sp..sub_end]) catch return error.InvalidNameSection;
            sp += idx_r.bytes_read;
            const nlen_r = leb128.readU32Leb128(payload[sp..sub_end]) catch return error.InvalidNameSection;
            sp += nlen_r.bytes_read;
            if (sp + nlen_r.value > sub_end) return error.InvalidNameSection;
            const name = payload[sp .. sp + nlen_r.value];
            sp += nlen_r.value;
            if (std.mem.eql(u8, name, want)) return idx_r.value;
        }
    }
    return null;
}

// ── Type-section helpers ───────────────────────────────────────────────

fn findOrAddEmptyFuncType(gpa: Allocator, mod: *Mod.Module) Error!u32 {
    for (mod.module_types.items, 0..) |t, i| switch (t) {
        .func_type => |ft| if (ft.params.len == 0 and ft.results.len == 0) return @intCast(i),
        else => {},
    };
    try mod.module_types.append(gpa, .{ .func_type = .{
        .params = &.{},
        .results = &.{},
        .param_type_idxs = &.{},
        .result_type_idxs = &.{},
    } });
    return @intCast(mod.module_types.items.len - 1);
}

fn findOrAddReallocFuncType(gpa: Allocator, mod: *Mod.Module) Error!u32 {
    const want_params = &[_]wtypes.ValType{ .i32, .i32, .i32, .i32 };
    const want_results = &[_]wtypes.ValType{.i32};
    for (mod.module_types.items, 0..) |t, i| switch (t) {
        .func_type => |ft| {
            if (std.mem.eql(wtypes.ValType, ft.params, want_params) and
                std.mem.eql(wtypes.ValType, ft.results, want_results))
            {
                return @intCast(i);
            }
        },
        else => {},
    };
    const params = try gpa.alloc(wtypes.ValType, 4);
    @memcpy(params, want_params);
    const results = try gpa.alloc(wtypes.ValType, 1);
    @memcpy(results, want_results);
    try mod.module_types.append(gpa, .{ .func_type = .{
        .params = params,
        .results = results,
        .param_type_idxs = &.{},
        .result_type_idxs = &.{},
    } });
    return @intCast(mod.module_types.items.len - 1);
}

// ── Func append helper ─────────────────────────────────────────────────

fn appendDefinedFunc(
    gpa: Allocator,
    mod: *Mod.Module,
    type_idx: u32,
    locals: []const wtypes.ValType,
    code_bytes: []u8,
) Error!void {
    var f: Mod.Func = .{};
    f.is_import = false;
    f.decl = .{ .type_var = .{ .index = type_idx }, .sig = .{} };
    f.code_bytes = code_bytes;
    f.owns_code_bytes = true;
    f.local_types = .empty;
    f.local_type_idxs = .empty;
    for (locals) |vt| {
        try f.local_types.append(gpa, vt);
        try f.local_type_idxs.append(gpa, 0xFFFFFFFF);
    }
    try mod.funcs.append(gpa, f);
}

// ── Code-emit helpers ──────────────────────────────────────────────────

fn writeLeb(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: u32) Error!void {
    var tmp: [leb128.max_u32_bytes]u8 = undefined;
    const n = leb128.writeU32Leb128(&tmp, v);
    try out.appendSlice(gpa, tmp[0..n]);
}

fn writeSLeb(out: *std.ArrayListUnmanaged(u8), gpa: Allocator, v: i32) Error!void {
    var tmp: [leb128.max_s32_bytes]u8 = undefined;
    const n = leb128.writeS32Leb128(&tmp, v);
    try out.appendSlice(gpa, tmp[0..n]);
}

fn buildReallocViaMemoryGrowBody(gpa: Allocator) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    // Assert local 0 (old_ptr) == 0.
    try out.appendSlice(gpa, &.{ 0x41, 0x00 }); // i32.const 0
    try out.appendSlice(gpa, &.{ 0x20, 0x00 }); // local.get 0
    try out.append(gpa, 0x47); // i32.ne
    try out.appendSlice(gpa, &.{ 0x04, 0x40 }); // if (empty block type)
    try out.append(gpa, 0x00); // unreachable
    try out.append(gpa, 0x0b); // end

    // Assert local 1 (old_len) == 0.
    try out.appendSlice(gpa, &.{ 0x41, 0x00 });
    try out.appendSlice(gpa, &.{ 0x20, 0x01 });
    try out.append(gpa, 0x47);
    try out.appendSlice(gpa, &.{ 0x04, 0x40 });
    try out.append(gpa, 0x00);
    try out.append(gpa, 0x0b);

    // Assert local 3 (new_len) == PAGE_SIZE.
    try out.append(gpa, 0x41); // i32.const
    try writeSLeb(&out, gpa, @intCast(PAGE_SIZE));
    try out.appendSlice(gpa, &.{ 0x20, 0x03 });
    try out.append(gpa, 0x47);
    try out.appendSlice(gpa, &.{ 0x04, 0x40 });
    try out.append(gpa, 0x00);
    try out.append(gpa, 0x0b);

    // memory.grow 0 → local.tee 4
    try out.appendSlice(gpa, &.{ 0x41, 0x01 }); // i32.const 1 (page count)
    try out.appendSlice(gpa, &.{ 0x40, 0x00 }); // memory.grow 0
    try out.appendSlice(gpa, &.{ 0x22, 0x04 }); // local.tee 4

    // Check grow result == -1 → unreachable.
    try out.appendSlice(gpa, &.{ 0x41, 0x7f }); // i32.const -1 (signed LEB128)
    try out.append(gpa, 0x46); // i32.eq
    try out.appendSlice(gpa, &.{ 0x04, 0x40 });
    try out.append(gpa, 0x00);
    try out.append(gpa, 0x0b);

    // Return local.get(4) << 16 (convert page index → byte address).
    try out.appendSlice(gpa, &.{ 0x20, 0x04 });
    try out.appendSlice(gpa, &.{ 0x41, 0x10 }); // i32.const 16
    try out.append(gpa, 0x74); // i32.shl

    try out.append(gpa, 0x0b); // function body end
    return out.toOwnedSlice(gpa);
}

fn buildAllocateStackBody(
    gpa: Allocator,
    realloc_func_idx: u32,
    sp_idx: u32,
    state_idx: ?u32,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    if (state_idx) |sidx| {
        // global.get $allocation_state ; i32.const 0 ; i32.eq ; if
        try out.append(gpa, 0x23); // global.get
        try writeLeb(&out, gpa, sidx);
        try out.appendSlice(gpa, &.{ 0x41, 0x00 });
        try out.append(gpa, 0x46); // i32.eq
        try out.appendSlice(gpa, &.{ 0x04, 0x40 }); // if (empty block type)

        // allocation_state = Allocating (1)
        try out.appendSlice(gpa, &.{ 0x41, 0x01 });
        try out.append(gpa, 0x24); // global.set
        try writeLeb(&out, gpa, sidx);
    }

    // realloc(0, 0, 8, PAGE_SIZE)
    try out.appendSlice(gpa, &.{ 0x41, 0x00 }); // i32.const 0
    try out.appendSlice(gpa, &.{ 0x41, 0x00 }); // i32.const 0
    try out.appendSlice(gpa, &.{ 0x41, 0x08 }); // i32.const 8
    try out.append(gpa, 0x41); // i32.const
    try writeSLeb(&out, gpa, @intCast(PAGE_SIZE));
    try out.append(gpa, 0x10); // call
    try writeLeb(&out, gpa, realloc_func_idx);

    // sp = result + PAGE_SIZE (stack grows down from top of region)
    try out.append(gpa, 0x41); // i32.const
    try writeSLeb(&out, gpa, @intCast(PAGE_SIZE));
    try out.append(gpa, 0x6a); // i32.add
    try out.append(gpa, 0x24); // global.set
    try writeLeb(&out, gpa, sp_idx);

    if (state_idx) |sidx| {
        // allocation_state = Allocated (2)
        try out.appendSlice(gpa, &.{ 0x41, 0x02 });
        try out.append(gpa, 0x24);
        try writeLeb(&out, gpa, sidx);
        try out.append(gpa, 0x0b); // end of if
    }

    try out.append(gpa, 0x0b); // function body end
    return out.toOwnedSlice(gpa);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseGlobalNameForMatch finds named global" {
    // name section payload: subsection 7 (globals) with 2 entries:
    //   idx=0 name="__stack_pointer"
    //   idx=1 name="other"
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    var sub: std.ArrayListUnmanaged(u8) = .empty;
    defer sub.deinit(testing.allocator);
    try writeLeb(&sub, testing.allocator, 2);
    try writeLeb(&sub, testing.allocator, 0);
    const n1 = "__stack_pointer";
    try writeLeb(&sub, testing.allocator, @intCast(n1.len));
    try sub.appendSlice(testing.allocator, n1);
    try writeLeb(&sub, testing.allocator, 1);
    const n2 = "other";
    try writeLeb(&sub, testing.allocator, @intCast(n2.len));
    try sub.appendSlice(testing.allocator, n2);

    try buf.append(testing.allocator, 7);
    try writeLeb(&buf, testing.allocator, @intCast(sub.items.len));
    try buf.appendSlice(testing.allocator, sub.items);

    try testing.expectEqual(@as(?u32, 0), try parseGlobalNameForMatch(buf.items, "__stack_pointer"));
    try testing.expectEqual(@as(?u32, 1), try parseGlobalNameForMatch(buf.items, "other"));
    try testing.expectEqual(@as(?u32, null), try parseGlobalNameForMatch(buf.items, "missing"));
}

test "parseGlobalNameForMatch ignores other subsections" {
    // subsection 1 (functions) precedes subsection 7 (globals).
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // function subsection: 1 entry idx=5 name="foo"
    {
        var sub: std.ArrayListUnmanaged(u8) = .empty;
        defer sub.deinit(testing.allocator);
        try writeLeb(&sub, testing.allocator, 1);
        try writeLeb(&sub, testing.allocator, 5);
        const n = "foo";
        try writeLeb(&sub, testing.allocator, @intCast(n.len));
        try sub.appendSlice(testing.allocator, n);

        try buf.append(testing.allocator, 1);
        try writeLeb(&buf, testing.allocator, @intCast(sub.items.len));
        try buf.appendSlice(testing.allocator, sub.items);
    }

    // global subsection
    {
        var sub: std.ArrayListUnmanaged(u8) = .empty;
        defer sub.deinit(testing.allocator);
        try writeLeb(&sub, testing.allocator, 1);
        try writeLeb(&sub, testing.allocator, 3);
        const n = "__stack_pointer";
        try writeLeb(&sub, testing.allocator, @intCast(n.len));
        try sub.appendSlice(testing.allocator, n);

        try buf.append(testing.allocator, 7);
        try writeLeb(&buf, testing.allocator, @intCast(sub.items.len));
        try buf.appendSlice(testing.allocator, sub.items);
    }

    try testing.expectEqual(@as(?u32, null), try parseGlobalNameForMatch(buf.items, "foo"));
    try testing.expectEqual(@as(?u32, 3), try parseGlobalNameForMatch(buf.items, "__stack_pointer"));
}
