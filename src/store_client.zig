//! Frontend client for the `example:petstore/store` data-access interface.
//!
//! These are the canonical-ABI "lower" side of the imports the HTTP frontend
//! calls; `wabt component compose` binds them to the storage backend's
//! exports. Scalar results come back directly; a result wider than one core
//! value (`option<pet>` / `option<toy>`) is written by the host into the
//! shared ret-area we pass as the trailing `retptr`, which we then decode.
//!
//! Returned strings are lifted into this component's `cabi_realloc` scratch
//! arena, so `Pet.name` / `Toy.name` borrow that arena — valid until the next
//! `abi.resetScratch()` (the http handler resets once per request).

const std = @import("std");
const abi = @import("abi");

/// A pet as seen by the frontend (strings borrow the scratch arena).
pub const Pet = struct {
    id: u32,
    name: []const u8,
    tag: ?[]const u8,
    age: u32,
};

pub const Toy = struct {
    id: u32,
    pet_id: u32,
    name: []const u8,
};

extern "example:petstore/store" fn @"pet-count"() i32;
extern "example:petstore/store" fn @"pet-at"(index: i32, retptr: i32) void;
extern "example:petstore/store" fn @"get-pet"(id: i32, retptr: i32) void;
extern "example:petstore/store" fn @"create-pet"(
    name_ptr: i32,
    name_len: i32,
    tag_disc: i32,
    tag_ptr: i32,
    tag_len: i32,
    age: i32,
    retptr: i32,
) void;
extern "example:petstore/store" fn @"delete-pet"(id: i32) i32;
extern "example:petstore/store" fn @"toy-count"(pet_id: i32) i32;
extern "example:petstore/store" fn @"toy-at"(pet_id: i32, index: i32, retptr: i32) void;

// Canonical memory layout of `option<pet>` / `option<toy>` written into the
// ret-area by the host (mirrors the provider's encoding).
const RetPet = extern struct {
    disc: u8,
    id: u32,
    name_ptr: u32,
    name_len: u32,
    tag_disc: u8,
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

fn slice(ptr: u32, len: u32) []const u8 {
    const p: [*]const u8 = @ptrFromInt(ptr);
    return p[0..len];
}

fn decodePet(r: *const RetPet) ?Pet {
    if (r.disc == 0) return null;
    return .{
        .id = r.id,
        .name = slice(r.name_ptr, r.name_len),
        .tag = if (r.tag_disc == 1) slice(r.tag_ptr, r.tag_len) else null,
        .age = r.age,
    };
}

pub fn petCount() u32 {
    return @bitCast(@"pet-count"());
}

pub fn petAt(index: u32) ?Pet {
    @"pet-at"(@bitCast(index), abi.retPtr());
    return decodePet(@ptrCast(@alignCast(abi.retWords())));
}

pub fn getPet(id: u32) ?Pet {
    @"get-pet"(@bitCast(id), abi.retPtr());
    return decodePet(@ptrCast(@alignCast(abi.retWords())));
}

pub fn createPet(name: []const u8, tag: ?[]const u8, age: u32) ?Pet {
    const tag_disc: i32 = if (tag != null) 1 else 0;
    const tag_ptr: i32 = if (tag) |t| @intCast(@intFromPtr(t.ptr)) else 0;
    const tag_len: i32 = if (tag) |t| @intCast(t.len) else 0;
    @"create-pet"(
        @intCast(@intFromPtr(name.ptr)),
        @intCast(name.len),
        tag_disc,
        tag_ptr,
        tag_len,
        @bitCast(age),
        abi.retPtr(),
    );
    return decodePet(@ptrCast(@alignCast(abi.retWords())));
}

pub fn deletePet(id: u32) bool {
    return @"delete-pet"(@bitCast(id)) != 0;
}

pub fn toyCount(pet_id: u32) u32 {
    return @bitCast(@"toy-count"(@bitCast(pet_id)));
}

pub fn toyAt(pet_id: u32, index: u32) ?Toy {
    @"toy-at"(@bitCast(pet_id), @bitCast(index), abi.retPtr());
    const r: *const RetToy = @ptrCast(@alignCast(abi.retWords()));
    if (r.disc == 0) return null;
    return .{
        .id = r.id,
        .pet_id = r.pet_id,
        .name = slice(r.name_ptr, r.name_len),
    };
}
