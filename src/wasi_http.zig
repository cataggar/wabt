//! `wasi_http` — guest-side helper for a `wasi:http/service@0.3.0` component
//! in pure Zig (WASI 0.3 / Component-Model async).
//!
//! A service exports `wasi:http/handler@0.3.0#handle`, an **async**
//! `func(request) -> result<response, error-code>`. This module reads the
//! request (method, path-with-query, and the request body), invokes a user
//! `handler` that fills a `Responder` (status, content-type, body), then
//! builds the `response` and streams it back.
//!
//! ## Concurrency
//!
//! Hosts (e.g. `wasmtime serve`) may invoke `handle` concurrently: multiple
//! request tasks can be in flight, interleaved at `await` points on one thread.
//! To stay correct, **all per-request data lives in per-task stack buffers**
//! (the request path/body and the response body), never in the shared
//! `cabi_realloc` arena. The arena is reset at the top of each `handle` and
//! only used transiently for canonical-ABI string lifts, which are copied to
//! stack storage before the task ever yields — so a sibling task's reset can
//! never clobber live data. Application state (e.g. an in-memory store) must
//! likewise be in static globals mutated with synchronous, await-free ops.
//!
//! ## Usage
//!
//! ```zig
//! const http = @import("wasi_http");
//! fn handle(req: *const http.Request, res: *http.Responder) void {
//!     res.setStatus(200);
//!     res.writeAll("hello");
//! }
//! comptime { http.exportHandler(handle); }
//! ```

const std = @import("std");
const abi = @import("abi");
const cm = @import("cm_async");

/// HTTP method (the standard cases of `wasi:http`'s `method` variant; `other`
/// covers any extension method).
pub const Method = enum(u8) {
    get = 0,
    head = 1,
    post = 2,
    put = 3,
    delete = 4,
    connect = 5,
    options = 6,
    trace = 7,
    patch = 8,
    other = 9,
};

/// A decoded incoming request. `path` is the full path-with-query
/// (e.g. `/pets/3?x=1`); `body` is the request body (empty unless read).
/// Both borrow per-task stack buffers valid for the `handler` call.
pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
};

/// What the handler fills in: a status, a content-type, and a body written
/// into a caller-provided per-task buffer.
pub const Responder = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    buf: []u8,
    len: usize = 0,

    pub fn setStatus(self: *Responder, status: u16) void {
        self.status = status;
    }

    pub fn writeAll(self: *Responder, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], bytes[0..n]);
        self.len += n;
    }

    /// `std.fmt`-style append into the response buffer.
    pub fn print(self: *Responder, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch self.buf[self.len..self.len];
        self.len += out.len;
    }

    pub fn body(self: *const Responder) []const u8 {
        return self.buf[0..self.len];
    }
};

// ── Host imports: wasi:http/types@0.3.0 resource canons ─────────────

extern "wasi:http/types@0.3.0" fn @"[constructor]fields"() i32;
extern "wasi:http/types@0.3.0" fn @"[method]fields.append"(self: i32, name_ptr: i32, name_len: i32, val_ptr: i32, val_len: i32, retptr: i32) void;

extern "wasi:http/types@0.3.0" fn @"[method]request.get-method"(self: i32, retptr: i32) void;
extern "wasi:http/types@0.3.0" fn @"[method]request.get-path-with-query"(self: i32, retptr: i32) void;
extern "wasi:http/types@0.3.0" fn @"[resource-drop]request"(req: i32) void;
/// `consume-body(this: request, res: future<result<_, error-code>>)
///   -> tuple<stream<u8>, future<result<option<trailers>, error-code>>>`.
/// Moves the request; returns the body stream + the request's trailers future.
extern "wasi:http/types@0.3.0" fn @"[static]request.consume-body"(this: i32, res: i32, retptr: i32) void;

extern "wasi:http/types@0.3.0" fn @"[static]response.new"(
    headers: i32,
    contents_disc: i32,
    contents_stream: i32,
    trailers: i32,
    retptr: i32,
) void;
extern "wasi:http/types@0.3.0" fn @"[method]response.set-status-code"(self: i32, status: i32) i32;

// The trailers `future<result<option<trailers>, error-code>>` — named after
// `request.new`'s async type #1 (response.new / consume-body reuse this type).
const trailers_future = struct {
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn new() i64;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn write(f: i32, ptr: i32) i32;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn @"drop-writable"(f: i32) void;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn @"drop-readable"(f: i32) void;
};

// The `future<result<_, error-code>>` (request.new async type #2): the result
// transmission future from `response.new`, and the `res` error-signal future
// passed to `consume-body`.
const txn_future = struct {
    extern "[future]wasi:http/types@0.3.0#[static]request.new#2" fn new() i64;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#2" fn write(f: i32, ptr: i32) i32;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#2" fn @"drop-writable"(f: i32) void;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#2" fn @"drop-readable"(f: i32) void;
};

const handle_task = struct {
    extern "[task-return]wasi:http/handler@0.3.0#handle" fn @"task-return"(
        d0: i32,
        d1: i32,
        d2: i32,
        d3: i64,
        d4: i32,
        d5: i32,
        d6: i32,
        d7: i32,
    ) void;
};

// `ok(none)` of `result<option<trailers>, error-code>` is all-zero bytes.
var trailers_ok_none: [64]u8 align(8) = [_]u8{0} ** 64;

/// Canonical `stream.write` status: blocked (operation pending).
const STREAM_BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

// ── Request decoding ────────────────────────────────────────────────

fn readMethod(request: i32) Method {
    @"[method]request.get-method"(request, abi.retPtr());
    const disc = abi.retWords()[0];
    return if (disc <= @intFromEnum(Method.patch))
        @enumFromInt(@as(u8, @intCast(disc)))
    else
        .other;
}

fn readPathWithQuery(request: i32, buf: []u8) []const u8 {
    @"[method]request.get-path-with-query"(request, abi.retPtr());
    const w = abi.retWords();
    if (w[0] != 1) return buf[0..0]; // none
    const src: [*]const u8 = @ptrFromInt(w[1]);
    const n = @min(@as(usize, w[2]), buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// Consume the request and read its body into `buf`, cooperatively waiting on
/// blocked reads. Also drops the request's trailers future and the `res`
/// error-signal future (we never signal a request-handling error).
fn readBody(request: i32, buf: []u8) []const u8 {
    const res = cm.unpack(txn_future.new());
    @"[static]request.consume-body"(request, res.readable, abi.retPtr());
    const rw = abi.retWords();
    const body_stream: i32 = @bitCast(rw[0]);
    const req_trailers: i32 = @bitCast(rw[1]);

    const stream = cm.ByteStream{ .handle = body_stream };
    var len: usize = 0;
    while (len < buf.len) {
        const status = stream.read(buf[len..]);
        const code: u32 = if (status == STREAM_BLOCKED) blk: {
            const set = cm.WaitableSet.create();
            set.add(body_stream);
            _ = set.waitOne();
            const c: u32 = abi.retWords()[2];
            set.drop();
            break :blk c;
        } else @bitCast(status);
        len += @as(usize, code >> 4);
        if (code & 0xf != 0) break; // dropped (EOF) / cancelled
        if (code >> 4 == 0) break; // no progress
    }
    stream.dropReadable();
    trailers_future.@"drop-readable"(req_trailers);
    // The `res` error-signal future must carry a value before its writable end
    // is dropped: write ok(()) (no request-handling error), then drop.
    _ = txn_future.write(res.writable, @intCast(@intFromPtr(&trailers_ok_none)));
    txn_future.@"drop-writable"(res.writable);
    return buf[0..len];
}

// ── Response building ───────────────────────────────────────────────

fn writeBody(writable: i32, bytes: []const u8) void {
    const stream = cm.ByteStream{ .handle = writable };
    var off: usize = 0;
    while (off < bytes.len) {
        const status = stream.write(bytes[off..]);
        if (status == STREAM_BLOCKED) {
            const set = cm.WaitableSet.create();
            set.add(writable);
            _ = set.waitOne();
            const code: u32 = abi.retWords()[2];
            set.drop();
            const n: usize = @intCast(code >> 4);
            if (n == 0 and (code & 0xf) != 0) break;
            off += n;
        } else {
            const n: usize = @intCast(@as(u32, @bitCast(status)) >> 4);
            if (n == 0) break;
            off += n;
        }
    }
    stream.dropWritable();
}

fn writeTrailers(writable: i32) void {
    const status = trailers_future.write(writable, @intCast(@intFromPtr(&trailers_ok_none)));
    if (status == STREAM_BLOCKED) {
        const set = cm.WaitableSet.create();
        set.add(writable);
        _ = set.waitOne();
        set.drop();
    }
    trailers_future.@"drop-writable"(writable);
}

fn sendResponse(res: *const Responder) void {
    const headers = @"[constructor]fields"();
    const ct = "content-type";
    _ = @"[method]fields.append"(
        headers,
        @intCast(@intFromPtr(ct.ptr)),
        @intCast(ct.len),
        @intCast(@intFromPtr(res.content_type.ptr)),
        @intCast(res.content_type.len),
        abi.retPtr(),
    );

    const payload = res.body();
    var contents_disc: i32 = 0;
    var contents_stream: i32 = 0;
    var body_writable: i32 = 0;
    const has_body = payload.len != 0;
    if (has_body) {
        const stream = cm.ByteStream.new();
        contents_disc = 1;
        contents_stream = stream.readable;
        body_writable = stream.writable;
    }

    const tf = cm.unpack(trailers_future.new());

    @"[static]response.new"(headers, contents_disc, contents_stream, tf.readable, abi.retPtr());
    const w = abi.retWords();
    const response: i32 = @bitCast(w[0]);
    const transmission: i32 = @bitCast(w[1]);
    txn_future.@"drop-readable"(transmission);

    if (res.status != 200) _ = @"[method]response.set-status-code"(response, @intCast(res.status));

    handle_task.@"task-return"(0, response, 0, 0, 0, 0, 0, 0);

    if (has_body) writeBody(body_writable, payload);
    writeTrailers(tf.writable);
}

// ── Export wiring ───────────────────────────────────────────────────

/// Per-task stack buffer sizes (request path, request body, response body).
pub const path_capacity = 1024;
pub const request_body_capacity = 8192;
pub const body_capacity = 8192;

/// Emit the async `wasi:http/handler@0.3.0#handle` export, dispatching each
/// request to `handler`.
pub fn exportHandler(comptime handler: fn (req: *const Request, res: *Responder) void) void {
    const Wrapper = struct {
        fn handle(request: i32) callconv(.c) void {
            abi.resetScratch();
            var path_buf: [path_capacity]u8 = undefined;
            var body_buf: [request_body_capacity]u8 = undefined;
            var resp_buf: [body_capacity]u8 = undefined;

            const method = readMethod(request);
            const path = readPathWithQuery(request, &path_buf);
            // consume-body moves the request, so read method + path first.
            const reqbody = readBody(request, &body_buf);

            const req = Request{ .method = method, .path = path, .body = reqbody };
            var res = Responder{ .buf = &resp_buf };
            handler(&req, &res);
            sendResponse(&res);
        }
    };
    @export(&Wrapper.handle, .{ .name = "wasi:http/handler@0.3.0#handle" });
}
