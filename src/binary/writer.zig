//! WebAssembly binary format writer.
//!
//! Serializes a Module IR to the .wasm binary format.

const std = @import("std");
const leb128 = @import("../leb128.zig");
const types = @import("../types.zig");
const Mod = @import("../Module.zig");
const reader = @import("reader.zig");

pub const WriteError = error{OutOfMemory};

// ── Public API ──────────────────────────────────────────────────────────

pub fn writeModule(allocator: std.mem.Allocator, module: *const Mod.Module) WriteError![]u8 {
    var w = Writer{ .allocator = allocator, .buf = .{} };
    errdefer w.buf.deinit(allocator);

    try w.appendSlice(&reader.magic);
    try w.writeU32LE(reader.version);

    try w.writeTypeSection(module);
    try w.writeImportSection(module);
    try w.writeFunctionSection(module);
    try w.writeTableSection(module);
    try w.writeMemorySection(module);
    try w.writeTagSection(module);
    try w.writeGlobalSection(module);
    try w.writeExportSection(module);
    try w.writeStartSection(module);
    try w.writeElementSection(module);
    try w.writeCodeSection(module);
    try w.writeDataSection(module);
    try w.writeCustomSections(module);

    return w.buf.toOwnedSlice(allocator);
}

// ── Internal writer ─────────────────────────────────────────────────────

const Writer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8),

    // -- primitives --

    fn appendByte(self: *Writer, b: u8) WriteError!void {
        try self.buf.append(self.allocator, b);
    }

    fn appendSlice(self: *Writer, s: []const u8) WriteError!void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn writeU32LE(self: *Writer, v: u32) WriteError!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try self.appendSlice(&tmp);
    }

    fn writeU32Leb(self: *Writer, v: u32) WriteError!void {
        var tmp: [leb128.max_u32_bytes]u8 = undefined;
        const n = leb128.writeU32Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeS32Leb(self: *Writer, v: i32) WriteError!void {
        var tmp: [leb128.max_s32_bytes]u8 = undefined;
        const n = leb128.writeS32Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeName(self: *Writer, name: []const u8) WriteError!void {
        try self.writeU32Leb(@intCast(name.len));
        try self.appendSlice(name);
    }

    fn writeValType(self: *Writer, vt: types.ValType) WriteError!void {
        try self.writeValTypeWithTidx(vt, 0xFFFFFFFF);
    }

    fn writeValTypeWithTidx(self: *Writer, vt: types.ValType, tidx: u32) WriteError!void {
        if ((vt == .ref_null or vt == .ref) and tidx != 0xFFFFFFFF) {
            // Concrete typed ref: write prefix + type index
            try self.appendByte(@bitCast(@as(i8, @intCast(@intFromEnum(vt)))));
            try self.writeU32Leb(tidx);
        } else if (vt == .ref_func) {
            try self.appendByte(0x64); // ref
            try self.appendByte(0x70); // func
        } else if (vt == .ref_extern) {
            try self.appendByte(0x64); // ref
            try self.appendByte(0x6F); // extern
        } else if (vt == .ref_any) {
            try self.appendByte(0x64); // ref
            try self.appendByte(0x6E); // any
        } else if (vt == .ref_none) {
            try self.appendByte(0x64); // ref
            try self.appendByte(0x65); // none
        } else if (vt == .ref_nofunc) {
            try self.appendByte(0x64); // ref
            try self.appendByte(0x73); // nofunc
        } else if (vt == .ref_noextern) {
            try self.appendByte(0x64); // ref
            try self.appendByte(0x72); // noextern
        } else {
            try self.appendByte(@bitCast(@as(i8, @intCast(@intFromEnum(vt)))));
        }
    }

    fn writeLimits(self: *Writer, limits: types.Limits) WriteError!void {
        var flags: u8 = 0;
        if (limits.has_max) flags |= 0x01;
        if (limits.is_shared) flags |= 0x02;
        // Auto-detect 64-bit: if values exceed u32 range, force 64-bit encoding
        const needs_64 = limits.is_64 or limits.initial > std.math.maxInt(u32) or
            (limits.has_max and limits.max > std.math.maxInt(u32));
        if (needs_64) flags |= 0x04;
        try self.appendByte(flags);

        if (needs_64) {
            var tmp: [leb128.max_u64_bytes]u8 = undefined;
            var n = leb128.writeU64Leb128(&tmp, limits.initial);
            try self.appendSlice(tmp[0..n]);
            if (limits.has_max) {
                n = leb128.writeU64Leb128(&tmp, limits.max);
                try self.appendSlice(tmp[0..n]);
            }
        } else {
            try self.writeU32Leb(@intCast(limits.initial));
            if (limits.has_max) try self.writeU32Leb(@intCast(limits.max));
        }
    }

    // -- section helpers --

    fn beginSection(self: *Writer, id: u8) WriteError!usize {
        try self.appendByte(id);
        const placeholder = self.buf.items.len;
        // Reserve 5 bytes for section size (fixed-length LEB128)
        try self.appendSlice(&[5]u8{ 0, 0, 0, 0, 0 });
        return placeholder;
    }

    fn endSection(self: *Writer, placeholder: usize) void {
        const size: u32 = @intCast(self.buf.items.len - placeholder - 5);
        var tmp: [5]u8 = undefined;
        leb128.writeFixedU32Leb128(&tmp, size);
        @memcpy(self.buf.items[placeholder .. placeholder + 5], &tmp);
    }

    // -- sections --

    fn writeTypeSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.module_types.items.len == 0) return;
        const ph = try self.beginSection(1);
        // Count top-level entries: each rec group counts as 1, standalone types count as 1
        var top_count: u32 = 0;
        {
            var i: usize = 0;
            while (i < module.module_types.items.len) {
                const rgs = if (i < module.type_meta.items.len) module.type_meta.items[i].rec_group_size else 1;
                if (rgs > 1) {
                    i += rgs;
                } else {
                    i += 1;
                }
                top_count += 1;
            }
        }
        try self.writeU32Leb(top_count);
        var idx: usize = 0;
        while (idx < module.module_types.items.len) {
            const meta = if (idx < module.type_meta.items.len) module.type_meta.items[idx] else Mod.TypeMeta{};
            if (meta.rec_group_size > 1) {
                try self.appendByte(0x4E); // rec group marker
                try self.writeU32Leb(meta.rec_group_size);
                var ri: u32 = 0;
                while (ri < meta.rec_group_size) : (ri += 1) {
                    const sub_idx = idx + ri;
                    const sub_meta = if (sub_idx < module.type_meta.items.len) module.type_meta.items[sub_idx] else Mod.TypeMeta{};
                    try self.writeOneType(module, sub_idx, sub_meta);
                }
                idx += meta.rec_group_size;
            } else {
                try self.writeOneType(module, idx, meta);
                idx += 1;
            }
        }
        self.endSection(ph);
    }

    fn writeOneType(self: *Writer, module: *const Mod.Module, idx: usize, meta: Mod.TypeMeta) WriteError!void {
        if (meta.is_sub or !meta.is_final or meta.parent != std.math.maxInt(u32)) {
            // sub/sub final type
            try self.appendByte(if (meta.is_final) 0x4F else 0x50);
            if (meta.parent != std.math.maxInt(u32)) {
                try self.writeU32Leb(1);
                try self.writeU32Leb(meta.parent);
            } else {
                try self.writeU32Leb(0);
            }
        }
        if (idx < module.module_types.items.len) {
            switch (module.module_types.items[idx]) {
                .func_type => |ft| {
                    try self.appendByte(0x60);
                    try self.writeU32Leb(@intCast(ft.params.len));
                    for (ft.params, 0..) |p, pi| {
                        const tidx: u32 = if (pi < ft.param_type_idxs.len) ft.param_type_idxs[pi] else 0xFFFFFFFF;
                        try self.writeValTypeWithTidx(p, tidx);
                    }
                    try self.writeU32Leb(@intCast(ft.results.len));
                    for (ft.results, 0..) |r, ri| {
                        const tidx: u32 = if (ri < ft.result_type_idxs.len) ft.result_type_idxs[ri] else 0xFFFFFFFF;
                        try self.writeValTypeWithTidx(r, tidx);
                    }
                },
                .struct_type => |st| {
                    try self.appendByte(0x5F);
                    try self.writeU32Leb(@intCast(st.fields.items.len));
                    for (st.fields.items) |f| {
                        try self.writeValTypeWithTidx(f.@"type", f.type_idx);
                        try self.appendByte(if (f.mutable) 1 else 0);
                    }
                },
                .array_type => |at| {
                    try self.appendByte(0x5E);
                    try self.writeValTypeWithTidx(at.field.@"type", at.field.type_idx);
                    try self.appendByte(if (at.field.mutable) 1 else 0);
                },
            }
        }
    }

    fn writeImportSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.imports.items.len == 0) return;
        const ph = try self.beginSection(2);
        try self.writeU32Leb(@intCast(module.imports.items.len));
        for (module.imports.items) |imp| {
            try self.writeName(imp.module_name);
            try self.writeName(imp.field_name);
            try self.appendByte(@intFromEnum(imp.kind));
            switch (imp.kind) {
                .func => try self.writeU32Leb(if (imp.func) |f| f.type_var.index else 0),
                .table => {
                    if (imp.table) |t| {
                        try self.writeValTypeWithTidx(t.elem_type, imp.table_type_idx);
                        try self.writeLimits(t.limits);
                    }
                },
                .memory => {
                    if (imp.memory) |m| try self.writeLimits(m.limits);
                },
                .global => {
                    if (imp.global) |g| {
                        try self.writeValTypeWithTidx(g.val_type, imp.global_type_idx);
                        try self.appendByte(if (g.mutability == .mutable) @as(u8, 1) else 0);
                    }
                },
                .tag => {
                    try self.appendByte(0); // attribute
                    try self.writeU32Leb(0); // sig index placeholder
                },
            }
        }
        self.endSection(ph);
    }

    fn writeFunctionSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.funcs.items.len - module.num_func_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(3);
        try self.writeU32Leb(@intCast(defined));
        for (module.funcs.items[module.num_func_imports..]) |func| {
            try self.writeU32Leb(func.decl.type_var.index);
        }
        self.endSection(ph);
    }

    fn writeTableSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.tables.items.len - module.num_table_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(4);
        try self.writeU32Leb(@intCast(defined));
        for (module.tables.items[module.num_table_imports..]) |table| {
            const et = table.type.elem_type;
            if (table.init_expr_bytes.len > 0) {
                // Table with init expression: 0x40 0x00 reftype limits expr
                try self.appendByte(0x40);
                try self.appendByte(0x00);
                try self.writeValTypeWithTidx(et, table.type_idx);
                try self.writeLimits(table.type.limits);
                try self.appendSlice(table.init_expr_bytes);
                try self.appendByte(0x0b);
            } else if ((et == .ref_null or et == .ref) and table.type_idx != 0xFFFFFFFF) {
                // Typed reference: write prefix + concrete type index
                try self.appendByte(@bitCast(@as(i8, @intCast(@intFromEnum(et)))));
                try self.writeU32Leb(table.type_idx);
                try self.writeLimits(table.type.limits);
            } else {
                try self.writeValType(et);
                try self.writeLimits(table.type.limits);
            }
        }
        self.endSection(ph);
    }

    fn writeMemorySection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.memories.items.len - module.num_memory_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(5);
        try self.writeU32Leb(@intCast(defined));
        for (module.memories.items[module.num_memory_imports..]) |mem| {
            try self.writeLimits(mem.type.limits);
        }
        self.endSection(ph);
    }

    fn writeTagSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.tags.items.len - module.num_tag_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(13); // tag section ID
        try self.writeU32Leb(@intCast(defined));
        for (module.tags.items[module.num_tag_imports..]) |tag| {
            try self.appendByte(0); // attribute: 0 = exception
            // Resolve type index: if not set, find matching type by signature
            var tidx = tag.type_idx;
            if (tidx == std.math.maxInt(u32)) {
                tidx = findMatchingType(module, tag.@"type".sig.params, tag.@"type".sig.results) orelse 0;
            }
            try self.writeU32Leb(tidx);
        }
        self.endSection(ph);
    }

    fn findMatchingType(module: *const Mod.Module, params: []const types.ValType, results: []const types.ValType) ?u32 {
        for (module.module_types.items, 0..) |entry, i| {
            switch (entry) {
                .func_type => |ft| {
                    if (ft.params.len == params.len and ft.results.len == results.len) {
                        var match = true;
                        for (ft.params, params) |a, b| {
                            if (a != b) { match = false; break; }
                        }
                        if (match) {
                            for (ft.results, results) |a, b| {
                                if (a != b) { match = false; break; }
                            }
                        }
                        if (match) return @intCast(i);
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn writeGlobalSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.globals.items.len - module.num_global_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(6);
        try self.writeU32Leb(@intCast(defined));
        for (module.globals.items[module.num_global_imports..]) |global| {
            try self.writeValTypeWithTidx(global.type.val_type, global.type_idx);
            try self.appendByte(if (global.type.mutability == .mutable) @as(u8, 1) else 0);
            // Write init expression
            if (global.init_expr_bytes.len > 0) {
                try self.appendSlice(global.init_expr_bytes);
                try self.appendByte(0x0b);
            } else {
                // Empty init expression: emit just end opcode (invalid per spec)
                try self.appendByte(0x0b);
            }
        }
        self.endSection(ph);
    }

    fn writeExportSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.exports.items.len == 0) return;
        const ph = try self.beginSection(7);
        try self.writeU32Leb(@intCast(module.exports.items.len));
        for (module.exports.items) |exp| {
            try self.writeName(exp.name);
            try self.appendByte(@intFromEnum(exp.kind));
            try self.writeU32Leb(exp.var_.index);
        }
        self.endSection(ph);
    }

    fn writeStartSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const sv = module.start_var orelse return;
        const ph = try self.beginSection(8);
        try self.writeU32Leb(sv.index);
        self.endSection(ph);
    }

    fn writeElementSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.elem_segments.items.len == 0) return;
        const ph = try self.beginSection(9);
        try self.writeU32Leb(@intCast(module.elem_segments.items.len));
        for (module.elem_segments.items) |seg| {
            const has_table_idx = seg.kind == .active and seg.table_var.index != 0;
            const has_exprs = seg.elem_expr_bytes.len > 0;

            // Compute flags per the wasm binary format:
            // bit 0: passive/declared (non-active)
            // bit 1: explicit table index (or elemkind/reftype for non-active)
            // bit 2: elem expressions instead of function indices
            var flags: u32 = 0;
            if (seg.kind == .passive) flags |= 1;
            if (seg.kind == .declared) flags |= 3;
            if (has_table_idx) flags |= 2;
            if (has_exprs) flags |= 4;
            // For passive/declared with func indices, bit 1 is set to indicate elemkind
            if (seg.kind != .active and !has_exprs) flags |= 2;
            try self.writeU32Leb(flags);

            // Table index (only for active with explicit table)
            if (has_table_idx) {
                try self.writeU32Leb(seg.table_var.index);
            }

            // Offset expression (only for active segments)
            if (seg.kind == .active) {
                if (seg.offset_expr_bytes.len > 0) {
                    try self.appendSlice(seg.offset_expr_bytes);
                    try self.appendByte(0x0b);
                } else {
                    // Empty offset expression: emit just end opcode (invalid per spec)
                    try self.appendByte(0x0b);
                }
            }

            if (has_exprs) {
                // Elem expressions: reftype + count + expression bytes
                if (flags & 3 != 0) {
                    // Non-active or explicit table: write reftype
                    try self.writeValType(seg.elem_type);
                }
                try self.writeU32Leb(seg.elem_expr_count);
                try self.appendSlice(seg.elem_expr_bytes);
            } else {
                // Function indices
                if (flags & 3 != 0) {
                    // Non-active or explicit table: write elemkind (0x00 = funcref)
                    try self.appendByte(0x00);
                }
                try self.writeU32Leb(@intCast(seg.elem_var_indices.items.len));
                for (seg.elem_var_indices.items) |v| {
                    try self.writeU32Leb(v.index);
                }
            }
        }
        self.endSection(ph);
    }

    fn writeCodeSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.funcs.items.len - module.num_func_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(10);
        try self.writeU32Leb(@intCast(defined));
        for (module.funcs.items[module.num_func_imports..]) |func| {
            const body_ph = self.buf.items.len;
            try self.appendSlice(&[5]u8{ 0, 0, 0, 0, 0 }); // body size placeholder
            const body_start = self.buf.items.len;

            // Write compressed local declarations (run-length encoded)
            const locals = func.local_types.items;
            if (locals.len == 0) {
                try self.writeU32Leb(0);
            } else {
                // Count runs of same type
                var num_decls: u32 = 1;
                for (1..locals.len) |i| {
                    if (locals[i] != locals[i - 1]) num_decls += 1;
                }
                try self.writeU32Leb(num_decls);
                var run_start: usize = 0;
                while (run_start < locals.len) {
                    var run_end = run_start + 1;
                    while (run_end < locals.len and locals[run_end] == locals[run_start]) : (run_end += 1) {}
                    try self.writeU32Leb(@intCast(run_end - run_start));
                    const tidx: u32 = if (run_start < func.local_type_idxs.items.len) func.local_type_idxs.items[run_start] else 0xFFFFFFFF;
                    try self.writeValTypeWithTidx(locals[run_start], tidx);
                    run_start = run_end;
                }
            }

            // Write instruction bytes (includes final 0x0b end)
            if (func.code_bytes.len > 0) {
                try self.appendSlice(func.code_bytes);
            } else {
                try self.appendByte(0x0b); // bare end for empty bodies
            }

            const body_size: u32 = @intCast(self.buf.items.len - body_start);
            var tmp: [5]u8 = undefined;
            leb128.writeFixedU32Leb128(&tmp, body_size);
            @memcpy(self.buf.items[body_ph .. body_ph + 5], &tmp);
        }
        self.endSection(ph);
    }

    fn writeDataSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        if (module.data_segments.items.len == 0) return;
        const ph = try self.beginSection(11);
        try self.writeU32Leb(@intCast(module.data_segments.items.len));
        for (module.data_segments.items) |seg| {
            if (seg.kind == .passive) {
                try self.writeU32Leb(1); // flags: passive
            } else {
                const mem_idx = seg.memory_var.index;
                if (mem_idx != 0) {
                    try self.writeU32Leb(2); // flags: active, explicit memory index
                    try self.writeU32Leb(mem_idx);
                } else {
                    try self.writeU32Leb(0); // flags: active, memory 0 (implicit)
                }
                // Write offset expression
                if (seg.offset_expr_bytes.len > 0) {
                    try self.appendSlice(seg.offset_expr_bytes);
                    try self.appendByte(0x0b);
                } else {
                    // Empty offset expression: emit just end opcode (invalid per spec)
                    try self.appendByte(0x0b);
                }
            }
            try self.writeU32Leb(@intCast(seg.data.len));
            try self.appendSlice(seg.data);
        }
        self.endSection(ph);
    }

    fn writeCustomSections(self: *Writer, module: *const Mod.Module) WriteError!void {
        for (module.customs.items) |custom| {
            const ph = try self.beginSection(0);
            try self.writeName(custom.name);
            try self.appendSlice(custom.data);
            self.endSection(ph);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "write empty module" {
    const allocator = std.testing.allocator;
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    const bytes = try writeModule(allocator, &module);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expect(std.mem.eql(u8, bytes[0..4], &reader.magic));
}

test "round-trip type section" {
    const allocator = std.testing.allocator;
    const input = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    };
    var module = try reader.readModule(allocator, &input);
    defer module.deinit();

    const output = try writeModule(allocator, &module);
    defer allocator.free(output);

    // Should contain type section
    try std.testing.expect(output.len > 8);
    try std.testing.expectEqual(@as(usize, 1), module.module_types.items.len);
}

test "round-trip memory section" {
    const allocator = std.testing.allocator;
    const input = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    var module = try reader.readModule(allocator, &input);
    defer module.deinit();

    const output = try writeModule(allocator, &module);
    defer allocator.free(output);

    // Re-read and verify
    var module2 = try reader.readModule(allocator, output);
    defer module2.deinit();
    try std.testing.expectEqual(@as(usize, 1), module2.memories.items.len);
    try std.testing.expectEqual(@as(u64, 1), module2.memories.items[0].type.limits.initial);
}

test "round-trip exports" {
    const allocator = std.testing.allocator;
    const input = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x07, 0x07, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00,
    };
    var module = try reader.readModule(allocator, &input);
    defer module.deinit();

    const output = try writeModule(allocator, &module);
    defer allocator.free(output);

    var module2 = try reader.readModule(allocator, output);
    defer module2.deinit();
    try std.testing.expectEqual(@as(usize, 1), module2.exports.items.len);
    try std.testing.expect(std.mem.eql(u8, "mem", module2.exports.items[0].name));
}

test "round-trip code section preserves function bodies" {
    const allocator = std.testing.allocator;
    // Module with: type (i32,i32)->i32, 1 func, export "add",
    // code: local.get 0 (0x20 0x00), local.get 1 (0x20 0x01), i32.add (0x6a), end (0x0b)
    const input = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->i32
        0x03, 0x02, 0x01, 0x00, // func: 1 func, type 0
        0x07, 0x07, 0x01, 0x03, 'a', 'd', 'd', 0x00, 0x00, // export: "add" func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, // code
    };
    var module = try reader.readModule(allocator, &input);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.funcs.items.len);
    try std.testing.expect(module.funcs.items[0].code_bytes.len > 0);

    const output = try writeModule(allocator, &module);
    defer allocator.free(output);

    // Re-read and verify function body preserved
    var module2 = try reader.readModule(allocator, output);
    defer module2.deinit();
    try std.testing.expectEqual(@as(usize, 1), module2.funcs.items.len);
    const code = module2.funcs.items[0].code_bytes;
    // Should contain local.get 0, local.get 1, i32.add, end
    try std.testing.expect(code.len >= 4);
    try std.testing.expectEqual(@as(u8, 0x20), code[0]); // local.get
    try std.testing.expectEqual(@as(u8, 0x00), code[1]); // idx 0
    try std.testing.expectEqual(@as(u8, 0x20), code[2]); // local.get
    try std.testing.expectEqual(@as(u8, 0x01), code[3]); // idx 1
    try std.testing.expectEqual(@as(u8, 0x6a), code[4]); // i32.add
    try std.testing.expectEqual(@as(u8, 0x0b), code[5]); // end
}

test "text parse + binary write: memory load has correct encoding" {
    // End-to-end: parse WAT with memory load → write binary → verify no extra mem_idx
    const allocator = std.testing.allocator;
    const Parser = @import("../text/Parser.zig");
    var module = try Parser.parseModule(allocator,
        \\(module (memory 1) (func (export "f") (result i32) (i32.load (i32.const 0))))
    );
    defer module.deinit();

    const wasm = try writeModule(allocator, &module);
    defer allocator.free(wasm);

    // Re-read and verify the code
    var module2 = try reader.readModule(allocator, wasm);
    defer module2.deinit();

    try std.testing.expectEqual(@as(usize, 1), module2.memories.items.len);
    const code = module2.funcs.items[0].code_bytes;
    // Should be: i32.const 0 (41 00), i32.load align=0 offset=0 (28 00 00), end (0b)
    try std.testing.expectEqual(@as(usize, 6), code.len);
    try std.testing.expectEqual(@as(u8, 0x28), code[2]); // i32.load
    try std.testing.expectEqual(@as(u8, 0x0b), code[5]); // end
}

test "text parse + binary write: data segment offset preserved" {
    const allocator = std.testing.allocator;
    const Parser = @import("../text/Parser.zig");

    var module = try Parser.parseModule(allocator,
        \\(module (memory 1) (data (i32.const 16) "\aa\bb"))
    );
    defer module.deinit();

    const wasm = try writeModule(allocator, &module);
    defer allocator.free(wasm);

    var module2 = try reader.readModule(allocator, wasm);
    defer module2.deinit();

    try std.testing.expectEqual(@as(usize, 1), module2.data_segments.items.len);
    try std.testing.expectEqual(@as(usize, 2), module2.data_segments.items[0].data.len);
    // The offset expression should contain i32.const 16, not i32.const 0
    const offset_bytes = module2.data_segments.items[0].offset_expr_bytes;
    try std.testing.expect(offset_bytes.len >= 3);
    try std.testing.expectEqual(@as(u8, 0x41), offset_bytes[0]); // i32.const
    // LEB128 for 16 = 0x10
    try std.testing.expectEqual(@as(u8, 0x10), offset_bytes[1]);
}

test "text parse + binary write: global init expression preserved" {
    const allocator = std.testing.allocator;
    const Parser = @import("../text/Parser.zig");

    var module = try Parser.parseModule(allocator,
        \\(module (global (export "g") i32 (i32.const 42)))
    );
    defer module.deinit();

    // Verify the text parser stored the init expr
    try std.testing.expectEqual(@as(usize, 1), module.globals.items.len);
    const init = module.globals.items[0].init_expr_bytes;
    try std.testing.expect(init.len >= 2);
    try std.testing.expectEqual(@as(u8, 0x41), init[0]); // i32.const
    try std.testing.expectEqual(@as(u8, 42), init[1]); // 42

    // Write to binary and verify the global section encodes the value
    const wasm = try writeModule(allocator, &module);
    defer allocator.free(wasm);

    // Find global section (id=6) and verify init expr bytes
    var i: usize = 8;
    while (i < wasm.len) {
        const sid = wasm[i];
        i += 1;
        const r = leb128.readU32Leb128(wasm[i..]) catch return error.TestUnexpectedResult;
        const sz = r.value;
        i += r.bytes_read;
        if (sid == 6) {
            // Global section: count, {valtype, mut, init_expr}*
            // Skip count LEB128
            const r2 = leb128.readU32Leb128(wasm[i..]) catch return error.TestUnexpectedResult;
            const start = i + r2.bytes_read;
            // Skip valtype + mutability
            const expr_start = start + 2;
            try std.testing.expectEqual(@as(u8, 0x41), wasm[expr_start]); // i32.const
            try std.testing.expectEqual(@as(u8, 42), wasm[expr_start + 1]); // 42
            try std.testing.expectEqual(@as(u8, 0x0b), wasm[expr_start + 2]); // end
            return;
        }
        i += sz;
    }
    return error.TestUnexpectedResult; // global section not found
}

test "text parse + binary write: elem segment with function indices" {
    const allocator = std.testing.allocator;
    const Parser = @import("../text/Parser.zig");

    var module = try Parser.parseModule(allocator,
        \\(module
        \\  (table 10 funcref)
        \\  (func) (func) (func)
        \\  (elem (i32.const 2) func 0 1 2)
        \\)
    );
    defer module.deinit();

    const wasm = try writeModule(allocator, &module);
    defer allocator.free(wasm);

    var module2 = try reader.readModule(allocator, wasm);
    defer module2.deinit();

    try std.testing.expectEqual(@as(usize, 1), module2.elem_segments.items.len);
    const seg = module2.elem_segments.items[0];
    try std.testing.expectEqual(@as(usize, 3), seg.elem_var_indices.items.len);
    try std.testing.expectEqual(@as(u32, 0), seg.elem_var_indices.items[0].index);
    try std.testing.expectEqual(@as(u32, 1), seg.elem_var_indices.items[1].index);
    try std.testing.expectEqual(@as(u32, 2), seg.elem_var_indices.items[2].index);
}

test "text parse + binary write: passive elem segment" {
    const allocator = std.testing.allocator;
    const Parser = @import("../text/Parser.zig");

    var module = try Parser.parseModule(allocator,
        \\(module
        \\  (table 10 funcref)
        \\  (func) (func)
        \\  (elem funcref (ref.func 0) (ref.func 1))
        \\)
    );
    defer module.deinit();

    const wasm = try writeModule(allocator, &module);
    defer allocator.free(wasm);

    var module2 = try reader.readModule(allocator, wasm);
    defer module2.deinit();

    try std.testing.expectEqual(@as(usize, 1), module2.elem_segments.items.len);
    // Passive segment with elem expressions
    try std.testing.expect(module2.elem_segments.items[0].kind == .passive);
}
