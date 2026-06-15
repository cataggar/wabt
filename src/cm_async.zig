//! `cm_async` — guest-side WASI 0.3 / Component-Model **async** canonical
//! primitives.
//!
//! WASI 0.3 has no `wasi:io` package: the roles that `pollable` /
//! `input-stream` / `output-stream` played in 0.2 moved into the
//! canonical ABI as the first-class `future<T>` / `stream<T>` types and
//! the `async` lift/lower convention. This module is the guest side of
//! that contract: hand-written `extern` declarations of the canonical
//! **async built-in intrinsics** the guest core imports, plus thin typed
//! wrappers. The component wrapper (`wabt component new`, once it grows
//! P3 generation — cataggar/wabt#263) supplies these imports via the
//! corresponding `canon` definitions (`canon future.new`, `canon
//! stream.write`, `canon task.return`, …).
//!
//! ## The contract (guest ⇄ wrapper)
//!
//! Each async built-in is imported as a core function. The import
//! **module** names the built-in family **and the operand type** (so the
//! wrapper can pick the right component type index — every `future<T>` /
//! `stream<T>` is a distinct type); the **field** is the bare op. E.g.
//! `(import "[stream]stream<u8>" "write" (func …))` ⇒ `canon stream.write
//! $stream_u8`.
//!
//! > **Status: provisional / design-stage.** This intrinsic naming is the
//! > proposed wasip3 ⇄ wabt contract, to be finalized alongside wabt's P3
//! > generation (and reconciled with `wit-bindgen`'s convention for
//! > cross-toolchain interop). Nothing here builds into a runnable
//! > component until that generation lands; the validation target is the
//! > local wasmtime 46 build (`-S p3 -W component-model-async`).
//!
//! Lowered core signatures follow the component-model spec
//! (`design/mvp/CanonicalABI.md`) and were cross-checked against the
//! wasmtime `component-model/async` test fixtures.

const abi = @import("abi");

/// The two ends of a freshly created `future` / `stream`. `new` returns a
/// packed `i64`: **readable** in the low 32 bits, **writable** in the high.
pub const Ends = struct {
    readable: i32,
    writable: i32,
};

inline fn unpackEnds(handles: i64) Ends {
    const u: u64 = @bitCast(handles);
    return .{
        .readable = @bitCast(@as(u32, @truncate(u))),
        .writable = @bitCast(@as(u32, @truncate(u >> 32))),
    };
}

// ── stream<u8> intrinsics ──────────────────────────────────────────
//
// The byte-stream specialization used by `wasi:cli/std{in,out}` and most
// I/O. Each distinct `stream<T>` needs its own intrinsic family; only
// `stream<u8>` is declared here for now.

const stream_u8 = struct {
    /// `stream.new` → packed `i64` (readable | writable<<32).
    extern "[stream]stream<u8>" fn new() i64;
    /// `stream.read (memory)` → `(stream, ptr, count) -> status`.
    extern "[stream]stream<u8>" fn read(s: i32, ptr: i32, count: i32) i32;
    /// `stream.write (memory)` → `(stream, ptr, count) -> status`.
    extern "[stream]stream<u8>" fn write(s: i32, ptr: i32, count: i32) i32;
    /// `stream.drop-readable`.
    extern "[stream]stream<u8>" fn @"drop-readable"(s: i32) void;
    /// `stream.drop-writable`.
    extern "[stream]stream<u8>" fn @"drop-writable"(s: i32) void;
};

/// A `stream<u8>` end. The canonical `stream.write`/`read` status word
/// encodes progress / blocked / closed; callers that must wait on a
/// blocked op use a `WaitableSet`. This first-cut wrapper exposes the raw
/// status; higher-level blocking helpers land with the wabt generation
/// co-design.
pub const ByteStream = struct {
    handle: i32,

    /// Create a new `stream<u8>`, returning both ends.
    pub fn new() Ends {
        return unpackEnds(stream_u8.new());
    }

    /// Write `bytes` to the stream; returns the raw canonical status.
    pub fn write(self: ByteStream, bytes: []const u8) i32 {
        return stream_u8.write(self.handle, @intCast(@intFromPtr(bytes.ptr)), @intCast(bytes.len));
    }

    /// Read up to `buf.len` bytes; returns the raw canonical status.
    pub fn read(self: ByteStream, buf: []u8) i32 {
        return stream_u8.read(self.handle, @intCast(@intFromPtr(buf.ptr)), @intCast(buf.len));
    }

    pub fn dropReadable(self: ByteStream) void {
        stream_u8.@"drop-readable"(self.handle);
    }
    pub fn dropWritable(self: ByteStream) void {
        stream_u8.@"drop-writable"(self.handle);
    }
};

// ── error-context intrinsics ───────────────────────────────────────

const errctx = struct {
    /// `error-context.new (memory) (realloc)` → `(msg-ptr, msg-len) -> handle`.
    extern "[error-context]" fn new(msg_ptr: i32, msg_len: i32) i32;
    /// `error-context.debug-message (memory) (realloc)` → `(handle, retptr)`.
    extern "[error-context]" fn @"debug-message"(self: i32, retptr: i32) void;
    /// `error-context.drop`.
    extern "[error-context]" fn drop(self: i32) void;
};

/// A canonical `error-context` handle.
pub const ErrorContext = struct {
    handle: i32,

    /// Create an `error-context` from a debug message.
    pub fn init(message: []const u8) ErrorContext {
        return .{ .handle = errctx.new(@intCast(@intFromPtr(message.ptr)), @intCast(message.len)) };
    }

    /// Host-provided debug string (borrows the scratch arena).
    pub fn debugMessage(self: ErrorContext) []const u8 {
        errctx.@"debug-message"(self.handle, abi.retPtr());
        const w = abi.retWords();
        const p: [*]const u8 = @ptrFromInt(w[0]);
        return p[0..w[1]];
    }

    pub fn drop(self: ErrorContext) void {
        errctx.drop(self.handle);
    }
};

// ── waitable-set intrinsics (block on async ops) ───────────────────

const waitset = struct {
    /// `waitable-set.new` → `() -> set`.
    extern "[waitable-set]" fn new() i32;
    /// `waitable-set.wait (memory)` → `(set, retptr) -> event-code`.
    extern "[waitable-set]" fn wait(set: i32, retptr: i32) i32;
    /// `waitable-set.drop`.
    extern "[waitable-set]" fn drop(set: i32) void;
    /// `waitable.join` → `(waitable, set)`.
    extern "[waitable]" fn join(waitable: i32, set: i32) void;
};

/// A `waitable-set` — the guest blocks on it to wait for a `future` /
/// `stream` / `subtask` to make progress, mirroring 0.2's `poll`.
pub const WaitableSet = struct {
    handle: i32,

    pub fn create() WaitableSet {
        return .{ .handle = waitset.new() };
    }
    /// Register a `future`/`stream`/`subtask` waitable with this set.
    pub fn add(self: WaitableSet, waitable: i32) void {
        waitset.join(waitable, self.handle);
    }
    /// Block until an event; the payload is written to the ret-area as
    /// `[event-code, waitable, code]`. Returns the event code.
    pub fn waitOne(self: WaitableSet) i32 {
        return waitset.wait(self.handle, abi.retPtr());
    }
    pub fn drop(self: WaitableSet) void {
        waitset.drop(self.handle);
    }
};
