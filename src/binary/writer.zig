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
        // ValType has i32 discriminant; binary encodes as single byte
        try self.appendByte(@bitCast(@as(i8, @intCast(@intFromEnum(vt)))));
    }

    fn writeLimits(self: *Writer, limits: types.Limits) WriteError!void {
        var flags: u8 = 0;
        if (limits.has_max) flags |= 0x01;
        if (limits.is_shared) flags |= 0x02;
        if (limits.is_64) flags |= 0x04;
        try self.appendByte(flags);

        if (limits.is_64) {
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
        try self.writeU32Leb(@intCast(module.module_types.items.len));
        for (module.module_types.items) |entry| {
            switch (entry) {
                .func_type => |ft| {
                    try self.appendByte(0x60);
                    try self.writeU32Leb(@intCast(ft.params.len));
                    for (ft.params) |p| try self.writeValType(p);
                    try self.writeU32Leb(@intCast(ft.results.len));
                    for (ft.results) |r| try self.writeValType(r);
                },
                else => {}, // struct/array not yet supported
            }
        }
        self.endSection(ph);
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
                        try self.writeValType(t.elem_type);
                        try self.writeLimits(t.limits);
                    }
                },
                .memory => {
                    if (imp.memory) |m| try self.writeLimits(m.limits);
                },
                .global => {
                    if (imp.global) |g| {
                        try self.writeValType(g.val_type);
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
            try self.writeValType(table.type.elem_type);
            try self.writeLimits(table.type.limits);
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

    fn writeGlobalSection(self: *Writer, module: *const Mod.Module) WriteError!void {
        const defined = module.globals.items.len - module.num_global_imports;
        if (defined == 0) return;
        const ph = try self.beginSection(6);
        try self.writeU32Leb(@intCast(defined));
        for (module.globals.items[module.num_global_imports..]) |global| {
            try self.writeValType(global.type.val_type);
            try self.appendByte(if (global.type.mutability == .mutable) @as(u8, 1) else 0);
            // Default init expr: type.const 0, end
            switch (global.type.val_type) {
                .i32 => {
                    try self.appendByte(0x41);
                    try self.writeS32Leb(0);
                },
                .i64 => {
                    try self.appendByte(0x42);
                    try self.writeS32Leb(0); // i64.const 0
                },
                .f32 => {
                    try self.appendByte(0x43);
                    try self.writeU32LE(0);
                },
                .f64 => {
                    try self.appendByte(0x44);
                    try self.appendSlice(&[8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
                },
                .funcref, .externref => {
                    try self.appendByte(0xd0); // ref.null
                    try self.writeValType(global.type.val_type);
                },
                else => {
                    try self.appendByte(0x41);
                    try self.writeS32Leb(0);
                },
            }
            try self.appendByte(0x0b); // end
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
            var flags: u32 = 0;
            if (seg.kind == .passive) flags |= 1;
            if (seg.kind == .declared) flags |= 3;
            try self.writeU32Leb(flags);

            if (seg.kind == .active) {
                // offset expression: i32.const 0, end
                try self.appendByte(0x41);
                try self.writeS32Leb(0);
                try self.appendByte(0x0b);
            }

            if (seg.kind != .active) {
                try self.appendByte(0x00); // elemkind funcref
            }

            try self.writeU32Leb(@intCast(seg.elem_var_indices.items.len));
            for (seg.elem_var_indices.items) |v| {
                try self.writeU32Leb(v.index);
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
                    try self.writeValType(locals[run_start]);
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
                try self.writeU32Leb(0); // flags: active, memory 0
                // offset expression: i32.const 0, end
                try self.appendByte(0x41);
                try self.writeS32Leb(0);
                try self.appendByte(0x0b);
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
