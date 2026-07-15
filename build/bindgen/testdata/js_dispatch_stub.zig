const std = @import("std");

pub const NativeTag = enum(u32) {
    undefined_,
    list_,
};

pub const NativeValue = extern struct {
    tag: NativeTag,
    list_ptr: ?[*]const NativeValue = null,
    list_len: usize = 0,
};

pub fn call(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    _ = export_name;
    _ = args;
    if (comptime Result == void) return;
    return undefined;
}

pub fn dropExportResource(
    comptime provider: []const u8,
    comptime resource_name: []const u8,
    rep: i32,
) void {
    _ = provider;
    _ = resource_name;
    _ = rep;
}

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
    return .{ .tag = .undefined_ };
}

pub fn commitNativeResources(
    comptime T: type,
    decoded: T,
    value: *const NativeValue,
    allocator: std.mem.Allocator,
) bool {
    _ = decoded;
    _ = value;
    _ = allocator;
    return true;
}

pub fn freeNativeArena(arena: ?*anyopaque) void {
    _ = arena;
}
