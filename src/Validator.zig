//! WebAssembly module validator.
//!
//! Validates a parsed Module against the WebAssembly specification,
//! checking types, indices, limits, exports, start function, and more.

const std = @import("std");
const types = @import("types.zig");
const Mod = @import("Module.zig");
const Feature = @import("Feature.zig");

pub const Error = error{
    InvalidTypeIndex,
    InvalidFuncIndex,
    InvalidTableIndex,
    InvalidMemoryIndex,
    InvalidGlobalIndex,
    InvalidTagIndex,
    InvalidElemIndex,
    InvalidDataIndex,
    InvalidLimits,
    InvalidExport,
    DuplicateExport,
    InvalidStart,
    TooManyMemories,
    TooManyTables,
    InvalidElemType,
    OutOfMemory,
};

pub const Options = struct {
    features: Feature.Set = .{},
};

/// Validate a WebAssembly module.
pub fn validate(module: *const Mod.Module, options: Options) Error!void {
    try checkTypes(module);
    try checkImports(module);
    try checkFunctions(module);
    try checkTables(module, options);
    try checkMemories(module, options);
    try checkGlobals(module);
    try checkExports(module);
    try checkStart(module);
    try checkElemSegments(module);
    try checkDataSegments(module);
}

// ── Validation passes ───────────────────────────────────────────────────

fn checkTypes(m: *const Mod.Module) Error!void {
    for (m.module_types.items) |entry| {
        switch (entry) {
            .func_type => |ft| {
                for (ft.params) |p| {
                    if (!p.isNumType() and !p.isRefType()) return error.InvalidTypeIndex;
                }
                for (ft.results) |r| {
                    if (!r.isNumType() and !r.isRefType()) return error.InvalidTypeIndex;
                }
            },
            else => {},
        }
    }
}

fn checkImports(m: *const Mod.Module) Error!void {
    for (m.imports.items) |imp| {
        switch (imp.kind) {
            .func => if (imp.func) |f| {
                if (f.type_var.index >= m.module_types.items.len)
                    return error.InvalidTypeIndex;
            },
            else => {},
        }
    }
}

fn checkFunctions(m: *const Mod.Module) Error!void {
    for (m.funcs.items) |func| {
        if (func.decl.type_var.index != types.invalid_index) {
            if (func.decl.type_var.index >= m.module_types.items.len)
                return error.InvalidTypeIndex;
        }
    }
}

fn checkTables(m: *const Mod.Module, options: Options) Error!void {
    if (!options.features.reference_types and m.tables.items.len > 1)
        return error.TooManyTables;

    for (m.tables.items) |table| {
        if (!table.type.elem_type.isRefType())
            return error.InvalidElemType;
        try checkLimits(table.type.limits, std.math.maxInt(u32));
    }
}

fn checkMemories(m: *const Mod.Module, options: Options) Error!void {
    if (!options.features.multi_memory and m.memories.items.len > 1)
        return error.TooManyMemories;

    for (m.memories.items) |mem| {
        const max_pages: u64 = if (mem.type.limits.is_64)
            std.math.maxInt(u64)
        else
            @as(u64, std.math.maxInt(u32));
        try checkLimits(mem.type.limits, max_pages);
    }
}

fn checkGlobals(m: *const Mod.Module) Error!void {
    for (m.globals.items) |global| {
        if (!global.type.val_type.isNumType() and !global.type.val_type.isRefType())
            return error.InvalidTypeIndex;
    }
}

fn checkExports(m: *const Mod.Module) Error!void {
    // Check for duplicate export names (O(n²) but simple)
    for (m.exports.items, 0..) |exp, i| {
        // Validate export target index
        switch (exp.kind) {
            .func => if (exp.var_.index >= m.funcs.items.len) return error.InvalidFuncIndex,
            .table => if (exp.var_.index >= m.tables.items.len) return error.InvalidTableIndex,
            .memory => if (exp.var_.index >= m.memories.items.len) return error.InvalidMemoryIndex,
            .global => if (exp.var_.index >= m.globals.items.len) return error.InvalidGlobalIndex,
            .tag => if (exp.var_.index >= m.tags.items.len) return error.InvalidTagIndex,
        }

        // Check for duplicate names
        for (m.exports.items[0..i]) |prev| {
            if (std.mem.eql(u8, exp.name, prev.name))
                return error.DuplicateExport;
        }
    }
}

fn checkStart(m: *const Mod.Module) Error!void {
    const sv = m.start_var orelse return;
    if (sv.index >= m.funcs.items.len)
        return error.InvalidFuncIndex;

    // Start function must be nullary and return nothing
    const func = m.funcs.items[sv.index];
    if (func.decl.type_var.index != types.invalid_index and
        func.decl.type_var.index < m.module_types.items.len)
    {
        const entry = m.module_types.items[func.decl.type_var.index];
        switch (entry) {
            .func_type => |ft| {
                if (ft.params.len != 0 or ft.results.len != 0)
                    return error.InvalidStart;
            },
            else => {},
        }
    }
}

fn checkElemSegments(m: *const Mod.Module) Error!void {
    for (m.elem_segments.items) |seg| {
        if (seg.kind == .active) {
            if (seg.table_var.index >= m.tables.items.len and m.tables.items.len > 0)
                return error.InvalidTableIndex;
        }
        for (seg.elem_var_indices.items) |v| {
            if (v.index != 0 and v.index >= m.funcs.items.len)
                return error.InvalidFuncIndex;
        }
    }
}

fn checkDataSegments(m: *const Mod.Module) Error!void {
    for (m.data_segments.items) |seg| {
        if (seg.kind == .active) {
            if (seg.memory_var.index >= m.memories.items.len and m.memories.items.len > 0)
                return error.InvalidMemoryIndex;
        }
    }
}

fn checkLimits(limits: types.Limits, absolute_max: u64) Error!void {
    if (limits.initial > absolute_max)
        return error.InvalidLimits;
    if (limits.has_max) {
        if (limits.max > absolute_max)
            return error.InvalidLimits;
        if (limits.max < limits.initial)
            return error.InvalidLimits;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "validate empty module" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try validate(&module, .{});
}

test "validate invalid type index in func" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.funcs.append(std.testing.allocator, .{ .decl = .{ .type_var = .{ .index = 99 } } });
    try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
}

test "validate duplicate export names" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.funcs.append(std.testing.allocator, .{});
    try module.exports.append(std.testing.allocator, .{ .name = "a", .kind = .func, .var_ = .{ .index = 0 } });
    try module.exports.append(std.testing.allocator, .{ .name = "a", .kind = .func, .var_ = .{ .index = 0 } });
    try std.testing.expectError(error.DuplicateExport, validate(&module, .{}));
}

test "validate export func index out of range" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.exports.append(std.testing.allocator, .{ .name = "f", .kind = .func, .var_ = .{ .index = 5 } });
    try std.testing.expectError(error.InvalidFuncIndex, validate(&module, .{}));
}

test "validate too many memories" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.memories.append(std.testing.allocator, .{});
    try module.memories.append(std.testing.allocator, .{});
    // With multi_memory disabled, two memories should fail
    try std.testing.expectError(error.TooManyMemories, validate(&module, .{ .features = .{ .multi_memory = false } }));
    // With multi_memory enabled (now default), should pass
    try validate(&module, .{});
}

test "validate invalid limits (max < initial)" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.memories.append(std.testing.allocator, .{
        .type = .{ .limits = .{ .initial = 10, .max = 5, .has_max = true } },
    });
    try std.testing.expectError(error.InvalidLimits, validate(&module, .{}));
}

test "validate start function must be nullary" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    // Add a type (i32) -> ()
    const params = try alloc.alloc(types.ValType, 1);
    params[0] = .i32;
    try module.module_types.append(alloc, .{ .func_type = .{ .params = params } });
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    module.start_var = .{ .index = 0 };
    try std.testing.expectError(error.InvalidStart, validate(&module, .{}));
}

test "validate valid module with export" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.memories.append(std.testing.allocator, .{
        .type = .{ .limits = .{ .initial = 1, .has_max = true, .max = 256 } },
    });
    try module.exports.append(std.testing.allocator, .{ .name = "mem", .kind = .memory, .var_ = .{ .index = 0 } });
    try validate(&module, .{});
}
