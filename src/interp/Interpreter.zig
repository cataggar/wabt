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
    StackOverflow,
    CallStackExhausted,
    OutOfMemory,
    Unimplemented,
    InstructionLimitExceeded,
};

// ── Value ────────────────────────────────────────────────────────────────

/// Runtime value that mirrors the core WebAssembly value types.
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    ref_null: void,
    ref_func: u32,
};

// ── Instance ─────────────────────────────────────────────────────────────

/// Runtime module instance — holds mutable state (memory, globals, tables).
pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const Mod.Module,

    /// Linear memory (one page = 65 536 bytes).
    memory: std.ArrayListUnmanaged(u8),

    /// Global variable values.
    globals: std.ArrayListUnmanaged(Value),

    /// Function tables — `null` entries are uninitialised.
    /// tables[0] is the default table; additional tables for multi-table proposals.
    tables: std.ArrayListUnmanaged(std.ArrayListUnmanaged(?u32)),

    /// Tracks which data segments have been dropped via data.drop.
    dropped_data: std.DynamicBitSetUnmanaged = .{},
    /// Tracks which element segments have been dropped via elem.drop.
    dropped_elems: std.DynamicBitSetUnmanaged = .{},

    /// Shorthand to access the default (index 0) table.
    pub fn table(self: *Instance) *std.ArrayListUnmanaged(?u32) {
        return &self.tables.items[0];
    }

    /// Access a table by index, falling back to index 0.
    pub fn getTable(self: *Instance, idx: u32) *std.ArrayListUnmanaged(?u32) {
        if (idx < self.tables.items.len) return &self.tables.items[idx];
        return &self.tables.items[0];
    }

    pub fn init(allocator: std.mem.Allocator, module: *const Mod.Module) TrapError!Instance {
        var inst = Instance{
            .allocator = allocator,
            .module = module,
            .memory = .{},
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

        // Allocate linear memory for first memory definition.
        if (module.memories.items.len > 0) {
            const mem = module.memories.items[0];
            const initial_pages: usize = @intCast(mem.@"type".limits.initial);
            const byte_count = initial_pages * @as(usize, page_size);
            inst.memory.resize(allocator, byte_count) catch return error.OutOfMemory;
            @memset(inst.memory.items, 0);
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

        // Initialise all tables.
        if (module.tables.items.len > 0) {
            inst.tables.resize(allocator, module.tables.items.len) catch return error.OutOfMemory;
            for (module.tables.items, 0..) |tbl, i| {
                inst.tables.items[i] = .{};
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
        self.memory.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        for (self.tables.items) |*t| t.deinit(self.allocator);
        self.tables.deinit(self.allocator);
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

        // Copy active data segments into memory
        for (self.module.data_segments.items) |seg| {
            if (seg.kind != .active or seg.data.len == 0) continue;
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
            if (offset + seg.data.len <= self.memory.items.len) {
                @memcpy(self.memory.items[offset .. offset + seg.data.len], seg.data);
            }
        }

        // Populate tables from active element segments
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
                        else => 0,
                    };
                }
            }
            for (seg.elem_var_indices.items, 0..) |var_, j| {
                const table_entry = offset + j;
                if (table_entry < tbl.items.len) {
                    switch (var_) {
                        .index => |idx| tbl.items[table_entry] = idx,
                        .name => {},
                    }
                }
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
    /// Instruction counter for execution limit.
    instruction_count: u64 = 0,
    /// Maximum instructions before trap (prevents infinite loops).
    max_instructions: u64 = 10_000_000,

    /// Resolved function import links (indexed by func_idx for imported funcs).
    import_links: std.ArrayListUnmanaged(?ImportLink) = .{},

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
    }

    /// Call an exported function by name.
    pub fn callExport(self: *Interpreter, name: []const u8, args: []const Value) TrapError!?Value {
        const exp = self.instance.module.getExport(name) orelse return error.UndefinedElement;
        if (exp.kind != .func) return error.UndefinedElement;
        const idx: u32 = switch (exp.var_) {
            .index => |i| i,
            .name => return error.Unimplemented,
        };
        self.instruction_count = 0;
        const stack_base = self.stack.items.len;
        const result = try self.callFunc(idx, args);
        // Clean up any stale values left on the stack from multi-return or leaky calls
        self.stack.shrinkRetainingCapacity(stack_base);
        return result;
    }

    /// Call a function by index.
    pub fn callFunc(self: *Interpreter, func_idx: u32, args: []const Value) TrapError!?Value {
        if (self.call_depth >= self.max_call_depth) return error.CallStackExhausted;
        if (func_idx >= self.instance.module.funcs.items.len) return error.UndefinedElement;

        self.call_depth += 1;
        defer self.call_depth -= 1;

        const func = self.instance.module.funcs.items[func_idx];
        if (func.is_import) {
            // Resolve via import links
            if (func_idx < self.import_links.items.len) {
                if (self.import_links.items[func_idx]) |link| {
                    return link.interpreter.callFunc(link.func_idx, args);
                }
            }
            return error.Unimplemented;
        }

        const code = func.code_bytes;
        if (code.len == 0) return null;

        // DBG: dump code bytes for all functions at depth 1
        if (self.call_depth == 1 and code.len <= 20) {
            std.debug.print("  DBG func[{d}] code({d}):", .{ func_idx, code.len });
            for (code) |b| std.debug.print(" {x:0>2}", .{b});
            std.debug.print("\n", .{});
        }

        // Resolve function signature
        const sig = self.resolveSig(func.decl);

        // Initialize locals: params + declared locals
        const num_locals = sig.params.len + func.local_types.items.len;
        var locals = self.allocator.alloc(Value, num_locals) catch return error.OutOfMemory;
        defer self.allocator.free(locals);
        // Copy arguments into parameter slots
        for (args, 0..) |arg, i| {
            if (i < locals.len) locals[i] = arg;
        }
        // Zero-initialize declared locals
        for (sig.params.len..num_locals) |i| {
            if (i < func.local_types.items.len + sig.params.len) {
                const lt = func.local_types.items[i - sig.params.len];
                locals[i] = switch (lt) {
                    .i64 => .{ .i64 = 0 },
                    .f32 => .{ .f32 = 0.0 },
                    .f64 => .{ .f64 = 0.0 },
                    else => .{ .i32 = 0 },
                };
            }
        }

        // Save and restore control flow state across calls
        const saved_branch = self.branch_depth;
        const saved_returning = self.returning;
        self.branch_depth = null;
        self.returning = false;
        defer {
            self.branch_depth = saved_branch;
            self.returning = saved_returning;
        }

        // Record stack depth before execution
        const stack_base = self.stack.items.len;

        // Execute bytecode
        _ = try self.dispatch(code, 0, locals);

        // Return value
        if (sig.results.len > 0 and self.stack.items.len > stack_base) {
            return self.popValue() catch null;
        }
        return null;
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
            a < @as(f64, @floatFromInt(@as(i64, std.math.minInt(i32)))))
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

    pub fn i32Load(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i32, self.instance.memory.items[idx..][0..4], .little);
        try self.pushValue(.{ .i32 = val });
    }

    pub fn i32Store(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI32();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(i32, self.instance.memory.items[idx..][0..4], val, .little);
    }

    pub fn i64Load(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 8 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i64, self.instance.memory.items[idx..][0..8], .little);
        try self.pushValue(.{ .i64 = val });
    }

    pub fn i64Store(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI64();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 8 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(i64, self.instance.memory.items[idx..][0..8], val, .little);
    }

    pub fn f32Load(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits = std.mem.readInt(u32, self.instance.memory.items[idx..][0..4], .little);
        try self.pushValue(.{ .f32 = @bitCast(bits) });
    }

    pub fn f32Store(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popF32();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits: u32 = @bitCast(val);
        std.mem.writeInt(u32, self.instance.memory.items[idx..][0..4], bits, .little);
    }

    pub fn f64Load(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 8 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits = std.mem.readInt(u64, self.instance.memory.items[idx..][0..8], .little);
        try self.pushValue(.{ .f64 = @bitCast(bits) });
    }

    pub fn f64Store(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popF64();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 8 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const bits: u64 = @bitCast(val);
        std.mem.writeInt(u64, self.instance.memory.items[idx..][0..8], bits, .little);
    }

    pub fn memorySize(self: *Interpreter) TrapError!void {
        const pages: i32 = @intCast(self.instance.memory.items.len / page_size);
        try self.pushValue(.{ .i32 = pages });
    }

    pub fn memoryGrow(self: *Interpreter) TrapError!void {
        const delta = try self.popI32();
        if (delta < 0) {
            try self.pushValue(.{ .i32 = -1 });
            return;
        }
        const old_pages: u32 = @intCast(self.instance.memory.items.len / page_size);
        const new_pages: u64 = @as(u64, old_pages) + @as(u64, @as(u32, @bitCast(delta)));

        // Wasm spec: max 65536 pages (4GB)
        if (new_pages > 65536) {
            try self.pushValue(.{ .i32 = -1 });
            return;
        }

        // Apply max limit from the module definition if present.
        if (self.instance.module.memories.items.len > 0) {
            const mem = self.instance.module.memories.items[0];
            if (mem.@"type".limits.has_max) {
                if (new_pages > mem.@"type".limits.max) {
                    try self.pushValue(.{ .i32 = -1 });
                    return;
                }
            }
        }

        const new_len = @as(usize, @intCast(new_pages)) * page_size;
        self.instance.memory.resize(self.allocator, new_len) catch {
            try self.pushValue(.{ .i32 = -1 });
            return;
        };
        // Zero-initialise newly grown pages.
        const old_len = @as(usize, old_pages) * page_size;
        @memset(self.instance.memory.items[old_len..], 0);
        try self.pushValue(.{ .i32 = @bitCast(old_pages) });
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
        if (a >= @as(f32, @floatFromInt(@as(i64, std.math.maxInt(u32)) + 1)) or a < 0.0)
            return error.IntegerOverflow;
        const u: u32 = @intFromFloat(a);
        try self.pushValue(.{ .i32 = @bitCast(u) });
    }

    pub fn i32TruncF64U(self: *Interpreter) TrapError!void {
        const a = try self.popF64();
        if (std.math.isNan(a)) return error.InvalidConversion;
        if (a >= @as(f64, @floatFromInt(@as(i64, std.math.maxInt(u32)) + 1)) or a < 0.0)
            return error.IntegerOverflow;
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
        if (a >= max_f or a < 0.0) return error.IntegerOverflow;
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
        if (a >= max_f or a < 0.0) return error.IntegerOverflow;
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

    pub fn memoryCopy(self: *Interpreter) TrapError!void {
        const n_val = try self.popI32();
        const src_val = try self.popI32();
        const dst_val = try self.popI32();
        const n: u32 = @bitCast(n_val);
        const src: u32 = @bitCast(src_val);
        const dst: u32 = @bitCast(dst_val);
        const mem = self.instance.memory.items;
        if (@as(u64, src) + n > mem.len or @as(u64, dst) + n > mem.len)
            return error.OutOfBoundsMemoryAccess;
        if (n == 0) return;
        const s: usize = @intCast(src);
        const d: usize = @intCast(dst);
        const len: usize = @intCast(n);
        if (d <= s) {
            std.mem.copyForwards(u8, mem[d .. d + len], mem[s .. s + len]);
        } else {
            std.mem.copyBackwards(u8, mem[d .. d + len], mem[s .. s + len]);
        }
    }

    pub fn memoryFill(self: *Interpreter) TrapError!void {
        const n_val = try self.popI32();
        const val = try self.popI32();
        const dst_val = try self.popI32();
        const n: u32 = @bitCast(n_val);
        const dst: u32 = @bitCast(dst_val);
        const mem = self.instance.memory.items;
        if (@as(u64, dst) + n > mem.len)
            return error.OutOfBoundsMemoryAccess;
        if (n == 0) return;
        const d: usize = @intCast(dst);
        const len: usize = @intCast(n);
        @memset(mem[d .. d + len], @truncate(@as(u32, @bitCast(val))));
    }

    pub fn memoryInit(self: *Interpreter, data_idx: u32) TrapError!void {
        const n_val = try self.popI32();
        const src_val = try self.popI32();
        const dst_val = try self.popI32();
        const n: u32 = @bitCast(n_val);
        const src: u32 = @bitCast(src_val);
        const dst: u32 = @bitCast(dst_val);
        if (data_idx >= self.instance.module.data_segments.items.len)
            return error.OutOfBoundsMemoryAccess;
        const dropped = data_idx < self.instance.dropped_data.capacity() and
            self.instance.dropped_data.isSet(data_idx);
        const seg = self.instance.module.data_segments.items[data_idx];
        const seg_len: u32 = if (dropped) 0 else @intCast(seg.data.len);
        if (@as(u64, src) + n > seg_len or
            @as(u64, dst) + n > self.instance.memory.items.len)
            return error.OutOfBoundsMemoryAccess;
        if (n == 0) return;
        const s: usize = @intCast(src);
        const d: usize = @intCast(dst);
        const len: usize = @intCast(n);
        @memcpy(self.instance.memory.items[d .. d + len], seg.data[s .. s + len]);
    }

    pub fn tableCopy(self: *Interpreter, dst_tbl_idx: u32, src_tbl_idx: u32) TrapError!void {
        const n_val = try self.popI32();
        const src_val = try self.popI32();
        const dst_val = try self.popI32();
        const n: u32 = @bitCast(n_val);
        const src: u32 = @bitCast(src_val);
        const dst: u32 = @bitCast(dst_val);
        const dst_tbl = self.instance.getTable(dst_tbl_idx);
        const src_tbl = self.instance.getTable(src_tbl_idx);
        if (@as(u64, dst) + n > dst_tbl.items.len or @as(u64, src) + n > src_tbl.items.len)
            return error.OutOfBoundsTableAccess;
        if (n == 0) return;
        const d: usize = @intCast(dst);
        const s: usize = @intCast(src);
        const len: usize = @intCast(n);
        if (dst_tbl_idx == src_tbl_idx) {
            // Same table: handle overlap
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
            // Different tables: no overlap possible
            var i: usize = 0;
            while (i < len) : (i += 1) dst_tbl.items[d + i] = src_tbl.items[s + i];
        }
    }

    pub fn tableInit(self: *Interpreter, elem_idx: u32, tbl_idx: u32) TrapError!void {
        const n_val = try self.popI32();
        const src_val = try self.popI32();
        const dst_val = try self.popI32();
        const n: u32 = @bitCast(n_val);
        const src: u32 = @bitCast(src_val);
        const dst: u32 = @bitCast(dst_val);
        if (elem_idx >= self.instance.module.elem_segments.items.len)
            return error.OutOfBoundsTableAccess;
        const dropped = elem_idx < self.instance.dropped_elems.capacity() and
            self.instance.dropped_elems.isSet(elem_idx);
        const seg = &self.instance.module.elem_segments.items[elem_idx];
        const seg_len: u32 = if (dropped) 0 else @intCast(seg.elem_var_indices.items.len);
        const tbl = self.instance.getTable(tbl_idx);
        if (@as(u64, src) + n > seg_len or
            @as(u64, dst) + n > tbl.items.len)
            return error.OutOfBoundsTableAccess;
        if (n == 0) return;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const func_idx = seg.elem_var_indices.items[src + i].index;
            tbl.items[dst + i] = func_idx;
        }
    }

    pub fn tableGrow(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        const tbl_idx = readCodeU32(code, pc);
        const delta = @as(u32, @bitCast(try self.popI32()));
        const init_val = try self.popValue();
        const tbl = self.instance.getTable(tbl_idx);
        const old_size: u32 = @intCast(tbl.items.len);
        const func_ref: ?u32 = switch (init_val) {
            .ref_func => |idx| idx,
            .ref_null => null,
            .i32 => |v| @bitCast(v),
            else => null,
        };
        if (delta == 0) {
            try self.pushValue(.{ .i32 = @bitCast(old_size) });
            return;
        }
        tbl.appendNTimes(self.allocator, func_ref, delta) catch {
            try self.pushValue(.{ .i32 = -1 });
            return;
        };
        try self.pushValue(.{ .i32 = @bitCast(old_size) });
    }

    pub fn tableSize(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        const tbl_idx = readCodeU32(code, pc);
        const tbl = self.instance.getTable(tbl_idx);
        try self.pushValue(.{ .i32 = @intCast(tbl.items.len) });
    }

    pub fn tableFill(self: *Interpreter, code: []const u8, pc: *usize) TrapError!void {
        const tbl_idx = readCodeU32(code, pc);
        const n = @as(u32, @bitCast(try self.popI32()));
        const val = try self.popValue();
        const dst = @as(u32, @bitCast(try self.popI32()));
        const tbl = self.instance.getTable(tbl_idx);
        if (@as(u64, dst) + n > tbl.items.len)
            return error.OutOfBoundsTableAccess;
        const func_ref: ?u32 = switch (val) {
            .ref_func => |idx| idx,
            .ref_null => null,
            .i32 => |v| @bitCast(v),
            else => null,
        };
        var i: u32 = 0;
        while (i < n) : (i += 1) tbl.items[dst + i] = func_ref;
    }

    // ── Sub-word memory loads ───────────────────────────────────────────

    pub fn i32Load8S(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 1 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const val: i8 = @bitCast(self.instance.memory.items[@intCast(addr)]);
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i32Load8U(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 1 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const val = self.instance.memory.items[@intCast(addr)];
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i32Load16S(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 2 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i16, self.instance.memory.items[idx..][0..2], .little);
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i32Load16U(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 2 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(u16, self.instance.memory.items[idx..][0..2], .little);
        try self.pushValue(.{ .i32 = @as(i32, val) });
    }

    pub fn i64Load8S(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 1 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const val: i8 = @bitCast(self.instance.memory.items[@intCast(addr)]);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load8U(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 1 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const val = self.instance.memory.items[@intCast(addr)];
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load16S(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 2 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i16, self.instance.memory.items[idx..][0..2], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load16U(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 2 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(u16, self.instance.memory.items[idx..][0..2], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load32S(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(i32, self.instance.memory.items[idx..][0..4], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    pub fn i64Load32U(self: *Interpreter, offset: u32) TrapError!void {
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        const val = std.mem.readInt(u32, self.instance.memory.items[idx..][0..4], .little);
        try self.pushValue(.{ .i64 = @as(i64, val) });
    }

    // ── Sub-word memory stores ──────────────────────────────────────────

    pub fn i32Store8(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI32();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 1 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        self.instance.memory.items[@intCast(addr)] = @truncate(@as(u32, @bitCast(val)));
    }

    pub fn i32Store16(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI32();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 2 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(u16, self.instance.memory.items[idx..][0..2], @truncate(@as(u32, @bitCast(val))), .little);
    }

    pub fn i64Store8(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI64();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 1 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        self.instance.memory.items[@intCast(addr)] = @truncate(@as(u64, @bitCast(val)));
    }

    pub fn i64Store16(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI64();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 2 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(u16, self.instance.memory.items[idx..][0..2], @truncate(@as(u64, @bitCast(val))), .little);
    }

    pub fn i64Store32(self: *Interpreter, offset: u32) TrapError!void {
        const val = try self.popI64();
        const base = try self.popI32();
        const addr = @as(u64, @as(u32, @bitCast(base))) + offset;
        if (addr + 4 > self.instance.memory.items.len) return error.OutOfBoundsMemoryAccess;
        const idx: usize = @intCast(addr);
        std.mem.writeInt(u32, self.instance.memory.items[idx..][0..4], @truncate(@as(u64, @bitCast(val))), .little);
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
                0x02 => { // block
                    const body_start = skipBlockType(code, pc);
                    pc = try self.dispatch(code, body_start, locals);
                    if (self.returning) return pc;
                    if (self.branch_depth) |d| {
                        if (d == 0) {
                            self.branch_depth = null;
                            // Scan from body start to correctly skip nested structures
                            pc = scanToEnd(code, body_start);
                        } else {
                            self.branch_depth = d - 1;
                            return pc;
                        }
                    }
                },
                0x03 => { // loop
                    const body_start = skipBlockType(code, pc);
                    pc = body_start;
                    while (true) {
                        pc = try self.dispatch(code, body_start, locals);
                        if (self.returning) return pc;
                        if (self.branch_depth) |d| {
                            if (d == 0) {
                                self.branch_depth = null;
                                continue; // restart loop
                            } else {
                                self.branch_depth = d - 1;
                                // Scan from body start to find loop's end
                                pc = scanToEnd(code, body_start);
                                return pc;
                            }
                        }
                        break;
                    }
                },
                0x04 => { // if
                    const body_start = skipBlockType(code, pc);
                    const cond = try self.popI32();
                    if (cond != 0) {
                        pc = try self.dispatch(code, body_start, locals);
                        if (self.returning) return pc;
                        if (self.branch_depth) |d| {
                            if (d == 0) {
                                self.branch_depth = null;
                                pc = scanToEnd(code, body_start);
                            } else {
                                self.branch_depth = d - 1;
                                return pc;
                            }
                        } else {
                            // Normal end — check if we stopped at else (need to skip else body)
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
                            if (self.returning) return pc;
                            if (self.branch_depth) |d| {
                                if (d == 0) {
                                    self.branch_depth = null;
                                    pc = scanToEnd(code, else_start);
                                } else {
                                    self.branch_depth = d - 1;
                                    return pc;
                                }
                            }
                        }
                    }
                },
                0x05 => return pc, // else — end of true branch
                0x0b => return pc, // end
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
                    const result = try self.callFunc(idx, call_args);
                    if (result) |v| try self.pushValue(v);
                },
                0x11 => { // call_indirect
                    var tmp_pc = pc;
                    const type_idx = readCodeU32(code, &tmp_pc);
                    const ci_tbl_idx = readCodeU32(code, &tmp_pc);
                    pc = tmp_pc;
                    const elem_idx = try self.popI32();
                    const uidx: u32 = @bitCast(elem_idx);
                    const ci_tbl = self.instance.getTable(ci_tbl_idx);
                    if (uidx >= ci_tbl.items.len) return error.OutOfBoundsTableAccess;
                    const func_idx = ci_tbl.items[uidx] orelse return error.UninitializedElement;
                    if (func_idx >= self.instance.module.funcs.items.len) return error.UndefinedElement;
                    const target = self.instance.module.funcs.items[func_idx];
                    const func_sig = self.resolveSig(target.decl);
                    // Verify type matches the expected signature (structural)
                    if (type_idx < self.instance.module.module_types.items.len) {
                        switch (self.instance.module.module_types.items[type_idx]) {
                            .func_type => |expected| {
                                const params_match = std.mem.eql(types.ValType, func_sig.params, expected.params);
                                const results_match = std.mem.eql(types.ValType, func_sig.results, expected.results);
                                if (!params_match or !results_match) {
                                    return error.IndirectCallTypeMismatch;
                                }
                            },
                            else => {},
                        }
                    }
                    var call_args = self.allocator.alloc(Value, func_sig.params.len) catch return error.OutOfMemory;
                    defer self.allocator.free(call_args);
                    var i = func_sig.params.len;
                    while (i > 0) {
                        i -= 1;
                        call_args[i] = try self.popValue();
                    }
                    const result = try self.callFunc(func_idx, call_args);
                    if (result) |v| try self.pushValue(v);
                },
                0x1a => _ = try self.popValue(), // drop
                0x1b => try self.selectOp(), // select
                0x20 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; try self.pushValue(locals[idx]); },
                0x21 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; locals[idx] = try self.popValue(); },
                0x22 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; const v = try self.popValue(); locals[idx] = v; try self.pushValue(v); },
                0x23 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; try self.pushValue(self.instance.globals.items[idx]); },
                0x24 => { var t = pc; const idx = readCodeU32(code, &t); pc = t; self.instance.globals.items[idx] = try self.popValue(); },
                0x25 => { // table.get
                    var t = pc;
                    const tg_idx = readCodeU32(code, &t);
                    pc = t;
                    const idx = @as(u32, @bitCast(try self.popI32()));
                    const tg_tbl = self.instance.getTable(tg_idx);
                    if (idx >= tg_tbl.items.len) return error.OutOfBoundsTableAccess;
                    if (tg_tbl.items[idx]) |func_idx|
                        try self.pushValue(.{ .ref_func = func_idx })
                    else
                        try self.pushValue(.{ .ref_null = {} });
                },
                0x26 => { // table.set
                    var t = pc;
                    const ts_idx = readCodeU32(code, &t);
                    pc = t;
                    const val = try self.popValue();
                    const idx = @as(u32, @bitCast(try self.popI32()));
                    const ts_tbl = self.instance.getTable(ts_idx);
                    if (idx >= ts_tbl.items.len) return error.OutOfBoundsTableAccess;
                    ts_tbl.items[idx] = switch (val) {
                        .ref_func => |fi| fi,
                        .ref_null => null,
                        .i32 => |v| @bitCast(v),
                        else => null,
                    };
                },
                // Memory load
                0x28 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Load(o); },
                0x29 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load(o); },
                0x2a => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.f32Load(o); },
                0x2b => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.f64Load(o); },
                0x2c => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Load8S(o); },
                0x2d => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Load8U(o); },
                0x2e => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Load16S(o); },
                0x2f => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Load16U(o); },
                0x30 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load8S(o); },
                0x31 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load8U(o); },
                0x32 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load16S(o); },
                0x33 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load16U(o); },
                0x34 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load32S(o); },
                0x35 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Load32U(o); },
                // Memory store
                0x36 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Store(o); },
                0x37 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Store(o); },
                0x38 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.f32Store(o); },
                0x39 => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.f64Store(o); },
                0x3a => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Store8(o); },
                0x3b => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i32Store16(o); },
                0x3c => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Store8(o); },
                0x3d => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Store16(o); },
                0x3e => { var t = pc; _ = readCodeU32(code, &t); const o = readCodeU32(code, &t); pc = t; try self.i64Store32(o); },
                0x3f => { var t = pc; _ = readCodeU32(code, &t); pc = t; try self.memorySize(); },
                0x40 => { var t = pc; _ = readCodeU32(code, &t); pc = t; try self.memoryGrow(); },
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
                            _ = readCodeU32(code, &pc); // mem idx
                            try self.memoryInit(data_idx);
                        },
                        0x09 => { // data.drop
                            const data_idx = readCodeU32(code, &pc);
                            if (data_idx < self.instance.dropped_data.capacity())
                                self.instance.dropped_data.set(data_idx);
                        },
                        0x0a => { // memory.copy
                            _ = readCodeU32(code, &pc); // dst mem
                            _ = readCodeU32(code, &pc); // src mem
                            try self.memoryCopy();
                        },
                        0x0b => { // memory.fill
                            _ = readCodeU32(code, &pc); // mem idx
                            try self.memoryFill();
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
                else => return error.Unimplemented,
            }
        }
        return pc;
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
    if (byte == 0x40 or (byte >= 0x7b and byte <= 0x7f) or byte == 0x70 or byte == 0x6f) {
        return pc + 1;
    }
    // Otherwise it's a signed LEB128 type index
    var tmp = pc;
    _ = readCodeS32(code, &tmp);
    return tmp;
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
        0x0c, 0x0d => _ = readCodeU32(code, &p), // br, br_if
        0x0e => { // br_table
            const count = readCodeU32(code, &p);
            for (0..count + 1) |_| _ = readCodeU32(code, &p);
        },
        0x10 => _ = readCodeU32(code, &p), // call
        0x11 => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); }, // call_indirect
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
        0xfc => {
            const sub = readCodeU32(code, &p);
            switch (sub) {
                0x08, 0x0a, 0x0c, 0x0e => { _ = readCodeU32(code, &p); _ = readCodeU32(code, &p); },
                0x09, 0x0b, 0x0d, 0x0f, 0x10, 0x11 => _ = readCodeU32(code, &p),
                else => {},
            }
        },
        else => {},
    }
    return p;
}

/// Evaluate a simple constant expression (used for global init and segment offsets).
fn evalConstExpr(instance: *const Instance, expr: []const u8) ?Value {
    var pc: usize = 0;
    while (pc < expr.len) {
        const op = expr[pc];
        pc += 1;
        switch (op) {
            0x41 => return .{ .i32 = readCodeS32(expr, &pc) },
            0x42 => return .{ .i64 = readCodeS64(expr, &pc) },
            0x43 => {
                const bits = readCodeFixedU32(expr, pc);
                return .{ .f32 = @bitCast(bits) };
            },
            0x44 => {
                const bits = readCodeFixedU64(expr, pc);
                return .{ .f64 = @bitCast(bits) };
            },
            0x23 => { // global.get
                const idx = readCodeU32(expr, &pc);
                if (idx < instance.globals.items.len) return instance.globals.items[idx];
                return null;
            },
            0xd0 => { pc += 1; return .{ .ref_null = {} }; },
            0xd2 => return .{ .ref_func = readCodeU32(expr, &pc) },
            0x0b => return null,
            else => return null,
        }
    }
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
    if (std.math.isNan(a) or std.math.isInf(a)) return a;
    if (a == 0.0) return a;
    const rounded = @round(a);
    const diff = a - rounded;
    if (diff == 0.5 or diff == -0.5) {
        const r_int: i64 = @intFromFloat(rounded);
        if (@rem(r_int, 2) != 0) return rounded - std.math.copysign(@as(f32, 1.0), a);
    }
    return rounded;
}

fn wasmNearestF64(a: f64) f64 {
    if (std.math.isNan(a) or std.math.isInf(a)) return a;
    if (a == 0.0) return a;
    const rounded = @round(a);
    const diff = a - rounded;
    if (diff == 0.5 or diff == -0.5) {
        const r_int: i64 = @intFromFloat(rounded);
        if (@rem(r_int, 2) != 0) return rounded - std.math.copysign(@as(f64, 1.0), a);
    }
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
        .memory = .{},
        .globals = .{},
        .tables = .{},
    };
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
    try ctx.interp.i32Store(0);

    // Load it back
    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.i32Load(0);
    try std.testing.expectEqual(@as(i32, 42), try ctx.interp.popI32());

    // Store at offset
    try ctx.interp.pushValue(.{ .i32 = 100 }); // base
    try ctx.interp.pushValue(.{ .i32 = 99 }); // value
    try ctx.interp.i32Store(4);

    try ctx.interp.pushValue(.{ .i32 = 100 });
    try ctx.interp.i32Load(4);
    try std.testing.expectEqual(@as(i32, 99), try ctx.interp.popI32());
}

test "memory load/store i64" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.pushValue(.{ .i64 = 0x123456789ABCDEF0 });
    try ctx.interp.i64Store(0);

    try ctx.interp.pushValue(.{ .i32 = 0 });
    try ctx.interp.i64Load(0);
    try std.testing.expectEqual(@as(i64, 0x123456789ABCDEF0), try ctx.interp.popI64());
}

test "memory load/store f32" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    try ctx.interp.pushValue(.{ .i32 = 16 });
    try ctx.interp.pushValue(.{ .f32 = 3.14 });
    try ctx.interp.f32Store(0);

    try ctx.interp.pushValue(.{ .i32 = 16 });
    try ctx.interp.f32Load(0);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), try ctx.interp.popF32(), 0.001);
}

test "memory out of bounds" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // Try loading from beyond memory (1 page = 65536 bytes)
    try ctx.interp.pushValue(.{ .i32 = @as(i32, @intCast(page_size - 2)) });
    try std.testing.expectError(error.OutOfBoundsMemoryAccess, ctx.interp.i32Load(0));
}

test "memory size and grow" {
    var ctx = testInterpreterWithMemory(1);
    defer cleanupTest(&ctx.interp, ctx.inst, ctx.mod);

    // memory.size should return 1
    try ctx.interp.memorySize();
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // Grow by 2 pages
    try ctx.interp.pushValue(.{ .i32 = 2 });
    try ctx.interp.memoryGrow();
    // Returns old size (1)
    try std.testing.expectEqual(@as(i32, 1), try ctx.interp.popI32());

    // memory.size should return 3
    try ctx.interp.memorySize();
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
    const result = try interp.callFunc(0, &[_]Value{ .{ .i32 = 3 }, .{ .i32 = 4 } });
    try std.testing.expectEqual(@as(i32, 7), result.?.i32);
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
    const result = try interp.callFunc(0, &[_]Value{.{ .i32 = 99 }});
    try std.testing.expectEqual(@as(i32, 99), result.?.i32);
}
