//! In-memory petstore implementation — the backend component's root module.
//!
//! `wabt component bindgen` generates the `store` bindings — the canonical-ABI
//! export shells for `example:petstore/store`. Those shells lift the params,
//! call the functions below (`Impl`, reached via `@import("root")`), and encode
//! the results, all via `canon`. The business logic here is pure: an in-memory
//! store seeded with examples, returning the `Pet` / `Toy` types the bindings
//! declare. The `comptime` reference below force-links the generated shells
//! (and `cabi_realloc`) into the component — there is no other root file.

const b = @import("store");
const Pet = b.Pet;
const Toy = b.Toy;

comptime {
    _ = b; // force-export the generated shells + cabi_realloc (-rdynamic)
}

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
    id: i32 = 0,
    pet_id: i32 = 0,
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

fn addToy(pet_id: i32, id: i32, name: []const u8) void {
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

fn petView(p: *const StoredPet) Pet {
    return .{ .id = @intCast(p.id), .name = p.name(), .tag = p.tag(), .age = @intCast(p.age) };
}

fn toyView(t: *const StoredToy) Toy {
    return .{ .id = @intCast(t.id), .pet_id = @intCast(t.pet_id), .name = t.name() };
}

// ── Impl: the functions the generated export shells call ────────────

pub fn petCount() u32 {
    ensureSeeded();
    var n: u32 = 0;
    for (&pets) |*p| {
        if (p.used) n += 1;
    }
    return n;
}

pub fn petAt(index: u32) ?Pet {
    ensureSeeded();
    var n: u32 = 0;
    for (&pets) |*p| {
        if (!p.used) continue;
        if (n == index) return petView(p);
        n += 1;
    }
    return null;
}

pub fn getPet(id: u32) ?Pet {
    ensureSeeded();
    if (findPet(@bitCast(id))) |p| return petView(p);
    return null;
}

pub fn createPet(name: []const u8, tag: ?[]const u8, age: u32) ?Pet {
    ensureSeeded();
    if (addPet(name, tag, @bitCast(age))) |p| return petView(p);
    return null;
}

pub fn deletePet(id: u32) bool {
    ensureSeeded();
    if (findPet(@bitCast(id))) |p| {
        p.used = false;
        return true;
    }
    return false;
}

pub fn toyCount(pet_id: u32) u32 {
    ensureSeeded();
    const pid: i32 = @bitCast(pet_id);
    var n: u32 = 0;
    for (&toys) |*t| {
        if (t.used and t.pet_id == pid) n += 1;
    }
    return n;
}

pub fn toyAt(pet_id: u32, index: u32) ?Toy {
    ensureSeeded();
    const pid: i32 = @bitCast(pet_id);
    var n: u32 = 0;
    for (&toys) |*t| {
        if (!t.used or t.pet_id != pid) continue;
        if (n == index) return toyView(t);
        n += 1;
    }
    return null;
}
