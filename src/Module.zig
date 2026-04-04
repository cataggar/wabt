//! WebAssembly module IR.
//!
//! In-memory representation of a WebAssembly module, including all
//! sections: types, imports, functions, tables, memories, globals,
//! exports, start, elements, code, data, and custom sections.
//!
//! Modeled after wabt's ir.h.

const std = @import("std");
const types = @import("types.zig");

// ── Location ─────────────────────────────────────────────────────────────

/// Source location for diagnostics.
pub const Location = struct {
    filename: ?[]const u8 = null,
    line: u32 = 0,
    first_column: u32 = 0,
    last_column: u32 = 0,
};

// ── Var ──────────────────────────────────────────────────────────────────

/// A variable reference — either a numeric index or a symbolic name.
pub const Var = union(enum) {
    index: types.Index,
    name: []const u8,

    pub fn isIndex(self: Var) bool {
        return self == .index;
    }

    pub fn isName(self: Var) bool {
        return self == .name;
    }
};

// ── Const ────────────────────────────────────────────────────────────────

/// A runtime constant value.
pub const Const = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32, // bit pattern
    f64: u64, // bit pattern
    v128: u128,
    ref_null: types.ValType,
    ref_func: types.Index,
};

// ── ExprType ─────────────────────────────────────────────────────────────

/// Expression / instruction categories matching wabt's ir.h.
pub const ExprType = enum {
    atomic_load,
    atomic_rmw,
    atomic_rmw_cmpxchg,
    atomic_store,
    atomic_notify,
    atomic_fence,
    atomic_wait,
    binary,
    block,
    br,
    br_if,
    br_on_non_null,
    br_on_null,
    br_table,
    call,
    call_indirect,
    call_ref,
    code_metadata,
    compare,
    @"const",
    convert,
    data_drop,
    drop,
    elem_drop,
    global_get,
    global_set,
    @"if",
    load,
    local_get,
    local_set,
    local_tee,
    loop,
    memory_copy,
    memory_fill,
    memory_grow,
    memory_init,
    memory_size,
    nop,
    quaternary,
    ref_as_non_null,
    ref_func,
    ref_is_null,
    ref_null,
    rethrow,
    @"return",
    return_call,
    return_call_indirect,
    return_call_ref,
    select,
    simd_lane_op,
    simd_load_lane,
    simd_store_lane,
    simd_shuffle_op,
    load_splat,
    load_zero,
    store,
    table_copy,
    table_fill,
    table_get,
    table_grow,
    table_init,
    table_set,
    table_size,
    ternary,
    throw,
    throw_ref,
    @"try",
    try_table,
    unary,
    @"unreachable",
    v128_const,
};

// ── FuncSignature ────────────────────────────────────────────────────────

/// Owned function signature (parameter and result types).
pub const FuncSignature = struct {
    params: []const types.ValType = &.{},
    results: []const types.ValType = &.{},

    pub fn eql(a: FuncSignature, b: FuncSignature) bool {
        return std.mem.eql(types.ValType, a.params, b.params) and
            std.mem.eql(types.ValType, a.results, b.results);
    }
};

// ── TypeEntry ────────────────────────────────────────────────────────────

/// Type section entry: function, struct, or array type (GC proposal).
pub const TypeEntry = union(enum) {
    func_type: FuncSignature,
    struct_type: StructType,
    array_type: ArrayType,

    pub const StructType = struct {
        fields: std.ArrayList(Field),

        pub const Field = struct {
            name: ?[]const u8 = null,
            @"type": types.ValType,
            mutable: bool = false,
        };
    };

    pub const ArrayType = struct {
        field: StructType.Field,
    };
};

// ── FuncDeclaration ──────────────────────────────────────────────────────

/// A function declaration binding a type index to a signature.
pub const FuncDeclaration = struct {
    type_var: Var = .{ .index = types.invalid_index },
    sig: types.FuncType = .{},
};

// ── Import / Export ──────────────────────────────────────────────────────

/// An import entry.
pub const Import = struct {
    module_name: []const u8,
    field_name: []const u8,
    kind: types.ExternalKind,
    func: ?FuncDeclaration = null,
    table: ?types.TableType = null,
    memory: ?types.MemoryType = null,
    global: ?types.GlobalType = null,
    tag: ?types.TagType = null,
};

/// An export entry.
pub const Export = struct {
    name: []const u8,
    kind: types.ExternalKind,
    var_: Var,
};

// ── Instruction ──────────────────────────────────────────────────────────

/// A parsed WebAssembly instruction.
pub const Instruction = union(enum) {
    // Control
    @"unreachable": void,
    nop: void,
    block: BlockType,
    loop: BlockType,
    @"if": BlockType,
    @"else": void,
    end: void,
    br: u32,
    br_if: u32,
    br_table: BrTable,
    @"return": void,
    call: u32,
    call_indirect: struct { type_index: u32, table_index: u32 },

    // Parametric
    drop: void,
    select: void,

    // Variable
    local_get: u32,
    local_set: u32,
    local_tee: u32,
    global_get: u32,
    global_set: u32,

    // Memory
    i32_load: MemArg,
    i64_load: MemArg,
    f32_load: MemArg,
    f64_load: MemArg,
    i32_load8_s: MemArg,
    i32_load8_u: MemArg,
    i32_load16_s: MemArg,
    i32_load16_u: MemArg,
    i64_load8_s: MemArg,
    i64_load8_u: MemArg,
    i64_load16_s: MemArg,
    i64_load16_u: MemArg,
    i64_load32_s: MemArg,
    i64_load32_u: MemArg,
    i32_store: MemArg,
    i64_store: MemArg,
    f32_store: MemArg,
    f64_store: MemArg,
    i32_store8: MemArg,
    i32_store16: MemArg,
    i64_store8: MemArg,
    i64_store16: MemArg,
    i64_store32: MemArg,
    memory_size: u32,
    memory_grow: u32,

    // Constants
    i32_const: i32,
    i64_const: i64,
    f32_const: u32,
    f64_const: u64,

    // Comparison i32
    i32_eqz: void,
    i32_eq: void,
    i32_ne: void,
    i32_lt_s: void,
    i32_lt_u: void,
    i32_gt_s: void,
    i32_gt_u: void,
    i32_le_s: void,
    i32_le_u: void,
    i32_ge_s: void,
    i32_ge_u: void,

    // Comparison i64
    i64_eqz: void,
    i64_eq: void,
    i64_ne: void,
    i64_lt_s: void,
    i64_lt_u: void,
    i64_gt_s: void,
    i64_gt_u: void,
    i64_le_s: void,
    i64_le_u: void,
    i64_ge_s: void,
    i64_ge_u: void,

    // Arithmetic i32
    i32_clz: void,
    i32_ctz: void,
    i32_popcnt: void,
    i32_add: void,
    i32_sub: void,
    i32_mul: void,
    i32_div_s: void,
    i32_div_u: void,
    i32_rem_s: void,
    i32_rem_u: void,
    i32_and: void,
    i32_or: void,
    i32_xor: void,
    i32_shl: void,
    i32_shr_s: void,
    i32_shr_u: void,
    i32_rotl: void,
    i32_rotr: void,

    // Arithmetic i64
    i64_clz: void,
    i64_ctz: void,
    i64_popcnt: void,
    i64_add: void,
    i64_sub: void,
    i64_mul: void,
    i64_div_s: void,
    i64_div_u: void,
    i64_rem_s: void,
    i64_rem_u: void,
    i64_and: void,
    i64_or: void,
    i64_xor: void,
    i64_shl: void,
    i64_shr_s: void,
    i64_shr_u: void,
    i64_rotl: void,
    i64_rotr: void,

    // F32 arithmetic
    f32_abs: void,
    f32_neg: void,
    f32_ceil: void,
    f32_floor: void,
    f32_trunc: void,
    f32_nearest: void,
    f32_sqrt: void,
    f32_add: void,
    f32_sub: void,
    f32_mul: void,
    f32_div: void,
    f32_min: void,
    f32_max: void,
    f32_copysign: void,

    // F64 arithmetic
    f64_abs: void,
    f64_neg: void,
    f64_ceil: void,
    f64_floor: void,
    f64_trunc: void,
    f64_nearest: void,
    f64_sqrt: void,
    f64_add: void,
    f64_sub: void,
    f64_mul: void,
    f64_div: void,
    f64_min: void,
    f64_max: void,
    f64_copysign: void,

    // F32/F64 comparison
    f32_eq: void, f32_ne: void, f32_lt: void, f32_gt: void, f32_le: void, f32_ge: void,
    f64_eq: void, f64_ne: void, f64_lt: void, f64_gt: void, f64_le: void, f64_ge: void,

    // Conversions
    i32_wrap_i64: void,
    i32_trunc_f32_s: void,
    i32_trunc_f32_u: void,
    i32_trunc_f64_s: void,
    i32_trunc_f64_u: void,
    i64_extend_i32_s: void,
    i64_extend_i32_u: void,
    i64_trunc_f32_s: void,
    i64_trunc_f32_u: void,
    i64_trunc_f64_s: void,
    i64_trunc_f64_u: void,
    f32_convert_i32_s: void,
    f32_convert_i32_u: void,
    f32_convert_i64_s: void,
    f32_convert_i64_u: void,
    f32_demote_f64: void,
    f64_convert_i32_s: void,
    f64_convert_i32_u: void,
    f64_convert_i64_s: void,
    f64_convert_i64_u: void,
    f64_promote_f32: void,
    i32_reinterpret_f32: void,
    i64_reinterpret_f64: void,
    f32_reinterpret_i32: void,
    f64_reinterpret_i64: void,

    // Sign extension
    i32_extend8_s: void,
    i32_extend16_s: void,
    i64_extend8_s: void,
    i64_extend16_s: void,
    i64_extend32_s: void,

    // Reference types
    ref_null: types.ValType,
    ref_is_null: void,
    ref_func: u32,

    pub const MemArg = struct {
        align_: u32,
        offset: u32,
    };

    pub const BlockType = union(enum) {
        empty: void,
        val_type: types.ValType,
        type_index: u32,
    };

    pub const BrTable = struct {
        targets: []const u32,
        default_target: u32,
    };
};

// ── Entities ─────────────────────────────────────────────────────────────

/// A defined or imported function.
pub const Func = struct {
    name: ?[]const u8 = null,
    decl: FuncDeclaration = .{},
    local_types: std.ArrayList(types.ValType) = .empty,
    instructions: std.ArrayList(Instruction) = .empty,
    loc: Location = .{},
    is_import: bool = false,
};

/// A defined or imported global.
pub const Global = struct {
    name: ?[]const u8 = null,
    @"type": types.GlobalType = .{},
    loc: Location = .{},
    is_import: bool = false,
};

/// A defined or imported table.
pub const Table = struct {
    name: ?[]const u8 = null,
    @"type": types.TableType = .{},
    loc: Location = .{},
    is_import: bool = false,
};

/// A defined or imported memory.
pub const Memory = struct {
    name: ?[]const u8 = null,
    @"type": types.MemoryType = .{},
    loc: Location = .{},
    is_import: bool = false,
};

/// A defined or imported tag (exception-handling proposal).
pub const Tag = struct {
    name: ?[]const u8 = null,
    @"type": types.TagType = .{},
    loc: Location = .{},
    is_import: bool = false,
};

// ── Segments / Custom ────────────────────────────────────────────────────

/// Element segment.
pub const ElemSegment = struct {
    name: ?[]const u8 = null,
    kind: types.SegmentKind = .active,
    table_var: Var = .{ .index = 0 },
    elem_type: types.ValType = .funcref,
    elem_var_indices: std.ArrayList(Var) = .empty,
};

/// Data segment.
pub const DataSegment = struct {
    name: ?[]const u8 = null,
    kind: types.SegmentKind = .active,
    memory_var: Var = .{ .index = 0 },
    data: []const u8 = &.{},
};

/// Custom section.
pub const Custom = struct {
    name: []const u8,
    data: []const u8 = &.{},
};

// ── Module ───────────────────────────────────────────────────────────────

/// A parsed WebAssembly module — the main IR container.
pub const Module = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    loc: Location = .{},

    // Type section
    module_types: std.ArrayList(TypeEntry) = .empty,

    // Entity lists
    funcs: std.ArrayList(Func) = .empty,
    tables: std.ArrayList(Table) = .empty,
    memories: std.ArrayList(Memory) = .empty,
    globals: std.ArrayList(Global) = .empty,
    tags: std.ArrayList(Tag) = .empty,
    imports: std.ArrayList(Import) = .empty,
    exports: std.ArrayList(Export) = .empty,
    elem_segments: std.ArrayList(ElemSegment) = .empty,
    data_segments: std.ArrayList(DataSegment) = .empty,
    customs: std.ArrayList(Custom) = .empty,

    // Start function (optional)
    start_var: ?Var = null,

    // Import counts for each kind
    num_func_imports: types.Index = 0,
    num_table_imports: types.Index = 0,
    num_memory_imports: types.Index = 0,
    num_global_imports: types.Index = 0,
    num_tag_imports: types.Index = 0,

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Module) void {
        for (self.module_types.items) |entry| {
            switch (entry) {
                .func_type => |ft| {
                    if (ft.params.len > 0) self.allocator.free(ft.params);
                    if (ft.results.len > 0) self.allocator.free(ft.results);
                },
                else => {},
            }
        }
        self.module_types.deinit(self.allocator);
        for (self.funcs.items) |*func| {
            func.local_types.deinit(self.allocator);
            for (func.instructions.items) |instr| {
                switch (instr) {
                    .br_table => |bt| self.allocator.free(bt.targets),
                    else => {},
                }
            }
            func.instructions.deinit(self.allocator);
        }
        self.funcs.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.memories.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.tags.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.elem_segments.deinit(self.allocator);
        self.data_segments.deinit(self.allocator);
        self.customs.deinit(self.allocator);
    }

    /// Get the total number of functions (imports + defined).
    pub fn numFuncs(self: Module) types.Index {
        return @intCast(self.funcs.items.len);
    }

    /// Get the total number of tables (imports + defined).
    pub fn numTables(self: Module) types.Index {
        return @intCast(self.tables.items.len);
    }

    /// Get the total number of memories (imports + defined).
    pub fn numMemories(self: Module) types.Index {
        return @intCast(self.memories.items.len);
    }

    /// Get the total number of globals (imports + defined).
    pub fn numGlobals(self: Module) types.Index {
        return @intCast(self.globals.items.len);
    }

    /// Check if a function index refers to an import.
    pub fn isFuncImport(self: Module, index: types.Index) bool {
        return index < self.num_func_imports;
    }

    /// Check if a table index refers to an import.
    pub fn isTableImport(self: Module, index: types.Index) bool {
        return index < self.num_table_imports;
    }

    /// Check if a memory index refers to an import.
    pub fn isMemoryImport(self: Module, index: types.Index) bool {
        return index < self.num_memory_imports;
    }

    /// Check if a global index refers to an import.
    pub fn isGlobalImport(self: Module, index: types.Index) bool {
        return index < self.num_global_imports;
    }

    /// Check if a tag index refers to an import.
    pub fn isTagImport(self: Module, index: types.Index) bool {
        return index < self.num_tag_imports;
    }

    /// Find an export by name, or return null if not found.
    pub fn getExport(self: Module, name: []const u8) ?*const Export {
        for (self.exports.items) |*exp| {
            if (std.mem.eql(u8, exp.name, name)) return exp;
        }
        return null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "Module init/deinit" {
    var module = Module.init(std.testing.allocator);
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 0), module.funcs.items.len);
}

test "Var" {
    const v1 = Var{ .index = 42 };
    const v2 = Var{ .name = "$main" };
    try std.testing.expect(v1.isIndex());
    try std.testing.expect(v2.isName());
}

test "Const" {
    const c = Const{ .i32 = 42 };
    try std.testing.expectEqual(@as(i32, 42), c.i32);
}

test "ExprType count" {
    const info = @typeInfo(ExprType);
    try std.testing.expectEqual(@as(usize, 71), info.@"enum".fields.len);
}

test "Module getExport" {
    var module = Module.init(std.testing.allocator);
    defer module.deinit();
    try module.exports.append(module.allocator, .{
        .name = "memory",
        .kind = .memory,
        .var_ = .{ .index = 0 },
    });
    try std.testing.expect(module.getExport("memory") != null);
    try std.testing.expect(module.getExport("missing") == null);
}

test "FuncSignature eql" {
    const a = FuncSignature{ .params = &.{.i32}, .results = &.{} };
    const b = FuncSignature{ .params = &.{}, .results = &.{} };
    const c = FuncSignature{ .params = &.{.i32}, .results = &.{} };
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.eql(c));
}

test "Module import helpers" {
    var module = Module.init(std.testing.allocator);
    defer module.deinit();
    module.num_func_imports = 2;
    try std.testing.expect(module.isFuncImport(0));
    try std.testing.expect(module.isFuncImport(1));
    try std.testing.expect(!module.isFuncImport(2));
}

test "Location defaults" {
    const loc = Location{};
    try std.testing.expectEqual(@as(u32, 0), loc.line);
    try std.testing.expect(loc.filename == null);
}
