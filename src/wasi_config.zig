//! `wasi_config` — guest-side bindings for the off-by-default
//! `wasi:config@0.2.0-rc.1` proposal (`store`).
//!
//! `store.get` collides with the typed wrappers' `get`, so the `extern`
//! imports live in a `raw` struct namespace.

const abi = @import("abi");

const raw = struct {
    /// `store.get(key: string) -> result<option<string>, error>`. retptr
    /// (align 4): `[result-disc @0, option/err-disc @4, ptr @8, len @12]`.
    extern "wasi:config/store@0.2.0-rc.1" fn @"get"(key_ptr: i32, key_len: i32, retptr: i32) void;
    /// `store.get-all() -> result<list<tuple<string,string>>, error>`.
    /// retptr: `[result-disc @0, elems_ptr @4, count @8]`.
    extern "wasi:config/store@0.2.0-rc.1" fn @"get-all"(retptr: i32) void;
};

pub const Error = error{ConfigError};

/// `store.get(key)`. Returns the value (borrowing the scratch arena),
/// `null` for a missing key, or `error.ConfigError` on a store error.
pub fn get(key: []const u8) Error!?[]const u8 {
    raw.get(@intCast(@intFromPtr(key.ptr)), @intCast(key.len), abi.retPtr());
    const w = abi.retWords();
    if (w[0] != 0) return error.ConfigError; // result::err
    if (w[1] == 0) return null; // option::none
    const p: [*]const u8 = @ptrFromInt(w[2]);
    return p[0..w[3]];
}

/// One `(key, value)` configuration entry (borrows the scratch arena).
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// The list returned by `getAll`, borrowing the scratch arena (valid
/// until the next `abi.resetScratch`).
pub const Entries = struct {
    base: usize,
    count: usize,

    const stride = 16; // tuple<string, string> = 4 u32 words

    pub fn len(self: Entries) usize {
        return self.count;
    }

    pub fn get(self: Entries, i: usize) Entry {
        const e = self.base + i * stride;
        const kp = @as(*align(1) const u32, @ptrFromInt(e)).*;
        const kl = @as(*align(1) const u32, @ptrFromInt(e + 4)).*;
        const vp = @as(*align(1) const u32, @ptrFromInt(e + 8)).*;
        const vl = @as(*align(1) const u32, @ptrFromInt(e + 12)).*;
        const k: [*]const u8 = @ptrFromInt(kp);
        const v: [*]const u8 = @ptrFromInt(vp);
        return .{ .key = k[0..kl], .value = v[0..vl] };
    }
};

/// `store.get-all()`. Returns all configuration entries, or
/// `error.ConfigError` on a store error.
pub fn getAll() Error!Entries {
    raw.@"get-all"(abi.retPtr());
    const w = abi.retWords();
    if (w[0] != 0) return error.ConfigError;
    return .{ .base = @intCast(w[1]), .count = w[2] };
}
