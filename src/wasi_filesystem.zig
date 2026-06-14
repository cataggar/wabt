//! `wasi_filesystem` — guest-side bindings for `wasi:filesystem@0.2.6`.
//!
//! Demand-driven: currently binds `preopens.get-directories` plus the
//! `descriptor` resource-drop. The full `types` interface (open-at,
//! read/write streams, stat, …) is large and added as examples need it.

const abi = @import("abi");

/// `preopens.get-directories() -> list<tuple<descriptor, string>>`. The
/// 2-word list header spills to retptr `[elems_ptr, count]`; each element
/// is 12 bytes: `[descriptor: u32 @0, path_ptr: u32 @4, path_len: u32 @8]`.
extern "wasi:filesystem/preopens@0.2.6" fn @"get-directories"(retptr: i32) void;

/// `[resource-drop]descriptor(own<descriptor>)`.
extern "wasi:filesystem/types@0.2.6" fn @"[resource-drop]descriptor"(self: i32) void;

/// A preopened directory: its `descriptor` handle and the guest path it
/// is mapped to. `path` borrows the scratch arena.
pub const Preopen = struct {
    descriptor: i32,
    path: []const u8,

    /// Drop the descriptor handle (canonical `resource.drop`).
    pub fn drop(self: Preopen) void {
        @"[resource-drop]descriptor"(self.descriptor);
    }
};

/// The list returned by `getDirectories`, borrowing the scratch arena
/// (valid until the next `abi.resetScratch`).
pub const Preopens = struct {
    base: usize,
    count: usize,

    const element_size = 12;

    pub fn len(self: Preopens) usize {
        return self.count;
    }

    pub fn get(self: Preopens, i: usize) Preopen {
        const e = self.base + i * element_size;
        const handle = @as(*align(1) const u32, @ptrFromInt(e)).*;
        const ptr = @as(*align(1) const u32, @ptrFromInt(e + 4)).*;
        const path_len = @as(*align(1) const u32, @ptrFromInt(e + 8)).*;
        const p: [*]const u8 = @ptrFromInt(ptr);
        return .{ .descriptor = @bitCast(handle), .path = p[0..path_len] };
    }
};

/// List the directories preopened by the host (e.g. wasmtime `--dir`).
pub fn getDirectories() Preopens {
    @"get-directories"(abi.retPtr());
    const w = abi.retWords();
    return .{ .base = @intCast(w[0]), .count = w[1] };
}
