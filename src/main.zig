//! PetStore — a `wasi:http@0.3.0` service (TypeSpec petstore sample) driven
//! entirely by the `wabt component bindgen`-generated `svc` bindings: the
//! `wasi:http/types` client wrappers, the `store` data-access client, and the
//! async `handle` export (manual-return streaming form). No hand-written
//! `wasi_http`.

const std = @import("std");
const svc = @import("svc");
const cm = @import("cm_async");
const canon = @import("canon");
const abi = @import("abi");

// Force the generated export shells (`wasi:http/handler@0.3.0#handle`) to emit:
// they live in this dependency module while `main` is the compilation root.
comptime {
    _ = svc;
}

const store = svc.store;
const Pet = svc.Pet;

// ── wasi:http protocol (over the generated bindings) ────────────────

const TxnFut = @typeInfo(@TypeOf(svc.Request.consumeBody)).@"fn".params[1].type.?;
const TrailersFut = @typeInfo(@TypeOf(svc.Response.new)).@"fn".params[2].type.?;
const ByteStream = canon.Stream(u8);

/// Canonical `stream`/`future` status: blocked (operation pending).
const BLOCKED: i32 = @bitCast(@as(u32, 0xffff_ffff));

// `ok(())` / `ok(none)` of the transmission / trailers futures are all-zero.
var ok_zero: [64]u8 align(8) = [_]u8{0} ** 64;

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

fn readBody(request: svc.Request, buf: []u8) []const u8 {
    const res = TxnFut.new();
    const tup = svc.Request.consumeBody(request, res.readable);
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

/// What a route fills: status, content-type, and a body in a caller buffer.
const Responder = struct {
    status: u16 = 200,
    content_type: []const u8 = "application/json",
    buf: []u8,
    len: usize = 0,

    fn setStatus(self: *Responder, status: u16) void {
        self.status = status;
    }
    fn print(self: *Responder, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch self.buf[self.len..self.len];
        self.len += out.len;
    }
    fn body(self: *const Responder) []const u8 {
        return self.buf[0..self.len];
    }
};

fn sendResponse(res: *const Responder) void {
    const headers = svc.Fields.init();
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
    const tup = svc.Response.new(headers, contents, tf.readable);
    const response: svc.Response = tup[0];
    const transmission: TxnFut = tup[1];
    transmission.dropReadable();

    if (res.status != 200) _ = response.setStatusCode(res.status);

    svc.handleReturn(.{ .ok = response });

    if (has_body) writeBody(body_writable, payload);
    writeTrailers(tf.writable);
}

// ── PetStore routes (TypeSpec petstore sample) ──────────────────────

const json_opts = std.json.Stringify.Options{ .emit_null_optional_fields = false };

const PetJson = struct {
    id: i32,
    name: []const u8,
    tag: ?[]const u8 = null,
    age: i32,
};

const ToyJson = struct {
    id: i64,
    petId: i64,
    name: []const u8,
};

const ErrorJson = struct {
    code: i32,
    message: []const u8,
};

const PetInput = struct {
    name: []const u8,
    tag: ?[]const u8 = null,
    age: i32,
};

fn petJson(p: Pet) PetJson {
    return .{ .id = @intCast(p.id), .name = p.name, .tag = p.tag, .age = @intCast(p.age) };
}

fn writeJson(res: *Responder, value: anytype) void {
    res.print("{f}", .{std.json.fmt(value, json_opts)});
}

fn writeError(res: *Responder, status: u16, code: i32, message: []const u8) void {
    res.setStatus(status);
    writeJson(res, ErrorJson{ .code = code, .message = message });
}

fn listPets(res: *Responder) void {
    var items: [128]PetJson = undefined;
    var n: usize = 0;
    const count = store.petCount();
    var i: u32 = 0;
    while (i < count and n < items.len) : (i += 1) {
        if (store.petAt(i)) |p| {
            items[n] = petJson(p);
            n += 1;
        }
    }
    writeJson(res, .{ .items = items[0..n] });
}

fn readPet(id: u32, res: *Responder) void {
    if (store.getPet(id)) |p| {
        writeJson(res, petJson(p));
    } else {
        writeError(res, 404, 404, "pet not found");
    }
}

fn deletePet(id: u32, res: *Responder) void {
    if (store.deletePet(id)) {
        writeJson(res, .{ .message = "deleted" });
    } else {
        writeError(res, 404, 404, "pet not found");
    }
}

fn listToys(pet_id: u32, res: *Responder) void {
    var items: [128]ToyJson = undefined;
    var n: usize = 0;
    const count = store.toyCount(pet_id);
    var i: u32 = 0;
    while (i < count and n < items.len) : (i += 1) {
        if (store.toyAt(pet_id, i)) |t| {
            items[n] = .{ .id = @intCast(t.id), .petId = @intCast(t.pet_id), .name = t.name };
            n += 1;
        }
    }
    writeJson(res, .{ .items = items[0..n] });
}

fn createPet(body: []const u8, res: *Responder) void {
    if (body.len == 0) return writeError(res, 400, 400, "request body required");
    var jbuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&jbuf);
    const parsed = std.json.parseFromSliceLeaky(PetInput, fba.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return writeError(res, 400, 400, "invalid pet json");
    if (parsed.age < 0 or parsed.age > 20) return writeError(res, 400, 400, "age must be 0..20");
    const p = store.createPet(parsed.name, parsed.tag, @intCast(parsed.age)) orelse
        return writeError(res, 507, 507, "store full");
    writeJson(res, petJson(p));
}

const Method = enum { get, post, put, delete, other };

fn methodOf(m: svc.Method) Method {
    return switch (m) {
        .get => .get,
        .post => .post,
        .put => .put,
        .delete => .delete,
        else => .other,
    };
}

fn route(method: Method, full_path: []const u8, body: []const u8, res: *Responder) void {
    const q = std.mem.indexOfScalar(u8, full_path, '?');
    const path = if (q) |i| full_path[0..i] else full_path;

    if (std.mem.eql(u8, path, "/pets")) {
        switch (method) {
            .get => listPets(res),
            .post => createPet(body, res),
            else => writeError(res, 405, 405, "method not allowed"),
        }
        return;
    }

    if (std.mem.startsWith(u8, path, "/pets/")) {
        const rest = path["/pets/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const id_str = rest[0..slash];
            const tail = rest[slash + 1 ..];
            if (std.mem.eql(u8, tail, "toys") and method == .get) {
                const pid = std.fmt.parseInt(u32, id_str, 10) catch return writeError(res, 400, 400, "invalid pet id");
                listToys(pid, res);
                return;
            }
            writeError(res, 404, 404, "not found");
            return;
        }
        const id = std.fmt.parseInt(u32, rest, 10) catch return writeError(res, 400, 400, "invalid pet id");
        switch (method) {
            .get => readPet(id, res),
            .delete => deletePet(id, res),
            else => writeError(res, 405, 405, "method not allowed"),
        }
        return;
    }

    writeError(res, 404, 404, "not found");
}

/// The `wasi:http/handler@0.3.0#handle` entry (manual-return form). Decode the
/// request, run the route, then deliver + stream the response.
pub fn handle(request: svc.Request) void {
    var path_buf: [1024]u8 = undefined;
    var body_buf: [8192]u8 = undefined;
    var resp_buf: [8192]u8 = undefined;

    const method = methodOf(request.getMethod());
    const raw_path = request.getPathWithQuery() orelse "";
    const pn = @min(raw_path.len, path_buf.len);
    @memcpy(path_buf[0..pn], raw_path[0..pn]);
    const path = path_buf[0..pn];
    // consume-body moves the request, so read method + path first.
    const body = readBody(request, &body_buf);

    var res = Responder{ .buf = &resp_buf };
    route(method, path, body, &res);
    sendResponse(&res);
}
