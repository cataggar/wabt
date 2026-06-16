//! `wasi_io` — guest-side bindings for `wasi:io@0.2.6` (the `error`,
//! `poll`, and `streams` interfaces).
//!
//! `wasi:io/streams` is foundational: `wasi:cli`, `wasi:http`,
//! `wasi:filesystem`, and `wasi:sockets` all hand back `input-stream` /
//! `output-stream` handles. Centralizing the stream/poll/error `extern`
//! declarations here lets those wrappers share one set (and one
//! `[resource-drop]`) instead of each re-declaring its own.
//!
//! Like the sibling `wasi_*` modules these are canonical-ABI
//! `extern`s over a thin typed API; the shared ret-area + `cabi_realloc`
//! live in `abi`, so a guest may combine this with other wrappers without
//! duplicate exports.

const abi = @import("abi");

const retPtr = abi.retPtr;
const retWords = abi.retWords;

// ── wasi:io/streams ────────────────────────────────────────────────

/// `[method]output-stream.blocking-write-and-flush(borrow, list<u8>)
///   -> result<_, stream-error>`. `list<u8>` → (ptr, len); the 2-word
/// result spills to retptr `[disc, stream_err_disc]`.
extern "wasi:io/streams@0.2.6" fn @"[method]output-stream.blocking-write-and-flush"(
    self: i32,
    contents_ptr: i32,
    contents_len: i32,
    retptr: i32,
) void;

/// `[method]output-stream.blocking-flush(borrow) -> result<_, stream-error>`.
extern "wasi:io/streams@0.2.6" fn @"[method]output-stream.blocking-flush"(self: i32, retptr: i32) void;

/// `[resource-drop]output-stream(own<output-stream>)` — the canonical
/// `resource.drop` built-in.
extern "wasi:io/streams@0.2.6" fn @"[resource-drop]output-stream"(self: i32) void;

/// `[method]input-stream.blocking-read(borrow, u64)
///   -> result<list<u8>, stream-error>`. `u64` → i64; the 3-word result
/// spills to retptr `[disc, ptr, len]`. End-of-stream surfaces as the
/// err arm (disc=1).
extern "wasi:io/streams@0.2.6" fn @"[method]input-stream.blocking-read"(self: i32, len: i64, retptr: i32) void;

/// `[resource-drop]input-stream(own<input-stream>)`.
extern "wasi:io/streams@0.2.6" fn @"[resource-drop]input-stream"(self: i32) void;

// ── wasi:io/poll ───────────────────────────────────────────────────

/// `[method]pollable.ready(borrow) -> bool`. `bool` lowers to a single
/// i32 (0 / 1).
extern "wasi:io/poll@0.2.6" fn @"[method]pollable.ready"(self: i32) i32;

/// `[method]pollable.block(borrow)` — block until the pollable is ready.
extern "wasi:io/poll@0.2.6" fn @"[method]pollable.block"(self: i32) void;

/// `[resource-drop]pollable(own<pollable>)`.
extern "wasi:io/poll@0.2.6" fn @"[resource-drop]pollable"(self: i32) void;

// ── wasi:io/error ──────────────────────────────────────────────────

/// `[method]error.to-debug-string(borrow) -> string`. `string` → (ptr,
/// len) spilled to retptr `[ptr, len]`.
extern "wasi:io/error@0.2.6" fn @"[method]error.to-debug-string"(self: i32, retptr: i32) void;

/// `[resource-drop]error(own<error>)`.
extern "wasi:io/error@0.2.6" fn @"[resource-drop]error"(self: i32) void;

// ── Public API ──────────────────────────────────────────────────────

/// A `wasi:io/streams.output-stream` handle. Methods are best-effort:
/// the `result<_, stream-error>` is ignored (a closed stream simply
/// drops further writes), matching the seed wrappers' behavior.
pub const OutputStream = struct {
    handle: i32,

    /// Write `bytes` and flush (blocking). No-op for an empty slice.
    pub fn writeAll(self: OutputStream, bytes: []const u8) void {
        if (bytes.len == 0) return;
        @"[method]output-stream.blocking-write-and-flush"(
            self.handle,
            @intCast(@intFromPtr(bytes.ptr)),
            @intCast(bytes.len),
            retPtr(),
        );
    }

    /// Block until all previously written data is flushed.
    pub fn flush(self: OutputStream) void {
        @"[method]output-stream.blocking-flush"(self.handle, retPtr());
    }

    /// Drop the handle (canonical `resource.drop`).
    pub fn drop(self: OutputStream) void {
        @"[resource-drop]output-stream"(self.handle);
    }
};

/// A `wasi:io/streams.input-stream` handle.
pub const InputStream = struct {
    handle: i32,

    /// Blocking read of up to `max` bytes. Returns the bytes (borrowing
    /// the scratch arena, valid until the next `abi.resetScratch`) on the
    /// ok arm, or `null` at end-of-stream / on a stream error.
    pub fn blockingRead(self: InputStream, max: u64) ?[]const u8 {
        @"[method]input-stream.blocking-read"(self.handle, @intCast(max), retPtr());
        const w = retWords();
        if (w[0] != 0) return null; // err arm: closed or last-operation-failed
        const p: [*]const u8 = @ptrFromInt(w[1]);
        return p[0..w[2]];
    }

    /// Drop the handle (canonical `resource.drop`).
    pub fn drop(self: InputStream) void {
        @"[resource-drop]input-stream"(self.handle);
    }
};

/// A `wasi:io/poll.pollable` handle.
pub const Pollable = struct {
    handle: i32,

    /// True if the pollable is ready (non-blocking check).
    pub fn ready(self: Pollable) bool {
        return @"[method]pollable.ready"(self.handle) != 0;
    }

    /// Block until the pollable is ready.
    pub fn block(self: Pollable) void {
        @"[method]pollable.block"(self.handle);
    }

    /// Drop the handle (canonical `resource.drop`).
    pub fn drop(self: Pollable) void {
        @"[resource-drop]pollable"(self.handle);
    }
};

/// A `wasi:io/error.error` handle (an opaque host error).
pub const Error = struct {
    handle: i32,

    /// Host-provided debug string (borrows the scratch arena).
    pub fn toDebugString(self: Error) []const u8 {
        @"[method]error.to-debug-string"(self.handle, retPtr());
        const w = retWords();
        const p: [*]const u8 = @ptrFromInt(w[0]);
        return p[0..w[1]];
    }

    /// Drop the handle (canonical `resource.drop`).
    pub fn drop(self: Error) void {
        @"[resource-drop]error"(self.handle);
    }
};
