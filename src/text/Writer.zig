//! WebAssembly text format writer.
//!
//! Serializes a Module IR to human-readable .wat text format.

const std = @import("std");
const types = @import("../types.zig");
const Mod = @import("../Module.zig");

pub const WriteError = error{OutOfMemory};

pub fn writeModule(allocator: std.mem.Allocator, module: *const Mod.Module) WriteError![]u8 {
    var w = WatWriter{ .buf = std.ArrayList(u8).init(allocator) };
    errdefer w.buf.deinit();
    try w.writeModuleImpl(module);
    return w.buf.toOwnedSlice();
}

const WatWriter = struct {
    buf: std.ArrayList(u8),

    fn a(self: *WatWriter) std.mem.Allocator {
        return self.buf.allocator;
    }

    fn put(self: *WatWriter, s: []const u8) WriteError!void {
        try self.buf.appendSlice(self.a(), s);
    }

    fn putByte(self: *WatWriter, b: u8) WriteError!void {
        try self.buf.append(self.a(), b);
    }

    fn putU32(self: *WatWriter, v: u32) WriteError!void {
        var tmp: [16]u8 = undefined;
        const len = std.fmt.formatIntBuf(&tmp, v, 10, .lower, .{});
        try self.put(tmp[0..len]);
    }

    fn putU64(self: *WatWriter, v: u64) WriteError!void {
        var tmp: [24]u8 = undefined;
        const len = std.fmt.formatIntBuf(&tmp, v, 10, .lower, .{});
        try self.put(tmp[0..len]);
    }

    fn nl(self: *WatWriter) WriteError!void {
        try self.putByte('\n');
    }

    fn putValType(self: *WatWriter, vt: types.ValType) WriteError!void {
        try self.put(vt.name());
    }

    fn putQuoted(self: *WatWriter, s: []const u8) WriteError!void {
        try self.putByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try self.put("\\\""),
                '\\' => try self.put("\\\\"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try self.putByte(c),
                else => {
                    try self.putByte('\\');
                    const hex = "0123456789abcdef";
                    try self.putByte(hex[c >> 4]);
                    try self.putByte(hex[c & 0x0f]);
                },
            }
        }
        try self.putByte('"');
    }

    fn putLimits(self: *WatWriter, lim: types.Limits) WriteError!void {
        try self.putU64(lim.initial);
        if (lim.has_max) {
            try self.putByte(' ');
            try self.putU64(lim.max);
        }
    }

    fn putExternalKind(self: *WatWriter, kind: types.ExternalKind) WriteError!void {
        try self.put(switch (kind) {
            .func => "func",
            .table => "table",
            .memory => "memory",
            .global => "global",
            .tag => "tag",
        });
    }

    fn writeModuleImpl(self: *WatWriter, m: *const Mod.Module) WriteError!void {
        try self.put("(module");
        if (m.name) |n| {
            try self.putByte(' ');
            try self.put(n);
        }
        try self.nl();

        for (m.types.items, 0..) |entry, i| {
            try self.put("  (type (;");
            try self.putU32(@intCast(i));
            try self.put(";) ");
            switch (entry) {
                .func_type => |ft| {
                    try self.put("(func");
                    if (ft.params.len > 0) {
                        try self.put(" (param");
                        for (ft.params) |p| {
                            try self.putByte(' ');
                            try self.putValType(p);
                        }
                        try self.putByte(')');
                    }
                    if (ft.results.len > 0) {
                        try self.put(" (result");
                        for (ft.results) |r| {
                            try self.putByte(' ');
                            try self.putValType(r);
                        }
                        try self.putByte(')');
                    }
                    try self.putByte(')');
                },
                else => try self.put("(unknown)"),
            }
            try self.put(")\n");
        }

        for (m.imports.items) |imp| {
            try self.put("  (import ");
            try self.putQuoted(imp.module_name);
            try self.putByte(' ');
            try self.putQuoted(imp.field_name);
            try self.put(" (");
            try self.putExternalKind(imp.kind);
            switch (imp.kind) {
                .func => if (imp.func) |f| {
                    try self.put(" (type ");
                    try self.putU32(f.type_var.index);
                    try self.putByte(')');
                },
                .memory => if (imp.memory) |mem| {
                    try self.putByte(' ');
                    try self.putLimits(mem.limits);
                },
                .table => if (imp.table) |t| {
                    try self.putByte(' ');
                    try self.putLimits(t.limits);
                    try self.putByte(' ');
                    try self.putValType(t.elem_type);
                },
                .global => if (imp.global) |g| {
                    try self.putByte(' ');
                    if (g.mutability == .mutable) {
                        try self.put("(mut ");
                        try self.putValType(g.val_type);
                        try self.putByte(')');
                    } else {
                        try self.putValType(g.val_type);
                    }
                },
                .tag => {},
            }
            try self.put("))\n");
        }

        for (m.funcs.items[m.num_func_imports..], 0..) |func, i| {
            try self.put("  (func (;");
            try self.putU32(m.num_func_imports + @as(u32, @intCast(i)));
            try self.put(";)");
            if (func.name) |n| {
                try self.putByte(' ');
                try self.put(n);
            }
            if (func.decl.type_var.index != types.invalid_index) {
                try self.put(" (type ");
                try self.putU32(func.decl.type_var.index);
                try self.putByte(')');
            }
            try self.put(")\n");
        }

        for (m.tables.items[m.num_table_imports..], 0..) |table, i| {
            try self.put("  (table (;");
            try self.putU32(m.num_table_imports + @as(u32, @intCast(i)));
            try self.put(";) ");
            try self.putLimits(table.type.limits);
            try self.putByte(' ');
            try self.putValType(table.type.elem_type);
            try self.put(")\n");
        }

        for (m.memories.items[m.num_memory_imports..], 0..) |mem, i| {
            try self.put("  (memory (;");
            try self.putU32(m.num_memory_imports + @as(u32, @intCast(i)));
            try self.put(";) ");
            try self.putLimits(mem.type.limits);
            try self.put(")\n");
        }

        for (m.globals.items[m.num_global_imports..], 0..) |global, i| {
            try self.put("  (global (;");
            try self.putU32(m.num_global_imports + @as(u32, @intCast(i)));
            try self.put(";) ");
            if (global.type.mutability == .mutable) {
                try self.put("(mut ");
                try self.putValType(global.type.val_type);
                try self.put(") ");
            } else {
                try self.putValType(global.type.val_type);
                try self.putByte(' ');
            }
            // Default init: type.const 0
            try self.put("(");
            try self.putValType(global.type.val_type);
            try self.put(".const 0)");
            try self.put(")\n");
        }

        for (m.exports.items) |exp| {
            try self.put("  (export ");
            try self.putQuoted(exp.name);
            try self.put(" (");
            try self.putExternalKind(exp.kind);
            try self.putByte(' ');
            try self.putU32(exp.var_.index);
            try self.put("))\n");
        }

        if (m.start_var) |sv| {
            try self.put("  (start ");
            try self.putU32(sv.index);
            try self.put(")\n");
        }

        for (m.data_segments.items, 0..) |seg, i| {
            try self.put("  (data (;");
            try self.putU32(@intCast(i));
            try self.put(";) ");
            if (seg.kind == .active) {
                try self.put("(i32.const 0) ");
            }
            try self.putQuoted(seg.data);
            try self.put(")\n");
        }

        try self.put(")\n");
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "write empty module" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    const wat = try writeModule(alloc, &module);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.startsWith(u8, wat, "(module"));
    try std.testing.expect(std.mem.endsWith(u8, wat, ")\n"));
}

test "write module with memory" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1, .has_max = true, .max = 256 } } });
    const wat = try writeModule(alloc, &module);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "1 256") != null);
}

test "write module with export" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.exports.append(alloc, .{ .name = "main", .kind = .func, .var_ = .{ .index = 0 } });
    const wat = try writeModule(alloc, &module);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "\"main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(func 0)") != null);
}

test "write module with type" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    const params = try alloc.alloc(types.ValType, 1);
    params[0] = .i32;
    const results = try alloc.alloc(types.ValType, 1);
    results[0] = .i32;
    try module.types.append(alloc, .{ .func_type = .{ .params = params, .results = results } });
    const wat = try writeModule(alloc, &module);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(type") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(param i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(result i32)") != null);
}

test "write module with data" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.data_segments.append(alloc, .{ .data = "hello" });
    const wat = try writeModule(alloc, &module);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(data") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "\"hello\"") != null);
}
