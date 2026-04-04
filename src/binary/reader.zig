//! WebAssembly binary format reader.
//!
//! Reads a .wasm binary file and produces a Module IR.
//! Implements the binary encoding specified in the WebAssembly spec.

const std = @import("std");
const leb128 = @import("../leb128.zig");
const types = @import("../types.zig");
const Mod = @import("../Module.zig");

pub const magic = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
pub const version: u32 = 1;

pub const SectionId = enum(u8) {
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    tag = 13,
};

pub const ReadError = error{
    InvalidMagic,
    InvalidVersion,
    UnexpectedEof,
    InvalidSection,
    InvalidType,
    InvalidLimits,
    TooManyLocals,
    SectionTooLarge,
    FunctionCodeMismatch,
    OutOfMemory,
};

// ── Public API ──────────────────────────────────────────────────────────

pub fn readModule(allocator: std.mem.Allocator, bytes: []const u8) ReadError!Mod.Module {
    if (bytes.len < 8) return error.UnexpectedEof;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidMagic;
    const ver = std.mem.readInt(u32, bytes[4..8], .little);
    if (ver != version) return error.InvalidVersion;

    var module = Mod.Module.init(allocator);
    errdefer module.deinit();

    var r = Reader{ .data = bytes, .pos = 8, .allocator = allocator, .module = &module };
    try r.readSections();

    return module;
}

/// Safe enum cast: returns null if the integer doesn't match any tag.
fn enumFromIntChecked(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (value == field.value) return @enumFromInt(value);
    }
    return null;
}

// ── Internal reader ─────────────────────────────────────────────────────

const Reader = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    module: *Mod.Module,

    // -- primitives --

    fn readByte(self: *Reader) ReadError!u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readBytes(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEof;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn readU32(self: *Reader) ReadError!u32 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const result = leb128.readU32Leb128(self.data[self.pos..]) catch return error.UnexpectedEof;
        self.pos += result.bytes_read;
        return result.value;
    }

    fn readS32(self: *Reader) ReadError!i32 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const result = leb128.readS32Leb128(self.data[self.pos..]) catch return error.UnexpectedEof;
        self.pos += result.bytes_read;
        return result.value;
    }

    fn readU64(self: *Reader) ReadError!u64 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const result = leb128.readU64Leb128(self.data[self.pos..]) catch return error.UnexpectedEof;
        self.pos += result.bytes_read;
        return result.value;
    }

    fn readS64(self: *Reader) ReadError!i64 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        const result = leb128.readS64Leb128(self.data[self.pos..]) catch return error.UnexpectedEof;
        self.pos += result.bytes_read;
        return result.value;
    }

    fn readFixedU32(self: *Reader) ReadError!u32 {
        const b = try self.readBytes(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn readFixedU64(self: *Reader) ReadError!u64 {
        const b = try self.readBytes(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }

    fn readName(self: *Reader) ReadError![]const u8 {
        const len = try self.readU32();
        return self.readBytes(len);
    }

    fn readValType(self: *Reader) ReadError!types.ValType {
        const byte = try self.readByte();
        return enumFromIntChecked(types.ValType, @as(i32, @intCast(@as(i8, @bitCast(byte))))) orelse
            return error.InvalidType;
    }

    fn readLimits(self: *Reader) ReadError!types.Limits {
        const flags = try self.readByte();
        var limits = types.Limits{};
        limits.has_max = (flags & 0x01) != 0;
        limits.is_shared = (flags & 0x02) != 0;
        limits.is_64 = (flags & 0x04) != 0;

        if (limits.is_64) {
            limits.initial = try self.readU64();
            if (limits.has_max) limits.max = try self.readU64();
        } else {
            limits.initial = try self.readU32();
            if (limits.has_max) limits.max = try self.readU32();
        }

        if (flags & 0x08 != 0) {
            const log2 = try self.readU32();
            if (log2 > 16) return error.InvalidLimits;
            limits.page_size = @as(u32, 1) << @intCast(log2);
        }

        return limits;
    }

    fn skipInitExpr(self: *Reader) ReadError!void {
        var depth: u32 = 0;
        while (true) {
            const byte = try self.readByte();
            switch (byte) {
                0x0b => {
                    if (depth == 0) return;
                    depth -= 1;
                },
                0x02, 0x03, 0x04 => depth += 1,
                0x41 => _ = try self.readS32(),
                0x42 => _ = try self.readS64(),
                0x43 => _ = try self.readBytes(4),
                0x44 => _ = try self.readBytes(8),
                0x23 => _ = try self.readU32(),
                0xd0 => _ = try self.readValType(),
                0xd2 => _ = try self.readU32(),
                else => {},
            }
        }
    }

    // -- sections --

    fn readSections(self: *Reader) ReadError!void {
        while (self.pos < self.data.len) {
            const id_byte = try self.readByte();
            const section_size = try self.readU32();
            const section_end = self.pos + section_size;
            if (section_end > self.data.len) return error.SectionTooLarge;

            switch (id_byte) {
                0 => try self.readCustomSection(section_end),
                1 => try self.readTypeSection(section_end),
                2 => try self.readImportSection(section_end),
                3 => try self.readFunctionSection(section_end),
                4 => try self.readTableSection(section_end),
                5 => try self.readMemorySection(section_end),
                6 => try self.readGlobalSection(section_end),
                7 => try self.readExportSection(section_end),
                8 => try self.readStartSection(section_end),
                9 => try self.readElementSection(section_end),
                10 => try self.readCodeSection(section_end),
                11 => try self.readDataSection(section_end),
                12 => try self.readDataCountSection(section_end),
                13 => try self.readTagSection(section_end),
                else => {},
            }
            self.pos = section_end;
        }
    }

    fn readTypeSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        try self.module.module_types.ensureTotalCapacity(self.allocator, count);
        for (0..count) |_| {
            const form_byte = try self.readByte();
            if (form_byte != 0x60) return error.InvalidType; // only func form for now
            const num_params = try self.readU32();
            var params = try self.allocator.alloc(types.ValType, num_params);
            errdefer self.allocator.free(params);
            for (0..num_params) |j| params[j] = try self.readValType();

            const num_results = try self.readU32();
            var results = try self.allocator.alloc(types.ValType, num_results);
            errdefer self.allocator.free(results);
            for (0..num_results) |j| results[j] = try self.readValType();

            self.module.module_types.appendAssumeCapacity(.{
                .func_type = .{ .params = params, .results = results },
            });
        }
    }

    fn readImportSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const module_name = try self.readName();
            const field_name = try self.readName();
            const kind_byte = try self.readByte();
            const kind: types.ExternalKind = enumFromIntChecked(types.ExternalKind, kind_byte) orelse
                return error.InvalidSection;

            var import = Mod.Import{
                .module_name = module_name,
                .field_name = field_name,
                .kind = kind,
            };

            switch (kind) {
                .func => {
                    const type_index = try self.readU32();
                    import.func = .{ .type_var = .{ .index = type_index } };
                    try self.module.funcs.append(self.allocator, .{
                        .is_import = true,
                        .decl = .{ .type_var = .{ .index = type_index } },
                    });
                    self.module.num_func_imports += 1;
                },
                .table => {
                    const elem_type = try self.readValType();
                    const limits = try self.readLimits();
                    import.table = .{ .elem_type = elem_type, .limits = limits };
                    try self.module.tables.append(self.allocator, .{
                        .type = .{ .elem_type = elem_type, .limits = limits },
                        .is_import = true,
                    });
                    self.module.num_table_imports += 1;
                },
                .memory => {
                    const limits = try self.readLimits();
                    import.memory = .{ .limits = limits };
                    try self.module.memories.append(self.allocator, .{
                        .type = .{ .limits = limits },
                        .is_import = true,
                    });
                    self.module.num_memory_imports += 1;
                },
                .global => {
                    const val_type = try self.readValType();
                    const mut_byte = try self.readByte();
                    const mutability: types.Mutability = if (mut_byte != 0) .mutable else .immutable;
                    import.global = .{ .val_type = val_type, .mutability = mutability };
                    try self.module.globals.append(self.allocator, .{
                        .type = .{ .val_type = val_type, .mutability = mutability },
                        .is_import = true,
                    });
                    self.module.num_global_imports += 1;
                },
                .tag => {
                    _ = try self.readByte(); // attribute
                    const sig_index = try self.readU32();
                    _ = sig_index;
                    try self.module.tags.append(self.allocator, .{ .is_import = true });
                    self.module.num_tag_imports += 1;
                },
            }
            try self.module.imports.append(self.allocator, import);
        }
    }

    fn readFunctionSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const type_index = try self.readU32();
            try self.module.funcs.append(self.allocator, .{
                .decl = .{ .type_var = .{ .index = type_index } },
            });
        }
    }

    fn readTableSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const elem_type = try self.readValType();
            const limits = try self.readLimits();
            try self.module.tables.append(self.allocator, .{
                .type = .{ .elem_type = elem_type, .limits = limits },
            });
        }
    }

    fn readMemorySection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const limits = try self.readLimits();
            try self.module.memories.append(self.allocator, .{
                .type = .{ .limits = limits },
            });
        }
    }

    fn readGlobalSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const val_type = try self.readValType();
            const mut_byte = try self.readByte();
            const mutability: types.Mutability = if (mut_byte != 0) .mutable else .immutable;
            try self.skipInitExpr();
            try self.module.globals.append(self.allocator, .{
                .type = .{ .val_type = val_type, .mutability = mutability },
            });
        }
    }

    fn readExportSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const exp_name = try self.readName();
            const kind_byte = try self.readByte();
            const index = try self.readU32();
            try self.module.exports.append(self.allocator, .{
                .name = exp_name,
                .kind = enumFromIntChecked(types.ExternalKind, kind_byte) orelse return error.InvalidSection,
                .var_ = .{ .index = index },
            });
        }
    }

    fn readStartSection(self: *Reader, _: usize) ReadError!void {
        const index = try self.readU32();
        self.module.start_var = .{ .index = index };
    }

    fn readElementSection(self: *Reader, end: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const flags = try self.readU32();
            var seg = Mod.ElemSegment{};

            const is_passive = (flags & 1) != 0;
            const has_explicit_index = (flags & 2) != 0;
            const use_elem_exprs = (flags & 4) != 0;

            if (is_passive and has_explicit_index) {
                seg.kind = .declared;
            } else if (is_passive) {
                seg.kind = .passive;
            } else {
                seg.kind = .active;
            }

            if (!is_passive) {
                if (has_explicit_index) seg.table_var = .{ .index = try self.readU32() };
                try self.skipInitExpr();
            }

            if (is_passive or has_explicit_index) {
                if (use_elem_exprs) {
                    seg.elem_type = try self.readValType();
                } else {
                    _ = try self.readByte(); // external kind (0=func)
                }
            }

            const elem_count = try self.readU32();
            seg.elem_var_indices = .empty;
            try seg.elem_var_indices.ensureTotalCapacity(self.allocator, elem_count);
            for (0..elem_count) |_| {
                if (use_elem_exprs) {
                    try self.skipInitExpr();
                    seg.elem_var_indices.appendAssumeCapacity(.{ .index = 0 });
                } else {
                    seg.elem_var_indices.appendAssumeCapacity(.{ .index = try self.readU32() });
                }
            }

            try self.module.elem_segments.append(self.allocator, seg);
        }
        _ = end;
    }

    fn readCodeSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        const expected = self.module.funcs.items.len - self.module.num_func_imports;
        if (count != expected) return error.FunctionCodeMismatch;

        for (0..count) |i| {
            const body_size = try self.readU32();
            const body_end = self.pos + body_size;
            if (body_end > self.data.len) return error.SectionTooLarge;

            const func_idx = self.module.num_func_imports + @as(u32, @intCast(i));
            var func = &self.module.funcs.items[func_idx];

            // Read locals
            const num_local_decls = try self.readU32();
            var total_locals: u64 = 0;
            for (0..num_local_decls) |_| {
                const local_count = try self.readU32();
                total_locals += local_count;
                if (total_locals > 50000) return error.TooManyLocals;
                const local_type = try self.readValType();
                for (0..local_count) |_| {
                    try func.local_types.append(self.allocator, local_type);
                }
            }

            // Read instructions until body_end
            try self.readInstructions(func, body_end);
        }
    }

    fn readInstructions(self: *Reader, func: *Mod.Func, end: usize) ReadError!void {
        while (self.pos < end) {
            const opcode = try self.readByte();
            const instr: Mod.Instruction = switch (opcode) {
                0x00 => .{ .@"unreachable" = {} },
                0x01 => .{ .nop = {} },
                0x02 => .{ .block = try self.readBlockType() },
                0x03 => .{ .loop = try self.readBlockType() },
                0x04 => .{ .@"if" = try self.readBlockType() },
                0x05 => .{ .@"else" = {} },
                0x0b => .{ .end = {} },
                0x0c => .{ .br = try self.readU32() },
                0x0d => .{ .br_if = try self.readU32() },
                0x0e => blk: {
                    const cnt = try self.readU32();
                    const targets = try self.allocator.alloc(u32, cnt);
                    for (0..cnt) |j| targets[j] = try self.readU32();
                    const default = try self.readU32();
                    break :blk .{ .br_table = .{ .targets = targets, .default_target = default } };
                },
                0x0f => .{ .@"return" = {} },
                0x10 => .{ .call = try self.readU32() },
                0x11 => .{ .call_indirect = .{
                    .type_index = try self.readU32(),
                    .table_index = try self.readU32(),
                } },
                0x1a => .{ .drop = {} },
                0x1b => .{ .select = {} },
                0x20 => .{ .local_get = try self.readU32() },
                0x21 => .{ .local_set = try self.readU32() },
                0x22 => .{ .local_tee = try self.readU32() },
                0x23 => .{ .global_get = try self.readU32() },
                0x24 => .{ .global_set = try self.readU32() },
                // Memory load/store
                0x28 => .{ .i32_load = try self.readMemArg() },
                0x29 => .{ .i64_load = try self.readMemArg() },
                0x2a => .{ .f32_load = try self.readMemArg() },
                0x2b => .{ .f64_load = try self.readMemArg() },
                0x2c => .{ .i32_load8_s = try self.readMemArg() },
                0x2d => .{ .i32_load8_u = try self.readMemArg() },
                0x2e => .{ .i32_load16_s = try self.readMemArg() },
                0x2f => .{ .i32_load16_u = try self.readMemArg() },
                0x30 => .{ .i64_load8_s = try self.readMemArg() },
                0x31 => .{ .i64_load8_u = try self.readMemArg() },
                0x32 => .{ .i64_load16_s = try self.readMemArg() },
                0x33 => .{ .i64_load16_u = try self.readMemArg() },
                0x34 => .{ .i64_load32_s = try self.readMemArg() },
                0x35 => .{ .i64_load32_u = try self.readMemArg() },
                0x36 => .{ .i32_store = try self.readMemArg() },
                0x37 => .{ .i64_store = try self.readMemArg() },
                0x38 => .{ .f32_store = try self.readMemArg() },
                0x39 => .{ .f64_store = try self.readMemArg() },
                0x3a => .{ .i32_store8 = try self.readMemArg() },
                0x3b => .{ .i32_store16 = try self.readMemArg() },
                0x3c => .{ .i64_store8 = try self.readMemArg() },
                0x3d => .{ .i64_store16 = try self.readMemArg() },
                0x3e => .{ .i64_store32 = try self.readMemArg() },
                0x3f => .{ .memory_size = try self.readU32() },
                0x40 => .{ .memory_grow = try self.readU32() },
                // Constants
                0x41 => .{ .i32_const = try self.readS32() },
                0x42 => .{ .i64_const = try self.readS64() },
                0x43 => .{ .f32_const = try self.readFixedU32() },
                0x44 => .{ .f64_const = try self.readFixedU64() },
                // i32 comparison
                0x45 => .{ .i32_eqz = {} },
                0x46 => .{ .i32_eq = {} },
                0x47 => .{ .i32_ne = {} },
                0x48 => .{ .i32_lt_s = {} },
                0x49 => .{ .i32_lt_u = {} },
                0x4a => .{ .i32_gt_s = {} },
                0x4b => .{ .i32_gt_u = {} },
                0x4c => .{ .i32_le_s = {} },
                0x4d => .{ .i32_le_u = {} },
                0x4e => .{ .i32_ge_s = {} },
                0x4f => .{ .i32_ge_u = {} },
                // i64 comparison
                0x50 => .{ .i64_eqz = {} },
                0x51 => .{ .i64_eq = {} },
                0x52 => .{ .i64_ne = {} },
                0x53 => .{ .i64_lt_s = {} },
                0x54 => .{ .i64_lt_u = {} },
                0x55 => .{ .i64_gt_s = {} },
                0x56 => .{ .i64_gt_u = {} },
                0x57 => .{ .i64_le_s = {} },
                0x58 => .{ .i64_le_u = {} },
                0x59 => .{ .i64_ge_s = {} },
                0x5a => .{ .i64_ge_u = {} },
                // f32/f64 comparison
                0x5b => .{ .f32_eq = {} }, 0x5c => .{ .f32_ne = {} },
                0x5d => .{ .f32_lt = {} }, 0x5e => .{ .f32_gt = {} },
                0x5f => .{ .f32_le = {} }, 0x60 => .{ .f32_ge = {} },
                0x61 => .{ .f64_eq = {} }, 0x62 => .{ .f64_ne = {} },
                0x63 => .{ .f64_lt = {} }, 0x64 => .{ .f64_gt = {} },
                0x65 => .{ .f64_le = {} }, 0x66 => .{ .f64_ge = {} },
                // i32 arithmetic
                0x67 => .{ .i32_clz = {} }, 0x68 => .{ .i32_ctz = {} }, 0x69 => .{ .i32_popcnt = {} },
                0x6a => .{ .i32_add = {} }, 0x6b => .{ .i32_sub = {} }, 0x6c => .{ .i32_mul = {} },
                0x6d => .{ .i32_div_s = {} }, 0x6e => .{ .i32_div_u = {} },
                0x6f => .{ .i32_rem_s = {} }, 0x70 => .{ .i32_rem_u = {} },
                0x71 => .{ .i32_and = {} }, 0x72 => .{ .i32_or = {} }, 0x73 => .{ .i32_xor = {} },
                0x74 => .{ .i32_shl = {} }, 0x75 => .{ .i32_shr_s = {} }, 0x76 => .{ .i32_shr_u = {} },
                0x77 => .{ .i32_rotl = {} }, 0x78 => .{ .i32_rotr = {} },
                // i64 arithmetic
                0x79 => .{ .i64_clz = {} }, 0x7a => .{ .i64_ctz = {} }, 0x7b => .{ .i64_popcnt = {} },
                0x7c => .{ .i64_add = {} }, 0x7d => .{ .i64_sub = {} }, 0x7e => .{ .i64_mul = {} },
                0x7f => .{ .i64_div_s = {} }, 0x80 => .{ .i64_div_u = {} },
                0x81 => .{ .i64_rem_s = {} }, 0x82 => .{ .i64_rem_u = {} },
                0x83 => .{ .i64_and = {} }, 0x84 => .{ .i64_or = {} }, 0x85 => .{ .i64_xor = {} },
                0x86 => .{ .i64_shl = {} }, 0x87 => .{ .i64_shr_s = {} }, 0x88 => .{ .i64_shr_u = {} },
                0x89 => .{ .i64_rotl = {} }, 0x8a => .{ .i64_rotr = {} },
                // f32 arithmetic
                0x8b => .{ .f32_abs = {} }, 0x8c => .{ .f32_neg = {} },
                0x8d => .{ .f32_ceil = {} }, 0x8e => .{ .f32_floor = {} },
                0x8f => .{ .f32_trunc = {} }, 0x90 => .{ .f32_nearest = {} }, 0x91 => .{ .f32_sqrt = {} },
                0x92 => .{ .f32_add = {} }, 0x93 => .{ .f32_sub = {} },
                0x94 => .{ .f32_mul = {} }, 0x95 => .{ .f32_div = {} },
                0x96 => .{ .f32_min = {} }, 0x97 => .{ .f32_max = {} }, 0x98 => .{ .f32_copysign = {} },
                // f64 arithmetic
                0x99 => .{ .f64_abs = {} }, 0x9a => .{ .f64_neg = {} },
                0x9b => .{ .f64_ceil = {} }, 0x9c => .{ .f64_floor = {} },
                0x9d => .{ .f64_trunc = {} }, 0x9e => .{ .f64_nearest = {} }, 0x9f => .{ .f64_sqrt = {} },
                0xa0 => .{ .f64_add = {} }, 0xa1 => .{ .f64_sub = {} },
                0xa2 => .{ .f64_mul = {} }, 0xa3 => .{ .f64_div = {} },
                0xa4 => .{ .f64_min = {} }, 0xa5 => .{ .f64_max = {} }, 0xa6 => .{ .f64_copysign = {} },
                // Conversions
                0xa7 => .{ .i32_wrap_i64 = {} },
                0xa8 => .{ .i32_trunc_f32_s = {} }, 0xa9 => .{ .i32_trunc_f32_u = {} },
                0xaa => .{ .i32_trunc_f64_s = {} }, 0xab => .{ .i32_trunc_f64_u = {} },
                0xac => .{ .i64_extend_i32_s = {} }, 0xad => .{ .i64_extend_i32_u = {} },
                0xae => .{ .i64_trunc_f32_s = {} }, 0xaf => .{ .i64_trunc_f32_u = {} },
                0xb0 => .{ .i64_trunc_f64_s = {} }, 0xb1 => .{ .i64_trunc_f64_u = {} },
                0xb2 => .{ .f32_convert_i32_s = {} }, 0xb3 => .{ .f32_convert_i32_u = {} },
                0xb4 => .{ .f32_convert_i64_s = {} }, 0xb5 => .{ .f32_convert_i64_u = {} },
                0xb6 => .{ .f32_demote_f64 = {} },
                0xb7 => .{ .f64_convert_i32_s = {} }, 0xb8 => .{ .f64_convert_i32_u = {} },
                0xb9 => .{ .f64_convert_i64_s = {} }, 0xba => .{ .f64_convert_i64_u = {} },
                0xbb => .{ .f64_promote_f32 = {} },
                0xbc => .{ .i32_reinterpret_f32 = {} }, 0xbd => .{ .i64_reinterpret_f64 = {} },
                0xbe => .{ .f32_reinterpret_i32 = {} }, 0xbf => .{ .f64_reinterpret_i64 = {} },
                // Sign extension
                0xc0 => .{ .i32_extend8_s = {} }, 0xc1 => .{ .i32_extend16_s = {} },
                0xc2 => .{ .i64_extend8_s = {} }, 0xc3 => .{ .i64_extend16_s = {} },
                0xc4 => .{ .i64_extend32_s = {} },
                // Reference types
                0xd0 => .{ .ref_null = try self.readValType() },
                0xd1 => .{ .ref_is_null = {} },
                0xd2 => .{ .ref_func = try self.readU32() },
                // Prefixed opcodes — skip for now
                0xfc, 0xfd, 0xfe => {
                    _ = try self.readU32();
                    continue;
                },
                else => continue,
            };
            try func.instructions.append(self.allocator, instr);
        }
    }

    fn readBlockType(self: *Reader) ReadError!Mod.Instruction.BlockType {
        const byte = try self.readByte();
        if (byte == 0x40) return .{ .empty = {} };
        const signed: i8 = @bitCast(byte);
        if (signed < 0) {
            return .{ .val_type = enumFromIntChecked(types.ValType, @as(i32, signed)) orelse return .{ .empty = {} } };
        }
        return .{ .type_index = byte };
    }

    fn readMemArg(self: *Reader) ReadError!Mod.Instruction.MemArg {
        const align_ = try self.readU32();
        const offset = try self.readU32();
        return .{ .align_ = align_, .offset = offset };
    }

    fn readDataSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const flags = try self.readU32();
            var seg = Mod.DataSegment{};

            if (flags & 1 != 0) {
                seg.kind = .passive;
            } else {
                seg.kind = .active;
                if (flags & 2 != 0) seg.memory_var = .{ .index = try self.readU32() };
                try self.skipInitExpr();
            }

            const data_len = try self.readU32();
            if (self.pos + data_len > self.data.len) return error.UnexpectedEof;
            seg.data = self.data[self.pos .. self.pos + data_len];
            self.pos += data_len;

            try self.module.data_segments.append(self.allocator, seg);
        }
    }

    fn readDataCountSection(self: *Reader, _: usize) ReadError!void {
        _ = try self.readU32();
    }

    fn readTagSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            _ = try self.readByte(); // attribute
            _ = try self.readU32(); // sig index
            try self.module.tags.append(self.allocator, .{});
        }
    }

    fn readCustomSection(self: *Reader, end: usize) ReadError!void {
        const sect_name = try self.readName();
        const payload = self.data[self.pos..end];
        try self.module.customs.append(self.allocator, .{
            .name = sect_name,
            .data = payload,
        });
        self.pos = end;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "reject invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidMagic, readModule(std.testing.allocator, &bad));
}

test "accept valid header" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var module = try readModule(std.testing.allocator, &header);
    defer module.deinit();
}

test "read type section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.module_types.items.len);
}

test "read memory section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.memories.items.len);
    try std.testing.expectEqual(@as(u64, 1), module.memories.items[0].type.limits.initial);
}

test "read export section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x07, 0x07, 0x01, 0x03, 'm', 'e', 'm', 0x02, 0x00,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.exports.items.len);
    try std.testing.expect(std.mem.eql(u8, "mem", module.exports.items[0].name));
}

test "read function and code sections" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type
        0x03, 0x02, 0x01, 0x00, // function
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // code
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.funcs.items.len);
}

test "read import section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type
        0x02, 0x0b, 0x01, // import section, 1 import
        0x03, 'e', 'n', 'v',
        0x03, 'l', 'o', 'g',
        0x00, 0x00,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.imports.items.len);
    try std.testing.expectEqual(@as(types.Index, 1), module.num_func_imports);
}

test "read global section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x06, 0x06, 0x01,
        0x7f, 0x01, // i32 mutable
        0x41, 0x2a, 0x0b, // i32.const 42, end
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.globals.items.len);
    try std.testing.expectEqual(types.ValType.i32, module.globals.items[0].type.val_type);
    try std.testing.expectEqual(types.Mutability.mutable, module.globals.items[0].type.mutability);
}

test "read custom section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x07, 0x04, 't', 'e', 's', 't', 0xDE, 0xAD,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.customs.items.len);
    try std.testing.expect(std.mem.eql(u8, "test", module.customs.items[0].name));
}

test "read data section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0b, 0x0b, 0x01,
        0x00, // active, memory 0
        0x41, 0x00, 0x0b, // offset: i32.const 0, end
        0x05, 'h', 'e', 'l', 'l', 'o',
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.data_segments.items.len);
    try std.testing.expect(std.mem.eql(u8, "hello", module.data_segments.items[0].data));
}

test "read start section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x08, 0x01, 0x00, // start function index 0
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expect(module.start_var != null);
    try std.testing.expectEqual(@as(types.Index, 0), module.start_var.?.index);
}

test "read code section parses instructions" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: (i32, i32) -> i32
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
        // function section: 1 func, type 0
        0x03, 0x02, 0x01, 0x00,
        // code section
        0x0a, 0x09, 0x01, // section id=10, size=9, 1 body
        0x07, // body size=7
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x6a, // i32.add
        0x0b, // end
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.funcs.items.len);
    const func = &module.funcs.items[0];
    try std.testing.expectEqual(@as(usize, 4), func.instructions.items.len);
    try std.testing.expectEqual(Mod.Instruction{ .local_get = 0 }, func.instructions.items[0]);
    try std.testing.expectEqual(Mod.Instruction{ .local_get = 1 }, func.instructions.items[1]);
    try std.testing.expect(func.instructions.items[2] == .i32_add);
    try std.testing.expect(func.instructions.items[3] == .end);
}

test "read code section parses i32.const" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: () -> i32
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        // function section
        0x03, 0x02, 0x01, 0x00,
        // code section
        0x0a, 0x06, 0x01, // section, 1 body
        0x04, // body size=4
        0x00, // 0 locals
        0x41, 0x2a, // i32.const 42
        0x0b, // end
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();

    const func = &module.funcs.items[0];
    try std.testing.expectEqual(@as(usize, 2), func.instructions.items.len);
    try std.testing.expectEqual(Mod.Instruction{ .i32_const = 42 }, func.instructions.items[0]);
}

test "read code section parses locals" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: () -> ()
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function section
        0x03, 0x02, 0x01, 0x00,
        // code section
        0x0a, 0x06, 0x01, // section, 1 body
        0x04, // body size=4
        0x01, // 1 local declaration
        0x02, 0x7f, // 2 x i32
        0x0b, // end
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();

    const func = &module.funcs.items[0];
    try std.testing.expectEqual(@as(usize, 2), func.local_types.items.len);
    try std.testing.expectEqual(types.ValType.i32, func.local_types.items[0]);
    try std.testing.expectEqual(types.ValType.i32, func.local_types.items[1]);
}
