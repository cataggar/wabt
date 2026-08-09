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
    buf: std.ArrayListUnmanaged(u8),
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
        var i: usize = 0;
        while (i < module.module_types.items.len) {
            const meta = self.typeMeta(module, i);
            // A recursion group is printed as one `(rec ...)` holding its
            // members; the grouping is part of the type's identity, so it
            // cannot be flattened away. A group of one is indistinguishable
            // from a standalone type in the IR today -- the parser gives every
            // type its own group id for canonicalisation -- so only real
            // groups are wrapped, matching what the binary writer emits.
            if (meta.rec_group_size > 1 and meta.rec_position == 0) {
                try self.writeIndent();
                try self.append("(rec");
                try self.newline();
                self.indent += 1;
                for (0..meta.rec_group_size) |k| {
                    try self.writeOneType(module, i + k);
                }
                self.indent -= 1;
                try self.writeIndent();
                try self.append(")");
                try self.newline();
                i += meta.rec_group_size;
            } else {
                try self.writeOneType(module, i);
                i += 1;
            }
        }
    }

    fn typeMeta(_: *WatWriter, module: *const Mod.Module, idx: usize) Mod.TypeMeta {
        return if (idx < module.type_meta.items.len) module.type_meta.items[idx] else .{};
    }

    fn writeOneType(self: *WatWriter, module: *const Mod.Module, idx: usize) WriteError!void {
        const meta = self.typeMeta(module, idx);
        try self.writeIndent();
        try self.append("(type (;");
        try self.writeU32(@intCast(idx));
        try self.append(";) ");

        // `sub` wraps the structural type and names any supertype. A final
        // type with no supertype adds nothing, so it is left off.
        const has_sub = meta.is_sub or !meta.is_final or meta.parent != types.invalid_index;
        if (has_sub) {
            try self.append("(sub ");
            if (meta.is_final) try self.append("final ");
            if (meta.parent != types.invalid_index) {
                try self.writeU32(meta.parent);
                try self.appendByte(' ');
            }
        }

        switch (module.module_types.items[idx]) {
            .func_type => |ft| {
                try self.append("(func");
                if (ft.params.len > 0) {
                    try self.append(" (param");
                    for (ft.params, 0..) |p, k| {
                        try self.appendByte(' ');
                        try self.writeValTypeWithTidx(p, Mod.FuncSignature.concreteIdxAt(ft.param_type_idxs, k));
                    }
                    try self.appendByte(')');
                }
                if (ft.results.len > 0) {
                    try self.append(" (result");
                    for (ft.results, 0..) |r, k| {
                        try self.appendByte(' ');
                        try self.writeValTypeWithTidx(r, Mod.FuncSignature.concreteIdxAt(ft.result_type_idxs, k));
                    }
                    try self.appendByte(')');
                }
                try self.appendByte(')');
            },
            .struct_type => |st| {
                try self.append("(struct");
                for (st.fields.items) |f| {
                    try self.append(" (field ");
                    try self.writeFieldType(f);
                    try self.appendByte(')');
                }
                try self.appendByte(')');
            },
            .array_type => |at| {
                try self.append("(array ");
                try self.writeFieldType(at.field);
                try self.appendByte(')');
            },
        }

        if (has_sub) try self.appendByte(')');
        try self.appendByte(')');
        try self.newline();
    }

    fn writeFieldType(self: *WatWriter, field: Mod.TypeEntry.StructType.Field) WriteError!void {
        if (field.mutable) try self.append("(mut ");
        try self.writeValTypeWithTidx(field.@"type", field.type_idx);
        if (field.mutable) try self.appendByte(')');
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
                    try self.writeValTypeWithTidx(t.elem_type, imp.table_type_idx);
                },
                .global => if (imp.global) |g| {
                    try self.appendByte(' ');
                    if (g.mutability == .mutable) {
                        try self.append("(mut ");
                        try self.writeValTypeWithTidx(g.val_type, imp.global_type_idx);
                        try self.appendByte(')');
                    } else {
                        try self.writeValTypeWithTidx(g.val_type, imp.global_type_idx);
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
                for (func.local_types.items, 0..) |lt, k| {
                    try self.writeIndent();
                    try self.append("(local ");
                    try self.writeValTypeWithTidx(lt, Mod.FuncSignature.concreteIdxAt(func.local_type_idxs.items, k));
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
            try self.writeValTypeWithTidx(table.type.elem_type, table.type_idx);
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
                try self.writeValTypeWithTidx(global.type.val_type, global.type_idx);
                try self.append(") ");
            } else {
                try self.writeValTypeWithTidx(global.type.val_type, global.type_idx);
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

    /// A value type together with the concrete type index it refers to, if it
    /// has one. `ValType.name` cannot render `(ref $t)` on its own because the
    /// index is held out-of-line, so it falls back to a `<typeidx>` placeholder
    /// that is not valid wat.
    fn writeValTypeWithTidx(self: *WatWriter, vt: types.ValType, type_idx: u32) WriteError!void {
        switch (vt) {
            .concrete_ref, .concrete_ref_null => {
                if (type_idx == types.invalid_index) {
                    try self.append(vt.name());
                    return;
                }
                try self.append(if (vt == .concrete_ref_null) "(ref null " else "(ref ");
                try self.writeU32(type_idx);
                try self.appendByte(')');
            },
            else => try self.append(vt.name()),
        }
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

/// Round-trips a module through the binary reader and back out as text, which
/// is the path `wabt text print` takes.
fn printBinary(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var module = try @import("../binary/reader.zig").readModule(alloc, bytes);
    defer module.deinit();
    return writeModule(alloc, &module);
}

test "struct and array types print as themselves" {
    const alloc = std.testing.allocator;

    // (module (type (struct (field i32) (field (mut f64)))))
    const struct_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x5f, 0x02, 0x7f, 0x00, 0x7c, 0x01,
    };
    const st = try printBinary(alloc, &struct_bytes);
    defer alloc.free(st);
    try std.testing.expect(std.mem.indexOf(u8, st, "(struct (field i32) (field (mut f64)))") != null);
    try std.testing.expect(std.mem.indexOf(u8, st, "unknown") == null);

    // (module (type (array (mut i8))))
    const array_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x5e, 0x78, 0x01,
    };
    const at = try printBinary(alloc, &array_bytes);
    defer alloc.free(at);
    try std.testing.expect(std.mem.indexOf(u8, at, "(array (mut i8))") != null);
    try std.testing.expect(std.mem.indexOf(u8, at, "unknown") == null);
}

test "a concrete reference prints the type index it names" {
    const alloc = std.testing.allocator;
    // (module (type (func)) (type (func (param (ref 0)) (result (ref null 0)))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0b, 0x02,
        0x60, 0x00, 0x00,
        0x60, 0x01, 0x64, 0x00, 0x01, 0x63, 0x00,
    };
    const wat = try printBinary(alloc, &bytes);
    defer alloc.free(wat);
    // The index lives out-of-line, so printing the value type alone yields a
    // `<typeidx>` placeholder that is not valid wat.
    try std.testing.expect(std.mem.indexOf(u8, wat, "typeidx") == null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(param (ref 0))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(result (ref null 0))") != null);
}

test "sub types print their finality and supertype" {
    const alloc = std.testing.allocator;
    // (module (type (sub (struct (field i32))))
    //         (type (sub 0 (struct (field i32) (field f64)))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x10, 0x02,
        0x50, 0x00, 0x5f, 0x01, 0x7f, 0x00,
        0x50, 0x01, 0x00, 0x5f, 0x02, 0x7f, 0x00, 0x7c, 0x00,
    };
    const wat = try printBinary(alloc, &bytes);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(sub (struct (field i32)))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(sub 0 (struct (field i32) (field f64)))") != null);

    // A plain type carries no `sub` wrapper at all.
    const plain = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    };
    const plain_wat = try printBinary(alloc, &plain);
    defer alloc.free(plain_wat);
    try std.testing.expect(std.mem.indexOf(u8, plain_wat, "sub") == null);
}

test "a recursion group prints as one rec holding its members" {
    const alloc = std.testing.allocator;
    // (module (rec (type (struct (field (ref null 1))))
    //              (type (struct (field (ref null 0))))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0d, 0x01, 0x4e, 0x02,
        0x5f, 0x01, 0x63, 0x01, 0x00,
        0x5f, 0x01, 0x63, 0x00, 0x00,
    };
    const wat = try printBinary(alloc, &bytes);
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(rec") != null);
    // Both members sit inside the one group, and each names the other.
    try std.testing.expect(std.mem.indexOf(u8, wat, "(struct (field (ref null 1)))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(struct (field (ref null 0)))") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wat, "(rec"));
}
