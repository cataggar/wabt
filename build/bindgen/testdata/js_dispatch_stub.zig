const std = @import("std");

pub const NativeValue = extern struct {
    tag: u32,
};

pub fn decodeNative(comptime T: type, value: *const NativeValue, allocator: std.mem.Allocator) T {
    _ = value;
    _ = allocator;
    @panic("semantic compilation stub");
}

pub fn encodeNative(
    comptime T: type,
    value: T,
    allocator: std.mem.Allocator,
) NativeValue {
    _ = value;
    _ = allocator;
    return .{ .tag = 0 };
}

pub fn freeNativeArena(arena: ?*anyopaque) void {
    _ = arena;
}
