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

    // Validate data count matches data section
    if (module.has_data_count) {
        if (module.data_count != module.data_segments.items.len) return error.InvalidSection;
    }

    return module;
}

/// Safe enum cast: returns null if the integer doesn't match any tag.
fn enumFromIntChecked(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    inline for (std.enums.values(E)) |field_value| {
        if (value == @intFromEnum(field_value)) return field_value;
    }
    return null;
}

// ── Reference types ─────────────────────────────────────────────────────

/// Binary prefix for a non-nullable typed reference, `(ref <heaptype>)`.
pub const ref_prefix: u8 = 0x64;
/// Binary prefix for a nullable typed reference, `(ref null <heaptype>)`.
pub const ref_null_prefix: u8 = 0x63;

/// The complete set of abstract heap types: the value each carries in a
/// heaptype LEB128, and the `ValType` for its nullable and non-nullable forms.
///
/// This is the single source of truth for heaptype decoding. It is deliberately
/// exhaustive: a heaptype missing from this table is rejected, never silently
/// widened to `funcref`.
const abstract_heap_types = [_]types.AbstractHeapType{
    .noexn, .nofunc, .noextern, .none,
    .func, .extern_, .any, .eq, .i31, .struct_, .array, .exn,
};

/// Resolve a decoded heaptype to a `types.RefType`. Abstract heap types come
/// from the exhaustive table above; a non-negative heaptype is a concrete type
/// index, carried out-of-line because `ValType` has no room for it.
fn refTypeFromHeapType(heap_type: i64, nullable: bool) ReadError!types.RefType {
    for (abstract_heap_types) |heap| {
        if (heap_type == @intFromEnum(heap)) {
            return types.RefType.abstract(nullable, heap);
        }
    }
    if (heap_type >= 0) {
        if (heap_type > std.math.maxInt(u32)) return error.InvalidType;
        return types.RefType.concrete(nullable, @intCast(heap_type));
    }
    return error.InvalidType;
}

/// Position of a non-custom section in the module's binary grammar.
///
/// Sections mostly appear in increasing ID order, but two do not, because
/// both were added by later proposals and took the next free ID rather than
/// one that sorts into place:
///
///   * the data-count section (id 12) sits between element (9) and code (10);
///   * the tag section (id 13) sits between memory (5) and global (6).
///
/// Scaling every ID by 2 leaves an odd-numbered gap after each section, so
/// both can occupy a half-step without colliding with their neighbours:
/// tag becomes 5.5 (→ 11) and data-count 9.5 (→ 19). Mapping either onto its
/// neighbour's number instead would make a legal `memory, tag` or
/// `element, data_count` pair look like a duplicate section.
///
/// Verified against `wasm-tools` 1.250.0, which emits
/// `1, 2, 3, 4, 5, 13, 6, 7, 8, 9, 10, 11` for a module using every section,
/// and `1, 3, 5, 13, 12, 10, 11` for one that needs a data-count section.
fn sectionOrder(id: u8) u8 {
    return switch (id) {
        13 => 11, // tag: between memory (5 → 10) and global (6 → 12)
        12 => 19, // data count: between element (9 → 18) and code (10 → 20)
        else => id *| 2,
    };
}

// ── Internal reader ─────────────────────────────────────────────────────

/// A decoded value type together with its concrete type index, if any.
/// `ValType` cannot carry the index itself, so the reader hands both back and
/// each caller stores the index in the matching IR slot.
const IndexedValType = struct {
    vt: types.ValType,
    type_idx: u32 = types.invalid_index,
};

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

    fn peekByte(self: *Reader) ReadError!u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEof;
        return self.data[self.pos];
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

    fn readValType(self: *Reader) ReadError!IndexedValType {
        const byte = try self.readByte();
        if (byte == ref_prefix or byte == ref_null_prefix) {
            // `0x63`/`0x64` are *prefixes*, not types: each is followed by a
            // heaptype LEB128 that must be consumed, or the stream desyncs and
            // the next byte is misread as this type.
            const heap_type = try self.readS64();
            const ref = try refTypeFromHeapType(heap_type, byte == ref_null_prefix);
            return .{
                .vt = ref.toValType(),
                .type_idx = switch (ref.heap) {
                    .abstract => types.invalid_index,
                    .concrete => |idx| idx,
                },
            };
        }
        const vt = enumFromIntChecked(types.ValType, @as(i32, @intCast(@as(i8, @bitCast(byte))))) orelse
            return error.InvalidType;
        // The abbreviated forms never carry a concrete index; a bare
        // `.concrete_ref` byte would be an internal marker leaking into the
        // binary format, which is not a valid encoding.
        if (vt == .concrete_ref or vt == .concrete_ref_null) return error.InvalidType;
        return .{ .vt = vt };
    }

    /// Read a reference type encoding, handling both the abbreviated form
    /// (`0x70` funcref, `0x6f` externref, …) and the general
    /// `0x63`/`0x64` + heaptype form.
    fn readRefType(self: *Reader) ReadError!IndexedValType {
        const indexed = try self.readValType();
        if (!indexed.vt.isRefType()) return error.InvalidType;
        return indexed;
    }

    /// Validate a concrete type index against the already-read type section.
    /// Sections after the type section can be checked immediately.
    fn checkTypeIndex(self: *Reader, indexed: IndexedValType) ReadError!IndexedValType {
        if (indexed.type_idx != types.invalid_index and
            indexed.type_idx >= self.module.module_types.items.len)
            return error.InvalidType;
        return indexed;
    }

    fn readLimits(self: *Reader) ReadError!types.Limits {
        const flags = try self.readByte();
        // Valid flags: 0x00 (min only), 0x01 (min+max), 0x03 (shared+max), 0x04 (memory64)
        // Reject unknown flag combinations
        if (flags & 0xF8 != 0) return error.InvalidLimits;
        if (flags & 0x02 != 0 and flags & 0x01 == 0) return error.InvalidLimits; // shared requires max
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
                // `ref.null`'s operand is a heaptype LEB128, not a value type.
                // The abbreviated abstract encodings coincide with the value
                // type bytes, which hid this until concrete indices appeared:
                // `ref.null 0` is `d0 00`, and an index >= 64 spans two bytes.
                0xd0 => _ = try self.readS64(),
                0xd2 => _ = try self.readU32(),
                else => {},
            }
        }
    }

    // -- sections --

    fn readSections(self: *Reader) ReadError!void {
        var last_non_custom_id: u8 = 0;
        var seen_sections: u16 = 0; // bitmask for section IDs 0-15

        while (self.pos < self.data.len) {
            const id_byte = try self.readByte();
            const section_size = try self.readU32();
            const section_end = self.pos + section_size;
            if (section_end > self.data.len) return error.SectionTooLarge;

            // Validate section ordering and duplicates (custom sections exempt)
            if (id_byte != 0) {
                if (id_byte > 13) return error.InvalidSection;
                const order_id = sectionOrder(id_byte);
                const last_order = sectionOrder(last_non_custom_id);
                if (order_id <= last_order and last_non_custom_id != 0) return error.InvalidSection;
                // Check for duplicate sections
                const mask: u16 = @as(u16, 1) << @intCast(id_byte);
                if (seen_sections & mask != 0) return error.InvalidSection;
                seen_sections |= mask;
                last_non_custom_id = id_byte;
            }

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
            // Verify section was fully consumed (detect section size mismatch)
            if (self.pos != section_end) return error.InvalidSection;
            self.pos = section_end;
        }

        // Cross-section validation
        // Data count must match actual data section count
        if (self.module.has_data_count and self.module.data_count != @as(u32, @intCast(self.module.data_segments.items.len))) {
            return error.InvalidSection;
        }
        // Function section requires code section and vice versa
        const num_defined_funcs = self.module.funcs.items.len - self.module.num_func_imports;
        const has_func_section = (seen_sections & (1 << 3)) != 0;
        const has_code_section = (seen_sections & (1 << 10)) != 0;
        if (has_func_section and !has_code_section and num_defined_funcs > 0) return error.FunctionCodeMismatch;
        if (!has_func_section and has_code_section and num_defined_funcs > 0) return error.FunctionCodeMismatch;
    }

    fn readTypeSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        try self.module.module_types.ensureTotalCapacity(self.allocator, count);
        // `count` counts *top-level* entries, and a rec group is one of them
        // however many types it holds, so the number of types read can exceed
        // it. This mirrors how the writer counts what it emits.
        for (0..count) |_| {
            if (try self.peekByte() == rec_group_form) {
                _ = try self.readByte();
                const group_size = try self.readU32();
                const group_id: u32 = @intCast(self.module.module_types.items.len);
                for (0..group_size) |position| {
                    try self.readOneType(.{
                        .in_rec_group = true,
                        .rec_group = group_id,
                        .rec_group_size = group_size,
                        .rec_position = @intCast(position),
                    });
                }
            } else {
                try self.readOneType(.{});
            }
        }
        // Concrete heap types may refer forward within the type section, so
        // indices can only be bounds-checked once the whole section is read.
        try self.checkTypeSectionIndices();
    }

    /// Recursion group marker, and the two forms that declare a supertype.
    const rec_group_form: u8 = 0x4E;
    const sub_form: u8 = 0x50;
    const sub_final_form: u8 = 0x4F;
    const func_form: u8 = 0x60;
    const struct_form: u8 = 0x5F;
    const array_form: u8 = 0x5E;

    /// Position of a type within its recursion group, if any.
    const RecPlacement = struct {
        in_rec_group: bool = false,
        rec_group: u32 = types.invalid_index,
        rec_group_size: u32 = 1,
        rec_position: u32 = 0,
    };

    /// One type definition: an optional `sub`/`sub final` prefix naming a
    /// supertype, then the structural form.
    fn readOneType(self: *Reader, placement: RecPlacement) ReadError!void {
        var meta = Mod.TypeMeta{
            .in_rec_group = placement.in_rec_group,
            .rec_group = placement.rec_group,
            .rec_group_size = placement.rec_group_size,
            .rec_position = placement.rec_position,
        };

        const first = try self.peekByte();
        if (first == sub_form or first == sub_final_form) {
            _ = try self.readByte();
            meta.is_sub = true;
            meta.is_final = first == sub_final_form;
            // The supertype list is a vector, but the GC proposal permits at
            // most one entry.
            const num_supertypes = try self.readU32();
            if (num_supertypes > 1) return error.InvalidType;
            if (num_supertypes == 1) meta.parent = try self.readU32();
        }

        const form_byte = try self.readByte();
        const entry: Mod.TypeEntry = switch (form_byte) {
            func_form => blk: {
                meta.kind = .func;
                break :blk .{ .func_type = try self.readFuncForm() };
            },
            struct_form => blk: {
                meta.kind = .struct_;
                break :blk .{ .struct_type = try self.readStructForm() };
            },
            array_form => blk: {
                meta.kind = .array;
                break :blk .{ .array_type = .{ .field = try self.readFieldType() } };
            },
            else => return error.InvalidType,
        };

        self.module.module_types.append(self.allocator, entry) catch return error.OutOfMemory;
        // `type_meta` is indexed in lockstep with `module_types`, so it has to
        // gain an entry per type even when there is nothing to record.
        self.module.type_meta.append(self.allocator, meta) catch return error.OutOfMemory;
    }

    fn readFuncForm(self: *Reader) ReadError!Mod.FuncSignature {
        const num_params = try self.readU32();
        var params = try self.allocator.alloc(types.ValType, num_params);
        errdefer self.allocator.free(params);
        var param_idxs = try self.allocator.alloc(u32, num_params);
        errdefer self.allocator.free(param_idxs);
        for (0..num_params) |j| {
            const indexed = try self.readValType();
            params[j] = indexed.vt;
            param_idxs[j] = indexed.type_idx;
        }

        const num_results = try self.readU32();
        var results = try self.allocator.alloc(types.ValType, num_results);
        errdefer self.allocator.free(results);
        var result_idxs = try self.allocator.alloc(u32, num_results);
        errdefer self.allocator.free(result_idxs);
        for (0..num_results) |j| {
            const indexed = try self.readValType();
            results[j] = indexed.vt;
            result_idxs[j] = indexed.type_idx;
        }

        return .{
            .params = params,
            .results = results,
            .param_type_idxs = param_idxs,
            .result_type_idxs = result_idxs,
        };
    }

    fn readStructForm(self: *Reader) ReadError!Mod.TypeEntry.StructType {
        const num_fields = try self.readU32();
        var fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
        errdefer fields.deinit(self.allocator);
        try fields.ensureTotalCapacity(self.allocator, num_fields);
        for (0..num_fields) |_| {
            fields.appendAssumeCapacity(try self.readFieldType());
        }
        return .{ .fields = fields };
    }

    /// A storage type and its mutability. `i8` and `i16` are only valid here,
    /// which is why they are read through `readValType` like any other.
    fn readFieldType(self: *Reader) ReadError!Mod.TypeEntry.StructType.Field {
        const indexed = try self.readValType();
        const mutable_byte = try self.readByte();
        if (mutable_byte > 1) return error.InvalidType;
        return .{
            .@"type" = indexed.vt,
            .mutable = mutable_byte == 1,
            .type_idx = indexed.type_idx,
        };
    }

    /// Reject concrete heap types naming a type index the module does not have.
    /// Left unchecked, an out-of-range index would reach the validator's type
    /// table lookups, which fail closed but report a less specific error.
    fn checkTypeSectionIndices(self: *Reader) ReadError!void {
        const count = self.module.module_types.items.len;
        const inRange = struct {
            fn f(idx: u32, n: usize) bool {
                return idx == types.invalid_index or idx < n;
            }
        }.f;
        for (self.module.module_types.items) |entry| {
            switch (entry) {
                .func_type => |ft| {
                    for (ft.param_type_idxs) |idx| {
                        if (!inRange(idx, count)) return error.InvalidType;
                    }
                    for (ft.result_type_idxs) |idx| {
                        if (!inRange(idx, count)) return error.InvalidType;
                    }
                },
                .struct_type => |st| {
                    for (st.fields.items) |f| {
                        if (!inRange(f.type_idx, count)) return error.InvalidType;
                    }
                },
                .array_type => |at| {
                    if (!inRange(at.field.type_idx, count)) return error.InvalidType;
                },
            }
        }
        // A declared supertype is an index into the same space.
        for (self.module.type_meta.items) |meta| {
            if (!inRange(meta.parent, count)) return error.InvalidType;
        }
    }

    fn readImportSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const module_name = try self.readName();
            if (!std.unicode.utf8ValidateSlice(module_name)) return error.InvalidSection;
            const field_name = try self.readName();
            if (!std.unicode.utf8ValidateSlice(field_name)) return error.InvalidSection;
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
                    const indexed = try self.checkTypeIndex(try self.readValType());
                    const elem_type = indexed.vt;
                    const limits = try self.readLimits();
                    import.table_type_idx = indexed.type_idx;
                    import.table = .{ .elem_type = elem_type, .limits = limits };
                    try self.module.tables.append(self.allocator, .{
                        .type = .{ .elem_type = elem_type, .limits = limits },
                        .type_idx = indexed.type_idx,
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
                    const indexed = try self.checkTypeIndex(try self.readValType());
                    const val_type = indexed.vt;
                    import.global_type_idx = indexed.type_idx;
                    const mut_byte = try self.readByte();
                    if (mut_byte > 1) return error.InvalidType;
                    const mutability: types.Mutability = if (mut_byte != 0) .mutable else .immutable;
                    import.global = .{ .val_type = val_type, .mutability = mutability };
                    try self.module.globals.append(self.allocator, .{
                        .type = .{ .val_type = val_type, .mutability = mutability },
                        .type_idx = indexed.type_idx,
                        .is_import = true,
                    });
                    self.module.num_global_imports += 1;
                },
                .tag => {
                    var tag = try self.readTagType();
                    tag.is_import = true;
                    import.tag = tag.@"type";
                    try self.module.tags.append(self.allocator, tag);
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
            const first_byte = try self.peekByte();
            if (first_byte == 0x40) {
                // Extended table type: 0x40 flags reftype limits [initexpr]
                _ = try self.readByte(); // consume 0x40
                const table_flags = try self.readByte(); // 0x00 = no table64
                const is_table64 = (table_flags & 0x01) != 0;
                const has_init = true; // 0x40 prefix indicates init expr
                const indexed = try self.checkTypeIndex(try self.readRefType());
                const elem_type = indexed.vt;
                const limits = try self.readLimits();
                var init_bytes: []const u8 = &.{};
                if (has_init) {
                    const expr_with_end = try self.readInitExprBytes();
                    // Writer appends its own trailing 0x0b — match the
                    // global init-expr convention and strip it here.
                    init_bytes = if (expr_with_end.len > 0)
                        expr_with_end[0 .. expr_with_end.len - 1]
                    else
                        expr_with_end;
                }
                try self.module.tables.append(self.allocator, .{
                    .type = .{ .elem_type = elem_type, .limits = limits },
                    .type_idx = indexed.type_idx,
                    .is_table64 = is_table64,
                    .init_expr_bytes = init_bytes,
                });
            } else {
                const indexed = try self.checkTypeIndex(try self.readValType());
                const limits = try self.readLimits();
                try self.module.tables.append(self.allocator, .{
                    .type = .{ .elem_type = indexed.vt, .limits = limits },
                    .type_idx = indexed.type_idx,
                });
            }
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
            const global_indexed = try self.checkTypeIndex(try self.readValType());
            const val_type = global_indexed.vt;
            const mut_byte = try self.readByte();
            if (mut_byte > 1) return error.InvalidType;
            const mutability: types.Mutability = if (mut_byte != 0) .mutable else .immutable;
            // Capture the init expression bytes so the global can
            // round-trip through the writer. The writer appends its
            // own trailing 0x0b, so we strip the terminator here.
            const expr_with_end = try self.readInitExprBytes();
            const expr_body: []const u8 = if (expr_with_end.len > 0)
                expr_with_end[0 .. expr_with_end.len - 1]
            else
                expr_with_end;
            try self.module.globals.append(self.allocator, .{
                .type = .{ .val_type = val_type, .mutability = mutability },
                .type_idx = global_indexed.type_idx,
                .init_expr_bytes = expr_body,
                .owns_init_expr_bytes = false,
            });
        }
    }

    fn readExportSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            const exp_name = try self.readName();
            if (!std.unicode.utf8ValidateSlice(exp_name)) return error.InvalidSection;
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
                const expr_with_end = try self.readInitExprBytes();
                seg.offset_expr_bytes = if (expr_with_end.len > 0)
                    expr_with_end[0 .. expr_with_end.len - 1]
                else
                    expr_with_end;
            }

            if (is_passive or has_explicit_index) {
                if (use_elem_exprs) {
                    const seg_indexed = try self.checkTypeIndex(try self.readRefType());
                    seg.elem_type = seg_indexed.vt;
                    seg.elem_type_idx = seg_indexed.type_idx;
                    // Element segment type must be a reference type
                    if (!seg.elem_type.isRefType()) return error.InvalidType;
                } else {
                    _ = try self.readByte(); // external kind (0=func)
                }
            }

            const elem_count = try self.readU32();
            seg.elem_var_indices = .empty;
            try seg.elem_var_indices.ensureTotalCapacity(self.allocator, elem_count);
            // Element expressions are laid out end to end, so the whole run
            // is one slice of the source. `elem_var_indices` keeps only the
            // function index each one happens to name, which is not enough to
            // print the segment back: `ref.null` has no index to keep.
            const elem_exprs_start = self.pos;
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
            if (use_elem_exprs) {
                seg.elem_expr_bytes = self.data[elem_exprs_start..self.pos];
                seg.owns_elem_expr_bytes = false;
                seg.elem_expr_count = elem_count;
            }

            try self.module.elem_segments.append(self.allocator, seg);
        }
        _ = end;
    }

    fn readCodeSection(self: *Reader, section_end: usize) ReadError!void {
        const count = try self.readU32();
        const expected = self.module.funcs.items.len - self.module.num_func_imports;
        if (count != expected) return error.FunctionCodeMismatch;

        for (0..count) |i| {
            const body_size = try self.readU32();
            const body_end = self.pos + body_size;
            if (body_end > self.data.len or body_end > section_end) return error.SectionTooLarge;

            const num_local_decls = try self.readU32();
            var total_locals: u64 = 0;
            const func_idx = self.module.num_func_imports + @as(u32, @intCast(i));
            for (0..num_local_decls) |_| {
                const local_count = try self.readU32();
                total_locals += local_count;
                if (total_locals > 50000) return error.TooManyLocals;
                const indexed = try self.checkTypeIndex(try self.readValType());
                for (0..local_count) |_| {
                    try self.module.funcs.items[func_idx].local_types.append(self.allocator, indexed.vt);
                    try self.module.funcs.items[func_idx].local_type_idxs.append(self.allocator, indexed.type_idx);
                }
            }
            // Validate function body ends with 0x0b (end opcode)
            if (body_end > 0 and self.data[body_end - 1] != 0x0b) return error.InvalidSection;
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
                const expr_with_end = try self.readInitExprBytes();
                seg.offset_expr_bytes = if (expr_with_end.len > 0)
                    expr_with_end[0 .. expr_with_end.len - 1]
                else
                    expr_with_end;
            }

            const data_len = try self.readU32();
            if (self.pos + data_len > self.data.len) return error.UnexpectedEof;
            seg.data = self.data[self.pos .. self.pos + data_len];
            self.pos += data_len;

            try self.module.data_segments.append(self.allocator, seg);
        }
    }

    fn readDataCountSection(self: *Reader, _: usize) ReadError!void {
        self.module.data_count = try self.readU32();
        self.module.has_data_count = true;
    }

    /// Resolve a tag's signature index against the type section.
    ///
    /// The index is the tag's whole type: dropping it left every
    /// binary-decoded tag with an empty signature, so `throw` had no
    /// parameters to check and the writer re-emitted the tag against
    /// whichever type happened to match `()`. The tag section always follows
    /// the type section, so this resolves immediately.
    ///
    /// The signature is copied because `Module.deinit` frees each tag's
    /// params and results; aliasing the type section's slices here would
    /// free them twice.
    fn readTagType(self: *Reader) ReadError!Mod.Tag {
        const attribute = try self.readByte();
        if (attribute != 0) return error.InvalidType; // 0 = exception; nothing else is defined
        const sig_index = try self.readU32();
        if (sig_index >= self.module.module_types.items.len) return error.InvalidType;
        const entry = self.module.module_types.items[sig_index];
        const sig = switch (entry) {
            .func_type => |ft| ft,
            else => return error.InvalidType,
        };
        const params = try self.allocator.dupe(types.ValType, sig.params);
        errdefer self.allocator.free(params);
        const results = try self.allocator.dupe(types.ValType, sig.results);
        return .{
            .@"type" = .{ .sig = .{ .params = params, .results = results } },
            .type_idx = sig_index,
        };
    }

    fn readTagSection(self: *Reader, _: usize) ReadError!void {
        const count = try self.readU32();
        for (0..count) |_| {
            try self.module.tags.append(self.allocator, try self.readTagType());
        }
    }

    fn readCustomSection(self: *Reader, end: usize) ReadError!void {
        if (self.pos >= end) return error.InvalidSection; // custom section must have a name
        const sect_name = try self.readName();
        if (self.pos > end) return error.UnexpectedEof;
        // Validate UTF-8 name
        if (!std.unicode.utf8ValidateSlice(sect_name)) return error.InvalidSection;
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

test "accept element then data_count then code then data ordering" {
    // The data-count section (id 12) is encoded between the element
    // section (id 9) and the code section (id 10). A naive ordering
    // check that remaps data_count's order to 9 sees `element(9),
    // data_count(→9)` as non-increasing and rejects this valid module
    // with InvalidSection. Regression for that false positive — this
    // is exactly the section layout Zig's wasm32 backend emits for a
    // module with a function table + passive/active data segments.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: one type () -> ()
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        // function section: one func of type 0
        0x03, 0x02, 0x01, 0x00,
        // table section: one funcref table, min 1
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01,
        // memory section: one memory, min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // element section (id 9): one active elem, table 0, offset 0, func 0
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00,
        // data count section (id 12): 1 data segment
        0x0c, 0x01, 0x01,
        // code section (id 10): one body, empty (just `end`)
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
        // data section (id 11): one active segment "hi"
        0x0b, 0x08, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x02, 'h', 'i',
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.data_segments.items.len);
    try std.testing.expect(module.has_data_count);
    try std.testing.expectEqual(@as(u32, 1), module.data_count);
}

// Drift guard: every abstract heap type must resolve to a *distinct* `ValType`
// in both its nullable and non-nullable form. The previous decoder collapsed
// most heap types onto `funcref` via an unconditional fallback, so unhandled
// types were indistinguishable from genuine `funcref`s and mismapped ones were
// invisible. A heap type added to the table with a duplicate or copy-pasted
// `ValType` now fails here instead of silently widening.
test "abstract heap types map to distinct value types" {
    var seen = std.AutoHashMap(types.ValType, void).init(std.testing.allocator);
    defer seen.deinit();
    var seen_codes = std.AutoHashMap(i64, void).init(std.testing.allocator);
    defer seen_codes.deinit();

    try std.testing.expectEqual(std.enums.values(types.AbstractHeapType).len, abstract_heap_types.len);
    inline for (std.enums.values(types.AbstractHeapType)) |heap| {
        var found = false;
        for (abstract_heap_types) |entry| {
            if (entry == heap) found = true;
        }
        try std.testing.expect(found);
    }

    for (abstract_heap_types) |entry| {
        const code: i64 = @intFromEnum(entry);
        const nullable_form = types.RefType.abstract(true, entry).toValType();
        const non_nullable_form = types.RefType.abstract(false, entry).toValType();

        try std.testing.expect(code < 0); // heap type codes are negative
        try std.testing.expect((try seen_codes.getOrPut(code)).found_existing == false);

        // Nullable and non-nullable forms are different types.
        try std.testing.expect(nullable_form != non_nullable_form);
        try std.testing.expect(nullable_form.isRefType());
        try std.testing.expect(non_nullable_form.isRefType());

        // No two heap types share a ValType.
        try std.testing.expect((try seen.getOrPut(nullable_form)).found_existing == false);
        try std.testing.expect((try seen.getOrPut(non_nullable_form)).found_existing == false);

        // Resolution round-trips.
        try std.testing.expectEqual(nullable_form, (try refTypeFromHeapType(code, true)).toValType());
        try std.testing.expectEqual(non_nullable_form, (try refTypeFromHeapType(code, false)).toValType());
    }

    // Every non-nullable internal marker in `ValType` is reachable from the
    // table, so none can be orphaned by a missing heap type entry.
    for ([_]types.ValType{
        .ref_func,   .ref_extern, .ref_any,    .ref_none,
        .ref_nofunc, .ref_noextern, .ref_eq,   .ref_i31,
        .ref_struct, .ref_array,  .ref_exn,    .ref_noexn,
    }) |vt| {
        try std.testing.expect(seen.contains(vt));
    }
}

test "readValType consumes the heaptype after a 0x63/0x64 prefix" {
    // `(ref null func)` and `funcref` denote the same type, so a type section
    // using the long form must decode identically to one using the shorthand.
    // Before this was fixed the prefix byte was mapped straight to an enum
    // member and the heaptype was left in the stream, desynchronising the
    // reader so that the *next* byte was misread — which surfaced as a
    // spurious `error.InvalidType` rather than as a decode failure.
    const allocator = std.testing.allocator;

    const long_form = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: count=1, func, params=1, 0x63 0x70 (ref null func), results=0
        0x01, 0x06, 0x01, 0x60, 0x01, 0x63, 0x70, 0x00,
    };
    const short_form = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x70, 0x00,
    };

    var m_long = try readModule(allocator, &long_form);
    defer m_long.deinit();
    var m_short = try readModule(allocator, &short_form);
    defer m_short.deinit();

    const long_sig = m_long.module_types.items[0].func_type;
    const short_sig = m_short.module_types.items[0].func_type;
    try std.testing.expectEqual(@as(usize, 1), long_sig.params.len);
    try std.testing.expectEqual(types.ValType.funcref, long_sig.params[0]);
    try std.testing.expectEqual(short_sig.params[0], long_sig.params[0]);

    // The non-nullable form is a different type, not the same one widened.
    const non_null_form = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x64, 0x70, 0x00,
    };
    var m_nn = try readModule(allocator, &non_null_form);
    defer m_nn.deinit();
    try std.testing.expectEqual(
        types.ValType.ref_func,
        m_nn.module_types.items[0].func_type.params[0],
    );
}

test "long-form reference types decode to the right type, not funcref" {
    // Each of these was previously either unhandled (falling through to
    // `funcref`) or mismapped by one position: `noextern` decoded as
    // `nullfuncref` and `none` as `nullexternref`.
    const allocator = std.testing.allocator;

    for (abstract_heap_types) |entry| {
        const code: i64 = @intFromEnum(entry);
        const nullable_form = types.RefType.abstract(true, entry).toValType();
        const non_nullable_form = types.RefType.abstract(false, entry).toValType();
        // One-byte s33 LEB128 form of the (negative) heap type code.
        const heap_byte: u8 = @intCast(code & 0x7f);

        inline for (.{ true, false }) |nullable| {
            const prefix: u8 = if (nullable) ref_null_prefix else ref_prefix;
            const src = [_]u8{
                0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
                0x01, 0x06, 0x01, 0x60, 0x01, prefix, heap_byte, 0x00,
            };
            var module = try readModule(allocator, &src);
            defer module.deinit();
            const expected = if (nullable) nullable_form else non_nullable_form;
            try std.testing.expectEqual(
                expected,
                module.module_types.items[0].func_type.params[0],
            );
        }
    }
}

test "concrete type indices are decoded and kept, not widened to funcref" {
    // Bytes from `wasm-tools parse` v1.250.0 for:
    //   (type $t (func))
    //   (type $u (func (param (ref null $t)) (result (ref $t))))
    //   (global (ref null $t) (ref.null $t))
    //   (func (local (ref null $t)))
    // `ValType` cannot carry the index, so every one of these must survive in
    // the matching out-of-line slot. Widening any of them back to funcref, or
    // dropping the index, loses the callee identity `call_ref` depends on.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0b, 0x02, 0x60, 0x00, 0x00, 0x60, 0x01, 0x63, 0x00, 0x01, 0x64, 0x00,
        0x03, 0x02, 0x01, 0x00,
        0x06, 0x07, 0x01, 0x63, 0x00, 0x00, 0xd0, 0x00, 0x0b,
        0x0a, 0x07, 0x01, 0x05, 0x01, 0x01, 0x63, 0x00, 0x0b,
    };
    var module = try readModule(allocator, &src);
    defer module.deinit();

    const ft = module.module_types.items[1].func_type;
    try std.testing.expectEqual(types.ValType.concrete_ref_null, ft.params[0]);
    try std.testing.expectEqual(@as(u32, 0), ft.param_type_idxs[0]);
    try std.testing.expectEqual(types.ValType.concrete_ref, ft.results[0]);
    try std.testing.expectEqual(@as(u32, 0), ft.result_type_idxs[0]);

    try std.testing.expectEqual(types.ValType.concrete_ref_null, module.globals.items[0].type.val_type);
    try std.testing.expectEqual(@as(u32, 0), module.globals.items[0].type_idx);

    const func = module.funcs.items[0];
    try std.testing.expectEqual(types.ValType.concrete_ref_null, func.local_types.items[0]);
    try std.testing.expectEqual(@as(u32, 0), func.local_type_idxs.items[0]);
}

test "a concrete type index past the end of the type section is rejected" {
    // Fail closed: index 7 names a type the module does not define. Forward
    // references inside the type section are legal, so this can only be
    // detected once the section is fully read.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x63, 0x07, 0x00,
    };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &src));
}

test "a forward concrete type reference inside the type section is accepted" {
    // type 0 = (func (param (ref null 1))); type 1 = (func). Index 1 is not
    // yet defined when type 0 is read, so a naive immediate bounds check
    // would wrongly reject this.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x60, 0x01, 0x63, 0x01, 0x00, 0x60, 0x00, 0x00,
    };
    var module = try readModule(allocator, &src);
    defer module.deinit();
    try std.testing.expectEqual(@as(u32, 1), module.module_types.items[0].func_type.param_type_idxs[0]);
}

test "unknown abstract heap types stay a plain type error" {
    const allocator = std.testing.allocator;
    const unknown = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x60, 0x01, 0x63, 0x50, 0x00,
    };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &unknown));
}

test "table element types use the full heap type table" {
    // `readRefType` had its own, shorter heap type mapping ending in an
    // unconditional widen to `funcref`, so a table declared
    // `(ref null noextern)` was read as a table of `nullfuncref`.
    const allocator = std.testing.allocator;

    const cases = [_]struct { u8, types.ValType }{
        .{ 0x72, .nullexternref }, // noextern
        .{ 0x71, .nullref }, // none
        .{ 0x73, .nullfuncref }, // nofunc
        .{ 0x6d, .eqref }, // eq
        .{ 0x69, .exnref }, // exn
    };

    for (cases) |case| {
        const heap_byte, const expected = case;
        const src = [_]u8{
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
            // table section: count=1, (ref null <heap>), limits min=1
            0x04, 0x05, 0x01, ref_null_prefix, heap_byte, 0x00, 0x01,
        };
        var module = try readModule(allocator, &src);
        defer module.deinit();
        try std.testing.expectEqual(@as(usize, 1), module.tables.items.len);
        try std.testing.expectEqual(expected, module.tables.items[0].@"type".elem_type);
    }
}

test "the tag section is accepted between the memory and global sections" {
    // Bytes from `wasm-tools parse` v1.250.0 for:
    //   (module (memory 1) (tag $a (param i32))
    //           (global $g i32 (i32.const 0)) (func (export "f")))
    // Sections come out as 1, 3, 5, 13, 6, 7, 10 -- the tag section has id 13
    // but is ordered between memory (5) and global (6). Sorting it by its id
    // instead put it after every other section, so wabt rejected every module
    // with a tag as `InvalidSection`, including its own writer's output.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x01,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x0d, 0x03, 0x01, 0x00, 0x00,
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
    };
    var module = try readModule(allocator, &src);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.tags.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.globals.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.memories.items.len);
}

test "the tag and data-count half-steps coexist in one module" {
    // Bytes from `wasm-tools parse` v1.250.0 for a module with a memory, a
    // tag, a passive data segment and a `memory.init`: sections 1, 3, 5, 13,
    // 12, 10, 11. Both out-of-order sections appear at once, so getting
    // either half-step wrong rejects this.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x08, 0x02, 0x60, 0x01, 0x7f, 0x00, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x01,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x0d, 0x03, 0x01, 0x00, 0x00,
        0x0c, 0x01, 0x01,
        0x0a, 0x0e, 0x01, 0x0c, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x01, 0xfc, 0x08, 0x00, 0x00, 0x0b,
        0x0b, 0x04, 0x01, 0x01, 0x01, 0x78,
    };
    var module = try readModule(allocator, &src);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.tags.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.data_segments.items.len);
}

test "a tag section after the global section is still rejected" {
    // Accepting the tag section in its proper place must not turn the
    // ordering check off for it: 6 then 13 is genuinely misordered.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00,
        0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b,
        0x0d, 0x03, 0x01, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidSection, readModule(allocator, &src));
}

test "a duplicate tag section is rejected" {
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00,
        0x0d, 0x03, 0x01, 0x00, 0x00,
        0x0d, 0x03, 0x01, 0x00, 0x00,
    };
    try std.testing.expectError(error.InvalidSection, readModule(allocator, &src));
}

test "section order positions are strictly increasing in binary-grammar order" {
    // Drift guard. The two out-of-place sections (tag 13, data count 12) are
    // easy to reintroduce as bugs by "simplifying" sectionOrder back to a
    // plain id comparison, which reads as an obvious cleanup and silently
    // rejects every module with a tag. Assert the grammar order directly.
    const grammar_order = [_]u8{
        1, // type
        2, // import
        3, // function
        4, // table
        5, // memory
        13, // tag
        6, // global
        7, // export
        8, // start
        9, // element
        12, // data count
        10, // code
        11, // data
    };
    var prev: u8 = 0;
    for (grammar_order) |id| {
        const pos = sectionOrder(id);
        try std.testing.expect(pos > prev);
        prev = pos;
    }
    // Every section must also land on its own position, or two distinct
    // sections would look like a duplicate of one another.
    for (grammar_order, 0..) |a, i| {
        for (grammar_order[i + 1 ..]) |b| {
            try std.testing.expect(sectionOrder(a) != sectionOrder(b));
        }
    }
}

test "tag signatures survive decoding" {
    // Bytes from `wasm-tools parse` v1.250.0 for:
    //   (type (func (param f64 f64)))   ;; 0
    //   (type (func (param i32 i64)))   ;; 1
    //   (tag $a (param i32 i64))        ;; -> type 1
    //   (tag $b (param f64 f64))        ;; -> type 0
    // The signature index used to be read and discarded, leaving every
    // binary-decoded tag with an empty signature. Nothing downstream could
    // tell the two tags apart afterwards, and the writer re-emitted both
    // against whichever type matched `()`.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0e, 0x03, 0x60, 0x02, 0x7c, 0x7c, 0x00, 0x60, 0x02, 0x7f, 0x7e, 0x00, 0x60, 0x00, 0x00,
        0x03, 0x02, 0x01, 0x02,
        0x0d, 0x05, 0x02, 0x00, 0x01, 0x00, 0x00,
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
        0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x01, 0x42, 0x02, 0x08, 0x00, 0x0b,
    };
    var module = try readModule(allocator, &src);
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 2), module.tags.items.len);
    const a = module.tags.items[0];
    try std.testing.expectEqual(@as(u32, 1), a.type_idx);
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .i64 }, a.@"type".sig.params);
    const b = module.tags.items[1];
    try std.testing.expectEqual(@as(u32, 0), b.type_idx);
    try std.testing.expectEqualSlices(types.ValType, &.{ .f64, .f64 }, b.@"type".sig.params);
}

test "imported tag signatures survive decoding" {
    // Bytes from `wasm-tools parse` v1.250.0 for
    //   (type (func)) (type (func (param i32 i64)))
    //   (import "m" "e" (tag (param i32 i64)))
    // Imported tags took the same discard path as defined ones.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x09, 0x02, 0x60, 0x00, 0x00, 0x60, 0x02, 0x7f, 0x7e, 0x00,
        0x02, 0x08, 0x01, 0x01, 0x6d, 0x01, 0x65, 0x04, 0x00, 0x01,
    };
    var module = try readModule(allocator, &src);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.tags.items.len);
    try std.testing.expectEqual(@as(u32, 1), module.num_tag_imports);
    const tag = module.tags.items[0];
    try std.testing.expect(tag.is_import);
    try std.testing.expectEqual(@as(u32, 1), tag.type_idx);
    try std.testing.expectEqualSlices(types.ValType, &.{ .i32, .i64 }, tag.@"type".sig.params);
    try std.testing.expectEqualSlices(
        types.ValType,
        &.{ .i32, .i64 },
        module.imports.items[0].tag.?.sig.params,
    );
}

test "a tag signature index past the end of the type section is rejected" {
    // Fail closed rather than leaving the tag with a default signature.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x0d, 0x03, 0x01, 0x00, 0x07,
    };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &src));
}

test "a tag with a non-zero attribute byte is rejected" {
    // 0 (exception) is the only attribute the format defines. Skipping the
    // byte unchecked would silently accept a future or corrupt encoding.
    const allocator = std.testing.allocator;
    const src = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
        0x0d, 0x03, 0x01, 0x01, 0x00,
    };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &src));
}

test "read a struct type" {
    // (module (type (struct (field i32) (field (mut f64)))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x5f, 0x02, 0x7f, 0x00, 0x7c, 0x01,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.module_types.items.len);
    const st = module.module_types.items[0].struct_type;
    try std.testing.expectEqual(@as(usize, 2), st.fields.items.len);
    try std.testing.expectEqual(types.ValType.i32, st.fields.items[0].@"type");
    try std.testing.expect(!st.fields.items[0].mutable);
    try std.testing.expectEqual(types.ValType.f64, st.fields.items[1].@"type");
    try std.testing.expect(st.fields.items[1].mutable);
    try std.testing.expectEqual(Mod.TypeMeta.Kind.struct_, module.type_meta.items[0].kind);
}

test "read an array type, including a packed element" {
    // (module (type (array (mut i8))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x5e, 0x78, 0x01,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    const at = module.module_types.items[0].array_type;
    try std.testing.expectEqual(types.ValType.i8, at.field.@"type");
    try std.testing.expect(at.field.mutable);
    try std.testing.expectEqual(Mod.TypeMeta.Kind.array, module.type_meta.items[0].kind);

    // An immutable `i16` element, to pin the other packed byte down too.
    const i16_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x5e, 0x77, 0x00,
    };
    var m16 = try readModule(std.testing.allocator, &i16_bytes);
    defer m16.deinit();
    try std.testing.expectEqual(types.ValType.i16, m16.module_types.items[0].array_type.field.@"type");
    try std.testing.expect(!m16.module_types.items[0].array_type.field.mutable);
}

test "a recursion group is one entry in the type section count" {
    // (module (rec (type $a (struct (field (ref null $b))))
    //              (type $b (struct (field (ref null $a))))))
    // The vector length is 1 -- a rec group counts once however many types it
    // holds -- so reading it as a type count loses the second type and then
    // desynchronises on whatever follows.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x0d, 0x01, 0x4e, 0x02,
        0x5f, 0x01, 0x63, 0x01, 0x00,
        0x5f, 0x01, 0x63, 0x00, 0x00,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 2), module.module_types.items.len);
    try std.testing.expectEqual(@as(usize, 2), module.type_meta.items.len);
    for (module.type_meta.items, 0..) |meta, i| {
        try std.testing.expectEqual(@as(u32, 2), meta.rec_group_size);
        try std.testing.expectEqual(@as(u32, 0), meta.rec_group);
        try std.testing.expectEqual(@as(u32, @intCast(i)), meta.rec_position);
    }
    // The two types refer to each other, which is only expressible inside a
    // rec group and only resolvable once the whole section has been read.
    try std.testing.expectEqual(@as(u32, 1), module.module_types.items[0].struct_type.fields.items[0].type_idx);
    try std.testing.expectEqual(@as(u32, 0), module.module_types.items[1].struct_type.fields.items[0].type_idx);
}

test "read sub and sub final types" {
    // (module (type $b (sub (struct (field i32))))
    //         (type $d (sub $b (struct (field i32) (field f64)))))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x10, 0x02,
        0x50, 0x00, 0x5f, 0x01, 0x7f, 0x00,
        0x50, 0x01, 0x00, 0x5f, 0x02, 0x7f, 0x00, 0x7c, 0x00,
    };
    var module = try readModule(std.testing.allocator, &bytes);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 2), module.module_types.items.len);
    try std.testing.expect(module.type_meta.items[0].is_sub);
    try std.testing.expect(!module.type_meta.items[0].is_final);
    try std.testing.expectEqual(types.invalid_index, module.type_meta.items[0].parent);
    try std.testing.expectEqual(@as(u32, 0), module.type_meta.items[1].parent);

    // `sub final` is the same shape with a different marker byte.
    const final_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x06, 0x01, 0x4f, 0x00, 0x60, 0x00, 0x00,
    };
    var fin = try readModule(std.testing.allocator, &final_bytes);
    defer fin.deinit();
    try std.testing.expect(fin.type_meta.items[0].is_sub);
    try std.testing.expect(fin.type_meta.items[0].is_final);
}

test "malformed type definitions are rejected" {
    const allocator = std.testing.allocator;
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    // An unassigned form byte. 0x5d sits just below the array form.
    const bad_form = header ++ [_]u8{ 0x01, 0x03, 0x01, 0x5d, 0x00 };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &bad_form));

    // The supertype list is a vector, but at most one entry is allowed.
    const two_supers = header ++ [_]u8{ 0x01, 0x08, 0x01, 0x50, 0x02, 0x00, 0x00, 0x60, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &two_supers));

    // A supertype index the module does not have.
    const bad_parent = header ++ [_]u8{ 0x01, 0x06, 0x01, 0x50, 0x01, 0x09, 0x60, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &bad_parent));

    // Mutability is a single boolean byte.
    const bad_mut = header ++ [_]u8{ 0x01, 0x04, 0x01, 0x5e, 0x7f, 0x02 };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &bad_mut));

    // A field naming a type index past the end of the section.
    const bad_field_idx = header ++ [_]u8{ 0x01, 0x06, 0x01, 0x5f, 0x01, 0x63, 0x09, 0x00 };
    try std.testing.expectError(error.InvalidType, readModule(allocator, &bad_field_idx));
}
