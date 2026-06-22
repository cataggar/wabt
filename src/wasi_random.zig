//! `wasi_random` — ergonomic guest-side helper for `wasi:random@0.3.0`
//! (WASI 0.3).
//!
//! The canonical-ABI client wrappers are **generated** by
//! `wabt component bindgen` (see `wasi_random_bindings.zig`); this module is the
//! thin ergonomic layer over them. Every function here is synchronous — the
//! interface has no async members.
//!
//! ## Usage
//!
//! ```zig
//! const random = @import("wasi_random");
//! const x = random.u64(); // cryptographically-secure
//! const bytes = random.bytes(32); // borrows the scratch arena; copy to retain
//! const seed = random.insecureSeed(); // { a, b } for hash-map DoS resistance
//! ```

const b = @import("wasi_random_bindings");
const wit_types = @import("wit_types");

const canon = wit_types.canon;

/// A 128-bit seed value as `{ a, b }`.
pub const Seed = canon.Tuple(.{ u64, u64 });

// ── secure random ───────────────────────────────────────────────────

/// Up to `max_len` cryptographically-secure random bytes (borrows the scratch
/// arena; copy out to retain). May return fewer than `max_len` (short read);
/// loop if an exact count is required.
pub fn bytes(max_len: u64) []const u8 {
    return b.random.getRandomBytes(max_len);
}

/// A cryptographically-secure random `u64`.
pub fn u64v() u64 {
    return b.random.getRandomU64();
}

// ── insecure (non-cryptographic) random ─────────────────────────────

/// Up to `max_len` insecure pseudo-random bytes (borrows the scratch arena).
/// Not cryptographically secure — do not use for anything security-related.
pub fn insecureBytes(max_len: u64) []const u8 {
    return b.insecure.getInsecureRandomBytes(max_len);
}

/// An insecure pseudo-random `u64`. Not cryptographically secure.
pub fn insecureU64() u64 {
    return b.insecure.getInsecureRandomU64();
}

/// A 128-bit value for seeding hash-map DoS resistance. Not required to come
/// from a CSPRNG; intended to be called once at startup.
pub fn insecureSeed() Seed {
    return b.insecure_seed.getInsecureSeed();
}
