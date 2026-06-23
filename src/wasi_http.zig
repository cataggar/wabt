//! `wasi_http` — guest-side helper for a `wasi:http/handler@0.3.0` service
//! component in pure Zig (WASI 0.3 / Component-Model async).
//!
//! The `wasi:http/types` client surface (the `request` / `response` / `fields`
//! resources and the body `stream<u8>` + trailers `future` channels) is
//! **generated** by `wabt component bindgen` (see `wasi_http_bindings.zig`);
//! this module is the thin ergonomic layer over it. A service exports
//! `wasi:http/handler@0.3.0#handle`, an **async**
//! `func(request) -> result<response, error-code>`: this module reads the
//! request (method, path-with-query, body), invokes a user `handler` that fills
//! a `Responder` (status, content-type, body), then builds the `response` and
//! streams it back — `task.return`-ing the response (which carries the body
//! stream's readable end) *before* writing the writable end, as the protocol
//! requires.
//!
//! ## Concurrency
//!
//! Hosts (e.g. `wasmtime serve`) may invoke `handle` concurrently: multiple
//! request tasks can interleave at `await` points on one thread. To stay
//! correct, **all per-request data lives in per-task stack buffers** (request
//! path/body, response body), never in the shared `cabi_realloc` arena; the
//! arena is reset at the top of each `handle` and only used transiently for
//! canonical-ABI lifts copied to stack storage before any `await`. Application
//! state must be in static globals mutated with synchronous, await-free ops.
//!
//! ## Usage
//!
//! ```zig
//! const http = @import("wasi_http");
//! fn handle(req: *const http.Request, res: *http.Responder) void {
//!     res.setStatus(200);
//!     res.writeAll("hello");
//! }
//! comptime { http.handler(handle); }
//! ```

const std = @import("std");
const b = @import("wasi_http_bindings");
const wit_types = @import("wit_types");
const wit_async = @import("wit_async");

const canon = wit_types;
const abi = wit_types.abi;
const cm = wit_async;

// The private body/trailers future channel types, recovered by reflection on
// the generated client signatures (the same trick the petstore example uses):
// `consume-body`'s `res` param and `response.new`'s `trailers` param.
const TxnFut = @typeInfo(@TypeOf(b.Request.consumeBody)).@"fn".params[1].type.?;
const TrailersFut = @typeInfo(@TypeOf(b.Response.new)).@"fn".params[2].type.?;
const ByteStream = wit_types.Stream(u8);

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

// `ok(())` / `ok(none)` of the transmission / trailers futures are all-zero.
var ok_zero: [64]u8 align(8) = [_]u8{0} ** 64;

/// HTTP method (the standard cases of `wasi:http`'s `method` variant; `other`
/// covers any extension method).
pub const Method = enum(u8) {
    get,
    head,
    post,
    put,
    delete,
    connect,
    options,
    trace,
    patch,
    other,
};

fn mapMethod(m: b.Method) Method {
    return switch (m) {
        .get => .get,
        .head => .head,
        .post => .post,
        .put => .put,
        .delete => .delete,
        .connect => .connect,
        .options => .options,
        .trace => .trace,
        .patch => .patch,
        .other => .other,
    };
}

/// A decoded incoming request. `path` is the full path-with-query
/// (e.g. `/pets/3?x=1`); `body` is the request body (empty unless read). Both
/// borrow per-task stack buffers valid for the `handler` call.
pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
};

/// What the handler fills: a status, a content-type, and a body written into a
/// caller-provided per-task buffer.
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

/// Default JSON stringification options (omit null optional fields).
pub const json_opts = std.json.Stringify.Options{ .emit_null_optional_fields = false };

/// Stringify a value as JSON and append to the response buffer.
pub fn writeJson(res: *Responder, value: anytype) void {
    res.print("{f}", .{std.json.fmt(value, json_opts)});
}

// ── async helpers (drive the generated stream/future channels) ──────

/// Block on `waitable` until it makes progress; returns the event payload
/// (`waitable-set.wait` writes `[waitable, payload]` to the ret-area).
fn waitCode(waitable: i32) u32 {
    const set = cm.WaitableSet.create();
    set.add(waitable);
    _ = set.waitOne();
    const code: u32 = abi.retWords()[1];
    set.drop();
    return code;
}

/// Consume the request and read its body into `buf`, cooperatively waiting on
/// blocked reads. Drops the trailers future and signals `ok(())` on the
/// error-signal future (we never report a request-handling error).
fn readBody(request: b.Request, buf: []u8) []const u8 {
    const res = TxnFut.new();
    const tup = b.Request.consumeBody(request, res.readable);
    const stream: ByteStream = tup[0];
    const trailers: TrailersFut = tup[1];

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
    _ = res.writable.writeFrom(&ok_zero);
    res.writable.dropWritable();
    return buf[0..len];
}

fn writeBody(writable: ByteStream, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const status = writable.write(bytes[off..]);
        const code: u32 = if (status == BLOCKED) waitCode(writable.handle) else @bitCast(status);
        const n: usize = code >> 4;
        if (n == 0) break;
        off += n;
    }
    writable.dropWritable();
}

fn writeTrailers(writable: TrailersFut) void {
    const status = writable.writeFrom(&ok_zero);
    if (status == BLOCKED) _ = waitCode(writable.handle);
    writable.dropWritable();
}

// `[task-return]wasi:http/handler@0.3.0#handle` — the async lift's return path
// for `result<response, error-code>`. The result flattens to a discriminant + a
// response handle joined against the (wider) `error-code` payload (8 slots); an
// `ok(response)` is `(0, response, 0, 0, 0, 0, 0, 0)`.
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

fn sendResponse(res: *const Responder) void {
    const headers = b.Fields.init();
    _ = headers.append("content-type", res.content_type);

    const payload = res.body();
    const has_body = payload.len != 0;
    var body_writable: ByteStream = undefined;
    var contents: ?ByteStream = null;
    if (has_body) {
        const bs = ByteStream.new();
        contents = bs.readable;
        body_writable = bs.writable;
    }

    const tf = TrailersFut.new();
    const tup = b.Response.new(headers, contents, tf.readable);
    const response: b.Response = tup[0];
    const transmission: TxnFut = tup[1];
    transmission.dropReadable();

    if (res.status != 200) _ = response.setStatusCode(res.status);

    // task.return the response (carrying the body stream's readable end) BEFORE
    // writing the writable end — otherwise the write blocks with no reader.
    handle_task.@"task-return"(0, response.handle, 0, 0, 0, 0, 0, 0);

    if (has_body) writeBody(body_writable, payload);
    writeTrailers(tf.writable);
}

/// Per-task stack buffer sizes (request path, request body, response body),
/// sized to align with wasmtime/hyper defaults: an 8 KiB request line/URI and
/// 64 KiB body chunks (the wasi-http stream transfer size).
pub const path_capacity = 8 * 1024;
pub const request_body_capacity = 64 * 1024;
pub const body_capacity = 64 * 1024;

/// Emit the async `wasi:http/handler@0.3.0#handle` export, dispatching each
/// request to `impl`.
pub fn handler(comptime impl: fn (req: *const Request, res: *Responder) void) void {
    const Wrapper = struct {
        fn handle(request: i32) callconv(.c) void {
            abi.resetScratch();
            var path_buf: [path_capacity]u8 = undefined;
            var body_buf: [request_body_capacity]u8 = undefined;
            var resp_buf: [body_capacity]u8 = undefined;

            const req_handle = b.Request{ .handle = request };
            const method = mapMethod(req_handle.getMethod());
            const path = blk: {
                const p = req_handle.getPathWithQuery() orelse break :blk path_buf[0..0];
                const n = @min(p.len, path_buf.len);
                @memcpy(path_buf[0..n], p[0..n]);
                break :blk path_buf[0..n];
            };
            // consume-body moves the request, so read method + path first.
            const reqbody = readBody(req_handle, &body_buf);

            const req = Request{ .method = method, .path = path, .body = reqbody };
            var res = Responder{ .buf = &resp_buf };
            impl(&req, &res);
            sendResponse(&res);
        }
    };
    @export(&Wrapper.handle, .{ .name = "wasi:http/handler@0.3.0#handle" });
}
