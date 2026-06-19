//! `wasi_clocks` — ergonomic guest-side helper for `wasi:clocks@0.3.0`
//! (WASI 0.3 / Component-Model async).
//!
//! The canonical-ABI client wrappers are **generated** by
//! `wabt component bindgen` (see `wasi_clocks_bindings.zig`); this module is the
//! thin ergonomic layer over them. The two `monotonic-clock` waits are
//! `async func`s — their generated wrappers block via `cm_async.awaitCall`, so
//! `sleep` / `sleepUntil` look synchronous to the guest.
//!
//! ## Usage
//!
//! ```zig
//! const clocks = @import("wasi_clocks");
//! const start = clocks.monotonicNow();
//! clocks.sleep(1_000_000); // 1ms
//! const elapsed = clocks.monotonicNow() - start;
//! const wall = clocks.systemNow(); // { seconds, nanoseconds } since the epoch
//! ```

const b = @import("wasi_clocks_bindings");

/// A duration of time, in nanoseconds.
pub const Duration = b.Duration;
/// A mark on the monotonic clock (nanoseconds since an unspecified start).
pub const Mark = b.Mark;
/// A point in time as `{ seconds, nanoseconds }` since 1970-01-01T00:00:00Z.
pub const Instant = b.Instant;

// ── monotonic clock ─────────────────────────────────────────────────

/// The current monotonic-clock value (non-decreasing across calls).
pub fn monotonicNow() Mark {
    return b.monotonic_clock.now();
}

/// The monotonic clock's resolution (duration of one tick), in nanoseconds.
pub fn monotonicResolution() Duration {
    return b.monotonic_clock.getResolution();
}

/// Block until the monotonic clock reaches `when`.
pub fn sleepUntil(when: Mark) void {
    b.monotonic_clock.waitUntil(when);
}

/// Block for `how_long` nanoseconds.
pub fn sleep(how_long: Duration) void {
    b.monotonic_clock.waitFor(how_long);
}

// ── system clock ────────────────────────────────────────────────────

/// The current wall-clock time (not monotonic; may be reset). The
/// `nanoseconds` field is always less than 1_000_000_000.
pub fn systemNow() Instant {
    return b.system_clock.now();
}

/// The system clock's resolution, in nanoseconds.
pub fn systemResolution() Duration {
    return b.system_clock.getResolution();
}
