//! PetStore — a `wasi:http@0.3.0` service implementing the TypeSpec petstore
//! sample (microsoft/typespec petstore.tsp) over an in-memory store seeded
//! with example pets and toys.
//!
//! Routes:
//!   GET    /pets                 -> { items: Pet[] }
//!   POST   /pets                 -> created Pet            (body: Pet JSON)
//!   GET    /pets/{id}            -> Pet | 404 Error
//!   DELETE /pets/{id}            -> 200 | 404 Error
//!   GET    /pets/{id}/toys       -> { items: Toy[] }
//!
//! Concurrency: the store is static global state mutated only by synchronous,
//! await-free operations, so cooperatively-interleaved request tasks never
//! observe a torn read/write. Per-request data lives in `wasi_http`'s per-task
//! stack buffers.

const std = @import("std");
const http = @import("wasi_http");

// ── In-memory store ─────────────────────────────────────────────────

const StoredPet = struct {
    used: bool = false,
    id: i32 = 0,
    age: i32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    has_tag: bool = false,
    tag_buf: [64]u8 = undefined,
    tag_len: u8 = 0,

    fn name(self: *const StoredPet) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn tag(self: *const StoredPet) ?[]const u8 {
        return if (self.has_tag) self.tag_buf[0..self.tag_len] else null;
    }
};

const StoredToy = struct {
    used: bool = false,
    id: i64 = 0,
    pet_id: i64 = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,

    fn name(self: *const StoredToy) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

var pets = [_]StoredPet{.{}} ** 128;
var toys = [_]StoredToy{.{}} ** 128;
var next_id: i32 = 1;
var seeded: bool = false;

fn setField(buf: []u8, len: *u8, value: []const u8) void {
    const n: u8 = @intCast(@min(value.len, buf.len));
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

fn addPet(name: []const u8, tag: ?[]const u8, age: i32) ?*StoredPet {
    for (&pets) |*p| {
        if (p.used) continue;
        p.* = .{ .used = true, .id = next_id, .age = age };
        next_id += 1;
        setField(&p.name_buf, &p.name_len, name);
        if (tag) |t| {
            p.has_tag = true;
            setField(&p.tag_buf, &p.tag_len, t);
        }
        return p;
    }
    return null;
}

fn addToy(pet_id: i64, id: i64, name: []const u8) void {
    for (&toys) |*t| {
        if (t.used) continue;
        t.* = .{ .used = true, .id = id, .pet_id = pet_id };
        setField(&t.name_buf, &t.name_len, name);
        return;
    }
}

fn findPet(id: i32) ?*StoredPet {
    for (&pets) |*p| {
        if (p.used and p.id == id) return p;
    }
    return null;
}

fn ensureSeeded() void {
    if (seeded) return;
    seeded = true;
    const p1 = addPet("Fluffy", "cat", 3);
    _ = addPet("Rex", "dog", 5);
    _ = addPet("Bubbles", null, 1);
    if (p1) |p| {
        addToy(p.id, 100, "Yarn Ball");
        addToy(p.id, 101, "Feather Wand");
    }
}

// ── JSON helpers ────────────────────────────────────────────────────

fn writeJsonString(res: *http.Responder, s: []const u8) void {
    res.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => res.writeAll("\\\""),
        '\\' => res.writeAll("\\\\"),
        '\n' => res.writeAll("\\n"),
        '\r' => res.writeAll("\\r"),
        '\t' => res.writeAll("\\t"),
        else => res.writeAll(&[_]u8{c}),
    };
    res.writeAll("\"");
}

fn writePet(res: *http.Responder, p: *const StoredPet) void {
    res.print("{{\"id\":{d},\"name\":", .{p.id});
    writeJsonString(res, p.name());
    if (p.tag()) |t| {
        res.writeAll(",\"tag\":");
        writeJsonString(res, t);
    }
    res.print(",\"age\":{d}}}", .{p.age});
}

fn writeToy(res: *http.Responder, t: *const StoredToy) void {
    res.print("{{\"id\":{d},\"petId\":{d},\"name\":", .{ t.id, t.pet_id });
    writeJsonString(res, t.name());
    res.writeAll("}");
}

fn writeError(res: *http.Responder, status: u16, code: i32, message: []const u8) void {
    res.setStatus(status);
    res.print("{{\"code\":{d},\"message\":", .{code});
    writeJsonString(res, message);
    res.writeAll("}");
}

// ── Handlers ────────────────────────────────────────────────────────

fn listPets(res: *http.Responder) void {
    res.writeAll("{\"items\":[");
    var first = true;
    for (&pets) |*p| {
        if (!p.used) continue;
        if (!first) res.writeAll(",");
        first = false;
        writePet(res, p);
    }
    res.writeAll("]}");
}

fn readPet(id: i32, res: *http.Responder) void {
    if (findPet(id)) |p| {
        writePet(res, p);
    } else {
        writeError(res, 404, 404, "pet not found");
    }
}

fn deletePet(id: i32, res: *http.Responder) void {
    if (findPet(id)) |p| {
        p.used = false;
        res.setStatus(200);
        res.writeAll("{\"message\":\"deleted\"}");
    } else {
        writeError(res, 404, 404, "pet not found");
    }
}

fn listToys(pet_id: i64, res: *http.Responder) void {
    res.writeAll("{\"items\":[");
    var first = true;
    for (&toys) |*t| {
        if (!t.used or t.pet_id != pet_id) continue;
        if (!first) res.writeAll(",");
        first = false;
        writeToy(res, t);
    }
    res.writeAll("]}");
}

const PetInput = struct {
    name: []const u8,
    tag: ?[]const u8 = null,
    age: i32,
};

fn createPet(req: *const http.Request, res: *http.Responder) void {
    if (req.body.len == 0) return writeError(res, 400, 400, "request body required");
    var jbuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&jbuf);
    const parsed = std.json.parseFromSliceLeaky(PetInput, fba.allocator(), req.body, .{
        .ignore_unknown_fields = true,
    }) catch return writeError(res, 400, 400, "invalid pet json");
    if (parsed.age < 0 or parsed.age > 20) return writeError(res, 400, 400, "age must be 0..20");
    const p = addPet(parsed.name, parsed.tag, parsed.age) orelse
        return writeError(res, 507, 507, "store full");
    res.setStatus(200);
    writePet(res, p);
}

// ── Routing ─────────────────────────────────────────────────────────

fn handle(req: *const http.Request, res: *http.Responder) void {
    ensureSeeded();

    const q = std.mem.indexOfScalar(u8, req.path, '?');
    const path = if (q) |i| req.path[0..i] else req.path;

    if (std.mem.eql(u8, path, "/pets")) {
        switch (req.method) {
            .get => listPets(res),
            .post => createPet(req, res),
            else => writeError(res, 405, 405, "method not allowed"),
        }
        return;
    }

    if (std.mem.startsWith(u8, path, "/pets/")) {
        const rest = path["/pets/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const id_str = rest[0..slash];
            const tail = rest[slash + 1 ..];
            if (std.mem.eql(u8, tail, "toys") and req.method == .get) {
                const pid = std.fmt.parseInt(i64, id_str, 10) catch return writeError(res, 400, 400, "invalid pet id");
                listToys(pid, res);
                return;
            }
            writeError(res, 404, 404, "not found");
            return;
        }
        const id = std.fmt.parseInt(i32, rest, 10) catch return writeError(res, 400, 400, "invalid pet id");
        switch (req.method) {
            .get => readPet(id, res),
            .delete => deletePet(id, res),
            else => writeError(res, 405, 405, "method not allowed"),
        }
        return;
    }

    writeError(res, 404, 404, "not found");
}

comptime {
    http.exportHandler(handle);
}
