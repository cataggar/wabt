const std = @import("std");
const http = @import("wasi_http");
const web = @import("web");

const store = web.store;
const Pet = web.Pet;

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

fn writeError(res: *http.Responder, status: u16, code: i32, message: []const u8) void {
    res.setStatus(status);
    http.writeJson(res, ErrorJson{ .code = code, .message = message });
}

fn listPets(res: *http.Responder) void {
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
    http.writeJson(res, .{ .items = items[0..n] });
}

fn readPet(id: u32, res: *http.Responder) void {
    if (store.getPet(id)) |p| {
        http.writeJson(res, petJson(p));
    } else {
        writeError(res, 404, 404, "pet not found");
    }
}

fn deletePet(id: u32, res: *http.Responder) void {
    if (store.deletePet(id)) {
        http.writeJson(res, .{ .message = "deleted" });
    } else {
        writeError(res, 404, 404, "pet not found");
    }
}

fn listToys(pet_id: u32, res: *http.Responder) void {
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
    http.writeJson(res, .{ .items = items[0..n] });
}

fn createPet(body: []const u8, res: *http.Responder) void {
    if (body.len == 0) return writeError(res, 400, 400, "request body required");
    var jbuf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&jbuf);
    const parsed = std.json.parseFromSliceLeaky(PetInput, fba.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return writeError(res, 400, 400, "invalid pet json");
    if (parsed.age < 0 or parsed.age > 20) return writeError(res, 400, 400, "age must be 0..20");
    const p = store.createPet(parsed.name, parsed.tag, @intCast(parsed.age)) orelse
        return writeError(res, 507, 507, "store full");
    http.writeJson(res, petJson(p));
}

fn route(method: http.Method, full_path: []const u8, body: []const u8, res: *http.Responder) void {
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

fn handler(req: *const http.Request, res: *http.Responder) void {
    route(req.method, req.path, req.body, res);
}

comptime {
    http.handler(handler);
}
