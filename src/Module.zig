//! WebAssembly module IR.
//!
//! In-memory representation of a WebAssembly module, including all
//! sections: types, imports, functions, tables, memories, globals,
//! exports, start, elements, code, data, and custom sections.

const std = @import("std");
const types = @import("types.zig");
const Feature = @import("Feature.zig");

/// A parsed WebAssembly module.
pub const Module = struct {
    allocator: std.mem.Allocator,
    features: Feature.Set = .{},
    func_types: std.ArrayListUnmanaged(types.FuncType) = .empty,
    memories: std.ArrayListUnmanaged(types.MemoryType) = .empty,
    tables: std.ArrayListUnmanaged(types.TableType) = .empty,
    globals: std.ArrayListUnmanaged(types.GlobalType) = .empty,
    name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Module) void {
        self.func_types.deinit(self.allocator);
        self.memories.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.globals.deinit(self.allocator);
    }
};

test "Module init/deinit" {
    var module = Module.init(std.testing.allocator);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 0), module.func_types.items.len);
}
