//! WebAssembly text format writer.
//!
//! Serializes a Module IR back to .wat text format.

const std = @import("std");
const types = @import("../types.zig");
const Mod = @import("../Module.zig");
const Opcode = @import("../Opcode.zig");
const leb128 = @import("../leb128.zig");

pub const WriteError = error{
    OutOfMemory,
    /// A function body holds an opcode this writer cannot name, so printing
    /// it would silently drop or corrupt code. Reported rather than skipped.
    UnsupportedOpcode,
    /// A function body ends in the middle of an instruction.
    TruncatedBody,
};

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
            // members; the grouping is part of the type's identity under
            // iso-recursive typing, so it cannot be flattened away even when
            // the group holds a single type.
            if (meta.in_rec_group and meta.rec_position == 0) {
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
            try self.writeSignature(module, func.decl);
            self.indent += 1;
            if (func.local_types.items.len > 0) {
                try self.newline();
                for (func.local_types.items, 0..) |lt, k| {
                    try self.writeIndent();
                    try self.append("(local ");
                    try self.writeValTypeWithTidx(lt, Mod.FuncSignature.concreteIdxAt(func.local_type_idxs.items, k));
                    try self.appendByte(')');
                }
            }
            try self.writeBody(func.code_bytes);
            self.indent -= 1;
            try self.newline();
            try self.writeIndent();
            try self.appendByte(')');
            try self.newline();
        }
    }

    /// Restate the params and results alongside the `(type N)` reference, the
    /// way `wasm-tools print` does. Without this a function whose declaration
    /// carries no type index would lose its signature entirely.
    fn writeSignature(self: *WatWriter, module: *const Mod.Module, decl: Mod.FuncDeclaration) WriteError!void {
        var sig = decl.sig;
        // A function read from a binary carries only its type index; the
        // params and results live in the type section. Resolve them there so
        // the printed function states its signature either way.
        if (sig.params.len == 0 and sig.results.len == 0 and decl.type_var.index != types.invalid_index and
            decl.type_var.index < module.module_types.items.len)
        {
            switch (module.module_types.items[decl.type_var.index]) {
                .func_type => |ft| sig = .{
                    .params = ft.params,
                    .results = ft.results,
                    .param_type_idxs = ft.param_type_idxs,
                    .result_type_idxs = ft.result_type_idxs,
                },
                else => {},
            }
        }
        if (sig.params.len > 0) {
            try self.append(" (param");
            for (sig.params, 0..) |vt, k| {
                try self.appendByte(' ');
                try self.writeValTypeWithTidx(vt, Mod.FuncSignature.concreteIdxAt(sig.param_type_idxs, k));
            }
            try self.appendByte(')');
        }
        if (sig.results.len > 0) {
            try self.append(" (result");
            for (sig.results, 0..) |vt, k| {
                try self.appendByte(' ');
                try self.writeValTypeWithTidx(vt, Mod.FuncSignature.concreteIdxAt(sig.result_type_idxs, k));
            }
            try self.appendByte(')');
        }
    }

    // ── Function bodies ─────────────────────────────────────────────────

    /// The immediate operands that follow an opcode. Most opcodes take none;
    /// the rest fall into these shapes, which is what makes decoding a body
    /// tractable without a per-opcode table of 540 entries.
    const Imm = enum {
        none,
        /// A block signature: `0x40`, a single value type, or a type index.
        block_type,
        /// One u32 index (label, function, local, global, table, ...).
        index,
        /// Two u32 indices, in the order the binary format writes them.
        index_pair,
        /// Two u32 indices that the text format states in the opposite order
        /// from the binary one, as `memory.init` and `table.init` do.
        index_pair_swapped,
        /// An optional table index followed by `(type N)`. The binary form
        /// writes the type first, so the two are also swapped here.
        call_indirect,
        /// A vector of label indices plus the default label.
        br_table,
        /// Alignment, an optional memory index, and an offset.
        mem_arg,
        /// A memarg followed by a lane index.
        mem_arg_lane,
        /// A single lane index byte.
        lane,
        /// Sixteen lane index bytes.
        shuffle,
        /// A sixteen byte vector constant.
        v128,
        s32,
        s64,
        f32,
        f64,
        /// A heap type, for `ref.null`.
        heap_type,
        /// A vector of value types, for the typed `select`.
        select_types,
        /// A block signature followed by a vector of catch clauses.
        try_table,
        /// The single reserved byte carried by `atomic.fence`.
        reserved_byte,
    };

    /// Immediate shape for an opcode, or null when this writer has no way to
    /// print it. Returning null is deliberate: emitting a mnemonic without its
    /// operands, or skipping the instruction, would produce wat that no longer
    /// means what the module said.
    fn immediateShape(prefix: u8, code: u32) ?Imm {
        return switch (prefix) {
            0 => switch (code) {
                0x02, 0x03, 0x04 => .block_type,
                // Legacy exception handling is not supported (see #366), and
                // the lexer has no keywords for it, so there is nothing valid
                // to print.
                0x06, 0x07, 0x09, 0x18, 0x19 => null,
                0x00, 0x01, 0x05, 0x0a, 0x0b, 0x0f, 0x1a, 0x1b => .none,
                0x08, 0x0c, 0x0d, 0x10, 0x12, 0x14, 0x15 => .index,
                0x0e => .br_table,
                0x11, 0x13 => .call_indirect,
                0x1c => .select_types,
                0x1f => .try_table,
                0x20...0x26 => .index,
                0x28...0x3e => .mem_arg,
                0x3f, 0x40 => .index,
                0x41 => .s32,
                0x42 => .s64,
                0x43 => .f32,
                0x44 => .f64,
                0x45...0xc4 => .none,
                0xd0 => .heap_type,
                0xd1, 0xd3, 0xd4 => .none,
                0xd2, 0xd5, 0xd6 => .index,
                else => null,
            },
            0xfc => switch (code) {
                0x00...0x07 => .none,
                0x08, 0x0c => .index_pair_swapped,
                0x0a, 0x0e => .index_pair,
                0x09, 0x0b, 0x0d, 0x0f, 0x10, 0x11 => .index,
                0x13...0x16 => .none,
                else => null,
            },
            0xfd => switch (code) {
                0x00...0x0b => .mem_arg,
                0x0c => .v128,
                0x0d => .shuffle,
                0x15...0x22 => .lane,
                0x54...0x5b => .mem_arg_lane,
                0x5c, 0x5d => .mem_arg,
                else => .none,
            },
            0xfe => switch (code) {
                0x03 => .reserved_byte,
                else => .mem_arg,
            },
            else => null,
        };
    }

    /// Print a function body in the flat form `wasm-tools print` emits, which
    /// this crate's own text parser accepts.
    fn writeBody(self: *WatWriter, code_bytes: []const u8) WriteError!void {
        var pos: usize = 0;
        while (pos < code_bytes.len) {
            const start = pos;
            const byte = code_bytes[pos];
            pos += 1;

            var prefix: u8 = 0;
            var code: u32 = byte;
            if (byte == 0xfc or byte == 0xfd or byte == 0xfe or byte == 0xfb) {
                prefix = byte;
                code = try readU32At(code_bytes, &pos);
            }

            // The body's trailing `end` closes the function itself and is
            // implied by the closing paren, so it is not printed. Anything
            // after it would be unreachable bytes, not instructions.
            if (prefix == 0 and code == 0x0b and self.blockDepthAtBodyEnd(start, code_bytes)) break;

            const shape = immediateShape(prefix, code) orelse return error.UnsupportedOpcode;

            if (prefix == 0 and (code == 0x0b or code == 0x05 or code == 0x07 or code == 0x19)) {
                if (self.indent > 0) self.indent -= 1;
            }

            try self.newline();
            try self.writeIndent();
            try self.append(mnemonic(prefix, code) orelse return error.UnsupportedOpcode);
            try self.writeImmediates(shape, code_bytes, &pos);

            if (prefix == 0 and (code == 0x02 or code == 0x03 or code == 0x04 or code == 0x05 or code == 0x1f)) {
                self.indent += 1;
            }
        }
    }

    /// True when the `end` at `start` is the one closing the function body.
    fn blockDepthAtBodyEnd(_: *WatWriter, start: usize, code_bytes: []const u8) bool {
        return start == code_bytes.len - 1;
    }

    fn mnemonic(prefix: u8, code: u32) ?[]const u8 {
        const raw: u32 = if (prefix == 0)
            code
        else if (code <= 0xff)
            (@as(u32, prefix) << 8) | code
        else
            (@as(u32, prefix) << 12) | code;
        const name = (@as(Opcode.Code, @enumFromInt(raw))).name();
        if (std.mem.eql(u8, name, "<unknown>")) return null;
        return name;
    }

    fn writeImmediates(self: *WatWriter, shape: Imm, bytes: []const u8, pos: *usize) WriteError!void {
        switch (shape) {
            .none => {},
            .block_type => try self.writeBlockType(bytes, pos),
            .index => {
                try self.appendByte(' ');
                try self.writeU32(try readU32At(bytes, pos));
            },
            .index_pair => {
                try self.appendByte(' ');
                try self.writeU32(try readU32At(bytes, pos));
                try self.appendByte(' ');
                try self.writeU32(try readU32At(bytes, pos));
            },
            .index_pair_swapped => {
                const first = try readU32At(bytes, pos);
                const second = try readU32At(bytes, pos);
                try self.appendByte(' ');
                try self.writeU32(second);
                try self.appendByte(' ');
                try self.writeU32(first);
            },
            .call_indirect => {
                const type_idx = try readU32At(bytes, pos);
                const table_idx = try readU32At(bytes, pos);
                try self.appendByte(' ');
                try self.writeU32(table_idx);
                try self.append(" (type ");
                try self.writeU32(type_idx);
                try self.appendByte(')');
            },
            .br_table => {
                const count = try readU32At(bytes, pos);
                for (0..count) |_| {
                    try self.appendByte(' ');
                    try self.writeU32(try readU32At(bytes, pos));
                }
                try self.appendByte(' ');
                try self.writeU32(try readU32At(bytes, pos));
            },
            .mem_arg => try self.writeMemArg(bytes, pos),
            .mem_arg_lane => {
                try self.writeMemArg(bytes, pos);
                try self.appendByte(' ');
                try self.writeU32(try readByteAt(bytes, pos));
            },
            .lane => {
                try self.appendByte(' ');
                try self.writeU32(try readByteAt(bytes, pos));
            },
            .shuffle => {
                for (0..16) |_| {
                    try self.appendByte(' ');
                    try self.writeU32(try readByteAt(bytes, pos));
                }
            },
            .v128 => {
                // Printed as sixteen i8 lanes, which is the form that survives
                // a round trip without reinterpreting the bits.
                try self.append(" i8x16");
                for (0..16) |_| {
                    try self.appendByte(' ');
                    try self.writeU32(try readByteAt(bytes, pos));
                }
            },
            .s32 => {
                try self.appendByte(' ');
                const r = leb128.readS32Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
                pos.* += r.bytes_read;
                try self.writeI64(r.value);
            },
            .s64 => {
                try self.appendByte(' ');
                const r = leb128.readS64Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
                pos.* += r.bytes_read;
                try self.writeI64(r.value);
            },
            .f32 => {
                if (pos.* + 4 > bytes.len) return error.TruncatedBody;
                const bits = std.mem.readInt(u32, bytes[pos.*..][0..4], .little);
                pos.* += 4;
                try self.appendByte(' ');
                try self.writeFloat(f32, bits);
            },
            .f64 => {
                if (pos.* + 8 > bytes.len) return error.TruncatedBody;
                const bits = std.mem.readInt(u64, bytes[pos.*..][0..8], .little);
                pos.* += 8;
                try self.appendByte(' ');
                try self.writeFloat(f64, bits);
            },
            .heap_type => {
                try self.appendByte(' ');
                try self.writeHeapType(bytes, pos);
            },
            .select_types => {
                const count = try readU32At(bytes, pos);
                for (0..count) |_| {
                    try self.append(" (result ");
                    const b = try readByteAt(bytes, pos);
                    try self.append(valTypeNameFromByte(@intCast(b)) orelse return error.UnsupportedOpcode);
                    try self.appendByte(')');
                }
            },
            .try_table => {
                try self.writeBlockType(bytes, pos);
                const count = try readU32At(bytes, pos);
                for (0..count) |_| {
                    const kind = try readByteAt(bytes, pos);
                    switch (kind) {
                        0x00 => try self.append(" (catch "),
                        0x01 => try self.append(" (catch_ref "),
                        0x02 => try self.append(" (catch_all "),
                        0x03 => try self.append(" (catch_all_ref "),
                        else => return error.UnsupportedOpcode,
                    }
                    if (kind == 0x00 or kind == 0x01) {
                        try self.writeU32(try readU32At(bytes, pos));
                        try self.appendByte(' ');
                    }
                    try self.writeU32(try readU32At(bytes, pos));
                    try self.appendByte(')');
                }
            },
            .reserved_byte => {
                _ = try readByteAt(bytes, pos);
            },
        }
    }

    /// A block signature is `0x40` for an empty one, a value type, or an s33
    /// type index. In the one-byte s33 form the sign bit is `0x40`, not the
    /// byte's high bit, so a value type such as `i64` (`0x7e`) reads as
    /// negative while a small type index reads as positive.
    fn writeBlockType(self: *WatWriter, bytes: []const u8, pos: *usize) WriteError!void {
        if (pos.* >= bytes.len) return error.TruncatedBody;
        const byte = bytes[pos.*];
        if (byte == 0x40) {
            pos.* += 1;
            return;
        }
        if (byte == 0x63 or byte == 0x64) {
            try self.append(" (result ");
            try self.writeHeapRef(bytes, pos);
            try self.appendByte(')');
            return;
        }
        if (byte < 0x80 and (byte & 0x40) == 0) {
            // A positive one-byte s33: a type index.
            pos.* += 1;
            try self.append(" (type ");
            try self.writeU32(byte);
            try self.appendByte(')');
            return;
        }
        if (byte >= 0x80) {
            const r = leb128.readS64Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
            pos.* += r.bytes_read;
            if (r.value < 0) return error.UnsupportedOpcode;
            try self.append(" (type ");
            try self.writeU32(@intCast(r.value));
            try self.appendByte(')');
            return;
        }
        pos.* += 1;
        try self.append(" (result ");
        try self.append(valTypeNameFromByte(byte) orelse return error.UnsupportedOpcode);
        try self.appendByte(')');
    }

    /// `(ref null? <heaptype>)`, the general reference form.
    fn writeHeapRef(self: *WatWriter, bytes: []const u8, pos: *usize) WriteError!void {
        const form = try readByteAt(bytes, pos);
        try self.append("(ref ");
        if (form == 0x63) try self.append("null ");
        try self.writeHeapType(bytes, pos);
        try self.appendByte(')');
    }

    /// The operand of `ref.null`: an abstract heap type or a type index. As
    /// with a block signature the encoding is an s33, so the sign lives in
    /// bit `0x40` -- `extern` is `0x6f`, which is negative as an s33 even
    /// though the byte on its own looks positive.
    fn writeHeapType(self: *WatWriter, bytes: []const u8, pos: *usize) WriteError!void {
        if (pos.* >= bytes.len) return error.TruncatedBody;
        const byte = bytes[pos.*];
        if (byte < 0x80) {
            pos.* += 1;
            if ((byte & 0x40) == 0) {
                try self.writeU32(byte);
                return;
            }
            const code = @as(i64, byte) - 0x80;
            const heap = types.AbstractHeapType.fromCode(code) orelse return error.UnsupportedOpcode;
            try self.append(heapTypeName(heap));
            return;
        }
        const r = leb128.readS64Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
        pos.* += r.bytes_read;
        if (r.value < 0) return error.UnsupportedOpcode;
        try self.writeU32(@intCast(r.value));
    }

    /// `align=` is always printed, as the encoded value rather than a value
    /// derived from the opcode's natural alignment, so re-encoding reproduces
    /// exactly what was read.
    fn writeMemArg(self: *WatWriter, bytes: []const u8, pos: *usize) WriteError!void {
        const raw = try readU32At(bytes, pos);
        const has_memidx = (raw & 0x40) != 0;
        const align_log2 = raw & ~@as(u32, 0x40);
        if (has_memidx) {
            try self.appendByte(' ');
            try self.writeU32(try readU32At(bytes, pos));
        }
        const offset = try readU64At(bytes, pos);
        if (offset != 0) {
            try self.append(" offset=");
            try self.writeU64(offset);
        }
        if (align_log2 < 64) {
            try self.append(" align=");
            try self.writeU64(@as(u64, 1) << @intCast(align_log2));
        }
    }

    fn writeI64(self: *WatWriter, v: i64) WriteError!void {
        var buf: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.OutOfMemory;
        try self.append(s);
    }

    /// Floats are printed from their bits so the exact value survives: hex
    /// float notation for finite values, and an explicit payload for NaN.
    fn writeFloat(self: *WatWriter, comptime F: type, bits: anytype) WriteError!void {
        const UInt = if (F == f32) u32 else u64;
        const mantissa_bits: comptime_int = if (F == f32) 23 else 52;
        const exp_mask: UInt = if (F == f32) 0x7f800000 else 0x7ff0000000000000;
        const mant_mask: UInt = (@as(UInt, 1) << mantissa_bits) - 1;
        const sign_mask: UInt = @as(UInt, 1) << (@bitSizeOf(UInt) - 1);
        const b: UInt = @intCast(bits);

        const negative = (b & sign_mask) != 0;
        if ((b & exp_mask) == exp_mask) {
            if (negative) try self.appendByte('-');
            const payload = b & mant_mask;
            if (payload == 0) {
                try self.append("inf");
            } else {
                try self.append("nan:0x");
                var buf: [20]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{x}", .{payload}) catch return error.OutOfMemory;
                try self.append(s);
            }
            return;
        }
        const value: F = @bitCast(b);
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x}", .{value}) catch return error.OutOfMemory;
        try self.append(s);
    }

    fn readU32At(bytes: []const u8, pos: *usize) WriteError!u32 {
        const r = leb128.readU32Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
        pos.* += r.bytes_read;
        return r.value;
    }

    fn readU64At(bytes: []const u8, pos: *usize) WriteError!u64 {
        const r = leb128.readU64Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
        pos.* += r.bytes_read;
        return r.value;
    }

    fn readByteAt(bytes: []const u8, pos: *usize) WriteError!u32 {
        if (pos.* >= bytes.len) return error.TruncatedBody;
        const b = bytes[pos.*];
        pos.* += 1;
        return b;
    }

    /// Value type names keyed by the byte the binary format uses. Built from
    /// the enum so a type added to `ValType` is picked up automatically; the
    /// internal `concrete_ref` markers are negative and so never appear here.
    const val_type_by_byte = blk: {
        var table = [_]?types.ValType{null} ** 256;
        for (@typeInfo(types.ValType).@"enum".fields) |field| {
            if (field.value >= 0 and field.value < 256) {
                table[@as(usize, field.value)] = @enumFromInt(field.value);
            }
        }
        break :blk table;
    };

    fn valTypeNameFromByte(byte: u8) ?[]const u8 {
        const vt = val_type_by_byte[byte] orelse return null;
        return vt.name();
    }

    /// Abstract heap type names: the reference value types minus their `ref`
    /// wrapper.
    fn heapTypeName(heap: types.AbstractHeapType) []const u8 {
        return switch (heap) {
            .noexn => "noexn",
            .nofunc => "nofunc",
            .noextern => "noextern",
            .none => "none",
            .func => "func",
            .extern_ => "extern",
            .any => "any",
            .eq => "eq",
            .i31 => "i31",
            .struct_ => "struct",
            .array => "array",
            .exn => "exn",
        };
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

test "a group of one keeps its rec wrapper" {
    const alloc = std.testing.allocator;
    // (module (rec (type (array (mut (ref null 0))))))
    // Self-referential, so the group is load-bearing: outside a `rec` the
    // type could not name itself.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x4e, 0x01, 0x5e, 0x63, 0x00, 0x01,
    };
    const wat = try printBinary(alloc, &bytes);
    defer alloc.free(wat);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wat, "(rec"));
    try std.testing.expect(std.mem.indexOf(u8, wat, "(array (mut (ref null 0)))") != null);

    // The same type declared outside a group has a different identity under
    // iso-recursive typing, so it must not gain a wrapper.
    const loose = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x5e, 0x63, 0x00, 0x01,
    };
    const loose_wat = try printBinary(alloc, &loose);
    defer alloc.free(loose_wat);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, loose_wat, "(rec"));
}

/// Wraps `body` (instructions plus the trailing `end`) in the smallest module
/// that can carry it: one `() -> ()` function with no locals. Returns the
/// printed text of that function's body, one instruction per line.
fn printBody(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(alloc);

    try bytes.appendSlice(alloc, &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // type: one () -> ()
    try bytes.appendSlice(alloc, &[_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 });
    // func: one function of type 0
    try bytes.appendSlice(alloc, &[_]u8{ 0x03, 0x02, 0x01, 0x00 });
    // code: one entry, zero local groups
    const entry_len: u8 = @intCast(body.len + 1);
    try bytes.appendSlice(alloc, &[_]u8{ 0x0a, entry_len + 2, 0x01, entry_len, 0x00 });
    try bytes.appendSlice(alloc, body);

    const wat = try printBinary(alloc, bytes.items);
    defer alloc.free(wat);

    // Keep only the lines between the `(func` header and its closing paren.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var in_func = false;
    var base: ?usize = null;
    var lines = std.mem.splitScalar(u8, wat, '\n');
    while (lines.next()) |line| {
        const indent = line.len - std.mem.trimStart(u8, line, " ").len;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!in_func) {
            if (std.mem.startsWith(u8, trimmed, "(func")) in_func = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, ")")) break;
        // Dedent every line by the body's own base indent so the test can
        // assert on relative nesting without hard-coding the module's.
        if (base == null) base = indent;
        try out.appendSlice(alloc, line[@min(base.?, indent)..]);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

test "a function body prints its instructions" {
    const alloc = std.testing.allocator;
    // i32.const 1  i32.const 2  i32.add  drop  end
    const wat = try printBody(alloc, &[_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6a, 0x1a, 0x0b });
    defer alloc.free(wat);
    try std.testing.expectEqualStrings(
        \\i32.const 1
        \\i32.const 2
        \\i32.add
        \\drop
        \\
    , wat);
}

test "a function body prints signed and floating immediates" {
    const alloc = std.testing.allocator;
    // i32.const -1   i64.const -2   f32.const 1.0   f64.const nan:0x8000000000000
    const wat = try printBody(alloc, &[_]u8{
        0x41, 0x7f,
        0x42, 0x7e,
        0x43, 0x00, 0x00, 0x80, 0x3f,
        0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
        0x1a, 0x1a, 0x1a, 0x1a,
        0x0b,
    });
    defer alloc.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "i32.const -1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "i64.const -2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "f32.const 0x1p0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "f64.const nan") != null);
}

test "nested blocks indent and the function-level end is not printed" {
    const alloc = std.testing.allocator;
    // block (result i32) i32.const 0 if (result i32) i32.const 1 else i32.const 2 end end drop end
    const wat = try printBody(alloc, &[_]u8{
        0x02, 0x7f,
        0x41, 0x00,
        0x04, 0x7f,
        0x41, 0x01,
        0x05,
        0x41, 0x02,
        0x0b,
        0x0b,
        0x1a,
        0x0b,
    });
    defer alloc.free(wat);
    try std.testing.expectEqualStrings(
        \\block (result i32)
        \\  i32.const 0
        \\  if (result i32)
        \\    i32.const 1
        \\  else
        \\    i32.const 2
        \\  end
        \\end
        \\drop
        \\
    , wat);
}

test "a one-byte block type is read as signed" {
    const alloc = std.testing.allocator;
    // Block types are s33: in the one-byte form the sign bit is 0x40, not
    // 0x80. Read as an i8, i64's 0x7e is +126 and prints as `(type 126)`.
    const wat = try printBody(alloc, &[_]u8{ 0x02, 0x7e, 0x0b, 0x0b });
    defer alloc.free(wat);
    try std.testing.expectEqualStrings("block (result i64)\nend\n", wat);

    // A positive one-byte index still names a type, and must keep that form.
    const idx = try printBody(alloc, &[_]u8{ 0x02, 0x00, 0x0b, 0x0b });
    defer alloc.free(idx);
    try std.testing.expectEqualStrings("block (type 0)\nend\n", idx);

    // 0x40 alone is the empty block type, which prints no annotation.
    const empty = try printBody(alloc, &[_]u8{ 0x02, 0x40, 0x0b, 0x0b });
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("block\nend\n", empty);
}

test "a heap type is read as signed" {
    const alloc = std.testing.allocator;
    // Same 0x40 sign bit as block types. Read unsigned, extern's 0x6f would
    // print as `ref.null 111`, which names an unrelated type index.
    const wat = try printBody(alloc, &[_]u8{ 0xd0, 0x6f, 0x1a, 0x0b });
    defer alloc.free(wat);
    try std.testing.expectEqualStrings("ref.null extern\ndrop\n", wat);

    const func = try printBody(alloc, &[_]u8{ 0xd0, 0x70, 0x1a, 0x0b });
    defer alloc.free(func);
    try std.testing.expectEqualStrings("ref.null func\ndrop\n", func);
}

test "instructions whose text order differs from the binary are swapped" {
    const alloc = std.testing.allocator;

    // call_indirect encodes typeidx then tableidx, but states the table
    // first in text.
    const ci = try printBody(alloc, &[_]u8{ 0x11, 0x00, 0x03, 0x0b });
    defer alloc.free(ci);
    try std.testing.expectEqualStrings("call_indirect 3 (type 0)\n", ci);

    // memory.init encodes dataidx then memidx, and states them the other
    // way round.
    const mi = try printBody(alloc, &[_]u8{ 0xfc, 0x08, 0x07, 0x01, 0x0b });
    defer alloc.free(mi);
    try std.testing.expectEqualStrings("memory.init 1 7\n", mi);

    // memory.copy encodes destination then source, and states them in that
    // same order, so it must not be swapped.
    const mc = try printBody(alloc, &[_]u8{ 0xfc, 0x0a, 0x00, 0x01, 0x0b });
    defer alloc.free(mc);
    try std.testing.expectEqualStrings("memory.copy 0 1\n", mc);
}

test "an instruction that cannot be printed is reported, not skipped" {
    const alloc = std.testing.allocator;
    // 0x06 is the legacy exception-handling `catch`, which this writer does
    // not print. Emitting `try` and dropping its catches would produce text
    // that silently means something else, so the failure must surface.
    try std.testing.expectError(error.UnsupportedOpcode, printBody(alloc, &[_]u8{ 0x06, 0x00, 0x0b, 0x0b }));

    // A body that ends mid-immediate is truncated, not merely unknown: here
    // f32.const's four operand bytes run past the end of the body.
    try std.testing.expectError(error.TruncatedBody, printBody(alloc, &[_]u8{ 0x43, 0x00, 0x0b }));
}

test "a function restates its signature alongside its type index" {
    const alloc = std.testing.allocator;
    // (module (type (func (param i32 f64) (result i32)))
    //         (func (type 0) (param i32 f64) (result i32) local.get 0))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7c, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x20, 0x00, 0x0b,
    };
    const wat = try printBinary(alloc, &bytes);
    defer alloc.free(wat);
    // Assert on the `(func` header itself: the type section prints the same
    // signature, so searching the whole module would pass either way.
    var header: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, wat, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "(func")) header = trimmed;
    }
    // The type index alone does not survive a round trip through a module
    // whose types are renumbered, so the signature is restated too.
    try std.testing.expectEqualStrings("(func (;0;) (type 0) (param i32 f64) (result i32)", header orelse return error.NoFunc);
    try std.testing.expect(std.mem.indexOf(u8, wat, "local.get 0") != null);
}
