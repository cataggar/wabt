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
// A result wider than one core value (`option<pet>` / `option<toy>`) is
// returned through a pointer. `OptionRet(T)` is the reusable mechanism: a
// static `extern struct { disc: u8, value: T }` reproduces the `option<T>`
// layout (a 1-byte discriminant, then the payload at `align(T)`), and
// `some`/`none` fill it and return its address. `T` is the canonical record
// layout — written out explicitly below, since that is the per-field
// marshalling this example exists to show.

fn OptionRet(comptime T: type) type {
    return struct {
        var area: extern struct { disc: u8, value: T } = undefined;

        fn some(value: T) i32 {
            area = .{ .disc = 1, .value = value };
            return @intCast(@intFromPtr(&area));
        }
        fn none() i32 {
            area.disc = 0;
            return @intCast(@intFromPtr(&area));
        }
    };
}

const PetRec = extern struct {
    id: u32,
    name_ptr: u32,
    name_len: u32,
    tag_disc: u8, // option<string> discriminant
    tag_ptr: u32,
    tag_len: u32,
    age: u32,
};

const ToyRec = extern struct {
    id: u32,
    pet_id: u32,
    name_ptr: u32,
    name_len: u32,
};

const PetOption = OptionRet(PetRec);
const ToyOption = OptionRet(ToyRec);

fn ptrTo(p: *const anyopaque) u32 {
    return @intCast(@intFromPtr(p));
}

fn writePet(p: *const StoredPet) i32 {
    return PetOption.some(.{
        .id = @intCast(p.id),
        .name_ptr = ptrTo(&p.name_buf),
        .name_len = p.name_len,
        .tag_disc = if (p.has_tag) 1 else 0,
        .tag_ptr = if (p.has_tag) ptrTo(&p.tag_buf) else 0,
        .tag_len = if (p.has_tag) p.tag_len else 0,
        .age = @intCast(p.age),
    });
}

fn writeNoPet() i32 {
    return PetOption.none();
}

fn writeToy(t: *const StoredToy) i32 {
    return ToyOption.some(.{
        .id = @intCast(t.id),
        .pet_id = @intCast(t.pet_id),
        .name_ptr = ptrTo(&t.name_buf),
        .name_len = t.name_len,
    });
}

fn writeNoToy() i32 {
    return ToyOption.none();
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
