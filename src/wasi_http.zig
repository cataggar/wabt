//! `wasi_http` — guest-side helper for a `wasi:http/service@0.3.0` component
//! in pure Zig (WASI 0.3 / Component-Model async).
//!
//! A service exports `wasi:http/handler@0.3.0#handle`, an **async**
//! `func(request) -> result<response, error-code>`. To answer, the guest
//! builds a `response` via `wasi:http/types@0.3.0`'s `response.new`, which
//! takes the body as an `option<stream<u8>>` and a `trailers` future
//! (`future<result<option<trailers>, error-code>>`). There is no `wasi:io`:
//! the body `stream<u8>` is a `cm_async` primitive and the trailers future is
//! a canonical-ABI `future` whose intrinsics are named by the wabt
//! function-reference contract (`[future]<iface>#<fn>#<async-idx>`).
//!
//! ## Usage
//!
//! ```zig
//! const http = @import("wasi_http");
//! comptime { http.exportHandler("Hello, WASI!"); }
//! ```
//!
//! The handler reports the response via `task.return` and then streams the
//! body, mirroring `wasmtime`'s `p3_cli_serve_hello_world` reference.

const abi = @import("abi");
const cm = @import("cm_async");

// ── Host imports: wasi:http/types@0.3.0 resource canons ─────────────

/// `[constructor]fields() -> own<fields>` — a fresh, mutable, empty headers.
extern "wasi:http/types@0.3.0" fn @"[constructor]fields"() i32;

/// `response.new(headers, contents: option<stream<u8>>, trailers:
/// future<result<option<trailers>, error-code>>) -> tuple<response,
/// future<result<_, error-code>>>`. `option<stream<u8>>` lowers to
/// `(disc, stream-handle)`; the spilled tuple result is written to `retptr`
/// as `[response-handle, transmission-future-handle]`.
extern "wasi:http/types@0.3.0" fn @"[static]response.new"(
    headers: i32,
    contents_disc: i32,
    contents_stream: i32,
    trailers: i32,
    retptr: i32,
) void;

/// `[resource-drop]request` — consume the incoming request handle.
extern "wasi:http/types@0.3.0" fn @"[resource-drop]request"(req: i32) void;

// The trailers `future<result<option<trailers>, error-code>>` — named after
// `request.new`'s async type #1 (response.new reuses the same type). `write`
// lowers to `(future, ptr) -> status` (a future carries one value, no count).
const trailers_future = struct {
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn new() i64;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn write(f: i32, ptr: i32) i32;
    extern "[future]wasi:http/types@0.3.0#[static]request.new#1" fn @"drop-writable"(f: i32) void;
};

// The transmission `future<result<_, error-code>>` returned by `response.new`
// (request.new async type #2). We don't await it — just drop the readable end.
const txn_future = struct {
    extern "[future]wasi:http/types@0.3.0#[static]request.new#2" fn @"drop-readable"(f: i32) void;
};

/// `task.return` for `handler.handle`'s `result<response, error-code>`. The
/// result flattens to 8 core values: `[disc, join(response, error-code)…]`.
/// `ok(response)` is `(0, response, 0, 0, 0, 0, 0, 0)`.
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

// `ok(none)` of `result<option<trailers>, error-code>` lowers to all-zero
// bytes (result disc 0 at offset 0, option disc 0 at the payload offset). A
// zeroed buffer at least as large as the element's memory layout suffices; 64
// bytes is ample headroom for the host to read.
var trailers_ok_none: [64]u8 align(8) = [_]u8{0} ** 64;

/// Canonical `stream.write` status: blocked (operation pending).
const STREAM_BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

/// Write all of `bytes` to the writable end of a `stream<u8>`, cooperatively
/// waiting when a write blocks. After `task.return` the host holds the
/// response and reads the body concurrently; a synchronous `stream.write` to a
/// not-yet-read stream returns `BLOCKED`, so we join the stream to a
/// `waitable-set` and `wait` (yielding to the host) until the write makes
/// progress, then continue with any remainder.
fn writeBody(writable: i32, bytes: []const u8) void {
    const stream = cm.ByteStream{ .handle = writable };
    var off: usize = 0;
    while (off < bytes.len) {
        const status = stream.write(bytes[off..]);
        if (status == STREAM_BLOCKED) {
            const set = cm.WaitableSet.create();
            set.add(writable);
            _ = set.waitOne();
            // The wait wrote `[event-code, waitable, code]` to the ret-area;
            // `code = (count << 4) | result` for a stream-write completion.
            const code: u32 = abi.retWords()[2];
            set.drop();
            const n: usize = @intCast(code >> 4);
            if (n == 0 and (code & 0xf) != 0) break; // dropped / cancelled
            off += n;
        } else {
            const n: usize = @intCast(@as(u32, @bitCast(status)) >> 4);
            if (n == 0) break; // closed
            off += n;
        }
    }
    stream.dropWritable();
}

/// Resolve a trailers `future` to `ok(none)` after `task.return` (the host
/// only holds the readable end then), cooperatively waiting if the write
/// blocks, then close the writable end.
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

/// Build a `200` response whose body is `body`, report it via `task.return`,
/// then stream the body and resolve the trailers. An empty `body` sends a
/// zero-length body (contents = none) and skips the body stream.
///
/// Crucial ordering: the body stream and trailers future are only **read** by
/// the host after `task.return` hands it the response (which carries their
/// readable ends). Writing/closing them beforehand blocks with no reader and
/// would cancel them — so all writes happen after `task.return`, cooperatively
/// (body first, then — once the body is closed — the trailers).
fn respond(body: []const u8) void {
    const headers = @"[constructor]fields"();

    var contents_disc: i32 = 0; // none
    var contents_stream: i32 = 0;
    var body_writable: i32 = 0;
    const has_body = body.len != 0;
    if (has_body) {
        const stream = cm.ByteStream.new();
        contents_disc = 1; // some
        contents_stream = stream.readable;
        body_writable = stream.writable;
    }

    // Create the trailers future; its value is written after task.return.
    const tf = cm.unpack(trailers_future.new());

    // response.new(headers, contents, trailers-readable).
    @"[static]response.new"(headers, contents_disc, contents_stream, tf.readable, abi.retPtr());
    const w = abi.retWords();
    const response: i32 = @bitCast(w[0]);
    const transmission: i32 = @bitCast(w[1]);
    txn_future.@"drop-readable"(transmission);

    // Report the response (ok(response)); the host now holds the readable ends.
    handle_task.@"task-return"(0, response, 0, 0, 0, 0, 0, 0);

    // Stream the body and close it, then resolve trailers to ok(none).
    if (has_body) writeBody(body_writable, body);
    writeTrailers(tf.writable);
}

/// Emit the async `wasi:http/handler@0.3.0#handle` export. It drops the
/// incoming request and answers with a `200` carrying `body`.
pub fn exportHandler(comptime body: []const u8) void {
    const Wrapper = struct {
        fn handle(request: i32) callconv(.c) void {
            @"[resource-drop]request"(request);
            respond(body);
        }
    };
    @export(&Wrapper.handle, .{ .name = "wasi:http/handler@0.3.0#handle" });
}
