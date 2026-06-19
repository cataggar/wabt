//! `wasi_filesystem` — ergonomic guest-side helper for `wasi:filesystem@0.3.0`
//! (WASI 0.3 / Component-Model async).
//!
//! The canonical-ABI client wrappers are **generated** by
//! `wabt component bindgen` (see `wasi_filesystem_bindings.zig`); this module is
//! the thin ergonomic layer over them. File contents move through `stream<u8>`
//! (0.3 has no `wasi:io`): `read-via-stream` hands back a readable stream + a
//! completion `future`; `write-via-stream` takes a readable stream you write to.
//! The async `descriptor` methods (`stat`, `get-type`, `open-at`, …) block via
//! `cm_async.awaitCall` inside the generated wrappers, so they look synchronous.
//!
//! ## Usage
//!
//! ```zig
//! const fs = @import("wasi_filesystem");
//! const dirs = fs.preopens();
//! const root: fs.Descriptor = dirs[0][0];
//! var buf: [4096]u8 = undefined;
//! if (root.openAt(.{ .symlink_follow = true }, "hello.txt", .{}, .{ .read = true })) |file| {
//!     const data = fs.readAll(file.ok, 0, &buf);
//!     file.ok.deinit();
//!     _ = data;
//! }
//! ```

const b = @import("wasi_filesystem_bindings");
const canon = @import("canon");
const cm = @import("cm_async");
const abi = @import("abi");

const ByteStream = canon.Stream(u8);

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

// ── re-exported generated types ─────────────────────────────────────
pub const Descriptor = b.Descriptor;
pub const DescriptorType = b.DescriptorType;
pub const DescriptorFlags = b.DescriptorFlags;
pub const DescriptorStat = b.DescriptorStat;
pub const OpenFlags = b.OpenFlags;
pub const PathFlags = b.PathFlags;
pub const ErrorCode = b.ErrorCode;
pub const Filesize = b.Filesize;
pub const DirectoryEntry = b.DirectoryEntry;

/// A preopened directory paired with its name.
pub const Preopen = canon.Tuple(.{ Descriptor, []const u8 });

// ── async helpers (drive the generated stream/future channels) ──────

/// Block on `waitable` until it makes progress; returns the event payload.
fn waitCode(waitable: i32) u32 {
    const set = cm.WaitableSet.create();
    set.add(waitable);
    _ = set.waitOne();
    const code: u32 = abi.retWords()[1];
    set.drop();
    return code;
}

/// Write all of `bytes` to a stream's writable end, waiting on a blocked write.
fn writeStreamAll(s: ByteStream, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const status = s.write(bytes[off..]);
        const code: u32 = if (status == BLOCKED) waitCode(s.handle) else @bitCast(status);
        const n: usize = code >> 4;
        if (n == 0) break;
        off += n;
    }
}

/// Drive a `future<result<_, error-code>>` to completion (value ignored) and
/// drop its readable end. `fut` is the generated channel type.
fn awaitFuture(fut: anytype) void {
    var buf: [16]u8 align(8) = undefined;
    const status = fut.readInto(&buf);
    if (status == BLOCKED) _ = waitCode(fut.handle);
    fut.dropReadable();
}

// ── preopens ────────────────────────────────────────────────────────

/// The preopened directories as `(descriptor, name)` pairs (borrows the scratch
/// arena for the names; copy to retain).
pub fn preopens() []const Preopen {
    return b.preopens.getDirectories();
}

// ── streaming read / write ──────────────────────────────────────────

/// Read up to `buf.len` bytes starting at `offset` into `buf`, waiting on
/// blocked reads. Returns the prefix actually read (shorter than `buf` at EOF).
pub fn readAll(file: Descriptor, offset: Filesize, buf: []u8) []const u8 {
    const ends = file.readViaStream(offset);
    const stream: ByteStream = ends[0];
    const fut = ends[1]; // future<result<_, error-code>> signalling read result
    var len: usize = 0;
    while (len < buf.len) {
        const status = stream.read(buf[len..]);
        const code: u32 = if (status == BLOCKED) waitCode(stream.handle) else @bitCast(status);
        len += @as(usize, code >> 4);
        if (code & 0xf != 0) break; // closed / EOF
        if (code >> 4 == 0) break; // no progress
    }
    stream.dropReadable();
    awaitFuture(fut);
    return buf[0..len];
}

/// Write all of `bytes` starting at `offset`, flushing fully before returning.
pub fn writeAll(file: Descriptor, offset: Filesize, bytes: []const u8) void {
    const ends = ByteStream.new();
    const fut = file.writeViaStream(ends.readable, offset); // host drains the readable end
    writeStreamAll(ends.writable, bytes);
    ends.writable.dropWritable(); // EOF
    awaitFuture(fut);
}

// ── open conveniences ───────────────────────────────────────────────

/// Open `path` (relative to `dir`) read-only, following symlinks.
pub fn openRead(dir: Descriptor, path: []const u8) canon.Result(Descriptor, ErrorCode) {
    return dir.openAt(.{ .symlink_follow = true }, path, .{}, .{ .read = true });
}

/// Open (creating + truncating) `path` (relative to `dir`) for writing.
pub fn createWrite(dir: Descriptor, path: []const u8) canon.Result(Descriptor, ErrorCode) {
    return dir.openAt(.{ .symlink_follow = true }, path, .{ .create = true, .truncate = true }, .{ .write = true });
}
