//! WebAssembly module optimizer.
//!
//! Performs deterministic intrafunction optimizations (constant folding,
//! control-flow simplification, dead-code elimination) and module-level
//! dead-function removal with function index remapping.

const std = @import("std");
const types = @import("types.zig");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const Feature = @import("Feature.zig");
const leb128 = @import("leb128.zig");
const instr = @import("binary/instr.zig");
const reader = @import("binary/reader.zig");
const writer = @import("binary/writer.zig");

pub const CustomSectionPolicy = enum {
    reject,
    strip,
};

pub const Options = struct {
    custom_sections: CustomSectionPolicy = .reject,
};

pub const Error = error{
    ComponentNotSupported,
    CustomSectionsPresent,
    UnsupportedFeature,
    UnsupportedOpcode,
    InvalidInput,
    InvalidOutput,
    OutOfMemory,
};

const component_version: u32 = 0x0001_000d;
const max_pass_rounds: usize = 4;

/// Optimize a binary WebAssembly module and return the optimized binary bytes.
pub fn optimize(allocator: std.mem.Allocator, wasm_bytes: []const u8, options: Options) Error![]u8 {
    if (wasm_bytes.len >= 8 and
        std.mem.eql(u8, wasm_bytes[0..4], &reader.magic) and
        std.mem.readInt(u32, wasm_bytes[4..8], .little) == component_version)
    {
        return error.ComponentNotSupported;
    }

    var module = reader.readModule(allocator, wasm_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
    defer module.deinit();

    Validator.validate(&module, .{ .features = Feature.Set.all }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LegacyExceptionsUnsupported => blk: {
            preflightDeclarations(&module) catch |pre_err| break :blk pre_err;
            break :blk error.UnsupportedOpcode;
        },
        else => error.InvalidInput,
    };

    try optimizeModule(allocator, &module, options);

    const out_bytes = writer.writeModule(allocator, &module) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutput,
    };
    errdefer allocator.free(out_bytes);

    var out_mod = reader.readModule(allocator, out_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutput,
    };
    defer out_mod.deinit();

    Validator.validate(&out_mod, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutput,
    };

    return out_bytes;
}

/// Optimize a parsed WebAssembly module in place.
pub fn optimizeModule(allocator: std.mem.Allocator, module: *Mod.Module, options: Options) Error!void {
    try preflightModule(module);

    if (module.customs.items.len > 0) {
        switch (options.custom_sections) {
            .reject => return error.CustomSectionsPresent,
            .strip => module.customs.clearRetainingCapacity(),
        }
    }

    for (module.funcs.items[module.num_func_imports..]) |*func| {
        if (func.is_import or func.code_bytes.len == 0) continue;
        try optimizeFuncBody(allocator, func);
    }

    try removeDeadFunctions(allocator, module);
}

// ── Preflight validation ─────────────────────────────────────────────────

fn isAllowedValType(vt: types.ValType, type_idx: u32) bool {
    if (type_idx != types.invalid_index) return false;
    return switch (vt) {
        .i32, .i64, .f32, .f64, .funcref, .externref => true,
        else => false,
    };
}

fn isAllowedValTypeByte(byte: u8) bool {
    return switch (byte) {
        0x7f, // i32
        0x7e, // i64
        0x7d, // f32
        0x7c, // f64
        0x70, // funcref
        0x6f, // externref
        => true,
        else => false,
    };
}

fn preflightDeclarations(module: *const Mod.Module) Error!void {
    if (module.tags.items.len > 0 or module.num_tag_imports > 0) {
        return error.UnsupportedFeature;
    }
    for (module.imports.items) |imp| {
        if (imp.kind == .tag or imp.tag != null) return error.UnsupportedFeature;
    }
    for (module.exports.items) |exp| {
        if (exp.kind == .tag) return error.UnsupportedFeature;
    }

    if (module.empty_rec_group_positions.items.len > 0) {
        return error.UnsupportedFeature;
    }
    for (module.type_meta.items) |meta| {
        if (meta.kind != .func or meta.is_sub or !meta.is_final or meta.in_rec_group or meta.parent != types.invalid_index) {
            return error.UnsupportedFeature;
        }
    }
    for (module.module_types.items) |entry| {
        switch (entry) {
            .struct_type, .array_type => return error.UnsupportedFeature,
            .func_type => |ft| {
                for (ft.params, 0..) |p, i| {
                    if (!isAllowedValType(p, Mod.FuncSignature.concreteIdxAt(ft.param_type_idxs, i))) {
                        return error.UnsupportedFeature;
                    }
                }
                for (ft.results, 0..) |r, i| {
                    if (!isAllowedValType(r, Mod.FuncSignature.concreteIdxAt(ft.result_type_idxs, i))) {
                        return error.UnsupportedFeature;
                    }
                }
            },
        }
    }

    for (module.funcs.items) |func| {
        for (func.decl.sig.params, 0..) |p, i| {
            const tidx = if (i < func.decl.sig.param_type_idxs.len) func.decl.sig.param_type_idxs[i] else types.invalid_index;
            if (!isAllowedValType(p, tidx)) return error.UnsupportedFeature;
        }
        for (func.decl.sig.results, 0..) |r, i| {
            const tidx = if (i < func.decl.sig.result_type_idxs.len) func.decl.sig.result_type_idxs[i] else types.invalid_index;
            if (!isAllowedValType(r, tidx)) return error.UnsupportedFeature;
        }
        for (func.local_types.items, 0..) |lt, i| {
            const tidx = if (i < func.local_type_idxs.items.len) func.local_type_idxs.items[i] else types.invalid_index;
            if (!isAllowedValType(lt, tidx)) return error.UnsupportedFeature;
        }
    }

    for (module.globals.items) |global| {
        if (!isAllowedValType(global.type.val_type, global.type_idx)) {
            return error.UnsupportedFeature;
        }
    }

    for (module.tables.items) |table| {
        if (!isAllowedValType(table.type.elem_type, table.type_idx)) {
            return error.UnsupportedFeature;
        }
        if (table.type.limits.is_shared or table.type.limits.usesCustomPageSize()) {
            return error.UnsupportedFeature;
        }
    }

    for (module.memories.items) |mem| {
        if (mem.type.limits.is_shared or mem.type.limits.usesCustomPageSize()) {
            return error.UnsupportedFeature;
        }
    }

    for (module.imports.items) |imp| {
        switch (imp.kind) {
            .func => if (imp.func) |f| {
                for (f.sig.params, 0..) |p, i| {
                    const tidx = if (i < f.sig.param_type_idxs.len) f.sig.param_type_idxs[i] else types.invalid_index;
                    if (!isAllowedValType(p, tidx)) return error.UnsupportedFeature;
                }
                for (f.sig.results, 0..) |r, i| {
                    const tidx = if (i < f.sig.result_type_idxs.len) f.sig.result_type_idxs[i] else types.invalid_index;
                    if (!isAllowedValType(r, tidx)) return error.UnsupportedFeature;
                }
            },
            .table => if (imp.table) |t| {
                if (!isAllowedValType(t.elem_type, imp.table_type_idx)) return error.UnsupportedFeature;
                if (t.limits.is_shared or t.limits.usesCustomPageSize()) return error.UnsupportedFeature;
            },
            .memory => if (imp.memory) |m| {
                if (m.limits.is_shared or m.limits.usesCustomPageSize()) return error.UnsupportedFeature;
            },
            .global => if (imp.global) |g| {
                if (!isAllowedValType(g.val_type, imp.global_type_idx)) return error.UnsupportedFeature;
            },
            .tag => return error.UnsupportedFeature,
        }
    }

    for (module.elem_segments.items) |seg| {
        if (seg.elem_type_idx != types.invalid_index) return error.UnsupportedFeature;
        if (seg.uses_elem_exprs) {
            if (!isAllowedValType(seg.elem_type, seg.elem_type_idx)) return error.UnsupportedFeature;
        } else {
            if (seg.elem_type != .funcref and seg.elem_type != .ref_func and seg.elem_type != .externref) {
                return error.UnsupportedFeature;
            }
        }
    }
}

fn preflightModule(module: *const Mod.Module) Error!void {
    try preflightDeclarations(module);

    for (module.funcs.items[module.num_func_imports..]) |func| {
        if (func.is_import or func.code_bytes.len == 0) continue;
        try preflightInstrBytes(module, func.code_bytes);
    }

    for (module.globals.items) |global| {
        if (!global.is_import and global.init_expr_bytes.len > 0) {
            try preflightInstrBytes(module, global.init_expr_bytes);
        }
    }

    for (module.tables.items) |table| {
        if (!table.is_import and table.hasInitExpr() and table.init_expr_bytes.len > 0) {
            try preflightInstrBytes(module, table.init_expr_bytes);
        }
    }

    for (module.elem_segments.items) |seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try preflightInstrBytes(module, seg.offset_expr_bytes);
        }
        if (seg.elem_expr_bytes.len > 0) {
            try preflightInstrBytes(module, seg.elem_expr_bytes);
        }
    }

    for (module.data_segments.items) |seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try preflightInstrBytes(module, seg.offset_expr_bytes);
        }
    }
}

fn preflightInstrBytes(module: *const Mod.Module, bytes: []const u8) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const byte = bytes[pos];
        pos += 1;

        switch (byte) {
            0xfd, 0xfe, 0xfb => return error.UnsupportedOpcode,
            0xfc => {
                const sub = readU32(bytes, &pos) catch return error.InvalidInput;
                switch (sub) {
                    0x00...0x07 => {},
                    0x08, 0x0a, 0x0c, 0x0e => {
                        _ = readU32(bytes, &pos) catch return error.InvalidInput;
                        _ = readU32(bytes, &pos) catch return error.InvalidInput;
                    },
                    0x09, 0x0b, 0x0d, 0x0f, 0x10, 0x11 => {
                        _ = readU32(bytes, &pos) catch return error.InvalidInput;
                    },
                    else => return error.UnsupportedOpcode,
                }
            },
            0x00, 0x01, 0x05, 0x0b, 0x0f, 0x1a, 0x1b, 0xd1 => {},
            0x02, 0x03, 0x04 => {
                try preflightBlockType(module, bytes, &pos);
            },
            0x0c, 0x0d, 0x10, 0x12, 0x20...0x26, 0x3f, 0x40, 0xd2 => {
                _ = readU32(bytes, &pos) catch return error.InvalidInput;
            },
            0x0e => {
                const count = readU32(bytes, &pos) catch return error.InvalidInput;
                for (0..@as(usize, count) + 1) |_| {
                    _ = readU32(bytes, &pos) catch return error.InvalidInput;
                }
            },
            0x11, 0x13 => {
                _ = readU32(bytes, &pos) catch return error.InvalidInput;
                _ = readU32(bytes, &pos) catch return error.InvalidInput;
            },
            0x1c => {
                const count = readU32(bytes, &pos) catch return error.InvalidInput;
                if (count != 1) return error.InvalidInput;
                if (pos >= bytes.len) return error.InvalidInput;
                const vt_byte = bytes[pos];
                pos += 1;
                if (!isAllowedValTypeByte(vt_byte)) {
                    return error.UnsupportedFeature;
                }
            },
            0x28...0x3e => {
                const align_flags = readU32(bytes, &pos) catch return error.InvalidInput;
                if ((align_flags & 0x40) != 0) {
                    _ = readU32(bytes, &pos) catch return error.InvalidInput;
                }
                _ = readU64(bytes, &pos) catch return error.InvalidInput;
            },
            0x41 => {
                _ = readS32(bytes, &pos) catch return error.InvalidInput;
            },
            0x42 => {
                _ = readS64(bytes, &pos) catch return error.InvalidInput;
            },
            0x43 => {
                if (pos + 4 > bytes.len) return error.InvalidInput;
                pos += 4;
            },
            0x44 => {
                if (pos + 8 > bytes.len) return error.InvalidInput;
                pos += 8;
            },
            0x45...0xc4 => {},
            0xd0 => {
                const ht = readS33(bytes, &pos) catch return error.InvalidInput;
                if (ht != -0x10 and ht != -0x11) {
                    return error.UnsupportedFeature;
                }
            },
            0x06...0x0a, 0x14, 0x15, 0x18, 0x19, 0x1f, 0xd3...0xd6 => {
                return error.UnsupportedOpcode;
            },
            else => return error.InvalidInput,
        }
    }
}

fn preflightBlockType(module: *const Mod.Module, bytes: []const u8, pos: *usize) Error!void {
    if (pos.* >= bytes.len) return error.InvalidInput;
    const byte = bytes[pos.*];
    if (byte == 0x40 or isAllowedValTypeByte(byte)) {
        pos.* += 1;
        return;
    }
    if (byte == reader.ref_null_prefix or byte == reader.ref_prefix) {
        return error.UnsupportedFeature;
    }
    if (byte >= 0x40 and byte < 0x80) {
        return error.UnsupportedFeature;
    }
    const s33 = readS33(bytes, pos) catch return error.InvalidInput;
    if (s33 < 0 or s33 > std.math.maxInt(u32)) return error.InvalidInput;
    const type_idx: u32 = @intCast(s33);
    if (type_idx >= module.module_types.items.len) return error.InvalidInput;
    switch (module.module_types.items[type_idx]) {
        .func_type => {},
        else => return error.UnsupportedFeature,
    }
}

// ── LEB128 helpers ───────────────────────────────────────────────────────

fn readU32(bytes: []const u8, pos: *usize) leb128.ReadError!u32 {
    const r = try leb128.readU32Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readU64(bytes: []const u8, pos: *usize) leb128.ReadError!u64 {
    const r = try leb128.readU64Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readS32(bytes: []const u8, pos: *usize) leb128.ReadError!i32 {
    const r = try leb128.readS32Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readS33(bytes: []const u8, pos: *usize) leb128.ReadError!i64 {
    const r = try leb128.readS33Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn readS64(bytes: []const u8, pos: *usize) leb128.ReadError!i64 {
    const r = try leb128.readS64Leb128(bytes[pos.*..]);
    pos.* += r.bytes_read;
    return r.value;
}

fn appendU32Leb(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: u32) Error!void {
    var tmp: [leb128.max_u32_bytes]u8 = undefined;
    const n = leb128.writeU32Leb128(&tmp, v);
    buf.appendSlice(allocator, tmp[0..n]) catch return error.OutOfMemory;
}

fn appendS32Leb(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: i32) Error!void {
    var tmp: [leb128.max_s32_bytes]u8 = undefined;
    const n = leb128.writeS32Leb128(&tmp, v);
    buf.appendSlice(allocator, tmp[0..n]) catch return error.OutOfMemory;
}

fn appendS64Leb(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), v: i64) Error!void {
    var tmp: [leb128.max_s64_bytes]u8 = undefined;
    const n = leb128.writeS64Leb128(&tmp, v);
    buf.appendSlice(allocator, tmp[0..n]) catch return error.OutOfMemory;
}

// ── Intrafunction AST & Passes ───────────────────────────────────────────

const BlockTypeBytes = struct {
    bytes: [leb128.max_s33_bytes]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const BlockTypeBytes) []const u8 {
        return self.bytes[0..self.len];
    }

    fn isEmpty(self: BlockTypeBytes) bool {
        return self.len == 1 and self.bytes[0] == 0x40;
    }
};

const InstrList = std.ArrayListUnmanaged(Instr);

const BlockInstr = struct {
    block_type: BlockTypeBytes,
    body: InstrList = .empty,
};

const IfInstr = struct {
    block_type: BlockTypeBytes,
    then_body: InstrList = .empty,
    has_else: bool = false,
    else_body: InstrList = .empty,
};

const Instr = union(enum) {
    unreachable_,
    nop,
    block: BlockInstr,
    loop: BlockInstr,
    if_: IfInstr,
    br: u32,
    br_if: u32,
    br_table: []u32,
    return_,
    call: u32,
    return_call: u32,
    return_call_indirect: []const u8,
    i32_const: i32,
    i64_const: i64,
    ref_func: u32,
    numeric_op: u8,
    raw: []const u8,

    fn isUnconditionalTransfer(self: Instr) bool {
        return switch (self) {
            .unreachable_,
            .br,
            .br_table,
            .return_,
            .return_call,
            .return_call_indirect,
            => true,
            else => false,
        };
    }
};

const EndKind = enum {
    end,
    else_,
};

fn readBlockTypeBytes(bytes: []const u8, pos: *usize) Error!BlockTypeBytes {
    if (pos.* >= bytes.len) return error.InvalidInput;
    const start = pos.*;
    const b = bytes[pos.*];
    if (b < 0x80) {
        pos.* += 1;
    } else {
        _ = readS33(bytes, pos) catch return error.InvalidInput;
    }
    const len = pos.* - start;
    if (len > leb128.max_s33_bytes) return error.InvalidInput;
    var bt = BlockTypeBytes{ .len = @intCast(len) };
    @memcpy(bt.bytes[0..len], bytes[start..pos.*]);
    return bt;
}

fn parseInstrBlock(
    arena: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
    allow_else: bool,
    out_list: *InstrList,
) Error!EndKind {
    while (pos.* < bytes.len) {
        const instr_start = pos.*;
        const b = bytes[pos.*];
        pos.* += 1;

        switch (b) {
            0x0b => return .end,
            0x05 => {
                if (!allow_else) return error.InvalidInput;
                return .else_;
            },
            0x00 => out_list.append(arena, .unreachable_) catch return error.OutOfMemory,
            0x01 => out_list.append(arena, .nop) catch return error.OutOfMemory,
            0x02 => {
                const bt = try readBlockTypeBytes(bytes, pos);
                var body: InstrList = .empty;
                const end_kind = try parseInstrBlock(arena, bytes, pos, false, &body);
                if (end_kind != .end) return error.InvalidInput;
                out_list.append(arena, .{ .block = .{ .block_type = bt, .body = body } }) catch return error.OutOfMemory;
            },
            0x03 => {
                const bt = try readBlockTypeBytes(bytes, pos);
                var body: InstrList = .empty;
                const end_kind = try parseInstrBlock(arena, bytes, pos, false, &body);
                if (end_kind != .end) return error.InvalidInput;
                out_list.append(arena, .{ .loop = .{ .block_type = bt, .body = body } }) catch return error.OutOfMemory;
            },
            0x04 => {
                const bt = try readBlockTypeBytes(bytes, pos);
                var then_body: InstrList = .empty;
                var else_body: InstrList = .empty;
                const end_kind = try parseInstrBlock(arena, bytes, pos, true, &then_body);
                var has_else = false;
                if (end_kind == .else_) {
                    has_else = true;
                    const else_end = try parseInstrBlock(arena, bytes, pos, false, &else_body);
                    if (else_end != .end) return error.InvalidInput;
                }
                out_list.append(arena, .{
                    .if_ = .{
                        .block_type = bt,
                        .then_body = then_body,
                        .has_else = has_else,
                        .else_body = else_body,
                    },
                }) catch return error.OutOfMemory;
            },
            0x0c => {
                const label = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .br = label }) catch return error.OutOfMemory;
            },
            0x0d => {
                const label = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .br_if = label }) catch return error.OutOfMemory;
            },
            0x0e => {
                const count = readU32(bytes, pos) catch return error.InvalidInput;
                const total = @as(usize, count) + 1;
                const targets = arena.alloc(u32, total) catch return error.OutOfMemory;
                for (0..total) |i| {
                    targets[i] = readU32(bytes, pos) catch return error.InvalidInput;
                }
                out_list.append(arena, .{ .br_table = targets }) catch return error.OutOfMemory;
            },
            0x0f => out_list.append(arena, .return_) catch return error.OutOfMemory,
            0x10 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .call = idx }) catch return error.OutOfMemory;
            },
            0x12 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .return_call = idx }) catch return error.OutOfMemory;
            },
            0x13 => {
                _ = readU32(bytes, pos) catch return error.InvalidInput;
                _ = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .return_call_indirect = bytes[instr_start..pos.*] }) catch return error.OutOfMemory;
            },
            0x41 => {
                const val = readS32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .i32_const = val }) catch return error.OutOfMemory;
            },
            0x42 => {
                const val = readS64(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .i64_const = val }) catch return error.OutOfMemory;
            },
            0x45...0xc4 => {
                out_list.append(arena, .{ .numeric_op = b }) catch return error.OutOfMemory;
            },
            0xd2 => {
                const idx = readU32(bytes, pos) catch return error.InvalidInput;
                out_list.append(arena, .{ .ref_func = idx }) catch return error.OutOfMemory;
            },
            else => {
                var probe = instr_start;
                const decoded = instr.decode(bytes, &probe) catch return error.InvalidInput;
                instr.skipImmediates(decoded.shape, bytes, &probe) catch return error.InvalidInput;
                pos.* = probe;
                out_list.append(arena, .{ .raw = bytes[instr_start..pos.*] }) catch return error.OutOfMemory;
            },
        }
    }
    return error.InvalidInput;
}

fn encodeInstrList(allocator: std.mem.Allocator, list: []const Instr, buf: *std.ArrayListUnmanaged(u8)) Error!void {
    for (list) |inst| {
        switch (inst) {
            .unreachable_ => buf.append(allocator, 0x00) catch return error.OutOfMemory,
            .nop => buf.append(allocator, 0x01) catch return error.OutOfMemory,
            .block => |b| {
                buf.append(allocator, 0x02) catch return error.OutOfMemory;
                buf.appendSlice(allocator, b.block_type.slice()) catch return error.OutOfMemory;
                try encodeInstrList(allocator, b.body.items, buf);
                buf.append(allocator, 0x0b) catch return error.OutOfMemory;
            },
            .loop => |l| {
                buf.append(allocator, 0x03) catch return error.OutOfMemory;
                buf.appendSlice(allocator, l.block_type.slice()) catch return error.OutOfMemory;
                try encodeInstrList(allocator, l.body.items, buf);
                buf.append(allocator, 0x0b) catch return error.OutOfMemory;
            },
            .if_ => |i| {
                buf.append(allocator, 0x04) catch return error.OutOfMemory;
                buf.appendSlice(allocator, i.block_type.slice()) catch return error.OutOfMemory;
                try encodeInstrList(allocator, i.then_body.items, buf);
                if (i.has_else) {
                    buf.append(allocator, 0x05) catch return error.OutOfMemory;
                    try encodeInstrList(allocator, i.else_body.items, buf);
                }
                buf.append(allocator, 0x0b) catch return error.OutOfMemory;
            },
            .br => |label| {
                buf.append(allocator, 0x0c) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, label);
            },
            .br_if => |label| {
                buf.append(allocator, 0x0d) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, label);
            },
            .br_table => |targets| {
                buf.append(allocator, 0x0e) catch return error.OutOfMemory;
                const count: u32 = @intCast(targets.len - 1);
                try appendU32Leb(allocator, buf, count);
                for (targets) |t| {
                    try appendU32Leb(allocator, buf, t);
                }
            },
            .return_ => buf.append(allocator, 0x0f) catch return error.OutOfMemory,
            .call => |idx| {
                buf.append(allocator, 0x10) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .return_call => |idx| {
                buf.append(allocator, 0x12) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .return_call_indirect => |raw| {
                buf.appendSlice(allocator, raw) catch return error.OutOfMemory;
            },
            .i32_const => |val| {
                buf.append(allocator, 0x41) catch return error.OutOfMemory;
                try appendS32Leb(allocator, buf, val);
            },
            .i64_const => |val| {
                buf.append(allocator, 0x42) catch return error.OutOfMemory;
                try appendS64Leb(allocator, buf, val);
            },
            .ref_func => |idx| {
                buf.append(allocator, 0xd2) catch return error.OutOfMemory;
                try appendU32Leb(allocator, buf, idx);
            },
            .numeric_op => |op| {
                buf.append(allocator, op) catch return error.OutOfMemory;
            },
            .raw => |raw| {
                buf.appendSlice(allocator, raw) catch return error.OutOfMemory;
            },
        }
    }
}

fn optimizeFuncBody(allocator: std.mem.Allocator, func: *Mod.Func) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pos: usize = 0;
    var root_list: InstrList = .empty;
    const end_kind = try parseInstrBlock(arena, func.code_bytes, &pos, false, &root_list);
    if (end_kind != .end or pos != func.code_bytes.len) return error.InvalidInput;

    for (0..max_pass_rounds) |_| {
        var changed = false;
        if (foldConstants(&root_list)) changed = true;
        if (try simplifyControlFlow(arena, &root_list)) changed = true;
        if (eliminateDeadCode(&root_list)) changed = true;
        if (!changed) break;
    }

    var out_buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out_buf.deinit(allocator);
    try encodeInstrList(allocator, root_list.items, &out_buf);
    out_buf.append(allocator, 0x0b) catch return error.OutOfMemory;

    const new_bytes = out_buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
    if (func.owns_code_bytes and func.code_bytes.len > 0) {
        allocator.free(func.code_bytes);
    }
    func.code_bytes = new_bytes;
    func.owns_code_bytes = true;
}

// ── Pass A: Constant Folding (i32 and i64 only) ──────────────────────────

fn foldI32Unary(a: i32, op: u8) ?Instr {
    const ua: u32 = @bitCast(a);
    return switch (op) {
        0x45 => .{ .i32_const = if (a == 0) 1 else 0 }, // i32.eqz
        0x67 => .{ .i32_const = @intCast(@clz(ua)) }, // i32.clz
        0x68 => .{ .i32_const = @intCast(@ctz(ua)) }, // i32.ctz
        0x69 => .{ .i32_const = @intCast(@popCount(ua)) }, // i32.popcnt
        0xc0 => .{ .i32_const = @as(i32, @as(i8, @truncate(a))) }, // i32.extend8_s
        0xc1 => .{ .i32_const = @as(i32, @as(i16, @truncate(a))) }, // i32.extend16_s
        else => null,
    };
}

fn foldI32Binary(a: i32, b: i32, op: u8) ?Instr {
    const ua: u32 = @bitCast(a);
    const ub: u32 = @bitCast(b);
    const shift: u5 = @truncate(ub);
    return switch (op) {
        0x6a => .{ .i32_const = a +% b }, // i32.add
        0x6b => .{ .i32_const = a -% b }, // i32.sub
        0x6c => .{ .i32_const = a *% b }, // i32.mul
        0x71 => .{ .i32_const = a & b }, // i32.and
        0x72 => .{ .i32_const = a | b }, // i32.or
        0x73 => .{ .i32_const = a ^ b }, // i32.xor
        0x74 => .{ .i32_const = @bitCast(ua << shift) }, // i32.shl
        0x75 => .{ .i32_const = a >> shift }, // i32.shr_s
        0x76 => .{ .i32_const = @bitCast(ua >> shift) }, // i32.shr_u
        0x77 => .{ .i32_const = @bitCast(std.math.rotl(u32, ua, shift)) }, // i32.rotl
        0x78 => .{ .i32_const = @bitCast(std.math.rotr(u32, ua, shift)) }, // i32.rotr
        0x46 => .{ .i32_const = if (a == b) 1 else 0 }, // i32.eq
        0x47 => .{ .i32_const = if (a != b) 1 else 0 }, // i32.ne
        0x48 => .{ .i32_const = if (a < b) 1 else 0 }, // i32.lt_s
        0x49 => .{ .i32_const = if (ua < ub) 1 else 0 }, // i32.lt_u
        0x4a => .{ .i32_const = if (a > b) 1 else 0 }, // i32.gt_s
        0x4b => .{ .i32_const = if (ua > ub) 1 else 0 }, // i32.gt_u
        0x4c => .{ .i32_const = if (a <= b) 1 else 0 }, // i32.le_s
        0x4d => .{ .i32_const = if (ua <= ub) 1 else 0 }, // i32.le_u
        0x4e => .{ .i32_const = if (a >= b) 1 else 0 }, // i32.ge_s
        0x4f => .{ .i32_const = if (ua >= ub) 1 else 0 }, // i32.ge_u
        else => null,
    };
}

fn foldI64Unary(a: i64, op: u8) ?Instr {
    const ua: u64 = @bitCast(a);
    return switch (op) {
        0x50 => .{ .i32_const = if (a == 0) 1 else 0 }, // i64.eqz
        0x79 => .{ .i64_const = @intCast(@clz(ua)) }, // i64.clz
        0x7a => .{ .i64_const = @intCast(@ctz(ua)) }, // i64.ctz
        0x7b => .{ .i64_const = @intCast(@popCount(ua)) }, // i64.popcnt
        0xc2 => .{ .i64_const = @as(i64, @as(i8, @truncate(a))) }, // i64.extend8_s
        0xc3 => .{ .i64_const = @as(i64, @as(i16, @truncate(a))) }, // i64.extend16_s
        0xc4 => .{ .i64_const = @as(i64, @as(i32, @truncate(a))) }, // i64.extend32_s
        else => null,
    };
}

fn foldI64Binary(a: i64, b: i64, op: u8) ?Instr {
    const ua: u64 = @bitCast(a);
    const ub: u64 = @bitCast(b);
    const shift: u6 = @truncate(ub);
    return switch (op) {
        0x7c => .{ .i64_const = a +% b }, // i64.add
        0x7d => .{ .i64_const = a -% b }, // i64.sub
        0x7e => .{ .i64_const = a *% b }, // i64.mul
        0x83 => .{ .i64_const = a & b }, // i64.and
        0x84 => .{ .i64_const = a | b }, // i64.or
        0x85 => .{ .i64_const = a ^ b }, // i64.xor
        0x86 => .{ .i64_const = @bitCast(ua << shift) }, // i64.shl
        0x87 => .{ .i64_const = a >> shift }, // i64.shr_s
        0x88 => .{ .i64_const = @bitCast(ua >> shift) }, // i64.shr_u
        0x89 => .{ .i64_const = @bitCast(std.math.rotl(u64, ua, shift)) }, // i64.rotl
        0x8a => .{ .i64_const = @bitCast(std.math.rotr(u64, ua, shift)) }, // i64.rotr
        0x51 => .{ .i32_const = if (a == b) 1 else 0 }, // i64.eq
        0x52 => .{ .i32_const = if (a != b) 1 else 0 }, // i64.ne
        0x53 => .{ .i32_const = if (a < b) 1 else 0 }, // i64.lt_s
        0x54 => .{ .i32_const = if (ua < ub) 1 else 0 }, // i64.lt_u
        0x55 => .{ .i32_const = if (a > b) 1 else 0 }, // i64.gt_s
        0x56 => .{ .i32_const = if (ua > ub) 1 else 0 }, // i64.gt_u
        0x57 => .{ .i32_const = if (a <= b) 1 else 0 }, // i64.le_s
        0x58 => .{ .i32_const = if (ua <= ub) 1 else 0 }, // i64.le_u
        0x59 => .{ .i32_const = if (a >= b) 1 else 0 }, // i64.ge_s
        0x5a => .{ .i32_const = if (ua >= ub) 1 else 0 }, // i64.ge_u
        else => null,
    };
}

fn foldConstants(list: *InstrList) bool {
    var changed = false;

    for (list.items) |*inst| {
        switch (inst.*) {
            .block => |*b| {
                if (foldConstants(&b.body)) changed = true;
            },
            .loop => |*l| {
                if (foldConstants(&l.body)) changed = true;
            },
            .if_ => |*i| {
                if (foldConstants(&i.then_body)) changed = true;
                if (i.has_else and foldConstants(&i.else_body)) changed = true;
            },
            else => {},
        }
    }

    var out_len: usize = 0;
    for (list.items) |inst| {
        if (inst == .numeric_op) {
            const op = inst.numeric_op;
            if (out_len >= 1) {
                switch (list.items[out_len - 1]) {
                    .i32_const => |a| {
                        if (foldI32Unary(a, op)) |folded| {
                            list.items[out_len - 1] = folded;
                            changed = true;
                            continue;
                        }
                    },
                    .i64_const => |a| {
                        if (foldI64Unary(a, op)) |folded| {
                            list.items[out_len - 1] = folded;
                            changed = true;
                            continue;
                        }
                    },
                    else => {},
                }
            }
            if (out_len >= 2) {
                if (list.items[out_len - 2] == .i32_const and list.items[out_len - 1] == .i32_const) {
                    const a = list.items[out_len - 2].i32_const;
                    const b = list.items[out_len - 1].i32_const;
                    if (foldI32Binary(a, b, op)) |folded| {
                        list.items[out_len - 2] = folded;
                        out_len -= 1;
                        changed = true;
                        continue;
                    }
                } else if (list.items[out_len - 2] == .i64_const and list.items[out_len - 1] == .i64_const) {
                    const a = list.items[out_len - 2].i64_const;
                    const b = list.items[out_len - 1].i64_const;
                    if (foldI64Binary(a, b, op)) |folded| {
                        list.items[out_len - 2] = folded;
                        out_len -= 1;
                        changed = true;
                        continue;
                    }
                }
            }
        }
        list.items[out_len] = inst;
        out_len += 1;
    }
    list.shrinkRetainingCapacity(out_len);
    return changed;
}

// ── Pass B: Control-Flow Simplification ──────────────────────────────────

fn hasBranchToDepth(instrs: []const Instr, target_depth: u32) bool {
    for (instrs) |inst| {
        switch (inst) {
            .br => |l| if (l == target_depth) return true,
            .br_if => |l| if (l == target_depth) return true,
            .br_table => |targets| {
                for (targets) |l| {
                    if (l == target_depth) return true;
                }
            },
            .block => |b| if (hasBranchToDepth(b.body.items, target_depth + 1)) return true,
            .loop => |l| if (hasBranchToDepth(l.body.items, target_depth + 1)) return true,
            .if_ => |i| {
                if (hasBranchToDepth(i.then_body.items, target_depth + 1)) return true;
                if (i.has_else and hasBranchToDepth(i.else_body.items, target_depth + 1)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn canInlineBlock(body: []const Instr) bool {
    for (body) |inst| {
        if (inst.isUnconditionalTransfer()) return false;
    }
    return !hasBranchToDepth(body, 0);
}

fn decrementOuterLabels(instrs: []Instr, min_depth: u32) void {
    for (instrs) |*inst| {
        switch (inst.*) {
            .br => |*l| if (l.* > min_depth) {
                l.* -= 1;
            },
            .br_if => |*l| if (l.* > min_depth) {
                l.* -= 1;
            },
            .br_table => |targets| {
                for (targets) |*l| {
                    if (l.* > min_depth) l.* -= 1;
                }
            },
            .block => |*b| decrementOuterLabels(b.body.items, min_depth + 1),
            .loop => |*l| decrementOuterLabels(l.body.items, min_depth + 1),
            .if_ => |*i| {
                decrementOuterLabels(i.then_body.items, min_depth + 1);
                if (i.has_else) decrementOuterLabels(i.else_body.items, min_depth + 1);
            },
            else => {},
        }
    }
}

fn simplifyControlFlow(arena: std.mem.Allocator, list: *InstrList) Error!bool {
    var changed = false;

    for (list.items) |*inst| {
        switch (inst.*) {
            .block => |*b| {
                if (try simplifyControlFlow(arena, &b.body)) changed = true;
            },
            .loop => |*l| {
                if (try simplifyControlFlow(arena, &l.body)) changed = true;
            },
            .if_ => |*i| {
                if (try simplifyControlFlow(arena, &i.then_body)) changed = true;
                if (i.has_else and try simplifyControlFlow(arena, &i.else_body)) changed = true;
            },
            else => {},
        }
    }

    var out: InstrList = .empty;
    out.ensureTotalCapacity(arena, list.items.len) catch return error.OutOfMemory;

    for (list.items) |inst| {
        switch (inst) {
            .nop => {
                changed = true;
                continue;
            },
            .br_if => |label| {
                if (out.items.len > 0 and out.items[out.items.len - 1] == .i32_const) {
                    const cond = out.pop().?.i32_const;
                    changed = true;
                    if (cond != 0) {
                        out.append(arena, .{ .br = label }) catch return error.OutOfMemory;
                    }
                    continue;
                }
            },
            .if_ => |if_inst| {
                if (out.items.len > 0 and out.items[out.items.len - 1] == .i32_const) {
                    const cond = out.pop().?.i32_const;
                    changed = true;
                    const chosen_body = if (cond != 0) if_inst.then_body else if_inst.else_body;
                    if (canInlineBlock(chosen_body.items)) {
                        decrementOuterLabels(chosen_body.items, 0);
                        out.appendSlice(arena, chosen_body.items) catch return error.OutOfMemory;
                    } else {
                        out.append(arena, .{
                            .block = .{
                                .block_type = if_inst.block_type,
                                .body = chosen_body,
                            },
                        }) catch return error.OutOfMemory;
                    }
                    continue;
                }
            },
            .block => |b_inst| {
                if ((b_inst.block_type.isEmpty() and b_inst.body.items.len == 0) or
                    canInlineBlock(b_inst.body.items))
                {
                    changed = true;
                    decrementOuterLabels(b_inst.body.items, 0);
                    out.appendSlice(arena, b_inst.body.items) catch return error.OutOfMemory;
                    continue;
                }
            },
            else => {},
        }
        out.append(arena, inst) catch return error.OutOfMemory;
    }

    list.* = out;
    return changed;
}

// ── Pass C: Dead-Code Elimination (Intrafunction) ────────────────────────

fn eliminateDeadCode(list: *InstrList) bool {
    var changed = false;

    for (list.items, 0..) |*inst, i| {
        switch (inst.*) {
            .block => |*b| {
                if (eliminateDeadCode(&b.body)) changed = true;
            },
            .loop => |*l| {
                if (eliminateDeadCode(&l.body)) changed = true;
            },
            .if_ => |*if_inst| {
                if (eliminateDeadCode(&if_inst.then_body)) changed = true;
                if (if_inst.has_else and eliminateDeadCode(&if_inst.else_body)) changed = true;
            },
            else => {},
        }

        if (inst.isUnconditionalTransfer()) {
            if (i + 1 < list.items.len) {
                list.shrinkRetainingCapacity(i + 1);
                changed = true;
            }
            break;
        }
    }

    return changed;
}

// ── Dead-function removal and index remapping ────────────────────────────

fn markLiveFunc(
    num_funcs: usize,
    live: []bool,
    worklist: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    idx: u32,
) Error!void {
    if (idx >= num_funcs) return;
    if (!live[idx]) {
        live[idx] = true;
        worklist.append(allocator, idx) catch return error.OutOfMemory;
    }
}

fn scanExprFuncRefs(
    bytes: []const u8,
    num_funcs: usize,
    live: []bool,
    worklist: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
        if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12 or decoded.code == 0xd2)) {
            const idx = readU32(bytes, &pos) catch return error.InvalidInput;
            try markLiveFunc(num_funcs, live, worklist, allocator, idx);
        } else {
            instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
        }
    }
}

fn rewriteExprFuncIndices(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    old_to_new: []const u32,
) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    out.ensureTotalCapacity(allocator, bytes.len) catch return error.OutOfMemory;

    var pos: usize = 0;
    while (pos < bytes.len) {
        const start = pos;
        const decoded = instr.decode(bytes, &pos) catch return error.InvalidInput;
        if (decoded.prefix == 0 and (decoded.code == 0x10 or decoded.code == 0x12 or decoded.code == 0xd2)) {
            const old_idx = readU32(bytes, &pos) catch return error.InvalidInput;
            if (old_idx >= old_to_new.len) return error.InvalidInput;
            const new_idx = old_to_new[old_idx];
            out.append(allocator, @intCast(decoded.code)) catch return error.OutOfMemory;
            try appendU32Leb(allocator, &out, new_idx);
        } else {
            instr.skipImmediates(decoded.shape, bytes, &pos) catch return error.InvalidInput;
            out.appendSlice(allocator, bytes[start..pos]) catch return error.OutOfMemory;
        }
    }

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn removeDeadFunctions(allocator: std.mem.Allocator, module: *Mod.Module) Error!void {
    const num_funcs = module.funcs.items.len;
    if (num_funcs <= module.num_func_imports) return;

    const live = allocator.alloc(bool, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(live);
    @memset(live, false);

    var worklist: std.ArrayListUnmanaged(u32) = .empty;
    defer worklist.deinit(allocator);

    for (0..module.num_func_imports) |i| {
        try markLiveFunc(num_funcs, live, &worklist, allocator, @intCast(i));
    }

    for (module.exports.items) |exp| {
        if (exp.kind == .func and exp.var_ == .index) {
            try markLiveFunc(num_funcs, live, &worklist, allocator, exp.var_.index);
        }
    }

    if (module.start_var) |sv| {
        if (sv == .index) {
            try markLiveFunc(num_funcs, live, &worklist, allocator, sv.index);
        }
    }

    for (module.elem_segments.items) |seg| {
        for (seg.elem_var_indices.items) |v| {
            if (v == .index and v.index != types.invalid_index) {
                try markLiveFunc(num_funcs, live, &worklist, allocator, v.index);
            }
        }
        if (seg.elem_expr_bytes.len > 0) {
            try scanExprFuncRefs(seg.elem_expr_bytes, num_funcs, live, &worklist, allocator);
        }
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try scanExprFuncRefs(seg.offset_expr_bytes, num_funcs, live, &worklist, allocator);
        }
    }

    for (module.globals.items) |global| {
        if (!global.is_import and global.init_expr_bytes.len > 0) {
            try scanExprFuncRefs(global.init_expr_bytes, num_funcs, live, &worklist, allocator);
        }
    }

    for (module.tables.items) |table| {
        if (!table.is_import and table.hasInitExpr() and table.init_expr_bytes.len > 0) {
            try scanExprFuncRefs(table.init_expr_bytes, num_funcs, live, &worklist, allocator);
        }
    }

    for (module.data_segments.items) |seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            try scanExprFuncRefs(seg.offset_expr_bytes, num_funcs, live, &worklist, allocator);
        }
    }

    while (worklist.items.len > 0) {
        const fidx = worklist.pop().?;
        if (fidx < module.num_func_imports or fidx >= num_funcs) continue;
        const func = module.funcs.items[fidx];
        if (func.code_bytes.len > 0) {
            try scanExprFuncRefs(func.code_bytes, num_funcs, live, &worklist, allocator);
        }
    }

    var all_live = true;
    for (live) |is_live| {
        if (!is_live) {
            all_live = false;
            break;
        }
    }
    if (all_live) return;

    const old_to_new = allocator.alloc(u32, num_funcs) catch return error.OutOfMemory;
    defer allocator.free(old_to_new);
    var next_idx: u32 = 0;
    for (0..num_funcs) |i| {
        if (live[i]) {
            old_to_new[i] = next_idx;
            next_idx += 1;
        } else {
            old_to_new[i] = types.invalid_index;
        }
    }

    // Rewrite function indices in live defined functions before compacting module.funcs.
    for (module.funcs.items, 0..) |*func, i| {
        if (!live[i] or i < module.num_func_imports or func.code_bytes.len == 0) continue;
        const rewritten = try rewriteExprFuncIndices(module.allocator, func.code_bytes, old_to_new);
        if (func.owns_code_bytes and func.code_bytes.len > 0) {
            module.allocator.free(func.code_bytes);
        }
        func.code_bytes = rewritten;
        func.owns_code_bytes = true;
    }

    for (module.elem_segments.items) |*seg| {
        for (seg.elem_var_indices.items) |*v| {
            if (v.* == .index and v.index < num_funcs) {
                v.index = old_to_new[v.index];
            }
        }
        if (seg.elem_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, seg.elem_expr_bytes, old_to_new);
            if (seg.owns_elem_expr_bytes and seg.elem_expr_bytes.len > 0) {
                module.allocator.free(seg.elem_expr_bytes);
            }
            seg.elem_expr_bytes = rewritten;
            seg.owns_elem_expr_bytes = true;
        }
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, seg.offset_expr_bytes, old_to_new);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                module.allocator.free(seg.offset_expr_bytes);
            }
            seg.offset_expr_bytes = rewritten;
            seg.owns_offset_expr_bytes = true;
        }
    }

    for (module.globals.items) |*global| {
        if (!global.is_import and global.init_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, global.init_expr_bytes, old_to_new);
            if (global.owns_init_expr_bytes and global.init_expr_bytes.len > 0) {
                module.allocator.free(global.init_expr_bytes);
            }
            global.init_expr_bytes = rewritten;
            global.owns_init_expr_bytes = true;
        }
    }

    for (module.tables.items) |*table| {
        if (!table.is_import and table.hasInitExpr() and table.init_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, table.init_expr_bytes, old_to_new);
            if (table.owns_init_expr_bytes and table.init_expr_bytes.len > 0) {
                module.allocator.free(table.init_expr_bytes);
            }
            table.init_expr_bytes = rewritten;
            table.owns_init_expr_bytes = true;
        }
    }

    for (module.data_segments.items) |*seg| {
        if (seg.kind == .active and seg.offset_expr_bytes.len > 0) {
            const rewritten = try rewriteExprFuncIndices(module.allocator, seg.offset_expr_bytes, old_to_new);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                module.allocator.free(seg.offset_expr_bytes);
            }
            seg.offset_expr_bytes = rewritten;
            seg.owns_offset_expr_bytes = true;
        }
    }

    for (module.exports.items) |*exp| {
        if (exp.kind == .func and exp.var_ == .index and exp.var_.index < num_funcs) {
            exp.var_.index = old_to_new[exp.var_.index];
        }
    }

    if (module.start_var) |*sv| {
        if (sv.* == .index and sv.index < num_funcs) {
            sv.index = old_to_new[sv.index];
        }
    }

    var write_idx: usize = 0;
    for (module.funcs.items, 0..) |*func, i| {
        if (live[i]) {
            module.funcs.items[write_idx] = func.*;
            write_idx += 1;
        } else {
            func.local_types.deinit(module.allocator);
            func.local_type_idxs.deinit(module.allocator);
            if (func.owns_code_bytes and func.code_bytes.len > 0) {
                module.allocator.free(func.code_bytes);
            }
        }
    }
    module.funcs.shrinkRetainingCapacity(write_idx);
}

// ── Unit Tests ───────────────────────────────────────────────────────────

const Parser = @import("text/Parser.zig");
const WatWriter = @import("text/Writer.zig");
const testing = std.testing;

fn watToWasm(allocator: std.mem.Allocator, wat: []const u8) ![]u8 {
    var module = try Parser.parseModule(allocator, wat);
    defer module.deinit();
    return try writer.writeModule(allocator, &module);
}

const OptimizedModule = struct {
    allocator: std.mem.Allocator,
    wasm: []u8,
    module: Mod.Module,

    fn deinit(self: *OptimizedModule) void {
        self.module.deinit();
        self.allocator.free(self.wasm);
    }
};

fn optimizeWat(allocator: std.mem.Allocator, wat: []const u8, options: Options) !OptimizedModule {
    const wasm = try watToWasm(allocator, wat);
    defer allocator.free(wasm);
    const opt_wasm = try optimize(allocator, wasm, options);
    errdefer allocator.free(opt_wasm);
    const mod = try reader.readModule(allocator, opt_wasm);
    return .{
        .allocator = allocator,
        .wasm = opt_wasm,
        .module = mod,
    };
}

test "i32 constant folding arithmetic, bitops, shifts, unary, and comparisons" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (func (export "arith") (result i32)
        \\    (i32.add
        \\      (i32.mul (i32.const 6) (i32.const 7))
        \\      (i32.sub (i32.const 10) (i32.const 2))))
        \\  (func (export "wrap") (result i32)
        \\    (i32.add (i32.const 0x7fffffff) (i32.const 1)))
        \\  (func (export "bitops") (result i32)
        \\    (i32.xor
        \\      (i32.or (i32.const 0xf0) (i32.const 0x0f))
        \\      (i32.and (i32.const 0xff) (i32.const 0x55))))
        \\  (func (export "shifts") (result i32)
        \\    (i32.add
        \\      (i32.add
        \\        (i32.shl (i32.const 1) (i32.const 35))
        \\        (i32.shr_s (i32.const -16) (i32.const 34)))
        \\      (i32.add
        \\        (i32.shr_u (i32.const -16) (i32.const 30))
        \\        (i32.rotl (i32.rotr (i32.const 0x12345678) (i32.const 4)) (i32.const 4)))))
        \\  (func (export "unary") (result i32)
        \\    (i32.add
        \\      (i32.add
        \\        (i32.eqz (i32.const 0))
        \\        (i32.clz (i32.const 0x00010000)))
        \\      (i32.add
        \\        (i32.add (i32.ctz (i32.const 8)) (i32.popcnt (i32.const 0x2d)))
        \\        (i32.add (i32.extend8_s (i32.const 0x80)) (i32.extend16_s (i32.const 0xff80))))))
        \\  (func (export "cmp") (result i32)
        \\    (i32.add
        \\      (i32.add
        \\        (i32.add (i32.eq (i32.const 5) (i32.const 5)) (i32.ne (i32.const 5) (i32.const 6)))
        \\        (i32.add (i32.lt_s (i32.const -1) (i32.const 1)) (i32.lt_u (i32.const -1) (i32.const 1))))
        \\      (i32.add
        \\        (i32.add (i32.gt_s (i32.const 2) (i32.const -2)) (i32.gt_u (i32.const -1) (i32.const 1)))
        \\        (i32.add
        \\          (i32.add (i32.le_s (i32.const 3) (i32.const 3)) (i32.le_u (i32.const 1) (i32.const -1)))
        \\          (i32.add (i32.ge_s (i32.const -1) (i32.const -1)) (i32.ge_u (i32.const -1) (i32.const 1)))))))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    const expected_vals = [_]i32{
        50, // arith: 42 + 8
        @bitCast(@as(u32, 0x80000000)), // wrap
        0xaa, // bitops: 0xff ^ 0x55
        (1 << 3) + (-4) + 3 + 0x12345678, // shifts
        1 + 15 + 3 + 4 + (-128) + (-128), // unary
        1 + 1 + 1 + 0 + 1 + 1 + 1 + 1 + 1 + 1, // cmp = 9
    };

    try testing.expectEqual(expected_vals.len, opt_mod.funcs.items.len);
    for (expected_vals, 0..) |expected, i| {
        const bytes = opt_mod.funcs.items[i].code_bytes;
        try testing.expect(bytes.len >= 2);
        try testing.expectEqual(@as(u8, 0x41), bytes[0]);
        var pos: usize = 1;
        const actual = try readS32(bytes, &pos);
        try testing.expectEqual(expected, actual);
        try testing.expectEqual(@as(u8, 0x0b), bytes[pos]);
        try testing.expectEqual(bytes.len, pos + 1);
    }
}

test "i64 constant folding arithmetic, bitops, shifts, unary, and comparisons" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (func (export "arith64") (result i64)
        \\    (i64.add
        \\      (i64.mul (i64.const 1000000) (i64.const 2000000))
        \\      (i64.sub (i64.const 50) (i64.const 8))))
        \\  (func (export "bitops64") (result i64)
        \\    (i64.rotr
        \\      (i64.rotl
        \\        (i64.xor
        \\          (i64.or (i64.const 0xf0f0) (i64.const 0x0f0f))
        \\          (i64.and (i64.const 0xffff) (i64.const 0x5555)))
        \\        (i64.const 72))
        \\      (i64.const 8)))
        \\  (func (export "shifts64") (result i64)
        \\    (i64.add
        \\      (i64.shl (i64.const 1) (i64.const 68))
        \\      (i64.add
        \\        (i64.shr_s (i64.const -32) (i64.const 66))
        \\        (i64.shr_u (i64.const -2) (i64.const 63)))))
        \\  (func (export "unary64") (result i64)
        \\    (i64.add
        \\      (i64.add (i64.clz (i64.const 1)) (i64.ctz (i64.const 16)))
        \\      (i64.add
        \\        (i64.popcnt (i64.const 0xff))
        \\        (i64.add
        \\          (i64.extend8_s (i64.const 0x80))
        \\          (i64.add (i64.extend16_s (i64.const 0x8000)) (i64.extend32_s (i64.const 0x80000000)))))))
        \\  (func (export "cmp64") (result i32)
        \\    (i32.add
        \\      (i64.eqz (i64.const 0))
        \\      (i32.add
        \\        (i32.add (i64.eq (i64.const 9) (i64.const 9)) (i64.ne (i64.const 9) (i64.const 8)))
        \\        (i32.add
        \\          (i32.add (i64.lt_s (i64.const -5) (i64.const 5)) (i64.lt_u (i64.const -5) (i64.const 5)))
        \\          (i32.add
        \\            (i32.add (i64.gt_s (i64.const 5) (i64.const -5)) (i64.gt_u (i64.const -5) (i64.const 5)))
        \\            (i32.add
        \\              (i32.add (i64.le_s (i64.const -5) (i64.const -5)) (i64.le_u (i64.const 5) (i64.const -5)))
        \\              (i32.add (i64.ge_s (i64.const 5) (i64.const 5)) (i64.ge_u (i64.const -5) (i64.const 5)))))))))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    const expected_i64 = [_]i64{
        2000000000042,
        0xaaaa,
        16 + (-8) + 1,
        63 + 4 + 8 + (-128) + (-32768) + (-2147483648),
    };
    for (expected_i64, 0..) |expected, i| {
        const bytes = opt_mod.funcs.items[i].code_bytes;
        try testing.expectEqual(@as(u8, 0x42), bytes[0]);
        var pos: usize = 1;
        const actual = try readS64(bytes, &pos);
        try testing.expectEqual(expected, actual);
        try testing.expectEqual(@as(u8, 0x0b), bytes[pos]);
    }

    // cmp64 returns i32.const 10
    const cmp_bytes = opt_mod.funcs.items[4].code_bytes;
    try testing.expectEqual(@as(u8, 0x41), cmp_bytes[0]);
    var pos: usize = 1;
    try testing.expectEqual(@as(i32, 10), try readS32(cmp_bytes, &pos));
    try testing.expectEqual(@as(u8, 0x0b), cmp_bytes[pos]);
}

test "division, remainder, and float operations are not constant-folded" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (func (export "div_zero") (result i32)
        \\    (i32.div_s (i32.const 1) (i32.const 0)))
        \\  (func (export "div_overflow") (result i32)
        \\    (i32.div_s (i32.const -2147483648) (i32.const -1)))
        \\  (func (export "rem_zero") (result i64)
        \\    (i64.rem_u (i64.const 10) (i64.const 0)))
        \\  (func (export "float_nan") (result f32)
        \\    (f32.add (f32.const nan:0x200000) (f32.const 1.0)))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    // Ensure i32.div_s (0x6d), i64.rem_u (0x82), and f32.add (0x92) remain present
    try testing.expect(std.mem.indexOfScalar(u8, opt_mod.funcs.items[0].code_bytes, 0x6d) != null);
    try testing.expect(std.mem.indexOfScalar(u8, opt_mod.funcs.items[1].code_bytes, 0x6d) != null);
    try testing.expect(std.mem.indexOfScalar(u8, opt_mod.funcs.items[2].code_bytes, 0x82) != null);
    try testing.expect(std.mem.indexOfScalar(u8, opt_mod.funcs.items[3].code_bytes, 0x92) != null);
}

test "control-flow simplification: nop, constant if, constant br_if, nested labels, and multi-value block types" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (type $pair (func (result i32 i32)))
        \\  (func (export "const_if_true") (result i32)
        \\    (nop)
        \\    (if (result i32) (i32.const 1)
        \\      (then (nop) (i32.add (i32.const 20) (i32.const 22)))
        \\      (else (i32.const 99))))
        \\  (func (export "const_if_false_no_else") (result i32)
        \\    (if (i32.const 0)
        \\      (then (unreachable)))
        \\    (i32.const 7))
        \\  (func (export "const_if_with_self_branch") (param i32) (result i32)
        \\    (if (result i32) (i32.const 1)
        \\      (then
        \\        (i32.const 11)
        \\        (br_if 0 (local.get 0))
        \\        (drop)
        \\        (i32.const 22))
        \\      (else
        \\        (i32.const 33))))
        \\  (func (export "const_if_with_outer_branch") (param i32) (result i32)
        \\    (block (result i32)
        \\      (if (result i32) (i32.const 1)
        \\        (then
        \\          (if (local.get 0)
        \\            (then (br 2 (i32.const 55))))
        \\          (i32.const 66))
        \\        (else
        \\          (i32.const 77)))))
        \\  (func (export "const_br_if") (result i32)
        \\    (block (result i32)
        \\      (i32.const 10)
        \\      (br_if 0 (i32.const 0))
        \\      (drop)
        \\      (i32.const 25)
        \\      (br_if 0 (i32.const 3))
        \\      (drop)
        \\      (i32.const 99)))
        \\  (func (export "multivalue_if") (type $pair)
        \\    (if (type $pair) (i32.const 0)
        \\      (then (i32.const 1) (i32.const 2))
        \\      (else (i32.const 3) (i32.const 4))))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    // Func 0: folds to i32.const 42, end
    try testing.expectEqualSlices(u8, &.{ 0x41, 42, 0x0b }, opt_mod.funcs.items[0].code_bytes);

    // Func 1: folds to i32.const 7, end
    try testing.expectEqualSlices(u8, &.{ 0x41, 7, 0x0b }, opt_mod.funcs.items[1].code_bytes);

    // Func 2: keeps block wrapper because br_if 0 targets the if/block itself
    try testing.expectEqual(@as(u8, 0x02), opt_mod.funcs.items[2].code_bytes[0]);

    // Func 5: multi-value if (false branch) inlined to i32.const 3, i32.const 4, end
    try testing.expectEqualSlices(u8, &.{ 0x41, 3, 0x41, 4, 0x0b }, opt_mod.funcs.items[5].code_bytes);
}

test "intrafunction dead-code elimination preserves prior side effects and structured delimiters" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (memory 1)
        \\  (global $g (mut i32) (i32.const 0))
        \\  (func (export "dce") (param i32) (result i32)
        \\    (global.set $g (i32.const 1))
        \\    (i32.store (i32.const 0) (i32.const 2))
        \\    (if (result i32) (local.get 0)
        \\      (then
        \\        (return (i32.const 10))
        \\        (global.set $g (i32.const 999))
        \\        (i32.const 20))
        \\      (else
        \\        (unreachable)
        \\        (i32.const 30)))
        \\    (return)
        \\    (i32.const 40))
        \\  (func (export "dce_br_table") (param i32) (result i32)
        \\    (block (result i32)
        \\      (i32.const 7)
        \\      (local.get 0)
        \\      (br_table 0 0)
        \\      (global.set $g (i32.const 888))
        \\      (i32.const 99)))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    const printed = try WatWriter.writeModule(allocator, opt_mod);
    defer allocator.free(printed);

    // Side effects before return/unreachable are kept
    try testing.expect(std.mem.indexOf(u8, printed, "global.set") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "i32.store") != null);
    // Dead stores after return/br_table/unreachable are removed
    try testing.expect(std.mem.indexOf(u8, printed, "999") == null);
    try testing.expect(std.mem.indexOf(u8, printed, "888") == null);
}

test "dead-function removal and index remapping across all root kinds" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (import "env" "imp0" (func $imp0))
        \\  (import "env" "imp1" (func $imp1 (result i32)))
        \\  (table $t 2 funcref)
        \\  (global $g funcref (ref.func $from_global))
        \\  (start $start_fn)
        \\  (elem (i32.const 0) func $from_elem_idx)
        \\  (elem declare func $from_declared_elem $callee_by_ref)
        \\  (elem funcref (ref.func $from_elem_expr))
        \\  (func $dead0 (result i32) (i32.const 111))
        \\  (func $start_fn (call $imp0) (call $callee_of_start))
        \\  (func $dead1 (call $dead0) (drop))
        \\  (func $callee_of_start)
        \\  (func $from_elem_idx)
        \\  (func $from_declared_elem)
        \\  (func $from_elem_expr)
        \\  (func $from_global)
        \\  (func $dead_after_const_if (result i32) (i32.const 222))
        \\  (func $callee_by_ref)
        \\  (func $exported (export "run") (result i32)
        \\    (drop (ref.func $callee_by_ref))
        \\    (if (result i32) (i32.eq (i32.const 2) (i32.const 3))
        \\      (then (call $dead_after_const_if))
        \\      (else (return_call $imp1))))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    // Total functions before: 2 imports + 11 defined = 13.
    // Dead defined functions: $dead0, $dead1, $dead_after_const_if (3 removed).
    // Remaining: 2 imports + 8 defined = 10.
    try testing.expectEqual(@as(u32, 2), opt_mod.num_func_imports);
    try testing.expectEqual(@as(usize, 10), opt_mod.funcs.items.len);

    // Export "run" should point to the last live function (index 9)
    const exp = opt_mod.getExport("run").?;
    try testing.expectEqual(@as(u32, 9), exp.var_.index);

    // Start function ($start_fn was index 3 -> now index 2)
    try testing.expectEqual(@as(u32, 2), opt_mod.start_var.?.index);
}

test "table init expr ref.func keeps target function live and remaps index" {
    const allocator = testing.allocator;
    const wat =
        \\(module
        \\  (func $dead)
        \\  (func $table_init_target)
        \\  (table 1 funcref (ref.func $table_init_target))
        \\)
    ;

    var opt = try optimizeWat(allocator, wat, .{});
    defer opt.deinit();
    const opt_mod = &opt.module;

    // $dead (index 0) is removed; $table_init_target (index 1 -> 0) is kept
    try testing.expectEqual(@as(usize, 1), opt_mod.funcs.items.len);
    try testing.expectEqualSlices(u8, &.{ 0xd2, 0x00 }, opt_mod.tables.items[0].init_expr_bytes);
}

test "custom section policy reject vs strip" {
    const allocator = testing.allocator;
    var module = try Parser.parseModule(allocator, "(module (func (export \"f\") (result i32) (i32.add (i32.const 1) (i32.const 2))))");
    defer module.deinit();
    try module.customs.append(allocator, .{ .name = "custom_test", .data = "payload" });

    const wasm_with_custom = try writer.writeModule(allocator, &module);
    defer allocator.free(wasm_with_custom);

    // Default policy (.reject) rejects modules with custom sections
    try testing.expectError(error.CustomSectionsPresent, optimize(allocator, wasm_with_custom, .{}));

    // .strip policy strips custom sections and optimizes the module
    const stripped_wasm = try optimize(allocator, wasm_with_custom, .{ .custom_sections = .strip });
    defer allocator.free(stripped_wasm);

    var out_mod = try reader.readModule(allocator, stripped_wasm);
    defer out_mod.deinit();
    try testing.expectEqual(@as(usize, 0), out_mod.customs.items.len);
    try testing.expectEqualSlices(u8, &.{ 0x41, 3, 0x0b }, out_mod.funcs.items[0].code_bytes);
}

test "reject component binary and unsupported features/opcodes" {
    const allocator = testing.allocator;

    // 1. Component preamble
    const component_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
    try testing.expectError(error.ComponentNotSupported, optimize(allocator, &component_bytes, .{}));

    // 2. SIMD v128 type -> UnsupportedFeature
    {
        const wasm = try watToWasm(allocator, "(module (func (param v128)))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedFeature, optimize(allocator, wasm, .{}));
    }

    // 3. SIMD opcode without v128 signature -> UnsupportedOpcode
    {
        const wasm = try watToWasm(allocator, "(module (func (drop (v128.const i32x4 0 0 0 0))))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedOpcode, optimize(allocator, wasm, .{}));
    }

    // 4. Shared memory -> UnsupportedFeature, atomic opcode -> UnsupportedOpcode
    {
        const wasm = try watToWasm(allocator, "(module (memory 1 1 shared))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedFeature, optimize(allocator, wasm, .{}));
    }
    {
        const wasm = try watToWasm(allocator, "(module (memory 1) (func (drop (i32.atomic.load (i32.const 0)))))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedOpcode, optimize(allocator, wasm, .{}));
    }

    // 5. GC struct type -> UnsupportedFeature, GC ref.i31 opcode -> UnsupportedOpcode
    {
        const wasm = try watToWasm(allocator, "(module (type (struct)))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedFeature, optimize(allocator, wasm, .{}));
    }
    {
        const wasm = try watToWasm(allocator, "(module (func (drop (ref.i31 (i32.const 0)))))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedOpcode, optimize(allocator, wasm, .{}));
    }

    // 6. Exception handling tag -> UnsupportedFeature, try_table -> UnsupportedOpcode
    {
        const wasm = try watToWasm(allocator, "(module (tag (param i32)))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedFeature, optimize(allocator, wasm, .{}));
    }
    {
        const wasm = try watToWasm(allocator, "(module (func (block (try_table (catch_all 0) (nop)))))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedOpcode, optimize(allocator, wasm, .{}));
    }

    // 7. Typed function references: call_ref -> UnsupportedOpcode
    {
        const wasm = try watToWasm(allocator, "(module (type $t (func)) (func (param (ref null $t)) (call_ref $t (local.get 0))))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedFeature, optimize(allocator, wasm, .{}));
    }
    {
        const wasm = try watToWasm(allocator, "(module (func (param funcref) (drop (ref.as_non_null (local.get 0)))))");
        defer allocator.free(wasm);
        try testing.expectError(error.UnsupportedOpcode, optimize(allocator, wasm, .{}));
    }
}
