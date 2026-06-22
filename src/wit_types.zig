// wit_types - shared canonical-ABI helpers for WASI 0.3 guests.
//
// This module now owns both:
// - abi: scratch arena and ret-area primitives
// - canon: canonical ABI marshalling and typed future/stream wrappers

const std = @import("std");
pub const abi: type = @This();
// `abi` — shared guest-side Component Model canonical-ABI primitives.
//
// The `wasi_*` helper modules in this directory (`wasi_http`,
// `wasi_keyvalue`, …) are thin typed wrappers over
// `extern` declarations of host imports. Everything those wrappers
// share — the `cabi_realloc` scratch arena and the "ret-area" used to
// receive results wider than one core value — lives here, exactly once,
// so a guest can pull in several `wasi_*` modules without duplicate
// `cabi_realloc` exports or competing scratch state.
//
// ## Canonical ABI, briefly
//
// A component guest speaks the **canonical ABI**: host functions are
// imported with lowered core-wasm signatures (every WIT type flattened
// to `i32` / `i64` slots). The flattening rules used throughout the
// `wasi_*` wrappers:
//
//   * `MAX_FLAT_PARAMS = 16`, `MAX_FLAT_RESULTS = 1`.
//   * A result whose flattened representation exceeds one core value is
//     returned through a guest-allocated "ret-area" pointer passed as
//     the trailing parameter; the callee writes the flattened words
//     there and the caller reads them back. `retPtr` / `retWords`
//     below provide that area.
//   * `string` and `list<T>` lower to `(ptr, len)` pairs.
//   * `option<T>` lowers to `(discriminant, …flatten(T))`.
//   * `result<T, E>` lowers to `(discriminant, …join(flatten(T), flatten(E)))`.
//
// There is no Zig `wit-bindgen` backend that emits these bindings, so
// they are written by hand in the wrappers; this module factors out the
// parts that are identical across every interface.

// ── cabi_realloc scratch arena ─────────────────────────────────────
//
// Canonical-ABI lifts of host-side `string` / `list` values into guest
// memory call `cabi_realloc`. A bump arena suits the canonical ABI's
// "grow-only, no free, lifetime = one host→guest call" shape: the host
// never frees, and `resetScratch` reclaims everything at once at the top
// of each request. `cabi_realloc` is `export`ed (a linker root), so it
// appears in the final component even though it lives in this dependency
// module rather than the guest's root source file.

var arena_buf: [65536]u8 align(16) = undefined;
var arena_top: usize = 0;

inline fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

export fn cabi_realloc(
    _: usize, // old_ptr — we never free
    _: usize, // old_size
    alignment: usize,
    new_size: usize,
) usize {
    if (new_size == 0) return 0;
    const a = if (alignment == 0) 1 else alignment;
    const start = alignUp(arena_top, a);
    if (start + new_size > arena_buf.len) return 0;
    arena_top = start + new_size;
    return @intFromPtr(&arena_buf[start]);
}

/// Reset the scratch arena. A handler entry point (e.g. `wasi_http`'s
/// `exportIncomingHandler` wrapper) calls this once at the top of each
/// request so every invocation gets a fresh 64 KiB scratch surface.
///
/// Not thread-safe, and intentionally so: the module-level `arena_buf`,
/// `arena_top`, and `ret_area` globals assume **one invocation at a
/// time**. That holds for wamr's serial accept loop and for a
/// single-threaded freestanding guest (no wasi-threads / shared memory),
/// and for runtimes that instantiate a fresh component per request
/// (e.g. `wasmtime serve`, where each request has its own linear
/// memory). A model that invoked one instance's export concurrently on
/// multiple threads would need per-thread scratch (wasm thread-locals).
pub fn resetScratch() void {
    arena_top = 0;
}

/// Allocate `size` bytes aligned to `alignment` from the scratch arena — the
/// `canon.Realloc` used to place `string` / `list` storage during lowering.
/// Grows the same bump arena as `cabi_realloc`; reclaimed by `resetScratch`.
pub fn alloc(size: usize, alignment: usize) [*]u8 {
    return @ptrFromInt(cabi_realloc(0, 0, alignment, size));
}

// ── Ret-area for spilled results ───────────────────────────────────
//
// Every imported function whose flat result exceeds one core value
// writes its result words here; the decoders below read them back. 64
// bytes (16 words) covers the widest result the wrappers decode —
// canonical `wasi:http` `outgoing-body.finish` → `result<_, error-code>`
// where the full `error-code` variant flattens to ~7 words (so the
// result is ~8), plus headroom.

var ret_area: [64]u8 align(8) = undefined;

/// Pointer to the ret-area as an `i32`, for passing as the trailing
/// `retptr` parameter of a spilled-result import.
pub inline fn retPtr() i32 {
    return @intCast(@intFromPtr(&ret_area));
}

/// The ret-area reinterpreted as a word array, for reading flattened
/// `i32` result slots back after a call.
pub inline fn retWords() [*]u32 {
    return @ptrCast(@alignCast(&ret_area));
}

/// The ret-area as a byte pointer, for `canon.lift` of a spilled result.
pub inline fn retArea() [*]const u8 {
    return @ptrCast(&ret_area);
}

/// Decode the ret-area as `result<own<handle>, _>` → the handle on the
/// ok arm (word layout `[disc, handle]`), or null on the err arm.
pub inline fn readResultHandle() ?i32 {
    const w = retWords();
    return if (w[0] == 0) @bitCast(w[1]) else null;
}

/// Decode the ret-area as `option<string>` / `option<list<u8>>`
/// (`[disc, ptr, len]`) into a slice borrowing from the scratch arena,
/// or null for `none`.
pub inline fn readOptionBytes() ?[]const u8 {
    const w = retWords();
    if (w[0] != 1) return null;
    const p: [*]const u8 = @ptrFromInt(w[1]);
    return p[0..w[2]];
}

// ── Tests ──────────────────────────────────────────────────────────
//
// These exercise the pure, host-import-free core: the alignment helper,
// the `cabi_realloc` bump arena, and the ret-area decoders. They link
// and run natively (`zig build test`); the `wasi_*` wrappers can't be
// tested this way because every public function calls an `extern` host
// import that only resolves under `wasm32-freestanding`.

const abi_testing = std.testing;

test alignUp {
    try abi_testing.expectEqual(@as(usize, 0), alignUp(0, 8));
    try abi_testing.expectEqual(@as(usize, 8), alignUp(1, 8));
    try abi_testing.expectEqual(@as(usize, 8), alignUp(8, 8));
    try abi_testing.expectEqual(@as(usize, 16), alignUp(9, 8));
    try abi_testing.expectEqual(@as(usize, 16), alignUp(16, 16));
    try abi_testing.expectEqual(@as(usize, 5), alignUp(5, 1));
}

test "cabi_realloc bumps, aligns, and grows monotonically" {
    resetScratch();

    const a = cabi_realloc(0, 0, 16, 32);
    try abi_testing.expect(a != 0);
    try abi_testing.expectEqual(@as(usize, 0), a % 16);

    // Next allocation is past the first and respects its alignment.
    const b = cabi_realloc(0, 0, 8, 8);
    try abi_testing.expect(b >= a + 32);
    try abi_testing.expectEqual(@as(usize, 0), b % 8);
}

test "cabi_realloc: zero size returns 0, oversize fails, reset reclaims" {
    resetScratch();

    try abi_testing.expectEqual(@as(usize, 0), cabi_realloc(0, 0, 1, 0));

    // A request larger than the whole arena cannot be satisfied.
    try abi_testing.expectEqual(@as(usize, 0), cabi_realloc(0, 0, 1, arena_buf.len + 1));

    // Fill the arena, then confirm reset makes room again.
    const full = cabi_realloc(0, 0, 1, arena_buf.len);
    try abi_testing.expect(full != 0);
    try abi_testing.expectEqual(@as(usize, 0), cabi_realloc(0, 0, 1, 1));
    resetScratch();
    try abi_testing.expect(cabi_realloc(0, 0, 1, 1) != 0);
}

test "readResultHandle decodes the ok and err arms" {
    const w = retWords();

    w[0] = 0; // ok
    w[1] = @bitCast(@as(i32, 42));
    try abi_testing.expectEqual(@as(?i32, 42), readResultHandle());

    w[0] = 1; // err
    try abi_testing.expectEqual(@as(?i32, null), readResultHandle());
}

// `canon` — a comptime Component-Model **canonical ABI** value marshaller.
//
// Given an ordinary Zig type, this module computes the canonical memory
// layout (`alignOf` / `sizeOf`) and lowers/lifts values to/from linear memory
// exactly as the Component Model canonical ABI specifies — so a guest never
// hand-writes `extern struct` layouts or pointer arithmetic for records,
// options, strings, or lists. It is the in-memory half of the ABI (the part
// used for aggregate params/results that spill to memory); flat scalar slots
// that a core function passes directly are handled by the caller.
//
// ## Zig → WIT type mapping
//
//   | Zig                         | WIT            |
//   | --------------------------- | -------------- |
//   | `bool`                      | `bool`         |
//   | `u8/u16/u32/u64`            | `u8/u16/u32/u64` |
//   | `i8/i16/i32/i64`            | `s8/s16/s32/s64` |
//   | `f32` / `f64`               | `f32` / `f64`  |
//   | `[]const u8`                | `string`       |
//   | `[]const T` (T ≠ u8)        | `list<T>`      |
//   | `?T`                        | `option<T>`    |
//   | `enum`                      | `enum`         |
//   | `struct { … }`              | `record`       |
//   | tuple `struct { T, U }`     | `tuple<T, U>`  |
//
// ## Layout rules (canonical ABI)
//
//   * `align(T)` / `size(T)` follow the spec: records concatenate fields at
//     their alignment; `option<T>` is a 2-case variant — a 1-byte
//     discriminant, the payload at `align(T)`, padded to `align(T)`;
//     `string`/`list` are a `(ptr: u32, len: u32)` pair (size 8, align 4 on
//     wasm32).
//   * A value wider than one core slot is returned/received through a pointer
//     to such a layout; `RetArea(T)` provides the static return area an export
//     returns by address.

/// The guest's `cabi_realloc` scratch arena — `lift` allocates from it when a
/// `list<E>` element can't be borrowed in place (its native Zig layout differs
/// from the canonical one, e.g. a tagged `variant`), copying each element into a
/// fresh native array with the same lifetime as the host-allocated list.
const abi_core = abi;
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

/// The WIT spelling of a primitive type, for the `[stream]stream<…>` /
/// `[future]future<…>` async-intrinsic module names. Non-primitive elements
/// (resources, results, …) need the function-reference intrinsic form instead.
fn witSpell(comptime T: type) []const u8 {
    return switch (T) {
        bool => "bool",
        u8 => "u8",
        u16 => "u16",
        u32 => "u32",
        u64 => "u64",
        i8 => "s8",
        i16 => "s16",
        i32 => "s32",
        i64 => "s64",
        f32 => "f32",
        f64 => "f64",
        else => @compileError("canon: stream/future read/write needs a primitive element; got " ++ @typeName(T)),
    };
}

/// The two ends of a freshly created `future`/`stream` of element `T`.
fn EndsOf(comptime Chan: type) type {
    return struct { readable: Chan, writable: Chan };
}

fn unpackChanEnds(comptime Chan: type, packed_ends: i64) EndsOf(Chan) {
    const u: u64 = @bitCast(packed_ends);
    return .{
        .readable = .{ .handle = @bitCast(@as(u32, @truncate(u))) },
        .writable = .{ .handle = @bitCast(@as(u32, @truncate(u >> 32))) },
    };
}

/// A WIT `future<T>` whose async read/write/drop intrinsics resolve through the
/// supplied module `mod` (the `@extern` `library_name`). `Future(T)` derives
/// `mod` from `T`'s primitive WIT spelling; a complex (aggregate /
/// resource-bearing) element can't be spelled that way, so the bindings
/// generator supplies the function-reference form
/// `[future]<iface>#<fn>#<idx>` here instead. At the canonical ABI the channel
/// is a single `i32` handle (the readable or writable end).
///
/// `read`/`write` take a pointer to a value already in *canonical* memory
/// layout. For a primitive `T` the Zig layout matches, so `&value` works; a
/// complex element (e.g. `Result(…)`, a Zig `union(enum)` whose in-memory
/// layout differs from the canonical ABI) must be staged via `lower`/`lift`
/// into a `sizeOf(T)`-byte, `alignOf(T)`-aligned buffer that stays live until
/// the op completes — use `readInto`/`writeFrom` (see `wasi_http.zig` for the
/// blocked-status + wait pattern).
pub fn FutureOf(comptime T: type, comptime mod: []const u8) type {
    return struct {
        handle: i32,
        pub const Element = T;
        const Self = @This();

        /// Create a new `future<T>`, returning both ends.
        pub fn new() EndsOf(Self) {
            const f = @extern(*const fn () callconv(.c) i64, .{ .name = "new", .library_name = mod });
            return unpackChanEnds(Self, f());
        }
        /// Read the value into `out` (which must be in canonical layout and stay
        /// live until the op completes); returns the raw canonical status.
        pub fn read(self: Self, out: *T) i32 {
            return self.readInto(@ptrCast(out));
        }
        /// Write `*value` (canonical layout, kept live by the caller until the
        /// op completes); returns the raw canonical status.
        pub fn write(self: Self, value: *const T) i32 {
            return self.writeFrom(@ptrCast(value));
        }
        /// Read into a raw canonical-layout buffer (for complex elements staged
        /// via `lift`).
        pub fn readInto(self: Self, base: [*]u8) i32 {
            const f = @extern(*const fn (i32, i32) callconv(.c) i32, .{ .name = "read", .library_name = mod });
            return f(self.handle, @intCast(@intFromPtr(base)));
        }
        /// Write from a raw canonical-layout buffer (for complex elements staged
        /// via `lower`).
        pub fn writeFrom(self: Self, base: [*]const u8) i32 {
            const f = @extern(*const fn (i32, i32) callconv(.c) i32, .{ .name = "write", .library_name = mod });
            return f(self.handle, @intCast(@intFromPtr(base)));
        }
        pub fn dropReadable(self: Self) void {
            const f = @extern(*const fn (i32) callconv(.c) void, .{ .name = "drop-readable", .library_name = mod });
            f(self.handle);
        }
        pub fn dropWritable(self: Self) void {
            const f = @extern(*const fn (i32) callconv(.c) void, .{ .name = "drop-writable", .library_name = mod });
            f(self.handle);
        }
    };
}

/// The Zig type for a WIT `future<T>` with a primitive element `T`. For a
/// complex element the bindings generator uses `FutureOf` with the
/// function-reference intrinsic module instead.
pub fn Future(comptime T: type) type {
    return FutureOf(T, "[future]future<" ++ witSpell(T) ++ ">");
}

/// A WIT `stream<T>` whose async intrinsics resolve through `mod` — the stream
/// analogue of `FutureOf` (see it for the primitive-vs-complex element
/// contract). `read`/`write` take a typed slice (correct for a primitive `T`);
/// `readInto`/`writeFrom` take a raw canonical-layout buffer plus element
/// `count` for complex elements.
pub fn StreamOf(comptime T: type, comptime mod: []const u8) type {
    return struct {
        handle: i32,
        pub const Element = T;
        const Self = @This();

        /// Create a new `stream<T>`, returning both ends.
        pub fn new() EndsOf(Self) {
            const f = @extern(*const fn () callconv(.c) i64, .{ .name = "new", .library_name = mod });
            return unpackChanEnds(Self, f());
        }
        /// Read up to `buf.len` elements; returns the raw canonical status.
        pub fn read(self: Self, buf: []T) i32 {
            return self.readInto(@ptrCast(buf.ptr), buf.len);
        }
        /// Write `items`; returns the raw canonical status.
        pub fn write(self: Self, items: []const T) i32 {
            return self.writeFrom(@ptrCast(items.ptr), items.len);
        }
        /// Read up to `count` elements into a raw canonical-layout buffer.
        pub fn readInto(self: Self, base: [*]u8, count: usize) i32 {
            const f = @extern(*const fn (i32, i32, i32) callconv(.c) i32, .{ .name = "read", .library_name = mod });
            return f(self.handle, @intCast(@intFromPtr(base)), @intCast(count));
        }
        /// Write `count` elements from a raw canonical-layout buffer.
        pub fn writeFrom(self: Self, base: [*]const u8, count: usize) i32 {
            const f = @extern(*const fn (i32, i32, i32) callconv(.c) i32, .{ .name = "write", .library_name = mod });
            return f(self.handle, @intCast(@intFromPtr(base)), @intCast(count));
        }
        pub fn dropReadable(self: Self) void {
            const f = @extern(*const fn (i32) callconv(.c) void, .{ .name = "drop-readable", .library_name = mod });
            f(self.handle);
        }
        pub fn dropWritable(self: Self) void {
            const f = @extern(*const fn (i32) callconv(.c) void, .{ .name = "drop-writable", .library_name = mod });
            f(self.handle);
        }
    };
}

/// The Zig type for a WIT `stream<T>` with a primitive element `T`. For a
/// complex element the bindings generator uses `StreamOf` with the
/// function-reference intrinsic module instead.
pub fn Stream(comptime T: type) type {
    return StreamOf(T, "[stream]stream<" ++ witSpell(T) ++ ">");
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

/// True when `E`'s native Zig layout equals its canonical-ABI layout, so a
/// canonical array of `E` can be borrowed in place as a `[]const E` with no
/// copy. Holds for primitives, `string`/`list` (slices), and `record`/`tuple`
/// of such on little-endian wasm32. A tagged `variant`/`result` (a Zig `union`,
/// whose in-memory layout differs from the canonical discriminant+payload) does
/// not match.
fn layoutMatches(comptime E: type) bool {
    return switch (@typeInfo(E)) {
        .bool, .int, .float, .@"enum" => sizeOf(E) == @sizeOf(E),
        .pointer => |p| p.size == .slice and sizeOf(E) == @sizeOf(E) and alignOf(E) == @alignOf(E),
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed") break :blk sizeOf(E) == @sizeOf(E);
            if (sizeOf(E) != @sizeOf(E) or alignOf(E) != @alignOf(E)) break :blk false;
            inline for (s.fields, 0..) |f, i| {
                if (@offsetOf(E, f.name) != fieldOffset(E, i)) break :blk false;
                if (!layoutMatches(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn liftSlice(comptime E: type, base: [*]const u8) []const E {
    // Borrow in place when `E`'s canonical layout equals its native one — the
    // canonical element array is then already a valid `[]const E` (primitives,
    // plus `string` / `list` / `record` / `tuple` of such on little-endian
    // wasm32). Otherwise (a tagged `variant` / `result`, or an aggregate
    // reaching one) lift element-by-element into a fresh native array allocated
    // from the same scratch arena the host placed the canonical list in.
    const ptr = load(usize, base);
    const len = load(usize, base + @sizeOf(usize));
    if (len == 0) return &.{};
    if (comptime layoutMatches(E)) {
        const items: [*]const E = @ptrFromInt(ptr);
        return items[0..len];
    }
    const esize = comptime sizeOf(E); // canonical element stride (matches `lowerSlice`)
    const src: [*]const u8 = @ptrFromInt(ptr);
    const out: [*]E = @ptrCast(@alignCast(abi_core.alloc(len * @sizeOf(E), @alignOf(E))));
    for (0..len) |i| out[i] = lift(E, src + i * esize);
    return out[0..len];
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

test "lift list<variant>: element-wise copy of a non-layout-matching element (#306)" {
    test_top = 0;
    abi_core.resetScratch();
    // variant V { num(u32), nothing, text(string) } — a tagged union whose Zig
    // layout differs from the canonical discriminant+payload, so the list can't
    // be borrowed in place.
    const V = union(enum) { num: u32, nothing: void, text: []const u8 };
    const items = [_]V{ .{ .num = 42 }, .{ .nothing = {} }, .{ .text = "hi" } };
    const list: []const V = &items;
    var buf: [sizeOf([]const V)]u8 align(8) = undefined;
    lower([]const V, list, &buf, &testAlloc);
    const got = lift([]const V, &buf);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expect(got[0] == .num);
    try testing.expectEqual(@as(u32, 42), got[0].num);
    try testing.expect(got[1] == .nothing);
    try testing.expect(got[2] == .text);
    try testing.expectEqualStrings("hi", got[2].text);

    // An empty list lifts to an empty slice (no allocation).
    var ebuf: [sizeOf([]const V)]u8 align(8) = undefined;
    lower([]const V, &.{}, &ebuf, &testAlloc);
    try testing.expectEqual(@as(usize, 0), lift([]const V, &ebuf).len);
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
        @as(i32, 0), @as(i32, 0), // name ptr,len
        @as(i32, 0), @as(i32, 0), @as(i32, 0), // tag none
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

test "list of aggregate elements: lower/lift round-trip (string / tuple<string,string>)" {
    // `list<string>` (wasi:cli get-arguments) and `list<tuple<string,string>>`
    // (get-environment) borrow the canonical element array in place — valid
    // because their canonical layout equals the native one.
    try testing.expect(layoutMatches([]const u8));
    try testing.expect(layoutMatches(Tuple(.{ []const u8, []const u8 })));
    try testing.expect(!layoutMatches(Result(u32, u8))); // a union: layout differs

    test_top = 0;
    {
        const L = []const []const u8;
        var buf: [sizeOf(L)]u8 align(8) = undefined;
        lower(L, &.{ "alpha", "beta", "gamma" }, &buf, &testAlloc);
        const got = lift(L, &buf);
        try testing.expectEqual(@as(usize, 3), got.len);
        try testing.expectEqualStrings("alpha", got[0]);
        try testing.expectEqualStrings("beta", got[1]);
        try testing.expectEqualStrings("gamma", got[2]);
    }
    {
        const Pair = Tuple(.{ []const u8, []const u8 });
        const L = []const Pair;
        var buf: [sizeOf(L)]u8 align(8) = undefined;
        lower(L, &.{ .{ "PATH", "/usr/bin" }, .{ "HOME", "/root" } }, &buf, &testAlloc);
        const got = lift(L, &buf);
        try testing.expectEqual(@as(usize, 2), got.len);
        try testing.expectEqualStrings("PATH", got[0][0]);
        try testing.expectEqualStrings("/usr/bin", got[0][1]);
        try testing.expectEqualStrings("HOME", got[1][0]);
        try testing.expectEqualStrings("/root", got[1][1]);
    }
}

test "Stream/Future intrinsic wrappers type-check for primitive elements" {
    // The read/write/drop/new methods declare `@extern` intrinsics whose module
    // is `[stream]stream<u8>` / `[future]future<u32>`; they can't be called
    // natively, but must type-check (analyzing them evaluates the module name).
    const S = Stream(u8);
    _ = @TypeOf(S.new);
    _ = @TypeOf(S.read);
    _ = @TypeOf(S.write);
    _ = @TypeOf(S.dropReadable);
    const F = Future(u32);
    _ = @TypeOf(F.new);
    _ = @TypeOf(F.read);
    _ = @TypeOf(F.write);
    // Adding methods doesn't change the handle marshalling.
    try testing.expectEqual(@as(usize, 1), flatCount(S));
    try testing.expectEqual(@as(usize, 1), flatCount(F));
}

test "FutureOf / StreamOf: parameterized module name, complex elements" {
    // `Future(T)` / `Stream(T)` are the primitive-spelling specializations of
    // `FutureOf` / `StreamOf`; they must be the *same* memoized nominal type
    // (so generated shells and the user impl agree on the type).
    try testing.expect(Future(u32) == FutureOf(u32, "[future]future<u32>"));
    try testing.expect(Stream(u8) == StreamOf(u8, "[stream]stream<u8>"));

    // A complex element (a `union(enum)` whose Zig layout != canonical ABI
    // layout) is valid for `FutureOf` — its module is a function-reference, and
    // marshalling is still a single i32 handle. `witSpell` is never reached.
    const TrailersFut = FutureOf(Result(u32, void), "[future]wasi:http/types@0.3.0#[static]request.new#1");
    try testing.expectEqual(@as(usize, 1), flatCount(TrailersFut));
    try testing.expectEqual(i32, CoreReturn(TrailersFut));
    // The raw `readInto`/`writeFrom` wrappers type-check for the complex element
    // (the primitive-layout `read`/`write` would be wrong to *call* here, but a
    // caller stages the element through `lower`/`lift` into a canonical buffer).
    _ = @TypeOf(TrailersFut.new);
    _ = @TypeOf(TrailersFut.readInto);
    _ = @TypeOf(TrailersFut.writeFrom);
    _ = @TypeOf(TrailersFut.dropReadable);
    _ = @TypeOf(TrailersFut.dropWritable);
    // The handle still lifts/lowers as a bare i32 across a Result/Tuple.
    const f = liftResultFlat(TrailersFut, returnResult(TrailersFut, .{ .handle = 5 }, &testAlloc));
    try testing.expectEqual(@as(i32, 5), f.handle);

    const BodyStream = StreamOf(Result(u8, void), "[stream]wasi:http/types@0.3.0#[static]request.new#0");
    try testing.expectEqual(@as(usize, 1), flatCount(BodyStream));
    _ = @TypeOf(BodyStream.readInto);
    _ = @TypeOf(BodyStream.writeFrom);
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
