//! `wasi_clocks` — guest-side bindings for `wasi:clocks@0.2.6`
//! (`monotonic-clock` and `wall-clock`).
//!
//! Both interfaces export `now` / `resolution`, so their `extern`
//! declarations are placed in separate struct namespaces to avoid a
//! Zig identifier clash while keeping the canonical import field names.

const abi = @import("abi");

const mono = struct {
    /// `monotonic-clock.now() -> instant` (instant = u64) — single i64
    /// result returned directly.
    extern "wasi:clocks/monotonic-clock@0.2.6" fn now() i64;
    /// `monotonic-clock.resolution() -> duration` (duration = u64).
    extern "wasi:clocks/monotonic-clock@0.2.6" fn resolution() i64;
};

const wall = struct {
    /// `wall-clock.now() -> datetime`. `datetime { seconds: u64,
    /// nanoseconds: u32 }` flattens to 2 slots → spilled to retptr
    /// `[seconds @ 0, nanoseconds @ 8]`.
    extern "wasi:clocks/wall-clock@0.2.6" fn now(retptr: i32) void;
    /// `wall-clock.resolution() -> datetime`.
    extern "wasi:clocks/wall-clock@0.2.6" fn resolution(retptr: i32) void;
};

/// `wasi:clocks/wall-clock.datetime`.
pub const Datetime = struct {
    seconds: u64,
    nanoseconds: u32,
};

/// Monotonic clock reading, in nanoseconds since an arbitrary epoch.
pub fn monotonicNow() u64 {
    return @bitCast(mono.now());
}

/// Monotonic clock resolution, in nanoseconds.
pub fn monotonicResolution() u64 {
    return @bitCast(mono.resolution());
}

/// Current wall-clock time (seconds + nanoseconds since the Unix epoch).
pub fn wallNow() Datetime {
    wall.now(abi.retPtr());
    return readDatetime();
}

/// Wall-clock resolution.
pub fn wallResolution() Datetime {
    wall.resolution(abi.retPtr());
    return readDatetime();
}

fn readDatetime() Datetime {
    const base: usize = @intCast(abi.retPtr());
    const seconds = @as(*align(1) const u64, @ptrFromInt(base)).*;
    const nanoseconds = @as(*align(1) const u32, @ptrFromInt(base + 8)).*;
    return .{ .seconds = seconds, .nanoseconds = nanoseconds };
}
