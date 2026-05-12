//! Module-level garbage collection for the WASI preview1 adapter
//! core wasm.
//!
//! `wabt component new --adapt` previously embedded the adapter
//! verbatim, so every WASI namespace the adapter declares (~25 of
//! them) leaked through to the wrapping component as a top-level
//! import — even when the embed only used preview1 stdout. The fix
//! mirrors `wit-component/src/gc.rs`: parse the adapter, walk the
//! call/data graph from a "must keep" set of exports, drop
//! unreachable items, renumber surviving operands, and re-emit.
//!
//! Scope:
//!
//!   * Function reachability via `call`, `call_indirect`,
//!     `return_call*`, `ref.func`, and active element segments.
//!   * Type reachability via call_indirect type idxs and block-type
//!     indexed forms.
//!   * Global / table / memory reachability via the corresponding
//!     load/store/get/set/copy/fill/init/grow/size opcodes.
//!   * Data and element segment reachability via
//!     `memory.init`/`data.drop`/`table.init`/`elem.drop`.
//!   * Custom sections are preserved verbatim (`component-type:…`
//!     world payload notably). The world's import list is filtered
//!     by `types_import.zig:hoist` separately based on the live core
//!     namespaces.
//!
//! Out of scope (kept simple because the v36.0.9 preview1 adapter
//! doesn't use them):
//!
//!   * SIMD (0xfd prefix), atomics (0xfe), exception handling
//!     (0x06/0x07/0x08/0x09/0x18/0x19/0x1f), GC proposal (0xfb).
//!     Encountering any of these returns `error.UnsupportedOpcode` so
//!     a future adapter that adds them surfaces here loudly rather
//!     than producing silently-wrong output.
//!   * Tag (exception) section / multi-memory beyond memidx 0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("../../binary/reader.zig");
const writer = @import("../../binary/writer.zig");
const Mod = @import("../../Module.zig");
const wtypes = @import("../../types.zig");
const leb128 = @import("../../leb128.zig");
const stack_init = @import("stack_init.zig");

pub const Error = error{
    UnsupportedOpcode,
    InvalidBody,
    MissingRequiredExport,
    InvalidIndex,
    InvalidMagic,
    InvalidVersion,
    UnexpectedEof,
    InvalidSection,
    InvalidType,
    InvalidLimits,
    TooManyLocals,
    SectionTooLarge,
    FunctionCodeMismatch,
    OutOfMemory,
};

const SENTINEL: u32 = std.math.maxInt(u32);

/// Run the GC pass.
///
/// `required_exports` is the must-keep set; any export whose name
/// matches one of these is treated as a live root, and its target
/// (func/global/memory/table) is marked live. Names not present in
/// the adapter's export table return `MissingRequiredExport`.
///
/// `cabi_import_realloc` is always preserved when exported (the
/// canonical-ABI realloc helper used by indirect-lower paths). Adding
/// a non-existent name to the required set is an error.
pub fn run(
    gpa: Allocator,
    adapter_bytes: []const u8,
    required_exports: []const []const u8,
) Error![]u8 {
    var module = try reader.readModule(gpa, adapter_bytes);
    defer module.deinit();

    var live = try LiveSets.init(gpa, &module);
    defer live.deinit(gpa);

    var worklist = std.ArrayListUnmanaged(u32).empty;
    defer worklist.deinit(gpa);

    // Seed: every required export contributes its target to the
    // appropriate live set.
    for (required_exports) |name| {
        const ex = findExport(&module, name) orelse return error.MissingRequiredExport;
        try seedFromExport(gpa, &live, &worklist, ex);
    }
    if (findExport(&module, "cabi_import_realloc")) |ex| {
        try seedFromExport(gpa, &live, &worklist, ex);
    }

    // Worklist iteration: each newly-live func contributes its body's
    // references to the live sets and (transitively) more funcs to
    // the worklist. Iterate to fixpoint.
    while (true) {
        while (worklist.pop()) |fidx| {
            try walkFuncForLiveness(gpa, &module, &live, &worklist, fidx);
        }
        // Element segments produce funcs reachable via live tables;
        // re-check after the func pass settles, then loop until no
        // new work is enqueued.
        const before_len = worklist.items.len;
        try propagateElemsAndData(gpa, &module, &live, &worklist);
        if (worklist.items.len == before_len) break;
    }

    // Renumbering + re-emit.
    const remaps = try Remaps.compute(gpa, &live, &module);
    defer remaps.deinit(gpa);

    var out_mod = Mod.Module.init(gpa);
    errdefer out_mod.deinit();
    try emitLive(gpa, &out_mod, &module, &live, &remaps);

    // Synthesize the adapter's shadow-stack init function so that
    // `__stack_pointer` is initialized before any export runs. No-op
    // when the adapter has no `__stack_pointer` global. Mirrors
    // `wit-component/src/gc.rs` lines 640-778.
    stack_init.augment(gpa, &out_mod) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidNameSection => return error.InvalidSection,
    };

    const bytes = try writer.writeModule(gpa, &out_mod);
    out_mod.deinit();
    return bytes;
}

// ── Live sets ───────────────────────────────────────────────────────────

/// Bitsets tracking which entities survive GC. Funcs/globals/tables/
/// memories are indexed by their original positions in the input
/// module (imports first, then defined). Types/data/elems are indexed
/// by their respective sections.
const LiveSets = struct {
    funcs: std.DynamicBitSetUnmanaged,
    globals: std.DynamicBitSetUnmanaged,
    tables: std.DynamicBitSetUnmanaged,
    memories: std.DynamicBitSetUnmanaged,
    types: std.DynamicBitSetUnmanaged,
    data: std.DynamicBitSetUnmanaged,
    elems: std.DynamicBitSetUnmanaged,
    /// `func_visited[i]` is true once func i's body has been walked
    /// for liveness. Imports skip the walk (no body) but still mark
    /// visited so we don't re-enqueue them.
    func_visited: std.DynamicBitSetUnmanaged,

    fn init(gpa: Allocator, m: *const Mod.Module) !LiveSets {
        return .{
            .funcs = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.funcs.items.len),
            .globals = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.globals.items.len),
            .tables = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.tables.items.len),
            .memories = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.memories.items.len),
            .types = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.module_types.items.len),
            .data = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.data_segments.items.len),
            .elems = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.elem_segments.items.len),
            .func_visited = try std.DynamicBitSetUnmanaged.initEmpty(gpa, m.funcs.items.len),
        };
    }

    fn deinit(self: *LiveSets, gpa: Allocator) void {
        self.funcs.deinit(gpa);
        self.globals.deinit(gpa);
        self.tables.deinit(gpa);
        self.memories.deinit(gpa);
        self.types.deinit(gpa);
        self.data.deinit(gpa);
        self.elems.deinit(gpa);
        self.func_visited.deinit(gpa);
    }
};

fn findExport(m: *const Mod.Module, name: []const u8) ?Mod.Export {
    for (m.exports.items) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

fn seedFromExport(
    gpa: Allocator,
    live: *LiveSets,
    worklist: *std.ArrayListUnmanaged(u32),
    ex: Mod.Export,
) Error!void {
    const idx: u32 = switch (ex.var_) {
        .index => |i| i,
        .name => return error.InvalidIndex,
    };
    switch (ex.kind) {
        .func => try markFuncLive(gpa, live, worklist, idx),
        .global => live.globals.set(idx),
        .table => live.tables.set(idx),
        .memory => live.memories.set(idx),
        .tag => return error.UnsupportedOpcode,
    }
}

fn markFuncLive(
    gpa: Allocator,
    live: *LiveSets,
    worklist: *std.ArrayListUnmanaged(u32),
    fidx: u32,
) Error!void {
    if (fidx >= live.funcs.bit_length) return error.InvalidIndex;
    if (live.funcs.isSet(fidx)) return;
    live.funcs.set(fidx);
    try worklist.append(gpa, fidx);
}

// ── Liveness walk over a function body ──────────────────────────────────

fn walkFuncForLiveness(
    gpa: Allocator,
    m: *const Mod.Module,
    live: *LiveSets,
    worklist: *std.ArrayListUnmanaged(u32),
    fidx: u32,
) Error!void {
    if (live.func_visited.isSet(fidx)) return;
    live.func_visited.set(fidx);

    const func = &m.funcs.items[fidx];

    // Mark the func's signature type live.
    switch (func.decl.type_var) {
        .index => |ti| if (ti != wtypes.invalid_index) {
            if (ti < live.types.bit_length) live.types.set(ti);
        },
        .name => {},
    }

    if (func.is_import) return; // imports have no body to walk

    var sink = LivenessSink{ .gpa = gpa, .live = live, .worklist = worklist, .m = m };
    try walkOps(func.code_bytes, &sink);
}

const LivenessSink = struct {
    gpa: Allocator,
    live: *LiveSets,
    worklist: *std.ArrayListUnmanaged(u32),
    m: *const Mod.Module,

    fn onFunc(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        try markFuncLive(self.gpa, self.live, self.worklist, idx);
    }
    fn onType(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        if (idx >= self.live.types.bit_length) return error.InvalidIndex;
        self.live.types.set(idx);
    }
    fn onGlobal(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        if (idx >= self.live.globals.bit_length) return error.InvalidIndex;
        self.live.globals.set(idx);
    }
    fn onTable(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        if (idx >= self.live.tables.bit_length) return error.InvalidIndex;
        self.live.tables.set(idx);
    }
    fn onMemory(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        if (idx >= self.live.memories.bit_length) return error.InvalidIndex;
        self.live.memories.set(idx);
    }
    fn onData(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        if (idx >= self.live.data.bit_length) return error.InvalidIndex;
        self.live.data.set(idx);
    }
    fn onElem(self: *LivenessSink, idx: u32, _: usize, _: usize) Error!void {
        if (idx >= self.live.elems.bit_length) return error.InvalidIndex;
        self.live.elems.set(idx);
    }
};

/// Active element segments contribute their funcs to the live set
/// when their target table is live. Active data segments (the
/// preview1 adapter has none) similarly become live when their target
/// memory does. Passive segments are covered by the body walk
/// (`memory.init`/`table.init`/`*.drop`).
fn propagateElemsAndData(
    gpa: Allocator,
    m: *const Mod.Module,
    live: *LiveSets,
    worklist: *std.ArrayListUnmanaged(u32),
) Error!void {
    for (m.elem_segments.items, 0..) |seg, i| {
        if (live.elems.isSet(@intCast(i))) continue;
        if (seg.kind != .active) continue;
        const tidx: u32 = switch (seg.table_var) {
            .index => |x| x,
            .name => continue,
        };
        if (tidx >= live.tables.bit_length or !live.tables.isSet(tidx)) continue;
        live.elems.set(@intCast(i));
        // The segment's funcref entries become live too.
        for (seg.elem_var_indices.items) |v| switch (v) {
            .index => |fi| try markFuncLive(gpa, live, worklist, fi),
            .name => {},
        };
        // Walk the elem_expr_bytes for any func references.
        if (seg.elem_expr_bytes.len > 0) {
            var sink = LivenessSink{ .gpa = gpa, .live = live, .worklist = worklist, .m = m };
            try walkConstExprs(seg.elem_expr_bytes, seg.elem_expr_count, &sink);
        }
    }

    for (m.data_segments.items, 0..) |seg, i| {
        if (live.data.isSet(@intCast(i))) continue;
        if (seg.kind != .active) continue;
        const midx: u32 = switch (seg.memory_var) {
            .index => |x| x,
            .name => continue,
        };
        if (midx >= live.memories.bit_length or !live.memories.isSet(midx)) continue;
        live.data.set(@intCast(i));
    }
}

// ── Operator walker ─────────────────────────────────────────────────────

/// Walk the operators in a function body, calling `sink.onX` for each
/// reference to an entity in the corresponding indexspace. The walker
/// is shared by the liveness pass and the rewrite pass via a duck
/// typed `sink`. Sinks may also examine `byte_pos` / `byte_len` to
/// patch operands in-place (see `RewriteSink`).
fn walkOps(bytes: []const u8, sink: anytype) Error!void {
    var pos: usize = 0;
    var depth: usize = 0;
    while (pos < bytes.len) {
        const op = bytes[pos];
        pos += 1;
        switch (op) {
            // Control: flow-of-control, no entity refs.
            0x00, 0x01 => {}, // unreachable, nop
            0x02, 0x03, 0x04 => try skipBlockType(bytes, &pos, sink), // block, loop, if
            0x05 => {}, // else
            0x0b => { // end
                if (depth == 0) return; // outer end
                depth -= 1;
            },
            0x0c, 0x0d => _ = try readU32At(bytes, &pos), // br, br_if
            0x0e => { // br_table
                const count = try readU32At(bytes, &pos);
                var i: u32 = 0;
                while (i <= count) : (i += 1) _ = try readU32At(bytes, &pos);
            },
            0x0f => {}, // return
            0x10, 0x12 => { // call, return_call
                const at = pos;
                const idx = try readU32At(bytes, &pos);
                try sink.onFunc(idx, at, pos - at);
            },
            0x11, 0x13 => { // call_indirect, return_call_indirect
                const tat = pos;
                const tidx = try readU32At(bytes, &pos);
                try sink.onType(tidx, tat, pos - tat);
                const tbat = pos;
                const tbl = try readU32At(bytes, &pos);
                try sink.onTable(tbl, tbat, pos - tbat);
            },
            0x14, 0x15 => { // call_ref, return_call_ref (typed func refs)
                const at = pos;
                const idx = try readU32At(bytes, &pos);
                try sink.onType(idx, at, pos - at);
            },
            0x1a, 0x1b => {}, // drop, select
            0x1c => { // select t
                const count = try readU32At(bytes, &pos);
                var i: u32 = 0;
                while (i < count) : (i += 1) try skipValType(bytes, &pos);
            },
            0x20, 0x21, 0x22 => _ = try readU32At(bytes, &pos), // local.{get,set,tee}
            0x23, 0x24 => { // global.get, global.set
                const at = pos;
                const idx = try readU32At(bytes, &pos);
                try sink.onGlobal(idx, at, pos - at);
            },
            0x25, 0x26 => { // table.get, table.set
                const at = pos;
                const idx = try readU32At(bytes, &pos);
                try sink.onTable(idx, at, pos - at);
            },
            // Memory load/store: align u32 + offset u32. A multi-memory
            // alignment encoding has bit 6 set in `align`; if so, the
            // memidx follows. Otherwise memidx is implicitly 0 and we
            // treat memory 0 as referenced.
            0x28...0x3e => try readMemargWithMemRef(bytes, &pos, sink),
            0x3f, 0x40 => { // memory.size, memory.grow
                const at = pos;
                const midx = try readU32At(bytes, &pos);
                try sink.onMemory(midx, at, pos - at);
            },
            0x41 => _ = try readSignedAt(bytes, &pos, 32), // i32.const
            0x42 => _ = try readSignedAt(bytes, &pos, 64), // i64.const
            0x43 => { if (pos + 4 > bytes.len) return error.InvalidBody; pos += 4; }, // f32.const
            0x44 => { if (pos + 8 > bytes.len) return error.InvalidBody; pos += 8; }, // f64.const
            0x45...0xc4 => {}, // numeric/comparison/conversion: no operands
            0xd0 => { // ref.null reftype
                if (pos >= bytes.len) return error.InvalidBody;
                pos += 1; // single-byte reftype encoding (preview1 only uses funcref/externref)
            },
            0xd1 => {}, // ref.is_null
            0xd2 => { // ref.func
                const at = pos;
                const idx = try readU32At(bytes, &pos);
                try sink.onFunc(idx, at, pos - at);
            },
            0xd3, 0xd4 => {}, // ref.eq, ref.as_non_null
            0xd5, 0xd6 => _ = try readU32At(bytes, &pos), // br_on_null, br_on_non_null
            0xfc => try walkPrefixed0xFC(bytes, &pos, sink),
            0xfb => return error.UnsupportedOpcode, // GC proposal
            0xfd => return error.UnsupportedOpcode, // SIMD
            0xfe => return error.UnsupportedOpcode, // atomics
            else => return error.UnsupportedOpcode,
        }
        // Track block depth so the outer 0x0b is detected only once
        // we've fully consumed every nested control structure.
        switch (op) {
            0x02, 0x03, 0x04 => depth += 1,
            else => {},
        }
    }
}

fn walkConstExprs(bytes: []const u8, count: u32, sink: anytype) Error!void {
    // Each elem_expr is a sequence of operators terminated by 0x0b at
    // outer depth. `walkOps` already terminates at the outer 0x0b but
    // doesn't tell the caller where it stopped, so we drive a small
    // boundary scanner here and call `walkOps` once per expression.
    var pos: usize = 0;
    var consumed: u32 = 0;
    while (consumed < count and pos < bytes.len) : (consumed += 1) {
        const start = pos;
        var depth: usize = 0;
        while (pos < bytes.len) {
            const op = bytes[pos];
            if (op == 0x0b and depth == 0) {
                pos += 1;
                break;
            }
            switch (op) {
                0x02, 0x03, 0x04 => depth += 1,
                0x0b => depth -= 1,
                else => {},
            }
            pos += 1;
        }
        try walkOps(bytes[start..pos], sink);
    }
}

fn walkPrefixed0xFC(bytes: []const u8, pos: *usize, sink: anytype) Error!void {
    const sub = try readU32At(bytes, pos);
    switch (sub) {
        0...7 => {}, // saturating float-to-int: no operands
        8 => { // memory.init dataidx u32 + memidx u32
            const dat = pos.*;
            const di = try readU32At(bytes, pos);
            try sink.onData(di, dat, pos.* - dat);
            const mat = pos.*;
            const mi = try readU32At(bytes, pos);
            try sink.onMemory(mi, mat, pos.* - mat);
        },
        9 => { // data.drop dataidx
            const at = pos.*;
            const di = try readU32At(bytes, pos);
            try sink.onData(di, at, pos.* - at);
        },
        10 => { // memory.copy dst src
            const dat = pos.*;
            const di = try readU32At(bytes, pos);
            try sink.onMemory(di, dat, pos.* - dat);
            const sat = pos.*;
            const si = try readU32At(bytes, pos);
            try sink.onMemory(si, sat, pos.* - sat);
        },
        11 => { // memory.fill memidx
            const at = pos.*;
            const mi = try readU32At(bytes, pos);
            try sink.onMemory(mi, at, pos.* - at);
        },
        12 => { // table.init elemidx + tableidx
            const eat = pos.*;
            const ei = try readU32At(bytes, pos);
            try sink.onElem(ei, eat, pos.* - eat);
            const tat = pos.*;
            const ti = try readU32At(bytes, pos);
            try sink.onTable(ti, tat, pos.* - tat);
        },
        13 => { // elem.drop elemidx
            const at = pos.*;
            const ei = try readU32At(bytes, pos);
            try sink.onElem(ei, at, pos.* - at);
        },
        14 => { // table.copy dst src
            const dat = pos.*;
            const di = try readU32At(bytes, pos);
            try sink.onTable(di, dat, pos.* - dat);
            const sat = pos.*;
            const si = try readU32At(bytes, pos);
            try sink.onTable(si, sat, pos.* - sat);
        },
        15, 16, 17 => { // table.grow / table.size / table.fill <tableidx>
            const at = pos.*;
            const ti = try readU32At(bytes, pos);
            try sink.onTable(ti, at, pos.* - at);
        },
        else => return error.UnsupportedOpcode,
    }
}

/// Block-type encoding: a single byte 0x40 (empty), or a single
/// negative-LEB-encoded valtype (one byte for primitive valtypes), or
/// a non-negative s33 LEB128 typeidx. The first byte is enough to
/// distinguish: all valid valtype bytes are >= 0x6F (highest valtype:
/// externref = 0x6F, funcref = 0x70, …, exnref = 0x69), and 0x40 is
/// the empty marker. Values < 0x40 (high bit clear) are typeidx.
fn skipBlockType(bytes: []const u8, pos: *usize, sink: anytype) Error!void {
    if (pos.* >= bytes.len) return error.InvalidBody;
    const b = bytes[pos.*];
    if (b == 0x40) {
        pos.* += 1;
        return;
    }
    // Single-byte valtypes (high bit set, range 0x6F..0x7F):
    if (b >= 0x6F) {
        pos.* += 1;
        return;
    }
    // Otherwise it's a positive s33 LEB128 typeidx.
    const at = pos.*;
    const ti = try readU32At(bytes, pos);
    try sink.onType(ti, at, pos.* - at);
}

fn skipValType(bytes: []const u8, pos: *usize) Error!void {
    if (pos.* >= bytes.len) return error.InvalidBody;
    pos.* += 1; // primitive valtypes are single-byte; preview1 doesn't use indexed valtypes here
}

/// Memory load/store memarg = align u32 + offset u32. Per the
/// multi-memory proposal, bit 6 of the encoded `align` is set when a
/// memidx follows. `pos` points to the byte after the load/store
/// opcode.
fn readMemargWithMemRef(bytes: []const u8, pos: *usize, sink: anytype) Error!void {
    const al_at = pos.*;
    const al_raw = try readU32At(bytes, pos);
    const has_memidx = (al_raw & 0x40) != 0;
    _ = al_at;
    if (has_memidx) {
        const mat = pos.*;
        const mi = try readU32At(bytes, pos);
        try sink.onMemory(mi, mat, pos.* - mat);
    } else {
        // Implicit memidx 0; mark live without a byte position.
        try sink.onMemory(0, std.math.maxInt(usize), 0);
    }
    _ = try readU32At(bytes, pos); // offset
}

fn readU32At(bytes: []const u8, pos: *usize) Error!u32 {
    const r = leb128.readU32Leb128(bytes[pos.*..]) catch return error.InvalidBody;
    pos.* += r.bytes_read;
    return r.value;
}

fn readSignedAt(bytes: []const u8, pos: *usize, comptime bits: u8) Error!void {
    if (bits == 32) {
        const r = leb128.readS32Leb128(bytes[pos.*..]) catch return error.InvalidBody;
        pos.* += r.bytes_read;
    } else {
        const r = leb128.readS64Leb128(bytes[pos.*..]) catch return error.InvalidBody;
        pos.* += r.bytes_read;
    }
}

// ── Renumbering ─────────────────────────────────────────────────────────

const Remaps = struct {
    funcs: []u32,
    globals: []u32,
    tables: []u32,
    memories: []u32,
    types: []u32,
    data: []u32,
    elems: []u32,

    fn deinit(self: Remaps, gpa: Allocator) void {
        gpa.free(self.funcs);
        gpa.free(self.globals);
        gpa.free(self.tables);
        gpa.free(self.memories);
        gpa.free(self.types);
        gpa.free(self.data);
        gpa.free(self.elems);
    }

    fn compute(gpa: Allocator, live: *const LiveSets, m: *const Mod.Module) !Remaps {
        return .{
            .funcs = try buildRemap(gpa, &live.funcs, m.funcs.items.len),
            .globals = try buildRemap(gpa, &live.globals, m.globals.items.len),
            .tables = try buildRemap(gpa, &live.tables, m.tables.items.len),
            .memories = try buildRemap(gpa, &live.memories, m.memories.items.len),
            .types = try buildRemap(gpa, &live.types, m.module_types.items.len),
            .data = try buildRemap(gpa, &live.data, m.data_segments.items.len),
            .elems = try buildRemap(gpa, &live.elems, m.elem_segments.items.len),
        };
    }
};

fn buildRemap(gpa: Allocator, live: *const std.DynamicBitSetUnmanaged, n: usize) ![]u32 {
    const out = try gpa.alloc(u32, n);
    var next: u32 = 0;
    for (out, 0..) |*slot, i| {
        if (live.isSet(i)) {
            slot.* = next;
            next += 1;
        } else {
            slot.* = SENTINEL;
        }
    }
    return out;
}

const RewriteSink = struct {
    out: *std.ArrayListUnmanaged(u8),
    src: []const u8,
    cursor: *usize, // tracks how much of `src` has been copied to `out`
    gpa: Allocator,
    remaps: *const Remaps,

    fn flushUntil(self: *RewriteSink, until: usize) !void {
        if (until > self.cursor.*) {
            try self.out.appendSlice(self.gpa, self.src[self.cursor.*..until]);
            self.cursor.* = until;
        }
    }

    fn rewriteAt(self: *RewriteSink, byte_pos: usize, byte_len: usize, new_idx: u32) !void {
        if (byte_pos == std.math.maxInt(usize)) return; // implicit memidx 0
        try self.flushUntil(byte_pos);
        var tmp: [leb128.max_u32_bytes]u8 = undefined;
        const n = leb128.writeU32Leb128(&tmp, new_idx);
        try self.out.appendSlice(self.gpa, tmp[0..n]);
        self.cursor.* = byte_pos + byte_len;
    }

    fn onFunc(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.funcs[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
    fn onType(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.types[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
    fn onGlobal(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.globals[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
    fn onTable(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.tables[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
    fn onMemory(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.memories[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
    fn onData(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.data[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
    fn onElem(self: *RewriteSink, idx: u32, byte_pos: usize, byte_len: usize) Error!void {
        const new = self.remaps.elems[idx];
        if (new == SENTINEL) return error.InvalidBody;
        try self.rewriteAt(byte_pos, byte_len, new);
    }
};

fn rewriteFuncBody(
    gpa: Allocator,
    src: []const u8,
    remaps: *const Remaps,
) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(gpa);
    var cursor: usize = 0;
    var sink = RewriteSink{
        .out = &out,
        .src = src,
        .cursor = &cursor,
        .gpa = gpa,
        .remaps = remaps,
    };
    try walkOps(src, &sink);
    // Append the trailing portion (past the last reference patched).
    try sink.flushUntil(src.len);
    return try out.toOwnedSlice(gpa);
}

// ── Build new module from live items ────────────────────────────────────

fn emitLive(
    gpa: Allocator,
    out: *Mod.Module,
    src: *const Mod.Module,
    live: *const LiveSets,
    remaps: *const Remaps,
) Error!void {
    // Types: copy live entries in order.
    for (src.module_types.items, 0..) |t, i| {
        if (!live.types.isSet(i)) continue;
        const cloned = try cloneTypeEntry(gpa, t);
        try out.module_types.append(gpa, cloned);
    }

    // Imports come first in the original; drop dead ones, renumber
    // type idxs in surviving func imports.
    for (src.imports.items) |im| {
        const keep = switch (im.kind) {
            .func => keep: {
                // Look up the func slot this import contributed to.
                const fidx = findImportFuncIdx(src, im) orelse break :keep false;
                break :keep live.funcs.isSet(fidx);
            },
            .global => keep: {
                const gidx = findImportGlobalIdx(src, im) orelse break :keep false;
                break :keep live.globals.isSet(gidx);
            },
            .table => keep: {
                const tidx = findImportTableIdx(src, im) orelse break :keep false;
                break :keep live.tables.isSet(tidx);
            },
            .memory => keep: {
                const midx = findImportMemoryIdx(src, im) orelse break :keep false;
                break :keep live.memories.isSet(midx);
            },
            .tag => false,
        };
        if (!keep) continue;
        var new = im;
        if (im.kind == .func and im.func != null) {
            new.func = .{
                .type_var = remapVar(im.func.?.type_var, remaps.types),
                .sig = im.func.?.sig,
            };
        }
        try out.imports.append(gpa, new);
        switch (new.kind) {
            .func => out.num_func_imports += 1,
            .global => out.num_global_imports += 1,
            .table => out.num_table_imports += 1,
            .memory => out.num_memory_imports += 1,
            .tag => out.num_tag_imports += 1,
        }
    }

    // Funcs: imports already added above; now add defined funcs.
    // We must replicate the import-funcs as Func entries first
    // (the writer needs to walk the funcs list in import order to
    // emit the function/code sections). Then append live defined
    // funcs with rewritten bodies.
    for (src.imports.items) |im| {
        if (im.kind != .func) continue;
        const fidx = findImportFuncIdx(src, im) orelse continue;
        if (!live.funcs.isSet(fidx)) continue;
        var f = src.funcs.items[fidx];
        f.decl = .{
            .type_var = remapVar(f.decl.type_var, remaps.types),
            .sig = f.decl.sig,
        };
        try out.funcs.append(gpa, f);
    }
    for (src.funcs.items[src.num_func_imports..], src.num_func_imports..) |f, i| {
        if (!live.funcs.isSet(i)) continue;
        var clone = f;
        clone.decl = .{
            .type_var = remapVar(f.decl.type_var, remaps.types),
            .sig = f.decl.sig,
        };
        clone.code_bytes = try rewriteFuncBody(gpa, f.code_bytes, remaps);
        clone.owns_code_bytes = true;
        // local_types/local_type_idxs are deep-cloned into the new
        // module so it can deinit them independently.
        clone.local_types = .empty;
        try clone.local_types.appendSlice(gpa, f.local_types.items);
        clone.local_type_idxs = .empty;
        try clone.local_type_idxs.appendSlice(gpa, f.local_type_idxs.items);
        try out.funcs.append(gpa, clone);
    }

    // Tables, memories, globals: imports first, then defined.
    for (src.tables.items, 0..) |t, i| {
        if (!live.tables.isSet(i)) continue;
        try out.tables.append(gpa, t);
    }
    for (src.memories.items, 0..) |mem, i| {
        if (!live.memories.isSet(i)) continue;
        try out.memories.append(gpa, mem);
    }
    for (src.globals.items, 0..) |g, i| {
        if (!live.globals.isSet(i)) continue;
        var clone = g;
        // Init exprs are constant exprs that may reference globals/funcs;
        // for the preview1 adapter they're all `i32.const 0` so passing
        // through is safe, but rewrite for correctness.
        if (g.init_expr_bytes.len > 0 and !g.is_import) {
            clone.init_expr_bytes = try rewriteFuncBody(gpa, g.init_expr_bytes, remaps);
            clone.owns_init_expr_bytes = true;
        }
        try out.globals.append(gpa, clone);
    }

    // Exports: drop those targeting dead entities, renumber.
    for (src.exports.items) |e| {
        const idx: u32 = switch (e.var_) {
            .index => |x| x,
            .name => continue,
        };
        const new_idx: u32 = switch (e.kind) {
            .func => remaps.funcs[idx],
            .global => remaps.globals[idx],
            .table => remaps.tables[idx],
            .memory => remaps.memories[idx],
            .tag => continue,
        };
        if (new_idx == SENTINEL) continue;
        try out.exports.append(gpa, .{
            .name = e.name,
            .kind = e.kind,
            .var_ = .{ .index = new_idx },
        });
    }

    // Element segments: keep only live ones, renumber funcref
    // contents and the table_var.
    for (src.elem_segments.items, 0..) |seg, i| {
        if (!live.elems.isSet(i)) continue;
        var clone = seg;
        clone.table_var = remapVar(seg.table_var, remaps.tables);
        clone.elem_var_indices = .empty;
        for (seg.elem_var_indices.items) |v| {
            try clone.elem_var_indices.append(gpa, remapVar(v, remaps.funcs));
        }
        if (seg.offset_expr_bytes.len > 0) {
            clone.offset_expr_bytes = try rewriteFuncBody(gpa, seg.offset_expr_bytes, remaps);
            clone.owns_offset_expr_bytes = true;
        }
        if (seg.elem_expr_bytes.len > 0) {
            clone.elem_expr_bytes = try rewriteFuncBody(gpa, seg.elem_expr_bytes, remaps);
            clone.owns_elem_expr_bytes = true;
        }
        try out.elem_segments.append(gpa, clone);
    }

    // Data segments: keep only live ones, renumber memory_var and
    // offset expr.
    for (src.data_segments.items, 0..) |seg, i| {
        if (!live.data.isSet(i)) continue;
        var clone = seg;
        clone.memory_var = remapVar(seg.memory_var, remaps.memories);
        if (seg.offset_expr_bytes.len > 0) {
            clone.offset_expr_bytes = try rewriteFuncBody(gpa, seg.offset_expr_bytes, remaps);
            clone.owns_offset_expr_bytes = true;
        }
        // Data bytes are owned by the source; the new module gets an
        // unowned view (the writer copies).
        clone.owns_data = false;
        try out.data_segments.append(gpa, clone);
    }
    if (src.has_data_count) {
        out.has_data_count = true;
        out.data_count = @intCast(out.data_segments.items.len);
    }

    // Custom sections: pass through verbatim. The encoded-world
    // payload notably stays intact; `types_import.zig:hoist` filters
    // its decls separately.
    for (src.customs.items) |c| try out.customs.append(gpa, c);

    // Start: drop if its target died.
    if (src.start_var) |sv| switch (sv) {
        .index => |i| if (i < remaps.funcs.len and remaps.funcs[i] != SENTINEL) {
            out.start_var = .{ .index = remaps.funcs[i] };
        },
        .name => {},
    };
}

fn findImportFuncIdx(m: *const Mod.Module, im: Mod.Import) ?u32 {
    var k: u32 = 0;
    for (m.imports.items) |x| {
        if (x.kind == .func and importsEqual(x, im)) return k;
        if (x.kind == .func) k += 1;
    }
    return null;
}
fn findImportGlobalIdx(m: *const Mod.Module, im: Mod.Import) ?u32 {
    var k: u32 = 0;
    for (m.imports.items) |x| {
        if (x.kind == .global and importsEqual(x, im)) return k;
        if (x.kind == .global) k += 1;
    }
    return null;
}
fn findImportTableIdx(m: *const Mod.Module, im: Mod.Import) ?u32 {
    var k: u32 = 0;
    for (m.imports.items) |x| {
        if (x.kind == .table and importsEqual(x, im)) return k;
        if (x.kind == .table) k += 1;
    }
    return null;
}
fn findImportMemoryIdx(m: *const Mod.Module, im: Mod.Import) ?u32 {
    var k: u32 = 0;
    for (m.imports.items) |x| {
        if (x.kind == .memory and importsEqual(x, im)) return k;
        if (x.kind == .memory) k += 1;
    }
    return null;
}

fn importsEqual(a: Mod.Import, b: Mod.Import) bool {
    return a.kind == b.kind and
        std.mem.eql(u8, a.module_name, b.module_name) and
        std.mem.eql(u8, a.field_name, b.field_name);
}

fn remapVar(v: Mod.Var, remap: []const u32) Mod.Var {
    return switch (v) {
        .index => |i| .{ .index = if (i < remap.len) remap[i] else i },
        .name => v,
    };
}

fn cloneTypeEntry(gpa: Allocator, t: Mod.TypeEntry) !Mod.TypeEntry {
    return switch (t) {
        .func_type => |ft| .{ .func_type = .{
            .params = try gpa.dupe(wtypes.ValType, ft.params),
            .results = try gpa.dupe(wtypes.ValType, ft.results),
            .param_type_idxs = try gpa.dupe(u32, ft.param_type_idxs),
            .result_type_idxs = try gpa.dupe(u32, ft.result_type_idxs),
        } },
        else => t, // struct/array types not used by preview1 adapter
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "gc.run: drops unused imports and renumbers calls" {
    // Synthetic core wasm:
    //   types: [() -> ()]
    //   imports:
    //     "wasi:cli/stdout" "ping" (func (type 0))   -- live, called by F1
    //     "wasi:filesystem/types" "advise" (func (type 0)) -- DEAD
    //   funcs (defined):
    //     F0 = (func (type 0) (call $stdout_ping)) -- live (exported)
    //     F1 = (func (type 0) (call $stdout_ping)) -- alias of F0; live transitively iff exported
    //   exports:
    //     "fd_write" -> F0
    //
    // After gc.run with required = ["fd_write"]:
    //   * F0 is live (export root).
    //   * F0 calls import #0 (stdout_ping) → live.
    //   * F1 is unreferenced → dead.
    //   * Import #1 (filesystem.advise) is unreferenced → dead.
    //
    // Assertions:
    //   * out.imports.len == 1, name "wasi:cli/stdout"."ping"
    //   * out.funcs.len == 2 (1 import + 1 defined)
    //   * out.exports[0].name == "fd_write" and points at the live func.

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const adapter_bytes = try buildSyntheticAdapter(ar);
    const out = try run(testing.allocator, adapter_bytes, &[_][]const u8{"fd_write"});
    defer testing.allocator.free(out);

    var out_mod = try reader.readModule(testing.allocator, out);
    defer out_mod.deinit();

    try testing.expectEqual(@as(usize, 1), out_mod.imports.items.len);
    try testing.expectEqualStrings("wasi:cli/stdout", out_mod.imports.items[0].module_name);
    try testing.expectEqualStrings("ping", out_mod.imports.items[0].field_name);

    try testing.expectEqual(@as(usize, 2), out_mod.funcs.items.len);
    try testing.expectEqual(@as(u32, 1), out_mod.num_func_imports);

    try testing.expectEqual(@as(usize, 1), out_mod.exports.items.len);
    try testing.expectEqualStrings("fd_write", out_mod.exports.items[0].name);
    try testing.expectEqual(Mod.Var{ .index = 1 }, out_mod.exports.items[0].var_);
}

test "gc.run: missing required export errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const adapter_bytes = try buildSyntheticAdapter(ar);
    const r = run(testing.allocator, adapter_bytes, &[_][]const u8{"nope"});
    try testing.expectError(error.MissingRequiredExport, r);
}

test "gc.run: preserves cabi_import_realloc when exported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const adapter_bytes = try buildSyntheticAdapterWithRealloc(ar);
    const out = try run(testing.allocator, adapter_bytes, &[_][]const u8{"fd_write"});
    defer testing.allocator.free(out);

    var out_mod = try reader.readModule(testing.allocator, out);
    defer out_mod.deinit();

    var saw_realloc = false;
    for (out_mod.exports.items) |e| {
        if (std.mem.eql(u8, e.name, "cabi_import_realloc")) saw_realloc = true;
    }
    try testing.expect(saw_realloc);
}

test "gc.run: preserves custom sections verbatim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const adapter_bytes = try buildSyntheticAdapterWithCustom(ar);
    const out = try run(testing.allocator, adapter_bytes, &[_][]const u8{"fd_write"});
    defer testing.allocator.free(out);

    // Re-parse and check the custom section survives.
    var out_mod = try reader.readModule(testing.allocator, out);
    defer out_mod.deinit();
    var saw_custom = false;
    for (out_mod.customs.items) |c| {
        if (std.mem.eql(u8, c.name, "x-marker")) {
            saw_custom = true;
            try testing.expectEqualSlices(u8, "hello", c.data);
        }
    }
    try testing.expect(saw_custom);
}

// ── Test fixtures ───────────────────────────────────────────────────────

fn buildSyntheticAdapter(arena: Allocator) ![]const u8 {
    // Build a tiny core wasm by hand, mirroring what wabt's binary
    // writer would emit. Modules with no body deps can be hand-built;
    // this keeps the test independent of the wabt writer's behavior.
    var b = std.ArrayListUnmanaged(u8).empty;
    defer b.deinit(arena);
    try b.appendSlice(arena, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    // Type section: 1 type = (func)
    try emitSection(arena, &b, 1, &.{ 0x01, 0x60, 0x00, 0x00 });

    // Import section: 2 func imports.
    //   "wasi:cli/stdout"."ping" func type=0
    //   "wasi:filesystem/types"."advise" func type=0
    var imp_body = std.ArrayListUnmanaged(u8).empty;
    defer imp_body.deinit(arena);
    try imp_body.append(arena, 2);
    try writeName(arena, &imp_body, "wasi:cli/stdout");
    try writeName(arena, &imp_body, "ping");
    try imp_body.appendSlice(arena, &.{ 0x00, 0x00 }); // kind=func, type=0
    try writeName(arena, &imp_body, "wasi:filesystem/types");
    try writeName(arena, &imp_body, "advise");
    try imp_body.appendSlice(arena, &.{ 0x00, 0x00 });
    try emitSection(arena, &b, 2, imp_body.items);

    // Function section: 2 defined funcs, both type 0.
    try emitSection(arena, &b, 3, &.{ 0x02, 0x00, 0x00 });

    // Export section: "fd_write" -> func 2 (= F0, the first defined).
    var exp_body = std.ArrayListUnmanaged(u8).empty;
    defer exp_body.deinit(arena);
    try exp_body.append(arena, 1);
    try writeName(arena, &exp_body, "fd_write");
    try exp_body.appendSlice(arena, &.{ 0x00, 0x02 });
    try emitSection(arena, &b, 7, exp_body.items);

    // Code section: 2 funcs.
    //   F0 body: (call $stdout_ping); end
    //   F1 body: (call $stdout_ping); end  -- distinct func, same body
    var code_body = std.ArrayListUnmanaged(u8).empty;
    defer code_body.deinit(arena);
    try code_body.append(arena, 2);
    // F0
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(arena);
        try body.append(arena, 0); // 0 locals
        try body.appendSlice(arena, &.{ 0x10, 0x00 }); // call func 0 (stdout_ping)
        try body.append(arena, 0x0b); // end
        try code_body.append(arena, @intCast(body.items.len));
        try code_body.appendSlice(arena, body.items);
    }
    // F1
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(arena);
        try body.append(arena, 0);
        try body.appendSlice(arena, &.{ 0x10, 0x01 }); // call func 1 (filesystem.advise)
        try body.append(arena, 0x0b);
        try code_body.append(arena, @intCast(body.items.len));
        try code_body.appendSlice(arena, body.items);
    }
    try emitSection(arena, &b, 10, code_body.items);

    return try arena.dupe(u8, b.items);
}

fn buildSyntheticAdapterWithRealloc(arena: Allocator) ![]const u8 {
    // Same as buildSyntheticAdapter but with an extra "cabi_import_realloc"
    // export pointing at F1 (the otherwise-dead func). After gc, that
    // export should keep F1 alive and surface in the output.
    var b = std.ArrayListUnmanaged(u8).empty;
    defer b.deinit(arena);
    try b.appendSlice(arena, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    try emitSection(arena, &b, 1, &.{ 0x01, 0x60, 0x00, 0x00 });

    var imp_body = std.ArrayListUnmanaged(u8).empty;
    defer imp_body.deinit(arena);
    try imp_body.append(arena, 2);
    try writeName(arena, &imp_body, "wasi:cli/stdout");
    try writeName(arena, &imp_body, "ping");
    try imp_body.appendSlice(arena, &.{ 0x00, 0x00 });
    try writeName(arena, &imp_body, "wasi:filesystem/types");
    try writeName(arena, &imp_body, "advise");
    try imp_body.appendSlice(arena, &.{ 0x00, 0x00 });
    try emitSection(arena, &b, 2, imp_body.items);

    try emitSection(arena, &b, 3, &.{ 0x02, 0x00, 0x00 });

    var exp_body = std.ArrayListUnmanaged(u8).empty;
    defer exp_body.deinit(arena);
    try exp_body.append(arena, 2);
    try writeName(arena, &exp_body, "fd_write");
    try exp_body.appendSlice(arena, &.{ 0x00, 0x02 });
    try writeName(arena, &exp_body, "cabi_import_realloc");
    try exp_body.appendSlice(arena, &.{ 0x00, 0x03 });
    try emitSection(arena, &b, 7, exp_body.items);

    var code_body = std.ArrayListUnmanaged(u8).empty;
    defer code_body.deinit(arena);
    try code_body.append(arena, 2);
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(arena);
        try body.append(arena, 0);
        try body.appendSlice(arena, &.{ 0x10, 0x00 });
        try body.append(arena, 0x0b);
        try code_body.append(arena, @intCast(body.items.len));
        try code_body.appendSlice(arena, body.items);
    }
    {
        var body = std.ArrayListUnmanaged(u8).empty;
        defer body.deinit(arena);
        try body.append(arena, 0);
        try body.append(arena, 0x0b);
        try code_body.append(arena, @intCast(body.items.len));
        try code_body.appendSlice(arena, body.items);
    }
    try emitSection(arena, &b, 10, code_body.items);

    return try arena.dupe(u8, b.items);
}

fn buildSyntheticAdapterWithCustom(arena: Allocator) ![]const u8 {
    const base = try buildSyntheticAdapter(arena);
    var b = std.ArrayListUnmanaged(u8).empty;
    defer b.deinit(arena);
    try b.appendSlice(arena, base);
    var custom_body = std.ArrayListUnmanaged(u8).empty;
    defer custom_body.deinit(arena);
    try writeName(arena, &custom_body, "x-marker");
    try custom_body.appendSlice(arena, "hello");
    try emitSection(arena, &b, 0, custom_body.items);
    return try arena.dupe(u8, b.items);
}

fn emitSection(arena: Allocator, out: *std.ArrayListUnmanaged(u8), id: u8, body: []const u8) !void {
    try out.append(arena, id);
    var tmp: [leb128.max_u32_bytes]u8 = undefined;
    const n = leb128.writeU32Leb128(&tmp, @intCast(body.len));
    try out.appendSlice(arena, tmp[0..n]);
    try out.appendSlice(arena, body);
}

fn writeName(arena: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    var tmp: [leb128.max_u32_bytes]u8 = undefined;
    const n = leb128.writeU32Leb128(&tmp, @intCast(s.len));
    try out.appendSlice(arena, tmp[0..n]);
    try out.appendSlice(arena, s);
}
