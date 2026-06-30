//! A demo `wasi:cli` command that walks every petstore endpoint in order.
//!
//! It makes outgoing requests through the imported `wasi:http/handler@0.3.0`
//! (the host's outgoing handler — provided by `wasmtime run -S http`) and
//! prints a transcript to stdout. The target authority (`host:port`) is taken
//! from the first non-`.wasm` program argument, then the `BASE_URL`
//! environment variable, then defaults to `localhost:8080` — so a
//! `zig build serve` in another terminal can be driven with
//! `zig build run-client` (optionally `-- 127.0.0.1:8080`).
//!
//! The `wasi:http/handler#handle` import is **async** (`func(request) ->
//! result<response, error-code>`). Unlike the generated inline-await wrapper,
//! this driver issues the call, then writes the request body while the call is
//! in flight, and only then awaits — so a request body larger than the stream's
//! initial window can't deadlock against a host that reads it before
//! responding. The body `stream<u8>` and trailers/transmission `future`
//! channels mirror the service side in `wasi_http.zig`, in reverse.

const std = @import("std");
const cli = @import("wasi_cli");
const http = @import("http_client");
const wit_types = @import("wit_types");
const cm = @import("wit_async");

const canon = wit_types;
const abi = wit_types;

const Request = http.Request;
const Response = http.Response;
const Fields = http.Fields;
const Method = http.Method;
const Scheme = http.Scheme;
const ErrorCode = http.ErrorCode;
const ByteStream = wit_types.Stream(u8);

// The private body/trailers/transmission `future` channel types, recovered by
// reflection on the generated client signatures (the same trick the service
// side uses): `request.new`'s `trailers` param is the trailers future, and
// `response.consume-body`'s `res` param is the transmission future.
const TrailersFut = @typeInfo(@TypeOf(Request.new)).@"fn".params[2].type.?;
const TxnFut = @typeInfo(@TypeOf(Response.consumeBody)).@"fn".params[1].type.?;

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

// `ok(())` / `ok(none)` of the trailers / transmission futures are all-zero.
var ok_zero: [64]u8 align(8) = [_]u8{0} ** 64;

// Dedicated result area for the async `handle` call. It must stay live from the
// call until `awaitCall` completes (the host writes the `result<response,
// error-code>` here), and must NOT be the shared ret-area — interim
// `waitable-set.wait`s during body streaming target the ret-area, and would
// otherwise clobber the pending response.
var handle_result: [64]u8 align(8) = undefined;

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
    const code: u32 = abi.retWords()[1];
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

const Reply = struct {
    status: u16,
    body: []const u8,
};

/// Issue one request to `authority` and return the response status + body
/// (read into `out`), or null on a transport-level `error-code`.
fn request(authority: []const u8, method: Method, path: []const u8, body: ?[]const u8, out: []u8) ?Reply {
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

    // Issue the async call (result lands in `handle_result`), then stream the
    // body while it's in flight, then await.
    const status = send(req.handle, @intCast(@intFromPtr(&handle_result)));
    if (body) |payload| writeBody(body_w, payload);
    signalOk(tf.writable);
    cm.awaitCall(status);

    const result = canon.lift(canon.Result(Response, ErrorCode), @ptrCast(&handle_result));
    switch (result) {
        .ok => |resp| {
            const sc = resp.getStatusCode();
            const rb = readBody(resp, out);
            return .{ .status = sc, .body = rb };
        },
        .err => return null,
    }
}

// ── transcript helpers ──────────────────────────────────────────────

fn emit(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    cli.print(s);
}

fn methodName(method: Method) []const u8 {
    return switch (method) {
        .get => "GET",
        .post => "POST",
        .delete => "DELETE",
        else => "?",
    };
}

var resp_buf: [64 * 1024]u8 = undefined;

fn step(authority: []const u8, method: Method, path: []const u8, body: ?[]const u8) void {
    emit("\n=== {s} {s} ===\n", .{ methodName(method), path });
    if (body) |b| emit("> {s}\n", .{b});
    if (request(authority, method, path, body, &resp_buf)) |reply| {
        emit("< {d}\n< {s}\n", .{ reply.status, reply.body });
    } else {
        emit("< request failed (transport error)\n", .{});
    }
}

// ── authority resolution ────────────────────────────────────────────

const default_authority = "localhost:8080";

fn stripScheme(s: []const u8) []const u8 {
    var v = s;
    if (std.mem.startsWith(u8, v, "http://")) v = v["http://".len..];
    if (std.mem.endsWith(u8, v, "/")) v = v[0 .. v.len - 1];
    return v;
}

fn resolveAuthority() []const u8 {
    // First a program argument that isn't the component path.
    for (cli.arguments()) |a| {
        if (std.mem.endsWith(u8, a, ".wasm")) continue;
        if (a.len == 0) continue;
        return stripScheme(a);
    }
    // Then the `BASE_URL` environment variable.
    for (cli.environment()) |kv| {
        if (std.mem.eql(u8, kv[0], "BASE_URL") and kv[1].len != 0) return stripScheme(kv[1]);
    }
    return default_authority;
}

fn run() u8 {
    const authority = resolveAuthority();
    emit("petstore demo client -> http://{s}\n", .{authority});

    // Walk every endpoint in order.
    step(authority, Method.get, "/pets", null); // initial list
    step(authority, Method.post, "/pets", "{\"name\":\"Whiskers\",\"tag\":\"cat\",\"age\":2}"); // create
    step(authority, Method.post, "/pets", "{\"name\":\"bad\"}"); // invalid -> 400
    step(authority, Method.get, "/pets/1", null); // read one
    step(authority, Method.get, "/pets/1/toys", null); // sub-resource
    step(authority, Method.delete, "/pets/2", null); // delete
    step(authority, Method.get, "/pets/2", null); // gone -> 404
    step(authority, Method.get, "/pets", null); // final list

    emit("\ndone\n", .{});
    return 0;
}

comptime {
    cli.exportRun(run);
}
