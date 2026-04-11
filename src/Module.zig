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
    param_type_idxs: []const u32 = &.{},
    result_type_idxs: []const u32 = &.{},

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
        fields: std.ArrayListUnmanaged(Field),

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

// ── Entities ─────────────────────────────────────────────────────────────

/// A defined or imported function.
pub const Func = struct {
    name: ?[]const u8 = null,
    decl: FuncDeclaration = .{},
    local_types: std.ArrayListUnmanaged(types.ValType) = .{},
    loc: Location = .{},
    is_import: bool = false,
    /// Raw instruction bytes (binary format) for validation.
    /// Points into the original wasm bytes (binary path) or an owned buffer (text path).
    code_bytes: []const u8 = &.{},
    /// True when code_bytes is an owned allocation that must be freed.
    owns_code_bytes: bool = false,
};

/// A defined or imported global.
pub const Global = struct {
    name: ?[]const u8 = null,
    @"type": types.GlobalType = .{},
    loc: Location = .{},
    is_import: bool = false,
    /// Raw bytecode for the init expression (constant expr).
    init_expr_bytes: []const u8 = &.{},
    owns_init_expr_bytes: bool = false,
};

/// A defined or imported table.
pub const Table = struct {
    name: ?[]const u8 = null,
    @"type": types.TableType = .{},
    init_expr_bytes: []const u8 = &.{},
    type_idx: u32 = 0xFFFFFFFF,
    loc: Location = .{},
    is_import: bool = false,
    is_table64: bool = false,
};

/// A defined or imported memory.
pub const Memory = struct {
    name: ?[]const u8 = null,
    @"type": types.MemoryType = .{},
    loc: Location = .{},
    is_import: bool = false,
    is_memory64: bool = false,
};

/// A defined or imported tag (exception-handling proposal).
pub const Tag = struct {
    name: ?[]const u8 = null,
    @"type": types.TagType = .{},
    type_idx: u32 = std.math.maxInt(u32),
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
    elem_var_indices: std.ArrayListUnmanaged(Var) = .{},
    /// Raw bytecode for the offset expression (constant expr).
    offset_expr_bytes: []const u8 = &.{},
    owns_offset_expr_bytes: bool = false,
    /// Raw bytecode for elem expressions (used with funcref/externref elem exprs).
    /// Each expression is terminated by 0x0b.
    elem_expr_bytes: []const u8 = &.{},
    owns_elem_expr_bytes: bool = false,
    /// Number of individual elem expressions encoded in elem_expr_bytes.
    elem_expr_count: u32 = 0,
};

/// Data segment.
pub const DataSegment = struct {
    name: ?[]const u8 = null,
    kind: types.SegmentKind = .active,
    memory_var: Var = .{ .index = 0 },
    data: []const u8 = &.{},
    owns_data: bool = false,
    /// Raw bytecode for the offset expression (constant expr).
    offset_expr_bytes: []const u8 = &.{},
    owns_offset_expr_bytes: bool = false,
};

/// Custom section.
pub const Custom = struct {
    name: []const u8,
    data: []const u8 = &.{},
};

/// Per-type metadata for GC subtyping validation.
pub const TypeMeta = struct {
    kind: Kind = .func,
    is_sub: bool = false,
    is_final: bool = true,
    parent: u32 = std.math.maxInt(u32),
    /// Rec group identifier (types in the same rec group share this).
    rec_group: u32 = std.math.maxInt(u32),
    /// Number of types in the rec group.
    rec_group_size: u32 = 1,
    /// Position within the rec group.
    rec_position: u32 = 0,
    /// Type indices referenced by this type's structural content (params/results/fields),
    /// in order of appearance. Used for iso-recursive type canonicalization.
    type_refs: []const u32 = &.{},
    /// Canonical rec group ID — types in iso-recursively equivalent rec groups share this.
    canonical_group: u32 = std.math.maxInt(u32),
    pub const Kind = enum { func, struct_, array };
};

// ── Module ───────────────────────────────────────────────────────────────

/// A parsed WebAssembly module — the main IR container.
pub const Module = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    loc: Location = .{},

    // Type section
    module_types: std.ArrayListUnmanaged(TypeEntry) = .{},
    /// Per-type metadata for GC subtyping validation.
    type_meta: std.ArrayListUnmanaged(TypeMeta) = .{},

    // Entity lists
    funcs: std.ArrayListUnmanaged(Func) = .{},
    tables: std.ArrayListUnmanaged(Table) = .{},
    memories: std.ArrayListUnmanaged(Memory) = .{},
    globals: std.ArrayListUnmanaged(Global) = .{},
    tags: std.ArrayListUnmanaged(Tag) = .{},
    imports: std.ArrayListUnmanaged(Import) = .{},
    exports: std.ArrayListUnmanaged(Export) = .{},
    elem_segments: std.ArrayListUnmanaged(ElemSegment) = .{},
    data_segments: std.ArrayListUnmanaged(DataSegment) = .{},
    customs: std.ArrayListUnmanaged(Custom) = .{},

    // Start function (optional)
    start_var: ?Var = null,

    // Import counts for each kind
    num_func_imports: types.Index = 0,
    num_table_imports: types.Index = 0,
    num_memory_imports: types.Index = 0,
    num_global_imports: types.Index = 0,
    num_tag_imports: types.Index = 0,

    // Data count section
    has_data_count: bool = false,
    data_count: u32 = 0,

    // Heap-allocated name strings (e.g. decoded escape sequences in import/export names).
    owned_strings: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Module) void {
        for (self.module_types.items) |entry| {
            switch (entry) {
                .func_type => |ft| {
                    if (ft.params.len > 0) self.allocator.free(ft.params);
                    if (ft.results.len > 0) self.allocator.free(ft.results);
                    if (ft.param_type_idxs.len > 0) self.allocator.free(ft.param_type_idxs);
                    if (ft.result_type_idxs.len > 0) self.allocator.free(ft.result_type_idxs);
                },
                .struct_type => |st| {
                    var fields = st.fields;
                    fields.deinit(self.allocator);
                },
                else => {},
            }
        }
        self.module_types.deinit(self.allocator);
        for (self.type_meta.items) |tm| {
            if (tm.type_refs.len > 0) self.allocator.free(tm.type_refs);
        }
        self.type_meta.deinit(self.allocator);
        for (self.funcs.items) |*func| {
            func.local_types.deinit(self.allocator);
            if (func.owns_code_bytes and func.code_bytes.len > 0) {
                self.allocator.free(func.code_bytes);
            }
        }
        self.funcs.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.memories.deinit(self.allocator);
        for (self.globals.items) |*g| {
            if (g.owns_init_expr_bytes and g.init_expr_bytes.len > 0) {
                self.allocator.free(g.init_expr_bytes);
            }
        }
        self.globals.deinit(self.allocator);
        for (self.tags.items) |tag| {
            if (tag.@"type".sig.params.len > 0) self.allocator.free(tag.@"type".sig.params);
            if (tag.@"type".sig.results.len > 0) self.allocator.free(tag.@"type".sig.results);
        }
        self.tags.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        for (self.elem_segments.items) |*seg| {
            seg.elem_var_indices.deinit(self.allocator);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                self.allocator.free(seg.offset_expr_bytes);
            }
            if (seg.owns_elem_expr_bytes and seg.elem_expr_bytes.len > 0) {
                self.allocator.free(seg.elem_expr_bytes);
            }
        }
        self.elem_segments.deinit(self.allocator);
        for (self.data_segments.items) |*seg| {
            if (seg.owns_data and seg.data.len > 0) {
                self.allocator.free(seg.data);
            }
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0) {
                self.allocator.free(seg.offset_expr_bytes);
            }
        }
        self.data_segments.deinit(self.allocator);
        self.customs.deinit(self.allocator);
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
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
