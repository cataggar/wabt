//! Frontend client for the `example:petstore/store` data-access interface.
//!
//! The canonical-ABI "lower" side of the imports the HTTP frontend calls;
//! `wabt component compose` binds them to the storage backend's exports.
//! Scalar results come back directly; a result wider than one core value
//! (`option<pet>` / `option<toy>`) is written by the host into the shared
//! ret-area we pass as the trailing `retptr`, and lifted into a typed Zig value
//! by the comptime `canon` marshaller — no hand-written layout structs.
//!
//! Lifted strings borrow this component's `cabi_realloc` scratch arena, so
//! `Pet.name` / `Toy.name` are valid until the next `abi.resetScratch()` (the
//! http handler resets once per request).

const abi = @import("abi");
const canon = @import("canon");

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

pub fn petCount() u32 {
    return canon.liftResultFlat(u32, @"pet-count"());
}

pub fn petAt(index: u32) ?Pet {
    @"pet-at"(@bitCast(index), abi.retPtr());
    return canon.lift(?Pet, abi.retArea());
}

pub fn getPet(id: u32) ?Pet {
    @"get-pet"(@bitCast(id), abi.retPtr());
    return canon.lift(?Pet, abi.retArea());
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
    return canon.lift(?Pet, abi.retArea());
}

pub fn deletePet(id: u32) bool {
    return canon.liftResultFlat(bool, @"delete-pet"(@bitCast(id)));
}

pub fn toyCount(pet_id: u32) u32 {
    return canon.liftResultFlat(u32, @"toy-count"(@bitCast(pet_id)));
}

pub fn toyAt(pet_id: u32, index: u32) ?Toy {
    @"toy-at"(@bitCast(pet_id), @bitCast(index), abi.retPtr());
    return canon.lift(?Toy, abi.retArea());
}
