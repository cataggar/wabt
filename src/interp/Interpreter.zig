//! WebAssembly interpreter.
//!
//! Stack-based interpreter that executes WebAssembly modules directly,
//! without compilation to native code. Individual operations are exposed
//! as public methods so they can be tested and composed incrementally.

const std = @import("std");
const Mod = @import("../Module.zig");
const types = @import("../types.zig");
const leb128 = @import("../leb128.zig");

const page_size: u32 = types.default_page_size; // 65 536

// ── Errors ───────────────────────────────────────────────────────────────

pub const TrapError = error{
    Unreachable,
    IntegerOverflow,
    IntegerDivisionByZero,
    InvalidConversion,
    OutOfBoundsMemoryAccess,
    OutOfBoundsTableAccess,
    UndefinedElement,
    UninitializedElement,
    IndirectCallTypeMismatch,
    CastFailure,
    StackOverflow,
    CallStackExhausted,
    OutOfMemory,
    Unimplemented,
    InstructionLimitExceeded,
    NullReference,
};

// ── Value ────────────────────────────────────────────────────────────────

/// Runtime value that mirrors the core WebAssembly value types.
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    v128: u128,
    ref_null: void,
    ref_func: u32,
    ref_i31: u32, // i31 reference: stores the 31-bit value
    ref_struct: u32, // index into gc_objects
    ref_array: u32, // index into gc_objects
    ref_extern: u32, // externalized GC reference
    exnref: u32, // Index into interpreter's caught_exceptions list
};

/// A GC-managed object (struct or array instance).
pub const GcObject = struct {
    type_idx: u32, // type index in the module
    fields: std.ArrayListUnmanaged(Value), // struct fields or array elements

    fn deinit(self: *GcObject, allocator: std.mem.Allocator) void {
        self.fields.deinit(allocator);
    }
};

const TailCall = struct {
    func_idx: u32,
    args: [64]Value = undefined,
    arg_count: usize = 0,
};

const ThrownException = struct {
    tag_idx: u32,
    values: [16]Value = undefined,
    value_count: usize = 0,
    source_module: ?*const Mod.Module = null,
};

// ── Instance ─────────────────────────────────────────────────────────────

/// Runtime module instance — holds mutable state (memory, globals, tables).
pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const Mod.Module,

    /// Linear memories — memories[0] is the default; multi-memory adds more.
    memories: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .{},

    /// Global variable values.
    globals: std.ArrayListUnmanaged(Value),

    /// Function tables — `null` entries are uninitialised.
    /// tables[0] is the default table; additional tables for multi-table proposals.
    tables: std.ArrayListUnmanaged(std.ArrayListUnmanaged(?u32)),

    /// Tracks which data segments have been dropped via data.drop.
    dropped_data: std.DynamicBitSetUnmanaged = .{},
    /// Tracks which element segments have been dropped via elem.drop.
    dropped_elems: std.DynamicBitSetUnmanaged = .{},

    /// Per-index shared memory pointers — when set, memory operations use these
    /// instead of the corresponding local memory slot.
    shared_memories: std.AutoHashMapUnmanaged(u32, *std.ArrayListUnmanaged(u8)) = .{},
    /// Per-index max pages for shared (imported) memories.
    shared_memory_max_pages_map: std.AutoHashMapUnmanaged(u32, u64) = .{},

    /// Shared table pointers — when set, table operations use this instead of local tables.
    shared_tables: ?*std.ArrayListUnmanaged(std.ArrayListUnmanaged(?u32)) = null,
    /// Per-index shared tables (for multiple imports from different sources).
    shared_table_map: std.AutoHashMapUnmanaged(u32, *std.ArrayListUnmanaged(?u32)) = .{},

    /// Per-table-entry interpreter refs for cross-module function references.
    /// Key = (tbl_idx << 32) | entry_idx. Only used when tables are shared.
    table_func_refs: std.AutoHashMapUnmanaged(u64, *Interpreter) = .{},
    /// Points to the table owner's table_func_refs when tables are shared.
    shared_table_func_refs: ?*std.AutoHashMapUnmanaged(u64, *Interpreter) = null,

    /// Per-table-entry GC value type tags. Key = (tbl_idx << 32) | entry_idx.
    /// Stores the Value tag (0=ref_func, 1=ref_i31, 2=ref_struct, 3=ref_array, 4=ref_extern).
    table_value_tags: std.AutoHashMapUnmanaged(u64, u8) = .{},

    /// Back-reference to the owning interpreter (set after creation).
    interp_ref: ?*Interpreter = null,

    /// Interpreter refs for imported funcref globals.
    /// Maps global index to the interpreter that owns the referenced function.
    global_func_interps: std.ArrayListUnmanaged(?*Interpreter) = .{},

    /// Get memory by index, following shared memory pointers.
    pub fn getMemory(self: *Instance, idx: u32) *std.ArrayListUnmanaged(u8) {
        if (self.shared_memories.get(idx)) |m| return m;
        if (idx < self.memories.items.len) return &self.memories.items[idx];
        if (self.memories.items.len > 0) return &self.memories.items[0];
        return &self.memories.items[0]; // will panic if no memories
    }

    /// Get default memory (index 0) — convenience for legacy single-memory use.
    pub fn getDefaultMemory(self: *Instance) *std.ArrayListUnmanaged(u8) {
        return self.getMemory(0);
    }

    /// Shorthand to access the default (index 0) table.
    pub fn table(self: *Instance) *std.ArrayListUnmanaged(?u32) {
        const tbls = self.shared_tables orelse &self.tables;
        return &tbls.items[0];
    }

    /// Access a table by index, falling back to index 0.
    pub fn getTable(self: *Instance, idx: u32) *std.ArrayListUnmanaged(?u32) {
        if (self.shared_table_map.get(idx)) |t| return t;
        const tbls = self.shared_tables orelse &self.tables;
        if (idx < tbls.items.len) return &tbls.items[idx];
        return &tbls.items[0];
    }

    /// Get the table func refs map (shared or local).
    pub fn getTableFuncRefs(self: *Instance) *std.AutoHashMapUnmanaged(u64, *Interpreter) {
        return self.shared_table_func_refs orelse &self.table_func_refs;
    }

    fn makeTableKey(tbl_idx: u32, entry_idx: u32) u64 {
        return (@as(u64, tbl_idx) << 32) | entry_idx;
    }

    pub fn init(allocator: std.mem.Allocator, module: *const Mod.Module) TrapError!Instance {
        var inst = Instance{
            .allocator = allocator,
            .module = module,
            .globals = .{},
            .tables = .{},
        };

        // Allocate drop tracking bitsets.
        if (module.data_segments.items.len > 0) {
            inst.dropped_data = std.DynamicBitSetUnmanaged.initEmpty(allocator, module.data_segments.items.len) catch return error.OutOfMemory;
        }
        if (module.elem_segments.items.len > 0) {
            inst.dropped_elems = std.DynamicBitSetUnmanaged.initEmpty(allocator, module.elem_segments.items.len) catch return error.OutOfMemory;
        }

        // Allocate linear memories (skip imported ones, they'll be set via shared_memories).
        const num_mems = if (module.memories.items.len > 0) module.memories.items.len else 1;
        inst.memories.resize(allocator, num_mems) catch return error.OutOfMemory;
        for (0..num_mems) |i| {
            inst.memories.items[i] = .{};
        }
        for (module.memories.items, 0..) |mem, i| {
            if (mem.is_import) continue;
            const initial_pages: usize = @intCast(mem.@"type".limits.initial);
            const byte_count = initial_pages * @as(usize, page_size);
            inst.memories.items[i].resize(allocator, byte_count) catch return error.OutOfMemory;
            @memset(inst.memories.items[i].items, 0);
        }

        // Initialise globals with zero values.
        for (module.globals.items) |g| {
            const val: Value = switch (g.@"type".val_type) {
                .i32 => .{ .i32 = 0 },
                .i64 => .{ .i64 = 0 },
                .f32 => .{ .f32 = 0.0 },
                .f64 => .{ .f64 = 0.0 },
                .funcref => .{ .ref_null = {} },
                .externref => .{ .ref_null = {} },
                else => .{ .i32 = 0 },
            };
            inst.globals.append(allocator, val) catch return error.OutOfMemory;
        }

        // Initialise all tables (skip imported ones, they'll be set via shared_tables).
        if (module.tables.items.len > 0) {
            inst.tables.resize(allocator, module.tables.items.len) catch return error.OutOfMemory;
            for (module.tables.items, 0..) |tbl, i| {
                inst.tables.items[i] = .{};
                if (tbl.is_import) continue; // will be shared via pointer
                const initial: usize = @intCast(tbl.@"type".limits.initial);
                inst.tables.items[i].resize(allocator, initial) catch return error.OutOfMemory;
                @memset(inst.tables.items[i].items, null);
            }
        } else {
            // Ensure at least one empty table exists so table() doesn't panic.
            inst.tables.resize(allocator, 1) catch return error.OutOfMemory;
            inst.tables.items[0] = .{};
        }

        return inst;
    }

    pub fn deinit(self: *Instance) void {
        for (self.memories.items) |*m| m.deinit(self.allocator);
        self.memories.deinit(self.allocator);
        self.shared_memories.deinit(self.allocator);
        self.shared_table_map.deinit(self.allocator);
        self.shared_memory_max_pages_map.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        for (self.tables.items) |*t| t.deinit(self.allocator);
        self.tables.deinit(self.allocator);
        self.table_func_refs.deinit(self.allocator);
        self.table_value_tags.deinit(self.allocator);
        self.global_func_interps.deinit(self.allocator);
        self.dropped_data.deinit(self.allocator);
        self.dropped_elems.deinit(self.allocator);
    }

    /// Run module instantiation: evaluate global init exprs, copy data segments,
    /// populate tables from element segments.
    pub fn instantiate(self: *Instance) TrapError!void {
        // Evaluate global init expressions
        for (self.module.globals.items, 0..) |g, i| {
            if (g.init_expr_bytes.len > 0) {
                const val = evalConstExpr(self, g.init_expr_bytes) orelse continue;
                if (i < self.globals.items.len) self.globals.items[i] = val;
            }
        }

        // Evaluate table init expressions (fill all entries with init value)
        for (self.module.tables.items, 0..) |tbl_def, ti| {
            if (tbl_def.init_expr_bytes.len > 0 and !tbl_def.is_import) {
                const val = evalConstExpr(self, tbl_def.init_expr_bytes);
                if (val) |v| {
                    const func_idx: ?u32 = switch (v) {
                        .ref_func => |idx| idx,
                        .ref_i31 => |iv| iv,
                        .ref_null => null,
                        else => null,
                    };
                    const tbl = self.getTable(@intCast(ti));
                    for (tbl.items) |*entry| entry.* = func_idx;
                }
            }
        }

        // Populate tables from active element segments (before data segments per spec)
        for (self.module.elem_segments.items) |seg| {
            if (seg.kind != .active) continue;
            const tbl_idx: u32 = switch (seg.table_var) {
                .index => |idx| idx,
                .name => 0,
            };
            const tbl = self.getTable(tbl_idx);
            var offset: usize = 0;
            if (seg.offset_expr_bytes.len > 0) {
                const off_val = evalConstExpr(self, seg.offset_expr_bytes);
                if (off_val) |v| {
                    offset = switch (v) {
                        .i32 => |x| @intCast(@as(u32, @bitCast(x))),
                        .i64 => |x| @intCast(@as(u64, @bitCast(x))),
                        else => 0,
                    };
                }
            }

            // Bounds check for empty elem segments (offset must be ≤ table.size)
            const elem_count = @max(seg.elem_var_indices.items.len, @as(usize, seg.elem_expr_count));
            if (offset + elem_count > tbl.items.len) {
                return error.OutOfBoundsTableAccess;
            }
            if (offset > tbl.items.len) {
                return error.OutOfBoundsTableAccess;
            }

            // Try elem expressions first (funcref expressions like ref.func, global.get)
            if (seg.elem_expr_count > 0 and seg.elem_expr_bytes.len > 0) {
                var expr_pc: usize = 0;
                var expr_i: u32 = 0;
                while (expr_i < seg.elem_expr_count) : (expr_i += 1) {
                    const entry_idx: u32 = @intCast(offset + expr_i);
                    const expr_start = expr_pc;
                    // Detect if expression is global.get (0x23) for funcref source tracking
                    var source_interp: ?*Interpreter = self.interp_ref;
                    if (expr_pc < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc] == 0x23) {
                        // global.get — check if it references an imported funcref global
                        var tmp = expr_pc + 1;
                        const gidx = readCodeU32(seg.elem_expr_bytes, &tmp);
                        if (gidx < self.global_func_interps.items.len) {
                            if (self.global_func_interps.items[gidx]) |gi| {
                                source_interp = gi;
                            }
                        }
                    }
                    // Find the end of this expression
                    while (expr_pc < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc] != 0x0b) {
                        expr_pc += 1;
                    }
                    if (expr_pc < seg.elem_expr_bytes.len) expr_pc += 1; // skip 0x0b
                    const val = evalConstExpr(self, seg.elem_expr_bytes[expr_start..expr_pc]);
                    if (val) |v| switch (v) {
                        .ref_func => |func_idx| {
                            tbl.items[entry_idx] = func_idx;
                            if (source_interp) |interp| {
                                const refs = self.getTableFuncRefs();
                                refs.put(self.allocator, makeTableKey(tbl_idx, entry_idx), interp) catch {};
                            }
                        },
                        .ref_i31 => |i31_val| {
                            tbl.items[entry_idx] = i31_val;
                            self.table_value_tags.put(self.allocator, makeTableKey(tbl_idx, entry_idx), 1) catch {};
                        },
                        .ref_struct => |s_val| {
                            tbl.items[entry_idx] = s_val;
                            self.table_value_tags.put(self.allocator, makeTableKey(tbl_idx, entry_idx), 2) catch {};
                        },
                        .ref_array => |a_val| {
                            tbl.items[entry_idx] = a_val;
                            self.table_value_tags.put(self.allocator, makeTableKey(tbl_idx, entry_idx), 3) catch {};
                        },
                        .ref_null => {
                            tbl.items[entry_idx] = null;
                        },
                        else => {},
                    };
                }
            } else if (seg.elem_var_indices.items.len > 0) {
                for (seg.elem_var_indices.items, 0..) |var_, j| {
                    const table_entry = offset + j;
                    switch (var_) {
                        .index => |idx| {
                            tbl.items[table_entry] = idx;
                            if (self.interp_ref) |interp| {
                                const refs = self.getTableFuncRefs();
                                refs.put(self.allocator, makeTableKey(tbl_idx, @intCast(table_entry)), interp) catch {};
                            }
                        },
                        .name => {},
                    }
                }
            }
        }

        // Implicitly drop active and declarative elem segments (per spec)
        for (self.module.elem_segments.items, 0..) |seg, seg_i| {
            if (seg.kind == .active or seg.kind == .declared) {
                if (seg_i < self.dropped_elems.capacity()) {
                    self.dropped_elems.set(seg_i);
                }
            }
        }

        // Copy active data segments into memory (after elem segments per spec,
        // so table entries persist even if data segment init traps)
        for (self.module.data_segments.items) |seg| {
            if (seg.kind != .active) continue;
            var offset: usize = 0;
            if (seg.offset_expr_bytes.len > 0) {
                const off_val = evalConstExpr(self, seg.offset_expr_bytes);
                if (off_val) |v| {
                    offset = switch (v) {
                        .i32 => |x| @intCast(@as(u32, @bitCast(x))),
                        .i64 => |x| @intCast(@as(u64, @bitCast(x))),
                        else => 0,
                    };
                }
            }
            const mem_idx: u32 = switch (seg.memory_var) {
                .index => |idx| idx,
                .name => 0,
            };
            const mem = self.getMemory(mem_idx);
            if (offset + seg.data.len > mem.items.len) {
                return error.OutOfBoundsMemoryAccess;
            }
            if (seg.data.len > 0) {
                @memcpy(mem.items[offset .. offset + seg.data.len], seg.data);
            }
        }
    }
};

// ── Interpreter ──────────────────────────────────────────────────────────

/// A resolved import link: points to the source interpreter + func index.
pub const ImportLink = struct {
    interpreter: *Interpreter,
    func_idx: u32,
};

pub const GlobalLink = struct {
    instance: *Instance,
    global_idx: u32,
};

/// Stack-based WebAssembly interpreter.
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    instance: *Instance,

    /// Operand stack.
    stack: std.ArrayListUnmanaged(Value),

    /// Current call nesting depth.
    call_depth: u32 = 0,
    /// Maximum allowed call nesting depth.
    max_call_depth: u32 = 1000,
    /// Remaining branch depth (set by br/br_if instructions).
    branch_depth: ?u32 = null,
    /// Set when a return instruction is executed.
    returning: bool = false,
    /// Pending tail call: set by return_call/return_call_indirect.
    pending_tail_call: ?TailCall = null,
    /// Pending thrown exception (propagating upward).
    thrown_exception: ?ThrownException = null,
    /// Instruction counter for execution limit.
    instruction_count: u64 = 0,
    /// Maximum instructions before trap (prevents infinite loops).
    max_instructions: u64 = 10_000_000,

    /// Caught exceptions storage for exnref values.
    caught_exceptions: std.ArrayListUnmanaged(ThrownException) = .{},

    /// GC object heap for struct and array instances.
    gc_objects: std.ArrayListUnmanaged(GcObject) = .{},

    /// Resolved function import links (indexed by func_idx for imported funcs).
    import_links: std.ArrayListUnmanaged(?ImportLink) = .{},

    /// Links imported globals to exporting instance's globals for shared mutation.
    global_links: std.ArrayListUnmanaged(?GlobalLink) = .{},
    tag_canonical_ids: std.ArrayListUnmanaged(u64) = .{},

    /// Maps extern ref index to original Value for any.convert_extern roundtrip.
    extern_originals: std.AutoHashMapUnmanaged(u32, Value) = .{},
    next_extern_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, instance: *Instance) Interpreter {
        return .{
            .allocator = allocator,
            .instance = instance,
            .stack = .{},
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit(self.allocator);
        self.import_links.deinit(self.allocator);
        self.global_links.deinit(self.allocator);
        self.tag_canonical_ids.deinit(self.allocator);
        self.caught_exceptions.deinit(self.allocator);
        for (self.gc_objects.items) |*obj| obj.deinit(self.allocator);
        self.gc_objects.deinit(self.allocator);
        self.extern_originals.deinit(self.allocator);
    }

    /// Allocate a new GC struct object, returns its index.
    fn allocStruct(self: *Interpreter, type_idx: u32, fields: []const Value) TrapError!u32 {
        const idx: u32 = @intCast(self.gc_objects.items.len);
        var obj = GcObject{ .type_idx = type_idx, .fields = .{} };
        obj.fields.appendSlice(self.allocator, fields) catch return error.OutOfMemory;
        self.gc_objects.append(self.allocator, obj) catch return error.OutOfMemory;
        return idx;
    }

    /// Allocate a new GC array object, returns its index.
    fn allocArray(self: *Interpreter, type_idx: u32, len: u32, init_val: Value) TrapError!u32 {
        const idx: u32 = @intCast(self.gc_objects.items.len);
        var obj = GcObject{ .type_idx = type_idx, .fields = .{} };
        obj.fields.appendNTimes(self.allocator, init_val, len) catch return error.OutOfMemory;
        self.gc_objects.append(self.allocator, obj) catch return error.OutOfMemory;
        return idx;
    }

    /// Get the number of fields in a struct type.
    fn getStructFieldCount(self: *Interpreter, type_idx: u32) u32 {
        if (type_idx < self.instance.module.module_types.items.len) {
            switch (self.instance.module.module_types.items[type_idx]) {
                .struct_type => |st| return @intCast(st.fields.items.len),
                else => {},
            }
        }
        return 0;
    }

    /// Get the default value for a field at the given index in a struct/array type.
    fn getDefaultFieldValue(self: *Interpreter, type_idx: u32, field_idx: u32) Value {
        if (type_idx < self.instance.module.module_types.items.len) {
            switch (self.instance.module.module_types.items[type_idx]) {
                .struct_type => |st| {
                    if (field_idx < st.fields.items.len) {
                        return defaultForValType(st.fields.items[field_idx].type);
                    }
                },
                .array_type => |at| {
                    return defaultForValType(at.field.type);
                },
                else => {},
            }
        }
        return .{ .i32 = 0 };
    }

    /// Read a global value, following links for imported globals.
    pub fn getGlobal(self: *Interpreter, idx: u32) Value {
        if (idx < self.global_links.items.len) {
            if (self.global_links.items[idx]) |link| {
                return link.instance.globals.items[link.global_idx];
            }
        }
        return self.instance.globals.items[idx];
    }

    /// Write a global value, following links for imported globals.
    fn setGlobal(self: *Interpreter, idx: u32, val: Value) void {
        if (idx < self.global_links.items.len) {
            if (self.global_links.items[idx]) |link| {
                link.instance.globals.items[link.global_idx] = val;
                return;
            }
        }
        self.instance.globals.items[idx] = val;
    }

    /// Call an exported function by name (single return value).
    pub fn callExport(self: *Interpreter, name: []const u8, args: []const Value) TrapError!?Value {
        const exp = self.instance.module.getExport(name) orelse return error.UndefinedElement;
        if (exp.kind != .func) return error.UndefinedElement;
        const idx: u32 = switch (exp.var_) {
            .index => |i| i,
            .name => return error.Unimplemented,
        };
        self.instruction_count = 0;
        const stack_base = self.stack.items.len;
        try self.callFunc(idx, args);
        if (self.thrown_exception != null) return error.Unreachable;
        const result: ?Value = if (self.stack.items.len > stack_base) self.stack.items[stack_base] else null;
        self.stack.shrinkRetainingCapacity(stack_base);
        return result;
    }

    /// Call an exported function by name, returning all result values.
    pub fn callExportMulti(self: *Interpreter, name: []const u8, args: []const Value, results_buf: []Value) TrapError![]Value {
        const exp = self.instance.module.getExport(name) orelse return error.UndefinedElement;
        if (exp.kind != .func) return error.UndefinedElement;
        const idx: u32 = switch (exp.var_) {
            .index => |i| i,
            .name => return error.Unimplemented,
        };
        self.instruction_count = 0;
        const stack_base = self.stack.items.len;
        try self.callFunc(idx, args);
        // Uncaught exception at top level → error
        if (self.thrown_exception != null) return error.Unreachable;
        const num_results = self.stack.items.len - stack_base;
        const n = @min(num_results, results_buf.len);
        for (0..n) |i| {
            results_buf[i] = self.stack.items[stack_base + i];
        }
        self.stack.shrinkRetainingCapacity(stack_base);
        return results_buf[0..n];
    }

    /// Call a function by index. Results are left on the operand stack.
    pub fn callFunc(self: *Interpreter, func_idx: u32, args: []const Value) TrapError!void {
        if (self.call_depth >= self.max_call_depth) return error.CallStackExhausted;
        if (func_idx >= self.instance.module.funcs.items.len) return error.UndefinedElement;

        self.call_depth += 1;
        defer self.call_depth -= 1;

        var current_func_idx = func_idx;
        var current_args_buf: [64]Value = undefined;
        var current_args_heap: ?[]Value = null;
        defer if (current_args_heap) |h| self.allocator.free(h);
        var current_arg_count: usize = args.len;
        if (args.len <= 64) {
            for (args, 0..) |a, i| current_args_buf[i] = a;
        } else {
            current_args_heap = self.allocator.alloc(Value, args.len) catch return error.OutOfMemory;
            @memcpy(current_args_heap.?, args);
        }

        // Tail-call trampoline loop
        while (true) {
            const cur_args = if (current_args_heap) |h| h[0..current_arg_count] else current_args_buf[0..current_arg_count];
            const func = self.instance.module.funcs.items[current_func_idx];
            if (func.is_import) {
                if (current_func_idx < self.import_links.items.len) {
                    if (self.import_links.items[current_func_idx]) |link| {
                        const link_base = link.interpreter.stack.items.len;
                        try link.interpreter.callFunc(link.func_idx, cur_args);
                        // Propagate thrown exception from imported module
                        if (link.interpreter.thrown_exception != null) {
                            self.thrown_exception = link.interpreter.thrown_exception;
                            link.interpreter.thrown_exception = null;
                            link.interpreter.stack.shrinkRetainingCapacity(link_base);
                            return;
                        }
                        const link_results = link.interpreter.stack.items[link_base..];
                        for (link_results) |v| try self.pushValue(v);
                        link.interpreter.stack.shrinkRetainingCapacity(link_base);
                        return;
                    }
                }
                return error.Unimplemented;
            }

            const code = func.code_bytes;
            if (code.len == 0) return;

            const sig = self.resolveSig(func.decl);
            const num_locals = sig.params.len + func.local_types.items.len;
            // Use stack buffer for small local counts, heap for large
            var locals_stack_buf: [32]Value = undefined;
            var locals_heap: ?[]Value = null;
            var locals: []Value = undefined;
            if (num_locals <= 32) {
                locals = locals_stack_buf[0..num_locals];
            } else {
                locals_heap = self.allocator.alloc(Value, num_locals) catch return error.OutOfMemory;
                locals = locals_heap.?;
            }
            defer if (locals_heap) |h| self.allocator.free(h);
            for (cur_args, 0..) |arg, i| {
                if (i < locals.len) locals[i] = arg;
            }
            for (sig.params.len..num_locals) |i| {
                if (i < func.local_types.items.len + sig.params.len) {
                    const lt = func.local_types.items[i - sig.params.len];
                    locals[i] = switch (lt) {
                        .i64 => .{ .i64 = 0 },
                        .f32 => .{ .f32 = 0.0 },
                        .f64 => .{ .f64 = 0.0 },
                        .v128 => .{ .v128 = 0 },
                        .funcref, .externref, .anyref, .exnref,
                        .nullfuncref, .nullexternref, .nullref,
                        .ref, .ref_null,
                        .ref_func, .ref_extern, .ref_any,
                        .ref_none, .ref_nofunc, .ref_noextern,
                        => .{ .ref_null = {} },
                        else => .{ .i32 = 0 },
                    };
                }
            }

            const saved_branch = self.branch_depth;
            const saved_returning = self.returning;
            self.branch_depth = null;
            self.returning = false;

            const stack_base = self.stack.items.len;
            _ = try self.dispatch(code, 0, locals);

            // Check for tail call before compacting
            if (self.pending_tail_call) |tc| {
                self.pending_tail_call = null;
                self.returning = saved_returning;
                self.branch_depth = saved_branch;
                self.stack.shrinkRetainingCapacity(stack_base);
                current_func_idx = tc.func_idx;
                current_arg_count = tc.arg_count;
                // Tail calls always fit in 64 args (TailCall uses [64]Value)
                if (current_args_heap) |h| { self.allocator.free(h); current_args_heap = null; }
                for (0..tc.arg_count) |i| current_args_buf[i] = tc.args[i];
                continue;
            }

            self.branch_depth = saved_branch;
            self.returning = saved_returning;

            // Compact results
            const num_on_stack = self.stack.items.len -| stack_base;
            const expected = sig.results.len;
            if (expected > 0 and num_on_stack > expected) {
                const src_start = self.stack.items.len - expected;
                for (0..expected) |i| {
                    self.stack.items[stack_base + i] = self.stack.items[src_start + i];
                }
                self.stack.shrinkRetainingCapacity(stack_base + expected);
            } else if (expected == 0) {
                self.stack.shrinkRetainingCapacity(stack_base);
            }
            break;
        }
    }

    /// Resolve function signature from a FuncDeclaration.
    fn resolveSig(self: *Interpreter, decl: Mod.FuncDeclaration) types.FuncType {
        if (decl.type_var == .index) {
            const idx = decl.type_var.index;
            if (idx < self.instance.module.module_types.items.len) {
                const te = self.instance.module.module_types.items[idx];
                switch (te) {
                    .func_type => |ft| return .{ .params = ft.params, .results = ft.results },
                    else => {},
                }
            }
        }
        return decl.sig;
    }

    // ── Stack helpers ────────────────────────────────────────────────────

    pub fn pushValue(self: *Interpreter, v: Value) TrapError!void {
        self.stack.append(self.allocator, v) catch return error.OutOfMemory;
    }

    pub fn popValue(self: *Interpreter) TrapError!Value {
        if (self.stack.items.len == 0) return error.StackOverflow;
        return self.stack.pop() orelse error.StackOverflow;
    }

    pub fn peekValue(self: *Interpreter) TrapError!Value {
        if (self.stack.items.len == 0) return error.StackOverflow;
        return self.stack.items[self.stack.items.len - 1];
    }

    pub fn popI32(self: *Interpreter) TrapError!i32 {
        const v = try self.popValue();
        return switch (v) {
            .i32 => |x| x,
            else => error.Unimplemented,
        };
    }

    pub fn popI64(self: *Interpreter) TrapError!i64 {
        const v = try self.popValue();
        return switch (v) {
            .i64 => |x| x,
            else => error.Unimplemented,
        };
    }

    pub fn popF32(self: *Interpreter) TrapError!f32 {
        const v = try self.popValue();
        return switch (v) {
            .f32 => |x| x,
            else => error.Unimplemented,
        };
    }

    pub fn popF64(self: *Interpreter) TrapError!f64 {
        const v = try self.popValue();
        return switch (v) {
            .f64 => |x| x,
            else => error.Unimplemented,
        };
    }

    // ── Constants ────────────────────────────────────────────────────────

    pub fn i32Const(self: *Interpreter, v: i32) TrapError!void {
        try self.pushValue(.{ .i32 = v });
    }

    pub fn i64Const(self: *Interpreter, v: i64) TrapError!void {
        try self.pushValue(.{ .i64 = v });
    }

    pub fn f32Const(self: *Interpreter, v: f32) TrapError!void {
        try self.pushValue(.{ .f32 = v });
    }

    pub fn f64Const(self: *Interpreter, v: f64) TrapError!void {
        try self.pushValue(.{ .f64 = v });
    }

    // ── i32 arithmetic ──────────────────────────────────────────────────

    pub fn i32Add(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = a +% b });
    }

    pub fn i32Sub(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = a -% b });
    }

    pub fn i32Mul(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = a *% b });
    }

    pub fn i32DivS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        if (b == 0) return error.IntegerDivisionByZero;
        if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
        try self.pushValue(.{ .i32 = @divTrunc(a, b) });
    }

    pub fn i32DivU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        if (b == 0) return error.IntegerDivisionByZero;
        try self.pushValue(.{ .i32 = @bitCast(a / b) });
    }

    pub fn i32RemS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        if (b == 0) return error.IntegerDivisionByZero;
        // minInt % -1 == 0 in wasm (no trap)
        if (a == std.math.minInt(i32) and b == -1) {
            try self.pushValue(.{ .i32 = 0 });
        } else {
            try self.pushValue(.{ .i32 = @rem(a, b) });
        }
    }

    pub fn i32RemU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        if (b == 0) return error.IntegerDivisionByZero;
        try self.pushValue(.{ .i32 = @bitCast(a % b) });
    }

    // ── i32 comparison ──────────────────────────────────────────────────

    pub fn i32Eqz(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a == 0) });
    }

    pub fn i32Eq(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a == b) });
    }

    pub fn i32Ne(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a != b) });
    }

    pub fn i32LtS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a < b) });
    }

    pub fn i32LtU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intFromBool(a < b) });
    }

    pub fn i32GtS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a > b) });
    }

    pub fn i32GtU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intFromBool(a > b) });
    }

    pub fn i32LeS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a <= b) });
    }

    pub fn i32LeU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intFromBool(a <= b) });
    }

    pub fn i32GeS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @intFromBool(a >= b) });
    }

    pub fn i32GeU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intFromBool(a >= b) });
    }

    // ── i32 bitwise ─────────────────────────────────────────────────────

    pub fn i32And(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = a & b });
    }

    pub fn i32Or(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = a | b });
    }

    pub fn i32Xor(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = a ^ b });
    }

    pub fn i32Shl(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        const shift: u5 = @truncate(@as(u32, @bitCast(b)));
        try self.pushValue(.{ .i32 = a << shift });
    }

    pub fn i32ShrS(self: *Interpreter) TrapError!void {
        const b = try self.popI32();
        const a = try self.popI32();
        const shift: u5 = @truncate(@as(u32, @bitCast(b)));
        try self.pushValue(.{ .i32 = a >> shift });
    }

    pub fn i32ShrU(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        const shift: u5 = @truncate(b);
        try self.pushValue(.{ .i32 = @bitCast(a >> shift) });
    }

    pub fn i32Rotl(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @bitCast(std.math.rotl(u32, a, b)) });
    }

    pub fn i32Rotr(self: *Interpreter) TrapError!void {
        const b: u32 = @bitCast(try self.popI32());
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @bitCast(std.math.rotr(u32, a, b)) });
    }

    pub fn i32Clz(self: *Interpreter) TrapError!void {
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intCast(@clz(a)) });
    }

    pub fn i32Ctz(self: *Interpreter) TrapError!void {
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intCast(@ctz(a)) });
    }

    pub fn i32Popcnt(self: *Interpreter) TrapError!void {
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i32 = @intCast(@popCount(a)) });
    }

    // ── i64 arithmetic ──────────────────────────────────────────────────

    pub fn i64Add(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = a +% b });
    }

    pub fn i64Sub(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = a -% b });
    }

    pub fn i64Mul(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = a *% b });
    }

    pub fn i64DivS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        if (b == 0) return error.IntegerDivisionByZero;
        if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
        try self.pushValue(.{ .i64 = @divTrunc(a, b) });
    }

    pub fn i64DivU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        if (b == 0) return error.IntegerDivisionByZero;
        try self.pushValue(.{ .i64 = @bitCast(a / b) });
    }

    pub fn i64RemS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        if (b == 0) return error.IntegerDivisionByZero;
        if (a == std.math.minInt(i64) and b == -1) {
            try self.pushValue(.{ .i64 = 0 });
        } else {
            try self.pushValue(.{ .i64 = @rem(a, b) });
        }
    }

    pub fn i64RemU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        if (b == 0) return error.IntegerDivisionByZero;
        try self.pushValue(.{ .i64 = @bitCast(a % b) });
    }

    // ── i64 comparison ──────────────────────────────────────────────────

    pub fn i64Eqz(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a == 0) });
    }

    pub fn i64Eq(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a == b) });
    }

    pub fn i64Ne(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a != b) });
    }

    pub fn i64LtS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a < b) });
    }

    pub fn i64LtU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i32 = @intFromBool(a < b) });
    }

    pub fn i64GtS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a > b) });
    }

    pub fn i64GtU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i32 = @intFromBool(a > b) });
    }

    pub fn i64LeS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a <= b) });
    }

    pub fn i64LeU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i32 = @intFromBool(a <= b) });
    }

    pub fn i64GeS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @intFromBool(a >= b) });
    }

    pub fn i64GeU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i32 = @intFromBool(a >= b) });
    }

    // ── i64 bitwise ─────────────────────────────────────────────────────

    pub fn i64And(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = a & b });
    }

    pub fn i64Or(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = a | b });
    }

    pub fn i64Xor(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = a ^ b });
    }

    pub fn i64Shl(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        const shift: u6 = @truncate(@as(u64, @bitCast(b)));
        try self.pushValue(.{ .i64 = a << shift });
    }

    pub fn i64ShrS(self: *Interpreter) TrapError!void {
        const b = try self.popI64();
        const a = try self.popI64();
        const shift: u6 = @truncate(@as(u64, @bitCast(b)));
        try self.pushValue(.{ .i64 = a >> shift });
    }

    pub fn i64ShrU(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        const shift: u6 = @truncate(b);
        try self.pushValue(.{ .i64 = @bitCast(a >> shift) });
    }

    pub fn i64Rotl(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i64 = @bitCast(std.math.rotl(u64, a, b)) });
    }

    pub fn i64Rotr(self: *Interpreter) TrapError!void {
        const b: u64 = @bitCast(try self.popI64());
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i64 = @bitCast(std.math.rotr(u64, a, b)) });
    }

    pub fn i64Clz(self: *Interpreter) TrapError!void {
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i64 = @intCast(@clz(a)) });
    }

    pub fn i64Ctz(self: *Interpreter) TrapError!void {
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i64 = @intCast(@ctz(a)) });
    }

    pub fn i64Popcnt(self: *Interpreter) TrapError!void {
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .i64 = @intCast(@popCount(a)) });
    }

    // ── f32 arithmetic ──────────────────────────────────────────────────

    pub fn f32Add(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = a + b });
    }

    pub fn f32Sub(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = a - b });
    }

    pub fn f32Mul(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = a * b });
    }

    pub fn f32Div(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = a / b });
    }

    pub fn f32Min(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = wasmMinF32(a, b) });
    }

    pub fn f32Max(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = wasmMaxF32(a, b) });
    }

    pub fn f32Abs(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = @abs(a) });
    }

    pub fn f32Neg(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = -a });
    }

    pub fn f32Sqrt(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = @sqrt(a) });
    }

    pub fn f32Ceil(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = @ceil(a) });
    }

    pub fn f32Floor(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = @floor(a) });
    }

    pub fn f32Trunc(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = @trunc(a) });
    }

    pub fn f32Nearest(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f32 = wasmNearestF32(a) });
    }

    // ── f64 arithmetic ──────────────────────────────────────────────────

    pub fn f64Add(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = a + b });
    }

    pub fn f64Sub(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = a - b });
    }

    pub fn f64Mul(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = a * b });
    }

    pub fn f64Div(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = a / b });
    }

    pub fn f64Min(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = wasmMinF64(a, b) });
    }

    pub fn f64Max(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = wasmMaxF64(a, b) });
    }

    pub fn f64Abs(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = @abs(a) });
    }

    pub fn f64Neg(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = -a });
    }

    pub fn f64Sqrt(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = @sqrt(a) });
    }

    pub fn f64Ceil(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = @ceil(a) });
    }

    pub fn f64Floor(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = @floor(a) });
    }

    pub fn f64Trunc(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = @trunc(a) });
    }

    pub fn f64Nearest(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f64 = wasmNearestF64(a) });
    }

    // ── Conversions ─────────────────────────────────────────────────────

    pub fn i32WrapI64(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .i32 = @truncate(a) });
    }

    pub fn i64ExtendI32S(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .i64 = @as(i64, a) });
    }

    pub fn i64ExtendI32U(self: *Interpreter) TrapError!void {
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .i64 = @as(i64, a) });
    }

    pub fn f32ConvertI32S(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .f32 = @floatFromInt(a) });
    }

    pub fn f32ConvertI32U(self: *Interpreter) TrapError!void {
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .f32 = @floatFromInt(a) });
    }

    pub fn f64ConvertI32S(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .f64 = @floatFromInt(a) });
    }

    pub fn f64ConvertI32U(self: *Interpreter) TrapError!void {
        const a: u32 = @bitCast(try self.popI32());
        try self.pushValue(.{ .f64 = @floatFromInt(a) });
    }

    pub fn f32ConvertI64S(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .f32 = @floatFromInt(a) });
    }

    pub fn f32ConvertI64U(self: *Interpreter) TrapError!void {
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .f32 = @floatFromInt(a) });
    }

    pub fn f64ConvertI64S(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .f64 = @floatFromInt(a) });
    }

    pub fn f64ConvertI64U(self: *Interpreter) TrapError!void {
        const a: u64 = @bitCast(try self.popI64());
        try self.pushValue(.{ .f64 = @floatFromInt(a) });
    }

    pub fn f64PromoteF32(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .f64 = @as(f64, a) });
    }

    pub fn f32DemoteF64(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .f32 = @floatCast(a) });
    }

    pub fn i32TruncF32S(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a)) return error.InvalidConversion;
        if (a >= @as(f32, @floatFromInt(@as(i64, std.math.maxInt(i32)) + 1)) or
            a < @as(f32, @floatFromInt(@as(i64, std.math.minInt(i32)))))
            return error.IntegerOverflow;
        try self.pushValue(.{ .i32 = @intFromFloat(a) });
    }

    pub fn i32TruncF64S(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) return error.InvalidConversion;
        if (a >= @as(f64, @floatFromInt(@as(i64, std.math.maxInt(i32)) + 1)) or
            a <= @as(f64, @floatFromInt(@as(i64, std.math.minInt(i32)) - 1)))
            return error.IntegerOverflow;
        try self.pushValue(.{ .i32 = @intFromFloat(a) });
    }

    pub fn i32ReinterpretF32(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @bitCast(a) });
    }

    pub fn i64ReinterpretF64(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        try self.pushValue(.{ .i64 = @bitCast(a) });
    }

    pub fn f32ReinterpretI32(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .f32 = @bitCast(a) });
    }

    pub fn f64ReinterpretI64(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .f64 = @bitCast(a) });
    }

    // ── Memory operations ───────────────────────────────────────────────

    pub fn i32Load(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i32, mem.items[idx..][0..4], .little);
        try self.pushValue(.{ .i32 = val });
    }

    pub fn i32Store(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI32();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(i32, mem.items[idx..][0..4], val, .little);
    }

    pub fn i64Load(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i64, mem.items[idx..][0..8], .little);
        try self.pushValue(.{ .i64 = val });
    }

    pub fn i64Store(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI64();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(i64, mem.items[idx..][0..8], val, .little);
    }

    pub fn f32Load(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits = std.mem.readInt(u32, mem.items[idx..][0..4], .little);
        try self.pushValue(.{ .f32 = @bitCast(bits) });
    }

    pub fn f32Store(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popF32();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits: u32 = @bitCast(val);
        std.mem.writeInt(u32, mem.items[idx..][0..4], bits, .little);
    }

    pub fn f64Load(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits = std.mem.readInt(u64, mem.items[idx..][0..8], .little);
        try self.pushValue(.{ .f64 = @bitCast(bits) });
    }

    pub fn f64Store(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popF64();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits: u64 = @bitCast(val);
        std.mem.writeInt(u64, mem.items[idx..][0..8], bits, .little);
    }

    fn isMemory64(self: *Interpreter, mem_idx: u32) bool {
        if (mem_idx < self.instance.module.memories.items.len)
            return self.instance.module.memories.items[mem_idx].is_memory64;
        return false;
    }

    fn isTable64(self: *Interpreter, tbl_idx: u32) bool {
        if (tbl_idx < self.instance.module.tables.items.len)
            return self.instance.module.tables.items[tbl_idx].is_table64;
        return false;
    }

    fn popTableIdx(self: *Interpreter, tbl_idx: u32) TrapError!u64 {
        if (self.isTable64(tbl_idx)) {
            return @bitCast(try self.popI64());
        } else {
            return @as(u64, @as(u32, @bitCast(try self.popI32())));
        }
    }

    fn popMemAddr(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!u64 {
        if (self.isMemory64(mem_idx)) {
            const base = try self.popI64();
            return @as(u64, @bitCast(base)) +% offset;
        } else {
            const base = try self.popI32();
            return @as(u64, @as(u32, @bitCast(base))) + offset;
        }
    }

    pub fn memorySize(self: *Interpreter, mem_idx: u32) TrapError!void {
        const pages: i64 = @intCast(self.instance.getMemory(mem_idx).items.len / page_size);
        if (self.isMemory64(mem_idx)) {
            try self.pushValue(.{ .i64 = pages });
        } else {
            try self.pushValue(.{ .i32 = @intCast(pages) });
        }
    }

    pub fn memoryGrow(self: *Interpreter, mem_idx: u32) TrapError!void {
        const is_m64 = self.isMemory64(mem_idx);
        const delta: i64 = if (is_m64) (try self.popI64()) else @as(i64, try self.popI32());
        if (delta < 0) {
            if (is_m64) try self.pushValue(.{ .i64 = -1 }) else try self.pushValue(.{ .i32 = -1 });
            return;
        }
        const mem = self.instance.getMemory(mem_idx);
        const old_pages: u32 = @intCast(mem.items.len / page_size);
        const new_pages: u64 = @as(u64, old_pages) + @as(u64, @intCast(@as(i64, @max(0, delta))));

        // Wasm spec: max 65536 pages (4GB) for 32-bit, more for 64-bit
        const max_pages: u64 = if (is_m64) 0x1_0000_0000_0000 else 65536;
        if (new_pages > max_pages) {
            if (is_m64) try self.pushValue(.{ .i64 = -1 }) else try self.pushValue(.{ .i32 = -1 });
            return;
        }

        // For imported (shared) memory, respect the exporter's actual max.
        if (self.instance.shared_memories.get(mem_idx) != null) {
            if (self.instance.shared_memory_max_pages_map.get(mem_idx)) |max| {
                if (new_pages > max) {
                    if (is_m64) try self.pushValue(.{ .i64 = -1 }) else try self.pushValue(.{ .i32 = -1 });
                    return;
                }
            }
        } else if (mem_idx < self.instance.module.memories.items.len) {
            const mod_mem = self.instance.module.memories.items[mem_idx];
            if (mod_mem.@"type".limits.has_max) {
                if (new_pages > mod_mem.@"type".limits.max) {
                    if (is_m64) try self.pushValue(.{ .i64 = -1 }) else try self.pushValue(.{ .i32 = -1 });
                    return;
                }
            }
        }

        const new_len = @as(usize, @intCast(new_pages)) * page_size;
        mem.resize(self.allocator, new_len) catch {
            if (is_m64) try self.pushValue(.{ .i64 = -1 }) else try self.pushValue(.{ .i32 = -1 });
            return;
        };
        // Zero-initialise newly grown pages.
        const old_len = @as(usize, old_pages) * page_size;
        @memset(mem.items[old_len..], 0);
        if (is_m64) try self.pushValue(.{ .i64 = @intCast(old_pages) }) else try self.pushValue(.{ .i32 = @bitCast(old_pages) });
    }

    // ── Select ──────────────────────────────────────────────────────────

    pub fn selectOp(self: *Interpreter) TrapError!void {
        const cond = try self.popI32();
        const val2 = try self.popValue();
        const val1 = try self.popValue();
        try self.pushValue(if (cond != 0) val1 else val2);
    }

    // ── f32 comparison ──────────────────────────────────────────────────

    pub fn f32Eq(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @intFromBool(a == b) });
    }

    pub fn f32Ne(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @intFromBool(a != b) });
    }

    pub fn f32Lt(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @intFromBool(a < b) });
    }

    pub fn f32Gt(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @intFromBool(a > b) });
    }

    pub fn f32Le(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @intFromBool(a <= b) });
    }

    pub fn f32Ge(self: *Interpreter) TrapError!void {
        const b = try self.popF32();
        const a = try self.popF32();
        try self.pushValue(.{ .i32 = @intFromBool(a >= b) });
    }

    // ── f64 comparison ──────────────────────────────────────────────────

    pub fn f64Eq(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .i32 = @intFromBool(a == b) });
    }

    pub fn f64Ne(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .i32 = @intFromBool(a != b) });
    }

    pub fn f64Lt(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .i32 = @intFromBool(a < b) });
    }

    pub fn f64Gt(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .i32 = @intFromBool(a > b) });
    }

    pub fn f64Le(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .i32 = @intFromBool(a <= b) });
    }

    pub fn f64Ge(self: *Interpreter) TrapError!void {
        const b = try self.popF64();
        const a = try self.popF64();
        try self.pushValue(.{ .i32 = @intFromBool(a >= b) });
    }

    // ── Copysign ────────────────────────────────────────────────────────

    pub fn f32Copysign(self: *Interpreter) TrapError!void {
        const b_bits: u32 = @bitCast(try self.popF32());
        const a_bits: u32 = @bitCast(try self.popF32());
        const result_bits = (a_bits & 0x7FFFFFFF) | (b_bits & 0x80000000);
        try self.pushValue(.{ .f32 = @bitCast(result_bits) });
    }

    pub fn f64Copysign(self: *Interpreter) TrapError!void {
        const b_bits: u64 = @bitCast(try self.popF64());
        const a_bits: u64 = @bitCast(try self.popF64());
        const result_bits = (a_bits & 0x7FFFFFFFFFFFFFFF) | (b_bits & 0x8000000000000000);
        try self.pushValue(.{ .f64 = @bitCast(result_bits) });
    }

    // ── Additional truncation conversions ───────────────────────────────

    pub fn i32TruncF32U(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a)) return error.InvalidConversion;
        if (a >= @as(f32, @floatFromInt(@as(i64, std.math.maxInt(u32)) + 1)) or a <= -1.0)
            return error.IntegerOverflow;
        if (a < 0.0) {
            try self.pushValue(.{ .i32 = 0 });
            return;
        }
        const u: u32 = @intFromFloat(a);
        try self.pushValue(.{ .i32 = @bitCast(u) });
    }

    pub fn i32TruncF64U(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) return error.InvalidConversion;
        if (a >= @as(f64, @floatFromInt(@as(i64, std.math.maxInt(u32)) + 1)) or a <= -1.0)
            return error.IntegerOverflow;
        if (a < 0.0) {
            try self.pushValue(.{ .i32 = 0 });
            return;
        }
        const u: u32 = @intFromFloat(a);
        try self.pushValue(.{ .i32 = @bitCast(u) });
    }

    pub fn i64TruncF32S(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a)) return error.InvalidConversion;
        const max_f: f32 = @floatFromInt(@as(i128, std.math.maxInt(i64)) + 1);
        const min_f: f32 = @floatFromInt(@as(i128, std.math.minInt(i64)));
        if (a >= max_f or a < min_f) return error.IntegerOverflow;
        try self.pushValue(.{ .i64 = @intFromFloat(a) });
    }

    pub fn i64TruncF32U(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a)) return error.InvalidConversion;
        const max_f: f32 = @floatFromInt(@as(u128, std.math.maxInt(u64)) + 1);
        if (a >= max_f or a <= -1.0) return error.IntegerOverflow;
        if (a < 0.0) {
            try self.pushValue(.{ .i64 = 0 });
            return;
        }
        const u: u64 = @intFromFloat(a);
        try self.pushValue(.{ .i64 = @bitCast(u) });
    }

    pub fn i64TruncF64S(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) return error.InvalidConversion;
        const max_f: f64 = @floatFromInt(@as(i128, std.math.maxInt(i64)) + 1);
        const min_f: f64 = @floatFromInt(@as(i128, std.math.minInt(i64)));
        if (a >= max_f or a < min_f) return error.IntegerOverflow;
        try self.pushValue(.{ .i64 = @intFromFloat(a) });
    }

    pub fn i64TruncF64U(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) return error.InvalidConversion;
        const max_f: f64 = @floatFromInt(@as(u128, std.math.maxInt(u64)) + 1);
        if (a >= max_f or a <= -1.0) return error.IntegerOverflow;
        if (a < 0.0) {
            try self.pushValue(.{ .i64 = 0 });
            return;
        }
        const u: u64 = @intFromFloat(a);
        try self.pushValue(.{ .i64 = @bitCast(u) });
    }

    // ── Sign extension ──────────────────────────────────────────────────

    pub fn i32Extend8S(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @as(i32, @as(i8, @truncate(a))) });
    }

    pub fn i32Extend16S(self: *Interpreter) TrapError!void {
        const a = try self.popI32();
        try self.pushValue(.{ .i32 = @as(i32, @as(i16, @truncate(a))) });
    }

    pub fn i64Extend8S(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = @as(i64, @as(i8, @truncate(a))) });
    }

    pub fn i64Extend16S(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = @as(i64, @as(i16, @truncate(a))) });
    }

    pub fn i64Extend32S(self: *Interpreter) TrapError!void {
        const a = try self.popI64();
        try self.pushValue(.{ .i64 = @as(i64, @as(i32, @truncate(a))) });
    }

    // ── Saturating truncation (0xfc 0x00..0x07) ────────────────────────

    pub fn i32TruncSatF32S(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a)) { try self.pushValue(.{ .i32 = 0 }); return; }
        if (a >= @as(f32, @floatFromInt(@as(i64, std.math.maxInt(i32)) + 1)))
            { try self.pushValue(.{ .i32 = std.math.maxInt(i32) }); return; }
        if (a < @as(f32, @floatFromInt(@as(i64, std.math.minInt(i32)))))
            { try self.pushValue(.{ .i32 = std.math.minInt(i32) }); return; }
        try self.pushValue(.{ .i32 = @intFromFloat(a) });
    }

    pub fn i32TruncSatF32U(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a) or a < 0.0) { try self.pushValue(.{ .i32 = 0 }); return; }
        if (a >= @as(f32, @floatFromInt(@as(i64, std.math.maxInt(u32)) + 1)))
            { try self.pushValue(.{ .i32 = @bitCast(@as(u32, std.math.maxInt(u32))) }); return; }
        const u: u32 = @intFromFloat(a);
        try self.pushValue(.{ .i32 = @bitCast(u) });
    }

    pub fn i32TruncSatF64S(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) { try self.pushValue(.{ .i32 = 0 }); return; }
        if (a >= @as(f64, @floatFromInt(@as(i64, std.math.maxInt(i32)) + 1)))
            { try self.pushValue(.{ .i32 = std.math.maxInt(i32) }); return; }
        if (a < @as(f64, @floatFromInt(@as(i64, std.math.minInt(i32)))))
            { try self.pushValue(.{ .i32 = std.math.minInt(i32) }); return; }
        try self.pushValue(.{ .i32 = @intFromFloat(a) });
    }

    pub fn i32TruncSatF64U(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a) or a < 0.0) { try self.pushValue(.{ .i32 = 0 }); return; }
        if (a >= @as(f64, @floatFromInt(@as(i64, std.math.maxInt(u32)) + 1)))
            { try self.pushValue(.{ .i32 = @bitCast(@as(u32, std.math.maxInt(u32))) }); return; }
        const u: u32 = @intFromFloat(a);
        try self.pushValue(.{ .i32 = @bitCast(u) });
    }

    pub fn i64TruncSatF32S(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a)) { try self.pushValue(.{ .i64 = 0 }); return; }
        const max_f: f32 = @floatFromInt(@as(i128, std.math.maxInt(i64)) + 1);
        const min_f: f32 = @floatFromInt(@as(i128, std.math.minInt(i64)));
        if (a >= max_f) { try self.pushValue(.{ .i64 = std.math.maxInt(i64) }); return; }
        if (a < min_f) { try self.pushValue(.{ .i64 = std.math.minInt(i64) }); return; }
        try self.pushValue(.{ .i64 = @intFromFloat(a) });
    }

    pub fn i64TruncSatF32U(self: *Interpreter) TrapError!void {
        const a = try self.popF32();
        if (std.math.isNan(a) or a < 0.0) { try self.pushValue(.{ .i64 = 0 }); return; }
        const max_f: f32 = @floatFromInt(@as(u128, std.math.maxInt(u64)) + 1);
        if (a >= max_f) { try self.pushValue(.{ .i64 = @bitCast(@as(u64, std.math.maxInt(u64))) }); return; }
        const u: u64 = @intFromFloat(a);
        try self.pushValue(.{ .i64 = @bitCast(u) });
    }

    pub fn i64TruncSatF64S(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) { try self.pushValue(.{ .i64 = 0 }); return; }
        const max_f: f64 = @floatFromInt(@as(i128, std.math.maxInt(i64)) + 1);
        const min_f: f64 = @floatFromInt(@as(i128, std.math.minInt(i64)));
        if (a >= max_f) { try self.pushValue(.{ .i64 = std.math.maxInt(i64) }); return; }
        if (a < min_f) { try self.pushValue(.{ .i64 = std.math.minInt(i64) }); return; }
        try self.pushValue(.{ .i64 = @intFromFloat(a) });
    }

    pub fn i64TruncSatF64U(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a) or a < 0.0) { try self.pushValue(.{ .i64 = 0 }); return; }
        const max_f: f64 = @floatFromInt(@as(u128, std.math.maxInt(u64)) + 1);
        if (a >= max_f) { try self.pushValue(.{ .i64 = @bitCast(@as(u64, std.math.maxInt(u64))) }); return; }
        const u: u64 = @intFromFloat(a);
        try self.pushValue(.{ .i64 = @bitCast(u) });
    }

    // ── Bulk memory ops (0xfc 0x0a, 0x0b) ──────────────────────────────

    pub fn memoryCopy(self: *Interpreter, dst_mem_idx: u32, src_mem_idx: u32) TrapError!void {
        const dst_m64 = self.isMemory64(dst_mem_idx);
        const n: u64 = if (dst_m64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const src_m64 = self.isMemory64(src_mem_idx);
        const src: u64 = if (src_m64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const dst: u64 = if (dst_m64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const src_mem = self.instance.getMemory(src_mem_idx).items;
        const dst_mem = self.instance.getMemory(dst_mem_idx);
        if (src +% n > src_mem.len or dst +% n > dst_mem.items.len)
            return error.OutOfBoundsMemoryAccess;
        if (n == 0) return;
        const s: usize = @intCast(src);
        const d: usize = @intCast(dst);
        const len: usize = @intCast(n);
        if (dst_mem_idx == src_mem_idx) {
            if (d <= s) {
                std.mem.copyForwards(u8, dst_mem.items[d .. d + len], src_mem[s .. s + len]);
            } else {
                std.mem.copyBackwards(u8, dst_mem.items[d .. d + len], src_mem[s .. s + len]);
            }
        } else {
            @memcpy(dst_mem.items[d .. d + len], src_mem[s .. s + len]);
        }
    }

    pub fn memoryFill(self: *Interpreter, mem_idx: u32) TrapError!void {
        const m64 = self.isMemory64(mem_idx);
        const n: u64 = if (m64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const val = try self.popI32();
        const dst: u64 = if (m64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const mem = self.instance.getMemory(mem_idx).items;
        if (dst +% n > mem.len)
            return error.OutOfBoundsMemoryAccess;
        if (n == 0) return;
        const d: usize = @intCast(dst);
        const len: usize = @intCast(n);
        @memset(mem[d .. d + len], @truncate(@as(u32, @bitCast(val))));
    }

    pub fn memoryInit(self: *Interpreter, data_idx: u32, mem_idx: u32) TrapError!void {
        const m64 = self.isMemory64(mem_idx);
        // memory.init: n and src are always i32 (data segment offsets), dst follows memory type
        const n_val = try self.popI32();
        const src_val = try self.popI32();
        const dst: u64 = if (m64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const n: u32 = @bitCast(n_val);
        const src: u32 = @bitCast(src_val);
        if (data_idx >= self.instance.module.data_segments.items.len)
            return error.OutOfBoundsMemoryAccess;
        const dropped = data_idx < self.instance.dropped_data.capacity() and
            self.instance.dropped_data.isSet(data_idx);
        const seg = self.instance.module.data_segments.items[data_idx];
        const seg_len: u32 = if (dropped) 0 else @intCast(seg.data.len);
        const mem = self.instance.getMemory(mem_idx);
        if (@as(u64, src) + n > seg_len or
            dst +% n > mem.items.len)
            return error.OutOfBoundsMemoryAccess;
        if (n == 0) return;
        const s: usize = @intCast(src);
        const d: usize = @intCast(dst);
        const len: usize = @intCast(n);
        @memcpy(mem.items[d .. d + len], seg.data[s .. s + len]);
    }

    pub fn tableCopy(self: *Interpreter, dst_tbl_idx: u32, src_tbl_idx: u32) TrapError!void {
        const dst_t64 = self.isTable64(dst_tbl_idx);
        const n: u64 = if (dst_t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const src_t64 = self.isTable64(src_tbl_idx);
        const src: u64 = if (src_t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const dst: u64 = if (dst_t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const dst_tbl = self.instance.getTable(dst_tbl_idx);
        const src_tbl = self.instance.getTable(src_tbl_idx);
        if (dst +% n > dst_tbl.items.len or src +% n > src_tbl.items.len)
            return error.OutOfBoundsTableAccess;
        if (n == 0) return;
        const d: usize = @intCast(dst);
        const s: usize = @intCast(src);
        const len: usize = @intCast(n);
        if (dst_tbl_idx == src_tbl_idx) {
            const tbl = dst_tbl.items;
            if (d <= s) {
                var i: usize = 0;
                while (i < len) : (i += 1) tbl[d + i] = tbl[s + i];
            } else {
                var i: usize = len;
                while (i > 0) {
                    i -= 1;
                    tbl[d + i] = tbl[s + i];
                }
            }
        } else {
            var i: usize = 0;
            while (i < len) : (i += 1) dst_tbl.items[d + i] = src_tbl.items[s + i];
        }
    }

    pub fn tableInit(self: *Interpreter, elem_idx: u32, tbl_idx: u32) TrapError!void {
        const t64 = self.isTable64(tbl_idx);
        // table.init: n and src are always i32 (elem segment offsets), dst follows table type
        const n_val = try self.popI32();
        const src_val = try self.popI32();
        const dst: u64 = if (t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const n: u32 = @bitCast(n_val);
        const src: u32 = @bitCast(src_val);
        if (elem_idx >= self.instance.module.elem_segments.items.len)
            return error.OutOfBoundsTableAccess;
        const dropped = elem_idx < self.instance.dropped_elems.capacity() and
            self.instance.dropped_elems.isSet(elem_idx);
        const seg = &self.instance.module.elem_segments.items[elem_idx];
        // Use the larger of var_indices count and expr count for segment length
        const var_len: u32 = @intCast(seg.elem_var_indices.items.len);
        const expr_len: u32 = seg.elem_expr_count;
        const seg_len: u32 = if (dropped) 0 else @max(var_len, expr_len);
        const tbl = self.instance.getTable(tbl_idx);
        if (@as(u64, src) + n > seg_len or
            dst +% n > tbl.items.len)
            return error.OutOfBoundsTableAccess;
        if (n == 0) return;
        const d: usize = @intCast(dst);
        const refs = self.instance.getTableFuncRefs();

        // If elem segment uses expressions (funcref/externref), evaluate them
        if (var_len == 0 and expr_len > 0 and seg.elem_expr_bytes.len > 0) {
            // Navigate to the src-th expression
            var expr_pc: usize = 0;
            var skip: u32 = 0;
            while (skip < src and expr_pc < seg.elem_expr_bytes.len) : (skip += 1) {
                while (expr_pc < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc] != 0x0b) {
                    expr_pc += 1;
                }
                if (expr_pc < seg.elem_expr_bytes.len) expr_pc += 1;
            }
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const expr_start = expr_pc;
                while (expr_pc < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc] != 0x0b) {
                    expr_pc += 1;
                }
                if (expr_pc < seg.elem_expr_bytes.len) expr_pc += 1;
                const val = evalConstExpr(self.instance, seg.elem_expr_bytes[expr_start..expr_pc]);
                if (val) |v| switch (v) {
                    .ref_func => |func_idx| {
                        tbl.items[d + i] = func_idx;
                        refs.put(self.allocator, Instance.makeTableKey(tbl_idx, @intCast(d + i)), self) catch {};
                    },
                    .ref_i31 => |i31_val| {
                        tbl.items[d + i] = i31_val;
                    },
                    .ref_null => {
                        tbl.items[d + i] = null;
                    },
                    else => {},
                };
            }
            return;
        }

        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const var_entry = seg.elem_var_indices.items[src + i];
            const func_idx = switch (var_entry) {
                .index => |idx| idx,
                .name => 0,
            };
            if (func_idx == std.math.maxInt(u32)) {
                tbl.items[d + i] = null;
            } else {
                tbl.items[d + i] = func_idx;
                refs.put(self.allocator, Instance.makeTableKey(tbl_idx, @intCast(d + i)), self) catch {};
            }
        }
    }

    pub fn tableGrow(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        const tbl_idx = readCodeU32(code, pc);
        const t64 = self.isTable64(tbl_idx);
        const delta: u64 = if (t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const init_val = try self.popValue();
        const tbl = self.instance.getTable(tbl_idx);
        const old_size: u64 = @intCast(tbl.items.len);
        const func_ref: ?u32 = switch (init_val) {
            .ref_func => |idx| idx,
            .ref_i31 => |v| v,
            .ref_struct => |v| v,
            .ref_array => |v| v,
            .ref_extern => |v| v,
            .ref_null => null,
            .i32 => |v| @bitCast(v),
            else => null,
        };
        if (delta == 0) {
            if (t64) try self.pushValue(.{ .i64 = @intCast(old_size) })
            else try self.pushValue(.{ .i32 = @intCast(old_size) });
            return;
        }
        const new_size: u64 = old_size + delta;
        if (new_size > 10_000_000) {
            if (t64) try self.pushValue(.{ .i64 = -1 })
            else try self.pushValue(.{ .i32 = -1 });
            return;
        }
        if (tbl_idx < self.instance.module.tables.items.len) {
            const tbl_type = self.instance.module.tables.items[tbl_idx];
            if (tbl_type.@"type".limits.has_max and new_size > tbl_type.@"type".limits.max) {
                if (t64) try self.pushValue(.{ .i64 = -1 })
                else try self.pushValue(.{ .i32 = -1 });
                return;
            }
        }
        tbl.appendNTimes(self.allocator, func_ref, @intCast(delta)) catch {
            if (t64) try self.pushValue(.{ .i64 = -1 })
            else try self.pushValue(.{ .i32 = -1 });
            return;
        };
        if (t64) try self.pushValue(.{ .i64 = @intCast(old_size) })
        else try self.pushValue(.{ .i32 = @intCast(old_size) });
    }

    pub fn tableSize(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        const tbl_idx = readCodeU32(code, pc);
        const tbl = self.instance.getTable(tbl_idx);
        if (self.isTable64(tbl_idx))
            try self.pushValue(.{ .i64 = @intCast(tbl.items.len) })
        else
            try self.pushValue(.{ .i32 = @intCast(tbl.items.len) });
    }

    pub fn tableFill(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        const tbl_idx = readCodeU32(code, pc);
        const t64 = self.isTable64(tbl_idx);
        const n: u64 = if (t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const val = try self.popValue();
        const dst: u64 = if (t64) @bitCast(try self.popI64()) else @as(u64, @as(u32, @bitCast(try self.popI32())));
        const tbl = self.instance.getTable(tbl_idx);
        if (dst +% n > tbl.items.len)
            return error.OutOfBoundsTableAccess;
        const func_ref: ?u32 = switch (val) {
            .ref_func => |idx| idx,
            .ref_i31 => |v| v,
            .ref_struct => |v| v,
            .ref_array => |v| v,
            .ref_extern => |v| v,
            .ref_null => null,
            .i32 => |v| @bitCast(v),
            else => null,
        };
        var i: usize = 0;
        const d: usize = @intCast(dst);
        while (i < n) : (i += 1) tbl.items[d + i] = func_ref;
    }

    // ── Sub-word memory loads ───────────────────────────────────────────

    pub fn i32Load8S(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 1 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const val: i8 = @bitCast(mem.items[@intCast(addr)]);
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i32Load8U(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 1 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const val = mem.items[@intCast(addr)];
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i32Load16S(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 2 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i16, mem.items[idx..][0..2], .little);
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i32Load16U(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 2 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(u16, mem.items[idx..][0..2], .little);
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i64Load8S(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 1 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const val: i8 = @bitCast(mem.items[@intCast(addr)]);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load8U(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 1 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const val = mem.items[@intCast(addr)];
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load16S(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 2 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i16, mem.items[idx..][0..2], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load16U(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 2 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(u16, mem.items[idx..][0..2], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load32S(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i32, mem.items[idx..][0..4], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load32U(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(u32, mem.items[idx..][0..4], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    // ── Sub-word memory stores ──────────────────────────────────────────

    pub fn i32Store8(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI32();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 1 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        mem.items[@intCast(addr)] = @truncate(@as(u32, @bitCast(val)));
    }

    pub fn i32Store16(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI32();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 2 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(u16, mem.items[idx..][0..2], @truncate(@as(u32, @bitCast(val))), .little);
    }

    pub fn i64Store8(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI64();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 1 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        mem.items[@intCast(addr)] = @truncate(@as(u64, @bitCast(val)));
    }

    pub fn i64Store16(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI64();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 2 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(u16, mem.items[idx..][0..2], @truncate(@as(u64, @bitCast(val))), .little);
    }

    pub fn i64Store32(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popI64();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 4 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(u32, mem.items[idx..][0..4], @truncate(@as(u64, @bitCast(val))), .little);
    }

    // ── Tag identity matching ──────────────────────────────────────────

    /// Check if catch_tag_idx in the current module matches the thrown
    /// exception's tag, handling imported aliases and cross-module throws.
    fn tagsMatchException(self: *Interpreter, catch_tag_idx: u32, exc: ThrownException) bool {
        const mod = self.instance.module;
        const exc_tag_idx = exc.tag_idx;
        const exc_mod = exc.source_module orelse mod;

        // Same module: direct comparison or canonical ID
        if (exc_mod == mod) {
            if (catch_tag_idx == exc_tag_idx) return true;
            // Use canonical IDs for alias resolution
            if (catch_tag_idx < self.tag_canonical_ids.items.len and
                exc_tag_idx < self.tag_canonical_ids.items.len)
                return self.tag_canonical_ids.items[catch_tag_idx] == self.tag_canonical_ids.items[exc_tag_idx];
            return false;
        }

        // Cross-module: the thrown exception has a source tag from a different module.
        // We need to check if our catch tag (imported) resolves to the same source.
        // Get the catch tag's canonical ID
        if (catch_tag_idx < self.tag_canonical_ids.items.len) {
            const catch_canonical = self.tag_canonical_ids.items[catch_tag_idx];
            // The thrown tag's canonical: use the source module's default ID
            const thrown_canonical = @as(u64, @intFromPtr(exc_mod)) ^ @as(u64, exc_tag_idx);
            return catch_canonical == thrown_canonical;
        }
        return false;
    }

    /// Find the tag index exported by a source module under a given field name.
    /// Resolves through function import links to find the source module.
    fn findSourceTagIndex(self: *Interpreter, mod: *const Mod.Module, module_name: []const u8, field_name: []const u8) ?u32 {
        // Find a function import from the same module to get the source interpreter
        var func_idx: u32 = 0;
        for (mod.imports.items) |imp| {
            if (imp.kind == .func) {
                if (std.mem.eql(u8, imp.module_name, module_name)) {
                    if (func_idx < self.import_links.items.len) {
                        if (self.import_links.items[func_idx]) |link| {
                            // Found the source module's interpreter
                            if (link.interpreter.instance.module.getExport(field_name)) |exp| {
                                if (exp.kind == .tag) {
                                    return switch (exp.var_) { .index => |i| i, .name => null };
                                }
                            }
                            return null;
                        }
                    }
                }
                func_idx += 1;
            }
        }
        return null;
    }

    // ── Block stack helpers ──────────────────────────────────────────────

    const BlockSig = struct { params: usize, results: usize };

    /// Return how many param and result values a block type declares.
    fn getBlockSig(self: *Interpreter, code: []const u8, block_type_pc: usize) BlockSig {
        if (block_type_pc >= code.len) return .{ .params = 0, .results = 0 };
        const byte = code[block_type_pc];
        if (byte == 0x40) return .{ .params = 0, .results = 0 }; // void
        if ((byte >= 0x7b and byte <= 0x7f) or byte == 0x70 or byte == 0x6f or byte == 0x69 or byte == 0x63 or byte == 0x64) return .{ .params = 0, .results = 1 };
        // Type index (signed LEB128)
        var tmp = block_type_pc;
        const idx_s32 = readCodeS32(code, &tmp);
        if (idx_s32 < 0) return .{ .params = 0, .results = 0 };
        const idx: u32 = @intCast(idx_s32);
        if (idx < self.instance.module.module_types.items.len) {
            switch (self.instance.module.module_types.items[idx]) {
                .func_type => |ft| return .{ .params = ft.params.len, .results = ft.results.len },
                else => return .{ .params = 0, .results = 0 },
            }
        }
        return .{ .params = 0, .results = 0 };
    }

    /// Compact the stack after a block finishes: keep only the top
    /// `result_count` values above `block_stack_base`.
    fn compactBlockResults(self: *Interpreter, block_stack_base: usize, result_count: usize) void {
        if (self.stack.items.len <= block_stack_base + result_count) return;
        if (result_count == 0) {
            self.stack.shrinkRetainingCapacity(block_stack_base);
            return;
        }
        const src = self.stack.items.len - result_count;
        for (0..result_count) |i| {
            self.stack.items[block_stack_base + i] = self.stack.items[src + i];
        }
        self.stack.shrinkRetainingCapacity(block_stack_base + result_count);
    }

    // ── Bytecode dispatch ───────────────────────────────────────────────

    fn dispatch(self: *Interpreter, code: []const u8, start_pc: usize, locals: []Value) TrapError!usize {
        var pc = start_pc;
        while (pc < code.len) {
            self.instruction_count += 1;
            if (self.instruction_count > self.max_instructions) return error.InstructionLimitExceeded;
            const opcode = code[pc];
            pc += 1;
            switch (opcode) {
                0x00 => return error.Unreachable,
                0x01 => {},
                0x08 => { // throw
                    var tmp_pc = pc;
                    const tag_idx = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    // Pop tag params and store as exception
                    var exc = ThrownException{ .tag_idx = tag_idx, .source_module = self.instance.module };
                    if (tag_idx < self.instance.module.tags.items.len) {
                        const tag = self.instance.module.tags.items[tag_idx];
                        exc.value_count = tag.@"type".sig.params.len;
                        var i = exc.value_count;
                        while (i > 0) {
                            i -= 1;
                            if (i < 16) exc.values[i] = try self.popValue();
                        }
                    }
                    self.thrown_exception = exc;
                    return pc;
                },
                0x0a => { // throw_ref — re-throw from exnref
                    const val = try self.popValue();
                    switch (val) {
                        .exnref => |idx| {
                            if (idx < self.caught_exceptions.items.len) {
                                self.thrown_exception = self.caught_exceptions.items[idx];
                                return pc;
                            }
                            return error.Unreachable;
                        },
                        .ref_null => return error.Unreachable,
                        else => return error.Unreachable,
                    }
                },
                0x02 => { // block
                    const bsig = self.getBlockSig(code, pc);
                    const body_start = skipBlockType(code, pc);
                    const block_stack_base = self.stack.items.len -| bsig.params;
                    pc = try self.dispatch(code, body_start, locals);
                    if (self.thrown_exception != null) return pc;
                    if (self.returning) return pc;
                    if (self.branch_depth) |d| {
                        if (d == 0) {
                            self.branch_depth = null;
                            self.compactBlockResults(block_stack_base, bsig.results);
                            pc = scanToEnd(code, body_start);
                        } else {
                            self.branch_depth = d - 1;
                            return pc;
                        }
                    } else {
                        // Normal block end — compact results
                        self.compactBlockResults(block_stack_base, bsig.results);
                    }
                },
                0x03 => { // loop
                    const lsig = self.getBlockSig(code, pc);
                    const body_start = skipBlockType(code, pc);
                    const loop_stack_base = self.stack.items.len -| lsig.params;
                    pc = body_start;
                    while (true) {
                        pc = try self.dispatch(code, body_start, locals);
                        if (self.thrown_exception != null) return pc;
                        if (self.returning) return pc;
                        if (self.branch_depth) |d| {
                            if (d == 0) {
                                self.branch_depth = null;
                                // For loop restart, compact to params
                                self.compactBlockResults(loop_stack_base, lsig.params);
                                continue; // restart loop
                            } else {
                                self.branch_depth = d - 1;
                                pc = scanToEnd(code, body_start);
                                return pc;
                            }
                        }
                        // Normal loop end — compact to results
                        self.compactBlockResults(loop_stack_base, lsig.results);
                        break;
                    }
                },
                0x04 => { // if
                    const isig = self.getBlockSig(code, pc);
                    const body_start = skipBlockType(code, pc);
                    const cond = try self.popI32();
                    const if_stack_base = self.stack.items.len -| isig.params;
                    if (cond != 0) {
                        pc = try self.dispatch(code, body_start, locals);
                        if (self.thrown_exception != null) return pc;
                        if (self.returning) return pc;
                        if (self.branch_depth) |d| {
                            if (d == 0) {
                                self.branch_depth = null;
                                self.compactBlockResults(if_stack_base, isig.results);
                                pc = scanToEnd(code, body_start);
                            } else {
                                self.branch_depth = d - 1;
                                return pc;
                            }
                        } else {
                            // Normal end — compact results
                            self.compactBlockResults(if_stack_base, isig.results);
                            // Check if we stopped at else (need to skip else body)
                            if (pc > 0 and pc - 1 < code.len and code[pc - 1] == 0x05) {
                                pc = scanToEnd(code, pc);
                            }
                        }
                    } else {
                        pc = scanToElseOrEnd(code, body_start);
                        if (pc > 0 and pc - 1 < code.len and code[pc - 1] == 0x05) {
                            const else_start = pc;
                            // Execute else branch
                            pc = try self.dispatch(code, pc, locals);
                            if (self.thrown_exception != null) return pc;
                            if (self.returning) return pc;
                            if (self.branch_depth) |d| {
                                if (d == 0) {
                                    self.branch_depth = null;
                                    self.compactBlockResults(if_stack_base, isig.results);
                                    pc = scanToEnd(code, else_start);
                                } else {
                                    self.branch_depth = d - 1;
                                    return pc;
                                }
                            } else {
                                // Normal else end — compact results
                                self.compactBlockResults(if_stack_base, isig.results);
                            }
                        }
                    }
                },
                0x05 => return pc, // else — end of true branch
                0x0b => return pc, // end
                0x1f => { // try_table
                    const tsig = self.getBlockSig(code, pc);
                    var body_start = skipBlockType(code, pc);
                    // Parse catch clauses from bytecode
                    const catch_count = readCodeU32(code, &body_start);
                    const CatchClause = struct { kind: u8, tag_idx: u32, label: u32 };
                    var catches_buf: [16]CatchClause = undefined;
                    const n_catches = @min(catch_count, 16);
                    for (0..n_catches) |ci| {
                        const kind = code[body_start];
                        body_start += 1;
                        var tag: u32 = 0;
                        if (kind <= 0x01) tag = readCodeU32(code, &body_start);
                        const lbl = readCodeU32(code, &body_start);
                        catches_buf[ci] = .{ .kind = kind, .tag_idx = tag, .label = lbl };
                    }
                    // Skip any remaining catch clauses beyond 16
                    for (n_catches..catch_count) |_| {
                        const kind = code[body_start];
                        body_start += 1;
                        if (kind <= 0x01) _ = readCodeU32(code, &body_start);
                        _ = readCodeU32(code, &body_start);
                    }

                    const try_stack_base = self.stack.items.len -| tsig.params;
                    pc = try self.dispatch(code, body_start, locals);

                    // Check for thrown exception
                    if (self.thrown_exception) |exc| {
                        // Try to match a catch clause
                        var caught = false;
                        for (catches_buf[0..n_catches]) |clause| {
                            const matches = switch (clause.kind) {
                                0x00, 0x01 => self.tagsMatchException(clause.tag_idx, exc),
                                0x02, 0x03 => true,
                                else => false,
                            };
                            if (matches) {
                                const saved_exc = exc;
                                self.thrown_exception = null;
                                self.stack.shrinkRetainingCapacity(try_stack_base);
                                if (clause.kind == 0x00 or clause.kind == 0x01) {
                                    for (0..saved_exc.value_count) |vi| {
                                        try self.pushValue(saved_exc.values[vi]);
                                    }
                                }
                                if (clause.kind == 0x01 or clause.kind == 0x03) {
                                    const exn_idx: u32 = @intCast(self.caught_exceptions.items.len);
                                    self.caught_exceptions.append(self.allocator, saved_exc) catch {};
                                    try self.pushValue(.{ .exnref = exn_idx });
                                }
                                self.branch_depth = clause.label;
                                caught = true;
                                break;
                            }
                        }
                        if (!caught) return pc; // No match — propagate exception
                        // Fall through to branch_depth handling below
                    }

                    if (self.thrown_exception != null) return pc;
                    if (self.returning) return pc;
                    if (self.branch_depth) |d| {
                        if (d == 0) {
                            self.branch_depth = null;
                            self.compactBlockResults(try_stack_base, tsig.results);
                            pc = scanToEnd(code, body_start);
                        } else {
                            self.branch_depth = d - 1;
                            return pc;
                        }
                    } else {
                        self.compactBlockResults(try_stack_base, tsig.results);
                    }
                },
                0x0c => { // br
                    var tmp_pc = pc;
                    const depth = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    self.branch_depth = depth;
                    return pc;
                },
                0x0d => { // br_if
                    var tmp_pc = pc;
                    const depth = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    const cond = try self.popI32();
                    if (cond != 0) {
                        self.branch_depth = depth;
                        return pc;
                    }
                },
                0x0e => { // br_table
                    var tmp_pc = pc;
                    const count = readCodeU32(code, &tmp_pc);
                    const idx: u32 = @bitCast(try self.popI32());
                    var target: u32 = 0;
                    for (0..count) |i| {
                        const t = readCodeU32(code, &tmp_pc);
                        if (i == idx) target = t;
                    }
                    const default = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    if (idx >= count) target = default;
                    self.branch_depth = target;
                    return pc;
                },
                0x0f => { // return
                    self.returning = true;
                    return pc;
                },
                0x10 => { // call
                    var tmp_pc = pc;
                    const idx = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    const target = self.instance.module.funcs.items[idx];
                    const sig = self.resolveSig(target.decl);
                    var call_args = self.allocator.alloc(Value, sig.params.len) catch return error.OutOfMemory;
                    defer self.allocator.free(call_args);
                    var i = sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        call_args[i] = try self.popValue();
                    }
                    try self.callFunc(idx, call_args);
                    if (self.thrown_exception != null) return pc;
                },
                0x12 => { // return_call (tail call)
                    var tmp_pc = pc;
                    const idx = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    const target = self.instance.module.funcs.items[idx];
                    const sig = self.resolveSig(target.decl);
                    var tc = TailCall{ .func_idx = idx, .arg_count = sig.params.len };
                    var i = sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        tc.args[i] = try self.popValue();
                    }
                    self.pending_tail_call = tc;
                    self.returning = true;
                    return pc;
                },
                0x14 => { // call_ref
                    var tmp_pc = pc;
                    _ = readCodeU32(code, &tmp_pc); // type index (for validation)
                    pc = tmp_pc;
                    const ref_val = try self.popValue();
                    const func_idx = switch (ref_val) {
                        .ref_func => |idx| idx,
                        .ref_null => return error.Unreachable, // null funcref trap
                        else => return error.Unreachable,
                    };
                    if (func_idx >= self.instance.module.funcs.items.len) return error.UndefinedElement;
                    const target = self.instance.module.funcs.items[func_idx];
                    const sig = self.resolveSig(target.decl);
                    var call_args = self.allocator.alloc(Value, sig.params.len) catch return error.OutOfMemory;
                    defer self.allocator.free(call_args);
                    var i = sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        call_args[i] = try self.popValue();
                    }
                    try self.callFunc(func_idx, call_args);
                    if (self.thrown_exception != null) return pc;
                },
                0x15 => { // return_call_ref (tail call)
                    var tmp_pc = pc;
                    _ = readCodeU32(code, &tmp_pc); // type index
                    pc = tmp_pc;
                    const ref_val = try self.popValue();
                    const func_idx = switch (ref_val) {
                        .ref_func => |idx| idx,
                        .ref_null => return error.Unreachable,
                        else => return error.Unreachable,
                    };
                    if (func_idx >= self.instance.module.funcs.items.len) return error.UndefinedElement;
                    const target = self.instance.module.funcs.items[func_idx];
                    const sig = self.resolveSig(target.decl);
                    var tc2 = TailCall{ .func_idx = func_idx, .arg_count = sig.params.len };
                    var i = sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        tc2.args[i] = try self.popValue();
                    }
                    self.pending_tail_call = tc2;
                    self.returning = true;
                    return pc;
                },
                0x11 => { // call_indirect
                    var tmp_pc = pc;
                    const type_idx = readCodeU32(code, &tmp_pc);
                    const ci_tbl_idx = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    const uidx = try self.popTableIdx(ci_tbl_idx);
                    const ci_tbl = self.instance.getTable(ci_tbl_idx);
                    if (uidx >= ci_tbl.items.len) return error.OutOfBoundsTableAccess;
                    const func_idx = ci_tbl.items[@intCast(uidx)] orelse return error.UninitializedElement;

                    // Check for cross-module function reference
                    const key = Instance.makeTableKey(ci_tbl_idx, @intCast(uidx));
                    const refs = self.instance.getTableFuncRefs();
                    const target_interp = refs.get(key) orelse self;

                    if (func_idx >= target_interp.instance.module.funcs.items.len) return error.UndefinedElement;
                    const target = target_interp.instance.module.funcs.items[func_idx];
                    const func_sig = target_interp.resolveSig(target.decl);
                    // Verify type matches: nominal matching with subtype chain for GC types
                    if (type_idx < self.instance.module.module_types.items.len) {
                        const actual_type_idx = target.decl.type_var.index;
                        // Check if types use GC sub declarations (nominal matching needed)
                        if (self.hasSubTypeInfo(type_idx) or target_interp.hasSubTypeInfo(actual_type_idx)) {
                            // Nominal matching: walk the actual type's parent chain
                            if (!self.isSubtypeOf(actual_type_idx, type_idx, target_interp)) {
                                return error.IndirectCallTypeMismatch;
                            }
                        } else {
                            // Structural matching (legacy/non-GC)
                            switch (self.instance.module.module_types.items[type_idx]) {
                                .func_type => |expected| {
                                    const params_match = std.mem.eql(types.ValType, func_sig.params, expected.params);
                                    const results_match = std.mem.eql(types.ValType, func_sig.results, expected.results);
                                    if (!params_match or !results_match) {
                                        return error.IndirectCallTypeMismatch;
                                    }
                                    if (!typesEquivalent(self.instance.module, type_idx, target_interp.instance.module, actual_type_idx)) {
                                        return error.IndirectCallTypeMismatch;
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                    var call_args = self.allocator.alloc(Value, func_sig.params.len) catch return error.OutOfMemory;
                    defer self.allocator.free(call_args);
                    var i = func_sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        call_args[i] = try self.popValue();
                    }
                    if (target_interp != self) {
                        // Cross-module call: call through target interpreter and copy results
                        const link_base = target_interp.stack.items.len;
                        try target_interp.callFunc(func_idx, call_args);
                        const link_results = target_interp.stack.items[link_base..];
                        for (link_results) |v| try self.pushValue(v);
                        target_interp.stack.shrinkRetainingCapacity(link_base);
                    } else {
                        try self.callFunc(func_idx, call_args);
                    }
                    if (self.thrown_exception != null) return pc;
                },
                0x13 => { // return_call_indirect (tail call)
                    var tmp_pc = pc;
                    const type_idx = readCodeU32(code, &tmp_pc);
                    const ci_tbl_idx = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    const uidx = try self.popTableIdx(ci_tbl_idx);
                    const ci_tbl = self.instance.getTable(ci_tbl_idx);
                    if (uidx >= ci_tbl.items.len) return error.OutOfBoundsTableAccess;
                    const func_idx = ci_tbl.items[@intCast(uidx)] orelse return error.UninitializedElement;
                    const key = Instance.makeTableKey(ci_tbl_idx, @intCast(uidx));
                    const refs = self.instance.getTableFuncRefs();
                    const target_interp = refs.get(key) orelse self;
                    if (func_idx >= target_interp.instance.module.funcs.items.len) return error.UndefinedElement;
                    const target = target_interp.instance.module.funcs.items[func_idx];
                    const func_sig = target_interp.resolveSig(target.decl);
                    if (type_idx < self.instance.module.module_types.items.len) {
                        const actual_type_idx = target.decl.type_var.index;
                        if (self.hasSubTypeInfo(type_idx) or target_interp.hasSubTypeInfo(actual_type_idx)) {
                            if (!self.isSubtypeOf(actual_type_idx, type_idx, target_interp))
                                return error.IndirectCallTypeMismatch;
                        } else {
                            switch (self.instance.module.module_types.items[type_idx]) {
                                .func_type => |expected| {
                                    if (!std.mem.eql(types.ValType, func_sig.params, expected.params) or
                                        !std.mem.eql(types.ValType, func_sig.results, expected.results))
                                        return error.IndirectCallTypeMismatch;
                                    if (!typesEquivalent(self.instance.module, type_idx, target_interp.instance.module, actual_type_idx))
                                        return error.IndirectCallTypeMismatch;
                                },
                                else => {},
                            }
                        }
                    }
                    var tc = TailCall{ .func_idx = func_idx, .arg_count = func_sig.params.len };
                    var i = func_sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        tc.args[i] = try self.popValue();
                    }
                    self.pending_tail_call = tc;
                    self.returning = true;
                    return pc;
                },
                0x1a => _ = try self.popValue(), // drop
                0x1b => try self.selectOp(), // select
                0x1c => { // select t*
                    var t = pc;
                    const vec_len = readCodeU32(code, &t);
                    var ti: u32 = 0;
                    while (ti < vec_len) : (ti += 1) _ = readCodeU32(code, &t);
                    pc = t;
                    try self.selectOp();
                },
                0x20 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; if (idx < locals.len) try self.pushValue(locals[idx]) else return error.Unimplemented; },
                0x21 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; locals[idx] = try self.popValue(); },
                0x22 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; const v = try self.popValue(); locals[idx] = v; try self.pushValue(v); },
                0x23 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; try self.pushValue(self.getGlobal(idx)); },
                0x24 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; self.setGlobal(idx, try self.popValue()); },
                0x25 => { // table.get
                    var t = pc;
                    const tg_idx = readCodeU32(code, &t);
                    pc = t;
                    const idx = try self.popTableIdx(tg_idx);
                    const tg_tbl = self.instance.getTable(tg_idx);
                    if (idx >= tg_tbl.items.len) return error.OutOfBoundsTableAccess;
                    if (tg_tbl.items[@intCast(idx)]) |raw_val| {
                        const key = Instance.makeTableKey(tg_idx, @intCast(idx));
                        const tag = self.instance.table_value_tags.get(key) orelse 0;
                        try self.pushValue(switch (tag) {
                            1 => Value{ .ref_i31 = raw_val },
                            2 => Value{ .ref_struct = raw_val },
                            3 => Value{ .ref_array = raw_val },
                            4 => Value{ .ref_extern = raw_val },
                            else => Value{ .ref_func = raw_val },
                        });
                    } else {
                        try self.pushValue(.{ .ref_null = {} });
                    }
                },
                0x26 => { // table.set
                    var t = pc;
                    const ts_idx = readCodeU32(code, &t);
                    pc = t;
                    const val = try self.popValue();
                    const idx = try self.popTableIdx(ts_idx);
                    const ts_tbl = self.instance.getTable(ts_idx);
                    if (idx >= ts_tbl.items.len) return error.OutOfBoundsTableAccess;
                    ts_tbl.items[@intCast(idx)] = switch (val) {
                        .ref_func => |fi| fi,
                        .ref_i31 => |v| v,
                        .ref_struct => |v| v,
                        .ref_array => |v| v,
                        .ref_extern => |v| v,
                        .ref_null => null,
                        .i32 => |v| @bitCast(v),
                        else => null,
                    };
                    // Store value type tag for correct reconstruction on table.get
                    const tag: u8 = switch (val) {
                        .ref_i31 => 1,
                        .ref_struct => 2,
                        .ref_array => 3,
                        .ref_extern => 4,
                        .ref_null => 5,
                        else => 0,
                    };
                    if (tag != 0 and tag != 5) {
                        const key = Instance.makeTableKey(ts_idx, @intCast(idx));
                        self.instance.table_value_tags.put(self.allocator, key, tag) catch {};
                    }
                },
                // Memory load (format: mem_idx, align, offset)
                0x28 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Load(m, o); },
                0x29 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load(m, o); },
                0x2a => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.f32Load(m, o); },
                0x2b => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.f64Load(m, o); },
                0x2c => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Load8S(m, o); },
                0x2d => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Load8U(m, o); },
                0x2e => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Load16S(m, o); },
                0x2f => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Load16U(m, o); },
                0x30 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load8S(m, o); },
                0x31 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load8U(m, o); },
                0x32 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load16S(m, o); },
                0x33 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load16U(m, o); },
                0x34 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load32S(m, o); },
                0x35 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Load32U(m, o); },
                // Memory store (format: mem_idx, align, offset)
                0x36 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Store(m, o); },
                0x37 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Store(m, o); },
                0x38 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.f32Store(m, o); },
                0x39 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.f64Store(m, o); },
                0x3a => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Store8(m, o); },
                0x3b => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i32Store16(m, o); },
                0x3c => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Store8(m, o); },
                0x3d => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Store16(m, o); },
                0x3e => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.i64Store32(m, o); },
                0x3f => { const m = readCodeU32(code, &pc); try self.memorySize(m); },
                0x40 => { const m = readCodeU32(code, &pc); try self.memoryGrow(m); },
                // Constants
                0x41 => { var t = pc; const v = readCodeS32(code, &t); pc = t; try self.pushValue(.{ .i32 = v }); },
                0x42 => { var t = pc; const v = readCodeS64(code, &t); pc = t; try self.pushValue(.{ .i64 = v }); },
                0x43 => { const bits = readCodeFixedU32(code, pc); pc += 4; try self.pushValue(.{ .f32 = @bitCast(bits) }); },
                0x44 => { const bits = readCodeFixedU64(code, pc); pc += 8; try self.pushValue(.{ .f64 = @bitCast(bits) }); },
                // i32 comparison
                0x45 => try self.i32Eqz(),
                0x46 => try self.i32Eq(),
                0x47 => try self.i32Ne(),
                0x48 => try self.i32LtS(),
                0x49 => try self.i32LtU(),
                0x4a => try self.i32GtS(),
                0x4b => try self.i32GtU(),
                0x4c => try self.i32LeS(),
                0x4d => try self.i32LeU(),
                0x4e => try self.i32GeS(),
                0x4f => try self.i32GeU(),
                // i64 comparison
                0x50 => try self.i64Eqz(),
                0x51 => try self.i64Eq(),
                0x52 => try self.i64Ne(),
                0x53 => try self.i64LtS(),
                0x54 => try self.i64LtU(),
                0x55 => try self.i64GtS(),
                0x56 => try self.i64GtU(),
                0x57 => try self.i64LeS(),
                0x58 => try self.i64LeU(),
                0x59 => try self.i64GeS(),
                0x5a => try self.i64GeU(),
                // f32 comparison
                0x5b => try self.f32Eq(),
                0x5c => try self.f32Ne(),
                0x5d => try self.f32Lt(),
                0x5e => try self.f32Gt(),
                0x5f => try self.f32Le(),
                0x60 => try self.f32Ge(),
                // f64 comparison
                0x61 => try self.f64Eq(),
                0x62 => try self.f64Ne(),
                0x63 => try self.f64Lt(),
                0x64 => try self.f64Gt(),
                0x65 => try self.f64Le(),
                0x66 => try self.f64Ge(),
                // i32 unary
                0x67 => try self.i32Clz(),
                0x68 => try self.i32Ctz(),
                0x69 => try self.i32Popcnt(),
                // i32 binary
                0x6a => try self.i32Add(),
                0x6b => try self.i32Sub(),
                0x6c => try self.i32Mul(),
                0x6d => try self.i32DivS(),
                0x6e => try self.i32DivU(),
                0x6f => try self.i32RemS(),
                0x70 => try self.i32RemU(),
                0x71 => try self.i32And(),
                0x72 => try self.i32Or(),
                0x73 => try self.i32Xor(),
                0x74 => try self.i32Shl(),
                0x75 => try self.i32ShrS(),
                0x76 => try self.i32ShrU(),
                0x77 => try self.i32Rotl(),
                0x78 => try self.i32Rotr(),
                // i64 unary
                0x79 => try self.i64Clz(),
                0x7a => try self.i64Ctz(),
                0x7b => try self.i64Popcnt(),
                // i64 binary
                0x7c => try self.i64Add(),
                0x7d => try self.i64Sub(),
                0x7e => try self.i64Mul(),
                0x7f => try self.i64DivS(),
                0x80 => try self.i64DivU(),
                0x81 => try self.i64RemS(),
                0x82 => try self.i64RemU(),
                0x83 => try self.i64And(),
                0x84 => try self.i64Or(),
                0x85 => try self.i64Xor(),
                0x86 => try self.i64Shl(),
                0x87 => try self.i64ShrS(),
                0x88 => try self.i64ShrU(),
                0x89 => try self.i64Rotl(),
                0x8a => try self.i64Rotr(),
                // f32 unary + binary
                0x8b => try self.f32Abs(),
                0x8c => try self.f32Neg(),
                0x8d => try self.f32Ceil(),
                0x8e => try self.f32Floor(),
                0x8f => try self.f32Trunc(),
                0x90 => try self.f32Nearest(),
                0x91 => try self.f32Sqrt(),
                0x92 => try self.f32Add(),
                0x93 => try self.f32Sub(),
                0x94 => try self.f32Mul(),
                0x95 => try self.f32Div(),
                0x96 => try self.f32Min(),
                0x97 => try self.f32Max(),
                0x98 => try self.f32Copysign(),
                // f64 unary + binary
                0x99 => try self.f64Abs(),
                0x9a => try self.f64Neg(),
                0x9b => try self.f64Ceil(),
                0x9c => try self.f64Floor(),
                0x9d => try self.f64Trunc(),
                0x9e => try self.f64Nearest(),
                0x9f => try self.f64Sqrt(),
                0xa0 => try self.f64Add(),
                0xa1 => try self.f64Sub(),
                0xa2 => try self.f64Mul(),
                0xa3 => try self.f64Div(),
                0xa4 => try self.f64Min(),
                0xa5 => try self.f64Max(),
                0xa6 => try self.f64Copysign(),
                // Conversions
                0xa7 => try self.i32WrapI64(),
                0xa8 => try self.i32TruncF32S(),
                0xa9 => try self.i32TruncF32U(),
                0xaa => try self.i32TruncF64S(),
                0xab => try self.i32TruncF64U(),
                0xac => try self.i64ExtendI32S(),
                0xad => try self.i64ExtendI32U(),
                0xae => try self.i64TruncF32S(),
                0xaf => try self.i64TruncF32U(),
                0xb0 => try self.i64TruncF64S(),
                0xb1 => try self.i64TruncF64U(),
                0xb2 => try self.f32ConvertI32S(),
                0xb3 => try self.f32ConvertI32U(),
                0xb4 => try self.f32ConvertI64S(),
                0xb5 => try self.f32ConvertI64U(),
                0xb6 => try self.f32DemoteF64(),
                0xb7 => try self.f64ConvertI32S(),
                0xb8 => try self.f64ConvertI32U(),
                0xb9 => try self.f64ConvertI64S(),
                0xba => try self.f64ConvertI64U(),
                0xbb => try self.f64PromoteF32(),
                0xbc => try self.i32ReinterpretF32(),
                0xbd => try self.i64ReinterpretF64(),
                0xbe => try self.f32ReinterpretI32(),
                0xbf => try self.f64ReinterpretI64(),
                // Sign extension
                0xc0 => try self.i32Extend8S(),
                0xc1 => try self.i32Extend16S(),
                0xc2 => try self.i64Extend8S(),
                0xc3 => try self.i64Extend16S(),
                0xc4 => try self.i64Extend32S(),
                // ref.null / ref.is_null / ref.func
                0xd0 => { pc += 1; try self.pushValue(.{ .ref_null = {} }); },
                0xd1 => { const v = try self.popValue(); try self.pushValue(.{ .i32 = @intFromBool(v == .ref_null) }); },
                0xd2 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; try self.pushValue(.{ .ref_func = idx }); },
                0xd3 => { // ref.eq
                    const b = try self.popValue();
                    const a = try self.popValue();
                    const eq: bool = blk: {
                        if (a == .ref_null and b == .ref_null) break :blk true;
                        if (a == .ref_null or b == .ref_null) break :blk false;
                        if (a == .ref_i31 and b == .ref_i31) break :blk a.ref_i31 == b.ref_i31;
                        if (a == .ref_func and b == .ref_func) break :blk a.ref_func == b.ref_func;
                        if (a == .ref_struct and b == .ref_struct) break :blk a.ref_struct == b.ref_struct;
                        if (a == .ref_array and b == .ref_array) break :blk a.ref_array == b.ref_array;
                        if (a == .ref_extern and b == .ref_extern) break :blk a.ref_extern == b.ref_extern;
                        break :blk false;
                    };
                    try self.pushValue(.{ .i32 = @intFromBool(eq) });
                },
                0xd4 => { // ref.as_non_null
                    const v = try self.popValue();
                    if (v == .ref_null) return error.NullReference;
                    try self.pushValue(v);
                },
                0xd5 => { // br_on_null
                    var t = pc;
                    const depth = readCodeU32(code, &t);
                    pc = t;
                    const v = try self.popValue();
                    if (v == .ref_null) {
                        self.branch_depth = depth;
                        return pc;
                    } else {
                        try self.pushValue(v);
                    }
                },
                0xd6 => { // br_on_non_null
                    var t = pc;
                    const depth = readCodeU32(code, &t);
                    pc = t;
                    const v = try self.popValue();
                    if (v != .ref_null) {
                        try self.pushValue(v);
                        self.branch_depth = depth;
                        return pc;
                    }
                },
                // 0xfc prefix: saturating truncation + bulk memory
                0xfc => {
                    var t = pc;
                    const sub = readCodeU32(code, &t);
                    pc = t;
                    switch (sub) {
                        0x00 => try self.i32TruncSatF32S(),
                        0x01 => try self.i32TruncSatF32U(),
                        0x02 => try self.i32TruncSatF64S(),
                        0x03 => try self.i32TruncSatF64U(),
                        0x04 => try self.i64TruncSatF32S(),
                        0x05 => try self.i64TruncSatF32U(),
                        0x06 => try self.i64TruncSatF64S(),
                        0x07 => try self.i64TruncSatF64U(),
                        0x08 => { // memory.init
                            const data_idx = readCodeU32(code, &pc);
                            const mem_idx = readCodeU32(code, &pc);
                            try self.memoryInit(data_idx, mem_idx);
                        },
                        0x09 => { // data.drop
                            const data_idx = readCodeU32(code, &pc);
                            if (data_idx < self.instance.dropped_data.capacity())
                                self.instance.dropped_data.set(data_idx);
                        },
                        0x0a => { // memory.copy
                            const dst_mem = readCodeU32(code, &pc);
                            const src_mem = readCodeU32(code, &pc);
                            try self.memoryCopy(dst_mem, src_mem);
                        },
                        0x0b => { // memory.fill
                            const mem_idx = readCodeU32(code, &pc);
                            try self.memoryFill(mem_idx);
                        },
                        0x0c => { // table.init
                            const elem_idx = readCodeU32(code, &pc);
                            const tbl_idx = readCodeU32(code, &pc);
                            try self.tableInit(elem_idx, tbl_idx);
                        },
                        0x0d => { // elem.drop
                            const elem_idx = readCodeU32(code, &pc);
                            if (elem_idx < self.instance.dropped_elems.capacity())
                                self.instance.dropped_elems.set(elem_idx);
                        },
                        0x0e => { // table.copy
                            const dst_tbl = readCodeU32(code, &pc);
                            const src_tbl = readCodeU32(code, &pc);
                            try self.tableCopy(dst_tbl, src_tbl);
                        },
                        0x0f => try self.tableGrow(code, &pc), // table.grow
                        0x10 => try self.tableSize(code, &pc), // table.size
                        0x11 => try self.tableFill(code, &pc), // table.fill
                        else => return error.Unimplemented,
                    }
                },
                0xfb => { // GC prefix
                    var t = pc;
                    const gc_sub = readCodeU32(code, &t);
                    pc = t;
                    switch (gc_sub) {
                        0x00 => { // struct.new
                            const type_idx = readCodeU32(code, &pc);
                            const field_count = self.getStructFieldCount(type_idx);
                            var fields_buf: [64]Value = undefined;
                            var i: u32 = field_count;
                            while (i > 0) { i -= 1; fields_buf[i] = try self.popValue(); }
                            const obj_idx = try self.allocStruct(type_idx, fields_buf[0..field_count]);
                            try self.pushValue(.{ .ref_struct = obj_idx });
                        },
                        0x01 => { // struct.new_default
                            const type_idx = readCodeU32(code, &pc);
                            const field_count = self.getStructFieldCount(type_idx);
                            var fields_buf: [64]Value = undefined;
                            for (0..field_count) |fi| fields_buf[fi] = self.getDefaultFieldValue(type_idx, @intCast(fi));
                            const obj_idx = try self.allocStruct(type_idx, fields_buf[0..field_count]);
                            try self.pushValue(.{ .ref_struct = obj_idx });
                        },
                        0x02, 0x03, 0x04 => { // struct.get, struct.get_s, struct.get_u
                            const stype_idx = readCodeU32(code, &pc);
                            const field_idx = readCodeU32(code, &pc);
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) {
                                .ref_struct => |id| id, .ref_func => |id| id, else => return error.NullReference,
                            };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            const obj = &self.gc_objects.items[obj_id];
                            if (field_idx >= obj.fields.items.len) return error.Unimplemented;
                            const val = obj.fields.items[field_idx];
                            // For packed fields (i8/i16), apply sign/zero extension
                            const field_type = getStructFieldType(self.instance.module, stype_idx, field_idx);
                            if (gc_sub == 0x03 and field_type == .i8) {
                                // struct.get_s i8: sign-extend from 8 bits
                                const raw: i8 = @truncate(val.i32);
                                try self.pushValue(.{ .i32 = @as(i32, raw) });
                            } else if (gc_sub == 0x04 and field_type == .i8) {
                                // struct.get_u i8: zero-extend from 8 bits
                                const raw: u8 = @truncate(@as(u32, @bitCast(val.i32)));
                                try self.pushValue(.{ .i32 = @as(i32, @intCast(@as(u32, raw))) });
                            } else if (gc_sub == 0x03 and field_type == .i16) {
                                const raw: i16 = @truncate(val.i32);
                                try self.pushValue(.{ .i32 = @as(i32, raw) });
                            } else if (gc_sub == 0x04 and field_type == .i16) {
                                const raw: u16 = @truncate(@as(u32, @bitCast(val.i32)));
                                try self.pushValue(.{ .i32 = @as(i32, @intCast(@as(u32, raw))) });
                            } else {
                                try self.pushValue(val);
                            }
                        },
                        0x05 => { // struct.set
                            const stype_idx2 = readCodeU32(code, &pc);
                            const field_idx = readCodeU32(code, &pc);
                            const val = try self.popValue();
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) {
                                .ref_struct => |id| id, .ref_func => |id| id, else => return error.NullReference,
                            };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            // For packed fields, truncate the value
                            const ft = getStructFieldType(self.instance.module, stype_idx2, field_idx);
                            if (ft == .i8) {
                                self.gc_objects.items[obj_id].fields.items[field_idx] = .{ .i32 = @as(i32, @as(u8, @truncate(@as(u32, @bitCast(val.i32))))) };
                            } else if (ft == .i16) {
                                self.gc_objects.items[obj_id].fields.items[field_idx] = .{ .i32 = @as(i32, @as(u16, @truncate(@as(u32, @bitCast(val.i32))))) };
                            } else {
                                self.gc_objects.items[obj_id].fields.items[field_idx] = val;
                            }
                        },
                        0x06 => { // array.new
                            const type_idx = readCodeU32(code, &pc);
                            const len: u32 = @bitCast(try self.popI32());
                            const init_val = try self.popValue();
                            const obj_idx = try self.allocArray(type_idx, len, init_val);
                            try self.pushValue(.{ .ref_array = obj_idx });
                        },
                        0x07 => { // array.new_default
                            const type_idx = readCodeU32(code, &pc);
                            const len: u32 = @bitCast(try self.popI32());
                            const default_val = self.getDefaultFieldValue(type_idx, 0);
                            const obj_idx = try self.allocArray(type_idx, len, default_val);
                            try self.pushValue(.{ .ref_array = obj_idx });
                        },
                        0x08 => { // array.new_fixed
                            const type_idx = readCodeU32(code, &pc);
                            const count = readCodeU32(code, &pc);
                            var fields_buf: [256]Value = undefined;
                            var fi: u32 = count;
                            while (fi > 0) { fi -= 1; fields_buf[fi] = try self.popValue(); }
                            const idx: u32 = @intCast(self.gc_objects.items.len);
                            var obj = GcObject{ .type_idx = type_idx, .fields = .{} };
                            obj.fields.appendSlice(self.allocator, fields_buf[0..count]) catch return error.OutOfMemory;
                            self.gc_objects.append(self.allocator, obj) catch return error.OutOfMemory;
                            try self.pushValue(.{ .ref_array = idx });
                        },
                        0x09 => { // array.new_data
                            const type_idx = readCodeU32(code, &pc);
                            const data_idx = readCodeU32(code, &pc);
                            const len: u32 = @bitCast(try self.popI32());
                            const offset: u32 = @bitCast(try self.popI32());
                            if (data_idx >= self.instance.module.data_segments.items.len)
                                return error.OutOfBoundsMemoryAccess;
                            const seg = self.instance.module.data_segments.items[data_idx];
                            const dropped = data_idx < self.instance.dropped_data.capacity() and
                                self.instance.dropped_data.isSet(data_idx);
                            const data = if (dropped) &[0]u8{} else seg.data;
                            const elem_size = getArrayElemByteSize(self.instance.module, type_idx);
                            const byte_len: u64 = @as(u64, len) * elem_size;
                            if (@as(u64, offset) + byte_len > data.len) return error.OutOfBoundsMemoryAccess;
                            const idx: u32 = @intCast(self.gc_objects.items.len);
                            var obj = GcObject{ .type_idx = type_idx, .fields = .{} };
                            for (0..len) |i| {
                                const off = offset + @as(u32, @intCast(i)) * elem_size;
                                const val = readArrayElemFromData(data, off, elem_size);
                                obj.fields.append(self.allocator, val) catch return error.OutOfMemory;
                            }
                            self.gc_objects.append(self.allocator, obj) catch return error.OutOfMemory;
                            try self.pushValue(.{ .ref_array = idx });
                        },
                        0x0a => { // array.new_elem
                            const type_idx = readCodeU32(code, &pc);
                            const elem_idx = readCodeU32(code, &pc);
                            const len: u32 = @bitCast(try self.popI32());
                            const offset: u32 = @bitCast(try self.popI32());
                            if (elem_idx >= self.instance.module.elem_segments.items.len)
                                return error.OutOfBoundsTableAccess;
                            const seg = &self.instance.module.elem_segments.items[elem_idx];
                            const dropped = elem_idx < self.instance.dropped_elems.capacity() and
                                self.instance.dropped_elems.isSet(elem_idx);
                            const var_len: u32 = @intCast(seg.elem_var_indices.items.len);
                            const expr_len: u32 = seg.elem_expr_count;
                            const seg_len: u32 = if (dropped) 0 else @max(var_len, expr_len);
                            if (@as(u64, offset) + len > seg_len) return error.OutOfBoundsTableAccess;
                            const idx: u32 = @intCast(self.gc_objects.items.len);
                            var obj = GcObject{ .type_idx = type_idx, .fields = .{} };
                            if (var_len == 0 and expr_len > 0 and seg.elem_expr_bytes.len > 0) {
                                // Expression-based elem segment
                                var expr_pc: usize = 0;
                                var skip: u32 = 0;
                                while (skip < offset and expr_pc < seg.elem_expr_bytes.len) : (skip += 1) {
                                    while (expr_pc < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc] != 0x0b) expr_pc += 1;
                                    if (expr_pc < seg.elem_expr_bytes.len) expr_pc += 1;
                                }
                                for (0..len) |_| {
                                    const expr_start = expr_pc;
                                    while (expr_pc < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc] != 0x0b) expr_pc += 1;
                                    if (expr_pc < seg.elem_expr_bytes.len) expr_pc += 1;
                                    const val = evalConstExpr(self.instance, seg.elem_expr_bytes[expr_start..expr_pc]);
                                    obj.fields.append(self.allocator, val orelse .{ .ref_null = {} }) catch return error.OutOfMemory;
                                }
                            } else {
                                for (0..len) |i| {
                                    const var_entry = seg.elem_var_indices.items[offset + i];
                                    const func_idx = switch (var_entry) { .index => |fi2| fi2, .name => 0 };
                                    if (func_idx == std.math.maxInt(u32)) {
                                        obj.fields.append(self.allocator, .{ .ref_null = {} }) catch return error.OutOfMemory;
                                    } else {
                                        obj.fields.append(self.allocator, .{ .ref_func = func_idx }) catch return error.OutOfMemory;
                                    }
                                }
                            }
                            self.gc_objects.append(self.allocator, obj) catch return error.OutOfMemory;
                            try self.pushValue(.{ .ref_array = idx });
                        },
                        0x0b, 0x0c, 0x0d => { // array.get, array.get_s, array.get_u
                            const arr_type_idx = readCodeU32(code, &pc);
                            const arr_idx_val: u32 = @bitCast(try self.popI32());
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) {
                                .ref_array => |id| id, .ref_func => |id| id, else => return error.NullReference,
                            };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            const obj = &self.gc_objects.items[obj_id];
                            if (arr_idx_val >= obj.fields.items.len) return error.OutOfBoundsTableAccess;
                            const val = obj.fields.items[arr_idx_val];
                            const elem_type = getArrayElemType(self.instance.module, arr_type_idx);
                            if (gc_sub == 0x0c and elem_type == .i8) {
                                const raw: i8 = @truncate(val.i32);
                                try self.pushValue(.{ .i32 = @as(i32, raw) });
                            } else if (gc_sub == 0x0d and elem_type == .i8) {
                                const raw: u8 = @truncate(@as(u32, @bitCast(val.i32)));
                                try self.pushValue(.{ .i32 = @as(i32, @intCast(@as(u32, raw))) });
                            } else if (gc_sub == 0x0c and elem_type == .i16) {
                                const raw: i16 = @truncate(val.i32);
                                try self.pushValue(.{ .i32 = @as(i32, raw) });
                            } else if (gc_sub == 0x0d and elem_type == .i16) {
                                const raw: u16 = @truncate(@as(u32, @bitCast(val.i32)));
                                try self.pushValue(.{ .i32 = @as(i32, @intCast(@as(u32, raw))) });
                            } else {
                                try self.pushValue(val);
                            }
                        },
                        0x0e => { // array.set
                            _ = readCodeU32(code, &pc); // type_idx
                            const val = try self.popValue();
                            const arr_idx_val: u32 = @bitCast(try self.popI32());
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) {
                                .ref_array => |id| id, .ref_func => |id| id, else => return error.NullReference,
                            };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            self.gc_objects.items[obj_id].fields.items[arr_idx_val] = val;
                        },
                        0x0f => { // array.len
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) {
                                .ref_array => |id| id, .ref_func => |id| id, else => return error.NullReference,
                            };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            try self.pushValue(.{ .i32 = @intCast(self.gc_objects.items[obj_id].fields.items.len) });
                        },
                        0x10 => { // array.fill
                            _ = readCodeU32(code, &pc); // type_idx
                            const n: u32 = @bitCast(try self.popI32());
                            const val = try self.popValue();
                            const offset2: u32 = @bitCast(try self.popI32());
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) { .ref_array => |id| id, else => return error.NullReference };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            const obj = &self.gc_objects.items[obj_id];
                            if (@as(u64, offset2) + n > obj.fields.items.len) return error.OutOfBoundsTableAccess;
                            for (offset2..offset2 + n) |i| obj.fields.items[i] = val;
                        },
                        0x11 => { // array.copy
                            const dst_type = readCodeU32(code, &pc);
                            _ = readCodeU32(code, &pc); // src_type
                            _ = dst_type;
                            const n: u32 = @bitCast(try self.popI32());
                            const src_off: u32 = @bitCast(try self.popI32());
                            const src_ref = try self.popValue();
                            const dst_off: u32 = @bitCast(try self.popI32());
                            const dst_ref = try self.popValue();
                            if (src_ref == .ref_null or dst_ref == .ref_null) return error.NullReference;
                            const src_id = switch (src_ref) { .ref_array => |id| id, else => return error.NullReference };
                            const dst_id = switch (dst_ref) { .ref_array => |id| id, else => return error.NullReference };
                            if (src_id >= self.gc_objects.items.len or dst_id >= self.gc_objects.items.len) return error.Unimplemented;
                            const src_obj = &self.gc_objects.items[src_id];
                            const dst_obj = &self.gc_objects.items[dst_id];
                            if (@as(u64, src_off) + n > src_obj.fields.items.len or
                                @as(u64, dst_off) + n > dst_obj.fields.items.len) return error.OutOfBoundsTableAccess;
                            if (n > 0) {
                                // Copy with overlap handling
                                if (src_id == dst_id and dst_off > src_off) {
                                    var i: u32 = n;
                                    while (i > 0) { i -= 1; dst_obj.fields.items[dst_off + i] = src_obj.fields.items[src_off + i]; }
                                } else {
                                    for (0..n) |i| dst_obj.fields.items[dst_off + @as(u32, @intCast(i))] = src_obj.fields.items[src_off + @as(u32, @intCast(i))];
                                }
                            }
                        },
                        0x12 => { // array.init_data
                            const type_idx = readCodeU32(code, &pc);
                            const data_idx = readCodeU32(code, &pc);
                            const n: u32 = @bitCast(try self.popI32());
                            const src_off: u32 = @bitCast(try self.popI32());
                            const dst_off: u32 = @bitCast(try self.popI32());
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) { .ref_array => |id| id, else => return error.NullReference };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            if (data_idx >= self.instance.module.data_segments.items.len) return error.OutOfBoundsMemoryAccess;
                            const seg = self.instance.module.data_segments.items[data_idx];
                            const dropped = data_idx < self.instance.dropped_data.capacity() and self.instance.dropped_data.isSet(data_idx);
                            const data = if (dropped) &[0]u8{} else seg.data;
                            const elem_size = getArrayElemByteSize(self.instance.module, type_idx);
                            const byte_len: u64 = @as(u64, n) * elem_size;
                            if (@as(u64, src_off) + byte_len > data.len) return error.OutOfBoundsMemoryAccess;
                            const obj = &self.gc_objects.items[obj_id];
                            if (@as(u64, dst_off) + n > obj.fields.items.len) return error.OutOfBoundsTableAccess;
                            for (0..n) |i| {
                                const off = src_off + @as(u32, @intCast(i)) * elem_size;
                                obj.fields.items[dst_off + @as(u32, @intCast(i))] = readArrayElemFromData(data, off, elem_size);
                            }
                        },
                        0x13 => { // array.init_elem
                            _ = readCodeU32(code, &pc); // type_idx
                            const elem_idx = readCodeU32(code, &pc);
                            const n: u32 = @bitCast(try self.popI32());
                            const src_off: u32 = @bitCast(try self.popI32());
                            const dst_off: u32 = @bitCast(try self.popI32());
                            const ref = try self.popValue();
                            if (ref == .ref_null) return error.NullReference;
                            const obj_id = switch (ref) { .ref_array => |id| id, else => return error.NullReference };
                            if (obj_id >= self.gc_objects.items.len) return error.Unimplemented;
                            if (elem_idx >= self.instance.module.elem_segments.items.len) return error.OutOfBoundsTableAccess;
                            const seg = &self.instance.module.elem_segments.items[elem_idx];
                            const dropped2 = elem_idx < self.instance.dropped_elems.capacity() and
                                self.instance.dropped_elems.isSet(elem_idx);
                            const var_len2: u32 = @intCast(seg.elem_var_indices.items.len);
                            const expr_len2: u32 = seg.elem_expr_count;
                            const seg_len2: u32 = if (dropped2) 0 else @max(var_len2, expr_len2);
                            if (@as(u64, src_off) + n > seg_len2) return error.OutOfBoundsTableAccess;
                            const obj = &self.gc_objects.items[obj_id];
                            if (@as(u64, dst_off) + n > obj.fields.items.len) return error.OutOfBoundsTableAccess;
                            if (var_len2 == 0 and expr_len2 > 0 and seg.elem_expr_bytes.len > 0) {
                                var expr_pc2: usize = 0;
                                var skip2: u32 = 0;
                                while (skip2 < src_off and expr_pc2 < seg.elem_expr_bytes.len) : (skip2 += 1) {
                                    while (expr_pc2 < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc2] != 0x0b) expr_pc2 += 1;
                                    if (expr_pc2 < seg.elem_expr_bytes.len) expr_pc2 += 1;
                                }
                                for (0..n) |i| {
                                    const expr_start2 = expr_pc2;
                                    while (expr_pc2 < seg.elem_expr_bytes.len and seg.elem_expr_bytes[expr_pc2] != 0x0b) expr_pc2 += 1;
                                    if (expr_pc2 < seg.elem_expr_bytes.len) expr_pc2 += 1;
                                    const val = evalConstExpr(self.instance, seg.elem_expr_bytes[expr_start2..expr_pc2]);
                                    obj.fields.items[dst_off + @as(u32, @intCast(i))] = val orelse .{ .ref_null = {} };
                                }
                            } else {
                                for (0..n) |i| {
                                    const var_entry = seg.elem_var_indices.items[src_off + @as(u32, @intCast(i))];
                                    const func_idx = switch (var_entry) { .index => |fi2| fi2, .name => 0 };
                                    obj.fields.items[dst_off + @as(u32, @intCast(i))] = if (func_idx == std.math.maxInt(u32)) .{ .ref_null = {} } else .{ .ref_func = func_idx };
                                }
                            }
                        },
                        0x1a => { // any.convert_extern — externref to anyref
                            const val = try self.popValue();
                            if (val == .ref_null) {
                                try self.pushValue(.{ .ref_null = {} });
                            } else if (val == .ref_extern) {
                                // Restore original value if it was externalized by extern.convert_any
                                if (self.extern_originals.get(val.ref_extern)) |orig| {
                                    try self.pushValue(orig);
                                } else {
                                    // Host externref — keep as ref_extern (won't match eq types)
                                    try self.pushValue(val);
                                }
                            } else {
                                // Host externref (ref_func from wast_runner) — wrap as ref_extern
                                const ext_id = self.next_extern_id;
                                self.next_extern_id +%= 1;
                                try self.pushValue(.{ .ref_extern = ext_id });
                            }
                        },
                        0x1b => { // extern.convert_any — anyref to externref
                            const val = try self.popValue();
                            if (val == .ref_null) {
                                try self.pushValue(.{ .ref_null = {} });
                            } else {
                                // Store original value for roundtrip restoration
                                const ext_id = self.next_extern_id;
                                self.next_extern_id +%= 1;
                                self.extern_originals.put(self.allocator, ext_id, val) catch {};
                                try self.pushValue(.{ .ref_extern = ext_id });
                            }
                        },
                        0x14, 0x15 => { // ref.test (non-null / nullable)
                            const heap_type = readCodeS32(code, &pc);
                            const val = try self.popValue();
                            const result: i32 = switch (val) {
                                .ref_null => if (gc_sub == 0x15) @as(i32, 1) else @as(i32, 0),
                                .ref_func => |fidx| blk: {
                                    // func matches: func(0x70), any(0x6e)
                                    if (heap_type == 0x70 or heap_type == 0x6e) break :blk 1;
                                    if (heap_type >= 0) {
                                        const ht_idx: u32 = @intCast(heap_type);
                                        if (fidx < self.instance.module.funcs.items.len) {
                                            const func_type = self.instance.module.funcs.items[fidx].decl.type_var.index;
                                            break :blk if (self.isSubtypeOf(func_type, ht_idx, self)) @as(i32, 1) else @as(i32, 0);
                                        }
                                    }
                                    break :blk 0;
                                },
                                .ref_i31 => blk: {
                                    // i31 matches: i31(0x6c), eq(0x6d), any(0x6e)
                                    break :blk if (heap_type == 0x6c or heap_type == 0x6d or heap_type == 0x6e) @as(i32, 1) else @as(i32, 0);
                                },
                                .ref_struct => |obj_id| blk: {
                                    // struct matches: struct(0x6b), eq(0x6d), any(0x6e), or concrete type
                                    if (heap_type == 0x6b or heap_type == 0x6d or heap_type == 0x6e) break :blk 1;
                                    if (heap_type >= 0 and heap_type < 0x68 and obj_id < self.gc_objects.items.len) {
                                        const obj_type = self.gc_objects.items[obj_id].type_idx;
                                        const ht_idx: u32 = @intCast(heap_type);
                                        if (obj_type == ht_idx) break :blk 1;
                                        if (self.isSubtypeOf(obj_type, ht_idx, self)) break :blk 1;
                                    }
                                    break :blk 0;
                                },
                                .ref_array => |obj_id| blk: {
                                    // array matches: array(0x6a), eq(0x6d), any(0x6e), or concrete type
                                    if (heap_type == 0x6a or heap_type == 0x6d or heap_type == 0x6e) break :blk 1;
                                    if (heap_type >= 0 and heap_type < 0x68 and obj_id < self.gc_objects.items.len) {
                                        const obj_type = self.gc_objects.items[obj_id].type_idx;
                                        const ht_idx: u32 = @intCast(heap_type);
                                        if (obj_type == ht_idx) break :blk 1;
                                        if (self.isSubtypeOf(obj_type, ht_idx, self)) break :blk 1;
                                    }
                                    break :blk 0;
                                },
                                .ref_extern => blk: {
                                    break :blk if (heap_type == 0x6f or heap_type == 0x6e) @as(i32, 1) else @as(i32, 0);
                                },
                                else => 0,
                            };
                            try self.pushValue(.{ .i32 = result });
                        },
                        0x16, 0x17 => { // ref.cast (non-null / nullable)
                            const heap_type = readCodeS32(code, &pc);
                            const val = try self.popValue();
                            switch (val) {
                                .ref_null => {
                                    if (gc_sub == 0x16) return error.CastFailure;
                                    try self.pushValue(val);
                                },
                                .ref_i31 => {
                                    if (heap_type == 0x6c or heap_type == 0x6d or heap_type == 0x6e or heap_type < 0)
                                        try self.pushValue(val)
                                    else return error.CastFailure;
                                },
                                .ref_struct => |obj_id| {
                                    if (heap_type == 0x6b or heap_type == 0x6d or heap_type == 0x6e or heap_type < 0) {
                                        try self.pushValue(val);
                                    } else if (heap_type >= 0 and heap_type < 0x68 and obj_id < self.gc_objects.items.len) {
                                        const obj_type = self.gc_objects.items[obj_id].type_idx;
                                        if (obj_type == @as(u32, @intCast(heap_type)) or self.isSubtypeOf(obj_type, @intCast(heap_type), self))
                                            try self.pushValue(val)
                                        else return error.CastFailure;
                                    } else return error.CastFailure;
                                },
                                .ref_array => |obj_id| {
                                    if (heap_type == 0x6a or heap_type == 0x6d or heap_type == 0x6e or heap_type < 0) {
                                        try self.pushValue(val);
                                    } else if (heap_type >= 0 and heap_type < 0x68 and obj_id < self.gc_objects.items.len) {
                                        const obj_type = self.gc_objects.items[obj_id].type_idx;
                                        if (obj_type == @as(u32, @intCast(heap_type)) or self.isSubtypeOf(obj_type, @intCast(heap_type), self))
                                            try self.pushValue(val)
                                        else return error.CastFailure;
                                    } else return error.CastFailure;
                                },
                                .ref_func => {
                                    if (heap_type == 0x70 or heap_type == 0x6e or heap_type < 0)
                                        try self.pushValue(val)
                                    else return error.CastFailure;
                                },
                                .ref_extern => {
                                    if (heap_type == 0x6f or heap_type < 0)
                                        try self.pushValue(val)
                                    else return error.CastFailure;
                                },
                                else => return error.CastFailure,
                            }
                        },
                        0x18 => { // br_on_cast
                            const depth = readCodeU32(code, &pc);
                            const cast_flags = code[pc];
                            pc += 1;
                            const target_ht = readCodeS32(code, &pc);
                            const val = try self.popValue();
                            const dst_nullable = (cast_flags & 2) != 0;
                            const matches = if (val == .ref_null) dst_nullable else gcValueMatchesHeapType(self, val, target_ht);
                            if (matches) {
                                try self.pushValue(val);
                                self.branch_depth = depth;
                                return pc;
                            } else {
                                try self.pushValue(val);
                            }
                        },
                        0x19 => { // br_on_cast_fail
                            const depth = readCodeU32(code, &pc);
                            const cast_flags = code[pc];
                            pc += 1;
                            const target_ht = readCodeS32(code, &pc);
                            const val = try self.popValue();
                            const dst_nullable = (cast_flags & 2) != 0;
                            const matches = if (val == .ref_null) dst_nullable else gcValueMatchesHeapType(self, val, target_ht);
                            if (!matches) {
                                try self.pushValue(val);
                                self.branch_depth = depth;
                                return pc;
                            } else {
                                try self.pushValue(val);
                            }
                        },
                        0x1c => { // ref.i31
                            const val = try self.popI32();
                            try self.pushValue(.{ .ref_i31 = @bitCast(val & 0x7fff_ffff) });
                        },
                        0x1d => { // i31.get_u
                            const v = try self.popValue();
                            if (v == .ref_null) return error.NullReference;
                            const raw = switch (v) {
                                .ref_i31 => |r| r,
                                .ref_func => |r| r, // table.get returns ref_func for i31 values
                                else => return error.NullReference,
                            };
                            try self.pushValue(.{ .i32 = @intCast(raw & 0x7fff_ffff) });
                        },
                        0x1e => { // i31.get_s
                            const v = try self.popValue();
                            if (v == .ref_null) return error.NullReference;
                            const raw = switch (v) {
                                .ref_i31 => |r| r,
                                .ref_func => |r| r,
                                else => return error.NullReference,
                            };
                            const masked = raw & 0x7fff_ffff;
                            const signed: i32 = if (masked & 0x4000_0000 != 0)
                                @bitCast(masked | 0x8000_0000)
                            else
                                @intCast(masked);
                            try self.pushValue(.{ .i32 = signed });
                        },
                        else => return error.Unimplemented,
                    }
                },
                0xfd => { // SIMD prefix
                    var t = pc;
                    const simd_sub = readCodeU32(code, &t);
                    pc = t;
                    switch (simd_sub) {
                        // v128.load (memarg)
                        0x00 => {
                            const m = readCodeU32(code, &pc);
                            _ = readCodeU32(code, &pc); // align
                            const o = readCodeU32(code, &pc);
                            try self.v128Load(m, o);
                        },
                        // v128.load8x8_s / u
                        0x01 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128Load8x8(m, o, true); },
                        0x02 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128Load8x8(m, o, false); },
                        // v128.load16x4_s / u
                        0x03 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128Load16x4(m, o, true); },
                        0x04 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128Load16x4(m, o, false); },
                        // v128.load32x2_s / u
                        0x05 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128Load32x2(m, o, true); },
                        0x06 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128Load32x2(m, o, false); },
                        // v128.load8_splat / load16_splat / load32_splat / load64_splat
                        0x07 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128LoadSplat(m, o, 1); },
                        0x08 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128LoadSplat(m, o, 2); },
                        0x09 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128LoadSplat(m, o, 4); },
                        0x0a => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128LoadSplat(m, o, 8); },
                        // v128.store (memarg)
                        0x0b => {
                            const m = readCodeU32(code, &pc);
                            _ = readCodeU32(code, &pc); // align
                            const o = readCodeU32(code, &pc);
                            try self.v128Store(m, o);
                        },
                        0x0c => try self.simdConst(code, &pc), // v128.const
                        // i8x16.shuffle
                        0x0d => {
                            var imm: [16]u8 = undefined;
                            if (pc + 16 <= code.len) {
                                @memcpy(&imm, code[pc..][0..16]);
                                pc += 16;
                            } else return error.Unimplemented;
                            try self.i8x16Shuffle(imm);
                        },
                        // i8x16.swizzle
                        0x0e => try self.i8x16Swizzle(),
                        // i8x16.splat .. f64x2.splat
                        0x0f => try self.splatOp(u8),
                        0x10 => try self.splatOp(u16),
                        0x11 => try self.splatOp(u32),
                        0x12 => try self.splatOp(u64),
                        0x13 => try self.f32Splat(),
                        0x14 => try self.f64Splat(),
                        // i8x16.extract_lane_s/u, i8x16.replace_lane
                        0x15 => { const lane = code[pc]; pc += 1; try self.extractLane(i8, lane, true); },
                        0x16 => { const lane = code[pc]; pc += 1; try self.extractLane(u8, lane, false); },
                        0x17 => { const lane = code[pc]; pc += 1; try self.replaceLane(u8, lane); },
                        // i16x8.extract_lane_s/u, i16x8.replace_lane
                        0x18 => { const lane = code[pc]; pc += 1; try self.extractLane(i16, lane, true); },
                        0x19 => { const lane = code[pc]; pc += 1; try self.extractLane(u16, lane, false); },
                        0x1a => { const lane = code[pc]; pc += 1; try self.replaceLane(u16, lane); },
                        // i32x4.extract_lane, i32x4.replace_lane
                        0x1b => { const lane = code[pc]; pc += 1; try self.extractLane(u32, lane, false); },
                        0x1c => { const lane = code[pc]; pc += 1; try self.replaceLane(u32, lane); },
                        // i64x2.extract_lane, i64x2.replace_lane
                        0x1d => { const lane = code[pc]; pc += 1; try self.extractLane(u64, lane, false); },
                        0x1e => { const lane = code[pc]; pc += 1; try self.replaceLane(u64, lane); },
                        // f32x4.extract_lane, f32x4.replace_lane
                        0x1f => { const lane = code[pc]; pc += 1; try self.extractLaneF32(lane); },
                        0x20 => { const lane = code[pc]; pc += 1; try self.replaceLaneF32(lane); },
                        // f64x2.extract_lane, f64x2.replace_lane
                        0x21 => { const lane = code[pc]; pc += 1; try self.extractLaneF64(lane); },
                        0x22 => { const lane = code[pc]; pc += 1; try self.replaceLaneF64(lane); },
                        // v128.load8_lane .. v128.load64_lane (0x54-0x57)
                        0x54 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128LoadLane(m, o, 1, lane); },
                        0x55 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128LoadLane(m, o, 2, lane); },
                        0x56 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128LoadLane(m, o, 4, lane); },
                        0x57 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128LoadLane(m, o, 8, lane); },
                        // v128.store8_lane .. v128.store64_lane (0x58-0x5b)
                        0x58 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128StoreLane(m, o, 1, lane); },
                        0x59 => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128StoreLane(m, o, 2, lane); },
                        0x5a => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128StoreLane(m, o, 4, lane); },
                        0x5b => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); const lane = code[pc]; pc += 1; try self.v128StoreLane(m, o, 8, lane); },
                        // v128.load32_zero / v128.load64_zero (0x5c-0x5d)
                        0x5c => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128LoadZero(m, o, 4); },
                        0x5d => { const m = readCodeU32(code, &pc); _ = readCodeU32(code, &pc); const o = readCodeU32(code, &pc); try self.v128LoadZero(m, o, 8); },
                        // f32x4.demote_f64x2_zero / f64x2.promote_low_f32x4
                        0x5e => try self.f32x4DemoteF64x2Zero(),
                        0x5f => try self.f64x2PromoteLowF32x4(),

                        // ── i8x16 comparison (0x23-0x2c) ──
                        0x23 => try self.simdCmpOp(u8, cmpEq(u8)),
                        0x24 => try self.simdCmpOp(u8, cmpNe(u8)),
                        0x25 => try self.simdCmpOp(u8, cmpLtS(u8)),
                        0x26 => try self.simdCmpOp(u8, cmpLtU(u8)),
                        0x27 => try self.simdCmpOp(u8, cmpGtS(u8)),
                        0x28 => try self.simdCmpOp(u8, cmpGtU(u8)),
                        0x29 => try self.simdCmpOp(u8, cmpLeS(u8)),
                        0x2a => try self.simdCmpOp(u8, cmpLeU(u8)),
                        0x2b => try self.simdCmpOp(u8, cmpGeS(u8)),
                        0x2c => try self.simdCmpOp(u8, cmpGeU(u8)),
                        // ── i16x8 comparison (0x2d-0x36) ──
                        0x2d => try self.simdCmpOp(u16, cmpEq(u16)),
                        0x2e => try self.simdCmpOp(u16, cmpNe(u16)),
                        0x2f => try self.simdCmpOp(u16, cmpLtS(u16)),
                        0x30 => try self.simdCmpOp(u16, cmpLtU(u16)),
                        0x31 => try self.simdCmpOp(u16, cmpGtS(u16)),
                        0x32 => try self.simdCmpOp(u16, cmpGtU(u16)),
                        0x33 => try self.simdCmpOp(u16, cmpLeS(u16)),
                        0x34 => try self.simdCmpOp(u16, cmpLeU(u16)),
                        0x35 => try self.simdCmpOp(u16, cmpGeS(u16)),
                        0x36 => try self.simdCmpOp(u16, cmpGeU(u16)),
                        // ── i32x4 comparison (0x37-0x40) ──
                        0x37 => try self.simdCmpOp(u32, cmpEq(u32)),
                        0x38 => try self.simdCmpOp(u32, cmpNe(u32)),
                        0x39 => try self.simdCmpOp(u32, cmpLtS(u32)),
                        0x3a => try self.simdCmpOp(u32, cmpLtU(u32)),
                        0x3b => try self.simdCmpOp(u32, cmpGtS(u32)),
                        0x3c => try self.simdCmpOp(u32, cmpGtU(u32)),
                        0x3d => try self.simdCmpOp(u32, cmpLeS(u32)),
                        0x3e => try self.simdCmpOp(u32, cmpLeU(u32)),
                        0x3f => try self.simdCmpOp(u32, cmpGeS(u32)),
                        0x40 => try self.simdCmpOp(u32, cmpGeU(u32)),
                        // ── f32x4 comparison (0x41-0x46) ──
                        0x41 => try self.simdFloatCmpOp(f32, floatEq(f32)),
                        0x42 => try self.simdFloatCmpOp(f32, floatNe(f32)),
                        0x43 => try self.simdFloatCmpOp(f32, floatLt(f32)),
                        0x44 => try self.simdFloatCmpOp(f32, floatGt(f32)),
                        0x45 => try self.simdFloatCmpOp(f32, floatLe(f32)),
                        0x46 => try self.simdFloatCmpOp(f32, floatGe(f32)),
                        // ── f64x2 comparison (0x47-0x4c) ──
                        0x47 => try self.simdFloatCmpOp(f64, floatEq(f64)),
                        0x48 => try self.simdFloatCmpOp(f64, floatNe(f64)),
                        0x49 => try self.simdFloatCmpOp(f64, floatLt(f64)),
                        0x4a => try self.simdFloatCmpOp(f64, floatGt(f64)),
                        0x4b => try self.simdFloatCmpOp(f64, floatLe(f64)),
                        0x4c => try self.simdFloatCmpOp(f64, floatGe(f64)),

                        // ── Bitwise ops (0x4d-0x53) ──
                        0x4d => try self.simdNot(),
                        0x4e => try self.simdAnd(),
                        0x4f => try self.simdAndNot(),
                        0x50 => try self.simdOr(),
                        0x51 => try self.simdXor(),
                        0x52 => try self.simdBitselect(),
                        0x53 => try self.simdAnyTrue(),

                        // ── i8x16 ops (0x60-0x7b) ──
                        0x60 => try self.simdUnaryOp(u8, intAbs(u8)),
                        0x61 => try self.simdUnaryOp(u8, intNeg(u8)),
                        0x62 => try self.i8x16Popcnt(),
                        0x63 => try self.simdAllTrue(u8),
                        0x64 => try self.simdBitmask(u8),
                        0x65 => try self.simdNarrowS(u16, u8),
                        0x66 => try self.simdNarrowU(u16, u8),
                        0x6b => try self.simdShiftOp(u8, .left),
                        0x6c => try self.simdShiftOp(u8, .right_s),
                        0x6d => try self.simdShiftOp(u8, .right_u),
                        0x6e => try self.simdBinOp(u8, intAdd(u8)),
                        0x6f => try self.simdBinOp(u8, intAddSatS(u8)),
                        0x70 => try self.simdBinOp(u8, intAddSatU(u8)),
                        0x71 => try self.simdBinOp(u8, intSub(u8)),
                        0x72 => try self.simdBinOp(u8, intSubSatS(u8)),
                        0x73 => try self.simdBinOp(u8, intSubSatU(u8)),
                        0x76 => try self.simdBinOp(u8, intMinS(u8)),
                        0x77 => try self.simdBinOp(u8, intMinU(u8)),
                        0x78 => try self.simdBinOp(u8, intMaxS(u8)),
                        0x79 => try self.simdBinOp(u8, intMaxU(u8)),
                        0x7b => try self.simdBinOp(u8, intAvgrU(u8)),

                        // ── f32x4 rounding (interleaved with i8x16) ──
                        0x67 => try self.simdUnaryOp(f32, floatCeil(f32)),
                        0x68 => try self.simdUnaryOp(f32, floatFloor(f32)),
                        0x69 => try self.simdUnaryOp(f32, floatTrunc(f32)),
                        0x6a => try self.simdUnaryOp(f32, floatNearest(f32)),

                        // ── f64x2 rounding (interleaved) ──
                        0x74 => try self.simdUnaryOp(f64, floatCeil(f64)),
                        0x75 => try self.simdUnaryOp(f64, floatFloor(f64)),
                        0x7a => try self.simdUnaryOp(f64, floatTrunc(f64)),
                        0x94 => try self.simdUnaryOp(f64, floatNearest(f64)),

                        // ── extadd_pairwise (0x7c-0x7f) ──
                        0x7c => try self.simdExtaddPairwise(u8, u16, true),
                        0x7d => try self.simdExtaddPairwise(u8, u16, false),
                        0x7e => try self.simdExtaddPairwise(u16, u32, true),
                        0x7f => try self.simdExtaddPairwise(u16, u32, false),

                        // ── i16x8 ops (0x80-0x9f) ──
                        0x80 => try self.simdUnaryOp(u16, intAbs(u16)),
                        0x81 => try self.simdUnaryOp(u16, intNeg(u16)),
                        0x82 => try self.i16x8Q15mulrSatS(),
                        0x83 => try self.simdAllTrue(u16),
                        0x84 => try self.simdBitmask(u16),
                        0x85 => try self.simdNarrowS(u32, u16),
                        0x86 => try self.simdNarrowU(u32, u16),
                        0x87 => try self.simdExtendLow(u8, u16, true),
                        0x88 => try self.simdExtendHigh(u8, u16, true),
                        0x89 => try self.simdExtendLow(u8, u16, false),
                        0x8a => try self.simdExtendHigh(u8, u16, false),
                        0x8b => try self.simdShiftOp(u16, .left),
                        0x8c => try self.simdShiftOp(u16, .right_s),
                        0x8d => try self.simdShiftOp(u16, .right_u),
                        0x8e => try self.simdBinOp(u16, intAdd(u16)),
                        0x8f => try self.simdBinOp(u16, intAddSatS(u16)),
                        0x90 => try self.simdBinOp(u16, intAddSatU(u16)),
                        0x91 => try self.simdBinOp(u16, intSub(u16)),
                        0x92 => try self.simdBinOp(u16, intSubSatS(u16)),
                        0x93 => try self.simdBinOp(u16, intSubSatU(u16)),
                        0x95 => try self.simdBinOp(u16, intMul(u16)),
                        0x96 => try self.simdBinOp(u16, intMinS(u16)),
                        0x97 => try self.simdBinOp(u16, intMinU(u16)),
                        0x98 => try self.simdBinOp(u16, intMaxS(u16)),
                        0x99 => try self.simdBinOp(u16, intMaxU(u16)),
                        0x9b => try self.simdBinOp(u16, intAvgrU(u16)),
                        0x9c => try self.simdExtmulLow(u8, u16, true),
                        0x9d => try self.simdExtmulHigh(u8, u16, true),
                        0x9e => try self.simdExtmulLow(u8, u16, false),
                        0x9f => try self.simdExtmulHigh(u8, u16, false),

                        // ── i32x4 ops (0xa0-0xbf) ──
                        0xa0 => try self.simdUnaryOp(u32, intAbs(u32)),
                        0xa1 => try self.simdUnaryOp(u32, intNeg(u32)),
                        0xa3 => try self.simdAllTrue(u32),
                        0xa4 => try self.simdBitmask(u32),
                        0xa7 => try self.simdExtendLow(u16, u32, true),
                        0xa8 => try self.simdExtendHigh(u16, u32, true),
                        0xa9 => try self.simdExtendLow(u16, u32, false),
                        0xaa => try self.simdExtendHigh(u16, u32, false),
                        0xab => try self.simdShiftOp(u32, .left),
                        0xac => try self.simdShiftOp(u32, .right_s),
                        0xad => try self.simdShiftOp(u32, .right_u),
                        0xae => try self.simdBinOp(u32, intAdd(u32)),
                        0xb1 => try self.simdBinOp(u32, intSub(u32)),
                        0xb5 => try self.simdBinOp(u32, intMul(u32)),
                        0xb6 => try self.simdBinOp(u32, intMinS(u32)),
                        0xb7 => try self.simdBinOp(u32, intMinU(u32)),
                        0xb8 => try self.simdBinOp(u32, intMaxS(u32)),
                        0xb9 => try self.simdBinOp(u32, intMaxU(u32)),
                        0xba => try self.i32x4DotI16x8S(),
                        0xbc => try self.simdExtmulLow(u16, u32, true),
                        0xbd => try self.simdExtmulHigh(u16, u32, true),
                        0xbe => try self.simdExtmulLow(u16, u32, false),
                        0xbf => try self.simdExtmulHigh(u16, u32, false),

                        // ── i64x2 ops (0xc0-0xdf) ──
                        0xc0 => try self.simdUnaryOp(u64, intAbs(u64)),
                        0xc1 => try self.simdUnaryOp(u64, intNeg(u64)),
                        0xc3 => try self.simdAllTrue(u64),
                        0xc4 => try self.simdBitmask(u64),
                        0xc7 => try self.simdExtendLow(u32, u64, true),
                        0xc8 => try self.simdExtendHigh(u32, u64, true),
                        0xc9 => try self.simdExtendLow(u32, u64, false),
                        0xca => try self.simdExtendHigh(u32, u64, false),
                        0xcb => try self.simdShiftOp(u64, .left),
                        0xcc => try self.simdShiftOp(u64, .right_s),
                        0xcd => try self.simdShiftOp(u64, .right_u),
                        0xce => try self.simdBinOp(u64, intAdd(u64)),
                        0xd1 => try self.simdBinOp(u64, intSub(u64)),
                        0xd5 => try self.simdBinOp(u64, intMul(u64)),
                        0xd6 => try self.simdCmpOp(u64, cmpEq(u64)),
                        0xd7 => try self.simdCmpOp(u64, cmpNe(u64)),
                        0xd8 => try self.simdCmpOp(u64, cmpLtS(u64)),
                        0xd9 => try self.simdCmpOp(u64, cmpGtS(u64)),
                        0xda => try self.simdCmpOp(u64, cmpLeS(u64)),
                        0xdb => try self.simdCmpOp(u64, cmpGeS(u64)),
                        0xdc => try self.simdExtmulLow(u32, u64, true),
                        0xdd => try self.simdExtmulHigh(u32, u64, true),
                        0xde => try self.simdExtmulLow(u32, u64, false),
                        0xdf => try self.simdExtmulHigh(u32, u64, false),

                        // ── f32x4 ops (0xe0-0xeb) ──
                        0xe0 => try self.simdUnaryOp(f32, floatAbs(f32)),
                        0xe1 => try self.simdUnaryOp(f32, floatNeg(f32)),
                        0xe3 => try self.simdUnaryOp(f32, floatSqrt(f32)),
                        0xe4 => try self.simdBinOp(f32, floatAdd(f32)),
                        0xe5 => try self.simdBinOp(f32, floatSub(f32)),
                        0xe6 => try self.simdBinOp(f32, floatMul(f32)),
                        0xe7 => try self.simdBinOp(f32, floatDiv(f32)),
                        0xe8 => try self.simdBinOp(f32, floatMin(f32)),
                        0xe9 => try self.simdBinOp(f32, floatMax(f32)),
                        0xea => try self.simdBinOp(f32, floatPmin(f32)),
                        0xeb => try self.simdBinOp(f32, floatPmax(f32)),

                        // ── f64x2 ops (0xec-0xf7) ──
                        0xec => try self.simdUnaryOp(f64, floatAbs(f64)),
                        0xed => try self.simdUnaryOp(f64, floatNeg(f64)),
                        0xef => try self.simdUnaryOp(f64, floatSqrt(f64)),
                        0xf0 => try self.simdBinOp(f64, floatAdd(f64)),
                        0xf1 => try self.simdBinOp(f64, floatSub(f64)),
                        0xf2 => try self.simdBinOp(f64, floatMul(f64)),
                        0xf3 => try self.simdBinOp(f64, floatDiv(f64)),
                        0xf4 => try self.simdBinOp(f64, floatMin(f64)),
                        0xf5 => try self.simdBinOp(f64, floatMax(f64)),
                        0xf6 => try self.simdBinOp(f64, floatPmin(f64)),
                        0xf7 => try self.simdBinOp(f64, floatPmax(f64)),

                        // ── Conversion ops (0xf8-0xff) ──
                        0xf8 => try self.i32x4TruncSatF32x4(true),
                        0xf9 => try self.i32x4TruncSatF32x4(false),
                        0xfa => try self.f32x4ConvertI32x4(true),
                        0xfb => try self.f32x4ConvertI32x4(false),
                        0xfc => try self.i32x4TruncSatF64x2Zero(true),
                        0xfd => try self.i32x4TruncSatF64x2Zero(false),
                        0xfe => try self.f64x2ConvertLowI32x4(true),
                        0xff => try self.f64x2ConvertLowI32x4(false),

                        // ── Relaxed SIMD (0x100-0x113) ──
                        0x100 => try self.relaxedSwizzle(),
                        0x101 => try self.relaxedTruncF32x4(true),
                        0x102 => try self.relaxedTruncF32x4(false),
                        0x103 => try self.relaxedTruncF64x2Zero(true),
                        0x104 => try self.relaxedTruncF64x2Zero(false),
                        0x105 => try self.relaxedMadd(f32, 4),
                        0x106 => try self.relaxedNmadd(f32, 4),
                        0x107 => try self.relaxedMadd(f64, 2),
                        0x108 => try self.relaxedNmadd(f64, 2),
                        0x109 => try self.relaxedLaneselect(u8, 16),
                        0x10a => try self.relaxedLaneselect(u16, 8),
                        0x10b => try self.relaxedLaneselect(u32, 4),
                        0x10c => try self.relaxedLaneselect(u64, 2),
                        0x10d => try self.relaxedMinMax(f32, 4, true),
                        0x10e => try self.relaxedMinMax(f32, 4, false),
                        0x10f => try self.relaxedMinMax(f64, 2, true),
                        0x110 => try self.relaxedMinMax(f64, 2, false),
                        0x111 => try self.relaxedQ15mulr(),
                        0x112 => try self.relaxedDotI8x16I7x16S(),
                        0x113 => try self.relaxedDotI8x16I7x16AddS(),

                        else => return error.Unimplemented,
                    }
                },
                else => return error.Unimplemented,
            }
        }
        return pc;
    }

    fn simdConst(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        if (pc.* + 16 <= code.len) {
            var bytes: [16]u8 = undefined;
            @memcpy(&bytes, code[pc.*..][0..16]);
            pc.* += 16;
            try self.pushValue(.{ .v128 = @bitCast(bytes) });
        } else return error.Unimplemented;
    }

    // ── SIMD v128 memory operations ─────────────────────────────────────

    fn v128Load(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 16 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var bytes: [16]u8 = undefined;
        @memcpy(&bytes, mem.items[idx..][0..16]);
        try self.pushValue(.{ .v128 = @bitCast(bytes) });
    }

    fn v128Store(self: *Interpreter, mem_idx: u32, offset: u32) TrapError!void {
        const val = try self.popValue();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 16 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bytes: [16]u8 = @bitCast(val.v128);
        @memcpy(mem.items[idx..][0..16], &bytes);
    }

    fn v128Load8x8(self: *Interpreter, mem_idx: u32, offset: u32, signed: bool) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var result: [8]i16 = undefined;
        for (0..8) |i| {
            if (signed) {
                result[i] = @as(i16, @as(i8, @bitCast(mem.items[idx + i])));
            } else {
                result[i] = @as(i16, mem.items[idx + i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn v128Load16x4(self: *Interpreter, mem_idx: u32, offset: u32, signed: bool) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var result: [4]i32 = undefined;
        for (0..4) |i| {
            const v = std.mem.readInt(i16, mem.items[idx + i * 2 ..][0..2], .little);
            if (signed) {
                result[i] = @as(i32, v);
            } else {
                result[i] = @as(i32, @as(u16, @bitCast(v)));
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn v128Load32x2(self: *Interpreter, mem_idx: u32, offset: u32, signed: bool) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + 8 > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var result: [2]i64 = undefined;
        for (0..2) |i| {
            const v = std.mem.readInt(i32, mem.items[idx + i * 4 ..][0..4], .little);
            if (signed) {
                result[i] = @as(i64, v);
            } else {
                result[i] = @as(i64, @as(u32, @bitCast(v)));
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn v128LoadSplat(self: *Interpreter, mem_idx: u32, offset: u32, comptime size: comptime_int) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + size > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var result: [16]u8 = undefined;
        const count = 16 / size;
        for (0..count) |i| {
            @memcpy(result[i * size ..][0..size], mem.items[idx..][0..size]);
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn v128LoadZero(self: *Interpreter, mem_idx: u32, offset: u32, comptime size: comptime_int) TrapError!void {
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + size > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var result: [16]u8 = [_]u8{0} ** 16;
        @memcpy(result[0..size], mem.items[idx..][0..size]);
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn v128LoadLane(self: *Interpreter, mem_idx: u32, offset: u32, comptime size: comptime_int, lane: u8) TrapError!void {
        const v = try self.popValue();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + size > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        var bytes: [16]u8 = @bitCast(v.v128);
        const lane_offset = @as(usize, lane) * size;
        if (lane_offset + size > 16) return error.Unimplemented;
        @memcpy(bytes[lane_offset..][0..size], mem.items[idx..][0..size]);
        try self.pushValue(.{ .v128 = @bitCast(bytes) });
    }

    fn v128StoreLane(self: *Interpreter, mem_idx: u32, offset: u32, comptime size: comptime_int, lane: u8) TrapError!void {
        const v = try self.popValue();
        const addr = try self.popMemAddr(mem_idx, offset);
        const mem = self.instance.getMemory(mem_idx);
        if (addr + size > mem.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bytes: [16]u8 = @bitCast(v.v128);
        const lane_offset = @as(usize, lane) * size;
        if (lane_offset + size > 16) return error.Unimplemented;
        @memcpy(mem.items[idx..][0..size], bytes[lane_offset..][0..size]);
    }

    // ── SIMD lane/splat operations ──────────────────────────────────────

    fn i8x16Shuffle(self: *Interpreter, imm: [16]u8) TrapError!void {
        const b = try self.popValue();
        const a = try self.popValue();
        const ab: [16]u8 = @bitCast(a.v128);
        const bb: [16]u8 = @bitCast(b.v128);
        var result: [16]u8 = undefined;
        for (0..16) |i| {
            const idx = imm[i];
            result[i] = if (idx < 16) ab[idx] else if (idx < 32) bb[idx - 16] else 0;
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn i8x16Swizzle(self: *Interpreter) TrapError!void {
        const s = try self.popValue();
        const v = try self.popValue();
        const vb: [16]u8 = @bitCast(v.v128);
        const sb: [16]u8 = @bitCast(s.v128);
        var result: [16]u8 = undefined;
        for (0..16) |i| {
            result[i] = if (sb[i] < 16) vb[sb[i]] else 0;
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn splatOp(self: *Interpreter, comptime T: type) TrapError!void {
        const count = 16 / @sizeOf(T);
        if (@sizeOf(T) <= 4) {
            const val = try self.popI32();
            const truncated: T = @truncate(@as(u32, @bitCast(val)));
            var lanes: [count]T = undefined;
            for (&lanes) |*l| l.* = truncated;
            try self.pushValue(.{ .v128 = @bitCast(lanes) });
        } else {
            const val = try self.popValue();
            const lanes = [2]u64{ @bitCast(val.i64), @bitCast(val.i64) };
            try self.pushValue(.{ .v128 = @bitCast(lanes) });
        }
    }

    fn f32Splat(self: *Interpreter) TrapError!void {
        const fval = try self.popF32();
        const lanes = [4]f32{ fval, fval, fval, fval };
        try self.pushValue(.{ .v128 = @bitCast(lanes) });
    }

    fn f64Splat(self: *Interpreter) TrapError!void {
        const fval = try self.popF64();
        const lanes = [2]f64{ fval, fval };
        try self.pushValue(.{ .v128 = @bitCast(lanes) });
    }

    fn extractLane(self: *Interpreter, comptime T: type, lane: u8, comptime signed: bool) TrapError!void {
        const count = 16 / @sizeOf(T);
        const v = try self.popValue();
        if (lane >= count) return error.Unimplemented;
        const lanes: [count]T = @bitCast(v.v128);
        if (@sizeOf(T) <= 4) {
            if (signed) {
                const s: i32 = @as(i32, @as(std.meta.Int(.signed, @bitSizeOf(T)), @bitCast(lanes[lane])));
                try self.pushValue(.{ .i32 = s });
            } else {
                const u_val: u32 = @as(u32, lanes[lane]);
                try self.pushValue(.{ .i32 = @bitCast(u_val) });
            }
        } else {
            try self.pushValue(.{ .i64 = @bitCast(lanes[lane]) });
        }
    }

    fn replaceLane(self: *Interpreter, comptime T: type, lane: u8) TrapError!void {
        const count = 16 / @sizeOf(T);
        if (@sizeOf(T) <= 4) {
            const val = try self.popI32();
            const v = try self.popValue();
            if (lane >= count) return error.Unimplemented;
            var lanes: [count]T = @bitCast(v.v128);
            lanes[lane] = @truncate(@as(u32, @bitCast(val)));
            try self.pushValue(.{ .v128 = @bitCast(lanes) });
        } else {
            const val = try self.popValue();
            const v = try self.popValue();
            if (lane >= count) return error.Unimplemented;
            var lanes: [count]T = @bitCast(v.v128);
            lanes[lane] = @bitCast(val.i64);
            try self.pushValue(.{ .v128 = @bitCast(lanes) });
        }
    }

    fn extractLaneF32(self: *Interpreter, lane: u8) TrapError!void {
        const v = try self.popValue();
        if (lane >= 4) return error.Unimplemented;
        const lanes: [4]f32 = @bitCast(v.v128);
        try self.pushValue(.{ .f32 = lanes[lane] });
    }

    fn replaceLaneF32(self: *Interpreter, lane: u8) TrapError!void {
        const fval = try self.popF32();
        const v = try self.popValue();
        if (lane >= 4) return error.Unimplemented;
        var lanes: [4]f32 = @bitCast(v.v128);
        lanes[lane] = fval;
        try self.pushValue(.{ .v128 = @bitCast(lanes) });
    }

    fn extractLaneF64(self: *Interpreter, lane: u8) TrapError!void {
        const v = try self.popValue();
        if (lane >= 2) return error.Unimplemented;
        const lanes: [2]f64 = @bitCast(v.v128);
        try self.pushValue(.{ .f64 = lanes[lane] });
    }

    fn replaceLaneF64(self: *Interpreter, lane: u8) TrapError!void {
        const fval = try self.popF64();
        const v = try self.popValue();
        if (lane >= 2) return error.Unimplemented;
        var lanes: [2]f64 = @bitCast(v.v128);
        lanes[lane] = fval;
        try self.pushValue(.{ .v128 = @bitCast(lanes) });
    }

    // ── SIMD generic helper functions ───────────────────────────────────

    /// Binary v128 op: pop two v128 values, apply `op` per lane, push result.
    fn simdBinOp(self: *Interpreter, comptime T: type, comptime op: fn (T, T) T) TrapError!void {
        const count = 16 / @sizeOf(T);
        const b: [count]T = @bitCast((try self.popValue()).v128);
        const a: [count]T = @bitCast((try self.popValue()).v128);
        var result: [count]T = undefined;
        for (0..count) |i| result[i] = op(a[i], b[i]);
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    /// Unary v128 op: pop one v128, apply `op` per lane, push result.
    fn simdUnaryOp(self: *Interpreter, comptime T: type, comptime op: fn (T) T) TrapError!void {
        const count = 16 / @sizeOf(T);
        const a: [count]T = @bitCast((try self.popValue()).v128);
        var result: [count]T = undefined;
        for (0..count) |i| result[i] = op(a[i]);
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    /// Compare op: pop two v128, compare per lane, push v128 with all-1s or all-0s per lane.
    fn simdCmpOp(self: *Interpreter, comptime T: type, comptime op: fn (T, T) bool) TrapError!void {
        const Unsigned = std.meta.Int(.unsigned, @bitSizeOf(T));
        const count = 16 / @sizeOf(T);
        const b: [count]T = @bitCast((try self.popValue()).v128);
        const a: [count]T = @bitCast((try self.popValue()).v128);
        var result: [count]Unsigned = undefined;
        for (0..count) |i| result[i] = if (op(a[i], b[i])) @as(Unsigned, @bitCast(@as(std.meta.Int(.signed, @bitSizeOf(T)), -1))) else 0;
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    /// Float compare op: pop two v128 of float type, compare per lane.
    fn simdFloatCmpOp(self: *Interpreter, comptime T: type, comptime op: fn (T, T) bool) TrapError!void {
        const Unsigned = std.meta.Int(.unsigned, @bitSizeOf(T));
        const count = 16 / @sizeOf(T);
        const b: [count]T = @bitCast((try self.popValue()).v128);
        const a: [count]T = @bitCast((try self.popValue()).v128);
        var result: [count]Unsigned = undefined;
        for (0..count) |i| result[i] = if (op(a[i], b[i])) std.math.maxInt(Unsigned) else 0;
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    /// Shift op: pop i32 shift amount, pop v128, shift each lane, push result.
    fn simdShiftOp(self: *Interpreter, comptime T: type, comptime dir: enum { left, right_s, right_u }) TrapError!void {
        const bits = @bitSizeOf(T);
        const Unsigned = std.meta.Int(.unsigned, bits);
        const Signed = std.meta.Int(.signed, bits);
        const ShiftT = std.math.Log2Int(Unsigned);
        const count = 16 / @sizeOf(T);
        const shift_raw: i32 = try self.popI32();
        const shift: ShiftT = @intCast(@as(u32, @bitCast(shift_raw)) % bits);
        const a: [count]T = @bitCast((try self.popValue()).v128);
        var result: [count]T = undefined;
        for (0..count) |i| {
            switch (dir) {
                .left => result[i] = @bitCast(@as(Unsigned, @bitCast(a[i])) << shift),
                .right_s => result[i] = @bitCast(@as(Unsigned, @bitCast(@as(Signed, @bitCast(a[i])) >> shift))),
                .right_u => result[i] = @bitCast(@as(Unsigned, @bitCast(a[i])) >> shift),
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    /// all_true: pop v128, push i32 (1 if all lanes non-zero).
    fn simdAllTrue(self: *Interpreter, comptime T: type) TrapError!void {
        const count = 16 / @sizeOf(T);
        const lanes: [count]T = @bitCast((try self.popValue()).v128);
        var all: bool = true;
        for (0..count) |i| {
            if (lanes[i] == 0) { all = false; break; }
        }
        try self.pushValue(.{ .i32 = @intFromBool(all) });
    }

    /// bitmask: extract high bit of each lane, pack into i32.
    fn simdBitmask(self: *Interpreter, comptime T: type) TrapError!void {
        const bits = @bitSizeOf(T);
        const Unsigned = std.meta.Int(.unsigned, bits);
        const count = 16 / @sizeOf(T);
        const lanes: [count]T = @bitCast((try self.popValue()).v128);
        var mask: u32 = 0;
        for (0..count) |i| {
            const val: Unsigned = @bitCast(lanes[i]);
            mask |= @as(u32, @intCast((val >> (bits - 1)) & 1)) << @intCast(i);
        }
        try self.pushValue(.{ .i32 = @bitCast(mask) });
    }

    // ── SIMD integer arithmetic lane ops ────────────────────────────────

    fn intAdd(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return a +% b; }
        }.f;
    }

    fn intSub(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return a -% b; }
        }.f;
    }

    fn intMul(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return a *% b; }
        }.f;
    }

    fn intNeg(comptime T: type) fn (T) T {
        return struct {
            fn f(a: T) T { return 0 -% a; }
        }.f;
    }

    fn intAbs(comptime T: type) fn (T) T {
        return struct {
            fn f(a: T) T {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                const s: Signed = @bitCast(a);
                if (s == std.math.minInt(Signed)) return a; // min value stays
                return @bitCast(if (s < 0) -s else s);
            }
        }.f;
    }

    // Saturating add/sub for signed
    fn intAddSatS(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                const sa: Signed = @bitCast(a);
                const sb: Signed = @bitCast(b);
                return @bitCast(sa +| sb);
            }
        }.f;
    }

    fn intSubSatS(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                const sa: Signed = @bitCast(a);
                const sb: Signed = @bitCast(b);
                return @bitCast(sa -| sb);
            }
        }.f;
    }

    // Saturating add/sub for unsigned
    fn intAddSatU(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return a +| b; }
        }.f;
    }

    fn intSubSatU(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return a -| b; }
        }.f;
    }

    fn intMinS(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                const sa: Signed = @bitCast(a);
                const sb: Signed = @bitCast(b);
                return @bitCast(@min(sa, sb));
            }
        }.f;
    }

    fn intMinU(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return @min(a, b); }
        }.f;
    }

    fn intMaxS(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                const sa: Signed = @bitCast(a);
                const sb: Signed = @bitCast(b);
                return @bitCast(@max(sa, sb));
            }
        }.f;
    }

    fn intMaxU(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return @max(a, b); }
        }.f;
    }

    fn intAvgrU(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                const Wide = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
                return @intCast((@as(Wide, a) + @as(Wide, b) + 1) / 2);
            }
        }.f;
    }

    // ── SIMD comparison helpers ─────────────────────────────────────────

    fn cmpEq(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a == b; } }.f;
    }
    fn cmpNe(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a != b; } }.f;
    }
    fn cmpLtS(comptime T: type) fn (T, T) bool {
        return struct {
            fn f(a: T, b: T) bool {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                return @as(Signed, @bitCast(a)) < @as(Signed, @bitCast(b));
            }
        }.f;
    }
    fn cmpLtU(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a < b; } }.f;
    }
    fn cmpGtS(comptime T: type) fn (T, T) bool {
        return struct {
            fn f(a: T, b: T) bool {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                return @as(Signed, @bitCast(a)) > @as(Signed, @bitCast(b));
            }
        }.f;
    }
    fn cmpGtU(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a > b; } }.f;
    }
    fn cmpLeS(comptime T: type) fn (T, T) bool {
        return struct {
            fn f(a: T, b: T) bool {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                return @as(Signed, @bitCast(a)) <= @as(Signed, @bitCast(b));
            }
        }.f;
    }
    fn cmpLeU(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a <= b; } }.f;
    }
    fn cmpGeS(comptime T: type) fn (T, T) bool {
        return struct {
            fn f(a: T, b: T) bool {
                const Signed = std.meta.Int(.signed, @bitSizeOf(T));
                return @as(Signed, @bitCast(a)) >= @as(Signed, @bitCast(b));
            }
        }.f;
    }
    fn cmpGeU(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a >= b; } }.f;
    }

    // Float comparisons
    fn floatEq(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a == b; } }.f;
    }
    fn floatNe(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a != b; } }.f;
    }
    fn floatLt(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a < b; } }.f;
    }
    fn floatGt(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a > b; } }.f;
    }
    fn floatLe(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a <= b; } }.f;
    }
    fn floatGe(comptime T: type) fn (T, T) bool {
        return struct { fn f(a: T, b: T) bool { return a >= b; } }.f;
    }

    // ── SIMD float arithmetic helpers ───────────────────────────────────

    fn floatAdd(comptime T: type) fn (T, T) T {
        return struct { fn f(a: T, b: T) T { return a + b; } }.f;
    }
    fn floatSub(comptime T: type) fn (T, T) T {
        return struct { fn f(a: T, b: T) T { return a - b; } }.f;
    }
    fn floatMul(comptime T: type) fn (T, T) T {
        return struct { fn f(a: T, b: T) T { return a * b; } }.f;
    }
    fn floatDiv(comptime T: type) fn (T, T) T {
        return struct { fn f(a: T, b: T) T { return a / b; } }.f;
    }
    fn floatAbs(comptime T: type) fn (T) T {
        return struct { fn f(a: T) T { return @abs(a); } }.f;
    }
    fn floatNeg(comptime T: type) fn (T) T {
        return struct { fn f(a: T) T { return -a; } }.f;
    }
    fn floatSqrt(comptime T: type) fn (T) T {
        return struct { fn f(a: T) T { return @sqrt(a); } }.f;
    }
    fn floatCeil(comptime T: type) fn (T) T {
        return struct { fn f(a: T) T { return @ceil(a); } }.f;
    }
    fn floatFloor(comptime T: type) fn (T) T {
        return struct { fn f(a: T) T { return @floor(a); } }.f;
    }
    fn floatTrunc(comptime T: type) fn (T) T {
        return struct { fn f(a: T) T { return @trunc(a); } }.f;
    }
    fn floatNearest(comptime T: type) fn (T) T {
        return struct {
            fn f(a: T) T {
                const UInt = if (T == f32) u32 else u64;
                const quiet_bit: UInt = if (T == f32) 0x00400000 else 0x0008000000000000;
                if (std.math.isNan(a)) return @bitCast(@as(UInt, @bitCast(a)) | quiet_bit);
                if (std.math.isInf(a)) return a;
                if (a == 0.0) return a; // preserve sign of zero
                const rounded = @round(a);
                // Banker's rounding: if exactly halfway, round to even
                const diff = a - rounded;
                var result = rounded;
                if (diff == 0.5 or diff == -0.5) {
                    const half_rounded = rounded / 2.0;
                    if (half_rounded != @round(half_rounded)) {
                        // rounded is odd, adjust
                        result = if (diff > 0) rounded + 1.0 else rounded - 1.0;
                    }
                }
                // Preserve sign of input when result is zero
                if (result == 0.0) return std.math.copysign(result, a);
                return result;
            }
        }.f;
    }

    /// IEEE 754 min: propagates NaN, -0 < +0
    fn floatMin(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                if (std.math.isNan(a)) return canonicalNan(T);
                if (std.math.isNan(b)) return canonicalNan(T);
                // -0 < +0
                if (a == b) {
                    const Uint = std.meta.Int(.unsigned, @bitSizeOf(T));
                    const ab: Uint = @bitCast(a);
                    const bb: Uint = @bitCast(b);
                    return @bitCast(ab | bb); // -0 wins over +0
                }
                return if (a < b) a else b;
            }
        }.f;
    }

    /// IEEE 754 max: propagates NaN, +0 > -0
    fn floatMax(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T {
                if (std.math.isNan(a)) return canonicalNan(T);
                if (std.math.isNan(b)) return canonicalNan(T);
                if (a == b) {
                    const Uint = std.meta.Int(.unsigned, @bitSizeOf(T));
                    const ab: Uint = @bitCast(a);
                    const bb: Uint = @bitCast(b);
                    return @bitCast(ab & bb); // +0 wins over -0
                }
                return if (a > b) a else b;
            }
        }.f;
    }

    fn canonicalNan(comptime T: type) T {
        return @bitCast(if (T == f32) @as(u32, 0x7fc00000) else @as(u64, 0x7ff8000000000000));
    }

    /// pmin: return b if b < a, else a (C-style, no NaN canonicalization)
    fn floatPmin(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return if (b < a) b else a; }
        }.f;
    }

    /// pmax: return b if a < b, else a
    fn floatPmax(comptime T: type) fn (T, T) T {
        return struct {
            fn f(a: T, b: T) T { return if (a < b) b else a; }
        }.f;
    }

    // ── SIMD bitwise operations ─────────────────────────────────────────

    fn simdNot(self: *Interpreter) TrapError!void {
        const a = (try self.popValue()).v128;
        try self.pushValue(.{ .v128 = ~a });
    }

    fn simdAnd(self: *Interpreter) TrapError!void {
        const b = (try self.popValue()).v128;
        const a = (try self.popValue()).v128;
        try self.pushValue(.{ .v128 = a & b });
    }

    fn simdAndNot(self: *Interpreter) TrapError!void {
        const b = (try self.popValue()).v128;
        const a = (try self.popValue()).v128;
        try self.pushValue(.{ .v128 = a & ~b });
    }

    fn simdOr(self: *Interpreter) TrapError!void {
        const b = (try self.popValue()).v128;
        const a = (try self.popValue()).v128;
        try self.pushValue(.{ .v128 = a | b });
    }

    fn simdXor(self: *Interpreter) TrapError!void {
        const b = (try self.popValue()).v128;
        const a = (try self.popValue()).v128;
        try self.pushValue(.{ .v128 = a ^ b });
    }

    fn simdBitselect(self: *Interpreter) TrapError!void {
        const c = (try self.popValue()).v128;
        const v2 = (try self.popValue()).v128;
        const v1 = (try self.popValue()).v128;
        try self.pushValue(.{ .v128 = (v1 & c) | (v2 & ~c) });
    }

    fn simdAnyTrue(self: *Interpreter) TrapError!void {
        const a = (try self.popValue()).v128;
        try self.pushValue(.{ .i32 = @intFromBool(a != 0) });
    }

    // ── SIMD narrow operations ──────────────────────────────────────────

    fn simdNarrowS(self: *Interpreter, comptime Src: type, comptime Dst: type) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
        const DstSigned = std.meta.Int(.signed, @bitSizeOf(Dst));
        const b: [src_count]Src = @bitCast((try self.popValue()).v128);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..src_count) |i| {
            const sv: SrcSigned = @bitCast(a[i]);
            const clamped: DstSigned = @intCast(@max(@as(SrcSigned, std.math.minInt(DstSigned)), @min(@as(SrcSigned, std.math.maxInt(DstSigned)), sv)));
            result[i] = @bitCast(clamped);
        }
        for (0..src_count) |i| {
            const sv: SrcSigned = @bitCast(b[i]);
            const clamped: DstSigned = @intCast(@max(@as(SrcSigned, std.math.minInt(DstSigned)), @min(@as(SrcSigned, std.math.maxInt(DstSigned)), sv)));
            result[src_count + i] = @bitCast(clamped);
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn simdNarrowU(self: *Interpreter, comptime Src: type, comptime Dst: type) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
        const b: [src_count]Src = @bitCast((try self.popValue()).v128);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..src_count) |i| {
            const sv: SrcSigned = @bitCast(a[i]);
            if (sv < 0) {
                result[i] = 0;
            } else if (sv > @as(SrcSigned, std.math.maxInt(Dst))) {
                result[i] = std.math.maxInt(Dst);
            } else {
                result[i] = @intCast(@as(Src, @bitCast(sv)));
            }
        }
        for (0..src_count) |i| {
            const sv: SrcSigned = @bitCast(b[i]);
            if (sv < 0) {
                result[src_count + i] = 0;
            } else if (sv > @as(SrcSigned, std.math.maxInt(Dst))) {
                result[src_count + i] = std.math.maxInt(Dst);
            } else {
                result[src_count + i] = @intCast(@as(Src, @bitCast(sv)));
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    // ── SIMD extend operations ──────────────────────────────────────────

    fn simdExtendLow(self: *Interpreter, comptime Src: type, comptime Dst: type, comptime signed: bool) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..dst_count) |i| {
            if (signed) {
                const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
                const DstSigned = std.meta.Int(.signed, @bitSizeOf(Dst));
                const sv: SrcSigned = @bitCast(a[i]);
                const extended: DstSigned = sv;
                result[i] = @bitCast(extended);
            } else {
                result[i] = @as(Dst, a[i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn simdExtendHigh(self: *Interpreter, comptime Src: type, comptime Dst: type, comptime signed: bool) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..dst_count) |i| {
            if (signed) {
                const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
                const DstSigned = std.meta.Int(.signed, @bitSizeOf(Dst));
                const sv: SrcSigned = @bitCast(a[dst_count + i]);
                const extended: DstSigned = sv;
                result[i] = @bitCast(extended);
            } else {
                result[i] = @as(Dst, a[dst_count + i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    // ── SIMD extmul operations ──────────────────────────────────────────

    fn simdExtmulLow(self: *Interpreter, comptime Src: type, comptime Dst: type, comptime signed: bool) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const b: [src_count]Src = @bitCast((try self.popValue()).v128);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..dst_count) |i| {
            if (signed) {
                const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
                const DstSigned = std.meta.Int(.signed, @bitSizeOf(Dst));
                const sa: DstSigned = @as(SrcSigned, @bitCast(a[i]));
                const sb: DstSigned = @as(SrcSigned, @bitCast(b[i]));
                result[i] = @bitCast(sa *% sb);
            } else {
                const wa: Dst = a[i];
                const wb: Dst = b[i];
                result[i] = wa *% wb;
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn simdExtmulHigh(self: *Interpreter, comptime Src: type, comptime Dst: type, comptime signed: bool) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const b: [src_count]Src = @bitCast((try self.popValue()).v128);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..dst_count) |i| {
            if (signed) {
                const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
                const DstSigned = std.meta.Int(.signed, @bitSizeOf(Dst));
                const sa: DstSigned = @as(SrcSigned, @bitCast(a[dst_count + i]));
                const sb: DstSigned = @as(SrcSigned, @bitCast(b[dst_count + i]));
                result[i] = @bitCast(sa *% sb);
            } else {
                const wa: Dst = a[dst_count + i];
                const wb: Dst = b[dst_count + i];
                result[i] = wa *% wb;
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    // ── SIMD special integer ops ────────────────────────────────────────

    fn i8x16Popcnt(self: *Interpreter) TrapError!void {
        const a: [16]u8 = @bitCast((try self.popValue()).v128);
        var result: [16]u8 = undefined;
        for (0..16) |i| result[i] = @popCount(a[i]);
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn i16x8Q15mulrSatS(self: *Interpreter) TrapError!void {
        const b: [8]u16 = @bitCast((try self.popValue()).v128);
        const a: [8]u16 = @bitCast((try self.popValue()).v128);
        var result: [8]u16 = undefined;
        for (0..8) |i| {
            const sa: i32 = @as(i16, @bitCast(a[i]));
            const sb: i32 = @as(i16, @bitCast(b[i]));
            const product = sa * sb;
            // Q15 rounding: (product + 0x4000) >> 15, saturated to i16
            const rounded = (product + 0x4000) >> 15;
            const clamped = @min(@as(i32, 32767), @max(@as(i32, -32768), rounded));
            result[i] = @bitCast(@as(i16, @intCast(clamped)));
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn i32x4DotI16x8S(self: *Interpreter) TrapError!void {
        const b: [8]u16 = @bitCast((try self.popValue()).v128);
        const a: [8]u16 = @bitCast((try self.popValue()).v128);
        var result: [4]i32 = undefined;
        for (0..4) |i| {
            const a0: i32 = @as(i16, @bitCast(a[i * 2]));
            const a1: i32 = @as(i16, @bitCast(a[i * 2 + 1]));
            const b0: i32 = @as(i16, @bitCast(b[i * 2]));
            const b1: i32 = @as(i16, @bitCast(b[i * 2 + 1]));
            result[i] = a0 *% b0 +% a1 *% b1;
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    // ── SIMD extadd_pairwise ────────────────────────────────────────────

    fn simdExtaddPairwise(self: *Interpreter, comptime Src: type, comptime Dst: type, comptime signed: bool) TrapError!void {
        const src_count = 16 / @sizeOf(Src);
        const dst_count = 16 / @sizeOf(Dst);
        const a: [src_count]Src = @bitCast((try self.popValue()).v128);
        var result: [dst_count]Dst = undefined;
        for (0..dst_count) |i| {
            if (signed) {
                const SrcSigned = std.meta.Int(.signed, @bitSizeOf(Src));
                const DstSigned = std.meta.Int(.signed, @bitSizeOf(Dst));
                const s0: DstSigned = @as(SrcSigned, @bitCast(a[i * 2]));
                const s1: DstSigned = @as(SrcSigned, @bitCast(a[i * 2 + 1]));
                result[i] = @bitCast(s0 + s1);
            } else {
                const DstT = Dst;
                result[i] = @as(DstT, a[i * 2]) + @as(DstT, a[i * 2 + 1]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    // ── SIMD conversion operations ──────────────────────────────────────

    fn f32x4DemoteF64x2Zero(self: *Interpreter) TrapError!void {
        const a: [2]f64 = @bitCast((try self.popValue()).v128);
        var result: [4]f32 = undefined;
        result[0] = @floatCast(a[0]);
        result[1] = @floatCast(a[1]);
        result[2] = 0;
        result[3] = 0;
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn f64x2PromoteLowF32x4(self: *Interpreter) TrapError!void {
        const a: [4]f32 = @bitCast((try self.popValue()).v128);
        var result: [2]f64 = undefined;
        result[0] = @floatCast(a[0]);
        result[1] = @floatCast(a[1]);
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn i32x4TruncSatF32x4(self: *Interpreter, comptime signed: bool) TrapError!void {
        const a: [4]f32 = @bitCast((try self.popValue()).v128);
        var result: [4]u32 = undefined;
        for (0..4) |i| {
            if (signed) {
                result[i] = @bitCast(truncSatF32ToI32(a[i]));
            } else {
                result[i] = truncSatF32ToU32(a[i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn f32x4ConvertI32x4(self: *Interpreter, comptime signed: bool) TrapError!void {
        const a: [4]u32 = @bitCast((try self.popValue()).v128);
        var result: [4]f32 = undefined;
        for (0..4) |i| {
            if (signed) {
                result[i] = @floatFromInt(@as(i32, @bitCast(a[i])));
            } else {
                result[i] = @floatFromInt(a[i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn i32x4TruncSatF64x2Zero(self: *Interpreter, comptime signed: bool) TrapError!void {
        const a: [2]f64 = @bitCast((try self.popValue()).v128);
        var result: [4]u32 = [4]u32{ 0, 0, 0, 0 };
        for (0..2) |i| {
            if (signed) {
                result[i] = @bitCast(truncSatF64ToI32(a[i]));
            } else {
                result[i] = truncSatF64ToU32(a[i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn f64x2ConvertLowI32x4(self: *Interpreter, comptime signed: bool) TrapError!void {
        const a: [4]u32 = @bitCast((try self.popValue()).v128);
        var result: [2]f64 = undefined;
        for (0..2) |i| {
            if (signed) {
                result[i] = @floatFromInt(@as(i32, @bitCast(a[i])));
            } else {
                result[i] = @floatFromInt(a[i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    // trunc_sat helpers for SIMD conversions
    fn truncSatF32ToI32(v: f32) i32 {
        if (std.math.isNan(v)) return 0;
        if (v >= @as(f32, @floatFromInt(@as(i32, 2147483647)))) return 2147483647;
        if (v <= @as(f32, @floatFromInt(@as(i32, -2147483648)))) return -2147483648;
        return @intFromFloat(v);
    }

    fn truncSatF32ToU32(v: f32) u32 {
        if (std.math.isNan(v)) return 0;
        if (v <= 0.0) return 0;
        if (v >= @as(f32, @floatFromInt(@as(u32, 4294967295)))) return 4294967295;
        return @intFromFloat(v);
    }

    fn truncSatF64ToI32(v: f64) i32 {
        if (std.math.isNan(v)) return 0;
        if (v >= 2147483647.0) return 2147483647;
        if (v <= -2147483648.0) return -2147483648;
        return @intFromFloat(v);
    }

    fn truncSatF64ToU32(v: f64) u32 {
        if (std.math.isNan(v)) return 0;
        if (v <= 0.0) return 0;
        if (v >= 4294967295.0) return 4294967295;
        return @intFromFloat(v);
    }

    // ── Relaxed SIMD operations ─────────────────────────────────────────

    fn relaxedSwizzle(self: *Interpreter) TrapError!void {
        const s = try self.popValue();
        const a = try self.popValue();
        const av: [16]u8 = @bitCast(a.v128);
        const sv: [16]u8 = @bitCast(s.v128);
        var result: [16]u8 = undefined;
        for (0..16) |i| {
            const idx = sv[i];
            result[i] = if (idx < 16) av[idx] else 0;
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedTruncF32x4(self: *Interpreter, comptime signed: bool) TrapError!void {
        try self.i32x4TruncSatF32x4(signed);
    }

    fn relaxedTruncF64x2Zero(self: *Interpreter, comptime signed: bool) TrapError!void {
        try self.i32x4TruncSatF64x2Zero(signed);
    }

    fn relaxedMadd(self: *Interpreter, comptime T: type, comptime lanes: comptime_int) TrapError!void {
        const c: [lanes]T = @bitCast((try self.popValue()).v128);
        const b: [lanes]T = @bitCast((try self.popValue()).v128);
        const a: [lanes]T = @bitCast((try self.popValue()).v128);
        var result: [lanes]T = undefined;
        for (0..lanes) |i| {
            result[i] = @mulAdd(T, a[i], b[i], c[i]);
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedNmadd(self: *Interpreter, comptime T: type, comptime lanes: comptime_int) TrapError!void {
        const c: [lanes]T = @bitCast((try self.popValue()).v128);
        const b: [lanes]T = @bitCast((try self.popValue()).v128);
        const a: [lanes]T = @bitCast((try self.popValue()).v128);
        var result: [lanes]T = undefined;
        for (0..lanes) |i| {
            result[i] = @mulAdd(T, -a[i], b[i], c[i]);
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedLaneselect(self: *Interpreter, comptime T: type, comptime lanes: comptime_int) TrapError!void {
        const m: [lanes]T = @bitCast((try self.popValue()).v128);
        const b: [lanes]T = @bitCast((try self.popValue()).v128);
        const a: [lanes]T = @bitCast((try self.popValue()).v128);
        var result: [lanes]T = undefined;
        for (0..lanes) |i| {
            result[i] = (a[i] & m[i]) | (b[i] & ~m[i]);
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedMinMax(self: *Interpreter, comptime T: type, comptime lanes: comptime_int, comptime is_min: bool) TrapError!void {
        const b: [lanes]T = @bitCast((try self.popValue()).v128);
        const a: [lanes]T = @bitCast((try self.popValue()).v128);
        var result: [lanes]T = undefined;
        for (0..lanes) |i| {
            if (is_min) {
                result[i] = @min(a[i], b[i]);
            } else {
                result[i] = @max(a[i], b[i]);
            }
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedQ15mulr(self: *Interpreter) TrapError!void {
        const b: [8]i16 = @bitCast((try self.popValue()).v128);
        const a: [8]i16 = @bitCast((try self.popValue()).v128);
        var result: [8]i16 = undefined;
        for (0..8) |i| {
            const prod: i32 = @as(i32, a[i]) * @as(i32, b[i]);
            result[i] = @truncate(@as(i32, @intCast((prod + 0x4000) >> 15)));
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedDotI8x16I7x16S(self: *Interpreter) TrapError!void {
        const b: [16]u8 = @bitCast((try self.popValue()).v128);
        const a: [16]u8 = @bitCast((try self.popValue()).v128);
        var result: [8]i16 = undefined;
        for (0..8) |i| {
            const a0: i16 = @as(i8, @bitCast(a[i * 2]));
            const a1: i16 = @as(i8, @bitCast(a[i * 2 + 1]));
            const b0: i16 = @as(i16, b[i * 2]);
            const b1: i16 = @as(i16, b[i * 2 + 1]);
            result[i] = @truncate(@as(i32, a0) * @as(i32, b0) + @as(i32, a1) * @as(i32, b1));
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    fn relaxedDotI8x16I7x16AddS(self: *Interpreter) TrapError!void {
        const c: [4]i32 = @bitCast((try self.popValue()).v128);
        const b: [16]u8 = @bitCast((try self.popValue()).v128);
        const a: [16]u8 = @bitCast((try self.popValue()).v128);
        var result: [4]i32 = undefined;
        for (0..4) |i| {
            var sum: i32 = c[i];
            for (0..4) |j| {
                const idx = i * 4 + j;
                const av: i32 = @as(i8, @bitCast(a[idx]));
                const bv: i32 = @as(i32, b[idx]);
                sum +%= av * bv;
            }
            result[i] = sum;
        }
        try self.pushValue(.{ .v128 = @bitCast(result) });
    }

    /// Check if a type index has GC sub-type metadata.
    fn hasSubTypeInfo(self: *const Interpreter, type_idx: u32) bool {
        if (type_idx >= self.instance.module.type_meta.items.len) return false;
        return self.instance.module.type_meta.items[type_idx].is_sub or
            self.instance.module.type_meta.items[type_idx].parent != std.math.maxInt(u32);
    }

    /// Check if actual_type is a subtype of (or equal to) expected_type.
    /// Walks the actual type's parent chain, checking iso-recursive equivalence at each step.
    fn isSubtypeOf(self: *const Interpreter, actual_idx: u32, expected_idx: u32, target: *const Interpreter) bool {
        const exp_mod = self.instance.module;
        const act_mod = target.instance.module;

        var current = actual_idx;
        var depth: u32 = 0;
        while (depth < 32) : (depth += 1) {
            // Check equivalence: same index (same module) or same canonical group + position
            if (exp_mod == act_mod and current == expected_idx) return true;
            if (typesEquivalent(exp_mod, expected_idx, act_mod, current)) return true;
            if (current >= act_mod.type_meta.items.len) break;
            const parent = act_mod.type_meta.items[current].parent;
            if (parent == std.math.maxInt(u32)) break;
            current = parent;
        }
        return false;
    }

    /// Check if two types are iso-recursively equivalent using canonical group IDs.
    fn typesEquivalent(mod_a: *const Mod.Module, idx_a: u32, mod_b: *const Mod.Module, idx_b: u32) bool {
        // Types without metadata (e.g., inline func types) match by signature alone
        if (idx_a >= mod_a.type_meta.items.len or idx_b >= mod_b.type_meta.items.len) return true;
        const meta_a = mod_a.type_meta.items[idx_a];
        const meta_b = mod_b.type_meta.items[idx_b];
        // Both must have valid canonical groups
        if (meta_a.canonical_group == std.math.maxInt(u32) or meta_b.canonical_group == std.math.maxInt(u32)) {
            // Fallback: structural comparison for cross-module types without canonicalization
            return recGroupsMatchStatic(mod_a, idx_a, mod_b, idx_b);
        }
        // Same module: canonical groups are directly comparable
        if (mod_a == mod_b) {
            return meta_a.canonical_group == meta_b.canonical_group and meta_a.rec_position == meta_b.rec_position;
        }
        // Cross-module: use structural comparison (canonical IDs are per-module)
        return recGroupsMatchStatic(mod_a, idx_a, mod_b, idx_b);
    }

    /// Structural rec group comparison for cross-module matching.
    fn recGroupsMatchStatic(exp_mod: *const Mod.Module, expected_idx: u32, act_mod: *const Mod.Module, actual_idx: u32) bool {
        if (expected_idx >= exp_mod.type_meta.items.len or actual_idx >= act_mod.type_meta.items.len)
            return true;
        const exp_meta = exp_mod.type_meta.items[expected_idx];
        const act_meta = act_mod.type_meta.items[actual_idx];
        if (exp_meta.rec_group_size != act_meta.rec_group_size) return false;
        if (exp_meta.rec_position != act_meta.rec_position) return false;
        const exp_start = exp_meta.rec_group;
        const act_start = act_meta.rec_group;
        for (0..exp_meta.rec_group_size) |i| {
            const ei = exp_start + @as(u32, @intCast(i));
            const ai = act_start + @as(u32, @intCast(i));
            if (ei >= exp_mod.type_meta.items.len or ai >= act_mod.type_meta.items.len) return false;
            if (exp_mod.type_meta.items[ei].kind != act_mod.type_meta.items[ai].kind) return false;
            if (ei < exp_mod.module_types.items.len and ai < act_mod.module_types.items.len) {
                const exp_entry = exp_mod.module_types.items[ei];
                const act_entry = act_mod.module_types.items[ai];
                switch (exp_entry) {
                    .func_type => |eft| switch (act_entry) {
                        .func_type => |aft| {
                            if (!std.mem.eql(types.ValType, eft.params, aft.params)) return false;
                            if (!std.mem.eql(types.ValType, eft.results, aft.results)) return false;
                        },
                        else => return false,
                    },
                    .struct_type => |est| switch (act_entry) {
                        .struct_type => |ast| {
                            if (est.fields.items.len != ast.fields.items.len) return false;
                        },
                        else => return false,
                    },
                    .array_type => switch (act_entry) {
                        .array_type => {},
                        else => return false,
                    },
                }
            }
        }
        return true;
    }
};

// ── Bytecode reading helpers ─────────────────────────────────────────────

fn readCodeU32(code: []const u8, pc: *usize) u32 {
    const result = leb128.readU32Leb128(code[pc.*..]) catch return 0;
    pc.* += result.bytes_read;
    return result.value;
}

fn readCodeS32(code: []const u8, pc: *usize) i32 {
    const result = leb128.readS32Leb128(code[pc.*..]) catch return 0;
    pc.* += result.bytes_read;
    return result.value;
}

fn readCodeS64(code: []const u8, pc: *usize) i64 {
    const result = leb128.readS64Leb128(code[pc.*..]) catch return 0;
    pc.* += result.bytes_read;
    return result.value;
}

fn readCodeFixedU32(code: []const u8, pc: usize) u32 {
    if (pc + 4 > code.len) return 0;
    return std.mem.readInt(u32, code[pc..][0..4], .little);
}

fn readCodeFixedU64(code: []const u8, pc: usize) u64 {
    if (pc + 8 > code.len) return 0;
    return std.mem.readInt(u64, code[pc..][0..8], .little);
}

fn skipBlockType(code: []const u8, pc: usize) usize {
    if (pc >= code.len) return pc;
    const byte = code[pc];
    // 0x40 = void, or a valtype byte (single-byte block type)
    if (byte == 0x40 or (byte >= 0x7b and byte <= 0x7f) or byte == 0x70 or byte == 0x6f or byte == 0x69 or byte == 0x63 or byte == 0x64) {
        return pc + 1;
    }
    // Otherwise it's a signed LEB128 type index
    var tmp = pc;
    _ = readCodeS32(code, &tmp);
    return tmp;
}

/// Skip past the catch clause vector for a try_table instruction.
fn skipCatchClauses(code: []const u8, pc: usize) usize {
    var p = pc;
    const count = readCodeU32(code, &p);
    for (0..count) |_| {
        if (p >= code.len) break;
        const kind = code[p];
        p += 1;
        if (kind <= 0x01) _ = readCodeU32(code, &p); // catch/catch_ref: tag index
        _ = readCodeU32(code, &p); // label
    }
    return p;
}

/// Scan forward from `start` to find matching else (0x05) or end (0x0b).
/// Returns pc just after the terminator byte.
fn scanToElseOrEnd(code: []const u8, start: usize) usize {
    var pc = start;
    var depth: u32 = 0;
    while (pc < code.len) {
        const op = code[pc];
        pc += 1;
        switch (op) {
            0x02, 0x03, 0x04 => {
                pc = skipBlockType(code, pc);
                depth += 1;
            },
            0x1f => { // try_table
                pc = skipBlockType(code, pc);
                pc = skipCatchClauses(code, pc);
                depth += 1;
            },
            0x05 => {
                if (depth == 0) return pc;
            },
            0x0b => {
                if (depth == 0) return pc;
                depth -= 1;
            },
            else => pc = skipImmediates(code, pc, op),
        }
    }
    return pc;
}

/// Scan forward from `start` to find matching end (0x0b), ignoring else.
fn scanToEnd(code: []const u8, start: usize) usize {
    var pc = start;
    var depth: u32 = 0;
    while (pc < code.len) {
        const op = code[pc];
        pc += 1;
        switch (op) {
            0x02, 0x03, 0x04 => {
                pc = skipBlockType(code, pc);
                depth += 1;
            },
            0x1f => { // try_table
                pc = skipBlockType(code, pc);
                pc = skipCatchClauses(code, pc);
                depth += 1;
            },
            0x0b => {
                if (depth == 0) return pc;
                depth -= 1;
            },
            else => pc = skipImmediates(code, pc, op),
        }
    }
    return pc;
}

/// Skip past the immediate operands for a given opcode.
fn skipImmediates(code: []const u8, pc: usize, op: u8) usize {
    var p = pc;
    switch (op) {
        0x08 => _ = readCodeU32(code, &p), // throw: tag index
        0x0a => {}, // throw_ref: no immediates
        0x0c, 0x0d => _ = readCodeU32(code, &p), // br, br_if
        0x0e => { // br_table
            const count = readCodeU32(code, &p);
            for (0..count + 1) |_| _ = readCodeU32(code, &p);
        },
        0x10, 0x12, 0x14, 0x15 => _ = readCodeU32(code, &p), // call, return_call, call_ref, return_call_ref
        0x11, 0x13 => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // call_indirect, return_call_indirect
        0x1c => { // select t*
            const vec_len = readCodeU32(code, &p);
            var ti: u32 = 0;
            while (ti < vec_len) : (ti += 1) _ = readCodeU32(code, &p);
        },
        0x20, 0x21, 0x22, 0x23, 0x24 => _ = readCodeU32(code, &p),
        0x25, 0x26 => _ = readCodeU32(code, &p), // table.get/set
        0x28...0x3e => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); },
        0x3f, 0x40 => _ = readCodeU32(code, &p),
        0x41 => _ = readCodeS32(code, &p),
        0x42 => _ = readCodeS64(code, &p),
        0x43 => p += 4,
        0x44 => p += 8,
        0xd0 => p += 1,
        0xd2 => _ = readCodeU32(code, &p),
        0xd5, 0xd6 => _ = readCodeU32(code, &p), // br_on_null, br_on_non_null: label depth
        0xfc => {
            const sub = readCodeU32(code, &p);
            switch (sub) {
                0x08, 0x0a, 0x0c, 0x0e => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); },
                0x09, 0x0b, 0x0d, 0x0f, 0x10, 0x11 => _ = readCodeU32(code, &p),
                else => {},
            }
        },
        0xfb => { // GC prefix
            const sub = readCodeU32(code, &p);
            switch (sub) {
                0x00, 0x01 => _ = readCodeU32(code, &p), // struct.new/new_default: typeidx
                0x02, 0x03, 0x04, 0x05 => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // struct.get/set: typeidx, fieldidx
                0x06, 0x07 => _ = readCodeU32(code, &p), // array.new/new_default: typeidx
                0x08 => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // array.new_fixed: typeidx, count
                0x09, 0x0a => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // array.new_data/elem
                0x0b, 0x0c, 0x0d, 0x0e => _ = readCodeU32(code, &p), // array.get/set: typeidx
                0x10 => _ = readCodeU32(code, &p), // array.fill: typeidx
                0x11 => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // array.copy: typeidx, typeidx
                0x12, 0x13 => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // array.init_data/elem
                0x14, 0x15, 0x16, 0x17 => _ = readCodeS32(code, &p), // ref.test/cast + heaptype
                0x18, 0x19 => { // br_on_cast, br_on_cast_fail
                    _ = readCodeU32(code, &p); // label
                    p += 1; // castflags
                    _ = readCodeS32(code, &p); // target heaptype
                },
                else => {},
            }
        },
        0xfd => { // SIMD prefix
            const sub = readCodeU32(code, &p);
            switch (sub) {
                0x00...0x0b => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // v128 load/store: memarg(align, offset) + mem_idx
                0x0c => p += 16, // v128.const: 16 bytes immediate
                0x0d => p += 16, // i8x16.shuffle: 16 lane bytes
                0x15...0x22 => p += 1, // extract_lane/replace_lane: 1 lane byte
                0x54...0x5d => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); p += 1; }, // v128 load/store lane
                else => {}, // Most SIMD ops have no immediates
            }
        },
        else => {},
    }
    return p;
}

/// Return the default (zero) value for a given ValType.
fn defaultForValType(vt: types.ValType) Value {
    return switch (vt) {
        .i32 => .{ .i32 = 0 },
        .i64 => .{ .i64 = 0 },
        .f32 => .{ .f32 = 0.0 },
        .f64 => .{ .f64 = 0.0 },
        .v128 => .{ .v128 = 0 },
        .funcref, .externref, .anyref, .exnref,
        .nullfuncref, .nullexternref, .nullref, .nullexnref,
        .ref, .ref_null => .{ .ref_null = {} },
        else => .{ .i32 = 0 },
    };
}

/// Get the byte size of an array element type.
fn getArrayElemByteSize(module: *const Mod.Module, type_idx: u32) u32 {
    if (type_idx < module.module_types.items.len) {
        switch (module.module_types.items[type_idx]) {
            .array_type => |at| return valTypeByteSize(at.field.type),
            else => {},
        }
    }
    return 1;
}

/// Get the field ValType for a struct type at the given field index.
fn getStructFieldType(module: *const Mod.Module, type_idx: u32, field_idx: u32) types.ValType {
    if (type_idx < module.module_types.items.len) {
        switch (module.module_types.items[type_idx]) {
            .struct_type => |st| {
                if (field_idx < st.fields.items.len) return st.fields.items[field_idx].type;
            },
            else => {},
        }
    }
    return .i32;
}

/// Get the element ValType for an array type.
fn getArrayElemType(module: *const Mod.Module, type_idx: u32) types.ValType {
    if (type_idx < module.module_types.items.len) {
        switch (module.module_types.items[type_idx]) {
            .array_type => |at| return at.field.type,
            else => {},
        }
    }
    return .i32;
}

/// Get the byte size for a ValType used in packed struct/array fields.
fn valTypeByteSize(vt: types.ValType) u32 {
    return switch (vt) {
        .i8 => 1,
        .i16 => 2,
        .i32, .f32 => 4,
        .i64, .f64 => 8,
        .v128 => 16,
        else => 1,
    };
}

/// Read an array element value from raw data bytes at the given offset.
fn readArrayElemFromData(data: []const u8, offset: u32, elem_size: u32) Value {
    const off: usize = offset;
    if (off + elem_size > data.len) return .{ .i32 = 0 };
    return switch (elem_size) {
        1 => .{ .i32 = @as(i32, data[off]) },
        2 => .{ .i32 = @as(i32, std.mem.readInt(u16, data[off..][0..2], .little)) },
        4 => .{ .i32 = @bitCast(std.mem.readInt(u32, data[off..][0..4], .little)) },
        8 => .{ .i64 = @bitCast(std.mem.readInt(u64, data[off..][0..8], .little)) },
        else => .{ .i32 = @as(i32, data[off]) },
    };
}

/// Check if a GC value matches a target heap type for ref.test/ref.cast/br_on_cast.
fn gcValueMatchesHeapType(self: *const Interpreter, val: Value, heap_type: i32) bool {
    return switch (val) {
        .ref_null => false,
        .ref_i31 => heap_type == 0x6c or heap_type == 0x6d or heap_type == 0x6e,
        .ref_struct => |obj_id| {
            if (heap_type == 0x6b or heap_type == 0x6d or heap_type == 0x6e) return true;
            if (heap_type >= 0 and heap_type < 0x68 and obj_id < self.gc_objects.items.len) {
                const obj_type = self.gc_objects.items[obj_id].type_idx;
                const ht: u32 = @intCast(heap_type);
                return obj_type == ht or self.isSubtypeOf(obj_type, ht, self);
            }
            return false;
        },
        .ref_array => |obj_id| {
            if (heap_type == 0x6a or heap_type == 0x6d or heap_type == 0x6e) return true;
            if (heap_type >= 0 and heap_type < 0x68 and obj_id < self.gc_objects.items.len) {
                const obj_type = self.gc_objects.items[obj_id].type_idx;
                const ht: u32 = @intCast(heap_type);
                return obj_type == ht or self.isSubtypeOf(obj_type, ht, self);
            }
            return false;
        },
        .ref_func => heap_type == 0x70 or heap_type == 0x6e,
        .ref_extern => heap_type == 0x6f or heap_type == 0x6e,
        else => false,
    };
}

/// Evaluate a simple constant expression (used for global init and segment offsets).
fn evalConstExpr(instance: *const Instance, expr: []const u8) ?Value {
    // Stack-based evaluator for extended constant expressions
    var stack: [16]Value = undefined;
    var sp: usize = 0;
    var pc: usize = 0;
    while (pc < expr.len) {
        const op = expr[pc];
        pc += 1;
        switch (op) {
            0x41 => { if (sp < 16) { stack[sp] = .{ .i32 = readCodeS32(expr, &pc) }; sp += 1; } },
            0x42 => { if (sp < 16) { stack[sp] = .{ .i64 = readCodeS64(expr, &pc) }; sp += 1; } },
            0x43 => {
                const bits = readCodeFixedU32(expr, pc);
                pc += 4;
                if (sp < 16) { stack[sp] = .{ .f32 = @bitCast(bits) }; sp += 1; }
            },
            0x44 => {
                const bits = readCodeFixedU64(expr, pc);
                pc += 8;
                if (sp < 16) { stack[sp] = .{ .f64 = @bitCast(bits) }; sp += 1; }
            },
            0x23 => { // global.get
                const idx = readCodeU32(expr, &pc);
                if (idx < instance.globals.items.len) {
                    if (sp < 16) { stack[sp] = instance.globals.items[idx]; sp += 1; }
                } else return null;
            },
            0xd0 => { pc += 1; if (sp < 16) { stack[sp] = .{ .ref_null = {} }; sp += 1; } },
            0xd2 => { if (sp < 16) { stack[sp] = .{ .ref_func = readCodeU32(expr, &pc) }; sp += 1; } },
            // Extended constant expressions: i32 arithmetic
            0x6a => { // i32.add
                if (sp < 2) return null;
                sp -= 1; const b = stack[sp].i32;
                sp -= 1; const a = stack[sp].i32;
                stack[sp] = .{ .i32 = a +% b }; sp += 1;
            },
            0x6b => { // i32.sub
                if (sp < 2) return null;
                sp -= 1; const b = stack[sp].i32;
                sp -= 1; const a = stack[sp].i32;
                stack[sp] = .{ .i32 = a -% b }; sp += 1;
            },
            0x6c => { // i32.mul
                if (sp < 2) return null;
                sp -= 1; const b = stack[sp].i32;
                sp -= 1; const a = stack[sp].i32;
                stack[sp] = .{ .i32 = a *% b }; sp += 1;
            },
            // Extended constant expressions: i64 arithmetic
            0x7c => { // i64.add
                if (sp < 2) return null;
                sp -= 1; const b = stack[sp].i64;
                sp -= 1; const a = stack[sp].i64;
                stack[sp] = .{ .i64 = a +% b }; sp += 1;
            },
            0x7d => { // i64.sub
                if (sp < 2) return null;
                sp -= 1; const b = stack[sp].i64;
                sp -= 1; const a = stack[sp].i64;
                stack[sp] = .{ .i64 = a -% b }; sp += 1;
            },
            0x7e => { // i64.mul
                if (sp < 2) return null;
                sp -= 1; const b = stack[sp].i64;
                sp -= 1; const a = stack[sp].i64;
                stack[sp] = .{ .i64 = a *% b }; sp += 1;
            },
            0x0b => { // end
                if (sp > 0) return stack[sp - 1];
                return null;
            },
            0xfb => { // GC prefix
                const gc_op = readCodeU32(expr, &pc);
                switch (gc_op) {
                    0x00 => { // struct.new
                        const type_idx = readCodeU32(expr, &pc);
                        if (instance.interp_ref) |interp| {
                            const field_count = interp.getStructFieldCount(type_idx);
                            if (sp >= field_count) {
                                var fields_buf: [64]Value = undefined;
                                var fi: u32 = field_count;
                                while (fi > 0) { fi -= 1; sp -= 1; fields_buf[fi] = stack[sp]; }
                                const obj_idx = interp.allocStruct(type_idx, fields_buf[0..field_count]) catch return null;
                                stack[sp] = .{ .ref_struct = obj_idx }; sp += 1;
                            }
                        } else return null;
                    },
                    0x01 => { // struct.new_default
                        const type_idx = readCodeU32(expr, &pc);
                        if (instance.interp_ref) |interp| {
                            const field_count = interp.getStructFieldCount(type_idx);
                            var fields_buf: [64]Value = undefined;
                            for (0..field_count) |fi| fields_buf[fi] = interp.getDefaultFieldValue(type_idx, @intCast(fi));
                            const obj_idx = interp.allocStruct(type_idx, fields_buf[0..field_count]) catch return null;
                            if (sp < 16) { stack[sp] = .{ .ref_struct = obj_idx }; sp += 1; }
                        } else return null;
                    },
                    0x06 => { // array.new
                        const type_idx = readCodeU32(expr, &pc);
                        if (sp >= 2) {
                            sp -= 1; const len: u32 = @bitCast(stack[sp].i32);
                            sp -= 1; const init_val = stack[sp];
                            if (instance.interp_ref) |interp| {
                                const obj_idx = interp.allocArray(type_idx, len, init_val) catch return null;
                                stack[sp] = .{ .ref_array = obj_idx }; sp += 1;
                            } else return null;
                        } else return null;
                    },
                    0x07 => { // array.new_default
                        const type_idx = readCodeU32(expr, &pc);
                        if (sp >= 1) {
                            sp -= 1; const len: u32 = @bitCast(stack[sp].i32);
                            if (instance.interp_ref) |interp| {
                                const default_val = interp.getDefaultFieldValue(type_idx, 0);
                                const obj_idx = interp.allocArray(type_idx, len, default_val) catch return null;
                                stack[sp] = .{ .ref_array = obj_idx }; sp += 1;
                            } else return null;
                        } else return null;
                    },
                    0x08 => { // array.new_fixed
                        const type_idx = readCodeU32(expr, &pc);
                        const count = readCodeU32(expr, &pc);
                        if (sp >= count and instance.interp_ref != null) {
                            const interp = instance.interp_ref.?;
                            var fields_buf: [256]Value = undefined;
                            var fi: u32 = count;
                            while (fi > 0) { fi -= 1; sp -= 1; fields_buf[fi] = stack[sp]; }
                            const idx: u32 = @intCast(interp.gc_objects.items.len);
                            var obj = GcObject{ .type_idx = type_idx, .fields = .{} };
                            obj.fields.appendSlice(interp.allocator, fields_buf[0..count]) catch return null;
                            interp.gc_objects.append(interp.allocator, obj) catch return null;
                            stack[sp] = .{ .ref_array = idx }; sp += 1;
                        } else return null;
                    },
                    0x1c => { // ref.i31
                        if (sp > 0) {
                            sp -= 1;
                            const val = stack[sp].i32;
                            stack[sp] = .{ .ref_i31 = @bitCast(val & 0x7fff_ffff) };
                            sp += 1;
                        }
                    },
                    else => return null,
                }
            },
            0xfd => { // SIMD prefix
                const simd_op = readCodeU32(expr, &pc);
                switch (simd_op) {
                    0x0c => { // v128.const
                        if (pc + 16 <= expr.len) {
                            var bytes: [16]u8 = undefined;
                            @memcpy(&bytes, expr[pc..][0..16]);
                            pc += 16;
                            if (sp < 16) { stack[sp] = .{ .v128 = @bitCast(bytes) }; sp += 1; }
                        } else return null;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }
    if (sp > 0) return stack[sp - 1];
    return null;
}

// ── Wasm-spec min/max helpers (NaN propagation) ─────────────────────────

fn wasmMinF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f32);
    if (a == 0.0 and b == 0.0) {
        // -0 < +0 in wasm
        return if (std.math.signbit(a)) a else b;
    }
    return @min(a, b);
}

fn wasmMaxF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f32);
    if (a == 0.0 and b == 0.0) {
        return if (std.math.signbit(a)) b else a;
    }
    return @max(a, b);
}

fn wasmMinF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    if (a == 0.0 and b == 0.0) {
        return if (std.math.signbit(a)) a else b;
    }
    return @min(a, b);
}

fn wasmMaxF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(f64);
    if (a == 0.0 and b == 0.0) {
        return if (std.math.signbit(a)) b else a;
    }
    return @max(a, b);
}

fn wasmNearestF32(a: f32) f32 {
    if (std.math.isNan(a)) return std.math.nan(f32);
    if (std.math.isInf(a)) return a;
    if (a == 0.0) return a;
    var rounded = @round(a);
    const diff = a - rounded;
    if (diff == 0.5 or diff == -0.5) {
        const r_int: i64 = @intFromFloat(rounded);
        if (@rem(r_int, 2) != 0) rounded = rounded - std.math.copysign(@as(f32, 1.0), a);
    }
    // Preserve negative zero: if result rounds to 0 but input was negative
    if (rounded == 0.0 and @as(u32, @bitCast(a)) & 0x80000000 != 0)
        return @bitCast(@as(u32, 0x80000000));
    return rounded;
}

fn wasmNearestF64(a: f64) f64 {
    if (std.math.isNan(a)) return std.math.nan(f64);
    if (std.math.isInf(a)) return a;
    if (a == 0.0) return a;
    var rounded = @round(a);
    const diff = a - rounded;
    if (diff == 0.5 or diff == -0.5) {
        const r_int: i64 = @intFromFloat(rounded);
        if (@rem(r_int, 2) != 0) rounded = rounded - std.math.copysign(@as(f64, 1.0), a);
    }
    // Preserve negative zero: if result rounds to 0 but input was negative
    if (rounded == 0.0 and @as(u64, @bitCast(a)) & 0x8000000000000000 != 0)
        return @bitCast(@as(u64, 0x8000000000000000));
    return rounded;
}

// ── Test helpers ─────────────────────────────────────────────────────────

fn testInterpreter() struct { interp: Interpreter, inst: *Instance, mod: *Mod.Module } {
    const alloc = std.testing.allocator;
    const mod = alloc.create(Mod.Module) catch @panic("OOM");
    mod.* = Mod.Module.init(alloc);
    const inst = alloc.create(Instance) catch @panic("OOM");
    inst.* = Instance{
        .allocator = alloc,
        .module = mod,
        .globals = .{},
        .tables = .{},
    };
    // Ensure at least one empty memory for getMemory(0) accessor
    inst.memories.resize(alloc, 1) catch @panic("OOM");
    inst.memories.items[0] = .{};
    // Ensure at least one empty table for table() accessor
    inst.tables.resize(alloc, 1) catch @panic("OOM");
    inst.tables.items[0] = .{};
    return .{
        .interp = Interpreter.init(alloc, inst),
        .inst = inst,
        .mod = mod,
    };
}

fn testInterpreterWithMemory(pages: usize) struct { interp: Interpreter, inst: *Instance, mod: *Mod.Module } {
    const alloc = std.testing.allocator;
    const mod = alloc.create(Mod.Module) catch @panic("OOM");
    mod.* = Mod.Module.init(alloc);

    // Add a memory definition to the module.
    mod.memories.append(alloc, .{
        .@"type" = .{ .limits = .{ .initial = @intCast(pages), .has_max = true, .max = 10 } },
    }) catch @panic("OOM");

    const inst = alloc.create(Instance) catch @panic("OOM");
    inst.* = Instance.init(alloc, mod) catch @panic("trap");
    return .{
        .interp = Interpreter.init(alloc, inst),
        .inst = inst,
        .mod = mod,
    };
}

fn cleanupTest(interp: *Interpreter, inst: *Instance, mod: *Mod.Module) void {
    const alloc = std.testing.allocator;
    interp.deinit();
    inst.deinit();
    alloc.destroy(inst);
    mod.deinit();
    alloc.destroy(mod);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "create interpreter" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    var inst = Instance.init(std.testing.allocator, &module) catch @panic("trap");
    defer inst.deinit();
    var interp = Interpreter.init(std.testing.allocator, &inst);
    defer interp.deinit();
}

test "i32 add" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = 10 });
    try ctx.interp.pushValue(.{ .i32 = 20 });
    try ctx.interp.i32Add();
    const r = try ctx.interp.popI32();
    try std.testing.expectEqual(@as(i32, 30), r);
}

test "i32 add wrapping" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = std.math.maxInt(i32) });
    try ctx.interp.pushValue(.{ .i32 = 1 });
    try ctx.interp.i32Add();
    const r = try ctx.interp.popI32();
    try std.testing.expectEqual(std.math.minInt(i32), r);
}

test "i32 sub" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = 30 });
    try ctx.interp.pushValue(.{ .i32 = 12 });
    try ctx.interp.i32Sub();
    try std.testing.expectEqual(@as(i32, 18), try ctx.interp.popI32());
}

test "i32 mul" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = 7 });
    try ctx.interp.pushValue(.{ .i32 = 6 });
    try ctx.interp.i32Mul();
    try std.testing.expectEqual(@as(i32, 42), try ctx.interp.popI32());
}

test "i32 div by zero traps" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = 10 });
    try ctx.interp.pushValue(.{ .i32 = 0 });
    try std.testing.expectError(error.IntegerDivisionByZero, ctx.interp.i32DivS());
}

test "i32 div overflow traps" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = std.math.minInt(i32) });
    try ctx.interp.pushValue(.{ .i32 = -1 });
    try std.testing.expectError(error.IntegerOverflow, ctx.interp.i32DivS());
}

test "i32 div_u" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = @bitCast(@as(u32, 0xFFFFFFFF)) }); // u32 max
    try ctx.interp.pushValue(.{ .i32 = 2 });
    try ctx.interp.i32DivU();
    const r: u32 = @bitCast(try ctx.interp.popI32());
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), r);
}

test "i32 rem_s minInt % -1 == 0" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i32 = std.math.minInt(i32) });
    try ctx.interp.pushValue(.{ .i32 = -1 });
    try ctx.interp.i32RemS();
    try std.testing.expectEqual(@as(i32, 0), try ctx.interp.popI32());
}

test "i32 comparison ops" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // eqz
    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.i32Eqz();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    try ctx.interp.pushValue(.{ .i32 = 42 });
    try ctx.interp.i32Eqz();
    try std.testing.expectEqual(@as(i32, 0), try ctx.interp.popI32());

    // eq
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.i32Eq();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // ne
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.pushValue(.{ .i32 = 6 });
    try ctx.interp.i32Ne();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // lt_s
    try ctx.interp.pushValue(.{ .i32 = -1 });
    try ctx.interp.pushValue(.{ .i32 = 1 });
    try ctx.interp.i32LtS();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // gt_s
    try ctx.interp.pushValue(.{ .i32 = 10 });
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.i32GtS();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // le_s
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.i32LeS();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // ge_s
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.pushValue(.{ .i32 = 5 });
    try ctx.interp.i32GeS();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());
}

test "i32 bitwise operations" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // and
    try ctx.interp.pushValue(.{ .i32 = 0xFF });
    try ctx.interp.pushValue(.{ .i32 = 0x0F });
    try ctx.interp.i32And();
    try std.testing.expectEqual(@as(i32, 0x0F), try ctx.interp.popI32());

    // or
    try ctx.interp.pushValue(.{ .i32 = 0xF0 });
    try ctx.interp.pushValue(.{ .i32 = 0x0F });
    try ctx.interp.i32Or();
    try std.testing.expectEqual(@as(i32, 0xFF), try ctx.interp.popI32());

    // xor
    try ctx.interp.pushValue(.{ .i32 = 0xFF });
    try ctx.interp.pushValue(.{ .i32 = 0x0F });
    try ctx.interp.i32Xor();
    try std.testing.expectEqual(@as(i32, 0xF0), try ctx.interp.popI32());

    // shl
    try ctx.interp.pushValue(.{ .i32 = 1 });
    try ctx.interp.pushValue(.{ .i32 = 4 });
    try ctx.interp.i32Shl();
    try std.testing.expectEqual(@as(i32, 16), try ctx.interp.popI32());

    // clz
    try ctx.interp.pushValue(.{ .i32 = 1 });
    try ctx.interp.i32Clz();
    try std.testing.expectEqual(@as(i32, 31), try ctx.interp.popI32());

    // ctz
    try ctx.interp.pushValue(.{ .i32 = 8 });
    try ctx.interp.i32Ctz();
    try std.testing.expectEqual(@as(i32, 3), try ctx.interp.popI32());

    // popcnt
    try ctx.interp.pushValue(.{ .i32 = 0xFF });
    try ctx.interp.i32Popcnt();
    try std.testing.expectEqual(@as(i32, 8), try ctx.interp.popI32());
}

test "i64 arithmetic" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .i64 = 100 });
    try ctx.interp.pushValue(.{ .i64 = 200 });
    try ctx.interp.i64Add();
    try std.testing.expectEqual(@as(i64, 300), try ctx.interp.popI64());

    try ctx.interp.pushValue(.{ .i64 = 500 });
    try ctx.interp.pushValue(.{ .i64 = 200 });
    try ctx.interp.i64Sub();
    try std.testing.expectEqual(@as(i64, 300), try ctx.interp.popI64());

    try ctx.interp.pushValue(.{ .i64 = 7 });
    try ctx.interp.pushValue(.{ .i64 = 6 });
    try ctx.interp.i64Mul();
    try std.testing.expectEqual(@as(i64, 42), try ctx.interp.popI64());

    try ctx.interp.pushValue(.{ .i64 = 100 });
    try ctx.interp.pushValue(.{ .i64 = 7 });
    try ctx.interp.i64DivS();
    try std.testing.expectEqual(@as(i64, 14), try ctx.interp.popI64());
}

test "i64 div by zero traps" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try ctx.interp.pushValue(.{ .i64 = 10 });
    try ctx.interp.pushValue(.{ .i64 = 0 });
    try std.testing.expectError(error.IntegerDivisionByZero, ctx.interp.i64DivS());
}

test "f32 arithmetic" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .f32 = 1.5 });
    try ctx.interp.pushValue(.{ .f32 = 2.5 });
    try ctx.interp.f32Add();
    try std.testing.expectEqual(@as(f32, 4.0), try ctx.interp.popF32());

    try ctx.interp.pushValue(.{ .f32 = 10.0 });
    try ctx.interp.pushValue(.{ .f32 = 3.0 });
    try ctx.interp.f32Sub();
    try std.testing.expectEqual(@as(f32, 7.0), try ctx.interp.popF32());

    try ctx.interp.pushValue(.{ .f32 = 3.0 });
    try ctx.interp.pushValue(.{ .f32 = 4.0 });
    try ctx.interp.f32Mul();
    try std.testing.expectEqual(@as(f32, 12.0), try ctx.interp.popF32());

    try ctx.interp.pushValue(.{ .f32 = -5.0 });
    try ctx.interp.f32Abs();
    try std.testing.expectEqual(@as(f32, 5.0), try ctx.interp.popF32());

    try ctx.interp.pushValue(.{ .f32 = 9.0 });
    try ctx.interp.f32Sqrt();
    try std.testing.expectEqual(@as(f32, 3.0), try ctx.interp.popF32());
}

test "f64 arithmetic" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .f64 = 1.5 });
    try ctx.interp.pushValue(.{ .f64 = 2.5 });
    try ctx.interp.f64Add();
    try std.testing.expectEqual(@as(f64, 4.0), try ctx.interp.popF64());

    try ctx.interp.pushValue(.{ .f64 = -7.0 });
    try ctx.interp.f64Neg();
    try std.testing.expectEqual(@as(f64, 7.0), try ctx.interp.popF64());

    try ctx.interp.pushValue(.{ .f64 = 2.7 });
    try ctx.interp.f64Floor();
    try std.testing.expectEqual(@as(f64, 2.0), try ctx.interp.popF64());

    try ctx.interp.pushValue(.{ .f64 = 2.3 });
    try ctx.interp.f64Ceil();
    try std.testing.expectEqual(@as(f64, 3.0), try ctx.interp.popF64());
}

test "conversions" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // i32.wrap_i64
    try ctx.interp.pushValue(.{ .i64 = 0x1_0000_0001 });
    try ctx.interp.i32WrapI64();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // i64.extend_i32_s
    try ctx.interp.pushValue(.{ .i32 = -1 });
    try ctx.interp.i64ExtendI32S();
    try std.testing.expectEqual(@as(i64, -1), try ctx.interp.popI64());

    // i64.extend_i32_u
    try ctx.interp.pushValue(.{ .i32 = -1 });
    try ctx.interp.i64ExtendI32U();
    try std.testing.expectEqual(@as(i64, 0xFFFFFFFF), try ctx.interp.popI64());

    // f64.promote_f32
    try ctx.interp.pushValue(.{ .f32 = 1.5 });
    try ctx.interp.f64PromoteF32();
    try std.testing.expectEqual(@as(f64, 1.5), try ctx.interp.popF64());

    // f32.convert_i32_s
    try ctx.interp.pushValue(.{ .i32 = 42 });
    try ctx.interp.f32ConvertI32S();
    try std.testing.expectEqual(@as(f32, 42.0), try ctx.interp.popF32());

    // i32.reinterpret_f32
    try ctx.interp.pushValue(.{ .f32 = 1.0 });
    try ctx.interp.i32ReinterpretF32();
    try std.testing.expectEqual(@as(i32, @bitCast(@as(f32, 1.0))), try ctx.interp.popI32());

    // f32.reinterpret_i32
    try ctx.interp.pushValue(.{ .i32 = @bitCast(@as(f32, 2.0)) });
    try ctx.interp.f32ReinterpretI32();
    try std.testing.expectEqual(@as(f32, 2.0), try ctx.interp.popF32());
}

test "memory load/store" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // Store 42 at address 0
    try ctx.interp.pushValue(.{ .i32 = 0 }); // base addr
    try ctx.interp.pushValue(.{ .i32 = 42 }); // value
    try ctx.interp.i32Store(0, 0);

    // Load it back
    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.i32Load(0, 0);
    try std.testing.expectEqual(@as(i32, 42), try ctx.interp.popI32());

    // Store at offset
    try ctx.interp.pushValue(.{ .i32 = 100 }); // base
    try ctx.interp.pushValue(.{ .i32 = 99 }); // value
    try ctx.interp.i32Store(0, 4);

    try ctx.interp.pushValue(.{ .i32 = 100 });
    try ctx.interp.i32Load(0, 4);
    try std.testing.expectEqual(@as(i32, 99), try ctx.interp.popI32());
}

test "memory load/store i64" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.pushValue(.{ .i64 = 0x123456789ABCDEF0 });
    try ctx.interp.i64Store(0, 0);

    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.i64Load(0, 0);
    try std.testing.expectEqual(@as(i64, 0x123456789ABCDEF0), try ctx.interp.popI64());
}

test "memory load/store f32" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .i32 = 16 });
    try ctx.interp.pushValue(.{ .f32 = 3.14 });
    try ctx.interp.f32Store(0, 0);

    try ctx.interp.pushValue(.{ .i32 = 16 });
    try ctx.interp.f32Load(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), try ctx.interp.popF32(), 0.001);
}

test "memory out of bounds" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // Try loading from beyond memory (1 page = 65536 bytes)
    try ctx.interp.pushValue(.{ .i32 = @as(i32, @intCast(page_size - 2)) });
    try std.testing.expectError(error.OutOfBoundsMemoryAccess, ctx.interp.i32Load(0, 0));
}

test "memory size and grow" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // memory.size should return 1
    try ctx.interp.memorySize(0);
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // Grow by 2 pages
    try ctx.interp.pushValue(.{ .i32 = 2 });
    try ctx.interp.memoryGrow(0);
    // Returns old size (1)
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // memory.size should return 3
    try ctx.interp.memorySize(0);
    try std.testing.expectEqual(@as(i32, 3), try ctx.interp.popI32());
}

test "stack underflow" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);
    try std.testing.expectError(error.StackOverflow, ctx.interp.popValue());
}

test "constants push values" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.i32Const(42);
    try std.testing.expectEqual(@as(i32, 42), try ctx.interp.popI32());

    try ctx.interp.i64Const(1_000_000);
    try std.testing.expectEqual(@as(i64, 1_000_000), try ctx.interp.popI64());

    try ctx.interp.f32Const(3.14);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), try ctx.interp.popF32(), 0.001);

    try ctx.interp.f64Const(2.718);
    try std.testing.expectApproxEqAbs(@as(f64, 2.718), try ctx.interp.popF64(), 0.001);
}

test "peek value" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .i32 = 99 });
    const v = try ctx.interp.peekValue();
    try std.testing.expectEqual(@as(i32, 99), v.i32);
    // Value should still be on the stack.
    try std.testing.expectEqual(@as(usize, 1), ctx.interp.stack.items.len);
}

test "i32 trunc f32 invalid conversion" {
    var ctx = testInterpreter();
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .f32 = std.math.nan(f32) });
    try std.testing.expectError(error.InvalidConversion, ctx.interp.i32TruncF32S());
}

test "Instance init with globals" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();

    try module.globals.append(alloc, .{ .@"type" = .{ .val_type = .i32 } });
    try module.globals.append(alloc, .{ .@"type" = .{ .val_type = .f64 } });

    var inst = Instance.init(alloc, &module) catch @panic("trap");
    defer inst.deinit();

    try std.testing.expectEqual(@as(usize, 2), inst.globals.items.len);
    try std.testing.expectEqual(@as(i32, 0), inst.globals.items[0].i32);
    try std.testing.expectEqual(@as(f64, 0.0), inst.globals.items[1].f64);
}

test "dispatch: i32.const + i32.add via callFunc" {
    const alloc = std.testing.allocator;
    const mod = alloc.create(Mod.Module) catch @panic("OOM");
    mod.* = Mod.Module.init(alloc);
    defer {
        mod.deinit();
        alloc.destroy(mod);
    }
    // Type: (func (param i32 i32) (result i32))
    const params = alloc.alloc(types.ValType, 2) catch @panic("OOM");
    params[0] = .i32;
    params[1] = .i32;
    const results = alloc.alloc(types.ValType, 1) catch @panic("OOM");
    results[0] = .i32;
    try mod.module_types.append(alloc, .{ .func_type = .{ .params = params, .results = results } });
    // Bytecode: local.get 0, local.get 1, i32.add, end
    const code = &[_]u8{ 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b };
    try mod.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = code,
    });
    var inst = Instance.init(alloc, mod) catch @panic("trap");
    defer inst.deinit();
    var interp = Interpreter.init(alloc, &inst);
    defer interp.deinit();
    try interp.callFunc(0, &[_]Value{ .{ .i32 = 3 }, .{ .i32 = 4 } });
    try std.testing.expectEqual(@as(i32, 7), interp.stack.items[interp.stack.items.len - 1].i32);
}

test "dispatch: block with br" {
    const alloc = std.testing.allocator;
    const mod = alloc.create(Mod.Module) catch @panic("OOM");
    mod.* = Mod.Module.init(alloc);
    defer {
        mod.deinit();
        alloc.destroy(mod);
    }
    const results = alloc.alloc(types.ValType, 1) catch @panic("OOM");
    results[0] = .i32;
    const params = alloc.alloc(types.ValType, 1) catch @panic("OOM");
    params[0] = .i32;
    try mod.module_types.append(alloc, .{ .func_type = .{ .params = params, .results = results } });
    // Bytecode: block (result i32) local.get 0 br 0 end end
    const code = &[_]u8{ 0x02, 0x7f, 0x20, 0x00, 0x0c, 0x00, 0x0b, 0x0b };
    try mod.funcs.append(alloc, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = code,
    });
    var inst = Instance.init(alloc, mod) catch @panic("trap");
    defer inst.deinit();
    var interp = Interpreter.init(alloc, &inst);
    defer interp.deinit();
    try interp.callFunc(0, &[_]Value{.{ .i32 = 99 }});
    try std.testing.expectEqual(@as(i32, 99), interp.stack.items[interp.stack.items.len - 1].i32);
}

