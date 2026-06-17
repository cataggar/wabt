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
        .@"struct" => |s| blk: {
            var a: usize = 1;
            inline for (s.fields) |f| a = @max(a, alignOf(f.type));
            break :blk a;
        },
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
        .@"struct" => |s| blk: {
            var off: usize = 0;
            inline for (s.fields) |f| {
                off = alignTo(off, alignOf(f.type)) + sizeOf(f.type);
            }
            break :blk alignTo(off, alignOf(T));
        },
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
        .@"struct" => |s| inline for (s.fields, 0..) |f, i| {
            lower(f.type, @field(value, f.name), base + fieldOffset(T, i), ra);
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
        .@"struct" => |s| blk: {
            var result: T = undefined;
            inline for (s.fields, 0..) |f, i| {
                @field(result, f.name) = lift(f.type, base + fieldOffset(T, i));
            }
            break :blk result;
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

// ── Tests (native; layout + lower/lift round-trips) ─────────────────

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
