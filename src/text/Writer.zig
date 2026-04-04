//! WebAssembly text format writer.
//!
//! Serializes a Module IR back to .wat text format.

const std = @import("std");
const types = @import("../types.zig");
const Mod = @import("../Module.zig");

pub const WriteError = error{OutOfMemory};

pub fn writeModule(allocator: std.mem.Allocator, module: *const Mod.Module) WriteError![]u8 {
    var w = WatWriter{ .allocator = allocator, .buf = .empty };
    errdefer w.buf.deinit(allocator);
    try w.write(module);
    return w.buf.toOwnedSlice(allocator);
}

const WatWriter = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    indent: u32 = 0,

    // ── Main entry ──────────────────────────────────────────────────────

    fn write(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        try self.append("(module");
        self.indent = 1;
        if (module.name) |n| {
            try self.append(" ");
            try self.append(n);
        }
        try self.newline();

        try self.writeTypes(module);
        try self.writeImports(module);
        try self.writeFuncs(module);
        try self.writeTables(module);
        try self.writeMemories(module);
        try self.writeGlobals(module);
        try self.writeExports(module);
        try self.writeStart(module);
        try self.writeElems(module);
        try self.writeDatas(module);

        try self.append(")\n");
    }

    // ── Section writers ─────────────────────────────────────────────────

    fn writeTypes(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.module_types.items, 0..) |entry, i| {
            try self.writeIndent();
            try self.append("(type (;");
            try self.writeU32(@intCast(i));
            try self.append(";) ");
            switch (entry) {
                .func_type => |ft| {
                    try self.append("(func");
                    if (ft.params.len > 0) {
                        try self.append(" (param");
                        for (ft.params) |p| {
                            try self.appendByte(' ');
                            try self.writeValType(p);
                        }
                        try self.appendByte(')');
                    }
                    if (ft.results.len > 0) {
                        try self.append(" (result");
                        for (ft.results) |r| {
                            try self.appendByte(' ');
                            try self.writeValType(r);
                        }
                        try self.appendByte(')');
                    }
                    try self.appendByte(')');
                },
                else => try self.append("(unknown)"),
            }
            try self.appendByte(')');
            try self.newline();
        }
    }

    fn writeImports(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.imports.items) |imp| {
            try self.writeIndent();
            try self.append("(import \"");
            try self.writeEscapedString(imp.module_name);
            try self.append("\" \"");
            try self.writeEscapedString(imp.field_name);
            try self.append("\" (");
            try self.writeExternalKind(imp.kind);
            switch (imp.kind) {
                .func => if (imp.func) |f| {
                    try self.append(" (type ");
                    try self.writeU32(f.type_var.index);
                    try self.appendByte(')');
                },
                .memory => if (imp.memory) |mem| {
                    try self.appendByte(' ');
                    try self.writeLimits(mem.limits);
                },
                .table => if (imp.table) |t| {
                    try self.appendByte(' ');
                    try self.writeLimits(t.limits);
                    try self.appendByte(' ');
                    try self.writeValType(t.elem_type);
                },
                .global => if (imp.global) |g| {
                    try self.appendByte(' ');
                    if (g.mutability == .mutable) {
                        try self.append("(mut ");
                        try self.writeValType(g.val_type);
                        try self.appendByte(')');
                    } else {
                        try self.writeValType(g.val_type);
                    }
                },
                .tag => {},
            }
            try self.append("))");
            try self.newline();
        }
    }

    fn writeFuncs(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.funcs.items[module.num_func_imports..], 0..) |func, i| {
            try self.writeIndent();
            try self.append("(func (;");
            try self.writeU32(module.num_func_imports + @as(u32, @intCast(i)));
            try self.append(";)");
            if (func.name) |n| {
                try self.appendByte(' ');
                try self.append(n);
            }
            if (func.decl.type_var.index != types.invalid_index) {
                try self.append(" (type ");
                try self.writeU32(func.decl.type_var.index);
                try self.appendByte(')');
            }
            if (func.local_types.items.len > 0) {
                self.indent += 1;
                try self.newline();
                for (func.local_types.items) |lt| {
                    try self.writeIndent();
                    try self.append("(local ");
                    try self.writeValType(lt);
                    try self.appendByte(')');
                }
                self.indent -= 1;
            }
            try self.appendByte(')');
            try self.newline();
        }
    }

    fn writeTables(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.tables.items[module.num_table_imports..], 0..) |table, i| {
            try self.writeIndent();
            try self.append("(table (;");
            try self.writeU32(module.num_table_imports + @as(u32, @intCast(i)));
            try self.append(";) ");
            try self.writeLimits(table.type.limits);
            try self.appendByte(' ');
            try self.writeValType(table.type.elem_type);
            try self.appendByte(')');
            try self.newline();
        }
    }

    fn writeMemories(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.memories.items[module.num_memory_imports..], 0..) |mem, i| {
            try self.writeIndent();
            try self.append("(memory (;");
            try self.writeU32(module.num_memory_imports + @as(u32, @intCast(i)));
            try self.append(";) ");
            try self.writeLimits(mem.type.limits);
            try self.appendByte(')');
            try self.newline();
        }
    }

    fn writeGlobals(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.globals.items[module.num_global_imports..], 0..) |global, i| {
            try self.writeIndent();
            try self.append("(global (;");
            try self.writeU32(module.num_global_imports + @as(u32, @intCast(i)));
            try self.append(";) ");
            if (global.type.mutability == .mutable) {
                try self.append("(mut ");
                try self.writeValType(global.type.val_type);
                try self.append(") ");
            } else {
                try self.writeValType(global.type.val_type);
                try self.appendByte(' ');
            }
            try self.writeDefaultInitExpr(global.type.val_type);
            try self.appendByte(')');
            try self.newline();
        }
    }

    fn writeExports(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.exports.items) |exp| {
            try self.writeIndent();
            try self.append("(export \"");
            try self.writeEscapedString(exp.name);
            try self.append("\" (");
            try self.writeExternalKind(exp.kind);
            try self.appendByte(' ');
            try self.writeU32(exp.var_.index);
            try self.append("))");
            try self.newline();
        }
    }

    fn writeStart(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        const sv = module.start_var orelse return;
        try self.writeIndent();
        try self.append("(start ");
        try self.writeU32(sv.index);
        try self.appendByte(')');
        try self.newline();
    }

    fn writeElems(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.elem_segments.items, 0..) |seg, i| {
            try self.writeIndent();
            try self.append("(elem (;");
            try self.writeU32(@intCast(i));
            try self.append(";)");
            switch (seg.kind) {
                .active => try self.append(" (i32.const 0)"),
                .declared => try self.append(" declare"),
                .passive => {},
            }
            try self.append(" func");
            for (seg.elem_var_indices.items) |v| {
                try self.appendByte(' ');
                try self.writeU32(v.index);
            }
            try self.appendByte(')');
            try self.newline();
        }
    }

    fn writeDatas(self: *WatWriter, module: *const Mod.Module) WriteError!void {
        for (module.data_segments.items, 0..) |seg, i| {
            try self.writeIndent();
            try self.append("(data (;");
            try self.writeU32(@intCast(i));
            try self.append(";) ");
            if (seg.kind == .active) {
                try self.append("(i32.const 0) ");
            }
            try self.appendByte('"');
            try self.writeEscapedString(seg.data);
            try self.append("\")");
            try self.newline();
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fn a(self: *WatWriter) std.mem.Allocator {
        return self.allocator;
    }

    fn append(self: *WatWriter, s: []const u8) WriteError!void {
        try self.buf.appendSlice(self.a(), s);
    }

    fn appendByte(self: *WatWriter, b: u8) WriteError!void {
        try self.buf.append(self.a(), b);
    }

    fn newline(self: *WatWriter) WriteError!void {
        try self.appendByte('\n');
    }

    fn writeIndent(self: *WatWriter) WriteError!void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) {
            try self.append("  ");
        }
    }

    fn writeValType(self: *WatWriter, vt: types.ValType) WriteError!void {
        try self.append(vt.name());
    }

    fn writeLimits(self: *WatWriter, limits: types.Limits) WriteError!void {
        try self.writeU64(limits.initial);
        if (limits.has_max) {
            try self.appendByte(' ');
            try self.writeU64(limits.max);
        }
    }

    fn writeU32(self: *WatWriter, v: u32) WriteError!void {
        var tmp: [16]u8 = undefined;
        const result = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.append(result);
    }

    fn writeU64(self: *WatWriter, v: u64) WriteError!void {
        var tmp: [24]u8 = undefined;
        const result = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.append(result);
    }

    fn writeEscapedString(self: *WatWriter, data: []const u8) WriteError!void {
        for (data) |c| {
            switch (c) {
                '"' => try self.append("\\\""),
                '\\' => try self.append("\\\\"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try self.appendByte(c),
                else => {
                    try self.appendByte('\\');
                    const hex = "0123456789abcdef";
                    try self.appendByte(hex[c >> 4]);
                    try self.appendByte(hex[c & 0x0f]);
                },
            }
        }
    }

    fn writeExternalKind(self: *WatWriter, kind: types.ExternalKind) WriteError!void {
        try self.append(switch (kind) {
            .func => "func",
            .table => "table",
            .memory => "memory",
            .global => "global",
            .tag => "tag",
        });
    }

    fn writeDefaultInitExpr(self: *WatWriter, val_type: types.ValType) WriteError!void {
        switch (val_type) {
            .i32 => try self.append("(i32.const 0)"),
            .i64 => try self.append("(i64.const 0)"),
            .f32 => try self.append("(f32.const 0)"),
            .f64 => try self.append("(f64.const 0)"),
            .funcref => try self.append("(ref.null func)"),
            .externref => try self.append("(ref.null extern)"),
            else => try self.append("(i32.const 0)"),
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "write empty module" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    const wat = try writeModule(std.testing.allocator, &module);
    defer std.testing.allocator.free(wat);
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
}

test "write module with export" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.exports.append(alloc, .{
        .name = "main",
        .kind = .func,
        .var_ = .{ .index = 0 },
    });
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
    try module.module_types.append(alloc, .{ .func_type = .{ .params = params, .results = results } });
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
}
