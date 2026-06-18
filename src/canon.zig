//! `canon` — a comptime Component-Model **canonical ABI** value marshaller.
//!
//! Given an ordinary Zig type, this module computes the canonical memory
//! layout (`alignOf` / `sizeOf`) and lowers/lifts values to/from linear memory
//! exactly as the Component Model canonical ABI specifies — so a guest never
//! hand-writes `extern struct` layouts or pointer arithmetic for records,
//! options, strings, or lists. It is the in-memory half of the ABI (the part
//! used for aggregate params/results that spill to memory); flat scalar slots
//! that a core function passes directly are handled by the caller.
//!
//! ## Zig → WIT type mapping
//!
//!   | Zig                         | WIT            |
//!   | --------------------------- | -------------- |
//!   | `bool`                      | `bool`         |
//!   | `u8/u16/u32/u64`            | `u8/u16/u32/u64` |
//!   | `i8/i16/i32/i64`            | `s8/s16/s32/s64` |
//!   | `f32` / `f64`               | `f32` / `f64`  |
//!   | `[]const u8`                | `string`       |
//!   | `[]const T` (T ≠ u8)        | `list<T>`      |
//!   | `?T`                        | `option<T>`    |
//!   | `enum`                      | `enum`         |
//!   | `struct { … }`              | `record`       |
//!   | tuple `struct { T, U }`     | `tuple<T, U>`  |
//!
//! ## Layout rules (canonical ABI)
//!
//!   * `align(T)` / `size(T)` follow the spec: records concatenate fields at
//!     their alignment; `option<T>` is a 2-case variant — a 1-byte
//!     discriminant, the payload at `align(T)`, padded to `align(T)`;
//!     `string`/`list` are a `(ptr: u32, len: u32)` pair (size 8, align 4 on
//!     wasm32).
//!   * A value wider than one core slot is returned/received through a pointer
//!     to such a layout; `RetArea(T)` provides the static return area an export
//!     returns by address.

const std = @import("std");

/// A bump allocator the canonical ABI calls to place `string` / `list` element
/// storage during `lower` (the guest's `cabi_realloc` arena). `lift` borrows
/// memory and needs none.
pub const Realloc = *const fn (size: usize, alignment: usize) [*]u8;

inline fn alignTo(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

fn intBytes(comptime bits: u16) usize {
    return switch (bits) {
        8 => 1,
        16 => 2,
        32 => 4,
        64 => 8,
        else => @compileError("canon: only 8/16/32/64-bit integers are supported"),
    };
}

/// The integer type of a variant/enum discriminant with `n` cases.
fn DiscInt(comptime n: usize) type {
    return if (n <= 0x100) u8 else if (n <= 0x10000) u16 else u32;
}

// ── Variant / result (Zig `union(enum)`) helpers ────────────────────
//
// A WIT `variant` / `result<T, E>` lowers to a tagged union: a discriminant
// (the case index) followed by the active case's payload. A Zig `union(enum)`
// with `void` payloads for no-data cases models it exactly. The payload sits at
// the discriminant's end, padded to the widest case alignment.

/// Max canonical alignment among a union's case payloads (1 if all `void`).
fn unionPayloadAlign(comptime T: type) usize {
    var a: usize = 1;
    inline for (@typeInfo(T).@"union".fields) |f| {
        if (f.type != void) a = @max(a, alignOf(f.type));
    }
    return a;
}

/// Max canonical size among a union's case payloads (0 if all `void`).
fn unionPayloadSize(comptime T: type) usize {
    var s: usize = 0;
    inline for (@typeInfo(T).@"union".fields) |f| {
        if (f.type != void) s = @max(s, sizeOf(f.type));
    }
    return s;
}

/// Byte offset of a union payload: past the discriminant, padded to the
/// payload alignment.
fn unionPayloadOffset(comptime T: type) usize {
    const disc = @sizeOf(DiscInt(@typeInfo(T).@"union".fields.len));
    return alignTo(disc, unionPayloadAlign(T));
}

/// The Zig type for a WIT `result<T, E>`: a tagged union the marshaller
/// lowers/lifts as a 2-case variant. Pass `void` for an absent (`_`) arm.
///
/// Naming the type through this memoized constructor — rather than spelling an
/// inline `union(enum) { … }` at each binding site — keeps it identical across
/// modules, so a generated export shell and the user `impl` it calls agree on
/// the type (two textually-identical inline unions are distinct nominal types).
pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) { ok: T, err: E };
}

/// The Zig type for a WIT `tuple<…>`: a tuple struct the marshaller lowers/lifts
/// as a record (fields concatenated at their canonical alignment). Memoized so
/// it is identical across modules. `Ts` is a tuple of element types, e.g.
/// `canon.Tuple(.{ u32, []const u8 })`.
pub fn Tuple(comptime Ts: anytype) type {
    return std.meta.Tuple(&Ts);
}

/// The Zig type for a WIT `future<T>`: an async single-value channel. At the
/// canonical ABI it is a single `i32` handle (the readable or writable end);
/// the element type `T` is carried for read/write helpers. Lowers/lifts as a
/// single-field record (the handle).
pub fn Future(comptime T: type) type {
    return struct {
        handle: i32,
        pub const Element = T;
    };
}

/// The Zig type for a WIT `stream<T>`: an async multi-value channel. Like
/// `Future`, a single `i32` handle at the canonical ABI.
pub fn Stream(comptime T: type) type {
    return struct {
        handle: i32,
        pub const Element = T;
    };
}

/// The Zig type for a WIT `error-context`: an opaque async error value, a single
/// `i32` handle at the canonical ABI.
pub const ErrorContextHandle = struct { handle: i32 };

// ── Flags (Zig `packed struct`) ─────────────────────────────────────
//
// A WIT `flags` lowers to a bitset: one bit per label, packed LSB-first into an
// integer of 1/2/4 bytes (≤8/≤16/≤32 labels). A Zig `packed struct(uN)` of
// `bool` fields (in label order) has exactly that representation, so the
// marshaller treats any packed struct as its backing integer.

fn PackedInt(comptime T: type) type {
    return @typeInfo(T).@"struct".backing_integer.?;
}

/// Widen a flags value to its flat i32 core slot.
fn packedToCore(comptime T: type, value: T) i32 {
    return @bitCast(@as(u32, @as(PackedInt(T), @bitCast(value))));
}

/// Rebuild a flags value from its flat i32 core slot.
fn packedFromCore(comptime T: type, core: anytype) T {
    return @bitCast(@as(PackedInt(T), @truncate(@as(u32, @bitCast(@as(i32, core))))));
}

// ── Layout ──────────────────────────────────────────────────────────

/// Canonical alignment of `T`, in bytes.
pub fn alignOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| intBytes(i.bits),
        .float => |f| intBytes(f.bits),
        .@"enum" => |e| @sizeOf(DiscInt(e.fields.len)),
        .optional => |o| @max(@as(usize, 1), alignOf(o.child)),
        .pointer => |p| if (p.size == .slice) @alignOf(usize) else unsupported(T),
        .@"struct" => |s| if (s.layout == .@"packed") @alignOf(T) else blk: {
            var a: usize = 1;
            inline for (s.fields) |f| a = @max(a, alignOf(f.type));
            break :blk a;
        },
        .@"union" => |u| @max(@as(usize, @sizeOf(DiscInt(u.fields.len))), unionPayloadAlign(T)),
        else => unsupported(T),
    };
}

/// Canonical size of `T`, in bytes.
pub fn sizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| intBytes(i.bits),
        .float => |f| intBytes(f.bits),
        .@"enum" => |e| @sizeOf(DiscInt(e.fields.len)),
        .optional => |o| blk: {
            const pa = alignOf(o.child);
            break :blk alignTo(alignTo(1, pa) + sizeOf(o.child), @max(@as(usize, 1), pa));
        },
        .pointer => |p| if (p.size == .slice) 2 * @sizeOf(usize) else unsupported(T),
        .@"struct" => |s| if (s.layout == .@"packed") @sizeOf(T) else blk: {
            var off: usize = 0;
            inline for (s.fields) |f| {
                off = alignTo(off, alignOf(f.type)) + sizeOf(f.type);
            }
            break :blk alignTo(off, alignOf(T));
        },
        .@"union" => alignTo(unionPayloadOffset(T) + unionPayloadSize(T), alignOf(T)),
        else => unsupported(T),
    };
}

/// Byte offset of struct field `idx` within `T`'s canonical record layout.
fn fieldOffset(comptime T: type, comptime idx: usize) usize {
    const fields = @typeInfo(T).@"struct".fields;
    var off: usize = 0;
    inline for (fields, 0..) |f, i| {
        off = alignTo(off, alignOf(f.type));
        if (i == idx) return off;
        off += sizeOf(f.type);
    }
    @compileError("canon: field index out of range");
}

/// Byte offset of an `option<T>` payload (the discriminant occupies byte 0).
fn payloadOffset(comptime T: type) usize {
    return alignTo(1, alignOf(@typeInfo(T).optional.child));
}

fn unsupported(comptime T: type) noreturn {
    @compileError("canon: unsupported type " ++ @typeName(T));
}

// ── Lower (value → memory) ──────────────────────────────────────────

fn store(comptime T: type, base: [*]u8, value: T) void {
    const p: *align(1) T = @ptrCast(base);
    p.* = value;
}

/// Lower `value` into `base..base+sizeOf(T)` (caller-allocated, aligned to
/// `alignOf(T)`) per the canonical ABI; `string`/`list` element storage is
/// allocated via `ra`.
pub fn lower(comptime T: type, value: T, base: [*]u8, ra: Realloc) void {
    switch (@typeInfo(T)) {
        .bool => base[0] = @intFromBool(value),
        .int => store(T, base, value),
        .float => store(T, base, value),
        .@"enum" => |e| store(DiscInt(e.fields.len), base, @intCast(@intFromEnum(value))),
        .optional => |o| if (value) |v| {
            base[0] = 1;
            lower(o.child, v, base + payloadOffset(T), ra);
        } else {
            base[0] = 0;
        },
        .pointer => |p| lowerSlice(p.child, value, base, ra),
        .@"struct" => |s| if (s.layout == .@"packed") {
            store(PackedInt(T), base, @bitCast(value));
        } else inline for (s.fields, 0..) |f, i| {
            lower(f.type, @field(value, f.name), base + fieldOffset(T, i), ra);
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            const tag = std.meta.activeTag(value);
            store(DiscInt(u.fields.len), base, @intCast(@intFromEnum(tag)));
            inline for (u.fields) |f| {
                if (comptime f.type != void) {
                    if (tag == @field(Tag, f.name)) {
                        lower(f.type, @field(value, f.name), base + unionPayloadOffset(T), ra);
                    }
                }
            }
        },
        else => unsupported(T),
    }
}

fn lowerSlice(comptime E: type, value: []const E, base: [*]u8, ra: Realloc) void {
    const n = value.len;
    if (n == 0) {
        store(usize, base, 0);
        store(usize, base + @sizeOf(usize), 0);
        return;
    }
    const esize = sizeOf(E);
    const buf = ra(n * esize, alignOf(E));
    if (E == u8) {
        @memcpy(buf[0..n], value);
    } else {
        for (value, 0..) |elem, i| lower(E, elem, buf + i * esize, ra);
    }
    store(usize, base, @intFromPtr(buf));
    store(usize, base + @sizeOf(usize), n);
}

// ── Lift (memory → value) ───────────────────────────────────────────

fn load(comptime T: type, base: [*]const u8) T {
    const p: *align(1) const T = @ptrCast(base);
    return p.*;
}

/// Lift a `T` from `base` per the canonical ABI. `string`/`list` results
/// borrow the memory they point at (valid until that memory is reused).
pub fn lift(comptime T: type, base: [*]const u8) T {
    return switch (@typeInfo(T)) {
        .bool => base[0] != 0,
        .int => load(T, base),
        .float => load(T, base),
        .@"enum" => |e| @enumFromInt(load(DiscInt(e.fields.len), base)),
        .optional => |o| if (base[0] == 0) null else lift(o.child, base + payloadOffset(T)),
        .pointer => |p| liftSlice(p.child, base),
        .@"struct" => |s| if (s.layout == .@"packed")
            @as(T, @bitCast(load(PackedInt(T), base)))
        else blk: {
            var result: T = undefined;
            inline for (s.fields, 0..) |f, i| {
                @field(result, f.name) = lift(f.type, base + fieldOffset(T, i));
            }
            break :blk result;
        },
        .@"union" => |u| blk: {
            const Tag = u.tag_type.?;
            const disc = load(DiscInt(u.fields.len), base);
            inline for (u.fields) |f| {
                if (disc == @intFromEnum(@field(Tag, f.name))) {
                    break :blk if (f.type == void)
                        @unionInit(T, f.name, {})
                    else
                        @unionInit(T, f.name, lift(f.type, base + unionPayloadOffset(T)));
                }
            }
            unreachable;
        },
        else => unsupported(T),
    };
}

fn liftSlice(comptime E: type, base: [*]const u8) []const E {
    // Borrow in place: valid only when the canonical element layout equals
    // the native one (primitives on little-endian wasm). Aggregate elements
    // would need element-wise copies into a fresh allocation.
    switch (@typeInfo(E)) {
        .int, .float, .bool => {},
        else => @compileError("canon: lifting list<" ++ @typeName(E) ++ "> (aggregate element) is unsupported"),
    }
    const len = load(usize, base + @sizeOf(usize));
    if (len == 0) return &.{};
    const items: [*]const E = @ptrFromInt(load(usize, base));
    return items[0..len];
}

// ── Return area for indirect (memory) results ───────────────────────

/// A static return area sized for `T`'s canonical layout. An export whose
/// result spills to memory lowers into it and returns its address.
pub fn RetArea(comptime T: type) type {
    return struct {
        // Over-aligned to 8 (the max canonical alignment of any supported
        // type), which always satisfies `alignOf(T)`.
        var area: [sizeOf(T)]u8 align(8) = undefined;

        /// Lower `value` into the area and return its address as the indirect
        /// result pointer (`i32`) the canonical ABI expects.
        pub fn put(value: T, ra: Realloc) i32 {
            lower(T, value, &area, ra);
            return @intCast(@intFromPtr(&area));
        }
    };
}

// ── Result flattening (flat vs. indirect) ───────────────────────────
//
// A function result flattens to a sequence of core values; the canonical ABI
// returns it directly when that sequence is a single core value, otherwise
// through a pointer to memory (`MAX_FLAT_RESULTS = 1`). These helpers compute
// that decision — and the flat core type — from `T` at comptime, so an export
// declares its core return type as `CoreReturn(T)` and encodes the value with
// `returnResult`, with no hand-coded flat/indirect distinction.

/// Number of core values `T` flattens to.
pub fn flatCount(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .void => 0,
        .bool, .int, .float, .@"enum" => 1,
        .pointer => 2, // (ptr, len)
        .optional => |o| 1 + flatCount(o.child), // discriminant + payload
        .@"struct" => |s| if (s.layout == .@"packed")
            (@bitSizeOf(PackedInt(T)) + 31) / 32
        else blk: {
            var c: usize = 0;
            inline for (s.fields) |f| c += flatCount(f.type);
            break :blk c;
        },
        .@"union" => |u| blk: {
            // discriminant + the widest case's flattened payload (the canonical
            // ABI joins case payloads element-wise; the count is the max).
            var m: usize = 0;
            inline for (u.fields) |f| {
                if (f.type != void) m = @max(m, flatCount(f.type));
            }
            break :blk 1 + m;
        },
        else => unsupported(T),
    };
}

/// The single core type a 1-slot `T` flattens to (`i32` / `i64` / `f32` / `f64`).
fn CoreScalar(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .bool, .@"enum" => i32,
        .int => |i| if (i.bits <= 32) i32 else i64,
        .float => |f| if (f.bits == 32) f32 else f64,
        .@"struct" => |s| if (s.layout == .@"packed") i32 else CoreScalar(s.fields[0].type), // packed=flags(i32), single-field record
        .@"union" => i32, // 1-slot union = bare discriminant (all-void cases)
        else => unsupported(T),
    };
}

/// The core return type of a function returning `T`: `void` (empty), the flat
/// scalar (1 core value), or `i32` (a pointer to the spilled result).
pub fn CoreReturn(comptime T: type) type {
    const fc = flatCount(T);
    return if (fc == 0) void else if (fc == 1) CoreScalar(T) else i32;
}

const ResultClass = enum { empty, flat, indirect };

fn resultClass(comptime T: type) ResultClass {
    const fc = flatCount(T);
    return if (fc == 0) .empty else if (fc == 1) .flat else .indirect;
}

/// True when `T`'s result is returned flat (≤ 1 core value) rather than via a
/// memory pointer. Lets a caller pick the matching import shape.
pub fn resultIsFlat(comptime T: type) bool {
    return flatCount(T) <= 1;
}

fn toCore(comptime T: type, value: T) CoreScalar(T) {
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(value),
        .@"enum" => @intCast(@intFromEnum(value)),
        .int => |i| if (CoreScalar(T) == i64)
            @bitCast(value)
        else if (i.bits == 32)
            @bitCast(value)
        else
            @intCast(value),
        .float => value,
        .@"struct" => |s| if (s.layout == .@"packed") packedToCore(T, value) else toCore(s.fields[0].type, @field(value, s.fields[0].name)),
        .@"union" => @intCast(@intFromEnum(std.meta.activeTag(value))),
        else => unsupported(T),
    };
}

fn fromCore(comptime T: type, core: CoreScalar(T)) T {
    return switch (@typeInfo(T)) {
        .bool => core != 0,
        .@"enum" => @enumFromInt(core),
        .int => |i| if (CoreScalar(T) == i64)
            @bitCast(core)
        else if (i.bits == 32)
            @bitCast(core)
        else
            @intCast(core),
        .float => core,
        .@"struct" => |s| if (s.layout == .@"packed") packedFromCore(T, core) else blk: {
            var r: T = undefined;
            @field(r, s.fields[0].name) = fromCore(s.fields[0].type, core);
            break :blk r;
        },
        .@"union" => |u| blk: {
            const Tag = u.tag_type.?;
            inline for (u.fields) |f| {
                if (core == @intFromEnum(@field(Tag, f.name))) break :blk @unionInit(T, f.name, {});
            }
            unreachable;
        },
        else => unsupported(T),
    };
}

/// Encode a function result of type `T` as its core return value: the flat
/// scalar, or (for a spilled result) the pointer to the lowered value. `ra`
/// supplies `string`/`list` storage and is unused for flat results.
pub fn returnResult(comptime T: type, value: T, ra: Realloc) CoreReturn(T) {
    // comptime switch so only the matching arm is analyzed — `toCore`'s
    // `CoreScalar(T)` is undefined for indirect (multi-slot) types.
    return switch (comptime resultClass(T)) {
        .empty => {},
        .flat => toCore(T, value),
        .indirect => RetArea(T).put(value, ra),
    };
}

/// Decode a flat (≤ 1 core value) function result back into `T`. Spilled
/// results are read from memory with `lift` instead.
pub fn liftResultFlat(comptime T: type, core: CoreScalar(T)) T {
    return fromCore(T, core);
}

// ── Parameter lifting (flat slots → values) ─────────────────────────
//
// Params are passed as a flat tuple of core slots (a `string` as two slots, an
// `option<string>` as three, a scalar as one). `liftParams` reconstructs the
// high-level `Params` struct from those slots — the inverse of the canonical
// ABI's parameter flattening — so an export decodes its params with one call
// instead of hand-slicing pointers.

fn coreSlotTo(comptime T: type, slot: anytype) T {
    return switch (@typeInfo(T)) {
        .bool => slot != 0,
        .@"enum" => @enumFromInt(slot),
        .int => if (@bitSizeOf(T) == @bitSizeOf(@TypeOf(slot))) @bitCast(slot) else @intCast(slot),
        .float => slot,
        else => unsupported(T),
    };
}

fn flatFieldOffset(comptime T: type, comptime idx: usize) usize {
    const fields = @typeInfo(T).@"struct".fields;
    var off: usize = 0;
    inline for (fields, 0..) |f, i| {
        if (i == idx) return off;
        off += flatCount(f.type);
    }
    return off;
}

fn flatLift(comptime T: type, slots: anytype, comptime start: usize) T {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => coreSlotTo(T, slots[start]),
        .pointer => |p| blk: { // string/list = (ptr, len)
            const len: usize = @intCast(slots[start + 1]);
            if (len == 0) break :blk &.{};
            const items: [*]const p.child = @ptrFromInt(@as(usize, @intCast(slots[start])));
            break :blk items[0..len];
        },
        .optional => |o| if (slots[start] == 0) null else flatLift(o.child, slots, start + 1),
        .@"struct" => |s| if (s.layout == .@"packed") packedFromCore(T, slots[start]) else blk: {
            var v: T = undefined;
            inline for (s.fields, 0..) |f, i| {
                @field(v, f.name) = flatLift(f.type, slots, start + comptime flatFieldOffset(T, i));
            }
            break :blk v;
        },
        .@"union" => |u| blk: {
            // discriminant at `start`; the active case's payload occupies the
            // joined slots beginning at `start + 1` (matching-width cases only).
            const Tag = u.tag_type.?;
            const disc = slots[start];
            inline for (u.fields) |f| {
                if (disc == @intFromEnum(@field(Tag, f.name))) {
                    break :blk if (f.type == void)
                        @unionInit(T, f.name, {})
                    else
                        @unionInit(T, f.name, flatLift(f.type, slots, start + 1));
                }
            }
            unreachable;
        },
        else => unsupported(T),
    };
}

/// Lift a function's flattened core parameters — a tuple of `i32`/`i64`/`f32`/
/// `f64` slots — into the high-level `Params` struct.
pub fn liftParams(comptime Params: type, slots: anytype) Params {
    return flatLift(Params, slots, 0);
}

// ── Lower to flat core slots (value → params/task.return slots) ──────
//
// The inverse of `liftParams`: flatten a value to the tuple of core slots a
// call (or `task.return`) passes directly. `variant`/`result` join their case
// payloads element-wise (a `void` case contributes nothing; unused slots are
// zeroed), so this is the lowering half of aggregate params.

fn joinCore(comptime a: type, comptime b: type) type {
    if (a == b) return a;
    if ((a == i32 and b == f32) or (a == f32 and b == i32)) return i32;
    return i64;
}

/// The list of core slot types `T` flattens to (with the variant join).
fn flatTypeList(comptime T: type) []const type {
    return switch (@typeInfo(T)) {
        .void => &[_]type{},
        .bool, .@"enum" => &[_]type{i32},
        .int => |i| &[_]type{if (i.bits <= 32) i32 else i64},
        .float => |f| &[_]type{if (f.bits == 32) f32 else f64},
        .pointer => &[_]type{ i32, i32 }, // (ptr, len)
        .optional => |o| concatTypes(&[_]type{i32}, flatTypeList(o.child)),
        .@"struct" => |s| if (s.layout == .@"packed")
            &([_]type{i32} ** ((@bitSizeOf(PackedInt(T)) + 31) / 32))
        else blk: {
            comptime var list: []const type = &[_]type{};
            inline for (s.fields) |f| list = concatTypes(list, flatTypeList(f.type));
            break :blk list;
        },
        .@"union" => |u| blk: {
            comptime var list: []const type = &[_]type{i32}; // discriminant
            inline for (u.fields) |f| {
                if (f.type != void) {
                    const cl = flatTypeList(f.type);
                    inline for (cl, 0..) |ct, i| {
                        const idx = 1 + i;
                        if (idx < list.len) {
                            list = concatTypes(concatTypes(list[0..idx], &[_]type{joinCore(list[idx], ct)}), list[idx + 1 ..]);
                        } else {
                            list = concatTypes(list, &[_]type{ct});
                        }
                    }
                }
            }
            break :blk list;
        },
        else => unsupported(T),
    };
}

fn concatTypes(comptime a: []const type, comptime b: []const type) []const type {
    return a ++ b;
}

/// The tuple type of `T`'s flattened core slots.
pub fn FlatParams(comptime T: type) type {
    return std.meta.Tuple(flatTypeList(T));
}

fn zeroOf(comptime S: type) S {
    return 0;
}

/// Store `val` into slot `i`, coercing to the slot's (possibly wider) core type.
fn setSlot(out: anytype, comptime i: usize, val: anytype) void {
    const S = @TypeOf(out.*[i]);
    const V = @TypeOf(val);
    out.*[i] = if (S == V)
        val
    else switch (@typeInfo(S)) {
        .int => switch (@typeInfo(V)) {
            .int => @intCast(val),
            else => @compileError("canon: cannot widen " ++ @typeName(V) ++ " into " ++ @typeName(S)),
        },
        .float => @floatCast(val),
        else => @compileError("canon: bad slot type " ++ @typeName(S)),
    };
}

fn zeroSlots(out: anytype, comptime start: usize, comptime n: usize) void {
    comptime var i = start;
    inline while (i < start + n) : (i += 1) out.*[i] = zeroOf(@TypeOf(out.*[i]));
}

fn fillFlat(comptime T: type, value: T, out: anytype, comptime start: usize, ra: Realloc) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => setSlot(out, start, @as(i32, @intFromBool(value))),
        .@"enum" => setSlot(out, start, @as(i32, @intCast(@intFromEnum(value)))),
        .int => setSlot(out, start, toCore(T, value)),
        .float => setSlot(out, start, value),
        .pointer => |p| {
            const r = lowerSliceFlat(p.child, value, ra);
            setSlot(out, start, r.ptr);
            setSlot(out, start + 1, r.len);
        },
        .optional => |o| if (value) |v| {
            setSlot(out, start, @as(i32, 1));
            fillFlat(o.child, v, out, start + 1, ra);
        } else {
            setSlot(out, start, @as(i32, 0));
            zeroSlots(out, start + 1, flatCount(o.child));
        },
        .@"struct" => |s| if (s.layout == .@"packed")
            setSlot(out, start, packedToCore(T, value))
        else {
            comptime var idx = start;
            inline for (s.fields) |f| {
                fillFlat(f.type, @field(value, f.name), out, idx, ra);
                idx += comptime flatCount(f.type);
            }
        },
        .@"union" => |u| {
            const Tag = u.tag_type.?;
            setSlot(out, start, @as(i32, @intCast(@intFromEnum(std.meta.activeTag(value)))));
            zeroSlots(out, start + 1, flatCount(T) - 1);
            inline for (u.fields) |f| {
                if (comptime f.type != void) {
                    if (std.meta.activeTag(value) == @field(Tag, f.name)) {
                        fillFlat(f.type, @field(value, f.name), out, start + 1, ra);
                    }
                }
            }
        },
        else => unsupported(T),
    }
}

fn lowerSliceFlat(comptime E: type, value: []const E, ra: Realloc) struct { ptr: i32, len: i32 } {
    const n = value.len;
    if (n == 0) return .{ .ptr = 0, .len = 0 };
    const esize = sizeOf(E);
    const buf = ra(n * esize, alignOf(E));
    if (E == u8) {
        @memcpy(buf[0..n], value);
    } else {
        for (value, 0..) |elem, i| lower(E, elem, buf + i * esize, ra);
    }
    return .{ .ptr = @intCast(@intFromPtr(buf)), .len = @intCast(n) };
}

/// Flatten `value` to the tuple of core slots a call passes directly. `ra`
/// supplies `string`/`list` element storage.
pub fn lowerFlat(comptime T: type, value: T, ra: Realloc) FlatParams(T) {
    var out: FlatParams(T) = undefined;
    fillFlat(T, value, &out, 0, ra);
    return out;
}

// ── Tests (native; layout + lower/lift + result round-trips) ────────

const testing = std.testing;

const Pet = struct { id: u32, name: []const u8, tag: ?[]const u8, age: u32 };
const Toy = struct { id: u32, pet_id: u32, name: []const u8 };

test "layout: primitives and string" {
    const ps = @sizeOf(usize); // canonical pointer width (4 on wasm32)
    try testing.expectEqual(@as(usize, 1), sizeOf(bool));
    try testing.expectEqual(@as(usize, 4), sizeOf(u32));
    try testing.expectEqual(@as(usize, 8), sizeOf(u64));
    try testing.expectEqual(@as(usize, 8), alignOf(u64));
    try testing.expectEqual(2 * ps, sizeOf([]const u8)); // (ptr, len)
    try testing.expectEqual(ps, alignOf([]const u8));
}

test "layout: option and record basics" {
    const ps = @sizeOf(usize);
    // option<string>: 1-byte disc padded to ptr alignment, then (ptr, len).
    try testing.expectEqual(3 * ps, sizeOf(?[]const u8));
    try testing.expectEqual(ps, alignOf(?[]const u8));
    // option adds a discriminant ahead of the payload (padded to its alignment).
    try testing.expectEqual(alignOf(Pet), payloadOffset(?Pet));
    try testing.expect(sizeOf(?Pet) >= sizeOf(Pet) + 1);
    // a record's first field sits at offset 0.
    try testing.expectEqual(@as(usize, 0), fieldOffset(Pet, 0));
}

// Exact canonical (wasm32 / 4-byte pointer) layout. Skipped on 64-bit test
// hosts; documents and guards the numbers the produced component relies on.
test "canonical wasm32 layout" {
    if (@sizeOf(usize) != 4) return error.SkipZigTest;
    try testing.expectEqual(@as(usize, 8), sizeOf([]const u8));
    try testing.expectEqual(@as(usize, 12), sizeOf(?[]const u8));
    try testing.expectEqual(@as(usize, 28), sizeOf(Pet));
    try testing.expectEqual(@as(usize, 32), sizeOf(?Pet));
    try testing.expectEqual(@as(usize, 20), sizeOf(?Toy));
    try testing.expectEqual(@as(usize, 12), fieldOffset(Pet, 2)); // tag
    try testing.expectEqual(@as(usize, 24), fieldOffset(Pet, 3)); // age
}

var test_arena: [4096]u8 align(8) = undefined;
var test_top: usize = 0;
fn testAlloc(size: usize, alignment: usize) [*]u8 {
    const start = alignTo(test_top, alignment);
    test_top = start + size;
    return @ptrCast(&test_arena[start]);
}

test "lower/lift round-trip: option<pet> with and without tag" {
    test_top = 0;
    var buf: [sizeOf(?Pet)]u8 align(8) = undefined;

    const some = Pet{ .id = 7, .name = "Fluffy", .tag = "cat", .age = 3 };
    lower(?Pet, some, &buf, &testAlloc);
    const got = lift(?Pet, &buf).?;
    try testing.expectEqual(@as(u32, 7), got.id);
    try testing.expectEqualStrings("Fluffy", got.name);
    try testing.expectEqualStrings("cat", got.tag.?);
    try testing.expectEqual(@as(u32, 3), got.age);

    const none_tag = Pet{ .id = 9, .name = "Bubbles", .tag = null, .age = 1 };
    lower(?Pet, none_tag, &buf, &testAlloc);
    const got2 = lift(?Pet, &buf).?;
    try testing.expect(got2.tag == null);
    try testing.expectEqualStrings("Bubbles", got2.name);

    lower(?Pet, null, &buf, &testAlloc);
    try testing.expect(lift(?Pet, &buf) == null);
}

test "lower writes the canonical option<pet> discriminants" {
    test_top = 0;
    var buf: [sizeOf(?Pet)]u8 align(8) = undefined;
    @memset(&buf, 0xaa);
    lower(?Pet, .{ .id = 1, .name = "hi", .tag = null, .age = 2 }, &buf, &testAlloc);
    const pet = buf[payloadOffset(?Pet)..].ptr;
    try testing.expectEqual(@as(u8, 1), buf[0]); // option disc = some
    try testing.expectEqual(@as(u32, 1), load(u32, pet + fieldOffset(Pet, 0))); // id
    try testing.expectEqual(@as(u8, 0), pet[fieldOffset(Pet, 2)]); // tag disc = none
    try testing.expectEqual(@as(u32, 2), load(u32, pet + fieldOffset(Pet, 3))); // age
}

test "round-trip: toy and scalars" {
    test_top = 0;
    var buf: [sizeOf(?Toy)]u8 align(8) = undefined;
    lower(?Toy, Toy{ .id = 100, .pet_id = 1, .name = "Yarn Ball" }, &buf, &testAlloc);
    const t = lift(?Toy, &buf).?;
    try testing.expectEqual(@as(u32, 100), t.id);
    try testing.expectEqual(@as(u32, 1), t.pet_id);
    try testing.expectEqualStrings("Yarn Ball", t.name);
}

test "lowerFlat round-trips through liftParams" {
    test_top = 0;
    // record { a: u32, c: bool, d: u64 } — no pointer (host-safe; strings are
    // validated end-to-end on wasm32 where pointers fit an i32 slot).
    const R = struct { a: u32, c: bool, d: u64 };
    const rg = liftParams(R, lowerFlat(R, .{ .a = 5, .c = true, .d = 0x1_0000_0000 }, &testAlloc));
    try testing.expectEqual(@as(u32, 5), rg.a);
    try testing.expectEqual(true, rg.c);
    try testing.expectEqual(@as(u64, 0x1_0000_0000), rg.d);

    // option<u32>
    try testing.expectEqual(@as(?u32, 9), liftParams(?u32, lowerFlat(?u32, @as(?u32, 9), &testAlloc)));
    try testing.expect(liftParams(?u32, lowerFlat(?u32, @as(?u32, null), &testAlloc)) == null);

    // variant: void cases + a payload case (the discriminant + joined-payload form)
    const M = union(enum) { get, post, val: u32 };
    const mg = liftParams(M, lowerFlat(M, .{ .val = 42 }, &testAlloc));
    try testing.expect(std.meta.activeTag(mg) == .val);
    try testing.expectEqual(@as(u32, 42), mg.val);
    try testing.expect(std.meta.activeTag(liftParams(M, lowerFlat(M, .post, &testAlloc))) == .post);

    // tuple<u32, bool>
    const Tup = Tuple(.{ u32, bool });
    const tg = liftParams(Tup, lowerFlat(Tup, .{ 7, false }, &testAlloc));
    try testing.expectEqual(@as(u32, 7), tg[0]);
    try testing.expectEqual(false, tg[1]);

    // FlatParams of a `method`/`other(string)` shape = disc + (ptr, len) = 3 slots.
    const Method = union(enum) { get, other: []const u8 };
    try testing.expectEqual(@as(usize, 3), @typeInfo(FlatParams(Method)).@"struct".fields.len);
}

test "result flattening decision and core types" {
    try testing.expect(resultIsFlat(u32));
    try testing.expect(resultIsFlat(bool));
    try testing.expect(!resultIsFlat([]const u8)); // (ptr, len) = 2 slots
    try testing.expect(!resultIsFlat(?Pet));
    try testing.expectEqual(i32, CoreReturn(u32));
    try testing.expectEqual(i32, CoreReturn(?Pet)); // pointer to spilled result
    try testing.expectEqual(i64, CoreReturn(u64));
    try testing.expectEqual(@as(usize, 1), flatCount(bool));
    try testing.expectEqual(@as(usize, 3), flatCount(?[]const u8)); // disc + (ptr, len)
}

test "flat result encode/decode round-trip" {
    // Flat results don't touch memory, so this runs on any host.
    try testing.expectEqual(@as(u32, 42), liftResultFlat(u32, returnResult(u32, 42, &testAlloc)));
    try testing.expectEqual(true, liftResultFlat(bool, returnResult(bool, true, &testAlloc)));
    try testing.expectEqual(false, liftResultFlat(bool, returnResult(bool, false, &testAlloc)));
    const big: u64 = 0x1_0000_0000;
    try testing.expectEqual(big, liftResultFlat(u64, returnResult(u64, big, &testAlloc)));
}

test "liftParams decodes flat scalar params" {
    const P = struct { a: u32, b: bool, c: u32 };
    const got = liftParams(P, .{ @as(i32, @bitCast(@as(u32, 7))), @as(i32, 1), @as(i32, @bitCast(@as(u32, 99))) });
    try testing.expectEqual(@as(u32, 7), got.a);
    try testing.expectEqual(true, got.b);
    try testing.expectEqual(@as(u32, 99), got.c);
}

test "liftParams places string/option/scalar at the right slots" {
    // name=(ptr,len) slots 0..1, tag=(disc,ptr,len) slots 2..4, age slot 5.
    // Pointers aren't dereferenced here, so empty (ptr=0,len=0) is safe.
    const P = struct { name: []const u8, tag: ?[]const u8, age: u32 };
    const got = liftParams(P, .{
        @as(i32, 0),                       @as(i32, 0), // name ptr,len
        @as(i32, 0),  @as(i32, 0),         @as(i32, 0), // tag none
        @as(i32, @bitCast(@as(u32, 5))), // age
    });
    try testing.expectEqual(@as(usize, 0), got.name.len);
    try testing.expect(got.tag == null);
    try testing.expectEqual(@as(u32, 5), got.age);
}

// ── Variant / result (tagged union) ─────────────────────────────────

const ResU32Str = union(enum) { ok: u32, err: []const u8 }; // result<u32, string>
const Shape = union(enum) { circle: u32, square: Toy, point }; // 3-case variant
const Outcome = union(enum) { pass, fail }; // result<_, _> — all-void → flat

test "union: flatten counts and result classification" {
    try testing.expectEqual(@as(usize, 3), flatCount(ResU32Str)); // disc + (ptr, len)
    try testing.expectEqual(@as(usize, 1), flatCount(Outcome)); // disc only
    try testing.expectEqual(@as(usize, 5), flatCount(Shape)); // disc + max(1, Toy=4, 0)
    try testing.expect(resultIsFlat(Outcome));
    try testing.expect(!resultIsFlat(ResU32Str));
    try testing.expectEqual(i32, CoreReturn(Outcome)); // bare discriminant
    try testing.expectEqual(i32, CoreReturn(ResU32Str)); // pointer to spilled result
}

test "union: flat all-void result encode/decode round-trip" {
    // Flat results don't touch memory, so this runs on any host.
    try testing.expect(std.meta.activeTag(liftResultFlat(Outcome, returnResult(Outcome, .pass, &testAlloc))) == .pass);
    try testing.expect(std.meta.activeTag(liftResultFlat(Outcome, returnResult(Outcome, .fail, &testAlloc))) == .fail);
}

test "union: memory lower/lift round-trip result<u32, string>" {
    test_top = 0;
    var buf: [sizeOf(ResU32Str)]u8 align(8) = undefined;
    lower(ResU32Str, .{ .ok = 7 }, &buf, &testAlloc);
    switch (lift(ResU32Str, &buf)) {
        .ok => |v| try testing.expectEqual(@as(u32, 7), v),
        .err => return error.TestUnexpectedResult,
    }
    lower(ResU32Str, .{ .err = "nope" }, &buf, &testAlloc);
    switch (lift(ResU32Str, &buf)) {
        .err => |e| try testing.expectEqualStrings("nope", e),
        .ok => return error.TestUnexpectedResult,
    }
}

test "union: memory round-trip 3-case variant (record + no-payload cases)" {
    test_top = 0;
    var buf: [sizeOf(Shape)]u8 align(8) = undefined;
    lower(Shape, .{ .square = .{ .id = 1, .pet_id = 2, .name = "yo" } }, &buf, &testAlloc);
    switch (lift(Shape, &buf)) {
        .square => |t| {
            try testing.expectEqual(@as(u32, 1), t.id);
            try testing.expectEqual(@as(u32, 2), t.pet_id);
            try testing.expectEqualStrings("yo", t.name);
        },
        else => return error.TestUnexpectedResult,
    }
    lower(Shape, .{ .circle = 9 }, &buf, &testAlloc);
    switch (lift(Shape, &buf)) {
        .circle => |r| try testing.expectEqual(@as(u32, 9), r),
        else => return error.TestUnexpectedResult,
    }
    lower(Shape, .point, &buf, &testAlloc);
    try testing.expect(std.meta.activeTag(lift(Shape, &buf)) == .point);
}

test "union: flatLift reconstructs a variant param" {
    const R = union(enum) { ok: u32, err: u32 }; // result<u32, u32>
    const a = liftParams(R, .{ @as(i32, 1), @as(i32, @bitCast(@as(u32, 99))) });
    try testing.expect(std.meta.activeTag(a) == .err);
    try testing.expectEqual(@as(u32, 99), a.err);
    const b = liftParams(R, .{ @as(i32, 0), @as(i32, @bitCast(@as(u32, 7))) });
    try testing.expect(std.meta.activeTag(b) == .ok);
    try testing.expectEqual(@as(u32, 7), b.ok);
}

test "union canonical wasm32 layout" {
    if (@sizeOf(usize) != 4) return error.SkipZigTest;
    // result<u32, string>: u8 disc padded to 4, payload max(4, 8)=8 → size 12.
    try testing.expectEqual(@as(usize, 4), alignOf(ResU32Str));
    try testing.expectEqual(@as(usize, 12), sizeOf(ResU32Str));
    try testing.expectEqual(@as(usize, 4), unionPayloadOffset(ResU32Str));
    // all-void 2-case variant: the bare discriminant byte.
    try testing.expectEqual(@as(usize, 1), alignOf(Outcome));
    try testing.expectEqual(@as(usize, 1), sizeOf(Outcome));
}

test "Result constructor is memoized and round-trips" {
    // Same args → identical type (so generated shells and user impls agree).
    try testing.expect(Result(u32, []const u8) == Result(u32, []const u8));
    const R = Result(u32, []const u8);
    test_top = 0;
    var buf: [sizeOf(R)]u8 align(8) = undefined;
    lower(R, .{ .ok = 5 }, &buf, &testAlloc);
    switch (lift(R, &buf)) {
        .ok => |v| try testing.expectEqual(@as(u32, 5), v),
        .err => return error.TestUnexpectedResult,
    }
    // result<_, _> flattens to a flat discriminant.
    try testing.expect(resultIsFlat(Result(void, void)));
}

test "Tuple / Future / Stream constructors marshal correctly" {
    // Future/Stream are i32 handles (single-field records).
    try testing.expectEqual(@as(usize, 1), flatCount(Future(u32)));
    try testing.expectEqual(@as(usize, 1), flatCount(Stream(u8)));
    try testing.expectEqual(i32, CoreReturn(Future(u32)));
    try testing.expect(Future(u32) == Future(u32)); // memoized
    const f = liftResultFlat(Future(u32), returnResult(Future(u32), .{ .handle = 7 }, &testAlloc));
    try testing.expectEqual(@as(i32, 7), f.handle);

    // tuple<u32, string> = 1 + (ptr,len) = 3 flat slots; round-trips via memory.
    const T = Tuple(.{ u32, []const u8 });
    try testing.expectEqual(@as(usize, 3), flatCount(T));
    test_top = 0;
    var buf: [sizeOf(T)]u8 align(8) = undefined;
    lower(T, .{ 9, "hi" }, &buf, &testAlloc);
    const got = lift(T, &buf);
    try testing.expectEqual(@as(u32, 9), got[0]);
    try testing.expectEqualStrings("hi", got[1]);
}

// ── Flags (packed struct) ───────────────────────────────────────────

const Perms = packed struct(u8) { read: bool = false, write: bool = false, exec: bool = false, _pad: u5 = 0 };
const Big = packed struct(u32) { f0: bool = false, rest: u31 = 0 };

test "flags: packed-struct layout, flat counts, round-trips" {
    try testing.expectEqual(@as(usize, 1), sizeOf(Perms));
    try testing.expectEqual(@as(usize, 1), alignOf(Perms));
    try testing.expectEqual(@as(usize, 1), flatCount(Perms)); // ≤32 labels → 1 i32
    try testing.expectEqual(i32, CoreReturn(Perms));

    // Flat result encode/decode (no memory).
    const v = Perms{ .read = true, .exec = true };
    const got = liftResultFlat(Perms, returnResult(Perms, v, &testAlloc));
    try testing.expect(got.read and got.exec and !got.write);

    // flatLift (param): read=bit0, exec=bit2 → 0b101 = 5.
    const p = liftParams(struct { f: Perms }, .{@as(i32, 5)});
    try testing.expect(p.f.read and p.f.exec and !p.f.write);
}

test "flags: memory lower/lift round-trip (LSB-first)" {
    test_top = 0;
    var buf: [sizeOf(Perms)]u8 align(8) = undefined;
    lower(Perms, .{ .write = true }, &buf, &testAlloc);
    try testing.expectEqual(@as(u8, 0b010), buf[0]); // write = bit 1
    const got = lift(Perms, &buf);
    try testing.expect(got.write and !got.read and !got.exec);
}

test "flags: u32 backing flattens through i32 without overflow" {
    const v: Big = @bitCast(@as(u32, 0x8000_0001)); // bit 31 + bit 0
    const got = liftResultFlat(Big, returnResult(Big, v, &testAlloc));
    try testing.expectEqual(@as(u32, 0x8000_0001), @as(u32, @bitCast(got)));
}
