//! `abi` — shared guest-side Component Model canonical-ABI primitives.
//!
//! The `wasi_*` helper modules in this directory (`wasi_http`,
//! `wasi_keyvalue`, …) are thin typed wrappers over
//! `extern` declarations of host imports. Everything those wrappers
//! share — the `cabi_realloc` scratch arena and the "ret-area" used to
//! receive results wider than one core value — lives here, exactly once,
//! so a guest can pull in several `wasi_*` modules without duplicate
//! `cabi_realloc` exports or competing scratch state.
//!
//! ## Canonical ABI, briefly
//!
//! A component guest speaks the **canonical ABI**: host functions are
//! imported with lowered core-wasm signatures (every WIT type flattened
//! to `i32` / `i64` slots). The flattening rules used throughout the
//! `wasi_*` wrappers:
//!
//!   * `MAX_FLAT_PARAMS = 16`, `MAX_FLAT_RESULTS = 1`.
//!   * A result whose flattened representation exceeds one core value is
//!     returned through a guest-allocated "ret-area" pointer passed as
//!     the trailing parameter; the callee writes the flattened words
//!     there and the caller reads them back. `retPtr` / `retWords`
//!     below provide that area.
//!   * `string` and `list<T>` lower to `(ptr, len)` pairs.
//!   * `option<T>` lowers to `(discriminant, …flatten(T))`.
//!   * `result<T, E>` lowers to `(discriminant, …join(flatten(T), flatten(E)))`.
//!
//! There is no Zig `wit-bindgen` backend that emits these bindings, so
//! they are written by hand in the wrappers; this module factors out the
//! parts that are identical across every interface.

const std = @import("std");

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

const testing = std.testing;

test alignUp {
    try testing.expectEqual(@as(usize, 0), alignUp(0, 8));
    try testing.expectEqual(@as(usize, 8), alignUp(1, 8));
    try testing.expectEqual(@as(usize, 8), alignUp(8, 8));
    try testing.expectEqual(@as(usize, 16), alignUp(9, 8));
    try testing.expectEqual(@as(usize, 16), alignUp(16, 16));
    try testing.expectEqual(@as(usize, 5), alignUp(5, 1));
}

test "cabi_realloc bumps, aligns, and grows monotonically" {
    resetScratch();

    const a = cabi_realloc(0, 0, 16, 32);
    try testing.expect(a != 0);
    try testing.expectEqual(@as(usize, 0), a % 16);

    // Next allocation is past the first and respects its alignment.
    const b = cabi_realloc(0, 0, 8, 8);
    try testing.expect(b >= a + 32);
    try testing.expectEqual(@as(usize, 0), b % 8);
}

test "cabi_realloc: zero size returns 0, oversize fails, reset reclaims" {
    resetScratch();

    try testing.expectEqual(@as(usize, 0), cabi_realloc(0, 0, 1, 0));

    // A request larger than the whole arena cannot be satisfied.
    try testing.expectEqual(@as(usize, 0), cabi_realloc(0, 0, 1, arena_buf.len + 1));

    // Fill the arena, then confirm reset makes room again.
    const full = cabi_realloc(0, 0, 1, arena_buf.len);
    try testing.expect(full != 0);
    try testing.expectEqual(@as(usize, 0), cabi_realloc(0, 0, 1, 1));
    resetScratch();
    try testing.expect(cabi_realloc(0, 0, 1, 1) != 0);
}

test "readResultHandle decodes the ok and err arms" {
    const w = retWords();

    w[0] = 0; // ok
    w[1] = @bitCast(@as(i32, 42));
    try testing.expectEqual(@as(?i32, 42), readResultHandle());

    w[0] = 1; // err
    try testing.expectEqual(@as(?i32, null), readResultHandle());
}
