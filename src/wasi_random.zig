//! `wasi_random` — guest-side bindings for `wasi:random@0.2.6`
//! (`random`, `insecure`, `insecure-seed`).
//!
//! The interfaces' function field names are all distinct, so the
//! `extern` declarations live at file scope.

const abi = @import("abi");

/// `random.get-random-u64() -> u64` — single i64 result returned directly.
extern "wasi:random/random@0.2.6" fn @"get-random-u64"() i64;
/// `random.get-random-bytes(len: u64) -> list<u8>` — retptr `[ptr, len]`.
extern "wasi:random/random@0.2.6" fn @"get-random-bytes"(len: i64, retptr: i32) void;
/// `insecure.get-insecure-random-u64() -> u64`.
extern "wasi:random/insecure@0.2.6" fn @"get-insecure-random-u64"() i64;
/// `insecure.get-insecure-random-bytes(len: u64) -> list<u8>`.
extern "wasi:random/insecure@0.2.6" fn @"get-insecure-random-bytes"(len: i64, retptr: i32) void;
/// `insecure-seed.insecure-seed() -> tuple<u64, u64>` — retptr `[lo, hi]`.
extern "wasi:random/insecure-seed@0.2.6" fn @"insecure-seed"(retptr: i32) void;

/// A cryptographically-secure random `u64`.
pub fn randomU64() u64 {
    return @bitCast(@"get-random-u64"());
}

/// `len` cryptographically-secure random bytes (borrow the scratch
/// arena, valid until the next `abi.resetScratch`).
pub fn randomBytes(len: u64) []const u8 {
    @"get-random-bytes"(@bitCast(len), abi.retPtr());
    return readBytes();
}

/// A fast, **non-cryptographic** random `u64`.
pub fn insecureRandomU64() u64 {
    return @bitCast(@"get-insecure-random-u64"());
}

/// `len` fast, **non-cryptographic** random bytes (borrow the scratch
/// arena).
pub fn insecureRandomBytes(len: u64) []const u8 {
    @"get-insecure-random-bytes"(@bitCast(len), abi.retPtr());
    return readBytes();
}

/// A 128-bit insecure seed, returned as `[lo, hi]` u64 halves.
pub fn insecureSeed() [2]u64 {
    @"insecure-seed"(abi.retPtr());
    const base: usize = @intCast(abi.retPtr());
    const lo = @as(*align(1) const u64, @ptrFromInt(base)).*;
    const hi = @as(*align(1) const u64, @ptrFromInt(base + 8)).*;
    return .{ lo, hi };
}

fn readBytes() []const u8 {
    const w = abi.retWords();
    const p: [*]const u8 = @ptrFromInt(w[0]);
    return p[0..w[1]];
}
