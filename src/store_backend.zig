//! Storage backend for the petstore — a standalone component that exports
//! `example:petstore/store@…`. It owns the in-memory pets/toys (seeded with
//! examples) and answers the data-access calls the HTTP frontend imports.
//! `wabt component compose` links this provider into the frontend.
//!
//! ## Canonical ABI (export side)
//!
//! Params arrive already flattened to core `i32`s (strings as `(ptr, len)`,
//! `option<string>` as `(disc, ptr, len)`). A result wider than one core value
//! (`option<pet>` / `option<toy>`) spills to memory: the comptime `canon`
//! marshaller computes the canonical layout from the plain Zig `Pet` / `Toy`
//! types — no hand-written `extern struct`s — and `canon.RetArea(T)` lowers the
//! value into a static area and returns its address. Result strings are copied
//! into the `abi` scratch arena (reset per call), which the host lifts
//! synchronously before the next call.
//!
//! The store is static global state mutated by synchronous, await-free calls;
//! the host serializes these imports, so a single static return area is safe.

const std = @import("std");
const abi = @import("abi");
const canon = @import("canon");

// `cabi_realloc` (exported by `abi`) is how the host lowers our string params
// into this component's memory, and how `canon` lowers result strings. Keep the
// module alive so the export is linked.
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

// ── Canonical-ABI result encoding ───────────────────────────────────
//
// Each export declares its core return type as `canon.CoreReturn(R)` and
// encodes the result with `canon.returnResult` — `canon` decides flat (a
// scalar) vs. indirect (a pointer to the `option<record>` it lowers into a
// static return area) from `R` at comptime.

const Pet = struct { id: u32, name: []const u8, tag: ?[]const u8, age: u32 };
const Toy = struct { id: u32, pet_id: u32, name: []const u8 };

fn petView(p: *const StoredPet) Pet {
    return .{ .id = @intCast(p.id), .name = p.name(), .tag = p.tag(), .age = @intCast(p.age) };
}

fn toyView(t: *const StoredToy) Toy {
    return .{ .id = @intCast(t.id), .pet_id = @intCast(t.pet_id), .name = t.name() };
}

// ── Exports: example:petstore/store ─────────────────────────────────
//
// Record-returning exports `abi.resetScratch()` first so the strings `canon`
// lowers for the result don't accumulate across calls.

export fn @"example:petstore/store#pet-count"() canon.CoreReturn(u32) {
    ensureSeeded();
    var n: u32 = 0;
    for (&pets) |*p| {
        if (p.used) n += 1;
    }
    return canon.returnResult(u32, n, &abi.alloc);
}

export fn @"example:petstore/store#pet-at"(index: i32) canon.CoreReturn(?Pet) {
    abi.resetScratch();
    ensureSeeded();
    const idx: u32 = @bitCast(index);
    var n: u32 = 0;
    for (&pets) |*p| {
        if (!p.used) continue;
        if (n == idx) return canon.returnResult(?Pet, petView(p), &abi.alloc);
        n += 1;
    }
    return canon.returnResult(?Pet, null, &abi.alloc);
}

export fn @"example:petstore/store#get-pet"(id: i32) canon.CoreReturn(?Pet) {
    abi.resetScratch();
    ensureSeeded();
    if (findPet(id)) |p| return canon.returnResult(?Pet, petView(p), &abi.alloc);
    return canon.returnResult(?Pet, null, &abi.alloc);
}

export fn @"example:petstore/store#create-pet"(
    name_ptr: i32,
    name_len: i32,
    tag_disc: i32,
    tag_ptr: i32,
    tag_len: i32,
    age: i32,
) canon.CoreReturn(?Pet) {
    abi.resetScratch();
    ensureSeeded();
    const a = canon.liftParams(struct {
        name: []const u8,
        tag: ?[]const u8,
        age: u32,
    }, .{ name_ptr, name_len, tag_disc, tag_ptr, tag_len, age });
    if (addPet(a.name, a.tag, @bitCast(a.age))) |p| return canon.returnResult(?Pet, petView(p), &abi.alloc);
    return canon.returnResult(?Pet, null, &abi.alloc);
}

export fn @"example:petstore/store#delete-pet"(id: i32) canon.CoreReturn(bool) {
    ensureSeeded();
    const existed = if (findPet(id)) |p| blk: {
        p.used = false;
        break :blk true;
    } else false;
    return canon.returnResult(bool, existed, &abi.alloc);
}

export fn @"example:petstore/store#toy-count"(pet_id: i32) canon.CoreReturn(u32) {
    ensureSeeded();
    var n: u32 = 0;
    for (&toys) |*t| {
        if (t.used and t.pet_id == pet_id) n += 1;
    }
    return canon.returnResult(u32, n, &abi.alloc);
}

export fn @"example:petstore/store#toy-at"(pet_id: i32, index: i32) canon.CoreReturn(?Toy) {
    abi.resetScratch();
    ensureSeeded();
    const idx: u32 = @bitCast(index);
    var n: u32 = 0;
    for (&toys) |*t| {
        if (!t.used or t.pet_id != pet_id) continue;
        if (n == idx) return canon.returnResult(?Toy, toyView(t), &abi.alloc);
        n += 1;
    }
    return canon.returnResult(?Toy, null, &abi.alloc);
}
