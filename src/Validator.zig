//! WebAssembly module validator.
//!
//! Validates a parsed Module against the WebAssembly specification,
//! checking types, indices, limits, exports, start function, and more.

const std = @import("std");
const types = @import("types.zig");
const Mod = @import("Module.zig");
const Feature = @import("Feature.zig");
const leb128 = @import("leb128.zig");
const Opcode = @import("Opcode.zig");

pub const Error = error{
    InvalidTypeIndex,
    InvalidFuncIndex,
    InvalidTableIndex,
    InvalidMemoryIndex,
    InvalidGlobalIndex,
    InvalidTagIndex,
    InvalidElemIndex,
    InvalidDataIndex,
    InvalidLimits,
    InvalidExport,
    DuplicateExport,
    InvalidStart,
    TooManyMemories,
    TooManyTables,
    InvalidElemType,
    InvalidLocalIndex,
    InvalidLabelIndex,
    ImmutableGlobal,
    TypeMismatch,
    ConstantExprRequired,
    InvalidAlignment,
    /// The byte (or prefixed sub-opcode) does not encode any instruction
    /// this build knows about, so the module is malformed.
    UnknownOpcode,
    /// A real instruction that this validator cannot type-check yet.
    /// Reported rather than skipped: a validator that stops checking is
    /// not entitled to report success. See issue #347.
    UnsupportedOpcode,
    /// A lane index immediate selects a lane the operand shape does not have.
    InvalidLaneIndex,
    /// An instruction's immediate operands run past the end of the body.
    UnexpectedEnd,
    OutOfMemory,
};

pub const Options = struct {
    features: Feature.Set = .{},
};

/// Validate a WebAssembly module.
pub fn validate(module: *const Mod.Module, options: Options) Error!void {
    try checkTypes(module);
    try checkImports(module);
    try checkFunctions(module);
    try checkTables(module, options);
    try checkMemories(module, options);
    try checkGlobals(module);
    try checkTags(module);
    try checkExports(module);
    try checkStart(module);
    try checkElemSegments(module);
    try checkDataSegments(module);
    try checkFunctionBodies(module);
}

// ── Validation passes ───────────────────────────────────────────────────

fn checkTypes(m: *const Mod.Module) Error!void {
    for (m.module_types.items) |entry| {
        switch (entry) {
            .func_type => |ft| {
                for (ft.params) |p| {
                    if (!p.isNumType() and !p.isRefType()) return error.InvalidTypeIndex;
                }
                for (ft.results) |r| {
                    if (!r.isNumType() and !r.isRefType()) return error.InvalidTypeIndex;
                }
            },
            else => {},
        }
    }
    // Validate GC subtype declarations
    for (m.type_meta.items, 0..) |meta, idx| {
        if (meta.parent != std.math.maxInt(u32)) {
            // Has a parent — validate subtyping
            if (meta.parent >= m.type_meta.items.len) return error.InvalidTypeIndex;
            const parent_meta = m.type_meta.items[meta.parent];
            // Parent must be non-final (declared with 'sub' and not 'final')
            if (parent_meta.is_final) return error.TypeMismatch;
            // Kind must match
            if (meta.kind != parent_meta.kind) return error.TypeMismatch;
            // Structural check for func types: param/result counts must match
            if (meta.kind == .func and idx < m.module_types.items.len and
                meta.parent < m.module_types.items.len)
            {
                switch (m.module_types.items[idx]) {
                    .func_type => |child_ft| switch (m.module_types.items[meta.parent]) {
                        .func_type => |parent_ft| {
                            if (child_ft.params.len != parent_ft.params.len or
                                child_ft.results.len != parent_ft.results.len)
                                return error.TypeMismatch;
                        },
                        else => {},
                    },
                    else => {},
                }
            }
            // Structural check for array types: element types must be compatible
            if (meta.kind == .array and idx < m.module_types.items.len and
                meta.parent < m.module_types.items.len)
            {
                switch (m.module_types.items[idx]) {
                    .array_type => |child_at| switch (m.module_types.items[meta.parent]) {
                        .array_type => |parent_at| {
                            // Mutable fields must have exact same type; immutable: child <: parent
                            if (child_at.field.mutable != parent_at.field.mutable)
                                return error.TypeMismatch;
                            if (child_at.field.mutable) {
                                // Mutable: types must be exactly equal
                                if (child_at.field.@"type" != parent_at.field.@"type")
                                    return error.TypeMismatch;
                            } else {
                                // Immutable: child element type must be subtype of parent
                                if (child_at.field.@"type" != parent_at.field.@"type") {
                                    // Check basic subtyping
                                    const cv = ValTypeOrUnknown.fromValType(child_at.field.@"type");
                                    const pv = ValTypeOrUnknown.fromValType(parent_at.field.@"type");
                                    if (!cv.isSubtypeOf(pv)) return error.TypeMismatch;
                                }
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
            // Structural check for struct types: fields must be compatible
            if (meta.kind == .struct_ and idx < m.module_types.items.len and
                meta.parent < m.module_types.items.len)
            {
                switch (m.module_types.items[idx]) {
                    .struct_type => |child_st| switch (m.module_types.items[meta.parent]) {
                        .struct_type => |parent_st| {
                            // Child must have at least as many fields as parent
                            if (child_st.fields.items.len < parent_st.fields.items.len)
                                return error.TypeMismatch;
                            // Each parent field must be compatible with corresponding child field
                            for (parent_st.fields.items, 0..) |pf, fi| {
                                if (fi >= child_st.fields.items.len) break;
                                const cf = child_st.fields.items[fi];
                                if (cf.mutable != pf.mutable) return error.TypeMismatch;
                                if (cf.mutable) {
                                    if (cf.@"type" != pf.@"type") return error.TypeMismatch;
                                } else {
                                    if (cf.@"type" != pf.@"type") {
                                        const cv = ValTypeOrUnknown.fromValType(cf.@"type");
                                        const pv = ValTypeOrUnknown.fromValType(pf.@"type");
                                        if (!cv.isSubtypeOf(pv)) return error.TypeMismatch;
                                    }
                                }
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }
}

fn checkImports(m: *const Mod.Module) Error!void {
    for (m.imports.items) |imp| {
        switch (imp.kind) {
            .func => if (imp.func) |f| {
                if (f.type_var.index >= m.module_types.items.len)
                    return error.InvalidTypeIndex;
            },
            else => {},
        }
    }
}

fn checkFunctions(m: *const Mod.Module) Error!void {
    for (m.funcs.items) |func| {
        if (func.decl.type_var.index != types.invalid_index) {
            if (func.decl.type_var.index >= m.module_types.items.len)
                return error.InvalidTypeIndex;
        }
    }
}

fn checkTables(m: *const Mod.Module, options: Options) Error!void {
    if (!options.features.reference_types and m.tables.items.len > 1)
        return error.TooManyTables;

    for (m.tables.items) |table| {
        if (!table.type.elem_type.isRefType())
            return error.InvalidElemType;
        // Non-nullable ref types require init expr (tables without init are invalid)
        const vt = ValTypeOrUnknown.fromValType(table.type.elem_type);
        if (vt.isNonNullableRef())
            return error.TypeMismatch;
        try checkLimits(table.@"type".limits, std.math.maxInt(u32));
        // Validate table init expression type
        if (table.init_expr_bytes.len > 0) {
            // Check init expr produces a ref type matching the table's elem type
            const first_byte = table.init_expr_bytes[0];
            if (first_byte == 0x41 or first_byte == 0x42 or first_byte == 0x43 or first_byte == 0x44) {
                // Numeric const — invalid for ref table
                return error.TypeMismatch;
            }
            // Check global.get references an imported global
            if (first_byte == 0x23) {
                const gidx = leb128.readU32Leb128(table.init_expr_bytes[1..]) catch return error.TypeMismatch;
                if (gidx.value >= m.globals.items.len) return error.InvalidGlobalIndex;
                if (!m.isGlobalImport(gidx.value)) return error.TypeMismatch;
            }
        }
    }
}

fn checkMemories(m: *const Mod.Module, options: Options) Error!void {
    if (!options.features.multi_memory and m.memories.items.len > 1)
        return error.TooManyMemories;

    for (m.memories.items) |mem| {
        const max_pages: u64 = if (mem.type.limits.is_64)
            1 << 48
        else
            65536; // 4GiB = 65536 pages of 64KiB
        try checkLimits(mem.type.limits, max_pages);
    }
}

fn checkGlobals(m: *const Mod.Module) Error!void {
    for (m.globals.items, 0..) |global, i| {
        if (!global.type.val_type.isNumType() and !global.type.val_type.isRefType())
            return error.InvalidTypeIndex;
        // Validate init expression for non-imported globals
        if (!global.is_import) {
            const expected = ValTypeOrUnknown.fromValType(global.type.val_type);
            try checkConstExpr(m, global.init_expr_bytes, expected, @intCast(i));
        }
    }
}

fn checkTags(m: *const Mod.Module) Error!void {
    for (m.tags.items) |tag| {
        // Tag types must have empty result types per spec.
        if (tag.@"type".sig.results.len > 0) return error.TypeMismatch;
    }
}

fn checkExports(m: *const Mod.Module) Error!void {
    // Check for duplicate export names (O(n²) but simple)
    for (m.exports.items, 0..) |exp, i| {
        // Validate export target index
        switch (exp.kind) {
            .func => if (exp.var_.index >= m.funcs.items.len) return error.InvalidFuncIndex,
            .table => if (exp.var_.index >= m.tables.items.len) return error.InvalidTableIndex,
            .memory => if (exp.var_.index >= m.memories.items.len) return error.InvalidMemoryIndex,
            .global => if (exp.var_.index >= m.globals.items.len) return error.InvalidGlobalIndex,
            .tag => if (exp.var_.index >= m.tags.items.len) return error.InvalidTagIndex,
        }

        // Check for duplicate names
        for (m.exports.items[0..i]) |prev| {
            if (std.mem.eql(u8, exp.name, prev.name))
                return error.DuplicateExport;
        }
    }
}

fn checkStart(m: *const Mod.Module) Error!void {
    const sv = m.start_var orelse return;
    if (sv.index >= m.funcs.items.len)
        return error.InvalidFuncIndex;

    // Start function must be nullary and return nothing
    const func = m.funcs.items[sv.index];
    if (func.decl.type_var.index != types.invalid_index and
        func.decl.type_var.index < m.module_types.items.len)
    {
        const entry = m.module_types.items[func.decl.type_var.index];
        switch (entry) {
            .func_type => |ft| {
                if (ft.params.len != 0 or ft.results.len != 0)
                    return error.InvalidStart;
            },
            else => {},
        }
    }
}

fn checkElemSegments(m: *const Mod.Module) Error!void {
    for (m.elem_segments.items) |seg| {
        // Validate elem type index references a valid type
        if (seg.elem_type_idx != 0xFFFFFFFF and seg.elem_type_idx >= m.module_types.items.len)
            return error.InvalidTypeIndex;
        if (seg.kind == .active) {
            if (m.tables.items.len == 0 or seg.table_var.index >= m.tables.items.len)
                return error.InvalidTableIndex;
            // Validate offset expression (even if empty — must produce i32)
            try checkConstExpr(m, seg.offset_expr_bytes, .i32, null);
            // Validate elem type matches table type
            const table = m.tables.items[seg.table_var.index];
            if (seg.elem_type != table.type.elem_type)
                return error.TypeMismatch;
        }
        // Validate elem expressions
        if (seg.elem_expr_count > 0) {
            const expected = ValTypeOrUnknown.fromValType(seg.elem_type);
            try checkElemExprs(m, seg.elem_expr_bytes, expected, seg.elem_expr_count);
        }
        // Validate that func refs in funcref segments actually exist
        for (seg.elem_var_indices.items) |v| {
            if (v.index >= m.funcs.items.len)
                return error.InvalidFuncIndex;
        }
    }
}

/// Validate elem expressions encoded as consecutive constant expressions
/// separated by 0x0b terminators.
fn checkElemExprs(m: *const Mod.Module, bytes: []const u8, expected: ValTypeOrUnknown, count: u32) Error!void {
    var pos: usize = 0;
    var remaining = count;

    while (remaining > 0 and pos < bytes.len) {
        // Find the end of this expression (terminated by 0x0b)
        var expr_end = pos;
        while (expr_end < bytes.len and bytes[expr_end] != 0x0b) : (expr_end += 1) {}
        const expr_bytes = bytes[pos..expr_end];

        try checkConstExpr(m, expr_bytes, expected, null);

        // Skip past the 0x0b terminator
        if (expr_end < bytes.len) expr_end += 1;
        pos = expr_end;
        remaining -= 1;
    }
}

fn checkDataSegments(m: *const Mod.Module) Error!void {
    for (m.data_segments.items) |seg| {
        if (seg.kind == .active) {
            if (m.memories.items.len == 0 or seg.memory_var.index >= m.memories.items.len)
                return error.InvalidMemoryIndex;
            // Validate offset expression (even if empty — must produce i32)
            try checkConstExpr(m, seg.offset_expr_bytes, .i32, null);
        }
    }
}

fn checkLimits(limits: types.Limits, absolute_max: u64) Error!void {
    if (limits.initial > absolute_max)
        return error.InvalidLimits;
    if (limits.has_max) {
        if (limits.max > absolute_max)
            return error.InvalidLimits;
        if (limits.max < limits.initial)
            return error.InvalidLimits;
    }
}

// ── Constant expression validation ──────────────────────────────────────

/// Validate a constant expression (used in global init, data/elem offsets).
/// Only constant instructions are allowed: i32.const, i64.const, f32.const, f64.const,
/// ref.null, ref.func, and global.get (of an immutable imported global).
/// The expression must produce exactly one value of the expected type.
/// `global_limit` restricts global.get to reference only imported globals with
/// index < global_limit (for global init, this is the current global's index).
fn checkConstExpr(m: *const Mod.Module, bytes: []const u8, expected: ValTypeOrUnknown, global_limit: ?u32) Error!void {
    var pos: usize = 0;
    var stack_depth: u32 = 0;
    var result_type: ValTypeOrUnknown = .unknown;

    while (pos < bytes.len) {
        const opcode = bytes[pos];
        pos += 1;

        switch (opcode) {
            0x41 => { // i32.const
                _ = readS32(bytes, &pos);
                stack_depth += 1;
                result_type = .i32;
            },
            0x42 => { // i64.const
                _ = readS64(bytes, &pos);
                stack_depth += 1;
                result_type = .i64;
            },
            0x43 => { // f32.const
                pos += 4;
                stack_depth += 1;
                result_type = .f32;
            },
            0x44 => { // f64.const
                pos += 8;
                stack_depth += 1;
                result_type = .f64;
            },
            0xd0 => { // ref.null
                if (pos < bytes.len) {
                    const reftype_byte = bytes[pos];
                    pos += 1;
                    result_type = if (reftype_byte == 0x6f) .externref else .funcref;
                } else {
                    result_type = .funcref;
                }
                stack_depth += 1;
            },
            0xd2 => { // ref.func
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                stack_depth += 1;
                result_type = .funcref;
            },
            0x23 => { // global.get
                const idx = readU32(bytes, &pos);
                // In a global init, can only reference imported immutable globals
                // with index < the current global being defined
                if (global_limit) |limit| {
                    // For global init: only imported immutable globals with index < current
                    if (idx >= limit or idx >= m.globals.items.len)
                        return error.InvalidGlobalIndex;
                    if (!m.globals.items[idx].is_import)
                        return error.InvalidGlobalIndex;
                    if (m.globals.items[idx].type.mutability == .mutable)
                        return error.ConstantExprRequired;
                } else {
                    // For data/elem offsets: only imported immutable globals
                    if (idx >= m.globals.items.len)
                        return error.InvalidGlobalIndex;
                    if (!m.globals.items[idx].is_import)
                        return error.InvalidGlobalIndex;
                    if (m.globals.items[idx].type.mutability == .mutable)
                        return error.ConstantExprRequired;
                }
                const gt = ValTypeOrUnknown.fromValType(m.globals.items[idx].type.val_type);
                stack_depth += 1;
                result_type = gt;
            },
            0x0b => break, // end
            else => {
                // Any other opcode is not allowed in constant expressions
                return error.ConstantExprRequired;
            },
        }
    }

    // Must produce exactly one value
    if (stack_depth == 0) return error.TypeMismatch;
    if (stack_depth > 1) return error.TypeMismatch;

    // Type must match expected
    if (!result_type.matches(expected)) return error.TypeMismatch;
}

// ── Unrecognised opcode classification ──────────────────────────────────

/// Classify an opcode the instruction switch has no arm for.
///
/// Returns `UnsupportedOpcode` when `Opcode.Code` declares the instruction —
/// it is real, this validator just cannot type-check it yet — and
/// `UnknownOpcode` when the encoding is meaningless.
///
/// `Opcode.Code` is a non-exhaustive enum, so knownness is a test for a
/// declared field rather than a successful int-to-enum cast.
///
/// Both are errors on purpose. The previous behaviour was to `break` out
/// of the instruction loop, which abandoned validation for the rest of the
/// body; because the function-level control frame was then never popped,
/// the body was ultimately rejected as `TypeMismatch`. That made every
/// SIMD module fail validation with an error naming a cause that did not
/// exist. See issue #347.
fn classifyOpcode(prefix: ?u8, code: u32) Error {
    // Opcode.Code packs prefixed opcodes at variable width: 0xPPCC for
    // sub-opcodes that fit in a byte, 0xPPCCC for the wider ones (relaxed
    // SIMD starts at 0xfd100). Mirror Opcode.getPrefix/getCode exactly --
    // a fixed <<8 would fold 0xfd 0x100 onto 0xfd00, i.e. v128.load.
    const disc: u32 = if (prefix) |p|
        (if (code <= 0xff) (@as(u32, p) << 8) | code else (@as(u32, p) << 12) | code)
    else
        code;
    const tag: Opcode.Code = @enumFromInt(disc);
    if (std.enums.tagName(Opcode.Code, tag) == null) return error.UnknownOpcode;
    return error.UnsupportedOpcode;
}

// ── Memory alignment validation ─────────────────────────────────────────

/// Return the maximum allowed alignment (as log2) for a memory opcode.
fn maxAlignmentForOpcode(opcode: u8) ?u32 {
    return switch (opcode) {
        0x28 => 2, // i32.load: 4 bytes
        0x29 => 3, // i64.load: 8 bytes
        0x2a => 2, // f32.load: 4 bytes
        0x2b => 3, // f64.load: 8 bytes
        0x2c, 0x2d => 0, // i32.load8_s/u: 1 byte
        0x2e, 0x2f => 1, // i32.load16_s/u: 2 bytes
        0x30, 0x31 => 0, // i64.load8_s/u: 1 byte
        0x32, 0x33 => 1, // i64.load16_s/u: 2 bytes
        0x34, 0x35 => 2, // i64.load32_s/u: 4 bytes
        0x36 => 2, // i32.store
        0x37 => 3, // i64.store
        0x38 => 2, // f32.store
        0x39 => 3, // f64.store
        0x3a => 0, // i32.store8
        0x3b => 1, // i32.store16
        0x3c => 0, // i64.store8
        0x3d => 1, // i64.store16
        0x3e => 2, // i64.store32
        else => null,
    };
}

// ── Function body validation ────────────────────────────────────────────

fn checkFunctionBodies(m: *const Mod.Module) Error!void {
    // Build set of "declared" function indices for ref.func validation.
    // A function is declared if it appears in an element segment or is exported.
    var declared = std.AutoHashMapUnmanaged(u32, void){};
    defer declared.deinit(gpa(m));
    for (m.elem_segments.items) |seg| {
        for (seg.elem_var_indices.items) |v| {
            declared.put(gpa(m), v.index, {}) catch {};
        }
        // Also scan elem_expr_bytes for ref.func instructions
        if (seg.elem_expr_count > 0) {
            var epos: usize = 0;
            while (epos < seg.elem_expr_bytes.len) {
                const op = seg.elem_expr_bytes[epos];
                epos += 1;
                if (op == 0xd2) { // ref.func
                    const r = leb128.readU32Leb128(seg.elem_expr_bytes[epos..]) catch break;
                    epos += r.bytes_read;
                    declared.put(gpa(m), r.value, {}) catch {};
                } else if (op == 0xd0) { // ref.null
                    if (epos < seg.elem_expr_bytes.len) epos += 1;
                } else if (op == 0x0b) { // end
                    continue;
                } else {
                    break;
                }
            }
        }
    }
    for (m.exports.items) |exp| {
        if (exp.kind == .func) declared.put(gpa(m), exp.var_.index, {}) catch {};
    }

    for (m.funcs.items) |func| {
        if (func.is_import) continue;
        if (func.code_bytes.len == 0) continue;
        try checkOneBody(m, &func, &declared);
    }
}

/// Resolve the signature (params, results) for a function.
fn resolveSig(m: *const Mod.Module, decl: Mod.FuncDeclaration) struct { params: []const types.ValType, results: []const types.ValType } {
    if (decl.type_var != .index) return .{ .params = &.{}, .results = &.{} };
    const ti = decl.type_var.index;
    if (ti == types.invalid_index or ti >= m.module_types.items.len) return .{ .params = &.{}, .results = &.{} };
    return switch (m.module_types.items[ti]) {
        .func_type => |ft| .{ .params = ft.params, .results = ft.results },
        else => .{ .params = &.{}, .results = &.{} },
    };
}

const ValStack = std.ArrayListUnmanaged(ValTypeOrUnknown);

/// Pack local initialization state into a compact bitset (up to 256 locals).
fn packInitState(local_inited: []const bool) [4]u64 {
    var bits: [4]u64 = .{ 0, 0, 0, 0 };
    for (local_inited, 0..) |v, i| {
        if (v) bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
    }
    return bits;
}

/// Restore local initialization state from a packed bitset.
fn unpackInitState(bits: [4]u64, local_inited: []bool) void {
    for (local_inited, 0..) |*v, i| {
        v.* = (bits[i / 64] >> @intCast(i % 64)) & 1 != 0;
    }
}

const ValTypeOrUnknown = enum(i32) {
    i32 = @intFromEnum(types.ValType.i32),
    i64 = @intFromEnum(types.ValType.i64),
    f32 = @intFromEnum(types.ValType.f32),
    f64 = @intFromEnum(types.ValType.f64),
    v128 = @intFromEnum(types.ValType.v128),
    funcref = @intFromEnum(types.ValType.funcref),
    externref = @intFromEnum(types.ValType.externref),
    anyref = @intFromEnum(types.ValType.anyref),
    ref = @intFromEnum(types.ValType.ref),
    ref_null = @intFromEnum(types.ValType.ref_null),
    nullfuncref = @intFromEnum(types.ValType.nullfuncref),
    nullexternref = @intFromEnum(types.ValType.nullexternref),
    nullref = @intFromEnum(types.ValType.nullref),
    ref_func = @intFromEnum(types.ValType.ref_func),
    ref_extern = @intFromEnum(types.ValType.ref_extern),
    ref_any = @intFromEnum(types.ValType.ref_any),
    ref_none = @intFromEnum(types.ValType.ref_none),
    ref_nofunc = @intFromEnum(types.ValType.ref_nofunc),
    ref_noextern = @intFromEnum(types.ValType.ref_noextern),
    unknown = 0,

    fn fromValType(vt: types.ValType) ValTypeOrUnknown {
        return switch (vt) {
            .i32 => .i32,
            .i64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .v128 => .v128,
            .funcref => .funcref,
            .externref => .externref,
            .anyref => .anyref,
            .ref => .ref,
            .ref_null => .ref_null,
            .nullfuncref => .nullfuncref,
            .nullexternref => .nullexternref,
            .nullref => .nullref,
            .ref_func => .ref_func,
            .ref_extern => .ref_extern,
            .ref_any => .ref_any,
            .ref_none => .ref_none,
            .ref_nofunc => .ref_nofunc,
            .ref_noextern => .ref_noextern,
            else => .unknown,
        };
    }

    fn isRefType(self: ValTypeOrUnknown) bool {
        return switch (self) {
            .funcref, .externref, .anyref, .ref, .ref_null,
            .nullfuncref, .nullexternref, .nullref,
            .ref_func, .ref_extern, .ref_any, .ref_none, .ref_nofunc, .ref_noextern,
            => true,
            else => false,
        };
    }

    fn isNonNullableRef(self: ValTypeOrUnknown) bool {
        return switch (self) {
            .ref, .ref_func, .ref_extern, .ref_any, .ref_none, .ref_nofunc, .ref_noextern => true,
            else => false,
        };
    }

    /// Check if self is a subtype of other (for validation).
    fn isSubtypeOf(self: ValTypeOrUnknown, other: ValTypeOrUnknown) bool {
        if (self == other) return true;
        if (self == .unknown or other == .unknown) return true;
        // GC type hierarchy (three SEPARATE hierarchies):
        // Internal: any > eq > struct/array/i31 > none
        // Function: func > nofunc (NOT under any)
        // External: extern > noextern (NOT under any)
        return switch (self) {
            .nullfuncref => other == .funcref,
            .nullexternref => other == .externref,
            .nullref => other == .anyref,
            .ref_nofunc => other == .ref_func,
            .ref_noextern => other == .ref_extern,
            .ref_none => other == .ref_any,
            else => false,
        };
    }

    fn matches(self: ValTypeOrUnknown, other: ValTypeOrUnknown) bool {
        if (self == .unknown or other == .unknown) return true;
        if (self == other) return true;
        // Check subtyping in both directions
        return self.isSubtypeOf(other) or other.isSubtypeOf(self);
    }
};

const CtrlFrame = struct {
    opcode: u8, // 0x02=block, 0x03=loop, 0x04=if
    start_types: []const types.ValType,
    end_types: []const types.ValType,
    height: usize,
    unreachable_flag: bool,
    else_seen: bool,
    // Local initialization state at frame entry (for conservative merge at join points)
    saved_init: [4]u64 = .{ 0, 0, 0, 0 },
};

fn checkOneBody(m: *const Mod.Module, func: *const Mod.Func, declared_funcs: *const std.AutoHashMapUnmanaged(u32, void)) Error!void {
    const sig = resolveSig(m, func.decl);
    const num_params: u32 = @intCast(sig.params.len);
    const num_locals: u32 = num_params + @as(u32, @intCast(func.local_types.items.len));

    // Build local types array: params ++ declared locals
    var local_types_buf: [256]ValTypeOrUnknown = undefined;
    var local_types: []ValTypeOrUnknown = &.{};
    if (num_locals <= 256) {
        for (sig.params, 0..) |p, i| local_types_buf[i] = ValTypeOrUnknown.fromValType(p);
        for (func.local_types.items, 0..) |lt, i| local_types_buf[num_params + i] = ValTypeOrUnknown.fromValType(lt);
        local_types = local_types_buf[0..num_locals];
    }

    // Track initialization of non-nullable ref locals (params are always initialized)
    var local_inited_buf: [256]bool = undefined;
    for (0..@min(num_locals, 256)) |i| {
        local_inited_buf[i] = if (i < num_params) true else !local_types_buf[i].isNonNullableRef();
    }
    const local_inited: []bool = if (num_locals <= 256) local_inited_buf[0..num_locals] else &.{};

    var val_stack: ValStack = .empty;
    defer val_stack.deinit(gpa(m));
    var ctrl_stack: std.ArrayListUnmanaged(CtrlFrame) = .empty;
    defer ctrl_stack.deinit(gpa(m));

    // Push the function frame
    ctrl_stack.append(gpa(m), .{
        .opcode = 0x02,
        .start_types = &.{},
        .end_types = sig.results,
        .height = 0,
        .unreachable_flag = false,
        .else_seen = false,
        .saved_init = packInitState(local_inited),
    }) catch return error.OutOfMemory;

    var pos: usize = 0;
    const bytes = func.code_bytes;

    while (pos < bytes.len) {
        const opcode = bytes[pos];
        pos += 1;

        switch (opcode) {
            0x00 => { // unreachable
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x01 => {}, // nop
            0x02 => { // block
                const bt = readBlockType(m, bytes, &pos);
                if (bt.params.len > 0)
                    try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x02, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x03 => { // loop
                const bt = readBlockType(m, bytes, &pos);
                if (bt.params.len > 0)
                    try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x03, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x04 => { // if
                const bt = readBlockType(m, bytes, &pos);
                try popExpect(&val_stack, &ctrl_stack, .i32);
                if (bt.params.len > 0)
                    try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x04, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                // Save init state at if entry for conservative merge
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x05 => { // else
                if (ctrl_stack.items.len == 0) return error.TypeMismatch;
                const frame = &ctrl_stack.items[ctrl_stack.items.len - 1];
                if (frame.opcode != 0x04) return error.TypeMismatch;
                try popVals(&val_stack, frame, frame.end_types);
                if (val_stack.items.len != frame.height) return error.TypeMismatch;
                frame.unreachable_flag = false;
                frame.else_seen = true;
                // Restore init state from if entry (else branch didn't execute then)
                unpackInitState(frame.saved_init, local_inited);
                pushVals(&val_stack, frame.start_types, gpa(m)) catch return error.OutOfMemory;
            },
            0x0b => { // end
                if (ctrl_stack.items.len == 0) break;
                const frame = ctrl_stack.items[ctrl_stack.items.len - 1];
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], frame.end_types);
                if (val_stack.items.len != frame.height) return error.TypeMismatch;
                // If block was an if without else, and it has results, that's a type error
                if (frame.opcode == 0x04 and !frame.else_seen and frame.end_types.len > 0) {
                    // Check if start_types match end_types (if with no else must have matching in/out)
                    if (!std.mem.eql(types.ValType, frame.start_types, frame.end_types))
                        return error.TypeMismatch;
                }
                // Roll back local-init state to frame entry. Per the
                // function-references spec, any local.set inside a
                // block/loop/if body does not propagate past `end` (an
                // early `br` could have skipped the set).
                unpackInitState(frame.saved_init, local_inited);
                _ = ctrl_stack.pop();
                pushVals(&val_stack, frame.end_types, gpa(m)) catch return error.OutOfMemory;
            },
            0x0c => { // br
                const depth = readU32(bytes, &pos);
                if (depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                const target = ctrl_stack.items[ctrl_stack.items.len - 1 - depth];
                const label_types = labelTypes(&target);
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], label_types);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x0d => { // br_if
                const depth = readU32(bytes, &pos);
                if (depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                try popExpect(&val_stack, &ctrl_stack, .i32);
                const target = ctrl_stack.items[ctrl_stack.items.len - 1 - depth];
                const lt = labelTypes(&target);
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], lt);
                pushVals(&val_stack, lt, gpa(m)) catch return error.OutOfMemory;
            },
            0x0e => { // br_table
                const count = readU32(bytes, &pos);
                // Save position to re-read target depths for type checking
                const targets_start = pos;
                var max_depth: u32 = 0;
                for (0..count) |_| {
                    const d = readU32(bytes, &pos);
                    if (d > max_depth) max_depth = d;
                }
                const default = readU32(bytes, &pos);
                if (default > max_depth) max_depth = default;
                if (max_depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                if (default >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                try popExpect(&val_stack, &ctrl_stack, .i32);

                const default_target = ctrl_stack.items[ctrl_stack.items.len - 1 - default];
                const default_lt = labelTypes(&default_target);

                // Verify all targets have consistent label types with the default
                var check_pos = targets_start;
                for (0..count) |_| {
                    const d = readU32(bytes, &check_pos);
                    const target = ctrl_stack.items[ctrl_stack.items.len - 1 - d];
                    const lt = labelTypes(&target);
                    if (lt.len != default_lt.len) return error.TypeMismatch;
                    for (lt, default_lt) |a, b| {
                        if (a != b) return error.TypeMismatch;
                    }
                }

                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], default_lt);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x0f => { // return
                if (ctrl_stack.items.len == 0) return error.TypeMismatch;
                const lt = ctrl_stack.items[0].end_types;
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], lt);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x10 => { // call
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                const callee_sig = resolveSig(m, m.funcs.items[idx].decl);
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], callee_sig.params);
                pushVals(&val_stack, callee_sig.results, gpa(m)) catch return error.OutOfMemory;
            },
            0x11 => { // call_indirect
                const type_idx = readU32(bytes, &pos);
                const table_idx = readU32(bytes, &pos);
                if (type_idx >= m.module_types.items.len) return error.InvalidTypeIndex;
                if (m.tables.items.len == 0) return error.InvalidTableIndex;
                if (table_idx >= m.tables.items.len) return error.InvalidTableIndex;
                // call_indirect requires a funcref table
                if (m.tables.items[table_idx].@"type".elem_type != .funcref) return error.TypeMismatch;
                try popExpect(&val_stack, &ctrl_stack, .i32); // table index operand
                const ft = switch (m.module_types.items[type_idx]) {
                    .func_type => |ft| ft,
                    else => Mod.FuncSignature{},
                };
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], ft.params);
                pushVals(&val_stack, ft.results, gpa(m)) catch return error.OutOfMemory;
            },
            0x12 => { // return_call
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                const callee_sig = resolveSig(m, m.funcs.items[idx].decl);
                try checkTailCallResults(&ctrl_stack, callee_sig.results);
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], callee_sig.params);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x13 => { // return_call_indirect
                const type_idx = readU32(bytes, &pos);
                const table_idx = readU32(bytes, &pos);
                if (type_idx >= m.module_types.items.len) return error.InvalidTypeIndex;
                if (m.tables.items.len == 0) return error.InvalidTableIndex;
                if (table_idx >= m.tables.items.len) return error.InvalidTableIndex;
                if (m.tables.items[table_idx].@"type".elem_type != .funcref) return error.TypeMismatch;
                const ft = switch (m.module_types.items[type_idx]) {
                    .func_type => |ft| ft,
                    else => Mod.FuncSignature{},
                };
                try checkTailCallResults(&ctrl_stack, ft.results);
                try popExpect(&val_stack, &ctrl_stack, .i32); // table index operand
                try popVals(&val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], ft.params);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x1a => { // drop
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
            },
            0x1b => { // select
                try popExpect(&val_stack, &ctrl_stack, .i32);
                const t1 = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                const t2 = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                if (t1 != .unknown and t2 != .unknown and t1 != t2) return error.TypeMismatch;
                const result = if (t1 != .unknown) t1 else t2;
                // Untyped select only works with numeric/vector types, not ref types
                if (result.isRefType()) return error.TypeMismatch;
                val_stack.append(gpa(m), result) catch return error.OutOfMemory;
            },
            0x1c => { // select t
                const count = readU32(bytes, &pos);
                for (0..count) |_| _ = readU32(bytes, &pos); // skip types
                try popExpect(&val_stack, &ctrl_stack, .i32);
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                val_stack.append(gpa(m), .unknown) catch return error.OutOfMemory;
            },
            0x20 => { // local.get
                const idx = readU32(bytes, &pos);
                if (idx >= num_locals) return error.InvalidLocalIndex;
                const lt = if (idx < local_types.len) local_types[idx] else ValTypeOrUnknown.unknown;
                // Non-nullable ref locals must be initialized before use
                if (idx < local_inited.len and !local_inited[idx]) return error.TypeMismatch;
                val_stack.append(gpa(m), lt) catch return error.OutOfMemory;
            },
            0x21 => { // local.set
                const idx = readU32(bytes, &pos);
                if (idx >= num_locals) return error.InvalidLocalIndex;
                const lt = if (idx < local_types.len) local_types[idx] else ValTypeOrUnknown.unknown;
                try popExpect(&val_stack, &ctrl_stack, lt);
                if (idx < local_inited.len) local_inited[idx] = true;
            },
            0x22 => { // local.tee
                const idx = readU32(bytes, &pos);
                if (idx >= num_locals) return error.InvalidLocalIndex;
                const lt = if (idx < local_types.len) local_types[idx] else ValTypeOrUnknown.unknown;
                try popExpect(&val_stack, &ctrl_stack, lt);
                val_stack.append(gpa(m), lt) catch return error.OutOfMemory;
                if (idx < local_inited.len) local_inited[idx] = true;
            },
            0x23 => { // global.get
                const idx = readU32(bytes, &pos);
                if (idx >= m.globals.items.len) return error.InvalidGlobalIndex;
                const gt = ValTypeOrUnknown.fromValType(m.globals.items[idx].type.val_type);
                val_stack.append(gpa(m), gt) catch return error.OutOfMemory;
            },
            0x24 => { // global.set
                const idx = readU32(bytes, &pos);
                if (idx >= m.globals.items.len) return error.InvalidGlobalIndex;
                if (m.globals.items[idx].type.mutability != .mutable) return error.ImmutableGlobal;
                const gt = ValTypeOrUnknown.fromValType(m.globals.items[idx].type.val_type);
                try popExpect(&val_stack, &ctrl_stack, gt);
            },
            0x25 => { // table.get
                const idx = readU32(bytes, &pos);
                if (idx >= m.tables.items.len) return error.InvalidTableIndex;
                try popExpect(&val_stack, &ctrl_stack, .i32);
                val_stack.append(gpa(m), ValTypeOrUnknown.fromValType(m.tables.items[idx].type.elem_type)) catch return error.OutOfMemory;
            },
            0x26 => { // table.set
                const idx = readU32(bytes, &pos);
                if (idx >= m.tables.items.len) return error.InvalidTableIndex;
                const et = ValTypeOrUnknown.fromValType(m.tables.items[idx].type.elem_type);
                try popExpect(&val_stack, &ctrl_stack, et);
                try popExpect(&val_stack, &ctrl_stack, .i32);
            },
            // Memory load instructions
            0x28 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x28); },
            0x29 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x29); },
            0x2a => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .f32, gpa(m), 0x2a); },
            0x2b => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .f64, gpa(m), 0x2b); },
            0x2c => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x2c); },
            0x2d => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x2d); },
            0x2e => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x2e); },
            0x2f => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x2f); },
            0x30 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x30); },
            0x31 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x31); },
            0x32 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x32); },
            0x33 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x33); },
            0x34 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x34); },
            0x35 => { try checkMemLoad(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x35); },
            // Memory store instructions
            0x36 => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x36); },
            0x37 => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x37); },
            0x38 => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .f32, gpa(m), 0x38); },
            0x39 => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .f64, gpa(m), 0x39); },
            0x3a => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x3a); },
            0x3b => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i32, gpa(m), 0x3b); },
            0x3c => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x3c); },
            0x3d => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x3d); },
            0x3e => { try checkMemStore(m, bytes, &pos, &val_stack, &ctrl_stack, .i64, gpa(m), 0x3e); },
            0x3f => { // memory.size
                if (pos < bytes.len and bytes[pos] != 0x00) return error.TypeMismatch;
                const mem_idx = readU32(bytes, &pos);
                if (m.memories.items.len == 0 or mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
                val_stack.append(gpa(m), .i32) catch return error.OutOfMemory;
            },
            0x40 => { // memory.grow
                if (pos < bytes.len and bytes[pos] != 0x00) return error.TypeMismatch;
                const mem_idx = readU32(bytes, &pos);
                if (m.memories.items.len == 0 or mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
                try popExpect(&val_stack, &ctrl_stack, .i32);
                val_stack.append(gpa(m), .i32) catch return error.OutOfMemory;
            },
            0x41 => { // i32.const
                _ = readS32(bytes, &pos);
                val_stack.append(gpa(m), .i32) catch return error.OutOfMemory;
            },
            0x42 => { // i64.const
                _ = readS64(bytes, &pos);
                val_stack.append(gpa(m), .i64) catch return error.OutOfMemory;
            },
            0x43 => { // f32.const
                pos += 4;
                val_stack.append(gpa(m), .f32) catch return error.OutOfMemory;
            },
            0x44 => { // f64.const
                pos += 8;
                val_stack.append(gpa(m), .f64) catch return error.OutOfMemory;
            },
            // i32 comparison: unary
            0x45 => { try checkUnary(&val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i32 comparison: binary
            0x46...0x4f => { try checkBinary(&val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i64 comparison: unary
            0x50 => { try checkUnary(&val_stack, &ctrl_stack, .i64, .i32, gpa(m)); },
            // i64 comparison: binary
            0x51...0x5a => { try checkBinary(&val_stack, &ctrl_stack, .i64, .i32, gpa(m)); },
            // f32 comparison
            0x5b...0x60 => { try checkBinary(&val_stack, &ctrl_stack, .f32, .i32, gpa(m)); },
            // f64 comparison
            0x61...0x66 => { try checkBinary(&val_stack, &ctrl_stack, .f64, .i32, gpa(m)); },
            // i32 unary
            0x67...0x69 => { try checkUnary(&val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i32 binary
            0x6a...0x78 => { try checkBinary(&val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i64 unary
            0x79...0x7b => { try checkUnary(&val_stack, &ctrl_stack, .i64, .i64, gpa(m)); },
            // i64 binary
            0x7c...0x8a => { try checkBinary(&val_stack, &ctrl_stack, .i64, .i64, gpa(m)); },
            // f32 unary
            0x8b...0x91 => { try checkUnary(&val_stack, &ctrl_stack, .f32, .f32, gpa(m)); },
            // f32 binary
            0x92...0x98 => { try checkBinary(&val_stack, &ctrl_stack, .f32, .f32, gpa(m)); },
            // f64 unary
            0x99...0x9f => { try checkUnary(&val_stack, &ctrl_stack, .f64, .f64, gpa(m)); },
            // f64 binary
            0xa0...0xa6 => { try checkBinary(&val_stack, &ctrl_stack, .f64, .f64, gpa(m)); },
            // Conversions
            0xa7 => { try checkUnary(&val_stack, &ctrl_stack, .i64, .i32, gpa(m)); }, // i32.wrap_i64
            0xa8, 0xa9 => { try checkUnary(&val_stack, &ctrl_stack, .f32, .i32, gpa(m)); },
            0xaa, 0xab => { try checkUnary(&val_stack, &ctrl_stack, .f64, .i32, gpa(m)); },
            0xac, 0xad => { try checkUnary(&val_stack, &ctrl_stack, .i32, .i64, gpa(m)); },
            0xae, 0xaf => { try checkUnary(&val_stack, &ctrl_stack, .f32, .i64, gpa(m)); },
            0xb0, 0xb1 => { try checkUnary(&val_stack, &ctrl_stack, .f64, .i64, gpa(m)); },
            0xb2, 0xb3 => { try checkUnary(&val_stack, &ctrl_stack, .i32, .f32, gpa(m)); },
            0xb4, 0xb5 => { try checkUnary(&val_stack, &ctrl_stack, .i64, .f32, gpa(m)); },
            0xb6 => { try checkUnary(&val_stack, &ctrl_stack, .f64, .f32, gpa(m)); },
            0xb7, 0xb8 => { try checkUnary(&val_stack, &ctrl_stack, .i32, .f64, gpa(m)); },
            0xb9, 0xba => { try checkUnary(&val_stack, &ctrl_stack, .i64, .f64, gpa(m)); },
            0xbb => { try checkUnary(&val_stack, &ctrl_stack, .f32, .f64, gpa(m)); },
            0xbc => { try checkUnary(&val_stack, &ctrl_stack, .f32, .i32, gpa(m)); },
            0xbd => { try checkUnary(&val_stack, &ctrl_stack, .f64, .i64, gpa(m)); },
            0xbe => { try checkUnary(&val_stack, &ctrl_stack, .i32, .f32, gpa(m)); },
            0xbf => { try checkUnary(&val_stack, &ctrl_stack, .i64, .f64, gpa(m)); },
            // Sign extension
            0xc0, 0xc1 => { try checkUnary(&val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            0xc2...0xc4 => { try checkUnary(&val_stack, &ctrl_stack, .i64, .i64, gpa(m)); },
            // Reference types
            0xd0 => { // ref.null
                if (pos < bytes.len) pos += 1; // skip reftype byte
                val_stack.append(gpa(m), .funcref) catch return error.OutOfMemory;
            },
            0xd1 => { // ref.is_null
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                val_stack.append(gpa(m), .i32) catch return error.OutOfMemory;
            },
            0xd2 => { // ref.func
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                if (!declared_funcs.contains(idx)) return error.InvalidFuncIndex;
                val_stack.append(gpa(m), .funcref) catch return error.OutOfMemory;
            },
            // Prefixed opcodes
            0xfc => {
                const sub = readU32(bytes, &pos);
                switch (sub) {
                    0x00...0x07 => {
                        // Saturating float-to-int: 0-1 f32→i32, 2-3 f64→i32, 4-5 f32→i64, 6-7 f64→i64
                        const input: ValTypeOrUnknown = if (sub & 2 == 0) .f32 else .f64;
                        const output: ValTypeOrUnknown = if (sub < 4) .i32 else .i64;
                        try checkUnary(&val_stack, &ctrl_stack, input, output, gpa(m));
                    },
                    0x08 => { // memory.init
                        if (!m.has_data_count) return error.InvalidDataIndex;
                        const data_idx = readU32(bytes, &pos);
                        _ = readU32(bytes, &pos); // mem idx
                        if (data_idx >= m.data_segments.items.len) return error.InvalidDataIndex;
                        if (m.memories.items.len == 0) return error.InvalidMemoryIndex;
                        try popExpect(&val_stack, &ctrl_stack, .i32);
                        try popExpect(&val_stack, &ctrl_stack, .i32);
                        try popExpect(&val_stack, &ctrl_stack, .i32);
                    },
                    0x09 => { // data.drop
                        if (!m.has_data_count) return error.InvalidDataIndex;
                        const idx = readU32(bytes, &pos);
                        if (idx >= m.data_segments.items.len) return error.InvalidDataIndex;
                    },
                    0x0a => { // memory.copy
                        const dst_mem = readU32(bytes, &pos);
                        const src_mem = readU32(bytes, &pos);
                        if (m.memories.items.len == 0) return error.InvalidMemoryIndex;
                        const dst_m64 = dst_mem < m.memories.items.len and m.memories.items[dst_mem].is_memory64;
                        const src_m64 = src_mem < m.memories.items.len and m.memories.items[src_mem].is_memory64;
                        try popExpect(&val_stack, &ctrl_stack, if (dst_m64) .i64 else .i32); // n
                        try popExpect(&val_stack, &ctrl_stack, if (src_m64) .i64 else .i32); // src
                        try popExpect(&val_stack, &ctrl_stack, if (dst_m64) .i64 else .i32); // dst
                    },
                    0x0b => { // memory.fill
                        const mem_idx = readU32(bytes, &pos);
                        if (m.memories.items.len == 0) return error.InvalidMemoryIndex;
                        const m64 = mem_idx < m.memories.items.len and m.memories.items[mem_idx].is_memory64;
                        try popExpect(&val_stack, &ctrl_stack, if (m64) .i64 else .i32); // n
                        try popExpect(&val_stack, &ctrl_stack, .i32); // val (always i32)
                        try popExpect(&val_stack, &ctrl_stack, if (m64) .i64 else .i32); // dst
                    },
                    0x0c => { // table.init
                        _ = readU32(bytes, &pos);
                        _ = readU32(bytes, &pos);
                    },
                    0x0d => { // elem.drop
                        const idx = readU32(bytes, &pos);
                        if (idx >= m.elem_segments.items.len) return error.InvalidElemIndex;
                    },
                    0x0e => { // table.copy
                        _ = readU32(bytes, &pos);
                        _ = readU32(bytes, &pos);
                    },
                    0x0f => { // table.grow
                        const tbl_idx = readU32(bytes, &pos);
                        try popExpect(&val_stack, &ctrl_stack, .i32);
                        if (tbl_idx < m.tables.items.len) {
                            const elem_t = ValTypeOrUnknown.fromValType(m.tables.items[tbl_idx].@"type".elem_type);
                            try popExpect(&val_stack, &ctrl_stack, elem_t);
                        } else {
                            _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                        }
                        val_stack.append(gpa(m), .i32) catch return error.OutOfMemory;
                    },
                    0x10 => { // table.size
                        _ = readU32(bytes, &pos);
                        val_stack.append(gpa(m), .i32) catch return error.OutOfMemory;
                    },
                    0x11 => { // table.fill
                        const tbl_idx = readU32(bytes, &pos);
                        try popExpect(&val_stack, &ctrl_stack, .i32);
                        if (tbl_idx < m.tables.items.len) {
                            const elem_t = ValTypeOrUnknown.fromValType(m.tables.items[tbl_idx].@"type".elem_type);
                            try popExpect(&val_stack, &ctrl_stack, elem_t);
                        } else {
                            _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                        }
                        try popExpect(&val_stack, &ctrl_stack, .i32);
                    },
                    else => return classifyOpcode(Opcode.prefix_math, sub),
                }
            },
            0xfe => {
                // Atomic prefix (threads proposal). Not type-checked yet.
                //
                // This arm used to skip the sub-opcode and memarg and then
                // carry on validating, without modelling the instruction's
                // stack effects. Every later instruction was then checked
                // against a value stack that no longer described the
                // program, so invalid modules were accepted. Reject instead.
                const sub = readU32(bytes, &pos);
                return classifyOpcode(Opcode.prefix_threads, sub);
            },
            0xfd => {
                const sub = readU32(bytes, &pos);
                const simd_sig = simdSig(sub) orelse
                    return classifyOpcode(Opcode.prefix_simd, sub);
                try checkSimd(m, bytes, &pos, &val_stack, &ctrl_stack, simd_sig, gpa(m));
            },
            0xfb => {
                // GC prefix. `Opcode.Code` does not enumerate the GC
                // proposal's sub-opcodes, so classification cannot tell a
                // real one from a bogus one; report the prefix as known but
                // unchecked, matching `component/adapter/gc.zig`.
                return error.UnsupportedOpcode;
            },
            else => return classifyOpcode(null, opcode),
        }
    }

    // After processing all instructions, check the final stack matches the function's result types
    if (ctrl_stack.items.len == 0) {
        // All blocks have been closed — check results on val_stack
        for (sig.results) |expected| {
            const actual = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
            if (!actual.matches(ValTypeOrUnknown.fromValType(expected))) return error.TypeMismatch;
        }
    } else {
        // Function body ended with unclosed blocks — unexpected end
        return error.TypeMismatch;
    }
}

fn gpa(m: *const Mod.Module) std.mem.Allocator {
    return m.allocator;
}

const BlockType = struct {
    params: []const types.ValType,
    results: []const types.ValType,
};

fn readBlockType(m: *const Mod.Module, bytes: []const u8, pos: *usize) BlockType {
    if (pos.* >= bytes.len) return .{ .params = &.{}, .results = &.{} };
    const byte = bytes[pos.*];
    if (byte == 0x40) {
        pos.* += 1;
        return .{ .params = &.{}, .results = &.{} };
    }
    // Single value type (wasm type bytes: 0x7F=i32, 0x7E=i64, 0x7D=f32, 0x7C=f64,
    // 0x70=funcref, 0x6F=externref). All are >= 0x60.
    if (byte >= 0x60) {
        pos.* += 1;
        return .{ .params = &.{}, .results = valTypeSlice(byte) };
    }
    // Type index (s33 LEB128)
    const result = leb128.readS32Leb128(bytes[pos.*..]) catch return .{ .params = &.{}, .results = &.{} };
    pos.* += result.bytes_read;
    const idx: u32 = @bitCast(result.value);
    if (idx < m.module_types.items.len) {
        return switch (m.module_types.items[idx]) {
            .func_type => |ft| .{ .params = ft.params, .results = ft.results },
            else => .{ .params = &.{}, .results = &.{} },
        };
    }
    return .{ .params = &.{}, .results = &.{} };
}

// Reusable single-element type slices for block types
const single_i32: [1]types.ValType = .{.i32};
const single_i64: [1]types.ValType = .{.i64};
const single_f32: [1]types.ValType = .{.f32};
const single_f64: [1]types.ValType = .{.f64};
const single_funcref: [1]types.ValType = .{.funcref};
const single_externref: [1]types.ValType = .{.externref};

const single_ref_null: [1]types.ValType = .{.ref_null};
const single_ref: [1]types.ValType = .{.ref};

fn valTypeSlice(byte: u8) []const types.ValType {
    return switch (byte) {
        0x7f => &single_i32,
        0x7e => &single_i64,
        0x7d => &single_f32,
        0x7c => &single_f64,
        0x70 => &single_funcref,
        0x6f => &single_externref,
        0x63 => &single_ref_null,
        0x64 => &single_ref,
        else => &.{},
    };
}

fn readU32(bytes: []const u8, pos: *usize) u32 {
    if (pos.* >= bytes.len) return 0;
    const result = leb128.readU32Leb128(bytes[pos.*..]) catch return 0;
    pos.* += result.bytes_read;
    return result.value;
}

fn readS32(bytes: []const u8, pos: *usize) i32 {
    if (pos.* >= bytes.len) return 0;
    const result = leb128.readS32Leb128(bytes[pos.*..]) catch return 0;
    pos.* += result.bytes_read;
    return result.value;
}

fn readS64(bytes: []const u8, pos: *usize) i64 {
    if (pos.* >= bytes.len) return 0;
    const result = leb128.readS64Leb128(bytes[pos.*..]) catch return 0;
    pos.* += result.bytes_read;
    return result.value;
}

fn pushCtrl(ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), val_stack: *ValStack, opcode: u8, start: []const types.ValType, end: []const types.ValType, alloc: std.mem.Allocator) !void {
    try ctrl_stack.append(alloc, .{
        .opcode = opcode,
        .start_types = start,
        .end_types = end,
        .height = val_stack.items.len,
        .unreachable_flag = false,
        .else_seen = false,
    });
}

fn pushVals(val_stack: *ValStack, vts: []const types.ValType, alloc: std.mem.Allocator) !void {
    for (vts) |vt| try val_stack.append(alloc, ValTypeOrUnknown.fromValType(vt));
}

fn popVal(val_stack: *ValStack, ctrl_stack: *const std.ArrayListUnmanaged(CtrlFrame)) error{TypeMismatch}!ValTypeOrUnknown {
    if (ctrl_stack.items.len > 0) {
        const frame = ctrl_stack.items[ctrl_stack.items.len - 1];
        if (val_stack.items.len <= frame.height) {
            if (frame.unreachable_flag) return .unknown;
            return error.TypeMismatch;
        }
    } else if (val_stack.items.len == 0) {
        return error.TypeMismatch;
    }
    return val_stack.pop() orelse return error.TypeMismatch;
}

fn popExpect(val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), expected: ValTypeOrUnknown) Error!void {
    const actual = popVal(val_stack, ctrl_stack) catch return error.TypeMismatch;
    if (!actual.matches(expected)) return error.TypeMismatch;
}

fn popVals(val_stack: *ValStack, frame: *const CtrlFrame, expected: []const types.ValType) Error!void {
    // Pop in reverse order
    var i: usize = expected.len;
    while (i > 0) {
        i -= 1;
        const actual = popValFromFrame(val_stack, frame) catch return error.TypeMismatch;
        if (!actual.matches(ValTypeOrUnknown.fromValType(expected[i]))) return error.TypeMismatch;
    }
}

fn popValFromFrame(val_stack: *ValStack, frame: *const CtrlFrame) error{TypeMismatch}!ValTypeOrUnknown {
    if (val_stack.items.len <= frame.height) {
        if (frame.unreachable_flag) return .unknown;
        return error.TypeMismatch;
    }
    return val_stack.pop() orelse return error.TypeMismatch;
}

fn setUnreachable(val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame)) void {
    if (ctrl_stack.items.len == 0) return;
    const frame = &ctrl_stack.items[ctrl_stack.items.len - 1];
    val_stack.shrinkRetainingCapacity(frame.height);
    frame.unreachable_flag = true;
}

/// A tail call replaces the caller's frame, so the callee's results become
/// the caller's results directly. The spec therefore requires them to be
/// exactly the enclosing function's result types -- there is no room for
/// the usual subtyping slack, because nothing runs afterwards to adapt them.
///
/// The enclosing function's results live in the frame seeded at the bottom
/// of the control stack, the same one `return` uses.
fn checkTailCallResults(
    ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame),
    callee_results: []const types.ValType,
) Error!void {
    if (ctrl_stack.items.len == 0) return error.TypeMismatch;
    const func_results = ctrl_stack.items[0].end_types;
    if (callee_results.len != func_results.len) return error.TypeMismatch;
    for (callee_results, func_results) |a, b| {
        if (a != b) return error.TypeMismatch;
    }
}

fn labelTypes(frame: *const CtrlFrame) []const types.ValType {
    // For loops, branch targets use start_types; for blocks/ifs, use end_types
    return if (frame.opcode == 0x03) frame.start_types else frame.end_types;
}

fn checkUnary(val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), input: ValTypeOrUnknown, output: ValTypeOrUnknown, alloc: std.mem.Allocator) Error!void {
    try popExpect(val_stack, ctrl_stack, input);
    val_stack.append(alloc, output) catch return error.OutOfMemory;
}

fn checkBinary(val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), operand: ValTypeOrUnknown, result: ValTypeOrUnknown, alloc: std.mem.Allocator) Error!void {
    try popExpect(val_stack, ctrl_stack, operand);
    try popExpect(val_stack, ctrl_stack, operand);
    val_stack.append(alloc, result) catch return error.OutOfMemory;
}

fn readMemArg(bytes: []const u8, pos: *usize) struct { align_val: u32, mem_idx: u32 } {
    const align_raw = readU32(bytes, pos);
    const has_explicit_memidx = (align_raw & 0x40) != 0;
    const align_val = align_raw & ~@as(u32, 0x40);
    const mem_idx: u32 = if (has_explicit_memidx) readU32(bytes, pos) else 0;
    _ = readU32(bytes, pos); // offset
    return .{ .align_val = align_val, .mem_idx = mem_idx };
}

fn checkMemLoad(m: *const Mod.Module, bytes: []const u8, pos: *usize, val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), result_type: ValTypeOrUnknown, alloc: std.mem.Allocator, opcode: u8) Error!void {
    const memarg = readMemArg(bytes, pos);
    if (maxAlignmentForOpcode(opcode)) |max_align| {
        if (memarg.align_val > max_align) return error.InvalidAlignment;
    }
    if (m.memories.items.len == 0 or memarg.mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
    try popExpect(val_stack, ctrl_stack, .i32);
    val_stack.append(alloc, result_type) catch return error.OutOfMemory;
}

fn checkMemStore(m: *const Mod.Module, bytes: []const u8, pos: *usize, val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), value_type: ValTypeOrUnknown, _: std.mem.Allocator, opcode: u8) Error!void {
    const memarg = readMemArg(bytes, pos);
    if (maxAlignmentForOpcode(opcode)) |max_align| {
        if (memarg.align_val > max_align) return error.InvalidAlignment;
    }
    if (m.memories.items.len == 0 or memarg.mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
    try popExpect(val_stack, ctrl_stack, value_type);
    try popExpect(val_stack, ctrl_stack, .i32);
}


// ── SIMD (0xfd) instruction signatures ──────────────────────────────────

/// Shape of the immediate operands that follow a SIMD opcode.
const SimdImm = enum {
    /// No immediate.
    none,
    /// align + optional memory index + offset.
    memarg,
    /// memarg followed by a single lane index byte.
    memarg_lane,
    /// A single lane index byte.
    lane,
    /// 16 raw bytes (v128.const).
    const16,
    /// 16 lane index bytes (i8x16.shuffle), each selecting from two vectors.
    shuffle,
};

/// Static type signature of one SIMD instruction.
const SimdSig = struct {
    /// Operands in stack order, bottom first; popped in reverse.
    params: []const ValTypeOrUnknown,
    results: []const ValTypeOrUnknown,
    imm: SimdImm,
    /// Exclusive upper bound for lane index immediates. 32 for shuffle,
    /// whose bytes index a concatenation of two vectors. 0 when unused.
    lanes: u8,
    /// log2 of the maximum permitted alignment for memarg forms.
    max_align: u8,
};

/// Signature for a 0xfd sub-opcode, or null if this build does not know it.
///
/// Generated from the opcode list in Opcode.zig; the drift-guard test below
/// asserts the two stay in sync, so a SIMD opcode cannot be added to
/// Opcode.zig without either a signature here or an explicit exemption.
/// Read a single lane index byte and bounds-check it against `limit`.
fn readLane(bytes: []const u8, pos: *usize, limit: u8) Error!void {
    if (pos.* >= bytes.len) return error.UnexpectedEnd;
    const lane = bytes[pos.*];
    pos.* += 1;
    if (lane >= limit) return error.InvalidLaneIndex;
}

/// Type-check one SIMD instruction: consume its immediates, then apply its
/// stack effect.
fn checkSimd(
    m: *const Mod.Module,
    bytes: []const u8,
    pos: *usize,
    val_stack: *ValStack,
    ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame),
    sig: SimdSig,
    alloc: std.mem.Allocator,
) Error!void {
    var mem_idx: u32 = 0;
    switch (sig.imm) {
        .none => {},
        .const16 => {
            if (pos.* + 16 > bytes.len) return error.UnexpectedEnd;
            pos.* += 16;
        },
        .shuffle => {
            // Each of the 16 bytes selects a lane from the two operand
            // vectors concatenated, so the bound is 32, not 16.
            if (pos.* + 16 > bytes.len) return error.UnexpectedEnd;
            for (bytes[pos.*..][0..16]) |lane| {
                if (lane >= sig.lanes) return error.InvalidLaneIndex;
            }
            pos.* += 16;
        },
        .lane => try readLane(bytes, pos, sig.lanes),
        .memarg, .memarg_lane => {
            const memarg = readMemArg(bytes, pos);
            if (memarg.align_val > sig.max_align) return error.InvalidAlignment;
            if (m.memories.items.len == 0 or memarg.mem_idx >= m.memories.items.len)
                return error.InvalidMemoryIndex;
            mem_idx = memarg.mem_idx;
            if (sig.imm == .memarg_lane) try readLane(bytes, pos, sig.lanes);
        },
    }

    // Operands are listed bottom-of-stack first, so pop in reverse.
    var i = sig.params.len;
    while (i > 0) {
        i -= 1;
        var expected = sig.params[i];
        // The address operand of a memarg form widens to i64 under memory64.
        // It is always the bottom-most operand.
        if (i == 0 and (sig.imm == .memarg or sig.imm == .memarg_lane) and
            m.memories.items[mem_idx].is_memory64)
        {
            expected = .i64;
        }
        try popExpect(val_stack, ctrl_stack, expected);
    }
    for (sig.results) |r| val_stack.append(alloc, r) catch return error.OutOfMemory;
}

fn simdSig(sub: u32) ?SimdSig {
    return switch (sub) {
        0x00 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 4 }, // v128_load
        0x01 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load8x8_s
        0x02 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load8x8_u
        0x03 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load16x4_s
        0x04 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load16x4_u
        0x05 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load32x2_s
        0x06 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load32x2_u
        0x07 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 0 }, // v128_load8_splat
        0x08 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 1 }, // v128_load16_splat
        0x09 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 2 }, // v128_load32_splat
        0x0a => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load64_splat
        0x0b => .{ .params = &.{.i32, .v128}, .results = &.{}, .imm = .memarg, .lanes = 0, .max_align = 4 }, // v128_store
        0x0c => .{ .params = &.{}, .results = &.{.v128}, .imm = .const16, .lanes = 0, .max_align = 0 }, // v128_const
        0x0d => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .shuffle, .lanes = 32, .max_align = 0 }, // i8x16_shuffle
        0x0e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_swizzle
        0x0f => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_splat
        0x10 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_splat
        0x11 => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_splat
        0x12 => .{ .params = &.{.i64}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_splat
        0x13 => .{ .params = &.{.f32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_splat
        0x14 => .{ .params = &.{.f64}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_splat
        0x15 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .lane, .lanes = 16, .max_align = 0 }, // i8x16_extract_lane_s
        0x16 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .lane, .lanes = 16, .max_align = 0 }, // i8x16_extract_lane_u
        0x17 => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .lane, .lanes = 16, .max_align = 0 }, // i8x16_replace_lane
        0x18 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .lane, .lanes = 8, .max_align = 0 }, // i16x8_extract_lane_s
        0x19 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .lane, .lanes = 8, .max_align = 0 }, // i16x8_extract_lane_u
        0x1a => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .lane, .lanes = 8, .max_align = 0 }, // i16x8_replace_lane
        0x1b => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .lane, .lanes = 4, .max_align = 0 }, // i32x4_extract_lane
        0x1c => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .lane, .lanes = 4, .max_align = 0 }, // i32x4_replace_lane
        0x1d => .{ .params = &.{.v128}, .results = &.{.i64}, .imm = .lane, .lanes = 2, .max_align = 0 }, // i64x2_extract_lane
        0x1e => .{ .params = &.{.v128, .i64}, .results = &.{.v128}, .imm = .lane, .lanes = 2, .max_align = 0 }, // i64x2_replace_lane
        0x1f => .{ .params = &.{.v128}, .results = &.{.f32}, .imm = .lane, .lanes = 4, .max_align = 0 }, // f32x4_extract_lane
        0x20 => .{ .params = &.{.v128, .f32}, .results = &.{.v128}, .imm = .lane, .lanes = 4, .max_align = 0 }, // f32x4_replace_lane
        0x21 => .{ .params = &.{.v128}, .results = &.{.f64}, .imm = .lane, .lanes = 2, .max_align = 0 }, // f64x2_extract_lane
        0x22 => .{ .params = &.{.v128, .f64}, .results = &.{.v128}, .imm = .lane, .lanes = 2, .max_align = 0 }, // f64x2_replace_lane
        0x23 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_eq
        0x24 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_ne
        0x25 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_lt_s
        0x26 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_lt_u
        0x27 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_gt_s
        0x28 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_gt_u
        0x29 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_le_s
        0x2a => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_le_u
        0x2b => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_ge_s
        0x2c => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_ge_u
        0x2d => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_eq
        0x2e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_ne
        0x2f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_lt_s
        0x30 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_lt_u
        0x31 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_gt_s
        0x32 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_gt_u
        0x33 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_le_s
        0x34 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_le_u
        0x35 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_ge_s
        0x36 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_ge_u
        0x37 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_eq
        0x38 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_ne
        0x39 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_lt_s
        0x3a => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_lt_u
        0x3b => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_gt_s
        0x3c => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_gt_u
        0x3d => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_le_s
        0x3e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_le_u
        0x3f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_ge_s
        0x40 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_ge_u
        0x41 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_eq
        0x42 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_ne
        0x43 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_lt
        0x44 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_gt
        0x45 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_le
        0x46 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_ge
        0x47 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_eq
        0x48 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_ne
        0x49 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_lt
        0x4a => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_gt
        0x4b => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_le
        0x4c => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_ge
        0x4d => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_not
        0x4e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_and
        0x4f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_andnot
        0x50 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_or
        0x51 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_xor
        0x52 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_bitselect
        0x53 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // v128_any_true
        0x54 => .{ .params = &.{.i32, .v128}, .results = &.{.v128}, .imm = .memarg_lane, .lanes = 16, .max_align = 0 }, // v128_load8_lane
        0x55 => .{ .params = &.{.i32, .v128}, .results = &.{.v128}, .imm = .memarg_lane, .lanes = 8, .max_align = 1 }, // v128_load16_lane
        0x56 => .{ .params = &.{.i32, .v128}, .results = &.{.v128}, .imm = .memarg_lane, .lanes = 4, .max_align = 2 }, // v128_load32_lane
        0x57 => .{ .params = &.{.i32, .v128}, .results = &.{.v128}, .imm = .memarg_lane, .lanes = 2, .max_align = 3 }, // v128_load64_lane
        0x58 => .{ .params = &.{.i32, .v128}, .results = &.{}, .imm = .memarg_lane, .lanes = 16, .max_align = 0 }, // v128_store8_lane
        0x59 => .{ .params = &.{.i32, .v128}, .results = &.{}, .imm = .memarg_lane, .lanes = 8, .max_align = 1 }, // v128_store16_lane
        0x5a => .{ .params = &.{.i32, .v128}, .results = &.{}, .imm = .memarg_lane, .lanes = 4, .max_align = 2 }, // v128_store32_lane
        0x5b => .{ .params = &.{.i32, .v128}, .results = &.{}, .imm = .memarg_lane, .lanes = 2, .max_align = 3 }, // v128_store64_lane
        0x5c => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 2 }, // v128_load32_zero
        0x5d => .{ .params = &.{.i32}, .results = &.{.v128}, .imm = .memarg, .lanes = 0, .max_align = 3 }, // v128_load64_zero
        0x5e => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_demote_f64x2_zero
        0x5f => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_promote_low_f32x4
        0x60 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_abs
        0x61 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_neg
        0x62 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_popcnt
        0x63 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_all_true
        0x64 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_bitmask
        0x65 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_narrow_i16x8_s
        0x66 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_narrow_i16x8_u
        0x67 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_ceil
        0x68 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_floor
        0x69 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_trunc
        0x6a => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_nearest
        0x6b => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_shl
        0x6c => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_shr_s
        0x6d => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_shr_u
        0x6e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_add
        0x6f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_add_sat_s
        0x70 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_add_sat_u
        0x71 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_sub
        0x72 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_sub_sat_s
        0x73 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_sub_sat_u
        0x74 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_ceil
        0x75 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_floor
        0x76 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_min_s
        0x77 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_min_u
        0x78 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_max_s
        0x79 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_max_u
        0x7a => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_trunc
        0x7b => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_avgr_u
        0x7c => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extadd_pairwise_i8x16_s
        0x7d => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extadd_pairwise_i8x16_u
        0x7e => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extadd_pairwise_i16x8_s
        0x7f => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extadd_pairwise_i16x8_u
        0x80 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_abs
        0x81 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_neg
        0x82 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_q15mulr_sat_s
        0x83 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_all_true
        0x84 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_bitmask
        0x85 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_narrow_i32x4_s
        0x86 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_narrow_i32x4_u
        0x87 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extend_low_i8x16_s
        0x88 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extend_high_i8x16_s
        0x89 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extend_low_i8x16_u
        0x8a => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extend_high_i8x16_u
        0x8b => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_shl
        0x8c => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_shr_s
        0x8d => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_shr_u
        0x8e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_add
        0x8f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_add_sat_s
        0x90 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_add_sat_u
        0x91 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_sub
        0x92 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_sub_sat_s
        0x93 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_sub_sat_u
        0x94 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_nearest
        0x95 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_mul
        0x96 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_min_s
        0x97 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_min_u
        0x98 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_max_s
        0x99 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_max_u
        0x9b => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_avgr_u
        0x9c => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extmul_low_i8x16_s
        0x9d => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extmul_high_i8x16_s
        0x9e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extmul_low_i8x16_u
        0x9f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_extmul_high_i8x16_u
        0xa0 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_abs
        0xa1 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_neg
        0xa3 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_all_true
        0xa4 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_bitmask
        0xa7 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extend_low_i16x8_s
        0xa8 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extend_high_i16x8_s
        0xa9 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extend_low_i16x8_u
        0xaa => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extend_high_i16x8_u
        0xab => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_shl
        0xac => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_shr_s
        0xad => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_shr_u
        0xae => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_add
        0xb1 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_sub
        0xb5 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_mul
        0xb6 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_min_s
        0xb7 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_min_u
        0xb8 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_max_s
        0xb9 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_max_u
        0xba => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_dot_i16x8_s
        0xbc => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extmul_low_i16x8_s
        0xbd => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extmul_high_i16x8_s
        0xbe => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extmul_low_i16x8_u
        0xbf => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_extmul_high_i16x8_u
        0xc0 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_abs
        0xc1 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_neg
        0xc3 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_all_true
        0xc4 => .{ .params = &.{.v128}, .results = &.{.i32}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_bitmask
        0xc7 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extend_low_i32x4_s
        0xc8 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extend_high_i32x4_s
        0xc9 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extend_low_i32x4_u
        0xca => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extend_high_i32x4_u
        0xcb => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_shl
        0xcc => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_shr_s
        0xcd => .{ .params = &.{.v128, .i32}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_shr_u
        0xce => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_add
        0xd1 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_sub
        0xd5 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_mul
        0xd6 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_eq
        0xd7 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_ne
        0xd8 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_lt_s
        0xd9 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_gt_s
        0xda => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_le_s
        0xdb => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_ge_s
        0xdc => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extmul_low_i32x4_s
        0xdd => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extmul_high_i32x4_s
        0xde => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extmul_low_i32x4_u
        0xdf => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_extmul_high_i32x4_u
        0xe0 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_abs
        0xe1 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_neg
        0xe3 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_sqrt
        0xe4 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_add
        0xe5 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_sub
        0xe6 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_mul
        0xe7 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_div
        0xe8 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_min
        0xe9 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_max
        0xea => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_pmin
        0xeb => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_pmax
        0xec => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_abs
        0xed => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_neg
        0xef => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_sqrt
        0xf0 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_add
        0xf1 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_sub
        0xf2 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_mul
        0xf3 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_div
        0xf4 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_min
        0xf5 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_max
        0xf6 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_pmin
        0xf7 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_pmax
        0xf8 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_trunc_sat_f32x4_s
        0xf9 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_trunc_sat_f32x4_u
        0xfa => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_convert_i32x4_s
        0xfb => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_convert_i32x4_u
        0xfc => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_trunc_sat_f64x2_s_zero
        0xfd => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_trunc_sat_f64x2_u_zero
        0xfe => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_convert_low_i32x4_s
        0xff => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_convert_low_i32x4_u
        0x100 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_relaxed_swizzle
        0x101 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_relaxed_trunc_f32x4_s
        0x102 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_relaxed_trunc_f32x4_u
        0x103 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_relaxed_trunc_f64x2_s_zero
        0x104 => .{ .params = &.{.v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_relaxed_trunc_f64x2_u_zero
        0x105 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_relaxed_madd
        0x106 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_relaxed_nmadd
        0x107 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_relaxed_madd
        0x108 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_relaxed_nmadd
        0x109 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i8x16_relaxed_laneselect
        0x10a => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_relaxed_laneselect
        0x10b => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_relaxed_laneselect
        0x10c => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i64x2_relaxed_laneselect
        0x10d => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_relaxed_min
        0x10e => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f32x4_relaxed_max
        0x10f => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_relaxed_min
        0x110 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // f64x2_relaxed_max
        0x111 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_relaxed_q15mulr_s
        0x112 => .{ .params = &.{.v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i16x8_dot_i8x16_i7x16_s
        0x113 => .{ .params = &.{.v128, .v128, .v128}, .results = &.{.v128}, .imm = .none, .lanes = 0, .max_align = 0 }, // i32x4_dot_i8x16_i7x16_add_s
        else => null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

test "validate empty module" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try validate(&module, .{});
}

test "validate invalid type index in func" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.funcs.append(std.testing.allocator, .{ .decl = .{ .type_var = .{ .index = 99 } } });
    try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
}

test "validate duplicate export names" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.funcs.append(std.testing.allocator, .{});
    try module.exports.append(std.testing.allocator, .{ .name = "a", .kind = .func, .var_ = .{ .index = 0 } });
    try module.exports.append(std.testing.allocator, .{ .name = "a", .kind = .func, .var_ = .{ .index = 0 } });
    try std.testing.expectError(error.DuplicateExport, validate(&module, .{}));
}

test "validate export func index out of range" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.exports.append(std.testing.allocator, .{ .name = "f", .kind = .func, .var_ = .{ .index = 5 } });
    try std.testing.expectError(error.InvalidFuncIndex, validate(&module, .{}));
}

test "validate too many memories" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.memories.append(std.testing.allocator, .{});
    try module.memories.append(std.testing.allocator, .{});
    // With multi_memory disabled, two memories should fail
    try std.testing.expectError(error.TooManyMemories, validate(&module, .{ .features = .{ .multi_memory = false } }));
    // With multi_memory enabled (default), should pass
    try validate(&module, .{});
}

test "validate invalid limits (max < initial)" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.memories.append(std.testing.allocator, .{
        .type = .{ .limits = .{ .initial = 10, .max = 5, .has_max = true } },
    });
    try std.testing.expectError(error.InvalidLimits, validate(&module, .{}));
}

test "validate start function must be nullary" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    // Add a type (i32) -> ()
    const params = try alloc.alloc(types.ValType, 1);
    params[0] = .i32;
    try module.module_types.append(alloc, .{ .func_type = .{ .params = params } });
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    module.start_var = .{ .index = 0 };
    try std.testing.expectError(error.InvalidStart, validate(&module, .{}));
}

test "validate valid module with export" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    try module.memories.append(std.testing.allocator, .{
        .type = .{ .limits = .{ .initial = 1, .has_max = true, .max = 256 } },
    });
    try module.exports.append(std.testing.allocator, .{ .name = "mem", .kind = .memory, .var_ = .{ .index = 0 } });
    try validate(&module, .{});
}

test "validate invalid local index via code_bytes" {
    const alloc = std.testing.allocator;
    const binary_reader = @import("binary/reader.zig");
    // (module (type (func)) (func (type 0) (local.get 5)))
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type section: () -> ()
        0x03, 0x02, 0x01, 0x00, // func section: type 0
        0x0a, 0x06, 0x01, 0x04, 0x00, // code: 1 body, size 4, 0 locals
        0x20, 0x05, // local.get 5 (invalid)
        0x0b, // end
    };
    var module = try binary_reader.readModule(alloc, &wasm);
    defer module.deinit();
    try std.testing.expectError(error.InvalidLocalIndex, validate(&module, .{}));
}

test "validate unknown global via code_bytes" {
    const alloc = std.testing.allocator;
    const binary_reader = @import("binary/reader.zig");
    // (module (type (func)) (func (type 0) (global.get 0))) — no globals
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type section: () -> ()
        0x03, 0x02, 0x01, 0x00, // func section: type 0
        0x0a, 0x06, 0x01, 0x04, 0x00, // code: 1 body, size 4, 0 locals
        0x23, 0x00, // global.get 0 (invalid — no globals)
        0x0b, // end
    };
    var module = try binary_reader.readModule(alloc, &wasm);
    defer module.deinit();
    try std.testing.expectError(error.InvalidGlobalIndex, validate(&module, .{}));
}

test "validate type mismatch via text parser" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    // (module (func (result i32))) — claims to return i32 but body is empty
    var module = try Parser.parseModule(alloc, "(module (func (result i32)))");
    defer module.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "return with empty operand in store should fail" {
    const alloc = std.testing.allocator;
    const TextParser = @import("text/Parser.zig");
    // (return (i32.store)) — i32.store needs operands, inside return
    var module = try TextParser.parseModule(alloc,
        \\(module
        \\  (memory 1)
        \\  (func $type-address-empty-in-return
        \\    (return (i32.store))
        \\  )
        \\)
    );
    defer module.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "br with empty stack in typed block should fail" {
    const alloc = std.testing.allocator;
    // block (result i32), br 0 with empty stack inside → TypeMismatch
    const bytes = [_]u8{
        0x02, 0x7f, // block (result i32)
        0x0c, 0x00, // br 0 — needs i32 but stack is empty inside block
        0x0b, // end (block)
        0x0b, // end (function)
    };
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = &bytes,
    });
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "memarg read consumes exactly 2 varuints (load)" {
    // Regression: checkMemLoad used to read 3 varuints (mem_idx, align, offset),
    // which over-consumed the byte stream and corrupted later instructions.
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    var module = try Parser.parseModule(alloc,
        \\(module
        \\  (memory 1)
        \\  (func $f (param $p i32) (result i32)
        \\    local.get $p
        \\    i32.load))
    );
    defer module.deinit();
    try validate(&module, .{});
}

test "memarg read consumes exactly 2 varuints (store)" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    var module = try Parser.parseModule(alloc,
        \\(module
        \\  (memory 1)
        \\  (func $f (param $p i32) (param $v i32)
        \\    local.get $p
        \\    local.get $v
        \\    i32.store))
    );
    defer module.deinit();
    try validate(&module, .{});
}

test "load with multi-memory bit + explicit mem-idx" {
    // Hand-roll a memarg with bit 6 set in align byte → mem-idx follows.
    // (module (memory 0 1) (memory 0 1) (func (param i32) (result i32)
    //    local.get 0
    //    i32.load align=4 offset=0 (mem 1)))
    const alloc = std.testing.allocator;
    const bytes = [_]u8{
        0x20, 0x00, // local.get 0
        0x28, 0x42, 0x01, 0x00, // i32.load align=2|0x40 mem-idx=1 offset=0
        0x0b, // end
    };
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{
        .params = try alloc.dupe(types.ValType, &[_]types.ValType{.i32}),
        .results = try alloc.dupe(types.ValType, &[_]types.ValType{.i32}),
    } });
    try module.memories.append(alloc, .{ .@"type" = .{ .limits = .{ .initial = 0 } } });
    try module.memories.append(alloc, .{ .@"type" = .{ .limits = .{ .initial = 0 } } });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = &bytes,
    });
    try validate(&module, .{});
}

test "block end does not clobber local-init state" {
    // Regression: a `block ... end` used to restore local_inited from
    // an unset saved_init (zero-filled), marking every local
    // uninitialised. This valid program then failed with TypeMismatch
    // on the subsequent local.get.
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    var module = try Parser.parseModule(alloc,
        \\(module
        \\  (func $f (param $p i32) (result i32)
        \\    block
        \\    end
        \\    local.get $p))
    );
    defer module.deinit();
    try validate(&module, .{});
}

test "local.set inside block does not escape (spec local_init.wast)" {
    // Per the function-references local-init rules (spec test
    // `uninit-after-end` in testsuite/local_init.wast), a non-nullable
    // ref local that is only ever set inside a `block` body remains
    // uninitialised after the block ends, because an early `br` could
    // have skipped the set.
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    var module = try Parser.parseModule(alloc,
        \\(module
        \\  (func $f (param $p (ref extern))
        \\    (local $x (ref extern))
        \\    (block (local.set $x (local.get $p)))
        \\    (drop (local.get $x))))
    );
    defer module.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

// ── Unrecognised opcodes (issue #347) ───────────────────────────────────

/// Build a single-function module whose body is `body`, with one memory so
/// that memory instructions resolve.
fn testModuleWithBody(alloc: std.mem.Allocator, body: []const u8) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    try module.memories.append(alloc, .{});
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

test "atomics are not silently accepted without type checking" {
    // Regression for issue #347. The 0xfe arm used to skip the sub-opcode
    // and memarg and keep going without modelling stack effects, so every
    // later instruction was checked against a stale value stack and invalid
    // modules were accepted.
    //
    //   f64.const 0        ;; wrong operand type for the address
    //   i32.atomic.load
    //   drop
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x44, 0, 0, 0, 0, 0, 0, 0, 0, // f64.const 0
        0xfe, 0x10, 0x02, 0x00, // i32.atomic.load align=2 offset=0
        0x1a, // drop
        0x0b, // end
    };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try std.testing.expectError(error.UnsupportedOpcode, validate(&module, .{}));
}

test "unchecked 0xfc sub-opcodes are reported, not ignored" {
    // i64.add128 (0xfc 0x13) has no arm; the inner `else` used to fall
    // through silently, leaving the value stack wrong for what followed.
    const alloc = std.testing.allocator;
    const body = [_]u8{ 0xfc, 0x13, 0x0b };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try std.testing.expectError(error.UnsupportedOpcode, validate(&module, .{}));
}

test "valid SIMD modules now validate (issue #347 D2)" {
    // v128.const 0; drop. Before SIMD type-checking this was rejected --
    // first as a bogus TypeMismatch, then honestly as UnsupportedOpcode.
    // It is a valid module and must now be accepted.
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // v128.const 0
        0x1a, // drop
        0x0b, // end
    };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try validate(&module, .{});
}

test "reference-typed call opcodes are reported as unsupported" {
    // return_call and return_call_indirect are type-checked as of the tail
    // call work below. call_ref and return_call_ref are not: their operand
    // is a typed reference and ValType carries no type index.
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        &[_]u8{ 0x14, 0x00, 0x0b }, // call_ref 0
        &[_]u8{ 0x15, 0x00, 0x0b }, // return_call_ref 0
    }) |body| {
        var module = try testModuleWithBody(alloc, body);
        defer module.deinit();
        try std.testing.expectError(error.UnsupportedOpcode, validate(&module, .{}));
    }
}

test "meaningless opcodes are distinguished from unimplemented ones" {
    // 0x27 is not assigned by any proposal this build knows about.
    const alloc = std.testing.allocator;
    const body = [_]u8{ 0x27, 0x0b };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try std.testing.expectError(error.UnknownOpcode, validate(&module, .{}));
}

test "classifyOpcode separates declared opcodes from undeclared encodings" {
    // Code is a non-exhaustive enum, so this must test for a declared field
    // rather than a successful @enumFromInt.
    try std.testing.expectEqual(error.UnsupportedOpcode, classifyOpcode(null, 0x12)); // return_call
    try std.testing.expectEqual(error.UnknownOpcode, classifyOpcode(null, 0x27)); // unassigned
    try std.testing.expectEqual(error.UnsupportedOpcode, classifyOpcode(Opcode.prefix_simd, 0x0c)); // v128.const
    try std.testing.expectEqual(error.UnknownOpcode, classifyOpcode(Opcode.prefix_simd, 0xffff));
    // Relaxed SIMD lives above 0xff, where Opcode.Code switches to 0xPPCCC.
    // A fixed <<8 would fold 0x100 onto 0xfd00 (v128.load) and answer the
    // wrong question.
    try std.testing.expectEqual(error.UnsupportedOpcode, classifyOpcode(Opcode.prefix_simd, 0x100));
    try std.testing.expectEqual(error.UnknownOpcode, classifyOpcode(Opcode.prefix_simd, 0x1fe));
}

test "every declared single-byte opcode is handled or explicitly unsupported" {
    // Drift guard for issue #347. Adding an opcode to Opcode.zig without
    // giving the validator an arm must not silently reopen the gap, so this
    // asserts both directions: opcodes on the backlog below must report
    // UnsupportedOpcode, and every other declared opcode must reach a real
    // arm (any other error is fine — a bare opcode byte is rarely a
    // well-typed body — but it must not come back as un-handled).
    //
    // The backlog is in the order the issue plans to clear it: tail calls
    // and typed refs (PR3), exception handling (PR4).
    const known_unsupported = [_]u8{
        0x06, 0x07, 0x08, 0x09, 0x0a, // try, catch, throw, rethrow, throw_ref
        0x14, 0x15, // call_ref, return_call_ref
        0x18, 0x19, 0x1f, // delegate, catch_all, try_table
        0xd3, 0xd4, 0xd5, 0xd6, // ref.eq, ref.as_non_null, br_on_null, br_on_non_null
    };
    const alloc = std.testing.allocator;
    var checked: usize = 0;
    inline for (@typeInfo(Opcode.Code).@"enum".fields) |f| {
        if (f.value <= 0xff) {
            const op: u8 = @intCast(f.value);
            const body = [_]u8{ op, 0x0b };
            var module = try testModuleWithBody(alloc, &body);
            defer module.deinit();
            checked += 1;
            if (std.mem.indexOfScalar(u8, &known_unsupported, op) != null) {
                try std.testing.expectError(error.UnsupportedOpcode, validate(&module, .{}));
            } else if (validate(&module, .{})) |_| {} else |err| switch (err) {
                error.UnsupportedOpcode, error.UnknownOpcode => {
                    std.debug.print(
                        "opcode 0x{x:0>2} ({s}) has no validator arm; add one or list it above\n",
                        .{ op, f.name },
                    );
                    return error.TestUnexpectedResult;
                },
                else => {},
            }
        }
    }
    // Guard against the loop silently stopping to exercise anything.
    try std.testing.expect(checked > 150);
}

test "ref.eq is a declared opcode, not a malformed encoding (issue #350)" {
    // 0xd3 was absent from Opcode.Code while text/Parser.zig emitted it, so
    // wabt rejected its own output and told the author the source was
    // malformed. It must classify like its neighbours: a real instruction
    // that is not type-checked yet, not a meaningless byte.
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(error.UnsupportedOpcode, classifyOpcode(null, 0xd3));
    for ([_]u8{ 0xd3, 0xd4 }) |op| {
        const body = [_]u8{ op, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.UnsupportedOpcode, validate(&module, .{}));
    }
    try std.testing.expectEqualStrings("ref.eq", Opcode.Code.ref_eq.name());
}

// ── SIMD type checking (issue #347, D2) ─────────────────────────────────

test "every declared SIMD opcode has a signature" {
    // Drift guard: Opcode.zig and simdSig must agree. Adding a 0xfd opcode
    // to Opcode.zig without a signature here would silently send it back to
    // classifyOpcode and re-reject valid modules, which is the bug D2 was.
    var checked: usize = 0;
    inline for (@typeInfo(Opcode.Code).@"enum".fields) |f| {
        if (f.value > 0xff) {
            const code: Opcode.Code = @enumFromInt(f.value);
            if (code.getPrefix() == Opcode.prefix_simd) {
                checked += 1;
                if (simdSig(code.getCode()) == null) {
                    std.debug.print(
                        "SIMD opcode 0x{x} ({s}) has no signature in simdSig\n",
                        .{ f.value, f.name },
                    );
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 256), checked);
}

test "SIMD signatures type-check operands" {
    const alloc = std.testing.allocator;

    // i32.const 0; i32.const 0; i8x16.splat -> wrong: splat takes one i32
    // and leaves a v128, so the extra i32 remains and the body is not empty
    // at end. Use drop to make the shape explicit instead.
    {
        // v128.const 0; v128.const 0; i8x16.add; drop  -- well typed
        const body = [_]u8{
            0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0xfd, 0x6e, // i8x16.add
            0x1a, 0x0b,
        };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try validate(&module, .{});
    }
    {
        // i32.const 0; i8x16.add -- operand is i32, not v128
        const body = [_]u8{ 0x41, 0x00, 0xfd, 0x6e, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
    }
    {
        // i32.const 0; i8x16.splat; drop -- splat consumes i32, yields v128
        const body = [_]u8{ 0x41, 0x00, 0xfd, 0x0f, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try validate(&module, .{});
    }
    {
        // f32.const 0; i8x16.splat -- splat wants i32
        const body = [_]u8{ 0x43, 0, 0, 0, 0, 0xfd, 0x0f, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
    }
}

test "SIMD extract_lane yields the lane's scalar type" {
    const alloc = std.testing.allocator;
    // v128.const 0; i64x2.extract_lane 0; drop -- yields i64
    const body = [_]u8{
        0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xfd, 0x1d, 0x00, // i64x2.extract_lane 0
        0x1a, 0x0b,
    };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try validate(&module, .{});

    // ...and it really is i64, not i32: i32.eqz on it must fail.
    const body2 = [_]u8{
        0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xfd, 0x1d, 0x00,
        0x45, // i32.eqz
        0x1a, 0x0b,
    };
    var m2 = try testModuleWithBody(alloc, &body2);
    defer m2.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m2, .{}));
}

test "SIMD lane indices are bounds-checked" {
    const alloc = std.testing.allocator;
    // i64x2 has 2 lanes, so lane 2 is out of range.
    const body = [_]u8{
        0xfd, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xfd, 0x1d, 0x02, // i64x2.extract_lane 2
        0x1a, 0x0b,
    };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try std.testing.expectError(error.InvalidLaneIndex, validate(&module, .{}));

    // i8x16.shuffle indices select from two concatenated vectors, so 31 is
    // in range and 32 is not.
    const ok = [_]u8{ 0xfd, 0x0c } ++ [_]u8{0} ** 16 ++ [_]u8{ 0xfd, 0x0c } ++
        [_]u8{0} ** 16 ++ [_]u8{ 0xfd, 0x0d } ++ [_]u8{31} ** 16 ++ [_]u8{ 0x1a, 0x0b };
    var m_ok = try testModuleWithBody(alloc, &ok);
    defer m_ok.deinit();
    try validate(&m_ok, .{});

    const bad = [_]u8{ 0xfd, 0x0c } ++ [_]u8{0} ** 16 ++ [_]u8{ 0xfd, 0x0c } ++
        [_]u8{0} ** 16 ++ [_]u8{ 0xfd, 0x0d } ++ [_]u8{32} ** 16 ++ [_]u8{ 0x1a, 0x0b };
    var m_bad = try testModuleWithBody(alloc, &bad);
    defer m_bad.deinit();
    try std.testing.expectError(error.InvalidLaneIndex, validate(&m_bad, .{}));
}

test "SIMD memarg alignment is bounds-checked" {
    const alloc = std.testing.allocator;
    // v128.load accesses 16 bytes, so align=4 is the natural maximum.
    const ok = [_]u8{ 0x41, 0x00, 0xfd, 0x00, 0x04, 0x00, 0x1a, 0x0b };
    var m_ok = try testModuleWithBody(alloc, &ok);
    defer m_ok.deinit();
    try validate(&m_ok, .{});

    const bad = [_]u8{ 0x41, 0x00, 0xfd, 0x00, 0x05, 0x00, 0x1a, 0x0b };
    var m_bad = try testModuleWithBody(alloc, &bad);
    defer m_bad.deinit();
    try std.testing.expectError(error.InvalidAlignment, validate(&m_bad, .{}));

    // v128.load8_splat reads one byte: align=0 only.
    const bad8 = [_]u8{ 0x41, 0x00, 0xfd, 0x07, 0x01, 0x00, 0x1a, 0x0b };
    var m_bad8 = try testModuleWithBody(alloc, &bad8);
    defer m_bad8.deinit();
    try std.testing.expectError(error.InvalidAlignment, validate(&m_bad8, .{}));
}

test "SIMD store consumes its operands and leaves nothing" {
    const alloc = std.testing.allocator;
    // i32.const 0; v128.const 0; v128.store
    const body = [_]u8{ 0x41, 0x00, 0xfd, 0x0c } ++ [_]u8{0} ** 16 ++
        [_]u8{ 0xfd, 0x0b, 0x04, 0x00, 0x0b };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try validate(&module, .{});

    // Operands reversed: v128 address, i32 value.
    const rev = [_]u8{ 0xfd, 0x0c } ++ [_]u8{0} ** 16 ++
        [_]u8{ 0x41, 0x00, 0xfd, 0x0b, 0x04, 0x00, 0x0b };
    var m_rev = try testModuleWithBody(alloc, &rev);
    defer m_rev.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m_rev, .{}));
}

test "SIMD immediates that run off the end are rejected" {
    const alloc = std.testing.allocator;
    // v128.const with only 3 of its 16 bytes present.
    const body = [_]u8{ 0xfd, 0x0c, 0, 0, 0 };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try std.testing.expectError(error.UnexpectedEnd, validate(&module, .{}));
}

test "relaxed SIMD opcodes above 0xff are type-checked" {
    const alloc = std.testing.allocator;
    // f32x4.relaxed_madd (0xfd 0x105) is ternary over v128.
    const three = [_]u8{ 0xfd, 0x0c } ++ [_]u8{0} ** 16;
    const body = three ++ three ++ three ++ [_]u8{ 0xfd, 0x85, 0x02, 0x1a, 0x0b };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try validate(&module, .{});
}

// ── Tail calls (issue #347) ─────────────────────────────────────────────

/// Build a module with an enclosing function (whose body is `body`) and a
/// callee at index 1, so tail-call targets can be given real signatures.
fn testTailCallModule(
    alloc: std.mem.Allocator,
    caller_results: []const types.ValType,
    callee_params: []const types.ValType,
    callee_results: []const types.ValType,
    body: []const u8,
    with_table: bool,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    // Module.deinit frees params/results, so they must be owned copies.
    try module.module_types.append(alloc, .{ .func_type = .{
        .results = try alloc.dupe(types.ValType, caller_results),
    } });
    try module.module_types.append(alloc, .{ .func_type = .{
        .params = try alloc.dupe(types.ValType, callee_params),
        .results = try alloc.dupe(types.ValType, callee_results),
    } });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 1 } } });
    if (with_table) try module.tables.append(alloc, .{});
    return module;
}

test "return_call requires the callee's results to be the caller's" {
    const alloc = std.testing.allocator;
    const i32_1 = [_]types.ValType{.i32};

    // caller [] -> [], callee [] -> []  : matching
    {
        var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try validate(&m, .{});
    }
    // caller [] -> [i32], callee [] -> [i32] : matching
    {
        var m = try testTailCallModule(alloc, &i32_1, &.{}, &i32_1, &[_]u8{ 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try validate(&m, .{});
    }
    // caller [] -> [i32], callee [] -> [] : the callee cannot supply the
    // caller's result, and nothing runs after a tail call to fix that up.
    {
        var m = try testTailCallModule(alloc, &i32_1, &.{}, &.{}, &[_]u8{ 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // caller [] -> [], callee [] -> [i32]
    {
        var m = try testTailCallModule(alloc, &.{}, &.{}, &i32_1, &[_]u8{ 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // caller [] -> [i32], callee [] -> [i64] : same arity, wrong type
    {
        const i64_1 = [_]types.ValType{.i64};
        var m = try testTailCallModule(alloc, &i32_1, &.{}, &i64_1, &[_]u8{ 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "return_call consumes the callee's parameters" {
    const alloc = std.testing.allocator;
    const i32_1 = [_]types.ValType{.i32};

    // i32.const 0; return_call 1   where callee is [i32] -> []
    {
        var m = try testTailCallModule(alloc, &.{}, &i32_1, &.{}, &[_]u8{ 0x41, 0x00, 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try validate(&m, .{});
    }
    // wrong operand type
    {
        const body = [_]u8{ 0x43, 0, 0, 0, 0, 0x12, 0x01, 0x0b }; // f32.const 0
        var m = try testTailCallModule(alloc, &.{}, &i32_1, &.{}, &body, false);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // missing operand entirely
    {
        var m = try testTailCallModule(alloc, &.{}, &i32_1, &.{}, &[_]u8{ 0x12, 0x01, 0x0b }, false);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "return_call rejects an out-of-range function index" {
    const alloc = std.testing.allocator;
    var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x12, 0x07, 0x0b }, false);
    defer m.deinit();
    try std.testing.expectError(error.InvalidFuncIndex, validate(&m, .{}));
}

test "return_call makes the rest of the body unreachable" {
    const alloc = std.testing.allocator;
    // return_call 1; i64.add; drop; end -- i64.add is reached with nothing on
    // the stack, which is only legal because a tail call makes the rest of
    // the body stack-polymorphic. The drop is needed because polymorphism
    // supplies i64.add's missing operands but not a home for its result,
    // and the enclosing function returns nothing.
    var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x12, 0x01, 0x7c, 0x1a, 0x0b }, false);
    defer m.deinit();
    try validate(&m, .{});

    // Without the tail call the same body is a plain type error.
    var m2 = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x7c, 0x1a, 0x0b }, false);
    defer m2.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m2, .{}));
}

test "return_call_indirect type-checks like return_call" {
    const alloc = std.testing.allocator;
    const i32_1 = [_]types.ValType{.i32};

    // i32.const 0 (table index); return_call_indirect type=1 table=0
    {
        var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x41, 0x00, 0x13, 0x01, 0x00, 0x0b }, true);
        defer m.deinit();
        try validate(&m, .{});
    }
    // result mismatch against the enclosing function
    {
        var m = try testTailCallModule(alloc, &i32_1, &.{}, &.{}, &[_]u8{ 0x41, 0x00, 0x13, 0x01, 0x00, 0x0b }, true);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // no table declared
    {
        var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x41, 0x00, 0x13, 0x01, 0x00, 0x0b }, false);
        defer m.deinit();
        try std.testing.expectError(error.InvalidTableIndex, validate(&m, .{}));
    }
    // missing the i32 table operand
    {
        var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x13, 0x01, 0x00, 0x0b }, true);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // out-of-range type index
    {
        var m = try testTailCallModule(alloc, &.{}, &.{}, &.{}, &[_]u8{ 0x41, 0x00, 0x13, 0x09, 0x00, 0x0b }, true);
        defer m.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&m, .{}));
    }
}

test "call_ref and return_call_ref stay rejected" {
    // ValType carries no type index, so the operand of call_ref cannot be
    // checked against the instruction's immediate. Accepting them would
    // report success on something unverified, which is the fail-open this
    // issue is about. They remain on the backlog.
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        &[_]u8{ 0x14, 0x00, 0x0b }, // call_ref 0
        &[_]u8{ 0x15, 0x00, 0x0b }, // return_call_ref 0
    }) |body| {
        var m = try testModuleWithBody(alloc, body);
        defer m.deinit();
        try std.testing.expectError(error.UnsupportedOpcode, validate(&m, .{}));
    }
}
