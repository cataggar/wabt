//! Storage backend for the petstore — a standalone component that exports
//! `example:petstore/store@…`. It owns the in-memory pets/toys (seeded with
//! examples) and answers the data-access calls the HTTP frontend imports.
//! `wabt component compose` links this provider into the frontend.
//!
//! ## Canonical ABI (export / "lift" side)
//!
//! Each export receives its params already flattened to core `i32`s (strings
//! as `(ptr, len)`, `option<string>` as `(disc, ptr, len)`). A result wider
//! than one core value (`option<pet>` / `option<toy>`) is returned through a
//! pointer: the function writes the record in canonical memory layout into a
//! static return area and returns its address. Record strings point straight
//! at the persistent store buffers — the host lifts them synchronously before
//! any later mutation, so no per-call copy is needed.
//!
//! The store is static global state mutated by synchronous, await-free calls;
//! the host serializes these imports, so a single static return area is safe.

const std = @import("std");
const abi = @import("abi");

// `cabi_realloc` (exported by `abi`) is how the host lowers our string
// params into this component's memory. Keep the module alive so the export
// is linked even though we never call it directly.
comptime {
    _ = abi;
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
};

const StoredToy = struct {
    used: bool = false,
    id: i32 = 0,
    pet_id: i32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
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

// ── Canonical-ABI result encoding ───────────────────────────────────
//
// Memory layout of `option<pet>` / `option<toy>` (all fields 4-byte
// aligned); `extern struct` reproduces it exactly so we can return a
// pointer to it as the function's indirect result.

const RetPet = extern struct {
    disc: u8, // option discriminant: 0 = none, 1 = some
    id: u32,
    name_ptr: u32,
    name_len: u32,
    tag_disc: u8, // option<string> discriminant
    tag_ptr: u32,
    tag_len: u32,
    age: u32,
};

const RetToy = extern struct {
    disc: u8,
    id: u32,
    pet_id: u32,
    name_ptr: u32,
    name_len: u32,
};

var ret_pet: RetPet = undefined;
var ret_toy: RetToy = undefined;

fn ptrTo(p: *const anyopaque) u32 {
    return @intCast(@intFromPtr(p));
}

fn writePet(p: *const StoredPet) i32 {
    ret_pet = .{
        .disc = 1,
        .id = @intCast(p.id),
        .name_ptr = ptrTo(&p.name_buf),
        .name_len = p.name_len,
        .tag_disc = if (p.has_tag) 1 else 0,
        .tag_ptr = if (p.has_tag) ptrTo(&p.tag_buf) else 0,
        .tag_len = if (p.has_tag) p.tag_len else 0,
        .age = @intCast(p.age),
    };
    return @intCast(@intFromPtr(&ret_pet));
}

fn writeNoPet() i32 {
    ret_pet.disc = 0;
    return @intCast(@intFromPtr(&ret_pet));
}

fn writeToy(t: *const StoredToy) i32 {
    ret_toy = .{
        .disc = 1,
        .id = @intCast(t.id),
        .pet_id = @intCast(t.pet_id),
        .name_ptr = ptrTo(&t.name_buf),
        .name_len = t.name_len,
    };
    return @intCast(@intFromPtr(&ret_toy));
}

fn writeNoToy() i32 {
    ret_toy.disc = 0;
    return @intCast(@intFromPtr(&ret_toy));
}

fn slice(ptr: i32, len: i32) []const u8 {
    const p: [*]const u8 = @ptrFromInt(@as(usize, @intCast(ptr)));
    return p[0..@intCast(len)];
}

// ── Exports: example:petstore/store ─────────────────────────────────

export fn @"example:petstore/store#pet-count"() i32 {
    ensureSeeded();
    var n: u32 = 0;
    for (&pets) |*p| {
        if (p.used) n += 1;
    }
    return @bitCast(n);
}

export fn @"example:petstore/store#pet-at"(index: i32) i32 {
    ensureSeeded();
    const idx: u32 = @bitCast(index);
    var n: u32 = 0;
    for (&pets) |*p| {
        if (!p.used) continue;
        if (n == idx) return writePet(p);
        n += 1;
    }
    return writeNoPet();
}

export fn @"example:petstore/store#get-pet"(id: i32) i32 {
    ensureSeeded();
    if (findPet(id)) |p| return writePet(p);
    return writeNoPet();
}

export fn @"example:petstore/store#create-pet"(
    name_ptr: i32,
    name_len: i32,
    tag_disc: i32,
    tag_ptr: i32,
    tag_len: i32,
    age: i32,
) i32 {
    ensureSeeded();
    const name = slice(name_ptr, name_len);
    const tag: ?[]const u8 = if (tag_disc == 1) slice(tag_ptr, tag_len) else null;
    if (addPet(name, tag, age)) |p| return writePet(p);
    return writeNoPet();
}

export fn @"example:petstore/store#delete-pet"(id: i32) i32 {
    ensureSeeded();
    if (findPet(id)) |p| {
        p.used = false;
        return 1;
    }
    return 0;
}

export fn @"example:petstore/store#toy-count"(pet_id: i32) i32 {
    ensureSeeded();
    var n: u32 = 0;
    for (&toys) |*t| {
        if (t.used and t.pet_id == pet_id) n += 1;
    }
    return @bitCast(n);
}

export fn @"example:petstore/store#toy-at"(pet_id: i32, index: i32) i32 {
    ensureSeeded();
    const idx: u32 = @bitCast(index);
    var n: u32 = 0;
    for (&toys) |*t| {
        if (!t.used or t.pet_id != pet_id) continue;
        if (n == idx) return writeToy(t);
        n += 1;
    }
    return writeNoToy();
}
