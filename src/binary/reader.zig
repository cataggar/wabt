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
        _ = try self.readInitExprBytes();
    }

    /// Read an init expression and return a slice of the underlying data
    /// that contains the expression bytecode (including the 0x0b terminator).
    fn readInitExprBytes(self: *Reader) ReadError![]const u8 {
        const start = self.pos;
        var depth: u32 = 0;
        while (true) {
            const byte = try self.readByte();
            switch (byte) {
                0x0b => {
                    if (depth == 0) return self.data[start..self.pos];
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
                seg.offset_expr_bytes = try self.readInitExprBytes();
            }

            if (is_passive or has_explicit_index) {
                if (use_elem_exprs) {
                    seg.elem_type = try self.readValType();
                } else {
                    _ = try self.readByte(); // external kind (0=func)
                }
            }

            const elem_count = try self.readU32();
            seg.elem_var_indices = .{};
            try seg.elem_var_indices.ensureTotalCapacity(self.allocator, elem_count);
            for (0..elem_count) |_| {
                if (use_elem_exprs) {
                    const expr = try self.readInitExprBytes();
                    if (expr.len >= 2 and expr[0] == 0xd2) {
                        const r = leb128.readU32Leb128(expr[1..]) catch
                            return error.InvalidSection;
                        seg.elem_var_indices.appendAssumeCapacity(.{ .index = r.value });
                    } else {
                        seg.elem_var_indices.appendAssumeCapacity(.{ .index = std.math.maxInt(u32) });
                    }
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

            const num_local_decls = try self.readU32();
            var total_locals: u64 = 0;
            const func_idx = self.module.num_func_imports + @as(u32, @intCast(i));
            for (0..num_local_decls) |_| {
                const local_count = try self.readU32();
                total_locals += local_count;
                if (total_locals > 50000) return error.TooManyLocals;
                const vt = try self.readValType();
                // Populate local_types on the func
                for (0..local_count) |_| {
                    try self.module.funcs.items[func_idx].local_types.append(self.allocator, vt);
                }
            }
            // Store the instruction bytes (slice into input data)
            self.module.funcs.items[func_idx].code_bytes = self.data[self.pos..body_end];
            self.pos = body_end;
        }
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
                seg.offset_expr_bytes = try self.readInitExprBytes();
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
