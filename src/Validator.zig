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
const instr = @import("binary/instr.zig");
const reader = @import("binary/reader.zig");

pub const Error = error{
    InvalidTypeIndex,
    InvalidFuncIndex,
    InvalidTableIndex,
    InvalidMemoryIndex,
    InvalidGlobalIndex,
    InvalidTagIndex,
    /// A `try_table` catch clause used a byte other than the four defined
    /// clause kinds (0x00 catch, 0x01 catch_ref, 0x02 catch_all,
    /// 0x03 catch_all_ref).
    InvalidCatchKind,
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
    /// A legacy exception-handling instruction (`try`, `catch`, `rethrow`,
    /// `delegate`, `catch_all`). Distinct from `UnsupportedOpcode` because
    /// this is a decision, not a backlog item: the legacy proposal was
    /// superseded by `try_table`/`throw_ref` before exception handling was
    /// standardised, and wabt implements only the standardised form.
    /// See issue #356.
    LegacyExceptionsUnsupported,
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
    try checkGlobals(module, options);
    try checkTags(module);
    try checkExports(module);
    try checkStart(module);
    try checkElemSegments(module, options);
    try checkDataSegments(module, options);
    try checkFunctionBodies(module);
}

// ── Validation passes ───────────────────────────────────────────────────

fn checkTypes(m: *const Mod.Module) Error!void {
    for (m.module_types.items, 0..) |entry, idx| {
        switch (entry) {
            .func_type => |ft| {
                for (ft.params, 0..) |p, i| {
                    if (!p.isNumType() and !p.isRefType()) return error.InvalidTypeIndex;
                    if (!checkConcreteTypeIndex(m, p, typeIndexAt(ft.param_type_idxs, i))) return error.InvalidTypeIndex;
                }
                for (ft.results, 0..) |r, i| {
                    if (!r.isNumType() and !r.isRefType()) return error.InvalidTypeIndex;
                    if (!checkConcreteTypeIndex(m, r, typeIndexAt(ft.result_type_idxs, i))) return error.InvalidTypeIndex;
                }
            },
            // Fields and array elements are *storage* types, so the packed
            // types are admissible here and nowhere else.
            .struct_type => |st| for (st.fields.items) |f| {
                if (!isStorageType(f.@"type")) return error.InvalidTypeIndex;
                if (!checkConcreteTypeIndex(m, f.@"type", f.type_idx)) return error.InvalidTypeIndex;
            },
            .array_type => |at| {
                if (!isStorageType(at.field.@"type")) return error.InvalidTypeIndex;
                if (!checkConcreteTypeIndex(m, at.field.@"type", at.field.type_idx)) return error.InvalidTypeIndex;
            },
        }
        if (idx < m.type_meta.items.len and m.type_meta.items[idx].kind != typeEntryKind(entry))
            return error.TypeMismatch;
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
            if (!structuralConcreteSubtype(m, @intCast(idx), meta.parent, 0)) return error.TypeMismatch;
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
        if (!checkConcreteTypeIndex(m, table.type.elem_type, table.type_idx))
            return error.InvalidTypeIndex;
        try checkLimits(table.@"type".limits, std.math.maxInt(u32));
        const elem = StackType.fromValTypeAndIndex(table.type.elem_type, table.type_idx);
        if (table.init_expr_bytes.len > 0) {
            // A table's initializer is a constant expression like any other,
            // so it is type-checked like any other rather than by inspecting
            // its first byte. The table section precedes the global section,
            // so only an imported global is in scope here whatever the GC
            // feature says about globals reading globals.
            try checkConstExpr(m, table.init_expr_bytes, elem, m.num_global_imports, options.features);
        } else if (!table.is_import and elem.isNonNullableRef()) {
            // A defined table whose element type has no null needs an
            // initializer to say what its slots hold. An imported one does
            // not: whoever supplies it has already filled it.
            return error.TypeMismatch;
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

fn checkGlobals(m: *const Mod.Module, options: Options) Error!void {
    for (m.globals.items, 0..) |global, i| {
        if (!global.type.val_type.isNumType() and !global.type.val_type.isRefType())
            return error.InvalidTypeIndex;
        if (!checkConcreteTypeIndex(m, global.type.val_type, global.type_idx))
            return error.InvalidTypeIndex;
        // Validate init expression for non-imported globals
        if (!global.is_import) {
            const expected = StackType.fromValTypeAndIndex(global.type.val_type, global.type_idx);
            try checkConstExpr(m, global.init_expr_bytes, expected, @intCast(i), options.features);
        }
    }
}

fn checkTags(m: *const Mod.Module) Error!void {
    for (m.tags.items) |tag| {
        // Tag types must have empty result types per spec.
        if (tag.@"type".sig.results.len > 0) return error.TypeMismatch;
        // A tag's type index must name a function type in the module. The
        // binary reader checks this as it decodes, but a tag can also arrive
        // from the text parser, so re-check rather than trust the producer.
        if (tag.type_idx != std.math.maxInt(u32)) {
            if (tag.type_idx >= m.module_types.items.len) return error.InvalidTypeIndex;
            switch (m.module_types.items[tag.type_idx]) {
                .func_type => {},
                else => return error.InvalidTypeIndex,
            }
        }
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

fn checkElemSegments(m: *const Mod.Module, options: Options) Error!void {
    for (m.elem_segments.items) |seg| {
        // Validate elem type index references a valid type
        if (seg.elem_type_idx != 0xFFFFFFFF and seg.elem_type_idx >= m.module_types.items.len)
            return error.InvalidTypeIndex;
        if (seg.kind == .active) {
            if (m.tables.items.len == 0 or seg.table_var.index >= m.tables.items.len)
                return error.InvalidTableIndex;
            const table = m.tables.items[seg.table_var.index];
            // The offset indexes the table, so it is of the table's index
            // type. Requiring i32 of every table rejected each segment of a
            // 64-bit one.
            try checkConstExpr(
                m,
                seg.offset_expr_bytes,
                StackType.fromValType(table.type.limits.indexType()),
                null,
                options.features,
            );
            // Validate elem type matches table type
            const elem_type = StackType.fromValTypeAndIndex(seg.elem_type, seg.elem_type_idx);
            const table_type = StackType.fromValTypeAndIndex(table.type.elem_type, table.type_idx);
            if (!elem_type.isSubtypeOf(m, table_type))
                return error.TypeMismatch;
        }
        // Validate elem expressions
        if (seg.elem_expr_count > 0) {
            const expected = StackType.fromValTypeAndIndex(seg.elem_type, seg.elem_type_idx);
            try checkElemExprs(m, seg.elem_expr_bytes, expected, seg.elem_expr_count, options.features);
        }
        // A segment names its elements either as bare function indices or as
        // expressions, never both. `elem_var_indices` shadows the expression
        // form lossily -- an element that is `ref.null` has no index, and is
        // recorded as `maxInt(u32)` -- so reading it as a function index
        // rejected every segment holding a null. The expressions are the
        // truth, and `checkElemExprs` above has already checked them.
        if (seg.elem_expr_count == 0) {
            for (seg.elem_var_indices.items) |v| {
                if (v.index >= m.funcs.items.len)
                    return error.InvalidFuncIndex;
            }
        }
    }
}

/// Validate elem expressions encoded as consecutive constant expressions
/// separated by 0x0b terminators.
fn checkElemExprs(m: *const Mod.Module, bytes: []const u8, expected: StackType, count: u32, features: Feature.Set) Error!void {
    var pos: usize = 0;
    var remaining = count;

    while (remaining > 0 and pos < bytes.len) {
        // Find the end of this expression. It is terminated by an `end`, but
        // scanning for a 0x0b byte finds the first one that *looks* like an
        // end, which may be part of an immediate: `ref.func 11` encodes as
        // d2 0b, so an element segment referring to function 11 was cut in
        // half. Step over whole instructions instead.
        const start = pos;
        while (pos < bytes.len) {
            if (bytes[pos] == 0x0b) break;
            var probe = pos;
            const decoded = instr.decode(bytes, &probe) catch return error.UnsupportedOpcode;
            instr.skipImmediates(decoded.shape, bytes, &probe) catch return error.UnexpectedEnd;
            pos = probe;
        }
        try checkConstExpr(m, bytes[start..pos], expected, null, features);

        // Skip past the 0x0b terminator
        if (pos < bytes.len) pos += 1;
        remaining -= 1;
    }
}

fn checkDataSegments(m: *const Mod.Module, options: Options) Error!void {
    for (m.data_segments.items) |seg| {
        if (seg.kind == .active) {
            if (m.memories.items.len == 0 or seg.memory_var.index >= m.memories.items.len)
                return error.InvalidMemoryIndex;
            // As for element segments, the offset is of the memory's index
            // type rather than always i32.
            const memory = m.memories.items[seg.memory_var.index];
            try checkConstExpr(
                m,
                seg.offset_expr_bytes,
                StackType.fromValType(memory.type.limits.indexType()),
                null,
                options.features,
            );
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
///
/// The constant instructions are the `*.const` forms, `ref.null`, `ref.func`
/// and `global.get`; with the extended-const feature the integer `add`, `sub`
/// and `mul` forms join them. The expression must leave exactly one value, of
/// the expected type.
///
/// `global_limit` restricts global.get to globals with index < global_limit
/// (for global init, this is the index of the global being defined).
fn checkConstExpr(
    m: *const Mod.Module,
    bytes: []const u8,
    expected: StackType,
    global_limit: ?u32,
    features: Feature.Set,
) Error!void {
    var pos: usize = 0;

    // A constant expression is type-checked like any other: an operand stack,
    // not a count of pushes. Counting was enough while every constant
    // instruction pushed one value and popped none, but extended-const adds
    // instructions that pop two and push one, and their operand types have to
    // be checked as well as their number.
    var stack: std.ArrayListUnmanaged(StackType) = .empty;
    defer stack.deinit(gpa(m));

    while (pos < bytes.len) {
        const opcode = bytes[pos];
        pos += 1;

        switch (opcode) {
            0x41 => { // i32.const
                _ = readS32(bytes, &pos);
                try push(m, &stack, StackType.known(.i32));
            },
            0x42 => { // i64.const
                _ = readS64(bytes, &pos);
                try push(m, &stack, StackType.known(.i64));
            },
            0x43 => { // f32.const
                pos += 4;
                try push(m, &stack, StackType.known(.f32));
            },
            0x44 => { // f64.const
                pos += 8;
                try push(m, &stack, StackType.known(.f64));
            },
            // i32.add, i32.sub, i32.mul, i64.add, i64.sub, i64.mul. These are
            // the whole of extended-const: the other integer operators, and
            // every float one, stay non-constant.
            0x6a, 0x6b, 0x6c, 0x7c, 0x7d, 0x7e => {
                if (!features.extended_const) return error.ConstantExprRequired;
                const vt: ValTypeOrUnknown = if (opcode <= 0x6c) .i32 else .i64;
                try popExpecting(m, &stack, vt);
                try popExpecting(m, &stack, vt);
                try push(m, &stack, StackType.known(vt));
            },
            0xd0 => { // ref.null
                const t = readHeapStackType(m, bytes, &pos, true) orelse return error.InvalidTypeIndex;
                try push(m, &stack, t);
            },
            0xd2 => { // ref.func
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                const type_idx = m.funcs.items[idx].decl.type_var.index;
                try push(m, &stack, if (type_idx != types.invalid_index and type_idx < m.module_types.items.len)
                    StackType.fromRefType(types.RefType.concrete(false, type_idx))
                else
                    StackType.known(.ref_func));
            },
            0x23 => { // global.get
                const idx = readU32(bytes, &pos);
                // In a global init only globals before this one are in scope;
                // elsewhere any global is.
                const limit = global_limit orelse m.globals.items.len;
                if (idx >= limit or idx >= m.globals.items.len)
                    return error.InvalidGlobalIndex;
                // A constant expression may only read an immutable global.
                // Reading one that is defined here rather than imported is
                // what the GC proposal relaxed; before it, only imports were
                // in reach.
                if (!m.globals.items[idx].is_import and !features.gc)
                    return error.ConstantExprRequired;
                if (m.globals.items[idx].type.mutability == .mutable)
                    return error.ConstantExprRequired;
                try push(m, &stack, StackType.fromValTypeAndIndex(
                    m.globals.items[idx].type.val_type,
                    m.globals.items[idx].type_idx,
                ));
            },
            0xfd => { // SIMD prefix; v128.const is the only constant form
                const sub = readU32(bytes, &pos);
                if (sub != 0x0c) return error.ConstantExprRequired;
                pos += 16;
                if (pos > bytes.len) return error.UnexpectedEnd;
                try push(m, &stack, StackType.known(.v128));
            },
            0x0b => break, // end
            else => {
                // Any other opcode is not allowed in constant expressions
                return error.ConstantExprRequired;
            },
        }
    }

    // Must leave exactly one value, which must suit the slot it initialises.
    if (stack.items.len != 1) return error.TypeMismatch;
    if (!stack.items[0].isSubtypeOf(m, expected)) return error.TypeMismatch;
}

fn push(m: *const Mod.Module, stack: *std.ArrayListUnmanaged(StackType), t: StackType) Error!void {
    stack.append(gpa(m), t) catch return error.OutOfMemory;
}

/// Pop one operand off a constant expression's stack, requiring it to be of
/// the given type.
fn popExpecting(
    m: *const Mod.Module,
    stack: *std.ArrayListUnmanaged(StackType),
    vt: ValTypeOrUnknown,
) Error!void {
    const got = stack.pop() orelse return error.TypeMismatch;
    if (!got.isSubtypeOf(m, StackType.known(vt))) return error.TypeMismatch;
}

// ── Unrecognised opcode classification ──────────────────────────────────

/// The legacy exception-handling instructions, in opcode order.
///
/// These are declared in `Opcode.Code` and are real instructions, but they
/// belong to the *first* exception-handling proposal, which was replaced by
/// `try_table`/`throw_ref` before exception handling was standardised. wabt
/// implements only the standardised form, so these are rejected as a matter
/// of policy rather than sitting on the backlog:
///
///   * The reference implementation agrees. `wasm-tools` gates them behind an
///     explicit `legacy-exceptions` feature that is off by default and is not
///     part of `wasm3`, the standardised feature set.
///   * Nothing else in wabt speaks legacy EH. `text/Lexer.zig` has keywords
///     for `try_table`, `throw`, `throw_ref` and the four catch clauses, but
///     none for `try`, `delegate` or `rethrow`, so validating them would
///     create a validate-only path for modules wabt can neither author nor
///     print.
///   * `delegate` and `rethrow` need frame-relative label rewriting and a
///     handler stack that `try_table` does not, so supporting them costs
///     permanent complexity in this file for a superseded design.
///
/// If a real need appears (old LLVM/Emscripten output is the only likely
/// source), the natural home for an opt-in is a `legacy_exceptions` field on
/// `Feature.Set`, mirroring `wasm-tools`. See issue #356.
const legacy_eh_opcodes = [_]u8{
    0x06, // try
    0x07, // catch
    0x09, // rethrow
    0x18, // delegate
    0x19, // catch_all
};

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
    // Legacy exception handling is declined, not pending, so it gets its own
    // error rather than being lumped in with the backlog. Checked before the
    // `Opcode.Code` lookup, which would answer `UnsupportedOpcode` for all
    // five and lose the distinction.
    if (prefix == null and code <= 0xff and
        std.mem.indexOfScalar(u8, &legacy_eh_opcodes, @intCast(code)) != null)
    {
        return error.LegacyExceptionsUnsupported;
    }
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

// ── Index types ─────────────────────────────────────────────────────────

/// The type that indexes a memory: i64 under memory64, i32 otherwise.
///
/// Out-of-range indices answer i32; the caller reports the bad index itself,
/// and answering here would report it as a type error instead.
fn memIndexType(m: *const Mod.Module, idx: u32) ValTypeOrUnknown {
    if (idx >= m.memories.items.len) return .i32;
    return ValTypeOrUnknown.fromValType(m.memories.items[idx].type.limits.indexType());
}

/// The type that indexes a table: i64 under table64, i32 otherwise.
fn tableIndexType(m: *const Mod.Module, idx: u32) ValTypeOrUnknown {
    if (idx >= m.tables.items.len) return .i32;
    return ValTypeOrUnknown.fromValType(m.tables.items[idx].type.limits.indexType());
}

/// The narrower of two index types, which is what a copy between two
/// memories or two tables counts in: the length has to be a valid count in
/// both, so it is i64 only when neither side is 32-bit.
fn narrowerIndexType(a: ValTypeOrUnknown, b: ValTypeOrUnknown) ValTypeOrUnknown {
    return if (a == .i64 and b == .i64) .i64 else .i32;
}

/// The type a table's elements have, concrete type index included. Callers
/// bounds-check the index themselves; an absent table has no element type,
/// and answering `unknown` here would accept anything in its place.
fn tableElemStackType(m: *const Mod.Module, idx: u32) StackType {
    if (idx >= m.tables.items.len) return StackType.unknown();
    const table = m.tables.items[idx];
    return StackType.fromValTypeAndIndex(table.type.elem_type, table.type_idx);
}

// ── Memory alignment validation ─────────────────────────────────────────

/// Return the natural alignment (as log2) of a plain memory opcode, which is
/// both the largest alignment it may state and the one the text format means
/// when it states none. Null for opcodes that take no memarg.
pub fn maxAlignmentForOpcode(opcode: u8) ?u32 {
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

/// The function indices a module declares, which is what `ref.func` in a
/// function body is measured against.
const DeclaredFuncs = std.AutoHashMapUnmanaged(u32, void);

/// Collect the function indices the module declares.
///
/// The rule is stated exactly by the module validation judgement, which
/// builds the context's `refs` field as
///
///     x* = funcidx(global* mem* table* elem* export*)
///
/// -- the function indices occurring syntactically in the *defined* globals,
/// memories, tables, element segments and exports. So the declaration sites
/// are:
///
///   * every defined global's initializer (`ref.func` in a constant
///     expression),
///   * every defined table's initializer, which the function-references
///     proposal added and which is what issue #418 was about,
///   * every element segment: its offset expression, its element
///     expressions, and, in the other form, its plain function indices,
///   * every export of a function.
///
/// Memories carry no expressions, so they contribute nothing. Everything
/// else is deliberately *not* a declaration site: data segments and the
/// start function are absent from the list above, so `(start $f)` alone
/// leaves `$f` undeclared -- wasm-tools 1.250.0 agrees -- and so are
/// imports, tags, types and the code of other functions.
fn collectDeclaredFuncs(m: *const Mod.Module, declared: *DeclaredFuncs) Error!void {
    // An imported global or table has no initializer of its own, and the
    // rule reads the defined ones; skipping the imports says so rather than
    // relying on their byte slices being empty.
    for (m.globals.items) |global| {
        if (global.is_import) continue;
        try declareFuncsInExprs(m, global.init_expr_bytes, declared);
    }
    for (m.tables.items) |table| {
        if (table.is_import) continue;
        try declareFuncsInExprs(m, table.init_expr_bytes, declared);
    }
    for (m.elem_segments.items) |seg| {
        try declareFuncsInExprs(m, seg.offset_expr_bytes, declared);
        if (seg.elem_expr_count > 0 or seg.elem_expr_bytes.len > 0) {
            // Walk the expressions rather than the indices shadowing them:
            // the shadow cannot represent `ref.null` and so records it as
            // `maxInt(u32)`, which would declare a function that cannot
            // exist. `checkElemSegments` picks the same form the same way.
            try declareFuncsInExprs(m, seg.elem_expr_bytes, declared);
        } else {
            for (seg.elem_var_indices.items) |v| try declareFunc(m, declared, v.index);
        }
    }
    for (m.exports.items) |exp| {
        if (exp.kind == .func) try declareFunc(m, declared, exp.var_.index);
    }
}

/// Record every function index `ref.func` names in a run of constant
/// expressions.
///
/// One buffer holds either a single expression -- a global or table
/// initializer, an element segment's offset -- or several laid end to end,
/// as a segment's element expressions are. Both are read the same way: an
/// `end` is just another instruction, separating the expressions of a run
/// and terminating the last, and the walk steps over whole instructions so
/// that an index encoded as `0x0b` is not mistaken for one.
///
/// The walk is total. Every byte is decoded, and a buffer that does not
/// decode is reported rather than abandoned part-read: a scan that gives up
/// silently would drop the declarations after the byte it stopped on, which
/// is the shape of bug this collection has had twice.
fn declareFuncsInExprs(m: *const Mod.Module, bytes: []const u8, declared: *DeclaredFuncs) Error!void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const before = pos;
        const decoded = instr.decode(bytes, &pos) catch |err| return switch (err) {
            error.TruncatedBody => error.UnexpectedEnd,
            error.UnsupportedOpcode => error.UnsupportedOpcode,
        };
        if (decoded.prefix == 0 and decoded.code == 0xd2) { // ref.func
            const r = leb128.readU32Leb128(bytes[pos..]) catch return error.UnexpectedEnd;
            try declareFunc(m, declared, r.value);
        }
        instr.skipImmediates(decoded.shape, bytes, &pos) catch |err| return switch (err) {
            error.TruncatedBody => error.UnexpectedEnd,
            error.UnsupportedOpcode => error.UnsupportedOpcode,
        };
        std.debug.assert(pos > before);
    }
}

/// Add one function index to the declaration set.
///
/// The index is recorded as it was written, without a bounds check: the set
/// is the syntactic one the spec describes, and each site that names a
/// function -- an element segment, an export, a constant expression -- has
/// its own check that the name exists, as does `ref.func` in a body. A
/// failure to record is a real failure and is reported: quietly dropping an
/// entry would reject a valid `ref.func` later.
fn declareFunc(m: *const Mod.Module, declared: *DeclaredFuncs, index: u32) Error!void {
    declared.put(gpa(m), index, {}) catch return error.OutOfMemory;
}

fn checkFunctionBodies(m: *const Mod.Module) Error!void {
    var declared: DeclaredFuncs = .{};
    defer declared.deinit(gpa(m));
    try collectDeclaredFuncs(m, &declared);

    for (m.funcs.items) |func| {
        if (func.is_import) continue;
        if (func.code_bytes.len == 0) continue;
        try checkOneBody(m, &func, &declared);
    }
}

const TypeSeq = struct {
    vts: []const types.ValType = &.{},
    type_idxs: []const u32 = &.{},

    fn at(self: TypeSeq, idx: usize) StackType {
        return StackType.fromValTypeAndIndex(self.vts[idx], typeIndexAt(self.type_idxs, idx));
    }

    fn len(self: TypeSeq) usize {
        return self.vts.len;
    }
};

fn funcParams(ft: Mod.FuncSignature) TypeSeq {
    return .{ .vts = ft.params, .type_idxs = ft.param_type_idxs };
}

fn funcResults(ft: Mod.FuncSignature) TypeSeq {
    return .{ .vts = ft.results, .type_idxs = ft.result_type_idxs };
}

/// The types a `throw` of this tag pops. The authoritative signature is the
/// type section entry: `Tag.@"type".sig` carries the value types but neither
/// the reader nor the parser fills in the concrete type indices beside them,
/// so a tag taking a `(ref $t)` is only resolved correctly through
/// `type_idx`. `checkTags` has already established that the index, when set,
/// names a function type.
fn tagParams(m: *const Mod.Module, tag: Mod.Tag) TypeSeq {
    if (tag.type_idx != std.math.maxInt(u32) and tag.type_idx < m.module_types.items.len) {
        switch (m.module_types.items[tag.type_idx]) {
            .func_type => |ft| return funcParams(ft),
            else => {},
        }
    }
    return .{ .vts = tag.@"type".sig.params, .type_idxs = tag.@"type".sig.param_type_idxs };
}

fn typeSeqEql(a: TypeSeq, b: TypeSeq) bool {
    if (a.len() != b.len()) return false;
    for (a.vts, 0..) |_, i| {
        const at = a.at(i);
        const bt = b.at(i);
        if (at.vt != bt.vt or at.type_idx != bt.type_idx) return false;
    }
    return true;
}

/// Resolve the signature (params, results) for a function.
fn resolveSig(m: *const Mod.Module, decl: Mod.FuncDeclaration) struct { params: TypeSeq, results: TypeSeq } {
    if (decl.type_var != .index) return .{ .params = .{}, .results = .{} };
    const ti = decl.type_var.index;
    if (ti == types.invalid_index or ti >= m.module_types.items.len) return .{ .params = .{}, .results = .{} };
    return switch (m.module_types.items[ti]) {
        .func_type => |ft| .{
            .params = .{ .vts = ft.params, .type_idxs = ft.param_type_idxs },
            .results = .{ .vts = ft.results, .type_idxs = ft.result_type_idxs },
        },
        else => .{ .params = .{}, .results = .{} },
    };
}

const ValStack = std.ArrayListUnmanaged(StackType);

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
    eqref = @intFromEnum(types.ValType.eqref),
    i31ref = @intFromEnum(types.ValType.i31ref),
    structref = @intFromEnum(types.ValType.structref),
    arrayref = @intFromEnum(types.ValType.arrayref),
    exnref = @intFromEnum(types.ValType.exnref),
    nullfuncref = @intFromEnum(types.ValType.nullfuncref),
    nullexternref = @intFromEnum(types.ValType.nullexternref),
    nullref = @intFromEnum(types.ValType.nullref),
    nullexnref = @intFromEnum(types.ValType.nullexnref),
    ref_func = @intFromEnum(types.ValType.ref_func),
    ref_extern = @intFromEnum(types.ValType.ref_extern),
    ref_any = @intFromEnum(types.ValType.ref_any),
    ref_eq = @intFromEnum(types.ValType.ref_eq),
    ref_i31 = @intFromEnum(types.ValType.ref_i31),
    ref_struct = @intFromEnum(types.ValType.ref_struct),
    ref_array = @intFromEnum(types.ValType.ref_array),
    ref_none = @intFromEnum(types.ValType.ref_none),
    ref_nofunc = @intFromEnum(types.ValType.ref_nofunc),
    ref_noextern = @intFromEnum(types.ValType.ref_noextern),
    ref_exn = @intFromEnum(types.ValType.ref_exn),
    ref_noexn = @intFromEnum(types.ValType.ref_noexn),
    concrete_ref = @intFromEnum(types.ValType.concrete_ref),
    concrete_ref_null = @intFromEnum(types.ValType.concrete_ref_null),
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
            .eqref => .eqref,
            .i31ref => .i31ref,
            .structref => .structref,
            .arrayref => .arrayref,
            .exnref => .exnref,
            .nullfuncref => .nullfuncref,
            .nullexternref => .nullexternref,
            .nullref => .nullref,
            .nullexnref => .nullexnref,
            .ref_func => .ref_func,
            .ref_extern => .ref_extern,
            .ref_any => .ref_any,
            .ref_eq => .ref_eq,
            .ref_i31 => .ref_i31,
            .ref_struct => .ref_struct,
            .ref_array => .ref_array,
            .ref_none => .ref_none,
            .ref_nofunc => .ref_nofunc,
            .ref_noextern => .ref_noextern,
            .ref_exn => .ref_exn,
            .ref_noexn => .ref_noexn,
            .concrete_ref => .concrete_ref,
            .concrete_ref_null => .concrete_ref_null,
            else => .unknown,
        };
    }

    fn toValType(self: ValTypeOrUnknown) ?types.ValType {
        if (self == .unknown) return null;
        return @enumFromInt(@intFromEnum(self));
    }

    fn asRefType(self: ValTypeOrUnknown) ?types.RefType {
        const vt = self.toValType() orelse return null;
        return types.RefType.fromValType(vt);
    }

    fn isRefType(self: ValTypeOrUnknown) bool {
        const vt = self.toValType() orelse return false;
        return vt.isRefType();
    }

    fn isNonNullableRef(self: ValTypeOrUnknown) bool {
        const ref_type = self.asRefType() orelse return false;
        return !ref_type.nullable;
    }

    fn heapSubtypeOf(self: types.AbstractHeapType, other: types.AbstractHeapType) bool {
        if (self == other) return true;
        return switch (self) {
            .eq => other == .any,
            .i31, .struct_, .array => other == .eq or other == .any,
            .none => switch (other) {
                .any, .eq, .i31, .struct_, .array => true,
                else => false,
            },
            .nofunc => other == .func,
            .noextern => other == .extern_,
            .noexn => other == .exn,
            else => false,
        };
    }

    /// Check abstract-only subtyping for legacy tests and non-indexed callers.
    fn isSubtypeOf(self: ValTypeOrUnknown, other: ValTypeOrUnknown) bool {
        return StackType.known(self).isSubtypeOf(null, StackType.known(other));
    }
};

const StackType = struct {
    vt: ValTypeOrUnknown,
    type_idx: u32 = types.invalid_index,

    fn known(vt: ValTypeOrUnknown) StackType {
        return .{ .vt = vt };
    }

    fn unknown() StackType {
        return .{ .vt = .unknown };
    }

    fn fromValType(vt: types.ValType) StackType {
        return fromValTypeAndIndex(vt, types.invalid_index);
    }

    fn fromValTypeAndIndex(vt: types.ValType, type_idx: u32) StackType {
        const ref_type = types.RefType.fromValTypeAndIndex(vt, type_idx) orelse
            return .{ .vt = ValTypeOrUnknown.fromValType(vt) };
        return fromRefType(ref_type);
    }

    fn fromRefType(ref_type: types.RefType) StackType {
        const vt = ValTypeOrUnknown.fromValType(ref_type.toValType());
        const type_idx = switch (ref_type.heap) {
            .abstract => types.invalid_index,
            .concrete => |idx| idx,
        };
        return .{ .vt = vt, .type_idx = type_idx };
    }

    fn toValType(self: StackType) ?types.ValType {
        return self.vt.toValType();
    }

    fn asRefType(self: StackType) ?types.RefType {
        const vt = self.toValType() orelse return null;
        return types.RefType.fromValTypeAndIndex(vt, self.type_idx);
    }

    fn isRefType(self: StackType) bool {
        const vt = self.toValType() orelse return false;
        return vt.isRefType();
    }

    fn isNonNullableRef(self: StackType) bool {
        const ref_type = self.asRefType() orelse return false;
        return !ref_type.nullable;
    }

    fn isSubtypeOf(self: StackType, maybe_m: ?*const Mod.Module, other: StackType) bool {
        if (self.vt == .unknown or other.vt == .unknown) return true;
        if (self.vt == other.vt and self.type_idx == other.type_idx) return true;
        const self_ref = self.asRefType() orelse return false;
        const other_ref = other.asRefType() orelse return false;
        if (self_ref.nullable and !other_ref.nullable) return false;
        return refSubtypeOf(maybe_m, self_ref, other_ref, 0);
    }
};

const CtrlFrame = struct {
    opcode: u8, // 0x02=block, 0x03=loop, 0x04=if
    start_types: TypeSeq,
    end_types: TypeSeq,
    height: usize,
    unreachable_flag: bool,
    else_seen: bool,
    // Local initialization state at frame entry (for conservative merge at join points)
    saved_init: [4]u64 = .{ 0, 0, 0, 0 },
};

fn typeIndexAt(type_idxs: []const u32, idx: usize) u32 {
    return if (idx < type_idxs.len) type_idxs[idx] else types.invalid_index;
}

/// A struct field or array element type: any value type, plus the packed
/// types, which are legal in this position only.
fn isStorageType(vt: types.ValType) bool {
    return vt.isNumType() or vt.isRefType() or vt.isPackedType();
}

fn checkConcreteTypeIndex(m: *const Mod.Module, vt: types.ValType, type_idx: u32) bool {
    if (vt != .concrete_ref and vt != .concrete_ref_null) return true;
    return type_idx != types.invalid_index and type_idx < m.module_types.items.len;
}

fn typeEntryKind(entry: Mod.TypeEntry) Mod.TypeMeta.Kind {
    return switch (entry) {
        .func_type => .func,
        .struct_type => .struct_,
        .array_type => .array,
    };
}

fn concreteKind(m: *const Mod.Module, idx: u32) ?Mod.TypeMeta.Kind {
    if (idx >= m.module_types.items.len) return null;
    if (idx < m.type_meta.items.len) return m.type_meta.items[idx].kind;
    return typeEntryKind(m.module_types.items[idx]);
}

fn equivalentConcreteTypes(m: *const Mod.Module, a: u32, b: u32) bool {
    if (a == b) return true;
    if (a >= m.module_types.items.len or b >= m.module_types.items.len) return false;
    if (a < m.type_meta.items.len and b < m.type_meta.items.len) {
        const am = m.type_meta.items[a];
        const bm = m.type_meta.items[b];
        return am.canonical_group != std.math.maxInt(u32) and
            am.canonical_group == bm.canonical_group and
            am.rec_position == bm.rec_position;
    }
    return a == b;
}

fn declaredParentSubtype(m: *const Mod.Module, actual_idx: u32, expected_idx: u32) bool {
    if (actual_idx >= m.type_meta.items.len) return false;
    var cur = actual_idx;
    var steps: usize = 0;
    while (steps < m.type_meta.items.len) : (steps += 1) {
        const parent = m.type_meta.items[cur].parent;
        if (parent == std.math.maxInt(u32) or parent >= m.type_meta.items.len) return false;
        if (equivalentConcreteTypes(m, parent, expected_idx)) return true;
        cur = parent;
    }
    return false;
}

fn concreteSubtypeOf(m: *const Mod.Module, actual_idx: u32, expected_idx: u32, depth: usize) bool {
    if (equivalentConcreteTypes(m, actual_idx, expected_idx)) return true;
    if (declaredParentSubtype(m, actual_idx, expected_idx)) return true;
    return structuralConcreteSubtype(m, actual_idx, expected_idx, depth + 1);
}

fn refSubtypeOf(maybe_m: ?*const Mod.Module, actual: types.RefType, expected: types.RefType, depth: usize) bool {
    return switch (actual.heap) {
        .abstract => |actual_heap| switch (expected.heap) {
            .abstract => |expected_heap| ValTypeOrUnknown.heapSubtypeOf(actual_heap, expected_heap),
            .concrete => |expected_idx| blk: {
                const m = maybe_m orelse break :blk false;
                const expected_kind = concreteKind(m, expected_idx) orelse break :blk false;
                break :blk switch (actual_heap) {
                    .nofunc => expected_kind == .func,
                    .none => expected_kind == .struct_ or expected_kind == .array,
                    else => false,
                };
            },
        },
        .concrete => |actual_idx| switch (expected.heap) {
            .abstract => |expected_heap| blk: {
                const m = maybe_m orelse break :blk false;
                const actual_kind = concreteKind(m, actual_idx) orelse break :blk false;
                break :blk switch (actual_kind) {
                    .func => expected_heap == .func,
                    .struct_ => expected_heap == .struct_ or expected_heap == .eq or expected_heap == .any,
                    .array => expected_heap == .array or expected_heap == .eq or expected_heap == .any,
                };
            },
            .concrete => |expected_idx| blk: {
                const m = maybe_m orelse break :blk false;
                break :blk concreteSubtypeOf(m, actual_idx, expected_idx, depth + 1);
            },
        },
    };
}

fn fieldStackType(field: Mod.TypeEntry.StructType.Field) StackType {
    return StackType.fromValTypeAndIndex(field.@"type", field.type_idx);
}

fn stackSubtype(m: *const Mod.Module, actual: StackType, expected: StackType, depth: usize) bool {
    if (actual.vt == .unknown or expected.vt == .unknown) return true;
    if (actual.vt == expected.vt and actual.type_idx == expected.type_idx) return true;
    if (depth > m.module_types.items.len + 16) return false;
    const actual_ref = actual.asRefType() orelse return false;
    const expected_ref = expected.asRefType() orelse return false;
    if (actual_ref.nullable and !expected_ref.nullable) return false;
    return refSubtypeOf(m, actual_ref, expected_ref, depth + 1);
}

fn stackEquivalent(m: *const Mod.Module, a: StackType, b: StackType, depth: usize) bool {
    return stackSubtype(m, a, b, depth + 1) and stackSubtype(m, b, a, depth + 1);
}

fn structuralConcreteSubtype(m: *const Mod.Module, actual_idx: u32, expected_idx: u32, depth: usize) bool {
    if (actual_idx >= m.module_types.items.len or expected_idx >= m.module_types.items.len) return false;
    if (depth > m.module_types.items.len + 16) return false;
    if (concreteKind(m, actual_idx) != concreteKind(m, expected_idx)) return false;
    return switch (m.module_types.items[actual_idx]) {
        .func_type => |actual_ft| switch (m.module_types.items[expected_idx]) {
            .func_type => |expected_ft| {
                if (actual_ft.params.len != expected_ft.params.len or
                    actual_ft.results.len != expected_ft.results.len)
                    return false;
                for (actual_ft.params, 0..) |actual_param, i| {
                    const expected_param = StackType.fromValTypeAndIndex(expected_ft.params[i], typeIndexAt(expected_ft.param_type_idxs, i));
                    const actual_param_st = StackType.fromValTypeAndIndex(actual_param, typeIndexAt(actual_ft.param_type_idxs, i));
                    if (!stackSubtype(m, expected_param, actual_param_st, depth + 1)) return false;
                }
                for (actual_ft.results, 0..) |actual_result, i| {
                    const actual_result_st = StackType.fromValTypeAndIndex(actual_result, typeIndexAt(actual_ft.result_type_idxs, i));
                    const expected_result = StackType.fromValTypeAndIndex(expected_ft.results[i], typeIndexAt(expected_ft.result_type_idxs, i));
                    if (!stackSubtype(m, actual_result_st, expected_result, depth + 1)) return false;
                }
                return true;
            },
            else => false,
        },
        .struct_type => |actual_st| switch (m.module_types.items[expected_idx]) {
            .struct_type => |expected_st| {
                if (actual_st.fields.items.len < expected_st.fields.items.len) return false;
                for (expected_st.fields.items, 0..) |expected_field, i| {
                    const actual_field = actual_st.fields.items[i];
                    if (actual_field.mutable != expected_field.mutable) return false;
                    const actual_type = fieldStackType(actual_field);
                    const expected_type = fieldStackType(expected_field);
                    if (actual_field.mutable) {
                        if (!stackEquivalent(m, actual_type, expected_type, depth + 1)) return false;
                    } else if (!stackSubtype(m, actual_type, expected_type, depth + 1)) return false;
                }
                return true;
            },
            else => false,
        },
        .array_type => |actual_at| switch (m.module_types.items[expected_idx]) {
            .array_type => |expected_at| {
                if (actual_at.field.mutable != expected_at.field.mutable) return false;
                const actual_type = fieldStackType(actual_at.field);
                const expected_type = fieldStackType(expected_at.field);
                if (actual_at.field.mutable)
                    return stackEquivalent(m, actual_type, expected_type, depth + 1);
                return stackSubtype(m, actual_type, expected_type, depth + 1);
            },
            else => false,
        },
    };
}

fn checkOneBody(m: *const Mod.Module, func: *const Mod.Func, declared_funcs: *const DeclaredFuncs) Error!void {
    const sig = resolveSig(m, func.decl);
    const num_params: u32 = @intCast(sig.params.len());
    const num_locals: u32 = num_params + @as(u32, @intCast(func.local_types.items.len));

    // Build local types array: params ++ declared locals
    var local_types_buf: [256]StackType = undefined;
    var local_types: []StackType = &.{};
    if (num_locals <= 256) {
        for (sig.params.vts, 0..) |_, i| local_types_buf[i] = sig.params.at(i);
        for (func.local_types.items, 0..) |lt, i| {
            local_types_buf[num_params + i] =
                StackType.fromValTypeAndIndex(lt, typeIndexAt(func.local_type_idxs.items, i));
        }
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
    // Backing store for the block signatures that cannot borrow their type
    // sequence from the type section -- `(ref null ht)` / `(ref ht)`. A
    // control frame outlives the `readBlockType` call that filled it, so the
    // slices must live as long as the body; nothing is allocated unless such
    // a signature actually appears.
    var block_types = std.heap.ArenaAllocator.init(gpa(m));
    defer block_types.deinit();

    // Push the function frame
    ctrl_stack.append(gpa(m), .{
        .opcode = 0x02,
        .start_types = .{},
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
                const bt = try readBlockType(m, bytes, &pos, block_types.allocator());
                if (bt.params.len() > 0)
                    try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x02, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x03 => { // loop
                const bt = try readBlockType(m, bytes, &pos, block_types.allocator());
                if (bt.params.len() > 0)
                    try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x03, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x04 => { // if
                const bt = try readBlockType(m, bytes, &pos, block_types.allocator());
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32));
                if (bt.params.len() > 0)
                    try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x04, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                // Save init state at if entry for conservative merge
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x05 => { // else
                if (ctrl_stack.items.len == 0) return error.TypeMismatch;
                const frame = &ctrl_stack.items[ctrl_stack.items.len - 1];
                if (frame.opcode != 0x04) return error.TypeMismatch;
                try popVals(m, &val_stack, frame, frame.end_types);
                if (val_stack.items.len != frame.height) return error.TypeMismatch;
                frame.unreachable_flag = false;
                frame.else_seen = true;
                // Restore init state from if entry (else branch didn't execute then)
                unpackInitState(frame.saved_init, local_inited);
                pushVals(&val_stack, frame.start_types, gpa(m)) catch return error.OutOfMemory;
            },
            0x08 => { // throw
                const tag_idx = readU32(bytes, &pos);
                if (tag_idx >= m.tags.items.len) return error.InvalidTagIndex;
                const params = tagParams(m, m.tags.items[tag_idx]);
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], params);
                // `throw` transfers control to a handler, so nothing after it
                // in this block is reached. Like `br`, it leaves the rest of
                // the block in the polymorphic stack-typing regime.
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x0a => { // throw_ref
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.exnref));
                // Rethrowing transfers control to a handler, so like `throw`
                // nothing after it in this block is reached.
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x0b => { // end
                if (ctrl_stack.items.len == 0) break;
                const frame = ctrl_stack.items[ctrl_stack.items.len - 1];
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], frame.end_types);
                if (val_stack.items.len != frame.height) return error.TypeMismatch;
                // If block was an if without else, and it has results, that's a type error
                if (frame.opcode == 0x04 and !frame.else_seen and frame.end_types.len() > 0) {
                    // Check if start_types match end_types (if with no else must have matching in/out)
                    if (!typeSeqEql(frame.start_types, frame.end_types))
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
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], label_types);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x0d => { // br_if
                const depth = readU32(bytes, &pos);
                if (depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32));
                const target = ctrl_stack.items[ctrl_stack.items.len - 1 - depth];
                const lt = labelTypes(&target);
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], lt);
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
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32));

                const default_target = ctrl_stack.items[ctrl_stack.items.len - 1 - default];
                const default_lt = labelTypes(&default_target);

                // Verify all targets have consistent label types with the default
                var check_pos = targets_start;
                for (0..count) |_| {
                    const d = readU32(bytes, &check_pos);
                    const target = ctrl_stack.items[ctrl_stack.items.len - 1 - d];
                    const lt = labelTypes(&target);
                    if (lt.len() != default_lt.len()) return error.TypeMismatch;
                    for (lt.vts, 0..) |_, i| {
                        const a = lt.at(i);
                        const b = default_lt.at(i);
                        if (a.vt != b.vt or a.type_idx != b.type_idx) return error.TypeMismatch;
                    }
                }

                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], default_lt);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x0f => { // return
                if (ctrl_stack.items.len == 0) return error.TypeMismatch;
                const lt = ctrl_stack.items[0].end_types;
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], lt);
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x10 => { // call
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                const callee_sig = resolveSig(m, m.funcs.items[idx].decl);
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], callee_sig.params);
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
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // table index operand
                const ft = switch (m.module_types.items[type_idx]) {
                    .func_type => |ft| ft,
                    else => Mod.FuncSignature{},
                };
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], funcParams(ft));
                pushVals(&val_stack, funcResults(ft), gpa(m)) catch return error.OutOfMemory;
            },
            0x12 => { // return_call
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                const callee_sig = resolveSig(m, m.funcs.items[idx].decl);
                try checkTailCallResults(&ctrl_stack, callee_sig.results);
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], callee_sig.params);
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
                try checkTailCallResults(&ctrl_stack, funcResults(ft));
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // table index operand
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], funcParams(ft));
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x14 => { // call_ref
                const type_idx = readU32(bytes, &pos);
                if (type_idx >= m.module_types.items.len) return error.InvalidTypeIndex;
                const ft = switch (m.module_types.items[type_idx]) {
                    .func_type => |ft| ft,
                    else => return error.TypeMismatch,
                };
                try popExpect(m, &val_stack, &ctrl_stack, StackType.fromRefType(types.RefType.concrete(true, type_idx)));
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], funcParams(ft));
                pushVals(&val_stack, funcResults(ft), gpa(m)) catch return error.OutOfMemory;
            },
            0x15 => { // return_call_ref
                const type_idx = readU32(bytes, &pos);
                if (type_idx >= m.module_types.items.len) return error.InvalidTypeIndex;
                const ft = switch (m.module_types.items[type_idx]) {
                    .func_type => |ft| ft,
                    else => return error.TypeMismatch,
                };
                try checkTailCallResults(&ctrl_stack, funcResults(ft));
                try popExpect(m, &val_stack, &ctrl_stack, StackType.fromRefType(types.RefType.concrete(true, type_idx)));
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], funcParams(ft));
                setUnreachable(&val_stack, &ctrl_stack);
            },
            0x1f => { // try_table
                const bt = try readBlockType(m, bytes, &pos, block_types.allocator());
                const clause_count = readU32(bytes, &pos);
                // The catch clauses are checked against the *enclosing*
                // label stack. `try_table`'s own frame is not pushed until
                // afterwards, because a clause's label index is resolved in
                // the context surrounding the instruction, not inside it --
                // `(block $l (try_table (catch_all $l) ...))` encodes depth
                // 0, not 1.
                var ci: u32 = 0;
                while (ci < clause_count) : (ci += 1) {
                    if (pos >= bytes.len) return error.UnexpectedEnd;
                    const kind = bytes[pos];
                    pos += 1;
                    // catch and catch_ref name a tag; catch_all and
                    // catch_all_ref do not.
                    const params: TypeSeq = switch (kind) {
                        0x00, 0x01 => blk: {
                            const tag_idx = readU32(bytes, &pos);
                            if (tag_idx >= m.tags.items.len) return error.InvalidTagIndex;
                            break :blk tagParams(m, m.tags.items[tag_idx]);
                        },
                        0x02, 0x03 => TypeSeq{},
                        else => return error.InvalidCatchKind,
                    };
                    // The _ref variants additionally hand the label the
                    // caught exception itself.
                    const with_exnref = kind == 0x01 or kind == 0x03;
                    const depth = readU32(bytes, &pos);
                    if (depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                    const target = ctrl_stack.items[ctrl_stack.items.len - 1 - depth];
                    try checkCatchLabel(m, &target, params, with_exnref);
                }
                // From here on `try_table` behaves exactly like `block`.
                if (bt.params.len() > 0)
                    try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], bt.params);
                pushCtrl(&ctrl_stack, &val_stack, 0x1f, bt.params, bt.results, gpa(m)) catch return error.OutOfMemory;
                ctrl_stack.items[ctrl_stack.items.len - 1].saved_init = packInitState(local_inited);
                pushVals(&val_stack, bt.params, gpa(m)) catch return error.OutOfMemory;
            },
            0x1a => { // drop
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
            },
            0x1b => { // select
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32));
                const t1 = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                const t2 = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                if (t1.vt != .unknown and t2.vt != .unknown and (t1.vt != t2.vt or t1.type_idx != t2.type_idx))
                    return error.TypeMismatch;
                const result = if (t1.vt != .unknown) t1 else t2;
                // Untyped select only works with numeric/vector types, not ref types
                if (result.isRefType()) return error.TypeMismatch;
                val_stack.append(gpa(m), result) catch return error.OutOfMemory;
            },
            0x1c => { // select t
                const count = readU32(bytes, &pos);
                for (0..count) |_| _ = readU32(bytes, &pos); // skip types
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32));
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                val_stack.append(gpa(m), StackType.unknown()) catch return error.OutOfMemory;
            },
            0x20 => { // local.get
                const idx = readU32(bytes, &pos);
                if (idx >= num_locals) return error.InvalidLocalIndex;
                const lt = if (idx < local_types.len) local_types[idx] else StackType.unknown();
                // Non-nullable ref locals must be initialized before use
                if (idx < local_inited.len and !local_inited[idx]) return error.TypeMismatch;
                val_stack.append(gpa(m), lt) catch return error.OutOfMemory;
            },
            0x21 => { // local.set
                const idx = readU32(bytes, &pos);
                if (idx >= num_locals) return error.InvalidLocalIndex;
                const lt = if (idx < local_types.len) local_types[idx] else StackType.unknown();
                try popExpect(m, &val_stack, &ctrl_stack, lt);
                if (idx < local_inited.len) local_inited[idx] = true;
            },
            0x22 => { // local.tee
                const idx = readU32(bytes, &pos);
                if (idx >= num_locals) return error.InvalidLocalIndex;
                const lt = if (idx < local_types.len) local_types[idx] else StackType.unknown();
                try popExpect(m, &val_stack, &ctrl_stack, lt);
                val_stack.append(gpa(m), lt) catch return error.OutOfMemory;
                if (idx < local_inited.len) local_inited[idx] = true;
            },
            0x23 => { // global.get
                const idx = readU32(bytes, &pos);
                if (idx >= m.globals.items.len) return error.InvalidGlobalIndex;
                const gt = StackType.fromValTypeAndIndex(m.globals.items[idx].type.val_type, m.globals.items[idx].type_idx);
                val_stack.append(gpa(m), gt) catch return error.OutOfMemory;
            },
            0x24 => { // global.set
                const idx = readU32(bytes, &pos);
                if (idx >= m.globals.items.len) return error.InvalidGlobalIndex;
                if (m.globals.items[idx].type.mutability != .mutable) return error.ImmutableGlobal;
                const gt = StackType.fromValTypeAndIndex(m.globals.items[idx].type.val_type, m.globals.items[idx].type_idx);
                try popExpect(m, &val_stack, &ctrl_stack, gt);
            },
            0x25 => { // table.get
                const idx = readU32(bytes, &pos);
                if (idx >= m.tables.items.len) return error.InvalidTableIndex;
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(tableIndexType(m, idx)));
                val_stack.append(gpa(m), StackType.fromValTypeAndIndex(m.tables.items[idx].type.elem_type, m.tables.items[idx].type_idx)) catch return error.OutOfMemory;
            },
            0x26 => { // table.set
                const idx = readU32(bytes, &pos);
                if (idx >= m.tables.items.len) return error.InvalidTableIndex;
                const et = StackType.fromValTypeAndIndex(m.tables.items[idx].type.elem_type, m.tables.items[idx].type_idx);
                try popExpect(m, &val_stack, &ctrl_stack, et);
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(tableIndexType(m, idx)));
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
                const mem_idx = readU32(bytes, &pos);
                if (m.memories.items.len == 0 or mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
                val_stack.append(gpa(m), StackType.known(memIndexType(m, mem_idx))) catch return error.OutOfMemory;
            },
            0x40 => { // memory.grow
                const mem_idx = readU32(bytes, &pos);
                if (m.memories.items.len == 0 or mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
                const it = memIndexType(m, mem_idx);
                try popExpect(m, &val_stack, &ctrl_stack, StackType.known(it));
                val_stack.append(gpa(m), StackType.known(it)) catch return error.OutOfMemory;
            },
            0x41 => { // i32.const
                _ = readS32(bytes, &pos);
                val_stack.append(gpa(m), StackType.known(.i32)) catch return error.OutOfMemory;
            },
            0x42 => { // i64.const
                _ = readS64(bytes, &pos);
                val_stack.append(gpa(m), StackType.known(.i64)) catch return error.OutOfMemory;
            },
            0x43 => { // f32.const
                pos += 4;
                val_stack.append(gpa(m), StackType.known(.f32)) catch return error.OutOfMemory;
            },
            0x44 => { // f64.const
                pos += 8;
                val_stack.append(gpa(m), StackType.known(.f64)) catch return error.OutOfMemory;
            },
            // i32 comparison: unary
            0x45 => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i32 comparison: binary
            0x46...0x4f => { try checkBinary(m, &val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i64 comparison: unary
            0x50 => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .i32, gpa(m)); },
            // i64 comparison: binary
            0x51...0x5a => { try checkBinary(m, &val_stack, &ctrl_stack, .i64, .i32, gpa(m)); },
            // f32 comparison
            0x5b...0x60 => { try checkBinary(m, &val_stack, &ctrl_stack, .f32, .i32, gpa(m)); },
            // f64 comparison
            0x61...0x66 => { try checkBinary(m, &val_stack, &ctrl_stack, .f64, .i32, gpa(m)); },
            // i32 unary
            0x67...0x69 => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i32 binary
            0x6a...0x78 => { try checkBinary(m, &val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            // i64 unary
            0x79...0x7b => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .i64, gpa(m)); },
            // i64 binary
            0x7c...0x8a => { try checkBinary(m, &val_stack, &ctrl_stack, .i64, .i64, gpa(m)); },
            // f32 unary
            0x8b...0x91 => { try checkUnary(m, &val_stack, &ctrl_stack, .f32, .f32, gpa(m)); },
            // f32 binary
            0x92...0x98 => { try checkBinary(m, &val_stack, &ctrl_stack, .f32, .f32, gpa(m)); },
            // f64 unary
            0x99...0x9f => { try checkUnary(m, &val_stack, &ctrl_stack, .f64, .f64, gpa(m)); },
            // f64 binary
            0xa0...0xa6 => { try checkBinary(m, &val_stack, &ctrl_stack, .f64, .f64, gpa(m)); },
            // Conversions
            0xa7 => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .i32, gpa(m)); }, // i32.wrap_i64
            0xa8, 0xa9 => { try checkUnary(m, &val_stack, &ctrl_stack, .f32, .i32, gpa(m)); },
            0xaa, 0xab => { try checkUnary(m, &val_stack, &ctrl_stack, .f64, .i32, gpa(m)); },
            0xac, 0xad => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .i64, gpa(m)); },
            0xae, 0xaf => { try checkUnary(m, &val_stack, &ctrl_stack, .f32, .i64, gpa(m)); },
            0xb0, 0xb1 => { try checkUnary(m, &val_stack, &ctrl_stack, .f64, .i64, gpa(m)); },
            0xb2, 0xb3 => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .f32, gpa(m)); },
            0xb4, 0xb5 => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .f32, gpa(m)); },
            0xb6 => { try checkUnary(m, &val_stack, &ctrl_stack, .f64, .f32, gpa(m)); },
            0xb7, 0xb8 => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .f64, gpa(m)); },
            0xb9, 0xba => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .f64, gpa(m)); },
            0xbb => { try checkUnary(m, &val_stack, &ctrl_stack, .f32, .f64, gpa(m)); },
            0xbc => { try checkUnary(m, &val_stack, &ctrl_stack, .f32, .i32, gpa(m)); },
            0xbd => { try checkUnary(m, &val_stack, &ctrl_stack, .f64, .i64, gpa(m)); },
            0xbe => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .f32, gpa(m)); },
            0xbf => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .f64, gpa(m)); },
            // Sign extension
            0xc0, 0xc1 => { try checkUnary(m, &val_stack, &ctrl_stack, .i32, .i32, gpa(m)); },
            0xc2...0xc4 => { try checkUnary(m, &val_stack, &ctrl_stack, .i64, .i64, gpa(m)); },
            // Reference types
            0xd0 => { // ref.null
                const rt = readHeapStackType(m, bytes, &pos, true) orelse return error.InvalidTypeIndex;
                val_stack.append(gpa(m), rt) catch return error.OutOfMemory;
            },
            0xd1 => { // ref.is_null
                _ = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                val_stack.append(gpa(m), StackType.known(.i32)) catch return error.OutOfMemory;
            },
            0xd2 => { // ref.func
                const idx = readU32(bytes, &pos);
                if (idx >= m.funcs.items.len) return error.InvalidFuncIndex;
                if (!declared_funcs.contains(idx)) return error.InvalidFuncIndex;
                const type_idx = m.funcs.items[idx].decl.type_var.index;
                const rt = if (type_idx != types.invalid_index and type_idx < m.module_types.items.len)
                    StackType.fromRefType(types.RefType.concrete(false, type_idx))
                else
                    StackType.known(.ref_func);
                val_stack.append(gpa(m), rt) catch return error.OutOfMemory;
            },
            0xd3 => { // ref.eq
                const eqref = StackType.known(.eqref);
                try popExpect(m, &val_stack, &ctrl_stack, eqref);
                try popExpect(m, &val_stack, &ctrl_stack, eqref);
                val_stack.append(gpa(m), StackType.known(.i32)) catch return error.OutOfMemory;
            },
            0xd4 => { // ref.as_non_null
                const actual = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                const result = if (actual.vt == .unknown) StackType.unknown() else blk: {
                    const ref_type = actual.asRefType() orelse return error.TypeMismatch;
                    break :blk StackType.fromRefType(.{ .nullable = false, .heap = ref_type.heap });
                };
                val_stack.append(gpa(m), result) catch return error.OutOfMemory;
            },
            0xd5 => { // br_on_null
                const depth = readU32(bytes, &pos);
                if (depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                const actual = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                const fallthrough = if (actual.vt == .unknown) StackType.unknown() else blk: {
                    const ref_type = actual.asRefType() orelse return error.TypeMismatch;
                    break :blk StackType.fromRefType(.{ .nullable = false, .heap = ref_type.heap });
                };
                const target = ctrl_stack.items[ctrl_stack.items.len - 1 - depth];
                const lt = labelTypes(&target);
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], lt);
                pushVals(&val_stack, lt, gpa(m)) catch return error.OutOfMemory;
                val_stack.append(gpa(m), fallthrough) catch return error.OutOfMemory;
            },
            0xd6 => { // br_on_non_null
                const depth = readU32(bytes, &pos);
                if (depth >= ctrl_stack.items.len) return error.InvalidLabelIndex;
                const actual = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
                const branch_value = if (actual.vt == .unknown) StackType.unknown() else blk: {
                    const ref_type = actual.asRefType() orelse return error.TypeMismatch;
                    break :blk StackType.fromRefType(.{ .nullable = false, .heap = ref_type.heap });
                };
                const target = ctrl_stack.items[ctrl_stack.items.len - 1 - depth];
                const lt = labelTypes(&target);
                if (lt.len() == 0) return error.TypeMismatch;
                val_stack.append(gpa(m), branch_value) catch return error.OutOfMemory;
                try popVals(m, &val_stack, &ctrl_stack.items[ctrl_stack.items.len - 1], lt);
                for (0..lt.len() - 1) |i| {
                    val_stack.append(gpa(m), lt.at(i)) catch return error.OutOfMemory;
                }
            },
            // Prefixed opcodes
            0xfc => {
                const sub = readU32(bytes, &pos);
                switch (sub) {
                    0x00...0x07 => {
                        // Saturating float-to-int: 0-1 f32→i32, 2-3 f64→i32, 4-5 f32→i64, 6-7 f64→i64
                        const input: ValTypeOrUnknown = if (sub & 2 == 0) .f32 else .f64;
                        const output: ValTypeOrUnknown = if (sub < 4) .i32 else .i64;
                        try checkUnary(m, &val_stack, &ctrl_stack, input, output, gpa(m));
                    },
                    0x08 => { // memory.init
                        // The binary states the data segment first and the
                        // memory second; the text format states them the
                        // other way round.
                        const data_idx = readU32(bytes, &pos);
                        const mem_idx = readU32(bytes, &pos);
                        // Bounds first: `memIndexType` answers i32 for a
                        // memory that is not there, so checking it later
                        // would report a bad memory index as a type error
                        // instead. The memory is checked before the segment,
                        // which is the order the reference implementation
                        // reports the two in.
                        if (mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
                        if (!m.has_data_count) return error.InvalidDataIndex;
                        if (data_idx >= m.data_segments.items.len) return error.InvalidDataIndex;
                        // Length and source offset index the data segment,
                        // which is never 64-bit, and stay i32; only the
                        // destination indexes the memory and so follows its
                        // index type.
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // n
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // src
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(memIndexType(m, mem_idx))); // dst
                    },
                    0x09 => { // data.drop
                        if (!m.has_data_count) return error.InvalidDataIndex;
                        const idx = readU32(bytes, &pos);
                        if (idx >= m.data_segments.items.len) return error.InvalidDataIndex;
                    },
                    0x0a => { // memory.copy
                        const dst_mem = readU32(bytes, &pos);
                        const src_mem = readU32(bytes, &pos);
                        if (dst_mem >= m.memories.items.len) return error.InvalidMemoryIndex;
                        if (src_mem >= m.memories.items.len) return error.InvalidMemoryIndex;
                        const dst_it = memIndexType(m, dst_mem);
                        const src_it = memIndexType(m, src_mem);
                        // Each offset follows the memory it indexes, while
                        // the length is of the narrower of the two index
                        // types -- it has to fit in both memories, so a copy
                        // involving any 32-bit memory counts in i32. The
                        // length used to follow the destination alone, which
                        // rejected valid mixed-width copies.
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(narrowerIndexType(dst_it, src_it))); // n
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(src_it)); // src
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(dst_it)); // dst
                    },
                    0x0b => { // memory.fill
                        const mem_idx = readU32(bytes, &pos);
                        if (mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
                        const it = memIndexType(m, mem_idx);
                        // The destination and the length index the memory;
                        // the byte written is a value, not an index, so it
                        // stays i32 however wide the memory is.
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(it)); // n
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // val
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(it)); // dst
                    },
                    0x0c => { // table.init
                        // The binary states the element segment first and the
                        // table second; the text format states them the other
                        // way round.
                        const elem_idx = readU32(bytes, &pos);
                        const tbl_idx = readU32(bytes, &pos);
                        // Bounds first: `tableIndexType` answers i32 for a
                        // table that is not there, so checking it later would
                        // report a bad table index as a type error instead.
                        if (elem_idx >= m.elem_segments.items.len) return error.InvalidElemIndex;
                        if (tbl_idx >= m.tables.items.len) return error.InvalidTableIndex;
                        const seg = m.elem_segments.items[elem_idx];
                        // The elements are written into the table, so the
                        // segment's type must be a subtype of the table's.
                        // Any segment may be named, active ones included:
                        // instantiation drops them, which is a trap at run
                        // time rather than a validation error.
                        const seg_type = StackType.fromValTypeAndIndex(seg.elem_type, seg.elem_type_idx);
                        if (!seg_type.isSubtypeOf(m, tableElemStackType(m, tbl_idx)))
                            return error.TypeMismatch;
                        // Length and source offset index the element segment
                        // and stay i32; only the destination indexes the
                        // table and so follows its index type.
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // n
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(.i32)); // src
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(tableIndexType(m, tbl_idx))); // dst
                    },
                    0x0d => { // elem.drop
                        const idx = readU32(bytes, &pos);
                        if (idx >= m.elem_segments.items.len) return error.InvalidElemIndex;
                    },
                    0x0e => { // table.copy
                        const dst_idx = readU32(bytes, &pos);
                        const src_idx = readU32(bytes, &pos);
                        if (dst_idx >= m.tables.items.len) return error.InvalidTableIndex;
                        if (src_idx >= m.tables.items.len) return error.InvalidTableIndex;
                        // Elements move from the source table to the
                        // destination, so the source's type must be a subtype
                        // of the destination's, not merely equal to it.
                        if (!tableElemStackType(m, src_idx).isSubtypeOf(m, tableElemStackType(m, dst_idx)))
                            return error.TypeMismatch;
                        const dst_it = tableIndexType(m, dst_idx);
                        const src_it = tableIndexType(m, src_idx);
                        // Each offset follows the table it indexes, while the
                        // length is of the narrower of the two index types --
                        // it has to fit in both tables, so a copy involving
                        // any 32-bit table counts in i32.
                        const len_it = narrowerIndexType(dst_it, src_it);
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(len_it)); // n
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(src_it)); // src
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(dst_it)); // dst
                    },
                    0x0f => { // table.grow
                        const tbl_idx = readU32(bytes, &pos);
                        // Bounds first: `tableIndexType` answers i32 for a
                        // table that is not there, so checking it later would
                        // report a bad table index as a type error instead --
                        // and a missing table has no element type to check
                        // the value against at all.
                        if (tbl_idx >= m.tables.items.len) return error.InvalidTableIndex;
                        const it = tableIndexType(m, tbl_idx);
                        // The delta and the old size the instruction answers
                        // with both count the table's entries, so both follow
                        // its index type; between them is the value the new
                        // entries take, which is one of the table's elements.
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(it)); // n
                        try popExpect(m, &val_stack, &ctrl_stack, tableElemStackType(m, tbl_idx)); // init
                        val_stack.append(gpa(m), StackType.known(it)) catch return error.OutOfMemory;
                    },
                    0x10 => { // table.size
                        const tbl_idx = readU32(bytes, &pos);
                        if (tbl_idx >= m.tables.items.len) return error.InvalidTableIndex;
                        // The size counts the table's entries, so it is of
                        // the table's index type.
                        val_stack.append(gpa(m), StackType.known(tableIndexType(m, tbl_idx))) catch return error.OutOfMemory;
                    },
                    0x11 => { // table.fill
                        const tbl_idx = readU32(bytes, &pos);
                        if (tbl_idx >= m.tables.items.len) return error.InvalidTableIndex;
                        const it = tableIndexType(m, tbl_idx);
                        // The destination and the length index the table; the
                        // value written between them is one of its elements.
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(it)); // n
                        try popExpect(m, &val_stack, &ctrl_stack, tableElemStackType(m, tbl_idx)); // val
                        try popExpect(m, &val_stack, &ctrl_stack, StackType.known(it)); // dst
                    },
                    else => return classifyOpcode(Opcode.prefix_math, sub),
                }
            },
            0xfe => {
                const sub = readU32(bytes, &pos);
                const at_sig = atomicSig(sub) orelse
                    return classifyOpcode(Opcode.prefix_threads, sub);
                try checkAtomic(m, bytes, &pos, &val_stack, &ctrl_stack, at_sig, gpa(m));
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
        for (sig.results.vts, 0..) |_, i| {
            const actual = popVal(&val_stack, &ctrl_stack) catch return error.TypeMismatch;
            if (!actual.isSubtypeOf(m, sig.results.at(i))) return error.TypeMismatch;
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
    params: TypeSeq,
    results: TypeSeq,
};

/// Read a block signature: `blocktype ::= 0x40 | valtype | s33 typeidx`.
///
/// The three cases are told apart by the first byte, but not by its
/// magnitude: as an s33 every one-byte value type is *negative* (`i32` is
/// `0x7f`, that is -1) while a type index is non-negative and needs two
/// bytes from 64 up (77 is `cd 00`), and `0x63`/`0x64` are prefixes that a
/// heap type follows rather than complete types. Taking any byte >= 0x60 for
/// a whole value type consumed half of both wide forms and left the rest of
/// the body decoding at the wrong offset, which surfaced as a type mismatch
/// or a bad label index somewhere further on (issue #384).
///
/// `scratch` owns the one-element sequence a `(ref null ht)` / `(ref ht)`
/// signature needs; see `blockRefResult`.
fn readBlockType(
    m: *const Mod.Module,
    bytes: []const u8,
    pos: *usize,
    scratch: std.mem.Allocator,
) Error!BlockType {
    if (pos.* >= bytes.len) return error.UnexpectedEnd;
    const byte = bytes[pos.*];

    // 0x40: no parameters and no results.
    if (byte == 0x40) {
        pos.* += 1;
        return .{ .params = .{}, .results = .{} };
    }

    // 0x63/0x64: a prefix plus a heap type, so the value type spans at least
    // two bytes. The heap type may be abstract or a concrete type index;
    // `readHeapStackType` bounds-checks the index.
    if (byte == reader.ref_null_prefix or byte == reader.ref_prefix) {
        pos.* += 1;
        const nullable = byte == reader.ref_null_prefix;
        const ref = readHeapStackType(m, bytes, pos, nullable) orelse return error.InvalidTypeIndex;
        return .{ .params = .{}, .results = try blockRefResult(scratch, ref) };
    }

    // Every remaining value type encodes in one byte. `single_val_types`
    // holds exactly those, so a byte it does not know is not a value type at
    // all and falls through to the type-index reading below -- where, being
    // negative as an s33, it is rejected.
    if (single_val_types[byte] != null) {
        pos.* += 1;
        return .{ .params = .{}, .results = .{ .vts = valTypeSlice(byte) } };
    }

    // What is left is an s33 type index. The 33-bit range does not fit in an
    // i32, and reading it as an i64 would admit encodings up to ten bytes
    // wide, so the width belongs to the reader.
    const result = leb128.readS33Leb128(bytes[pos.*..]) catch |err| return switch (err) {
        error.UnexpectedEnd => error.UnexpectedEnd,
        error.Overflow => error.InvalidTypeIndex,
    };
    pos.* += result.bytes_read;
    if (result.value < 0 or result.value > std.math.maxInt(u32)) return error.InvalidTypeIndex;
    const idx: u32 = @intCast(result.value);
    if (idx >= m.module_types.items.len) return error.InvalidTypeIndex;
    return switch (m.module_types.items[idx]) {
        .func_type => |ft| .{ .params = funcParams(ft), .results = funcResults(ft) },
        // A block signature names a function type; a struct or array type
        // in that position is not a signature at all.
        else => error.TypeMismatch,
    };
}

/// The one-element result sequence of a `(ref null ht)` / `(ref ht)` block
/// signature.
///
/// These value types have no single-byte encoding, so `single_val_types`
/// cannot supply the slice, and a concrete index has to travel beside the
/// type. `TypeSeq` holds slices and the control frame built from it outlives
/// this call, so the storage comes from the caller's per-body arena rather
/// than from a local.
fn blockRefResult(scratch: std.mem.Allocator, ref: StackType) Error!TypeSeq {
    const vt = ref.toValType() orelse return error.InvalidTypeIndex;
    const vts = scratch.alloc(types.ValType, 1) catch return error.OutOfMemory;
    vts[0] = vt;
    if (ref.type_idx == types.invalid_index) return .{ .vts = vts };
    const idxs = scratch.alloc(u32, 1) catch return error.OutOfMemory;
    idxs[0] = ref.type_idx;
    return .{ .vts = vts, .type_idxs = idxs };
}

/// Reusable single-element type slices for block types, one per value type
/// with a single-byte encoding.
///
/// Built from `types.ValType` rather than listed by hand: the hand-written
/// list covered only i32/i64/f32/f64/funcref/externref, and every other
/// single-byte block type -- `exnref`, `anyref`, `eqref`, `i31ref`,
/// `structref`, `arrayref` and the four null bottoms -- fell through to the
/// empty slice. A block declared to return one of those was validated as
/// returning nothing at all.
const single_val_types = blk: {
    var table: [256]?[1]types.ValType = @splat(null);
    for (@typeInfo(types.ValType).@"enum".fields) |f| {
        // Negative discriminants are the internal non-nullable forms, which
        // have no single-byte encoding. The composite markers (`func`,
        // `struct`, `array`) and the GC packed types (`i8`, `i16`) do have
        // one, but only inside a type section -- never as a block type.
        if (f.value < 0 or f.value > 0xff) continue;
        const vt: types.ValType = @enumFromInt(f.value);
        switch (vt) {
            .func, .struct_, .array, .i8, .i16 => continue,
            else => {},
        }
        table[@as(usize, f.value)] = .{vt};
    }
    break :blk table;
};

fn valTypeSlice(byte: u8) []const types.ValType {
    if (single_val_types[byte]) |*one| return one;
    return &.{};
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

/// Read a heap type: an s33 whose negative values name the abstract heap
/// types and whose non-negative values are type indices. Same width rule as
/// a block signature -- a heap type six bytes wide is malformed, not padded.
fn readHeapStackType(m: *const Mod.Module, bytes: []const u8, pos: *usize, nullable: bool) ?StackType {
    if (pos.* >= bytes.len) return null;
    const result = leb128.readS33Leb128(bytes[pos.*..]) catch return null;
    pos.* += result.bytes_read;
    if (types.AbstractHeapType.fromCode(result.value)) |heap| {
        return StackType.fromRefType(types.RefType.abstract(nullable, heap));
    }
    if (result.value >= 0 and result.value <= std.math.maxInt(u32)) {
        const idx: u32 = @intCast(result.value);
        if (idx >= m.module_types.items.len) return null;
        return StackType.fromRefType(types.RefType.concrete(nullable, idx));
    }
    return null;
}

fn pushCtrl(ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), val_stack: *ValStack, opcode: u8, start: TypeSeq, end: TypeSeq, alloc: std.mem.Allocator) !void {
    try ctrl_stack.append(alloc, .{
        .opcode = opcode,
        .start_types = start,
        .end_types = end,
        .height = val_stack.items.len,
        .unreachable_flag = false,
        .else_seen = false,
    });
}

fn pushVals(val_stack: *ValStack, vts: TypeSeq, alloc: std.mem.Allocator) !void {
    for (vts.vts, 0..) |_, i| try val_stack.append(alloc, vts.at(i));
}

fn popVal(val_stack: *ValStack, ctrl_stack: *const std.ArrayListUnmanaged(CtrlFrame)) error{TypeMismatch}!StackType {
    if (ctrl_stack.items.len > 0) {
        const frame = ctrl_stack.items[ctrl_stack.items.len - 1];
        if (val_stack.items.len <= frame.height) {
            if (frame.unreachable_flag) return StackType.unknown();
            return error.TypeMismatch;
        }
    } else if (val_stack.items.len == 0) {
        return error.TypeMismatch;
    }
    return val_stack.pop() orelse return error.TypeMismatch;
}

fn popExpect(m: *const Mod.Module, val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), expected: StackType) Error!void {
    const actual = popVal(val_stack, ctrl_stack) catch return error.TypeMismatch;
    if (!actual.isSubtypeOf(m, expected)) return error.TypeMismatch;
}

fn popVals(m: *const Mod.Module, val_stack: *ValStack, frame: *const CtrlFrame, expected: TypeSeq) Error!void {
    // Pop in reverse order
    var i: usize = expected.len();
    while (i > 0) {
        i -= 1;
        const actual = popValFromFrame(val_stack, frame) catch return error.TypeMismatch;
        if (!actual.isSubtypeOf(m, expected.at(i))) return error.TypeMismatch;
    }
}

fn popValFromFrame(val_stack: *ValStack, frame: *const CtrlFrame) error{TypeMismatch}!StackType {
    if (val_stack.items.len <= frame.height) {
        if (frame.unreachable_flag) return StackType.unknown();
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
    callee_results: TypeSeq,
) Error!void {
    if (ctrl_stack.items.len == 0) return error.TypeMismatch;
    const func_results = ctrl_stack.items[0].end_types;
    if (callee_results.len() != func_results.len()) return error.TypeMismatch;
    for (callee_results.vts, 0..) |_, i| {
        const a = callee_results.at(i);
        const b = func_results.at(i);
        if (a.vt != b.vt or a.type_idx != b.type_idx) return error.TypeMismatch;
    }
}

/// A `try_table` catch clause hands its label a fixed list of values: the
/// tag's parameters, plus the caught exception for the `_ref` variants. The
/// label has to accept exactly that many, each a supertype of what arrives --
/// the same rule `br` uses, which is why `(ref func)` may be delivered to a
/// `funcref` label but not the reverse.
fn checkCatchLabel(
    m: *const Mod.Module,
    target: *const CtrlFrame,
    delivered: TypeSeq,
    with_exnref: bool,
) Error!void {
    const lt = labelTypes(target);
    const expected_len = delivered.len() + @intFromBool(with_exnref);
    if (lt.len() != expected_len) return error.TypeMismatch;
    for (0..delivered.len()) |i| {
        if (!delivered.at(i).isSubtypeOf(m, lt.at(i))) return error.TypeMismatch;
    }
    if (with_exnref and !StackType.known(.exnref).isSubtypeOf(m, lt.at(expected_len - 1)))
        return error.TypeMismatch;
}

fn labelTypes(frame: *const CtrlFrame) TypeSeq {
    // For loops, branch targets use start_types; for blocks/ifs, use end_types
    return if (frame.opcode == 0x03) frame.start_types else frame.end_types;
}

fn checkUnary(m: *const Mod.Module, val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), input: ValTypeOrUnknown, output: ValTypeOrUnknown, alloc: std.mem.Allocator) Error!void {
    try popExpect(m, val_stack, ctrl_stack, StackType.known(input));
    val_stack.append(alloc, StackType.known(output)) catch return error.OutOfMemory;
}

fn checkBinary(m: *const Mod.Module, val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), operand: ValTypeOrUnknown, result: ValTypeOrUnknown, alloc: std.mem.Allocator) Error!void {
    try popExpect(m, val_stack, ctrl_stack, StackType.known(operand));
    try popExpect(m, val_stack, ctrl_stack, StackType.known(operand));
    val_stack.append(alloc, StackType.known(result)) catch return error.OutOfMemory;
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
    try popExpect(m, val_stack, ctrl_stack, StackType.known(memIndexType(m, memarg.mem_idx)));
    val_stack.append(alloc, StackType.known(result_type)) catch return error.OutOfMemory;
}

fn checkMemStore(m: *const Mod.Module, bytes: []const u8, pos: *usize, val_stack: *ValStack, ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame), value_type: ValTypeOrUnknown, _: std.mem.Allocator, opcode: u8) Error!void {
    const memarg = readMemArg(bytes, pos);
    if (maxAlignmentForOpcode(opcode)) |max_align| {
        if (memarg.align_val > max_align) return error.InvalidAlignment;
    }
    if (m.memories.items.len == 0 or memarg.mem_idx >= m.memories.items.len) return error.InvalidMemoryIndex;
    try popExpect(m, val_stack, ctrl_stack, StackType.known(value_type));
    try popExpect(m, val_stack, ctrl_stack, StackType.known(memIndexType(m, memarg.mem_idx)));
}



// ── Atomic (0xfe) instruction signatures ────────────────────────────────

/// Shape of the immediate operands that follow an atomic opcode.
pub const AtomicImm = enum {
    /// align + optional memory index + offset.
    memarg,
    /// A single reserved byte, which must be zero (atomic.fence).
    fence,
};

/// Static type signature of one atomic instruction.
pub const AtomicSig = struct {
    /// Operands in stack order, bottom first; popped in reverse.
    params: []const ValTypeOrUnknown,
    results: []const ValTypeOrUnknown,
    imm: AtomicImm,
    /// Required alignment, as log2 of the accessed width. Unlike ordinary
    /// memory instructions, atomics must be *exactly* naturally aligned --
    /// an under-aligned atomic access is not a valid module.
    align_log2: u8,
};

/// Signature for a 0xfe sub-opcode, or null if this build does not know it.
///
/// Generated from the opcode list in Opcode.zig; the drift-guard test below
/// asserts the two stay in sync.
pub fn atomicSig(sub: u32) ?AtomicSig {
    return switch (sub) {
        0x00 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // memory_atomic_notify
        0x01 => .{ .params = &.{.i32, .i32, .i64}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // memory_atomic_wait32
        0x02 => .{ .params = &.{.i32, .i64, .i64}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 3 }, // memory_atomic_wait64
        0x03 => .{ .params = &.{}, .results = &.{}, .imm = .fence, .align_log2 = 0 }, // atomic_fence
        0x10 => .{ .params = &.{.i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_load
        0x11 => .{ .params = &.{.i32}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_load
        0x12 => .{ .params = &.{.i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_load8_u
        0x13 => .{ .params = &.{.i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_load16_u
        0x14 => .{ .params = &.{.i32}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_load8_u
        0x15 => .{ .params = &.{.i32}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_load16_u
        0x16 => .{ .params = &.{.i32}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_load32_u
        0x17 => .{ .params = &.{.i32, .i32}, .results = &.{}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_store
        0x18 => .{ .params = &.{.i32, .i64}, .results = &.{}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_store
        0x19 => .{ .params = &.{.i32, .i32}, .results = &.{}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_store8
        0x1a => .{ .params = &.{.i32, .i32}, .results = &.{}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_store16
        0x1b => .{ .params = &.{.i32, .i64}, .results = &.{}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_store8
        0x1c => .{ .params = &.{.i32, .i64}, .results = &.{}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_store16
        0x1d => .{ .params = &.{.i32, .i64}, .results = &.{}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_store32
        0x1e => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_add
        0x1f => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_add
        0x20 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_add_u
        0x21 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_add_u
        0x22 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_add_u
        0x23 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_add_u
        0x24 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_add_u
        0x25 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_sub
        0x26 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_sub
        0x27 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_sub_u
        0x28 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_sub_u
        0x29 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_sub_u
        0x2a => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_sub_u
        0x2b => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_sub_u
        0x2c => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_and
        0x2d => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_and
        0x2e => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_and_u
        0x2f => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_and_u
        0x30 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_and_u
        0x31 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_and_u
        0x32 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_and_u
        0x33 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_or
        0x34 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_or
        0x35 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_or_u
        0x36 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_or_u
        0x37 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_or_u
        0x38 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_or_u
        0x39 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_or_u
        0x3a => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_xor
        0x3b => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_xor
        0x3c => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_xor_u
        0x3d => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_xor_u
        0x3e => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_xor_u
        0x3f => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_xor_u
        0x40 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_xor_u
        0x41 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_xchg
        0x42 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_xchg
        0x43 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_xchg_u
        0x44 => .{ .params = &.{.i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_xchg_u
        0x45 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_xchg_u
        0x46 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_xchg_u
        0x47 => .{ .params = &.{.i32, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_xchg_u
        0x48 => .{ .params = &.{.i32, .i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 2 }, // i32_atomic_rmw_cmpxchg
        0x49 => .{ .params = &.{.i32, .i64, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 3 }, // i64_atomic_rmw_cmpxchg
        0x4a => .{ .params = &.{.i32, .i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 0 }, // i32_atomic_rmw8_cmpxchg_u
        0x4b => .{ .params = &.{.i32, .i32, .i32}, .results = &.{.i32}, .imm = .memarg, .align_log2 = 1 }, // i32_atomic_rmw16_cmpxchg_u
        0x4c => .{ .params = &.{.i32, .i64, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 0 }, // i64_atomic_rmw8_cmpxchg_u
        0x4d => .{ .params = &.{.i32, .i64, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 1 }, // i64_atomic_rmw16_cmpxchg_u
        0x4e => .{ .params = &.{.i32, .i64, .i64}, .results = &.{.i64}, .imm = .memarg, .align_log2 = 2 }, // i64_atomic_rmw32_cmpxchg_u
        else => null,
    };
}

/// Type-check one atomic instruction: consume its immediates, then apply
/// its stack effect.
fn checkAtomic(
    m: *const Mod.Module,
    bytes: []const u8,
    pos: *usize,
    val_stack: *ValStack,
    ctrl_stack: *std.ArrayListUnmanaged(CtrlFrame),
    sig: AtomicSig,
    alloc: std.mem.Allocator,
) Error!void {
    var mem_idx: u32 = 0;
    switch (sig.imm) {
        .fence => {
            if (pos.* >= bytes.len) return error.UnexpectedEnd;
            // The byte is reserved for a future memory index.
            if (bytes[pos.*] != 0) return error.InvalidMemoryIndex;
            pos.* += 1;
        },
        .memarg => {
            const memarg = readMemArg(bytes, pos);
            // Exact, not maximum: atomics may not be under-aligned.
            if (memarg.align_val != sig.align_log2) return error.InvalidAlignment;
            if (m.memories.items.len == 0 or memarg.mem_idx >= m.memories.items.len)
                return error.InvalidMemoryIndex;
            mem_idx = memarg.mem_idx;
        },
    }

    // Operands are listed bottom-of-stack first, so pop in reverse.
    var i = sig.params.len;
    while (i > 0) {
        i -= 1;
        var expected = sig.params[i];
        // The address operand widens to i64 under memory64.
        if (i == 0 and sig.imm == .memarg) {
            expected = memIndexType(m, mem_idx);
        }
        try popExpect(m, val_stack, ctrl_stack, StackType.known(expected));
    }
    for (sig.results) |r| val_stack.append(alloc, StackType.known(r)) catch return error.OutOfMemory;
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
pub const SimdSig = struct {
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
        if (i == 0 and (sig.imm == .memarg or sig.imm == .memarg_lane)) {
            expected = memIndexType(m, mem_idx);
        }
        try popExpect(m, val_stack, ctrl_stack, StackType.known(expected));
    }
    for (sig.results) |r| val_stack.append(alloc, StackType.known(r)) catch return error.OutOfMemory;
}

pub fn simdSig(sub: u32) ?SimdSig {
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

test "concrete table and global imports validate in both text spellings" {
    const Parser = @import("text/Parser.zig");
    const cases = [_][]const u8{
        \\(module (type $t (func))
        \\  (import "m" "t" (table $tab 1 (ref null $t)))
        \\  (func (result (ref null $t)) i32.const 0 table.get $tab))
        ,
        \\(module (type $t (func))
        \\  (table $tab (import "m" "t") 1 (ref null $t))
        \\  (func (result (ref null $t)) i32.const 0 table.get $tab))
        ,
        \\(module (type (func))
        \\  (import "m" "t" (table $tab 1 (ref null 0)))
        \\  (func (result (ref null 0)) i32.const 0 table.get $tab))
        ,
        \\(module (type (func))
        \\  (table $tab (import "m" "t") 1 (ref null 0))
        \\  (func (result (ref null 0)) i32.const 0 table.get $tab))
        ,
        \\(module (type $t (func))
        \\  (import "m" "g" (global $g (ref null $t)))
        \\  (func (result (ref null $t)) global.get $g))
        ,
        \\(module (type $t (func))
        \\  (global $g (import "m" "g") (ref null $t))
        \\  (func (result (ref null $t)) global.get $g))
        ,
        \\(module (type (func))
        \\  (import "m" "g" (global $g (mut (ref null 0))))
        \\  (func (result (ref null 0)) global.get $g))
        ,
        \\(module (type (func))
        \\  (global $g (import "m" "g") (mut (ref null 0)))
        \\  (func (result (ref null 0)) global.get $g))
        ,
    };

    for (cases) |source| {
        var module = try Parser.parseModule(std.testing.allocator, source);
        defer module.deinit();
        try validate(&module, .{});
    }
}

test "concrete table and global imports reject invalid type indices" {
    const Parser = @import("text/Parser.zig");

    var table_module = try Parser.parseModule(std.testing.allocator,
        "(module (type (func)) (import \"m\" \"t\" (table 1 (ref null 0))))",
    );
    defer table_module.deinit();
    table_module.tables.items[0].type_idx = 1;
    try std.testing.expectError(error.InvalidTypeIndex, validate(&table_module, .{}));

    var global_module = try Parser.parseModule(std.testing.allocator,
        "(module (type (func)) (import \"m\" \"g\" (global (ref null 0))))",
    );
    defer global_module.deinit();
    global_module.globals.items[0].type_idx = 1;
    try std.testing.expectError(error.InvalidTypeIndex, validate(&global_module, .{}));
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

fn testModuleWithSignatureAndBody(
    alloc: std.mem.Allocator,
    params: []const types.ValType,
    results: []const types.ValType,
    body: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{
        .params = try alloc.dupe(types.ValType, params),
        .results = try alloc.dupe(types.ValType, results),
    } });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

fn appendFuncTypeForTest(
    module: *Mod.Module,
    params: []const types.ValType,
    results: []const types.ValType,
    param_type_idxs: []const u32,
    result_type_idxs: []const u32,
) !void {
    const alloc = module.allocator;
    try module.module_types.append(alloc, .{ .func_type = .{
        .params = if (params.len > 0) try alloc.dupe(types.ValType, params) else &.{},
        .results = if (results.len > 0) try alloc.dupe(types.ValType, results) else &.{},
        .param_type_idxs = if (param_type_idxs.len > 0) try alloc.dupe(u32, param_type_idxs) else &.{},
        .result_type_idxs = if (result_type_idxs.len > 0) try alloc.dupe(u32, result_type_idxs) else &.{},
    } });
}

// ── Abstract reference subtyping (issue #355) ───────────────────────────

const test_heap_types = [_]types.AbstractHeapType{
    .func,
    .nofunc,
    .extern_,
    .noextern,
    .any,
    .eq,
    .i31,
    .struct_,
    .array,
    .none,
    .exn,
    .noexn,
};

const test_nullabilities = [_]bool{ false, true };

fn expectedHeapSubtype(actual: types.AbstractHeapType, expected: types.AbstractHeapType) bool {
    if (actual == expected) return true;
    return switch (actual) {
        .eq => expected == .any,
        .i31, .struct_, .array => expected == .eq or expected == .any,
        .none => switch (expected) {
            .any, .eq, .i31, .struct_, .array => true,
            else => false,
        },
        .nofunc => expected == .func,
        .noextern => expected == .extern_,
        .noexn => expected == .exn,
        else => false,
    };
}

fn expectedRefSubtype(
    actual_nullable: bool,
    actual_heap: types.AbstractHeapType,
    expected_nullable: bool,
    expected_heap: types.AbstractHeapType,
) bool {
    if (actual_nullable and !expected_nullable) return false;
    return expectedHeapSubtype(actual_heap, expected_heap);
}

fn abstractRefValType(nullable: bool, heap: types.AbstractHeapType) types.ValType {
    return if (nullable) heap.nullableValType() else heap.nonNullableValType();
}

test "abstract reference subtyping lattice covers all pairs" {
    for (test_nullabilities) |actual_nullable| {
        for (test_heap_types) |actual_heap| {
            const actual_vt = ValTypeOrUnknown.fromValType(abstractRefValType(actual_nullable, actual_heap));
            for (test_nullabilities) |expected_nullable| {
                for (test_heap_types) |expected_heap| {
                    const expected_vt = ValTypeOrUnknown.fromValType(abstractRefValType(expected_nullable, expected_heap));
                    try std.testing.expectEqual(
                        expectedRefSubtype(actual_nullable, actual_heap, expected_nullable, expected_heap),
                        actual_vt.isSubtypeOf(expected_vt),
                    );
                }
            }
        }
    }

    try std.testing.expect(!ValTypeOrUnknown.fromValType(.anyref).isSubtypeOf(ValTypeOrUnknown.fromValType(.nullref)));
    try std.testing.expect(!ValTypeOrUnknown.fromValType(.funcref).isSubtypeOf(ValTypeOrUnknown.fromValType(.anyref)));
    try std.testing.expect(!ValTypeOrUnknown.fromValType(.externref).isSubtypeOf(ValTypeOrUnknown.fromValType(.anyref)));
    try std.testing.expect(!ValTypeOrUnknown.fromValType(.structref).isSubtypeOf(ValTypeOrUnknown.fromValType(.arrayref)));
    try std.testing.expect(!ValTypeOrUnknown.fromValType(.arrayref).isSubtypeOf(ValTypeOrUnknown.fromValType(.structref)));
    try std.testing.expect(!ValTypeOrUnknown.fromValType(.funcref).isSubtypeOf(ValTypeOrUnknown.fromValType(.ref_func)));
}

test "abstract reference subtyping lattice is reflexive and transitive" {
    for (test_nullabilities) |nullable| {
        for (test_heap_types) |heap| {
            const vt = ValTypeOrUnknown.fromValType(abstractRefValType(nullable, heap));
            try std.testing.expect(vt.isSubtypeOf(vt));
        }
    }

    for (test_nullabilities) |a_nullable| {
        for (test_heap_types) |a_heap| {
            const av = ValTypeOrUnknown.fromValType(abstractRefValType(a_nullable, a_heap));
            for (test_nullabilities) |b_nullable| {
                for (test_heap_types) |b_heap| {
                    const bv = ValTypeOrUnknown.fromValType(abstractRefValType(b_nullable, b_heap));
                    if (!av.isSubtypeOf(bv)) continue;
                    for (test_nullabilities) |c_nullable| {
                        for (test_heap_types) |c_heap| {
                            const cv = ValTypeOrUnknown.fromValType(abstractRefValType(c_nullable, c_heap));
                            if (bv.isSubtypeOf(cv)) {
                                try std.testing.expect(av.isSubtypeOf(cv));
                            }
                        }
                    }
                }
            }
        }
    }
}

test "validator rejects a reference supertype where a subtype is required" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : anyref
        0x0b, // end, expected nullref
    };
    var module = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.anyref},
        &[_]types.ValType{.nullref},
        &body,
    );
    defer module.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "validator accepts a non-null reference where nullable is expected" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : (ref func)
        0x0b, // end, expected funcref
    };
    var module = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.ref_func},
        &[_]types.ValType{.funcref},
        &body,
    );
    defer module.deinit();
    try validate(&module, .{});
}

test "validator keeps concrete type indices on the operand stack" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();

    try appendFuncTypeForTest(&module, &[_]types.ValType{.i32}, &.{}, &.{}, &.{});
    try appendFuncTypeForTest(&module, &[_]types.ValType{.i64}, &.{}, &.{}, &.{});
    try appendFuncTypeForTest(
        &module,
        &[_]types.ValType{.concrete_ref},
        &[_]types.ValType{.concrete_ref},
        &[_]u32{0},
        &[_]u32{1},
    );
    const body = [_]u8{
        0x20, 0x00, // local.get 0; wasm-tools v1.250.0 body bytes for `(local.get 0)`
        0x0b,
    };
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 2 } }, .code_bytes = &body });

    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "concrete function subtyping is contravariant in parameters" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();

    try appendFuncTypeForTest(&module, &[_]types.ValType{.anyref}, &.{}, &.{}, &.{});
    try appendFuncTypeForTest(&module, &[_]types.ValType{.structref}, &.{}, &.{}, &.{});
    try appendFuncTypeForTest(&module, &.{}, &[_]types.ValType{.concrete_ref}, &.{}, &[_]u32{1});
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    try module.exports.append(alloc, .{ .name = "callee", .kind = .func, .var_ = .{ .index = 0 } });
    const body = [_]u8{
        0xd2, 0x00, // ref.func 0; wasm-tools v1.250.0 body bytes
        0x0b,
    };
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 2 } }, .code_bytes = &body });

    try validate(&module, .{});
}

test "mutable struct fields are invariant under declared subtyping" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();

    var parent_fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
    try parent_fields.append(alloc, .{ .@"type" = .anyref, .mutable = true });
    try module.module_types.append(alloc, .{ .struct_type = .{ .fields = parent_fields } });
    try module.type_meta.append(alloc, .{ .kind = .struct_, .is_final = false });

    var child_fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
    try child_fields.append(alloc, .{ .@"type" = .structref, .mutable = true });
    try module.module_types.append(alloc, .{ .struct_type = .{ .fields = child_fields } });
    try module.type_meta.append(alloc, .{ .kind = .struct_, .is_sub = true, .parent = 0 });

    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "concrete reference subtyping bridges to abstract heap types and bottoms" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();

    try appendFuncTypeForTest(&module, &.{}, &.{}, &.{}, &.{});
    const struct_fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
    try module.module_types.append(alloc, .{ .struct_type = .{ .fields = struct_fields } });

    const func_ref = StackType.fromRefType(types.RefType.concrete(false, 0));
    const struct_ref = StackType.fromRefType(types.RefType.concrete(false, 1));
    try std.testing.expect(func_ref.isSubtypeOf(&module, StackType.known(.funcref)));
    try std.testing.expect(struct_ref.isSubtypeOf(&module, StackType.known(.eqref)));
    try std.testing.expect(struct_ref.isSubtypeOf(&module, StackType.known(.anyref)));
    try std.testing.expect(StackType.known(.nullfuncref).isSubtypeOf(&module, StackType.fromRefType(types.RefType.concrete(true, 0))));
    try std.testing.expect(StackType.known(.nullref).isSubtypeOf(&module, StackType.fromRefType(types.RefType.concrete(true, 1))));
}

test "atomics are type-checked, not silently accepted" {
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
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
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
    // The two lists are deliberately separate. `modern_eh_todo` is a backlog
    // that issue #356 empties; `legacy_eh_opcodes` is a decision that stays,
    // so the work of clearing the first must never quietly erode the second.
    // Issue #356 emptied this. It stays as a named, documented anchor:
    // a future EH-adjacent opcode that lands without a validator arm should
    // be listed here deliberately rather than slipped past the guard.
    const modern_eh_todo = [_]u8{};
    const alloc = std.testing.allocator;
    var checked: usize = 0;
    inline for (@typeInfo(Opcode.Code).@"enum".fields) |f| {
        if (f.value <= 0xff) {
            const op: u8 = @intCast(f.value);
            const body = [_]u8{ op, 0x0b };
            var module = try testModuleWithBody(alloc, &body);
            defer module.deinit();
            checked += 1;
            if (std.mem.indexOfScalar(u8, &modern_eh_todo, op) != null) {
                try std.testing.expectError(error.UnsupportedOpcode, validate(&module, .{}));
            } else if (std.mem.indexOfScalar(u8, &legacy_eh_opcodes, op) != null) {
                try std.testing.expectError(error.LegacyExceptionsUnsupported, validate(&module, .{}));
            } else if (validate(&module, .{})) |_| {} else |err| switch (err) {
                error.UnsupportedOpcode, error.UnknownOpcode => {
                    std.debug.print(
                        "opcode 0x{x:0>2} ({s}) has no validator arm; add one or list it above\n",
                        .{ op, f.name },
                    );
                    return error.TestUnexpectedResult;
                },
                error.LegacyExceptionsUnsupported => {
                    std.debug.print(
                        "opcode 0x{x:0>2} ({s}) reports LegacyExceptionsUnsupported but is not" ++
                            " a legacy EH instruction\n",
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
        try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
    }
    try std.testing.expectEqualStrings("ref.eq", Opcode.Code.ref_eq.name());
}

// ── Typed reference instructions (issue #355, PR5) ──────────────────────

test "ref.eq accepts eqref-compatible operands" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0xd3, // ref.eq; wasm-tools v1.250.0 body bytes
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{ .eqref, .eqref },
        &[_]types.ValType{.i32},
        &body,
    );
    defer m.deinit();
    try validate(&m, .{});
}

test "ref.eq rejects non-eq references" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : funcref
        0x20, 0x01, // local.get 1 : eqref
        0xd3, // ref.eq; wasm-tools v1.250.0 rejects funcref here
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{ .funcref, .eqref },
        &[_]types.ValType{.i32},
        &body,
    );
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
}

test "ref.as_non_null preserves a concrete type index" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();

    try appendFuncTypeForTest(&module, &.{}, &.{}, &.{}, &.{});
    try appendFuncTypeForTest(
        &module,
        &[_]types.ValType{.concrete_ref_null},
        &[_]types.ValType{.concrete_ref},
        &[_]u32{0},
        &[_]u32{0},
    );
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : (ref null 0)
        0xd4, // ref.as_non_null; wasm-tools v1.250.0 body bytes
        0x0b,
    };
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 1 } },
        .code_bytes = &body,
    });

    try validate(&module, .{});
}

test "ref.as_non_null rejects non-reference operands" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : i32
        0xd4, // ref.as_non_null; wasm-tools v1.250.0 rejects i32 here
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.i32},
        &[_]types.ValType{.ref_eq},
        &body,
    );
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
}

test "br_on_null sharpens the fallthrough reference" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x02, 0x40, // block
        0x20, 0x00, // local.get 0 : eqref
        0xd5, 0x00, // br_on_null 0; wasm-tools v1.250.0 body bytes
        0x1a, // drop the non-null fallthrough value
        0x0b,
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.eqref},
        &.{},
        &body,
    );
    defer m.deinit();
    try validate(&m, .{});
}

test "br_on_null rejects an unconsumed sharpened fallthrough value" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x02, 0x40, // block
        0x20, 0x00, // local.get 0 : eqref
        0xd5, 0x00, // br_on_null 0; wasm-tools v1.250.0 leaves (ref eq)
        0x0b,
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.eqref},
        &.{},
        &body,
    );
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
}

test "br_on_non_null branches with the non-null reference" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : eqref
        0xd6, 0x00, // br_on_non_null 0 to the function label
        0xd0, 0x6d, // ref.null eq for the fallthrough path
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.eqref},
        &[_]types.ValType{.eqref},
        &body,
    );
    defer m.deinit();
    try validate(&m, .{});
}

test "br_on_non_null rejects a target with no label type for its value" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x20, 0x00, // local.get 0 : eqref
        0xd6, 0x00, // br_on_non_null 0; wasm-tools v1.250.0 rejects this target
        0x0b,
    };
    var m = try testModuleWithSignatureAndBody(
        alloc,
        &[_]types.ValType{.eqref},
        &.{},
        &body,
    );
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
}

fn testCallRefModule(
    alloc: std.mem.Allocator,
    caller_results: []const types.ValType,
    body: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try appendFuncTypeForTest(
        &module,
        &[_]types.ValType{.i32},
        &[_]types.ValType{.i32},
        &.{},
        &.{},
    );
    try appendFuncTypeForTest(&module, &.{}, caller_results, &.{}, &.{});
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .is_import = true,
    });
    try module.exports.append(alloc, .{
        .name = "callee",
        .kind = .func,
        .var_ = .{ .index = 0 },
    });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 1 } },
        .code_bytes = body,
    });
    return module;
}

test "call_ref checks the callee reference and function parameters" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x41, 0x04, // i32.const 4
        0xd2, 0x00, // ref.func 0
        0x14, 0x00, // call_ref 0; wasm-tools v1.250.0 body bytes
        0x0b,
    };
    var m = try testCallRefModule(alloc, &[_]types.ValType{.i32}, &body);
    defer m.deinit();
    try validate(&m, .{});
}

test "call_ref rejects a callee reference of the wrong heap" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x41, 0x04, // i32.const 4
        0xd0, 0x6f, // ref.null extern
        0x14, 0x00, // call_ref 0; wasm-tools v1.250.0 rejects externref here
        0x0b,
    };
    var m = try testCallRefModule(alloc, &[_]types.ValType{.i32}, &body);
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
}

test "call_ref rejects a concrete callee whose signature is not the expected type" {
    // The wrong-heap test above uses externref, which any funcref-shaped check
    // rejects. This one passes a *function* reference of a different concrete
    // type: only comparing against (ref null $t) catches it. Widening the
    // callee expectation to funcref makes wabt accept a module that
    // wasm-tools v1.250.0 rejects with "func 0 failed to validate".
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    // type 0: (i32) -> (i32)   — what call_ref names
    try appendFuncTypeForTest(&module, &[_]types.ValType{.i32}, &[_]types.ValType{.i32}, &.{}, &.{});
    // type 1: () -> (i32)      — the caller
    try appendFuncTypeForTest(&module, &.{}, &[_]types.ValType{.i32}, &.{}, &.{});
    // type 2: (f64) -> (f64)   — the callee actually referenced
    try appendFuncTypeForTest(&module, &[_]types.ValType{.f64}, &[_]types.ValType{.f64}, &.{}, &.{});
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 2 } }, .is_import = true });
    try module.exports.append(alloc, .{ .name = "callee", .kind = .func, .var_ = .{ .index = 0 } });
    const body = [_]u8{
        0x41, 0x04, // i32.const 4
        0xd2, 0x00, // ref.func 0 -> (ref 2), not (ref 0)
        0x14, 0x00, // call_ref 0
        0x0b,
    };
    try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 1 } }, .code_bytes = &body });
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "return_call_ref checks the callee and makes the frame unreachable" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x41, 0x04, // i32.const 4
        0xd2, 0x00, // ref.func 0
        0x15, 0x00, // return_call_ref 0; wasm-tools v1.250.0 body bytes
        0x0b,
    };
    var m = try testCallRefModule(alloc, &[_]types.ValType{.i32}, &body);
    defer m.deinit();
    try validate(&m, .{});
}

test "return_call_ref rejects result mismatch with the enclosing function" {
    const alloc = std.testing.allocator;
    const body = [_]u8{
        0x41, 0x04, // i32.const 4
        0xd2, 0x00, // ref.func 0
        0x15, 0x00, // return_call_ref 0; wasm-tools v1.250.0 rejects i32 -> i64
        0x0b,
    };
    var m = try testCallRefModule(alloc, &[_]types.ValType{.i64}, &body);
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
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

// ── Atomics (issue #347, D3) ────────────────────────────────────────────

test "every declared atomic opcode has a signature" {
    // Drift guard: Opcode.zig and atomicSig must agree.
    var checked: usize = 0;
    inline for (@typeInfo(Opcode.Code).@"enum".fields) |f| {
        if (f.value > 0xff) {
            const code: Opcode.Code = @enumFromInt(f.value);
            if (code.getPrefix() == Opcode.prefix_threads) {
                checked += 1;
                if (atomicSig(code.getCode()) == null) {
                    std.debug.print(
                        "atomic opcode 0x{x} ({s}) has no signature in atomicSig\n",
                        .{ f.value, f.name },
                    );
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 67), checked);
}

test "valid atomic modules now validate" {
    const alloc = std.testing.allocator;
    // i32.const 0; i32.atomic.load align=2; drop
    const body = [_]u8{ 0x41, 0x00, 0xfe, 0x10, 0x02, 0x00, 0x1a, 0x0b };
    var m = try testModuleWithBody(alloc, &body);
    defer m.deinit();
    try validate(&m, .{});
}

test "atomic alignment must be exact, not merely bounded" {
    const alloc = std.testing.allocator;
    // i32.atomic.load accesses 4 bytes, so align must be exactly 2.
    // Ordinary loads permit anything up to the natural alignment; atomics
    // do not, because an under-aligned atomic access is not well defined.
    for ([_]u8{ 0x00, 0x01, 0x03 }) |bad_align| {
        const body = [_]u8{ 0x41, 0x00, 0xfe, 0x10, bad_align, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try std.testing.expectError(error.InvalidAlignment, validate(&m, .{}));
    }
    // i32.atomic.load8_u accesses 1 byte: align must be exactly 0.
    const ok = [_]u8{ 0x41, 0x00, 0xfe, 0x12, 0x00, 0x00, 0x1a, 0x0b };
    var m_ok = try testModuleWithBody(alloc, &ok);
    defer m_ok.deinit();
    try validate(&m_ok, .{});

    const bad = [_]u8{ 0x41, 0x00, 0xfe, 0x12, 0x02, 0x00, 0x1a, 0x0b };
    var m_bad = try testModuleWithBody(alloc, &bad);
    defer m_bad.deinit();
    try std.testing.expectError(error.InvalidAlignment, validate(&m_bad, .{}));
}

test "atomic rmw and cmpxchg consume the right operand shapes" {
    const alloc = std.testing.allocator;
    // i32.const 0 (addr); i32.const 1 (val); i32.atomic.rmw.add; drop
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x01, 0xfe, 0x1e, 0x02, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try validate(&m, .{});
    }
    // cmpxchg takes addr, expected, replacement -- three operands.
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x01, 0x41, 0x02, 0xfe, 0x48, 0x02, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try validate(&m, .{});
    }
    // ...and rejects two.
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x01, 0xfe, 0x48, 0x02, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // i64 rmw wants an i64 value, not an i32.
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x01, 0xfe, 0x1f, 0x03, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "atomic loads yield the declared width's type" {
    const alloc = std.testing.allocator;
    // i64.atomic.load8_u yields i64, so i32.eqz on it is a type error.
    const body = [_]u8{ 0x41, 0x00, 0xfe, 0x14, 0x00, 0x00, 0x45, 0x1a, 0x0b };
    var m = try testModuleWithBody(alloc, &body);
    defer m.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));

    // i64.eqz is fine.
    const ok = [_]u8{ 0x41, 0x00, 0xfe, 0x14, 0x00, 0x00, 0x50, 0x1a, 0x0b };
    var m_ok = try testModuleWithBody(alloc, &ok);
    defer m_ok.deinit();
    try validate(&m_ok, .{});
}

test "memory.atomic.wait and notify signatures" {
    const alloc = std.testing.allocator;
    // memory.atomic.wait32: addr i32, expected i32, timeout i64 -> i32
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x42, 0x00, 0xfe, 0x01, 0x02, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try validate(&m, .{});
    }
    // wait64 wants an i64 expected value; an i32 is a type error.
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x42, 0x00, 0xfe, 0x02, 0x03, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
    // memory.atomic.notify: addr i32, count i32 -> i32
    {
        const body = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0xfe, 0x00, 0x02, 0x00, 0x1a, 0x0b };
        var m = try testModuleWithBody(alloc, &body);
        defer m.deinit();
        try validate(&m, .{});
    }
}

test "atomic.fence takes a reserved zero byte and no operands" {
    const alloc = std.testing.allocator;
    const ok = [_]u8{ 0xfe, 0x03, 0x00, 0x0b };
    var m_ok = try testModuleWithBody(alloc, &ok);
    defer m_ok.deinit();
    try validate(&m_ok, .{});

    const bad = [_]u8{ 0xfe, 0x03, 0x01, 0x0b };
    var m_bad = try testModuleWithBody(alloc, &bad);
    defer m_bad.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&m_bad, .{}));
}

test "atomics require a memory to be declared" {
    const alloc = std.testing.allocator;
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    const body = [_]u8{ 0x41, 0x00, 0xfe, 0x10, 0x02, 0x00, 0x1a, 0x0b };
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&m, .{}));
}

test "legacy exception handling is declined with its own error (issue #356)" {
    // The legacy proposal (`try`/`catch`/`rethrow`/`delegate`/`catch_all`)
    // was superseded by `try_table`/`throw_ref` before exception handling was
    // standardised. Rejecting it is a decision, so it must not be reported as
    // `UnsupportedOpcode` -- that error means "on the backlog", and would tell
    // a caller to wait for support that is never coming.
    const alloc = std.testing.allocator;
    for (legacy_eh_opcodes) |op| {
        const body = [_]u8{ op, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.LegacyExceptionsUnsupported, validate(&module, .{}));
    }
}

test "the legacy EH list names the legacy EH instructions and nothing else" {
    // Without this, a typo'd byte in `legacy_eh_opcodes` would silently
    // divert an unrelated instruction into the legacy error, and the drift
    // guard above could not tell: it trusts the same list.
    const expected = [_][]const u8{ "try", "catch", "rethrow", "delegate", "catch_all" };
    try std.testing.expectEqual(expected.len, legacy_eh_opcodes.len);
    // Indexed rather than a paired loop: a paired `for` over two arrays of
    // comptime-known length turns a drifted list into a compile error, which
    // reports the mismatch without naming the offending instruction.
    for (legacy_eh_opcodes, 0..) |op, i| {
        const tag: Opcode.Code = @enumFromInt(op);
        try std.testing.expect(std.enums.tagName(Opcode.Code, tag) != null);
        try std.testing.expectEqualStrings(expected[i % expected.len], tag.name());
    }
}

test "the standardised EH instructions all reach a real validator arm" {
    // Issue #356 is done when none of `throw`, `throw_ref` or `try_table`
    // comes back as UnsupportedOpcode. A bare opcode byte is not a
    // well-typed body, so some other error is expected -- what matters is
    // that the validator recognises the instruction. The legacy set must
    // stay separately declined; clearing this backlog must not erode it.
    const alloc = std.testing.allocator;
    for ([_]u8{ 0x08, 0x0a, 0x1f }) |op| {
        const body = [_]u8{ op, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        if (validate(&module, .{})) |_| {} else |err| switch (err) {
            error.UnsupportedOpcode, error.UnknownOpcode, error.LegacyExceptionsUnsupported => {
                std.debug.print("EH opcode 0x{x:0>2} is still unhandled\n", .{op});
                return error.TestUnexpectedResult;
            },
            else => {},
        }
    }
}

test "classifyOpcode reports legacy EH separately from the backlog" {
    try std.testing.expectEqual(error.LegacyExceptionsUnsupported, classifyOpcode(null, 0x06));
    try std.testing.expectEqual(error.LegacyExceptionsUnsupported, classifyOpcode(null, 0x18));
    try std.testing.expectEqual(error.UnsupportedOpcode, classifyOpcode(null, 0x1f)); // try_table
    // The legacy bytes are only legacy unprefixed: 0xfd 0x06 is a SIMD
    // sub-opcode, and 0xfc 0x18 is unassigned. Neither may inherit the
    // legacy error from a prefix-blind byte comparison.
    try std.testing.expectEqual(error.UnsupportedOpcode, classifyOpcode(Opcode.prefix_simd, 0x06));
    try std.testing.expectEqual(error.UnknownOpcode, classifyOpcode(0xfc, 0x18));
}

test "throw pops the tag's parameters, in reverse" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    var ok = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32 i64))
        \\  (func (i32.const 1) (i64.const 2) (throw $e)))
    );
    defer ok.deinit();
    try validate(&ok, .{});

    // Operands supplied in the wrong order. Both are on the stack and both
    // are of a type the tag mentions, so only an order-sensitive check
    // rejects this.
    var swapped = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32 i64))
        \\  (func (i64.const 2) (i32.const 1) (throw $e)))
    );
    defer swapped.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&swapped, .{}));

    var too_few = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32 i64))
        \\  (func (i32.const 1) (throw $e)))
    );
    defer too_few.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&too_few, .{}));
}

test "throw checks the tag it names, not merely some tag" {
    // Two tags of the same arity whose parameter types differ. Throwing $b
    // with $a's operand only fails if the tag index is actually resolved;
    // a check that reached for the wrong tag, or for `tags.items[0]`, would
    // accept it.
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    var wrong = try Parser.parseModule(alloc,
        \\(module (tag $a (param i32)) (tag $b (param f32))
        \\  (func (i32.const 1) (throw $b)))
    );
    defer wrong.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wrong, .{}));

    var right = try Parser.parseModule(alloc,
        \\(module (tag $a (param i32)) (tag $b (param f32))
        \\  (func (f32.const 1) (throw $b)))
    );
    defer right.deinit();
    try validate(&right, .{});
}

test "throw resolves an imported tag's signature" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    var module = try Parser.parseModule(alloc,
        \\(module (import "m" "t" (tag $e (param i64)))
        \\  (func (i64.const 1) (throw $e)))
    );
    defer module.deinit();
    try validate(&module, .{});

    var bad = try Parser.parseModule(alloc,
        \\(module (import "m" "t" (tag $e (param i64)))
        \\  (func (i32.const 1) (throw $e)))
    );
    defer bad.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&bad, .{}));
}

test "throw with an out-of-range tag index is rejected" {
    const alloc = std.testing.allocator;
    const body = [_]u8{ 0x08, 0x00, 0x0b }; // throw 0, with no tags declared
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    try std.testing.expectError(error.InvalidTagIndex, validate(&module, .{}));
}

test "throw makes the rest of the block unreachable" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    // Nothing produces the i32 result: `throw` has to leave the block in the
    // polymorphic regime for this to type-check, exactly as `br` does.
    var module = try Parser.parseModule(alloc,
        \\(module (tag $e)
        \\  (func (result i32) (throw $e)))
    );
    defer module.deinit();
    try validate(&module, .{});
}

test "throw resolves a tag parameter's concrete type index" {
    // The value types alone say `(ref $a)` and `(ref $b)` are both a
    // non-null concrete ref; only the type index beside them tells the two
    // apart, and that index lives in the type section, not on the tag. Both
    // signatures are spelled as explicit `(type ...)` declarations so that
    // the function's own type is not folded together with the tag's.
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    var ok = try Parser.parseModule(alloc,
        \\(module
        \\  (type $a (func)) (type $b (func (param i32)))
        \\  (type $ta (func (param (ref $a)))) (type $tb (func (param (ref $b))))
        \\  (tag $e (type $tb))
        \\  (func (type $tb) (local.get 0) (throw $e)))
    );
    defer ok.deinit();
    try validate(&ok, .{});

    var mismatched = try Parser.parseModule(alloc,
        \\(module
        \\  (type $a (func)) (type $b (func (param i32)))
        \\  (type $ta (func (param (ref $a)))) (type $tb (func (param (ref $b))))
        \\  (tag $e (type $tb))
        \\  (func (type $ta) (local.get 0) (throw $e)))
    );
    defer mismatched.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&mismatched, .{}));
}

test "throw_ref pops an exnref and makes the rest unreachable" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    // Nothing produces the i32; `throw_ref` has to leave the block
    // polymorphic for this to type-check.
    var ok = try Parser.parseModule(alloc,
        \\(module (func (param exnref) (result i32) (local.get 0) (throw_ref)))
    );
    defer ok.deinit();
    try validate(&ok, .{});

    var wrong = try Parser.parseModule(alloc,
        \\(module (func (param i32) (local.get 0) (throw_ref)))
    );
    defer wrong.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wrong, .{}));

    var empty = try Parser.parseModule(alloc,
        \\(module (func (throw_ref)))
    );
    defer empty.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&empty, .{}));
}

test "try_table catch delivers the tag's parameters to its label" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    var ok = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32))
        \\  (func (block $l (result i32)
        \\    (try_table (result i32) (catch $e $l) (i32.const 0))) (drop)))
    );
    defer ok.deinit();
    try validate(&ok, .{});

    // Label takes an f32 where the tag delivers an i32. Both are one-element
    // labels, so only a type-aware check rejects this.
    var wrong_type = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32))
        \\  (func (block $l (result f32)
        \\    (try_table (result f32) (catch $e $l) (f32.const 0))) (drop)))
    );
    defer wrong_type.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wrong_type, .{}));

    // catch_all delivers nothing, so a label expecting a value is wrong.
    var all_with_results = try Parser.parseModule(alloc,
        \\(module (tag $e)
        \\  (func (block $l (result i32)
        \\    (try_table (result i32) (catch_all $l) (i32.const 0))) (drop)))
    );
    defer all_with_results.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&all_with_results, .{}));
}

test "try_table _ref clauses append an exnref to what the label receives" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    var catch_ref = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32))
        \\  (func (block $l (result i32 exnref)
        \\    (try_table (result i32 exnref) (catch_ref $e $l)
        \\      (i32.const 0) (unreachable))) (drop) (drop)))
    );
    defer catch_ref.deinit();
    try validate(&catch_ref, .{});

    // Same clause, label missing the trailing exnref.
    var missing = try Parser.parseModule(alloc,
        \\(module (tag $e (param i32))
        \\  (func (block $l (result i32)
        \\    (try_table (result i32) (catch_ref $e $l) (i32.const 0))) (drop)))
    );
    defer missing.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&missing, .{}));

    var catch_all_ref = try Parser.parseModule(alloc,
        \\(module (tag $e)
        \\  (func (block $l (result exnref)
        \\    (try_table (result exnref) (catch_all_ref $l) (unreachable))) (drop)))
    );
    defer catch_all_ref.deinit();
    try validate(&catch_all_ref, .{});

    // catch_all_ref still delivers one value, so an empty label is wrong.
    var all_ref_empty = try Parser.parseModule(alloc,
        \\(module (tag $e) (func (block $l (try_table (catch_all_ref $l) (nop)))))
    );
    defer all_ref_empty.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&all_ref_empty, .{}));
}

test "a try_table catch label is resolved in the enclosing context" {
    // The clause's label index counts from outside `try_table`, not inside
    // it, so depth 0 here is the enclosing block. Off by one and depth 0
    // would name `try_table` itself, whose label types are `(result i32)`
    // rather than the block's `(result i64)` -- distinguishable only because
    // the two differ.
    const alloc = std.testing.allocator;
    //  block(i64) { try_table(i32) catch_all -> depth 0 }
    const body = [_]u8{
        0x02, 0x7e, // block (result i64)
        0x1f, 0x7f, 0x01, 0x02, 0x00, // try_table (result i32), 1 clause: catch_all depth 0
        0x41, 0x00, // i32.const 0
        0x0b, // end try_table
        0x1a, // drop
        0x42, 0x00, // i64.const 0
        0x0b, // end block
        0x1a, // drop
        0x0b, // end function
    };
    var module = try testModuleWithBody(alloc, &body);
    defer module.deinit();
    // Depth 0 is the i64 block, which catch_all (delivering nothing) cannot
    // branch to.
    try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
}

test "try_table rejects a bad tag index, label depth and clause kind" {
    const alloc = std.testing.allocator;

    const bad_tag = [_]u8{ 0x1f, 0x40, 0x01, 0x00, 0x07, 0x00, 0x0b, 0x0b };
    var m1 = try testModuleWithBody(alloc, &bad_tag);
    defer m1.deinit();
    try std.testing.expectError(error.InvalidTagIndex, validate(&m1, .{}));

    const bad_depth = [_]u8{ 0x1f, 0x40, 0x01, 0x02, 0x7f, 0x0b, 0x0b };
    var m2 = try testModuleWithBody(alloc, &bad_depth);
    defer m2.deinit();
    try std.testing.expectError(error.InvalidLabelIndex, validate(&m2, .{}));

    const bad_kind = [_]u8{ 0x1f, 0x40, 0x01, 0x04, 0x00, 0x0b, 0x0b };
    var m3 = try testModuleWithBody(alloc, &bad_kind);
    defer m3.deinit();
    try std.testing.expectError(error.InvalidCatchKind, validate(&m3, .{}));

    const truncated = [_]u8{ 0x1f, 0x40, 0x01 };
    var m4 = try testModuleWithBody(alloc, &truncated);
    defer m4.deinit();
    try std.testing.expectError(error.UnexpectedEnd, validate(&m4, .{}));
}

test "try_table is otherwise an ordinary block" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");

    var ok = try Parser.parseModule(alloc,
        \\(module (func (result i64)
        \\  i32.const 1
        \\  try_table (param i32) (result i64) drop i64.const 2 end))
    );
    defer ok.deinit();
    try validate(&ok, .{});

    // Body does not produce the declared result.
    var bad = try Parser.parseModule(alloc,
        \\(module (func (result i64) try_table (result i64) nop end))
    );
    defer bad.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&bad, .{}));
}

test "a block may return any single-byte value type" {
    // The block-type table was a hand-written list of six; every other
    // single-byte type -- exnref, anyref, eqref, i31ref, structref,
    // arrayref and the four null bottoms -- silently became "no result", so
    // a block declared to return one was validated as returning nothing.
    const alloc = std.testing.allocator;
    const cases = [_]struct { byte: u8, name: []const u8 }{
        .{ .byte = 0x69, .name = "exnref" },
        .{ .byte = 0x6e, .name = "anyref" },
        .{ .byte = 0x6d, .name = "eqref" },
        .{ .byte = 0x6c, .name = "i31ref" },
        .{ .byte = 0x6b, .name = "structref" },
        .{ .byte = 0x6a, .name = "arrayref" },
        .{ .byte = 0x71, .name = "nullref" },
        .{ .byte = 0x73, .name = "nullfuncref" },
        .{ .byte = 0x72, .name = "nullexternref" },
        .{ .byte = 0x74, .name = "nullexnref" },
    };
    for (cases) |c| {
        // block (result T) { } end -- the empty body cannot supply the
        // declared result, so this must be rejected.
        const body = [_]u8{ 0x02, c.byte, 0x0b, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        if (validate(&module, .{})) |_| {
            std.debug.print("block (result {s}) was validated as returning nothing\n", .{c.name});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.TypeMismatch, err);
    }
}

// ── Block signatures wider than one byte (issue #384) ───────────────────

/// A module with `empty_types` empty function types, then `(func (result
/// i32))`, and one function of the first type whose body is `body`. The
/// `(result i32)` type is the last one, so its index is `empty_types`.
fn testModuleWithTypeCountAndBody(
    alloc: std.mem.Allocator,
    empty_types: usize,
    body: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    for (0..empty_types) |_| try appendFuncTypeForTest(&module, &.{}, &.{}, &.{}, &.{});
    try appendFuncTypeForTest(&module, &.{}, &.{.i32}, &.{}, &.{});
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

test "a block signature may be a type index that needs more than one byte" {
    // Type index 64 is `c0 00` as an s33. Reading only `c0` left `00` to be
    // decoded as an instruction and the rest of the body at the wrong
    // offset. `block`, `loop` and `if` share the reader, so all three are
    // exercised.
    const alloc = std.testing.allocator;
    const bodies = [_][]const u8{
        // block (type 64) (i32.const 1) end drop end
        &.{ 0x02, 0xc0, 0x00, 0x41, 0x01, 0x0b, 0x1a, 0x0b },
        // loop (type 64) (i32.const 1) end drop end
        &.{ 0x03, 0xc0, 0x00, 0x41, 0x01, 0x0b, 0x1a, 0x0b },
        // (i32.const 0) if (type 64) (i32.const 1) else (i32.const 2) end drop end
        &.{ 0x41, 0x00, 0x04, 0xc0, 0x00, 0x41, 0x01, 0x05, 0x41, 0x02, 0x0b, 0x1a, 0x0b },
    };
    for (bodies) |body| {
        var module = try testModuleWithTypeCountAndBody(alloc, 64, body);
        defer module.deinit();
        try validate(&module, .{});
    }
}

test "a try_table signature may be a type index that needs more than one byte" {
    // e53 of the fixed wasm-smith corpus: `try_table (type 64)`, the only
    // one of the 200 corpus binaries `wabt module validate` rejected.
    const alloc = std.testing.allocator;
    // try_table (type 64) 0-clauses (i32.const 1) end drop end
    const body = [_]u8{ 0x1f, 0xc0, 0x00, 0x00, 0x41, 0x01, 0x0b, 0x1a, 0x0b };
    var module = try testModuleWithTypeCountAndBody(alloc, 64, &body);
    defer module.deinit();
    try validate(&module, .{});
}

test "a block signature may be a two-byte 0x63/0x64 reference type" {
    // `0x63`/`0x64` are prefixes, not types: the heap type after them is
    // part of the value type. Consuming only the prefix desynchronised the
    // body -- for `(ref null extern)` the `6f` left behind reads as
    // `i32.rem_u`.
    const alloc = std.testing.allocator;

    // block (result (ref null extern)) (ref.null extern) end drop end
    {
        const body = [_]u8{ 0x02, 0x63, 0x6f, 0xd0, 0x6f, 0x0b, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try validate(&module, .{});
    }

    // block (result (ref null 0)) (ref.null 0) end drop end -- a concrete
    // heap type, which has to travel beside the value type.
    {
        const body = [_]u8{ 0x02, 0x63, 0x00, 0xd0, 0x00, 0x0b, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try validate(&module, .{});
    }

    // (func (param (ref 0))) with
    // block (result (ref 0)) (local.get 0) end drop end -- the non-nullable
    // prefix, and a result the block really has to supply.
    {
        const body = [_]u8{ 0x02, 0x64, 0x00, 0x20, 0x00, 0x0b, 0x1a, 0x0b };
        var module = Mod.Module.init(alloc);
        defer module.deinit();
        try appendFuncTypeForTest(&module, &.{}, &.{}, &.{}, &.{});
        try appendFuncTypeForTest(&module, &.{.concrete_ref}, &.{}, &.{0}, &.{});
        try module.funcs.append(alloc, .{
            .decl = .{ .type_var = .{ .index = 1 } },
            .code_bytes = &body,
        });
        try validate(&module, .{});
    }

    // The concrete index is kept, not flattened: a block declared to return
    // `(ref null 1)` is not satisfied by a `(ref null 0)`.
    {
        const body = [_]u8{ 0x02, 0x63, 0x01, 0xd0, 0x00, 0x0b, 0x1a, 0x0b };
        var module = Mod.Module.init(alloc);
        defer module.deinit();
        try appendFuncTypeForTest(&module, &.{}, &.{}, &.{}, &.{});
        try appendFuncTypeForTest(&module, &.{.i32}, &.{}, &.{}, &.{});
        try module.funcs.append(alloc, .{
            .decl = .{ .type_var = .{ .index = 0 } },
            .code_bytes = &body,
        });
        try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
    }
}

test "a malformed block signature is rejected, not read as an empty one" {
    // Every one of these used to fall back to "no parameters, no results",
    // which both accepted a module it should not have and hid the real
    // shape of the body from everything after it.
    const alloc = std.testing.allocator;

    // A type index past the end of the type section.
    {
        // block (type 64) ... with only 2 types in the module
        const body = [_]u8{ 0x02, 0xc0, 0x00, 0x41, 0x01, 0x0b, 0x1a, 0x0b };
        var module = try testModuleWithTypeCountAndBody(alloc, 1, &body);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }

    // A type index that names a struct type. A block signature is a
    // function type; nothing else is a signature.
    {
        const body = [_]u8{ 0x02, 0x01, 0x0b, 0x0b };
        var module = Mod.Module.init(alloc);
        defer module.deinit();
        try appendFuncTypeForTest(&module, &.{}, &.{}, &.{}, &.{});
        try module.module_types.append(alloc, .{ .struct_type = .{ .fields = .empty } });
        try module.funcs.append(alloc, .{
            .decl = .{ .type_var = .{ .index = 0 } },
            .code_bytes = &body,
        });
        try std.testing.expectError(error.TypeMismatch, validate(&module, .{}));
    }

    // `0x60` is the function-type marker, not a value type, and as an s33 it
    // is negative, so it is not a type index either.
    {
        const body = [_]u8{ 0x02, 0x60, 0x0b, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }

    // A body that stops on the signature, and one that stops inside a
    // multi-byte index.
    for ([_][]const u8{ &.{0x02}, &.{ 0x02, 0xc0 } }) |body| {
        var module = try testModuleWithBody(alloc, body);
        defer module.deinit();
        try std.testing.expectError(error.UnexpectedEnd, validate(&module, .{}));
    }

    // `0x63` with a heap type that names no type, and `0x64` with none at
    // all.
    for ([_][]const u8{ &.{ 0x02, 0x63, 0x09, 0x0b, 0x0b }, &.{ 0x02, 0x64 } }) |body| {
        var module = try testModuleWithBody(alloc, body);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }
}

test "a block signature is an s33, and five bytes is as wide as one gets" {
    // Padding is legal up to the width of the encoding and no further: 33
    // bits do not reach a sixth byte, so a signature written in six is
    // malformed. Reading the index as an s64 accepted up to ten -- wasm-tools
    // 1.250.0 rejects every one of them.
    const alloc = std.testing.allocator;

    // block (type 0), padded to the full five bytes: valid.
    {
        const body = [_]u8{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0b, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try validate(&module, .{});
    }

    // The same index in six and in ten bytes, and a fifth byte that carries
    // bits past the 33rd.
    const malformed = [_][]const u8{
        &.{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0b, 0x0b },
        &.{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x0b, 0x0b },
        &.{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x10, 0x0b, 0x0b },
    };
    for (malformed) |body| {
        var module = try testModuleWithBody(alloc, body);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }
}

test "a heap type is an s33 too, and no wider" {
    // The heap type after `0x63`/`0x64` and the operand of `ref.null` share
    // one reader, so they share the width rule; both were reachable from
    // this defect.
    const alloc = std.testing.allocator;

    // Padded to five bytes: `block (result (ref null 0))` and `ref.null 0`.
    {
        const body = [_]u8{
            0x02, 0x63, 0x80, 0x80, 0x80, 0x80, 0x00,
            0xd0, 0x80, 0x80, 0x80, 0x80, 0x00,
            0x0b, 0x1a, 0x0b,
        };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try validate(&module, .{});
    }

    // Six bytes for the heap type of a block signature, of a `ref.null` in a
    // body, and of a `ref.null` in a global's initialiser.
    {
        const body = [_]u8{ 0x02, 0x63, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0xd0, 0x00, 0x0b, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }
    {
        const body = [_]u8{ 0xd0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x1a, 0x0b };
        var module = try testModuleWithBody(alloc, &body);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }
    {
        const init = [_]u8{ 0xd0, 0xf0, 0xff, 0xff, 0xff, 0xff, 0x7f, 0x0b };
        var module = try testModuleWithGlobal(alloc, .funcref, &init);
        defer module.deinit();
        try std.testing.expectError(error.InvalidTypeIndex, validate(&module, .{}));
    }
}

test "packed types are valid as storage types and nowhere else" {
    const alloc = std.testing.allocator;

    // An array of `(mut i8)` is well-formed: fields and array elements are
    // storage types, so the packed types belong there.
    var packed_array = Mod.Module.init(alloc);
    defer packed_array.deinit();
    try packed_array.module_types.append(alloc, .{
        .array_type = .{ .field = .{ .@"type" = .i8, .mutable = true } },
    });
    try packed_array.type_meta.append(alloc, .{ .kind = .array });
    try validate(&packed_array, .{});

    // As is an `i16` struct field.
    var packed_struct = Mod.Module.init(alloc);
    defer packed_struct.deinit();
    var fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
    try fields.append(alloc, .{ .@"type" = .i16 });
    try packed_struct.module_types.append(alloc, .{ .struct_type = .{ .fields = fields } });
    try packed_struct.type_meta.append(alloc, .{ .kind = .struct_ });
    try validate(&packed_struct, .{});

    // A packed type is not a value type, so it cannot be a parameter.
    var packed_param = Mod.Module.init(alloc);
    defer packed_param.deinit();
    try appendFuncTypeForTest(&packed_param, &.{.i8}, &.{}, &.{}, &.{});
    try std.testing.expectError(error.InvalidTypeIndex, validate(&packed_param, .{}));
}

// ── Constant expression tests ───────────────────────────────────────────

/// A module with one defined global of `vt`, initialised by `init`.
fn testModuleWithGlobal(alloc: std.mem.Allocator, vt: types.ValType, init: []const u8) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.globals.append(alloc, .{
        .type = .{ .val_type = vt, .mutability = .immutable },
        .init_expr_bytes = init,
    });
    return module;
}

test "extended-const arithmetic initialises a global" {
    const alloc = std.testing.allocator;
    // `(global i32 (i32.add (i32.const 1) (i32.const 2)))`. Only the const
    // instructions were accepted, so every module using extended-const was
    // rejected -- 98 of them across the test corpora.
    const init = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6a, 0x0b };
    var m = try testModuleWithGlobal(alloc, .i32, &init);
    defer m.deinit();
    try validate(&m, .{});

    // It is a feature, and stating that the feature is off must bring the
    // old answer back rather than being quietly ignored.
    try std.testing.expectError(
        error.ConstantExprRequired,
        validate(&m, .{ .features = .{ .extended_const = false } }),
    );
}

test "only add, sub and mul are constant" {
    const alloc = std.testing.allocator;
    // i32.mul is in extended-const...
    const mul = [_]u8{ 0x41, 0x02, 0x41, 0x03, 0x6c, 0x0b };
    var ok = try testModuleWithGlobal(alloc, .i32, &mul);
    defer ok.deinit();
    try validate(&ok, .{});

    // ...but i32.div_u (0x6e) is not, and neither is anything else. Accepting
    // the whole arithmetic range would be the easy mistake to make here.
    const div = [_]u8{ 0x41, 0x02, 0x41, 0x03, 0x6e, 0x0b };
    var bad = try testModuleWithGlobal(alloc, .i32, &div);
    defer bad.deinit();
    try std.testing.expectError(error.ConstantExprRequired, validate(&bad, .{}));
}

test "a constant expression type-checks its operands and its result" {
    const alloc = std.testing.allocator;
    // i64 operands under an i32.add. Counting pushes rather than tracking
    // types would let this through.
    const wrong_operands = [_]u8{ 0x42, 0x01, 0x42, 0x02, 0x6a, 0x0b };
    var a = try testModuleWithGlobal(alloc, .i32, &wrong_operands);
    defer a.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&a, .{}));

    // Only one operand for an instruction that needs two.
    const too_few = [_]u8{ 0x41, 0x01, 0x6a, 0x0b };
    var b = try testModuleWithGlobal(alloc, .i32, &too_few);
    defer b.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&b, .{}));

    // An operand left over at the end.
    const leftover = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x41, 0x03, 0x6a, 0x0b };
    var c = try testModuleWithGlobal(alloc, .i32, &leftover);
    defer c.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&c, .{}));

    // The right shape, but the wrong type for the global it initialises.
    const wrong_result = [_]u8{ 0x41, 0x01, 0x41, 0x02, 0x6a, 0x0b };
    var d = try testModuleWithGlobal(alloc, .i64, &wrong_result);
    defer d.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&d, .{}));
}

test "v128.const initialises a global" {
    const alloc = std.testing.allocator;
    // 0xfd 0x0c followed by sixteen bytes. The whole SIMD prefix was
    // rejected, so a v128 global could be printed but never read back.
    const init = [_]u8{0xfd} ++ [_]u8{0x0c} ++ [_]u8{0} ** 16 ++ [_]u8{0x0b};
    var m = try testModuleWithGlobal(alloc, .v128, &init);
    defer m.deinit();
    try validate(&m, .{});

    // v128.const is the only constant SIMD instruction; i8x16.splat (0x0f)
    // is not one.
    const splat = [_]u8{ 0xfd, 0x0f, 0x0b };
    var bad = try testModuleWithGlobal(alloc, .v128, &splat);
    defer bad.deinit();
    try std.testing.expectError(error.ConstantExprRequired, validate(&bad, .{}));
}

test "a constant expression reads an immutable global, imported or not" {
    const alloc = std.testing.allocator;
    // Global 1 is initialised from global 0, which is defined here rather
    // than imported. Reading a locally defined global is what the GC
    // proposal relaxed; before it, only imports were in reach.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    const first = [_]u8{ 0x41, 0x07, 0x0b };
    const second = [_]u8{ 0x23, 0x00, 0x0b };
    try m.globals.append(alloc, .{
        .type = .{ .val_type = .i32, .mutability = .immutable },
        .init_expr_bytes = &first,
    });
    try m.globals.append(alloc, .{
        .type = .{ .val_type = .i32, .mutability = .immutable },
        .init_expr_bytes = &second,
    });
    try validate(&m, .{});
    try std.testing.expectError(
        error.ConstantExprRequired,
        validate(&m, .{ .features = .{ .gc = false } }),
    );

    // A global may still only read one declared before it, whatever the
    // feature says: global 0 cannot read global 1.
    var fwd = Mod.Module.init(alloc);
    defer fwd.deinit();
    const reads_later = [_]u8{ 0x23, 0x01, 0x0b };
    try fwd.globals.append(alloc, .{
        .type = .{ .val_type = .i32, .mutability = .immutable },
        .init_expr_bytes = &reads_later,
    });
    try fwd.globals.append(alloc, .{
        .type = .{ .val_type = .i32, .mutability = .immutable },
        .init_expr_bytes = &first,
    });
    try std.testing.expectError(error.InvalidGlobalIndex, validate(&fwd, .{}));
}

test "a table's initializer is a constant expression of its element type" {
    const alloc = std.testing.allocator;

    // The initializer used to be checked by looking at its first byte, which
    // could only ever catch a numeric constant and a `global.get`. It is an
    // ordinary constant expression, so it is checked like one: `ref.null`
    // has to name a heap type the table accepts, and `ref.func` has to name
    // a function.
    const cases = [_]struct {
        elem: types.ValType,
        type_idx: u32 = 0xFFFFFFFF,
        init: []const u8,
        err: ?anyerror = null,
    }{
        .{ .elem = .funcref, .init = &.{ 0xd0, 0x70 } }, // ref.null func
        .{ .elem = .externref, .init = &.{ 0xd0, 0x6f } }, // ref.null extern
        .{ .elem = .anyref, .init = &.{ 0xd0, 0x71 } }, // ref.null none <: anyref
        .{ .elem = .funcref, .init = &.{ 0xd0, 0x6f }, .err = error.TypeMismatch },
        .{ .elem = .externref, .init = &.{ 0xd0, 0x70 }, .err = error.TypeMismatch },
        .{ .elem = .funcref, .init = &.{ 0xd2, 0x00 } }, // ref.func 0
        .{ .elem = .ref_func, .init = &.{ 0xd2, 0x00 } },
        .{ .elem = .concrete_ref_null, .type_idx = 0, .init = &.{ 0xd2, 0x00 } },
        .{ .elem = .concrete_ref, .type_idx = 0, .init = &.{ 0xd2, 0x00 } },
        .{ .elem = .concrete_ref_null, .type_idx = 0, .init = &.{ 0xd0, 0x00 } }, // ref.null 0
        .{ .elem = .funcref, .init = &.{ 0xd2, 0x07 }, .err = error.InvalidFuncIndex },
        .{ .elem = .externref, .init = &.{ 0xd2, 0x00 }, .err = error.TypeMismatch },
        .{ .elem = .funcref, .init = &.{ 0x41, 0x00 }, .err = error.TypeMismatch }, // i32.const 0
        .{ .elem = .funcref, .init = &.{ 0x20, 0x00 }, .err = error.ConstantExprRequired }, // local.get 0
        // Two values where the table wants one.
        .{ .elem = .funcref, .init = &.{ 0xd2, 0x00, 0xd0, 0x70 }, .err = error.TypeMismatch },
    };

    for (cases) |case| {
        var m = Mod.Module.init(alloc);
        defer m.deinit();
        try m.module_types.append(alloc, .{ .func_type = .{} });
        try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
        try m.tables.append(alloc, .{
            .type = .{ .elem_type = case.elem, .limits = .{ .initial = 1 } },
            .type_idx = case.type_idx,
            .init_expr_bytes = case.init,
        });
        if (case.err) |e| {
            try std.testing.expectError(e, validate(&m, .{}));
        } else {
            try validate(&m, .{});
        }
    }
}

test "a table's initializer reads an imported global and no other" {
    const alloc = std.testing.allocator;

    // The table section precedes the global section, so a table initializer
    // can only reach a global the module imports -- the GC relaxation that
    // lets a global read a global defined before it does not reach here.
    const get0 = [_]u8{ 0x23, 0x00 };

    var imported = Mod.Module.init(alloc);
    defer imported.deinit();
    try imported.globals.append(alloc, .{
        .type = .{ .val_type = .externref, .mutability = .immutable },
        .is_import = true,
    });
    imported.num_global_imports = 1;
    try imported.tables.append(alloc, .{
        .type = .{ .elem_type = .externref, .limits = .{ .initial = 1 } },
        .init_expr_bytes = &get0,
    });
    try validate(&imported, .{});

    // Same module, mutable global: a mutable global is not a constant.
    var mutable = Mod.Module.init(alloc);
    defer mutable.deinit();
    try mutable.globals.append(alloc, .{
        .type = .{ .val_type = .externref, .mutability = .mutable },
        .is_import = true,
    });
    mutable.num_global_imports = 1;
    try mutable.tables.append(alloc, .{
        .type = .{ .elem_type = .externref, .limits = .{ .initial = 1 } },
        .init_expr_bytes = &get0,
    });
    try std.testing.expectError(error.ConstantExprRequired, validate(&mutable, .{}));

    // Same module again, with the global defined here rather than imported:
    // it is not in scope yet.
    var defined = Mod.Module.init(alloc);
    defer defined.deinit();
    const null_extern = [_]u8{ 0xd0, 0x6f };
    try defined.globals.append(alloc, .{
        .type = .{ .val_type = .externref, .mutability = .immutable },
        .init_expr_bytes = &null_extern,
    });
    try defined.tables.append(alloc, .{
        .type = .{ .elem_type = .externref, .limits = .{ .initial = 1 } },
        .init_expr_bytes = &get0,
    });
    try std.testing.expectError(error.InvalidGlobalIndex, validate(&defined, .{}));

    // An imported global of the wrong type is still the wrong type.
    var wrong = Mod.Module.init(alloc);
    defer wrong.deinit();
    try wrong.globals.append(alloc, .{
        .type = .{ .val_type = .funcref, .mutability = .immutable },
        .is_import = true,
    });
    wrong.num_global_imports = 1;
    try wrong.tables.append(alloc, .{
        .type = .{ .elem_type = .externref, .limits = .{ .initial = 1 } },
        .init_expr_bytes = &get0,
    });
    try std.testing.expectError(error.TypeMismatch, validate(&wrong, .{}));
}

test "a table whose element type has no null is initialised or imported" {
    const alloc = std.testing.allocator;

    // Every table with a non-nullable element type was rejected, initializer
    // or not, so the modules the initializer exists for could not be
    // expressed at all. What is invalid is a *defined* table that says
    // nothing about what fills it.
    const ref_func = [_]u8{ 0xd2, 0x00 };
    const cases = [_]struct {
        elem: types.ValType,
        type_idx: u32 = 0xFFFFFFFF,
        init: []const u8 = &.{},
        is_import: bool = false,
        err: ?anyerror = null,
    }{
        .{ .elem = .ref_func, .init = &ref_func },
        .{ .elem = .concrete_ref, .type_idx = 0, .init = &ref_func },
        .{ .elem = .ref_func, .err = error.TypeMismatch },
        .{ .elem = .concrete_ref, .type_idx = 0, .err = error.TypeMismatch },
        .{ .elem = .ref_func, .is_import = true },
        .{ .elem = .concrete_ref, .type_idx = 0, .is_import = true },
        // A nullable element type needs nothing said about it.
        .{ .elem = .funcref },
        .{ .elem = .concrete_ref_null, .type_idx = 0 },
    };

    for (cases) |case| {
        var m = Mod.Module.init(alloc);
        defer m.deinit();
        try m.module_types.append(alloc, .{ .func_type = .{} });
        try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
        try m.tables.append(alloc, .{
            .type = .{ .elem_type = case.elem, .limits = .{ .initial = 1 } },
            .type_idx = case.type_idx,
            .init_expr_bytes = case.init,
            .is_import = case.is_import,
        });
        if (case.is_import) m.num_table_imports = 1;
        if (case.err) |e| {
            try std.testing.expectError(e, validate(&m, .{}));
        } else {
            try validate(&m, .{});
        }
    }
}

test "an element expression ends where the instruction ends" {
    const alloc = std.testing.allocator;
    // Expressions were split at the first 0x0b byte, which is not
    // necessarily an `end`: `ref.func 11` encodes as d2 0b, so a segment
    // referring to function 11 was cut in half and the halves type-checked
    // as if they were whole expressions.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    for (0..13) |_| {
        try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    }
    try m.tables.append(alloc, .{
        .type = .{ .elem_type = .funcref, .limits = .{ .initial = 20 } },
    });
    const offset = [_]u8{ 0x41, 0x00, 0x0b };
    // ref.func 11, end, ref.func 1, end
    const exprs = [_]u8{ 0xd2, 0x0b, 0x0b, 0xd2, 0x01, 0x0b };
    try m.elem_segments.append(alloc, .{
        .kind = .active,
        .elem_type = .funcref,
        .offset_expr_bytes = &offset,
        .elem_expr_bytes = &exprs,
        .elem_expr_count = 2,
        .uses_elem_exprs = true,
    });
    try validate(&m, .{});
}

// ── Index type tests ────────────────────────────────────────────────────

/// A module with one memory of the given index type and one function.
fn testModuleWith64Memory(alloc: std.mem.Allocator, is_64: bool, body: []const u8) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    try module.memories.append(alloc, .{
        .type = .{ .limits = .{ .initial = 1, .is_64 = is_64 } },
    });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

/// A module with one table of the given index type and one function.
fn testModuleWith64Table(alloc: std.mem.Allocator, is_64: bool, body: []const u8) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    try module.tables.append(alloc, .{
        .type = .{ .elem_type = .funcref, .limits = .{ .initial = 4, .is_64 = is_64 } },
    });
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

test "a memory address is of the memory's index type" {
    const alloc = std.testing.allocator;
    // i64.const 0; i32.load; drop; end
    const with_i64_addr = [_]u8{ 0x42, 0x00, 0x28, 0x02, 0x00, 0x1a, 0x0b };
    // i32.const 0; i32.load; drop; end
    const with_i32_addr = [_]u8{ 0x41, 0x00, 0x28, 0x02, 0x00, 0x1a, 0x0b };

    var m64 = try testModuleWith64Memory(alloc, true, &with_i64_addr);
    defer m64.deinit();
    try validate(&m64, .{});

    // The address widens with the memory, so an i32 address no longer suits
    // a 64-bit one...
    var narrow = try testModuleWith64Memory(alloc, true, &with_i32_addr);
    defer narrow.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&narrow, .{}));

    // ...and an i64 address still does not suit a 32-bit one.
    var m32 = try testModuleWith64Memory(alloc, false, &with_i64_addr);
    defer m32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m32, .{}));

    var ok32 = try testModuleWith64Memory(alloc, false, &with_i32_addr);
    defer ok32.deinit();
    try validate(&ok32, .{});

    // Storing indexes the memory just as loading does.
    // i64.const 0; i32.const 0; i32.store; end
    const store_i64_addr = [_]u8{ 0x42, 0x00, 0x41, 0x00, 0x36, 0x02, 0x00, 0x0b };
    var s64 = try testModuleWith64Memory(alloc, true, &store_i64_addr);
    defer s64.deinit();
    try validate(&s64, .{});

    var s32 = try testModuleWith64Memory(alloc, false, &store_i64_addr);
    defer s32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&s32, .{}));
}

test "memory.size and memory.grow speak the memory's index type" {
    const alloc = std.testing.allocator;
    // memory.size; i64.eqz; drop; end -- i64.eqz only accepts an i64, so it
    // is what proves the result widened rather than merely being ignored.
    const size64 = [_]u8{ 0x3f, 0x00, 0x50, 0x1a, 0x0b };
    var m = try testModuleWith64Memory(alloc, true, &size64);
    defer m.deinit();
    try validate(&m, .{});

    var m32 = try testModuleWith64Memory(alloc, false, &size64);
    defer m32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&m32, .{}));

    // i64.const 1; memory.grow; i64.eqz; drop; end -- grow takes and returns
    // the index type.
    const grow64 = [_]u8{ 0x42, 0x01, 0x40, 0x00, 0x50, 0x1a, 0x0b };
    var g = try testModuleWith64Memory(alloc, true, &grow64);
    defer g.deinit();
    try validate(&g, .{});

    // Explicit non-zero indices select that memory rather than being rejected
    // as a legacy reserved zero byte.
    const size_second = [_]u8{ 0x3f, 0x01, 0x50, 0x1a, 0x0b };
    var second = try testModuleWith64Memory(alloc, false, &size_second);
    defer second.deinit();
    try second.memories.append(alloc, .{
        .type = .{ .limits = .{ .initial = 1, .is_64 = true } },
    });
    try validate(&second, .{});

    const grow_second = [_]u8{ 0x42, 0x01, 0x40, 0x01, 0x50, 0x1a, 0x0b };
    var grow = try testModuleWith64Memory(alloc, false, &grow_second);
    defer grow.deinit();
    try grow.memories.append(alloc, .{
        .type = .{ .limits = .{ .initial = 1, .is_64 = true } },
    });
    try validate(&grow, .{});

    const invalid = [_]u8{ 0x3f, 0x02, 0x1a, 0x0b };
    var bad = try testModuleWith64Memory(alloc, false, &invalid);
    defer bad.deinit();
    try bad.memories.append(alloc, .{
        .type = .{ .limits = .{ .initial = 1, .is_64 = true } },
    });
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&bad, .{}));
}

test "a table index is of the table's index type" {
    const alloc = std.testing.allocator;
    // table.size; i64.eqz; drop; end
    const size64 = [_]u8{ 0xfc, 0x10, 0x00, 0x50, 0x1a, 0x0b };
    var t = try testModuleWith64Table(alloc, true, &size64);
    defer t.deinit();
    try validate(&t, .{});

    var t32 = try testModuleWith64Table(alloc, false, &size64);
    defer t32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&t32, .{}));

    // i64.const 0; table.get 0; drop; end
    const get64 = [_]u8{ 0x42, 0x00, 0x25, 0x00, 0x1a, 0x0b };
    var g = try testModuleWith64Table(alloc, true, &get64);
    defer g.deinit();
    try validate(&g, .{});

    var g32 = try testModuleWith64Table(alloc, false, &get64);
    defer g32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&g32, .{}));
}

test "a segment offset is of the index type of what it indexes" {
    const alloc = std.testing.allocator;
    // The offset indexes the memory or table, so it widens with it. It was
    // required to be i32 whatever the memory or table said, which rejected
    // every active segment of a 64-bit one.
    const off64 = [_]u8{ 0x42, 0x00, 0x0b }; // i64.const 0, end
    const off32 = [_]u8{ 0x41, 0x00, 0x0b }; // i32.const 0, end

    var mem = Mod.Module.init(alloc);
    defer mem.deinit();
    try mem.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1, .is_64 = true } } });
    try mem.data_segments.append(alloc, .{ .kind = .active, .offset_expr_bytes = &off64 });
    try validate(&mem, .{});

    var mem_narrow = Mod.Module.init(alloc);
    defer mem_narrow.deinit();
    try mem_narrow.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1, .is_64 = true } } });
    try mem_narrow.data_segments.append(alloc, .{ .kind = .active, .offset_expr_bytes = &off32 });
    try std.testing.expectError(error.TypeMismatch, validate(&mem_narrow, .{}));

    var tbl = Mod.Module.init(alloc);
    defer tbl.deinit();
    try tbl.tables.append(alloc, .{
        .type = .{ .elem_type = .funcref, .limits = .{ .initial = 4, .is_64 = true } },
    });
    try tbl.elem_segments.append(alloc, .{ .kind = .active, .offset_expr_bytes = &off64 });
    try validate(&tbl, .{});

    // A 32-bit memory still wants an i32 offset, so the rule follows the
    // memory rather than simply being dropped.
    var mem32 = Mod.Module.init(alloc);
    defer mem32.deinit();
    try mem32.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1 } } });
    try mem32.data_segments.append(alloc, .{ .kind = .active, .offset_expr_bytes = &off64 });
    try std.testing.expectError(error.TypeMismatch, validate(&mem32, .{}));
}

test "a memory's index type is one fact, not two" {
    const alloc = std.testing.allocator;
    // `Memory` carried both `is_memory64` and `type.limits.is_64`. The text
    // parser set both, the binary reader only ever set the second, and the
    // bulk and vector instructions read only the first -- so a valid module
    // validated when parsed from text and was rejected when read from the
    // binary it had just been written to.
    //
    // This module is built the way the reader builds one, setting only the
    // limits. Every instruction below indexes the memory, so if any of them
    // still consulted a separate flag this would fail.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    try m.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1, .is_64 = true } } });
    const body = [_]u8{
        0x42, 0x00, 0x41, 0x00, 0x42, 0x00, 0xfc, 0x0b, 0x00, // memory.fill
        0x42, 0x00, 0x42, 0x00, 0x42, 0x00, 0xfc, 0x0a, 0x00, 0x00, // memory.copy
        0x42, 0x00, 0xfd, 0x00, 0x04, 0x00, 0x1a, // v128.load, drop
        0x42, 0x00, 0xfe, 0x10, 0x02, 0x00, 0x1a, // i32.atomic.load, drop
        0x0b,
    };
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try validate(&m, .{});
}

// ── table.init and table.copy tests ─────────────────────────────────────

/// One table of a `testTableModule`: its element type, the concrete type
/// index that element type may name, and its index type.
const TestTable = struct {
    elem: types.ValType = .funcref,
    type_idx: u32 = types.invalid_index,
    is_64: bool = false,
    /// A table whose element type has no null needs an initializer.
    init_expr_bytes: []const u8 = &.{},
};

/// One element segment of a `testTableModule`.
const TestElemSeg = struct {
    elem: types.ValType = .funcref,
    type_idx: u32 = types.invalid_index,
    kind: types.SegmentKind = .passive,
    /// Only read for an active segment, which needs an offset that
    /// type-checks against the table it is written into.
    offset_expr_bytes: []const u8 = &.{},
};

/// A module of the given tables and element segments plus one function.
/// Type 0 is `(func)`, so a table or segment naming type index 0 has a
/// concrete function reference as its element type.
fn testTableModule(
    alloc: std.mem.Allocator,
    tables: []const TestTable,
    segs: []const TestElemSeg,
    body: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    for (tables) |t| {
        try module.tables.append(alloc, .{
            .type = .{ .elem_type = t.elem, .limits = .{ .initial = 4, .is_64 = t.is_64 } },
            .type_idx = t.type_idx,
            .init_expr_bytes = t.init_expr_bytes,
        });
    }
    for (segs) |s| {
        try module.elem_segments.append(alloc, .{
            .kind = s.kind,
            .elem_type = s.elem,
            .elem_type_idx = s.type_idx,
            .offset_expr_bytes = s.offset_expr_bytes,
            .uses_elem_exprs = true,
        });
    }
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

const funcref_table = [_]TestTable{.{}};
const funcref_seg = [_]TestElemSeg{.{}};

test "table.init pops three operands" {
    const alloc = std.testing.allocator;
    // The arm read its two immediates and returned, so any stack at all --
    // an empty one included -- was accepted.
    const i32_0 = [_]u8{ 0x41, 0x00 };
    const cases = [_]struct { body: []const u8, ok: bool }{
        // table.init 0 0; end -- nothing to pop
        .{ .body = &[_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }, .ok = false },
        .{ .body = &(i32_0 ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = false },
        .{ .body = &(i32_0 ++ i32_0 ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = false },
        .{ .body = &(i32_0 ++ i32_0 ++ i32_0 ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = true },
        // A fourth operand is left behind, and the function returns nothing.
        .{ .body = &(i32_0 ** 4 ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = false },
        // f32.const 0 in each of the three positions: destination...
        .{ .body = &([_]u8{ 0x43, 0, 0, 0, 0 } ++ i32_0 ++ i32_0 ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = false },
        // ...source...
        .{ .body = &(i32_0 ++ [_]u8{ 0x43, 0, 0, 0, 0 } ++ i32_0 ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = false },
        // ...and length.
        .{ .body = &(i32_0 ++ i32_0 ++ [_]u8{ 0x43, 0, 0, 0, 0 } ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }), .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, &funcref_table, &funcref_seg, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "table.init checks the table and the element segment it names" {
    const alloc = std.testing.allocator;
    const ops = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00 };
    // table.init elem=0 table=1 -- there is no table 1.
    var bad_table = try testTableModule(alloc, &funcref_table, &funcref_seg, &(ops ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x01, 0x0b }));
    defer bad_table.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&bad_table, .{}));

    // table.init elem=1 table=0 -- there is no segment 1.
    var bad_elem = try testTableModule(alloc, &funcref_table, &funcref_seg, &(ops ++ [_]u8{ 0xfc, 0x0c, 0x01, 0x00, 0x0b }));
    defer bad_elem.deinit();
    try std.testing.expectError(error.InvalidElemIndex, validate(&bad_elem, .{}));

    // With no table at all the index is still the complaint. `tableIndexType`
    // answers i32 for a table that is not there, so checking bounds after it
    // would report a missing table as a type error.
    var no_table = try testTableModule(alloc, &.{}, &funcref_seg, &(ops ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b }));
    defer no_table.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&no_table, .{}));

    // A bad index is caught in unreachable code too, where no operand is
    // popped that could have raised the alarm instead.
    var unreachable_bad = try testTableModule(alloc, &funcref_table, &funcref_seg, &[_]u8{ 0x00, 0xfc, 0x0c, 0x01, 0x00, 0x0b });
    defer unreachable_bad.deinit();
    try std.testing.expectError(error.InvalidElemIndex, validate(&unreachable_bad, .{}));
}

test "table.init's destination follows the table's index type" {
    const alloc = std.testing.allocator;
    const table64 = [_]TestTable{.{ .is_64 = true }};
    const i32_0 = [_]u8{ 0x41, 0x00 };
    const i64_0 = [_]u8{ 0x42, 0x00 };
    const init = [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b };

    // The source offset and the length index the element segment, which is
    // never 64-bit, so they stay i32 however wide the table is.
    var ok = try testTableModule(alloc, &table64, &funcref_seg, &(i64_0 ++ i32_0 ++ i32_0 ++ init));
    defer ok.deinit();
    try validate(&ok, .{});

    var narrow_dst = try testTableModule(alloc, &table64, &funcref_seg, &(i32_0 ++ i32_0 ++ i32_0 ++ init));
    defer narrow_dst.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&narrow_dst, .{}));

    var wide_src = try testTableModule(alloc, &table64, &funcref_seg, &(i64_0 ++ i64_0 ++ i32_0 ++ init));
    defer wide_src.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_src, .{}));

    var wide_len = try testTableModule(alloc, &table64, &funcref_seg, &(i64_0 ++ i32_0 ++ i64_0 ++ init));
    defer wide_len.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_len, .{}));

    // A 32-bit table still wants an i32 destination.
    var wide_dst_32 = try testTableModule(alloc, &funcref_table, &funcref_seg, &(i64_0 ++ i32_0 ++ i32_0 ++ init));
    defer wide_dst_32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_dst_32, .{}));

    // Unreachable code supplies the missing operands but not their types: the
    // i32 length is still the length of a 64-bit table's initialisation.
    var poly = try testTableModule(alloc, &table64, &funcref_seg, &([_]u8{0x00} ++ i32_0 ++ init));
    defer poly.deinit();
    try validate(&poly, .{});

    var poly_bad = try testTableModule(alloc, &table64, &funcref_seg, &([_]u8{0x00} ++ i64_0 ++ init));
    defer poly_bad.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&poly_bad, .{}));
}

test "table.init requires the segment's elements to suit the table" {
    const alloc = std.testing.allocator;
    const ops = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00 };
    const body = ops ++ [_]u8{ 0xfc, 0x0c, 0x00, 0x00, 0x0b };
    const externref_table = [_]TestTable{.{ .elem = .externref }};
    const externref_seg = [_]TestElemSeg{.{ .elem = .externref }};
    // Type 0 is `(func)`, so `(ref null 0)` is a subtype of funcref.
    const concrete_table = [_]TestTable{.{ .elem = .concrete_ref_null, .type_idx = 0 }};
    const concrete_seg = [_]TestElemSeg{.{ .elem = .concrete_ref_null, .type_idx = 0 }};

    var mismatched = try testTableModule(alloc, &externref_table, &funcref_seg, &body);
    defer mismatched.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&mismatched, .{}));

    var matched = try testTableModule(alloc, &externref_table, &externref_seg, &body);
    defer matched.deinit();
    try validate(&matched, .{});

    // The elements are written into the table, so a segment of a subtype
    // suits it...
    var subtype = try testTableModule(alloc, &funcref_table, &concrete_seg, &body);
    defer subtype.deinit();
    try validate(&subtype, .{});

    // ...and a segment of a supertype does not.
    var supertype = try testTableModule(alloc, &concrete_table, &funcref_seg, &body);
    defer supertype.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&supertype, .{}));

    // Type compatibility is checked without popping anything, so unreachable
    // code does not excuse it.
    var poly = try testTableModule(alloc, &externref_table, &funcref_seg, &[_]u8{ 0x00, 0xfc, 0x0c, 0x00, 0x00, 0x0b });
    defer poly.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&poly, .{}));

    // Any segment may be named, whatever its kind: an active segment is
    // dropped at instantiation, which traps at run time rather than failing
    // validation. i32.const 0, end.
    const offset = [_]u8{ 0x41, 0x00, 0x0b };
    const active = [_]TestElemSeg{.{ .kind = .active, .offset_expr_bytes = &offset }};
    var active_m = try testTableModule(alloc, &funcref_table, &active, &body);
    defer active_m.deinit();
    try validate(&active_m, .{});

    const declared = [_]TestElemSeg{.{ .kind = .declared }};
    var declared_m = try testTableModule(alloc, &funcref_table, &declared, &body);
    defer declared_m.deinit();
    try validate(&declared_m, .{});
}

test "table.copy pops three operands" {
    const alloc = std.testing.allocator;
    const i32_0 = [_]u8{ 0x41, 0x00 };
    const copy = [_]u8{ 0xfc, 0x0e, 0x00, 0x00, 0x0b }; // table.copy 0 0
    const cases = [_]struct { body: []const u8, ok: bool }{
        .{ .body = &copy, .ok = false },
        .{ .body = &(i32_0 ++ copy), .ok = false },
        .{ .body = &(i32_0 ++ i32_0 ++ copy), .ok = false },
        .{ .body = &(i32_0 ++ i32_0 ++ i32_0 ++ copy), .ok = true },
        .{ .body = &([_]u8{ 0x43, 0, 0, 0, 0 } ++ i32_0 ++ i32_0 ++ copy), .ok = false },
        .{ .body = &(i32_0 ++ [_]u8{ 0x43, 0, 0, 0, 0 } ++ i32_0 ++ copy), .ok = false },
        .{ .body = &(i32_0 ++ i32_0 ++ [_]u8{ 0x43, 0, 0, 0, 0 } ++ copy), .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, &funcref_table, &.{}, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "table.copy checks both of the tables it names" {
    const alloc = std.testing.allocator;
    const ops = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00 };

    var bad_dst = try testTableModule(alloc, &funcref_table, &.{}, &(ops ++ [_]u8{ 0xfc, 0x0e, 0x01, 0x00, 0x0b }));
    defer bad_dst.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&bad_dst, .{}));

    var bad_src = try testTableModule(alloc, &funcref_table, &.{}, &(ops ++ [_]u8{ 0xfc, 0x0e, 0x00, 0x01, 0x0b }));
    defer bad_src.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&bad_src, .{}));

    var no_tables = try testTableModule(alloc, &.{}, &.{}, &(ops ++ [_]u8{ 0xfc, 0x0e, 0x00, 0x00, 0x0b }));
    defer no_tables.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&no_tables, .{}));

    var poly = try testTableModule(alloc, &funcref_table, &.{}, &[_]u8{ 0x00, 0xfc, 0x0e, 0x00, 0x01, 0x0b });
    defer poly.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&poly, .{}));
}

test "table.copy's offsets follow their tables and its length the narrower" {
    const alloc = std.testing.allocator;
    const i32_0 = [_]u8{ 0x41, 0x00 };
    const i64_0 = [_]u8{ 0x42, 0x00 };
    const mixed = [_]TestTable{ .{}, .{ .is_64 = true } }; // table 0 is 32-bit, table 1 is 64
    const both64 = [_]TestTable{ .{ .is_64 = true }, .{ .is_64 = true } };
    // table.copy dst=0 src=1, then dst=1 src=0.
    const copy_32_64 = [_]u8{ 0xfc, 0x0e, 0x00, 0x01, 0x0b };
    const copy_64_32 = [_]u8{ 0xfc, 0x0e, 0x01, 0x00, 0x0b };
    const copy_64_64 = [_]u8{ 0xfc, 0x0e, 0x00, 0x01, 0x0b };

    // Each offset is of the index type of the table it indexes, and the
    // length is of the narrower of the two -- it has to be a valid count in
    // both tables, so a copy touching any 32-bit table counts in i32.
    var d32s64 = try testTableModule(alloc, &mixed, &.{}, &(i32_0 ++ i64_0 ++ i32_0 ++ copy_32_64));
    defer d32s64.deinit();
    try validate(&d32s64, .{});

    var d64s32 = try testTableModule(alloc, &mixed, &.{}, &(i64_0 ++ i32_0 ++ i32_0 ++ copy_64_32));
    defer d64s32.deinit();
    try validate(&d64s32, .{});

    // The length does not widen with either table on its own.
    var d32s64_len64 = try testTableModule(alloc, &mixed, &.{}, &(i32_0 ++ i64_0 ++ i64_0 ++ copy_32_64));
    defer d32s64_len64.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&d32s64_len64, .{}));

    var d64s32_len64 = try testTableModule(alloc, &mixed, &.{}, &(i64_0 ++ i32_0 ++ i64_0 ++ copy_64_32));
    defer d64s32_len64.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&d64s32_len64, .{}));

    // Nor does an offset take the other table's index type.
    var swapped = try testTableModule(alloc, &mixed, &.{}, &(i64_0 ++ i32_0 ++ i32_0 ++ copy_32_64));
    defer swapped.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&swapped, .{}));

    // Only when both tables are 64-bit does the length widen.
    var wide = try testTableModule(alloc, &both64, &.{}, &(i64_0 ++ i64_0 ++ i64_0 ++ copy_64_64));
    defer wide.deinit();
    try validate(&wide, .{});

    var wide_len32 = try testTableModule(alloc, &both64, &.{}, &(i64_0 ++ i64_0 ++ i32_0 ++ copy_64_64));
    defer wide_len32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_len32, .{}));
}

test "table.copy requires the source elements to suit the destination" {
    const alloc = std.testing.allocator;
    const ops = [_]u8{ 0x41, 0x00, 0x41, 0x00, 0x41, 0x00 };
    const copy_0_1 = ops ++ [_]u8{ 0xfc, 0x0e, 0x00, 0x01, 0x0b };
    const copy_1_0 = ops ++ [_]u8{ 0xfc, 0x0e, 0x01, 0x00, 0x0b };
    const func_extern = [_]TestTable{ .{}, .{ .elem = .externref } };
    // Type 0 is `(func)`, so table 1's `(ref null 0)` is a subtype of the
    // funcref of table 0.
    const func_concrete = [_]TestTable{ .{}, .{ .elem = .concrete_ref_null, .type_idx = 0 } };
    // A non-null reference is a subtype of the nullable one, not the reverse.
    // The non-null table needs an initializer: ref.func 0, end.
    const ref_func_init = [_]u8{ 0xd2, 0x00, 0x0b };
    const null_nonnull = [_]TestTable{
        .{ .elem = .funcref },
        .{ .elem = .ref_func, .init_expr_bytes = &ref_func_init },
    };

    var unrelated = try testTableModule(alloc, &func_extern, &.{}, &copy_0_1);
    defer unrelated.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&unrelated, .{}));

    var subtype = try testTableModule(alloc, &func_concrete, &.{}, &copy_0_1);
    defer subtype.deinit();
    try validate(&subtype, .{});

    var supertype = try testTableModule(alloc, &func_concrete, &.{}, &copy_1_0);
    defer supertype.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&supertype, .{}));

    var nonnull_into_null = try testTableModule(alloc, &null_nonnull, &.{}, &copy_0_1);
    defer nonnull_into_null.deinit();
    try validate(&nonnull_into_null, .{});

    var null_into_nonnull = try testTableModule(alloc, &null_nonnull, &.{}, &copy_1_0);
    defer null_into_nonnull.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&null_into_nonnull, .{}));

    // A table is trivially compatible with itself, whatever it holds.
    const externref_table = [_]TestTable{.{ .elem = .externref }};
    var self_copy = try testTableModule(alloc, &externref_table, &.{}, &(ops ++ [_]u8{ 0xfc, 0x0e, 0x00, 0x00, 0x0b }));
    defer self_copy.deinit();
    try validate(&self_copy, .{});

    var poly = try testTableModule(alloc, &func_extern, &.{}, &[_]u8{ 0x00, 0xfc, 0x0e, 0x00, 0x01, 0x0b });
    defer poly.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&poly, .{}));
}

test "table.init and table.copy validate the same whichever front end built the module" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    const binary_reader = @import("binary/reader.zig");
    const writer = @import("binary/writer.zig");

    const cases = [_]struct { wat: []const u8, ok: bool }{
        .{ .wat = "(module (table 4 funcref) (elem funcref) (func table.init 0 0))", .ok = false },
        .{ .wat = "(module (table 4 funcref) (elem funcref)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.init 0 0))", .ok = true },
        // `table.init $table $elem` in the text is elem-then-table in the
        // binary, so a front end that swapped them would name the wrong one.
        .{ .wat = "(module (table 4 funcref) (elem funcref) (elem externref)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.init 0 1))", .ok = false },
        .{ .wat = "(module (table i64 4 funcref) (elem funcref)" ++
            " (func i64.const 0 i32.const 0 i32.const 0 table.init 0 0))", .ok = true },
        .{ .wat = "(module (table i64 4 funcref) (elem funcref)" ++
            " (func i64.const 0 i64.const 0 i64.const 0 table.init 0 0))", .ok = false },
        // Function-index segments infer non-nullable `(ref func)`. They
        // initialise a matching table, both as passive and declarative
        // segments, and an active segment also suits the table at module
        // validation time.
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0))" ++
            " (elem (i32.const 0) func 0))", .ok = true },
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0)) (elem func 0)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.init 0 0))", .ok = true },
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0)) (elem declare func 0)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.init 0 0))", .ok = true },
        // `(ref func)` is not a subtype of nullable bottom `(ref null
        // nofunc)`: this covers table.init and active segment validation.
        .{ .wat = "(module (type (func)) (func) (table 1 nullfuncref) (elem func 0)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.init 0 0))", .ok = false },
        .{ .wat = "(module (type (func)) (func) (table 1 nullfuncref)" ++
            " (elem (i32.const 0) func 0))", .ok = false },
        .{ .wat = "(module (table 4 funcref) (func table.copy 0 0))", .ok = false },
        .{ .wat = "(module (table 4 funcref)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.copy 0 0))", .ok = true },
        .{ .wat = "(module (table 4 funcref) (table i64 4 funcref)" ++
            " (func i32.const 0 i64.const 0 i32.const 0 table.copy 0 1))", .ok = true },
        .{ .wat = "(module (table 4 funcref) (table i64 4 funcref)" ++
            " (func i64.const 0 i32.const 0 i32.const 0 table.copy 1 0))", .ok = true },
        .{ .wat = "(module (table 4 funcref) (table i64 4 funcref)" ++
            " (func i64.const 0 i32.const 0 i64.const 0 table.copy 1 0))", .ok = false },
        .{ .wat = "(module (table 4 funcref) (table 4 externref)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 table.copy 0 1))", .ok = false },
    };

    for (cases) |c| {
        var parsed = Parser.parseModule(alloc, c.wat) catch |err| {
            if (c.ok) return err;
            continue;
        };
        defer parsed.deinit();
        if (c.ok) try validate(&parsed, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&parsed, .{}));

        // The same module written out and read back must reach the same
        // verdict: the text and binary front ends fill in tables and
        // segments differently, and the immediates are ordered differently
        // in the two formats.
        const bytes = try writer.writeModule(alloc, &parsed);
        defer alloc.free(bytes);
        var read_back = try binary_reader.readModule(alloc, bytes);
        defer read_back.deinit();
        if (c.ok) try validate(&read_back, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&read_back, .{}));
    }
}

// ── table.grow, table.size and table.fill tests ─────────────────────────

/// `ref.null func`, `ref.null extern` and `ref.null nofunc`: one null of an
/// abstract heap type each, for the value `table.grow` and `table.fill`
/// write into a table.
const ref_null_func = [_]u8{ 0xd0, 0x70 };
const ref_null_extern = [_]u8{ 0xd0, 0x6f };
const ref_null_nofunc = [_]u8{ 0xd0, 0x73 };

/// `table.grow 0`, `table.size 0` and `table.fill 0`.
const grow_0 = [_]u8{ 0xfc, 0x0f, 0x00 };
const size_0 = [_]u8{ 0xfc, 0x10, 0x00 };
const fill_0 = [_]u8{ 0xfc, 0x11, 0x00 };
const drop_end = [_]u8{ 0x1a, 0x0b };
const end_only = [_]u8{0x0b};

test "table.grow pops a delta and a value and answers the old size" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { body: []const u8, ok: bool }{
        // Nothing to pop at all.
        .{ .body = &(grow_0 ++ drop_end), .ok = false },
        // The delta alone, then the value alone.
        .{ .body = &(i32_zero ++ grow_0 ++ drop_end), .ok = false },
        .{ .body = &(ref_null_func ++ grow_0 ++ drop_end), .ok = false },
        // The value is pushed first and the delta second.
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .ok = true },
        .{ .body = &(i32_zero ++ ref_null_func ++ grow_0 ++ drop_end), .ok = false },
        // A wrong delta...
        .{ .body = &(ref_null_func ++ f32_zero ++ grow_0 ++ drop_end), .ok = false },
        // ...and a wrong value: a funcref table takes no externref.
        .{ .body = &(ref_null_extern ++ i32_zero ++ grow_0 ++ drop_end), .ok = false },
        // The old size is pushed, so leaving it behind is a leftover value
        // in a function that returns nothing.
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ end_only), .ok = false },
        // Exactly two operands are popped, so a third is left behind.
        .{ .body = &(i32_zero ++ ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, &funcref_table, &.{}, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "table.size answers one value and pops nothing" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { body: []const u8, ok: bool }{
        .{ .body = &(size_0 ++ drop_end), .ok = true },
        // The size is pushed, so it has to go somewhere.
        .{ .body = &(size_0 ++ end_only), .ok = false },
        // Exactly one value is pushed, so a second drop empties too much.
        .{ .body = &(size_0 ++ [_]u8{0x1a} ++ drop_end), .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, &funcref_table, &.{}, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "table.fill pops a destination, a value and a length" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { body: []const u8, ok: bool }{
        .{ .body = &(fill_0 ++ end_only), .ok = false },
        .{ .body = &(i32_zero ++ fill_0 ++ end_only), .ok = false },
        .{ .body = &(i32_zero ++ ref_null_func ++ fill_0 ++ end_only), .ok = false },
        .{ .body = &(i32_zero ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .ok = true },
        // A fourth operand is left behind.
        .{ .body = &(i32_zero ** 2 ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .ok = false },
        // A wrong destination, value and length in turn.
        .{ .body = &(f32_zero ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .ok = false },
        .{ .body = &(i32_zero ++ ref_null_extern ++ i32_zero ++ fill_0 ++ end_only), .ok = false },
        .{ .body = &(i32_zero ++ ref_null_func ++ f32_zero ++ fill_0 ++ end_only), .ok = false },
        // The value sits between the two indices, not beside them.
        .{ .body = &(ref_null_func ++ i32_zero ++ i32_zero ++ fill_0 ++ end_only), .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, &funcref_table, &.{}, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "table.grow, table.size and table.fill check the table they name" {
    const alloc = std.testing.allocator;
    // Each of the three read their immediate and never bounds-checked it.
    // `tableIndexType` answers i32 for a table that is not there, so the
    // index type it stands in for made the instruction validate: in a module
    // with no table at all, `table.size 0` pushed an i32 and passed.
    const grow_3 = [_]u8{ 0xfc, 0x0f, 0x03 };
    const size_3 = [_]u8{ 0xfc, 0x10, 0x03 };
    const fill_3 = [_]u8{ 0xfc, 0x11, 0x03 };
    const grow_ops = ref_null_func ++ i32_zero;
    const fill_ops = i32_zero ++ ref_null_func ++ i32_zero;

    const cases = [_]struct { body: []const u8, tables: []const TestTable }{
        // A table the module does not have, with the operands the
        // instruction wants...
        .{ .body = &(grow_ops ++ grow_3 ++ drop_end), .tables = &funcref_table },
        .{ .body = &(size_3 ++ drop_end), .tables = &funcref_table },
        .{ .body = &(fill_ops ++ fill_3 ++ end_only), .tables = &funcref_table },
        // ...and with no operands at all, where the bad index is the only
        // thing wrong that could be reported first.
        .{ .body = &(grow_3 ++ drop_end), .tables = &funcref_table },
        .{ .body = &(fill_3 ++ end_only), .tables = &funcref_table },
        // A module with no tables whatsoever.
        .{ .body = &(grow_ops ++ grow_0 ++ drop_end), .tables = &.{} },
        .{ .body = &(size_0 ++ drop_end), .tables = &.{} },
        .{ .body = &(fill_ops ++ fill_0 ++ end_only), .tables = &.{} },
        // Unreachable code excuses the missing operands but not the index.
        .{ .body = &([_]u8{0x00} ++ grow_3 ++ drop_end), .tables = &funcref_table },
        .{ .body = &([_]u8{0x00} ++ size_3 ++ drop_end), .tables = &funcref_table },
        .{ .body = &([_]u8{0x00} ++ fill_3 ++ end_only), .tables = &funcref_table },
        // A bad index outranks a bad operand, which is the order the
        // reference implementation reports the two in.
        .{ .body = &(f32_zero ++ f32_zero ++ grow_3 ++ drop_end), .tables = &funcref_table },
        .{ .body = &(f32_zero ** 3 ++ fill_3 ++ end_only), .tables = &funcref_table },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, c.tables, &.{}, c.body);
        defer m.deinit();
        try std.testing.expectError(error.InvalidTableIndex, validate(&m, .{}));
    }
}

test "table.grow, table.size and table.fill speak the named table's index type" {
    const alloc = std.testing.allocator;
    const table64 = [_]TestTable{.{ .is_64 = true }};
    // Table 0 is 32-bit and table 1 is 64-bit.
    const mixed = [_]TestTable{ .{}, .{ .is_64 = true } };
    const i32_eqz = [_]u8{0x45};
    const i64_eqz = [_]u8{0x50};
    const grow_1 = [_]u8{ 0xfc, 0x0f, 0x01 };
    const size_1 = [_]u8{ 0xfc, 0x10, 0x01 };
    const fill_1 = [_]u8{ 0xfc, 0x11, 0x01 };

    const cases = [_]struct { body: []const u8, tables: []const TestTable, ok: bool }{
        // The delta and the old size both count entries, so both follow the
        // table's index type. `i64.eqz` accepts only an i64, so it is what
        // proves the result widened rather than merely being ignored.
        .{ .body = &(ref_null_func ++ i64_zero ++ grow_0 ++ i64_eqz ++ drop_end), .tables = &table64, .ok = true },
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .tables = &table64, .ok = false },
        .{ .body = &(ref_null_func ++ i64_zero ++ grow_0 ++ i32_eqz ++ drop_end), .tables = &table64, .ok = false },
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ i32_eqz ++ drop_end), .tables = &funcref_table, .ok = true },
        .{ .body = &(ref_null_func ++ i64_zero ++ grow_0 ++ drop_end), .tables = &funcref_table, .ok = false },
        // The size answers in the index type too.
        .{ .body = &(size_0 ++ i64_eqz ++ drop_end), .tables = &table64, .ok = true },
        .{ .body = &(size_0 ++ i32_eqz ++ drop_end), .tables = &table64, .ok = false },
        .{ .body = &(size_0 ++ i32_eqz ++ drop_end), .tables = &funcref_table, .ok = true },
        // The destination and the length index the table; the value between
        // them is an element and has no width to widen.
        .{ .body = &(i64_zero ++ ref_null_func ++ i64_zero ++ fill_0 ++ end_only), .tables = &table64, .ok = true },
        .{ .body = &(i32_zero ++ ref_null_func ++ i64_zero ++ fill_0 ++ end_only), .tables = &table64, .ok = false },
        .{ .body = &(i64_zero ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .tables = &table64, .ok = false },
        .{ .body = &(i64_zero ++ ref_null_func ++ i64_zero ++ fill_0 ++ end_only), .tables = &funcref_table, .ok = false },
        // The table the immediate names is the one that decides, not table 0.
        .{ .body = &(ref_null_func ++ i64_zero ++ grow_1 ++ i64_eqz ++ drop_end), .tables = &mixed, .ok = true },
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_1 ++ drop_end), .tables = &mixed, .ok = false },
        .{ .body = &(size_1 ++ i64_eqz ++ drop_end), .tables = &mixed, .ok = true },
        .{ .body = &(size_0 ++ i64_eqz ++ drop_end), .tables = &mixed, .ok = false },
        .{ .body = &(i64_zero ++ ref_null_func ++ i64_zero ++ fill_1 ++ end_only), .tables = &mixed, .ok = true },
        .{ .body = &(i64_zero ++ ref_null_func ++ i64_zero ++ fill_0 ++ end_only), .tables = &mixed, .ok = false },
        // Unreachable code supplies the missing operands but not their
        // types: a 64-bit table still counts in i64.
        .{ .body = &([_]u8{0x00} ++ i64_zero ++ fill_0 ++ end_only), .tables = &table64, .ok = true },
        .{ .body = &([_]u8{0x00} ++ i32_zero ++ fill_0 ++ end_only), .tables = &table64, .ok = false },
        .{ .body = &([_]u8{0x00} ++ i64_zero ++ grow_0 ++ drop_end), .tables = &table64, .ok = true },
        .{ .body = &([_]u8{0x00} ++ i32_zero ++ grow_0 ++ drop_end), .tables = &table64, .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, c.tables, &.{}, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "table.grow and table.fill write a value the table's elements accept" {
    const alloc = std.testing.allocator;
    const externref_table = [_]TestTable{.{ .elem = .externref }};
    // Type 0 is `(func)`, so this table holds `(ref null 0)`.
    const concrete_table = [_]TestTable{.{ .elem = .concrete_ref_null, .type_idx = 0 }};
    // A table whose element type has no null needs an initializer:
    // ref.func 0, end.
    const ref_func_init = [_]u8{ 0xd2, 0x00, 0x0b };
    const nonnull_table = [_]TestTable{.{ .elem = .ref_func, .init_expr_bytes = &ref_func_init }};

    const cases = [_]struct { body: []const u8, tables: []const TestTable, ok: bool }{
        .{ .body = &(ref_null_extern ++ i32_zero ++ grow_0 ++ drop_end), .tables = &externref_table, .ok = true },
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .tables = &externref_table, .ok = false },
        .{ .body = &(i32_zero ++ ref_null_extern ++ i32_zero ++ fill_0 ++ end_only), .tables = &externref_table, .ok = true },
        .{ .body = &(i32_zero ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .tables = &externref_table, .ok = false },
        // A subtype of the element type is written; a supertype is not.
        // `nullfuncref` is below every function reference, `funcref` above
        // the concrete one.
        .{ .body = &(ref_null_nofunc ++ i32_zero ++ grow_0 ++ drop_end), .tables = &concrete_table, .ok = true },
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .tables = &concrete_table, .ok = false },
        .{ .body = &(i32_zero ++ ref_null_nofunc ++ i32_zero ++ fill_0 ++ end_only), .tables = &concrete_table, .ok = true },
        .{ .body = &(i32_zero ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .tables = &concrete_table, .ok = false },
        // A table whose elements have no null takes no null.
        .{ .body = &(ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .tables = &nonnull_table, .ok = false },
        .{ .body = &(i32_zero ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .tables = &nonnull_table, .ok = false },
        // The element type is checked in unreachable code as well, where the
        // value is not popped from anything.
        .{ .body = &([_]u8{0x00} ++ ref_null_func ++ i32_zero ++ grow_0 ++ drop_end), .tables = &externref_table, .ok = false },
        .{ .body = &([_]u8{0x00} ++ ref_null_func ++ i32_zero ++ fill_0 ++ end_only), .tables = &nonnull_table, .ok = false },
    };
    for (cases) |c| {
        var m = try testTableModule(alloc, c.tables, &.{}, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "a truncated table immediate is not taken for a table that exists" {
    const alloc = std.testing.allocator;
    // A body that stops in the middle of an instruction reads a zero for the
    // immediate that is not there, so the bounds check is what stands
    // between a truncated `table.size` and the module's first table.
    var no_tables = try testTableModule(alloc, &.{}, &.{}, &[_]u8{ 0xfc, 0x10 });
    defer no_tables.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&no_tables, .{}));

    // With a table present the instruction reads as `table.size 0`, but the
    // body still ends without its `end`.
    var truncated = try testTableModule(alloc, &funcref_table, &.{}, &[_]u8{ 0xfc, 0x10 });
    defer truncated.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&truncated, .{}));

    // The `end` of a body whose immediate is missing is read as the
    // immediate -- 0x0b is 11 -- and 11 is not a table this module has.
    var eats_end = try testTableModule(alloc, &funcref_table, &.{}, &[_]u8{ 0xfc, 0x10, 0x0b });
    defer eats_end.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&eats_end, .{}));

    // An immediate whose LEB128 never ends is not a table index either.
    var unfinished = try testTableModule(alloc, &funcref_table, &.{}, &[_]u8{ 0xfc, 0x10, 0x80 });
    defer unfinished.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&unfinished, .{}));

    var grow_cut = try testTableModule(alloc, &.{}, &.{}, &(ref_null_func ++ i32_zero ++ [_]u8{ 0xfc, 0x0f }));
    defer grow_cut.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&grow_cut, .{}));

    var fill_cut = try testTableModule(alloc, &.{}, &.{}, &(i32_zero ++ ref_null_func ++ i32_zero ++ [_]u8{ 0xfc, 0x11 }));
    defer fill_cut.deinit();
    try std.testing.expectError(error.InvalidTableIndex, validate(&fill_cut, .{}));

    // A binary whose code section stops mid-instruction does not reach the
    // validator at all: the reader rejects the section.
    const binary_reader = @import("binary/reader.zig");
    const truncated_module = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic, version
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: (func)
        0x03, 0x02, 0x01, 0x00, // function: one func of type 0
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: one funcref table
        0x0a, 0x05, 0x01, 0x03, 0x00, 0xfc, 0x10, // code: table.size, no immediate
    };
    try std.testing.expectError(error.InvalidSection, binary_reader.readModule(alloc, &truncated_module));
}

test "table.grow, table.size and table.fill validate the same whichever front end built the module" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    const binary_reader = @import("binary/reader.zig");
    const writer = @import("binary/writer.zig");

    const cases = [_]struct { wat: []const u8, err: ?Error }{
        .{ .wat = "(module (table 1 funcref) (func ref.null func i32.const 1 table.grow drop))", .err = null },
        // The table index may be omitted, and it means table 0 either way.
        .{ .wat = "(module (table 1 funcref) (func ref.null func i32.const 1 table.grow 0 drop))", .err = null },
        .{ .wat = "(module (table 1 funcref) (func ref.null func i32.const 1 table.grow 3 drop))", .err = error.InvalidTableIndex },
        .{ .wat = "(module (table 1 funcref) (func table.size drop))", .err = null },
        .{ .wat = "(module (table 1 funcref) (func table.size 3 drop))", .err = error.InvalidTableIndex },
        // A module with no table at all: `table.size 0` used to push the i32
        // that stands in for a missing table's index type and pass.
        .{ .wat = "(module (func table.size 0 drop))", .err = error.InvalidTableIndex },
        .{ .wat = "(module (func ref.null func i32.const 1 table.grow 0 drop))", .err = error.InvalidTableIndex },
        .{ .wat = "(module (func i32.const 0 ref.null func i32.const 0 table.fill 0))", .err = error.InvalidTableIndex },
        .{ .wat = "(module (table 1 funcref) (func i32.const 0 ref.null func i32.const 0 table.fill))", .err = null },
        .{ .wat = "(module (table 1 funcref) (func i32.const 0 ref.null func i32.const 0 table.fill 3))", .err = error.InvalidTableIndex },
        // A bad index is reported from unreachable code too.
        .{ .wat = "(module (table 1 funcref) (func unreachable table.size 3 drop))", .err = error.InvalidTableIndex },
        // table64: the delta, the size and the fill's two indices are i64.
        .{ .wat = "(module (table i64 1 funcref) (func ref.null func i64.const 1 table.grow drop))", .err = null },
        .{ .wat = "(module (table i64 1 funcref) (func ref.null func i32.const 1 table.grow drop))", .err = error.TypeMismatch },
        .{ .wat = "(module (table i64 1 funcref) (func table.size i64.eqz drop))", .err = null },
        .{ .wat = "(module (table i64 1 funcref) (func i64.const 0 ref.null func i64.const 0 table.fill))", .err = null },
        .{ .wat = "(module (table i64 1 funcref) (func i64.const 0 ref.null func i32.const 0 table.fill))", .err = error.TypeMismatch },
        // The table named decides, not table 0.
        .{ .wat = "(module (table 1 funcref) (table i64 1 funcref) (func table.size 1 i64.eqz drop))", .err = null },
        .{ .wat = "(module (table 1 funcref) (table i64 1 funcref) (func table.size 0 i64.eqz drop))", .err = error.TypeMismatch },
        // The value written has to suit the table's elements.
        .{ .wat = "(module (table 1 externref) (func ref.null func i32.const 1 table.grow drop))", .err = error.TypeMismatch },
        .{ .wat = "(module (table 1 externref) (func ref.null extern i32.const 1 table.grow drop))", .err = null },
        .{ .wat = "(module (type (func)) (table 1 (ref null 0))" ++
            " (func i32.const 0 ref.null nofunc i32.const 0 table.fill))", .err = null },
        .{ .wat = "(module (type (func)) (table 1 (ref null 0))" ++
            " (func i32.const 0 ref.null func i32.const 0 table.fill))", .err = error.TypeMismatch },
        .{ .wat = "(module (type (func)) (func) (elem declare func 0) (table 1 (ref func) (ref.func 0))" ++
            " (func ref.func 0 i32.const 1 table.grow drop))", .err = null },
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0))" ++
            " (func ref.null func i32.const 1 table.grow drop))", .err = error.TypeMismatch },
    };

    for (cases) |c| {
        var parsed = try Parser.parseModule(alloc, c.wat);
        defer parsed.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&parsed, .{})) else try validate(&parsed, .{});

        // The same module written out and read back must reach the same
        // verdict: the two front ends fill in tables differently, and a
        // table index that no table answers to must survive the trip.
        const bytes = try writer.writeModule(alloc, &parsed);
        defer alloc.free(bytes);
        var read_back = try binary_reader.readModule(alloc, bytes);
        defer read_back.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&read_back, .{})) else try validate(&read_back, .{});
    }
}

// ── memory.init, memory.copy and memory.fill tests ──────────────────────

/// A module of one memory per entry of `memories` -- each says whether that
/// memory is 64-bit -- plus `data_segs` passive data segments and one
/// function. The data count section is present, as it is in every module
/// that is not read from a binary lacking one.
fn testMemoryModule(
    alloc: std.mem.Allocator,
    memories: []const bool,
    data_segs: usize,
    body: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    for (memories) |is_64| {
        try module.memories.append(alloc, .{
            .type = .{ .limits = .{ .initial = 1, .is_64 = is_64 } },
        });
    }
    for (0..data_segs) |_| {
        try module.data_segments.append(alloc, .{ .kind = .passive, .data = "abc" });
    }
    module.data_count = @intCast(data_segs);
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

const mem32_only = [_]bool{false};
const mem64_only = [_]bool{true};
/// Memory 0 is 32-bit and memory 1 is 64-bit.
const mem_mixed = [_]bool{ false, true };
const mem_both64 = [_]bool{ true, true };

const i32_zero = [_]u8{ 0x41, 0x00 };
const i64_zero = [_]u8{ 0x42, 0x00 };
const f32_zero = [_]u8{ 0x43, 0x00, 0x00, 0x00, 0x00 };

test "memory.init pops three operands" {
    const alloc = std.testing.allocator;
    // memory.init data=0 mem=0; end
    const init = [_]u8{ 0xfc, 0x08, 0x00, 0x00, 0x0b };
    const cases = [_]struct { body: []const u8, ok: bool }{
        .{ .body = &init, .ok = false },
        .{ .body = &(i32_zero ++ init), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ init), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ i32_zero ++ init), .ok = true },
        // A fourth operand is left behind, and the function returns nothing.
        .{ .body = &(i32_zero ** 4 ++ init), .ok = false },
        // f32.const 0 in each of the three positions: destination...
        .{ .body = &(f32_zero ++ i32_zero ++ i32_zero ++ init), .ok = false },
        // ...source...
        .{ .body = &(i32_zero ++ f32_zero ++ i32_zero ++ init), .ok = false },
        // ...and length.
        .{ .body = &(i32_zero ++ i32_zero ++ f32_zero ++ init), .ok = false },
    };
    for (cases) |c| {
        var m = try testMemoryModule(alloc, &mem32_only, 1, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }
}

test "memory.init checks the memory and the data segment it names" {
    const alloc = std.testing.allocator;
    const ops = i32_zero ++ i32_zero ++ i32_zero;

    // memory.init data=0 mem=3 -- there is no memory 3. The immediate used
    // to be read and thrown away, so any index at all was accepted.
    var bad_mem = try testMemoryModule(alloc, &mem32_only, 1, &(ops ++ [_]u8{ 0xfc, 0x08, 0x00, 0x03, 0x0b }));
    defer bad_mem.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&bad_mem, .{}));

    // memory.init data=3 mem=0 -- there is no segment 3.
    var bad_data = try testMemoryModule(alloc, &mem32_only, 1, &(ops ++ [_]u8{ 0xfc, 0x08, 0x03, 0x00, 0x0b }));
    defer bad_data.deinit();
    try std.testing.expectError(error.InvalidDataIndex, validate(&bad_data, .{}));

    // With both wrong the memory is the complaint, which is what the
    // reference implementation reports.
    var both_bad = try testMemoryModule(alloc, &mem32_only, 1, &(ops ++ [_]u8{ 0xfc, 0x08, 0x03, 0x03, 0x0b }));
    defer both_bad.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&both_bad, .{}));

    // With no memory at all the index is still the complaint. `memIndexType`
    // answers i32 for a memory that is not there, so checking bounds after
    // it would report a missing memory as a type error.
    var no_mem = try testMemoryModule(alloc, &.{}, 1, &(ops ++ [_]u8{ 0xfc, 0x08, 0x00, 0x00, 0x0b }));
    defer no_mem.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&no_mem, .{}));

    var no_data = try testMemoryModule(alloc, &mem32_only, 0, &(ops ++ [_]u8{ 0xfc, 0x08, 0x00, 0x00, 0x0b }));
    defer no_data.deinit();
    try std.testing.expectError(error.InvalidDataIndex, validate(&no_data, .{}));

    // A binary without a data count section may not name a data segment at
    // all, even one the data section defines.
    var no_count = try testMemoryModule(alloc, &mem32_only, 1, &(ops ++ [_]u8{ 0xfc, 0x08, 0x00, 0x00, 0x0b }));
    defer no_count.deinit();
    no_count.has_data_count = false;
    try std.testing.expectError(error.InvalidDataIndex, validate(&no_count, .{}));

    // Bad indices are caught in unreachable code too, where no operand is
    // popped that could have raised the alarm instead.
    var unreachable_mem = try testMemoryModule(alloc, &mem32_only, 1, &[_]u8{ 0x00, 0xfc, 0x08, 0x00, 0x03, 0x0b });
    defer unreachable_mem.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&unreachable_mem, .{}));

    var unreachable_data = try testMemoryModule(alloc, &mem32_only, 1, &[_]u8{ 0x00, 0xfc, 0x08, 0x03, 0x00, 0x0b });
    defer unreachable_data.deinit();
    try std.testing.expectError(error.InvalidDataIndex, validate(&unreachable_data, .{}));
}

test "memory.init's destination follows the memory's index type" {
    const alloc = std.testing.allocator;
    const init = [_]u8{ 0xfc, 0x08, 0x00, 0x00, 0x0b };

    // The source offset and the length index the data segment, which is
    // never 64-bit, so they stay i32 however wide the memory is. The
    // destination was required to be i32 as well, which rejected every
    // memory64 module that initialised its memory.
    var ok = try testMemoryModule(alloc, &mem64_only, 1, &(i64_zero ++ i32_zero ++ i32_zero ++ init));
    defer ok.deinit();
    try validate(&ok, .{});

    var narrow_dst = try testMemoryModule(alloc, &mem64_only, 1, &(i32_zero ++ i32_zero ++ i32_zero ++ init));
    defer narrow_dst.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&narrow_dst, .{}));

    var wide_src = try testMemoryModule(alloc, &mem64_only, 1, &(i64_zero ++ i64_zero ++ i32_zero ++ init));
    defer wide_src.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_src, .{}));

    var wide_len = try testMemoryModule(alloc, &mem64_only, 1, &(i64_zero ++ i32_zero ++ i64_zero ++ init));
    defer wide_len.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_len, .{}));

    // A 32-bit memory still wants an i32 destination.
    var wide_dst_32 = try testMemoryModule(alloc, &mem32_only, 1, &(i64_zero ++ i32_zero ++ i32_zero ++ init));
    defer wide_dst_32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_dst_32, .{}));

    // The memory the immediate names is the one that decides, not memory 0:
    // here memory 1 is the 64-bit one.
    const init_mem1 = [_]u8{ 0xfc, 0x08, 0x00, 0x01, 0x0b };
    var picks_named = try testMemoryModule(alloc, &mem_mixed, 1, &(i64_zero ++ i32_zero ++ i32_zero ++ init_mem1));
    defer picks_named.deinit();
    try validate(&picks_named, .{});

    var picks_named_32 = try testMemoryModule(alloc, &mem_mixed, 1, &(i32_zero ++ i32_zero ++ i32_zero ++ init));
    defer picks_named_32.deinit();
    try validate(&picks_named_32, .{});

    // Unreachable code supplies the missing operands but not their types:
    // the i32 length is still the length of a 64-bit memory's initialisation.
    var poly = try testMemoryModule(alloc, &mem64_only, 1, &([_]u8{0x00} ++ i32_zero ++ init));
    defer poly.deinit();
    try validate(&poly, .{});

    var poly_bad = try testMemoryModule(alloc, &mem64_only, 1, &([_]u8{0x00} ++ i64_zero ++ init));
    defer poly_bad.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&poly_bad, .{}));
}

test "memory.copy's offsets follow their memories and its length the narrower" {
    const alloc = std.testing.allocator;
    // memory.copy dst=1 src=0, then dst=0 src=1.
    const copy_64_32 = [_]u8{ 0xfc, 0x0a, 0x01, 0x00, 0x0b };
    const copy_32_64 = [_]u8{ 0xfc, 0x0a, 0x00, 0x01, 0x0b };
    const copy_0_1 = [_]u8{ 0xfc, 0x0a, 0x00, 0x01, 0x0b };

    // Each offset is of the index type of the memory it indexes, and the
    // length is of the narrower of the two -- it has to be a valid count in
    // both memories, so a copy touching any 32-bit memory counts in i32.
    // The length used to follow the destination alone, which both rejected
    // valid copies out of a 32-bit memory and accepted invalid ones into it.
    var d64s32 = try testMemoryModule(alloc, &mem_mixed, 0, &(i64_zero ++ i32_zero ++ i32_zero ++ copy_64_32));
    defer d64s32.deinit();
    try validate(&d64s32, .{});

    var d32s64 = try testMemoryModule(alloc, &mem_mixed, 0, &(i32_zero ++ i64_zero ++ i32_zero ++ copy_32_64));
    defer d32s64.deinit();
    try validate(&d32s64, .{});

    // The length does not widen with either memory on its own.
    var d64s32_len64 = try testMemoryModule(alloc, &mem_mixed, 0, &(i64_zero ++ i32_zero ++ i64_zero ++ copy_64_32));
    defer d64s32_len64.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&d64s32_len64, .{}));

    var d32s64_len64 = try testMemoryModule(alloc, &mem_mixed, 0, &(i32_zero ++ i64_zero ++ i64_zero ++ copy_32_64));
    defer d32s64_len64.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&d32s64_len64, .{}));

    // Nor does an offset take the other memory's index type.
    var swapped = try testMemoryModule(alloc, &mem_mixed, 0, &(i64_zero ++ i32_zero ++ i32_zero ++ copy_32_64));
    defer swapped.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&swapped, .{}));

    // Only when both memories are 64-bit does the length widen.
    var wide = try testMemoryModule(alloc, &mem_both64, 0, &(i64_zero ++ i64_zero ++ i64_zero ++ copy_0_1));
    defer wide.deinit();
    try validate(&wide, .{});

    var wide_len32 = try testMemoryModule(alloc, &mem_both64, 0, &(i64_zero ++ i64_zero ++ i32_zero ++ copy_0_1));
    defer wide_len32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_len32, .{}));

    // Two 32-bit memories count in i32 throughout.
    const both32 = [_]bool{ false, false };
    var narrow = try testMemoryModule(alloc, &both32, 0, &(i32_zero ++ i32_zero ++ i32_zero ++ copy_0_1));
    defer narrow.deinit();
    try validate(&narrow, .{});

    // A memory copied onto itself follows its own index type throughout.
    const self_copy = [_]u8{ 0xfc, 0x0a, 0x00, 0x00, 0x0b };
    var self64 = try testMemoryModule(alloc, &mem64_only, 0, &(i64_zero ++ i64_zero ++ i64_zero ++ self_copy));
    defer self64.deinit();
    try validate(&self64, .{});

    var self64_len32 = try testMemoryModule(alloc, &mem64_only, 0, &(i64_zero ++ i64_zero ++ i32_zero ++ self_copy));
    defer self64_len32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&self64_len32, .{}));

    // Unreachable code still types what it is given: the length of a copy
    // between a 64-bit and a 32-bit memory is i32.
    var poly = try testMemoryModule(alloc, &mem_mixed, 0, &([_]u8{0x00} ++ i32_zero ++ copy_32_64));
    defer poly.deinit();
    try validate(&poly, .{});

    var poly_bad = try testMemoryModule(alloc, &mem_mixed, 0, &([_]u8{0x00} ++ i64_zero ++ copy_32_64));
    defer poly_bad.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&poly_bad, .{}));
}

test "memory.copy pops three operands and checks both memories" {
    const alloc = std.testing.allocator;
    const copy = [_]u8{ 0xfc, 0x0a, 0x00, 0x00, 0x0b };
    const cases = [_]struct { body: []const u8, ok: bool }{
        .{ .body = &copy, .ok = false },
        .{ .body = &(i32_zero ++ copy), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ copy), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ i32_zero ++ copy), .ok = true },
        .{ .body = &(i32_zero ** 4 ++ copy), .ok = false },
        .{ .body = &(f32_zero ++ i32_zero ++ i32_zero ++ copy), .ok = false },
        .{ .body = &(i32_zero ++ f32_zero ++ i32_zero ++ copy), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ f32_zero ++ copy), .ok = false },
    };
    for (cases) |c| {
        var m = try testMemoryModule(alloc, &mem32_only, 0, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }

    const ops = i32_zero ++ i32_zero ++ i32_zero;
    // Neither index was bounds-checked: only a module with no memory at all
    // was rejected, so `memory.copy 3 4` passed in a module with one memory.
    var bad_dst = try testMemoryModule(alloc, &mem32_only, 0, &(ops ++ [_]u8{ 0xfc, 0x0a, 0x03, 0x00, 0x0b }));
    defer bad_dst.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&bad_dst, .{}));

    var bad_src = try testMemoryModule(alloc, &mem32_only, 0, &(ops ++ [_]u8{ 0xfc, 0x0a, 0x00, 0x03, 0x0b }));
    defer bad_src.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&bad_src, .{}));

    var both_bad = try testMemoryModule(alloc, &mem32_only, 0, &(ops ++ [_]u8{ 0xfc, 0x0a, 0x03, 0x04, 0x0b }));
    defer both_bad.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&both_bad, .{}));

    var no_mem = try testMemoryModule(alloc, &.{}, 0, &(ops ++ copy));
    defer no_mem.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&no_mem, .{}));

    var unreachable_bad = try testMemoryModule(alloc, &mem32_only, 0, &[_]u8{ 0x00, 0xfc, 0x0a, 0x03, 0x04, 0x0b });
    defer unreachable_bad.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&unreachable_bad, .{}));
}

test "memory.fill's destination and length follow the memory, its value does not" {
    const alloc = std.testing.allocator;
    const fill = [_]u8{ 0xfc, 0x0b, 0x00, 0x0b };

    // The byte written is a value, not an index, so it stays i32 however
    // wide the memory is; the destination and the count index the memory.
    var ok64 = try testMemoryModule(alloc, &mem64_only, 0, &(i64_zero ++ i32_zero ++ i64_zero ++ fill));
    defer ok64.deinit();
    try validate(&ok64, .{});

    var narrow_len = try testMemoryModule(alloc, &mem64_only, 0, &(i64_zero ++ i32_zero ++ i32_zero ++ fill));
    defer narrow_len.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&narrow_len, .{}));

    var narrow_dst = try testMemoryModule(alloc, &mem64_only, 0, &(i32_zero ++ i32_zero ++ i64_zero ++ fill));
    defer narrow_dst.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&narrow_dst, .{}));

    var wide_val = try testMemoryModule(alloc, &mem64_only, 0, &(i64_zero ++ i64_zero ++ i64_zero ++ fill));
    defer wide_val.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_val, .{}));

    var ok32 = try testMemoryModule(alloc, &mem32_only, 0, &(i32_zero ++ i32_zero ++ i32_zero ++ fill));
    defer ok32.deinit();
    try validate(&ok32, .{});

    var wide_dst_32 = try testMemoryModule(alloc, &mem32_only, 0, &(i64_zero ++ i32_zero ++ i32_zero ++ fill));
    defer wide_dst_32.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&wide_dst_32, .{}));

    // The memory the immediate names decides, not memory 0.
    const fill_mem1 = [_]u8{ 0xfc, 0x0b, 0x01, 0x0b };
    var picks_named = try testMemoryModule(alloc, &mem_mixed, 0, &(i64_zero ++ i32_zero ++ i64_zero ++ fill_mem1));
    defer picks_named.deinit();
    try validate(&picks_named, .{});

    var poly = try testMemoryModule(alloc, &mem64_only, 0, &([_]u8{0x00} ++ i64_zero ++ fill));
    defer poly.deinit();
    try validate(&poly, .{});

    var poly_bad = try testMemoryModule(alloc, &mem64_only, 0, &([_]u8{0x00} ++ i32_zero ++ fill));
    defer poly_bad.deinit();
    try std.testing.expectError(error.TypeMismatch, validate(&poly_bad, .{}));
}

test "memory.fill pops three operands and checks the memory it names" {
    const alloc = std.testing.allocator;
    const fill = [_]u8{ 0xfc, 0x0b, 0x00, 0x0b };
    const cases = [_]struct { body: []const u8, ok: bool }{
        .{ .body = &fill, .ok = false },
        .{ .body = &(i32_zero ++ fill), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ fill), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ i32_zero ++ fill), .ok = true },
        .{ .body = &(i32_zero ** 4 ++ fill), .ok = false },
        .{ .body = &(f32_zero ++ i32_zero ++ i32_zero ++ fill), .ok = false },
        .{ .body = &(i32_zero ++ f32_zero ++ i32_zero ++ fill), .ok = false },
        .{ .body = &(i32_zero ++ i32_zero ++ f32_zero ++ fill), .ok = false },
    };
    for (cases) |c| {
        var m = try testMemoryModule(alloc, &mem32_only, 0, c.body);
        defer m.deinit();
        if (c.ok) try validate(&m, .{}) else try std.testing.expectError(error.TypeMismatch, validate(&m, .{}));
    }

    const ops = i32_zero ++ i32_zero ++ i32_zero;
    // The index was not bounds-checked: `memory.fill 3` passed in a module
    // with one memory.
    var bad_mem = try testMemoryModule(alloc, &mem32_only, 0, &(ops ++ [_]u8{ 0xfc, 0x0b, 0x03, 0x0b }));
    defer bad_mem.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&bad_mem, .{}));

    var no_mem = try testMemoryModule(alloc, &.{}, 0, &(ops ++ fill));
    defer no_mem.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&no_mem, .{}));

    var unreachable_bad = try testMemoryModule(alloc, &mem32_only, 0, &[_]u8{ 0x00, 0xfc, 0x0b, 0x03, 0x0b });
    defer unreachable_bad.deinit();
    try std.testing.expectError(error.InvalidMemoryIndex, validate(&unreachable_bad, .{}));
}

test "the bulk memory instructions validate the same whichever front end built the module" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    const binary_reader = @import("binary/reader.zig");
    const writer = @import("binary/writer.zig");

    // Every verdict below was checked against wasm-tools 1.250.0.
    const cases = [_]struct { wat: []const u8, err: ?Error = null }{
        // memory.init: the destination follows the memory, the source
        // offset and the length index the data segment and stay i32.
        .{ .wat = "(module (memory i64 1) (data \"abc\")" ++
            " (func i64.const 0 i32.const 0 i32.const 0 memory.init 0 0))" },
        .{ .wat = "(module (memory i64 1) (data \"abc\")" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.init 0 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory i64 1) (data \"abc\")" ++
            " (func i64.const 0 i64.const 0 i32.const 0 memory.init 0 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory i64 1) (data \"abc\")" ++
            " (func i64.const 0 i32.const 0 i64.const 0 memory.init 0 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory 1) (data \"abc\")" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.init 0 0))" },
        .{ .wat = "(module (memory 1) (data \"abc\") (func memory.init 0 0))", .err = error.TypeMismatch },
        // `memory.init $mem $data` in the text is data-then-memory in the
        // binary, so a front end that swapped them would name the wrong one:
        // memory 1 is the 64-bit one here.
        .{ .wat = "(module (memory 1) (memory i64 1) (data \"abc\")" ++
            " (func i64.const 0 i32.const 0 i32.const 0 memory.init 1 0))" },
        .{ .wat = "(module (memory 1) (memory i64 1) (data \"abc\")" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.init 1 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory 1) (data \"abc\")" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.init 0 1))", .err = error.InvalidDataIndex },
        .{ .wat = "(module (memory 1) (data \"abc\")" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.init 1 0))", .err = error.InvalidMemoryIndex },
        // memory.copy: each offset follows its own memory, the length the
        // narrower of the two.
        .{ .wat = "(module (memory i64 1)" ++
            " (func i64.const 0 i64.const 0 i64.const 0 memory.copy 0 0))" },
        .{ .wat = "(module (memory i64 1)" ++
            " (func i64.const 0 i64.const 0 i32.const 0 memory.copy 0 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory i64 1) (memory 1)" ++
            " (func i64.const 0 i32.const 0 i32.const 0 memory.copy 0 1))" },
        .{ .wat = "(module (memory i64 1) (memory 1)" ++
            " (func i64.const 0 i32.const 0 i64.const 0 memory.copy 0 1))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory 1) (memory i64 1)" ++
            " (func i32.const 0 i64.const 0 i32.const 0 memory.copy 0 1))" },
        .{ .wat = "(module (memory 1) (memory i64 1)" ++
            " (func i32.const 0 i64.const 0 i64.const 0 memory.copy 0 1))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory 1)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.copy 1 0))", .err = error.InvalidMemoryIndex },
        .{ .wat = "(module (memory 1)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.copy 0 1))", .err = error.InvalidMemoryIndex },
        // memory.fill: destination and length follow the memory, the byte
        // written stays i32.
        .{ .wat = "(module (memory i64 1)" ++
            " (func i64.const 0 i32.const 0 i64.const 0 memory.fill 0))" },
        .{ .wat = "(module (memory i64 1)" ++
            " (func i64.const 0 i64.const 0 i64.const 0 memory.fill 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory i64 1)" ++
            " (func i64.const 0 i32.const 0 i32.const 0 memory.fill 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory 1)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.fill 0))" },
        .{ .wat = "(module (memory 1) (memory i64 1)" ++
            " (func i64.const 0 i32.const 0 i64.const 0 memory.fill 1))" },
        .{ .wat = "(module (memory 1)" ++
            " (func i32.const 0 i32.const 0 i32.const 0 memory.fill 1))", .err = error.InvalidMemoryIndex },
        // Unreachable code supplies operands but not their types.
        .{ .wat = "(module (memory i64 1) (data \"abc\")" ++
            " (func unreachable i32.const 0 memory.init 0 0))" },
        .{ .wat = "(module (memory i64 1) (data \"abc\")" ++
            " (func unreachable i64.const 0 memory.init 0 0))", .err = error.TypeMismatch },
        .{ .wat = "(module (memory 1) (func unreachable memory.fill 1))", .err = error.InvalidMemoryIndex },
    };

    for (cases) |c| {
        var parsed = Parser.parseModule(alloc, c.wat) catch |err| {
            if (c.err == null) return err;
            continue;
        };
        defer parsed.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&parsed, .{})) else try validate(&parsed, .{});

        // The same module written out and read back must reach the same
        // verdict: the two front ends fill in memories and segments
        // differently, and memory.init's immediates are ordered differently
        // in the two formats.
        const bytes = try writer.writeModule(alloc, &parsed);
        defer alloc.free(bytes);
        var read_back = try binary_reader.readModule(alloc, bytes);
        defer read_back.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&read_back, .{})) else try validate(&read_back, .{});
    }
}

// ── Element and data segment index tests ────────────────────────────────

test "an element expressed as ref.null is not a function index" {
    const alloc = std.testing.allocator;
    // A segment naming its elements as expressions carries no function
    // indices; `elem_var_indices` only shadows them, and cannot express
    // `ref.null`, which it records as maxInt(u32). Reading that shadow as a
    // function index rejected every segment holding a null.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    const exprs = [_]u8{ 0xd0, 0x6f, 0x0b }; // ref.null extern, end
    try m.elem_segments.append(alloc, .{
        .kind = .declared,
        .elem_type = .externref,
        .elem_expr_bytes = &exprs,
        .elem_expr_count = 1,
        .elem_var_indices = blk: {
            var list: std.ArrayListUnmanaged(Mod.Var) = .empty;
            try list.append(alloc, .{ .index = std.math.maxInt(u32) });
            break :blk list;
        },
    });
    try validate(&m, .{});
}

test "a function named by an element expression is still bounds checked" {
    const alloc = std.testing.allocator;
    // Ignoring the shadow must not mean ignoring the check: the expressions
    // themselves name functions, and those names must exist.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    const exprs = [_]u8{ 0xd2, 0x07, 0x0b }; // ref.func 7, end
    try m.elem_segments.append(alloc, .{
        .kind = .declared,
        .elem_type = .funcref,
        .elem_expr_bytes = &exprs,
        .elem_expr_count = 1,
    });
    try std.testing.expectError(error.InvalidFuncIndex, validate(&m, .{}));
}

test "a module built in memory has a data count section" {
    const alloc = std.testing.allocator;
    // memory.init and data.drop require the section. The writer emits one
    // whenever there are data segments, so any module built in memory has
    // it; the flag used to default to false, so every such instruction
    // parsed from text was rejected as an invalid data index.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    try m.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1 } } });
    try m.data_segments.append(alloc, .{ .kind = .passive });
    // i32.const 0 x3; memory.init 0; data.drop 0; end
    const body = [_]u8{
        0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0xfc, 0x08, 0x00, 0x00,
        0xfc, 0x09, 0x00, 0x0b,
    };
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try validate(&m, .{});

    // A binary that genuinely lacks the section is still rejected, so the
    // rule was relaxed for modules the reader never saw, not abandoned.
    m.has_data_count = false;
    try std.testing.expectError(error.InvalidDataIndex, validate(&m, .{}));
}

test "a function declared after an unfamiliar element expression is still declared" {
    const alloc = std.testing.allocator;
    // ref.func may only name a function some element segment has declared.
    // Finding those declarations meant scanning the expression bytes for
    // ref.func by hand, stopping at the first opcode the scan did not know.
    // A segment beginning with global.get therefore hid every declaration
    // after it, and a valid ref.func was rejected.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    try m.globals.append(alloc, .{
        .type = .{ .val_type = .funcref, .mutability = .immutable },
        .is_import = true,
    });
    const exprs = [_]u8{ 0x23, 0x00, 0x0b, 0xd2, 0x00, 0x0b }; // global.get 0; ref.func 0
    try m.elem_segments.append(alloc, .{
        .kind = .declared,
        .elem_type = .funcref,
        .elem_expr_bytes = &exprs,
        .elem_expr_count = 2,
    });
    const body = [_]u8{ 0xd2, 0x00, 0x1a, 0x0b }; // ref.func 0; drop; end
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try validate(&m, .{});
}

test "every part of a module outside its bodies declares the functions it names" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    const binary_reader = @import("binary/reader.zig");
    const writer = @import("binary/writer.zig");

    // `ref.func x` in a body is valid only where x is declared, and the set
    // of declarations is `funcidx(global* mem* table* elem* export*)`: the
    // function indices written in the module's defined globals, tables,
    // element segments and exports. Table initializers used to be left out,
    // which rejected the modules issue #418 reported, and so were global
    // initializers.
    const cases = [_]struct { wat: []const u8, err: ?Error = null }{
        // Element segments, in each of their forms.
        .{ .wat = "(module (type (func)) (func) (elem declare func 0) (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (elem declare funcref (item ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table 1 funcref) (elem (i32.const 0) 0)" ++
            " (func ref.func 0 drop))" },
        // An export.
        .{ .wat = "(module (type (func)) (func) (export \"f\" (func 0)) (func ref.func 0 drop))" },
        // A global initializer, whatever the global's type or mutability.
        .{ .wat = "(module (type (func)) (func) (global funcref (ref.func 0)) (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (global (ref func) (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (global (ref 0) (ref.func 0)) (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (global (mut funcref) (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (global funcref (ref.null func))" ++
            " (global funcref (ref.func 0)) (func ref.func 0 drop))" },
        // A table initializer, which is what issue #418 was about.
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table 1 funcref (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table 1 (ref 0) (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table i64 1 (ref func) (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table 1 funcref) (table 1 (ref func) (ref.func 0))" ++
            " (func ref.func 0 drop))" },
        // The declaration set is the whole module's, so it does not matter
        // whether the declaration is written before the body or after it,
        // nor whether the body's `ref.func` is reachable.
        .{ .wat = "(module (type (func)) (func) (func ref.func 0 drop) (global funcref (ref.func 0)))" },
        .{ .wat = "(module (type (func)) (func) (func ref.func 0 drop) (table 1 (ref func) (ref.func 0)))" },
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0))" ++
            " (func unreachable ref.func 0 drop))" },
        // An imported function is declared the same way as a defined one.
        .{ .wat = "(module (type (func)) (import \"m\" \"f\" (func (type 0)))" ++
            " (table 1 (ref func) (ref.func 0)) (func ref.func 0 drop))" },

        // Nothing else declares. A function that no global, table, element
        // segment or export names cannot be referred to, however else it is
        // mentioned.
        .{ .wat = "(module (type (func)) (func) (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        .{ .wat = "(module (type (func)) (func) (start 0) (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        .{ .wat = "(module (type (func)) (func) (memory 1) (data (i32.const 0) \"x\")" ++
            " (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        // A mention in another body is not a declaration either.
        .{ .wat = "(module (type (func)) (func) (func) (elem declare func 1)" ++
            " (func ref.func 1 drop) (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        // An initializer that names no function declares no function.
        .{ .wat = "(module (type (func)) (func) (table 1 funcref (ref.null func))" ++
            " (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        .{ .wat = "(module (type (func)) (func) (global funcref (ref.null func))" ++
            " (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        .{ .wat = "(module (type (func)) (import \"m\" \"g\" (global funcref)) (func)" ++
            " (table 1 funcref (global.get 0)) (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        // An imported table brings no initializer with it.
        .{ .wat = "(module (type (func)) (import \"m\" \"t\" (table 1 funcref)) (func)" ++
            " (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        // A declaration is of the function it names and of no other.
        .{ .wat = "(module (type (func)) (func) (func) (table 1 (ref func) (ref.func 1))" ++
            " (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
        .{ .wat = "(module (type (func)) (func) (func) (global funcref (ref.func 1))" ++
            " (func ref.func 0 drop))", .err = error.InvalidFuncIndex },
    };

    for (cases) |c| {
        var parsed = try Parser.parseModule(alloc, c.wat);
        defer parsed.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&parsed, .{})) else try validate(&parsed, .{});

        // The verdict must not depend on the front end: the reader and the
        // parser fill in initializers and segments by different routes.
        const bytes = try writer.writeModule(alloc, &parsed);
        defer alloc.free(bytes);
        var read_back = try binary_reader.readModule(alloc, bytes);
        defer read_back.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&read_back, .{})) else try validate(&read_back, .{});
    }
}

test "a non-nullable table's initializer declares the element table.grow and table.fill write" {
    const alloc = std.testing.allocator;
    const Parser = @import("text/Parser.zig");
    const binary_reader = @import("binary/reader.zig");
    const writer = @import("binary/writer.zig");

    // The four modules issue #418 was found from: a `(ref func)` table has
    // to be initialised, its initializer is the only mention of the
    // function, and growing or filling the table needs that same function as
    // a value. wasm-tools 1.250.0 accepts all four.
    const cases = [_]struct { wat: []const u8, err: ?Error = null }{
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0))" ++
            " (func ref.func 0 i32.const 1 table.grow 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table i64 1 (ref func) (ref.func 0))" ++
            " (func ref.func 0 i64.const 1 table.grow 0 drop))" },
        .{ .wat = "(module (type (func)) (func) (table 1 (ref func) (ref.func 0))" ++
            " (func i32.const 0 ref.func 0 i32.const 1 table.fill 0))" },
        .{ .wat = "(module (type (func)) (func) (table i64 1 (ref func) (ref.func 0))" ++
            " (func i64.const 0 ref.func 0 i64.const 1 table.fill 0))" },
        // The other function the module defines is still undeclared.
        .{ .wat = "(module (type (func)) (func) (func) (table 1 (ref func) (ref.func 0))" ++
            " (func ref.func 1 i32.const 1 table.grow 0 drop))", .err = error.InvalidFuncIndex },
        .{ .wat = "(module (type (func)) (func) (func) (table i64 1 (ref func) (ref.func 0))" ++
            " (func i64.const 0 ref.func 1 i64.const 1 table.fill 0))", .err = error.InvalidFuncIndex },
    };

    for (cases) |c| {
        var parsed = try Parser.parseModule(alloc, c.wat);
        defer parsed.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&parsed, .{})) else try validate(&parsed, .{});

        const bytes = try writer.writeModule(alloc, &parsed);
        defer alloc.free(bytes);
        var read_back = try binary_reader.readModule(alloc, bytes);
        defer read_back.deinit();
        if (c.err) |e| try std.testing.expectError(e, validate(&read_back, .{})) else try validate(&read_back, .{});
    }
}

/// A module of `func_count` functions of type `(func)`, one table of the
/// given element type initialised by `table_init`, one global of type
/// `funcref` initialised by `global_init`, and one function whose body is
/// `body`. Empty initializers are left out, so a case says only what it is
/// about.
fn testDeclarationModule(
    alloc: std.mem.Allocator,
    func_count: usize,
    table_init: []const u8,
    global_init: []const u8,
    body: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(alloc);
    errdefer module.deinit();
    try module.module_types.append(alloc, .{ .func_type = .{} });
    for (0..func_count) |_| {
        try module.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    }
    if (table_init.len > 0) {
        try module.tables.append(alloc, .{
            .type = .{ .elem_type = .funcref, .limits = .{ .initial = 1 } },
            .init_expr_bytes = table_init,
        });
    }
    if (global_init.len > 0) {
        try module.globals.append(alloc, .{
            .type = .{ .val_type = .funcref, .mutability = .immutable },
            .init_expr_bytes = global_init,
        });
    }
    try module.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

test "an initializer's function index is decoded rather than searched for" {
    const alloc = std.testing.allocator;

    // `ref.func 11` encodes as d2 0b, and 0x0b is also `end`: an index read
    // by looking at bytes rather than by decoding the instruction that
    // carries it splits the instruction in half. The index is also read
    // exactly as written, so a padded LEB names the same function as a
    // short one.
    const ref_func_11 = [_]u8{ 0xd2, 0x0b }; // ref.func 11
    const ref_func_0_padded = [_]u8{ 0xd2, 0x80, 0x80, 0x00 }; // ref.func 0
    const body_11 = [_]u8{ 0xd2, 0x0b, 0x1a, 0x0b }; // ref.func 11; drop; end
    const body_0 = [_]u8{ 0xd2, 0x00, 0x1a, 0x0b }; // ref.func 0; drop; end

    var from_table = try testDeclarationModule(alloc, 12, &ref_func_11, &.{}, &body_11);
    defer from_table.deinit();
    try validate(&from_table, .{});

    var from_global = try testDeclarationModule(alloc, 12, &.{}, &ref_func_11, &body_11);
    defer from_global.deinit();
    try validate(&from_global, .{});

    var padded = try testDeclarationModule(alloc, 1, &ref_func_0_padded, &.{}, &body_0);
    defer padded.deinit();
    try validate(&padded, .{});

    // The function next to the one declared is still not declared.
    var neighbour = try testDeclarationModule(alloc, 12, &ref_func_11, &.{}, &body_0);
    defer neighbour.deinit();
    try std.testing.expectError(error.InvalidFuncIndex, validate(&neighbour, .{}));
}

test "a declaration after the expressions before it in a run is still found" {
    const alloc = std.testing.allocator;

    // A segment's element expressions are laid end to end, and a global or
    // table initializer may be several instructions long. Reading the run
    // has to step over whole instructions, all the way to its end: a scan
    // that gave up at the first opcode it did not recognise hid every
    // declaration after it.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    for (0..13) |_| try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    try m.globals.append(alloc, .{
        .type = .{ .val_type = .funcref, .mutability = .immutable },
        .is_import = true,
    });
    // global.get 0; end; ref.null func; end; ref.func 11; end; ref.func 1; end
    const exprs = [_]u8{
        0x23, 0x00, 0x0b, 0xd0, 0x70, 0x0b, 0xd2, 0x0b, 0x0b, 0xd2, 0x01, 0x0b,
    };
    try m.elem_segments.append(alloc, .{
        .kind = .declared,
        .elem_type = .funcref,
        .elem_expr_bytes = &exprs,
        .elem_expr_count = 4,
        .uses_elem_exprs = true,
    });
    // ref.func 11; drop; ref.func 1; drop; end
    const body = [_]u8{ 0xd2, 0x0b, 0x1a, 0xd2, 0x01, 0x1a, 0x0b };
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try validate(&m, .{});
}

test "an initializer that runs off its end is reported, not read half way" {
    const alloc = std.testing.allocator;

    // Collecting declarations reads bytes the type-checkers ahead of it have
    // already accepted, but it reads more of them: a truncated immediate is
    // a malformed module, and abandoning the scan there would silently drop
    // the declarations that follow. So it is reported.
    const truncated = [_]u8{0xd2}; // ref.func, with no index
    const body = [_]u8{ 0xd2, 0x00, 0x1a, 0x0b }; // ref.func 0; drop; end

    var table = try testDeclarationModule(alloc, 1, &truncated, &.{}, &body);
    defer table.deinit();
    try std.testing.expectError(error.UnexpectedEnd, validate(&table, .{}));

    var global = try testDeclarationModule(alloc, 1, &.{}, &truncated, &body);
    defer global.deinit();
    try std.testing.expectError(error.UnexpectedEnd, validate(&global, .{}));

    // The same for a run of element expressions, whose tail is read even
    // where it is longer than the count says.
    var seg = Mod.Module.init(alloc);
    defer seg.deinit();
    try seg.module_types.append(alloc, .{ .func_type = .{} });
    try seg.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    const exprs = [_]u8{ 0xd2, 0x00, 0x0b, 0xd2 }; // ref.func 0; end; ref.func …
    try seg.elem_segments.append(alloc, .{
        .kind = .declared,
        .elem_type = .funcref,
        .elem_expr_bytes = &exprs,
        .elem_expr_count = 1,
        .uses_elem_exprs = true,
    });
    try seg.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try std.testing.expectError(error.UnexpectedEnd, validate(&seg, .{}));
}

/// An allocator that fails exactly one allocation -- the first -- and serves
/// every other from the allocator behind it.
///
/// `std.testing.FailingAllocator` cannot express this: once it has induced
/// its failure every later allocation fails too, so a validator that
/// swallowed the failure and carried on would still end up reporting
/// `OutOfMemory` from the next allocation, and the test would pass either
/// way.
const FailFirstAllocator = struct {
    backing: std.mem.Allocator,
    failed: bool = false,

    fn allocator(self: *FailFirstAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(ctx));
        if (!self.failed) {
            self.failed = true;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "a declaration that cannot be recorded is reported rather than dropped" {
    const alloc = std.testing.allocator;

    // The declaration set is a hash map, and a failure to grow it used to be
    // swallowed. That turns an allocation failure into a wrong answer: the
    // module is reported invalid, naming a function that is in fact
    // declared. This module declares function 0 by exporting it, and that
    // record is the first thing validating it allocates.
    var m = Mod.Module.init(alloc);
    defer m.deinit();
    try m.module_types.append(alloc, .{ .func_type = .{} });
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } } });
    try m.exports.append(alloc, .{ .name = "f", .kind = .func, .var_ = .{ .index = 0 } });
    const body = [_]u8{ 0xd2, 0x00, 0x1a, 0x0b }; // ref.func 0; drop; end
    try m.funcs.append(alloc, .{ .decl = .{ .type_var = .{ .index = 0 } }, .code_bytes = &body });
    try validate(&m, .{});

    var failing = FailFirstAllocator{ .backing = alloc };
    m.allocator = failing.allocator();
    defer m.allocator = alloc;
    try std.testing.expectError(error.OutOfMemory, validate(&m, .{}));
    try std.testing.expect(failing.failed);
}
