//! `wasi_http_client` — guest-side driver for issuing **outgoing** HTTP
//! requests through the imported `wasi:http/client@0.3.0#send` (WASI 0.3 /
//! Component-Model async).
//!
//! The `wasi:http/types` client surface (the `request` / `response` / `fields`
//! resources and the body `stream<u8>` + trailers `future` channels) is
//! **generated** by `wabt component bindgen` (see `wasi_http_bindings.zig`);
//! this module is the thin ergonomic layer over it, mirroring `wasi_http.zig`
//! (the service-handler side) in reverse.
//!
//! `send` is **async** (`func(request) -> result<response, error-code>`):
//! `request` issues the call, writes the request body while the call is in
//! flight, and only then awaits — so a request body larger than the stream's
//! initial window can't deadlock against a host that reads it before
//! responding.
//!
//! ## Usage
//!
//! ```zig
//! const http = @import("wasi_http_client");
//! var buf: [64 * 1024]u8 = undefined;
//! if (http.request("localhost:8080", .get, "/pets", null, &buf)) |reply| {
//!     // reply.status, reply.body
//! }
//! ```

const std = @import("std");
const b = @import("wasi_http_bindings");
const wit_types = @import("wit_types");
const cm = @import("wit_async");

pub const Request = b.Request;
pub const Response = b.Response;
pub const Fields = b.Fields;
pub const Method = b.Method;
pub const Scheme = b.Scheme;
pub const ErrorCode = b.ErrorCode;
const ByteStream = wit_types.Stream(u8);

// The private body/trailers/transmission `future` channel types, recovered by
// reflection on the generated signatures (the same trick the service side
// uses): `request.new`'s `trailers` param is the trailers future, and
// `response.consume-body`'s `res` param is the transmission future.
const TrailersFut = @typeInfo(@TypeOf(Request.new)).@"fn".params[2].type.?;
const TxnFut = @typeInfo(@TypeOf(Response.consumeBody)).@"fn".params[1].type.?;

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

// `ok(())` / `ok(none)` of the trailers / transmission futures are all-zero.
var ok_zero: [64]u8 align(8) = [_]u8{0} ** 64;

// Dedicated result area for the async `send` call. It must stay live from the
// call until `awaitCall` completes (the host writes the `result<response,
// error-code>` here), and must NOT be the shared ret-area — interim
// `waitable-set.wait`s during body streaming target the ret-area, and would
// otherwise clobber the pending response.
var send_result: [64]u8 align(8) = undefined;

// The async-lowered `wasi:http/client@0.3.0#send` import: `(request,
// result-ptr) -> status`. `status`'s low nibble is the `CallState`; a blocked
// call carries a subtask handle in the high bits that `cm.awaitCall` drives.
extern "wasi:http/client@0.3.0" fn send(request: i32, result_ptr: i32) i32;

/// Block on `waitable` until it makes progress; returns the canonical status
/// word (`waitable-set.wait` writes `[event, waitable, code]` to the ret-area).
fn waitCode(waitable: i32) u32 {
    const set = cm.WaitableSet.create();
    set.add(waitable);
    _ = set.waitOne();
    const code: u32 = wit_types.retWords()[1];
    set.drop();
    return code;
}

/// Write all of `bytes` to a body stream's writable end, cooperatively waiting
/// on a blocked write, then signal EOF by dropping the end.
fn writeBody(w: ByteStream, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const status = w.write(bytes[off..]);
        const code: u32 = if (status == BLOCKED) waitCode(w.handle) else @bitCast(status);
        const n: usize = code >> 4;
        if (n == 0) break;
        off += n;
    }
    w.dropWritable();
}

/// Resolve a `future<result<…>>` writable end with `ok` (all-zero payload),
/// cooperatively waiting if the write blocks, then drop it.
fn signalOk(w: anytype) void {
    const status = w.writeFrom(&ok_zero);
    if (status == BLOCKED) _ = waitCode(w.handle);
    w.dropWritable();
}

/// Consume the response and read its body into `buf`, cooperatively waiting on
/// blocked reads. Drops the trailers future and signals `ok(())` on the
/// transmission future.
fn readBody(resp: Response, buf: []u8) []const u8 {
    const txn = TxnFut.new();
    const tup = Response.consumeBody(resp, txn.readable);
    const stream: ByteStream = tup[0];
    const trailers = tup[1];

    var len: usize = 0;
    while (len < buf.len) {
        const status = stream.read(buf[len..]);
        const code: u32 = if (status == BLOCKED) waitCode(stream.handle) else @bitCast(status);
        len += @as(usize, code >> 4);
        if (code & 0xf != 0) break; // dropped (EOF) / cancelled
        if (code >> 4 == 0) break; // no progress
    }
    stream.dropReadable();
    trailers.dropReadable();
    signalOk(txn.writable);
    return buf[0..len];
}

/// A completed response: the HTTP status code and the body bytes (borrowing the
/// caller-provided buffer passed to `request`).
pub const Reply = struct {
    status: u16,
    body: []const u8,
};

/// Issue one request to `authority` (`host:port`) and return the response
/// status + body (read into `out`), or null on a transport-level `error-code`.
pub fn request(authority: []const u8, method: Method, path: []const u8, body: ?[]const u8, out: []u8) ?Reply {
    const headers = Fields.init();
    if (body != null) _ = headers.append("content-type", "application/json");

    var contents: ?ByteStream = null;
    var body_w: ByteStream = undefined;
    if (body != null) {
        const ends = ByteStream.new();
        contents = ends.readable;
        body_w = ends.writable;
    }

    const tf = TrailersFut.new();
    const made = Request.new(headers, contents, tf.readable, null);
    const req = made[0];
    const transmission = made[1];
    transmission.dropReadable();

    _ = req.setMethod(method);
    _ = req.setPathWithQuery(path);
    _ = req.setScheme(Scheme.HTTP);
    _ = req.setAuthority(authority);

    // Issue the async call (result lands in `send_result`), then stream the
    // body while it's in flight, then await.
    const status = send(req.handle, @intCast(@intFromPtr(&send_result)));
    if (body) |payload| writeBody(body_w, payload);
    signalOk(tf.writable);
    cm.awaitCall(status);

    const result = wit_types.lift(wit_types.Result(Response, ErrorCode), @ptrCast(&send_result));
    switch (result) {
        .ok => |resp| {
            const sc = resp.getStatusCode();
            const rb = readBody(resp, out);
            return .{ .status = sc, .body = rb };
        },
        .err => return null,
    }
}
