//! WebAssembly interpreter.
//!
//! Stack-based interpreter that executes WebAssembly modules directly,
//! without compilation to native code. Individual operations are exposed
//! as public methods so they can be tested and composed incrementally.

const std = @import("std");
const Mod = @import("../Module.zig");
const types = @import("../types.zig");

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

/// Runtime module instance — holds mutable state (memory, globals, table).
pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const Mod.Module,

    /// Linear memory (one page = 65 536 bytes).
    memory: std.ArrayList(u8),

    /// Global variable values.
    globals: std.ArrayList(Value),

    /// Function table — `null` entries are uninitialised.
    table: std.ArrayList(?u32),

    pub fn init(allocator: std.mem.Allocator, module: *const Mod.Module) TrapError!Instance {
        var inst = Instance{
            .allocator = allocator,
            .module = module,
            .memory = .empty,
            .globals = .empty,
            .table = .empty,
        };

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

        // Initialise table for first table definition.
        if (module.tables.items.len > 0) {
            const tbl = module.tables.items[0];
            const initial: usize = @intCast(tbl.@"type".limits.initial);
            inst.table.resize(allocator, initial) catch return error.OutOfMemory;
            @memset(inst.table.items, null);
        }

        return inst;
    }

    pub fn deinit(self: *Instance) void {
        self.memory.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.table.deinit(self.allocator);
    }
};

// ── Interpreter ──────────────────────────────────────────────────────────

/// Stack-based WebAssembly interpreter.
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    instance: *Instance,

    /// Operand stack.
    stack: std.ArrayList(Value),

    /// Current call nesting depth.
    call_depth: u32 = 0,
    /// Maximum allowed call nesting depth.
    max_call_depth: u32 = 1000,

    pub fn init(allocator: std.mem.Allocator, instance: *Instance) Interpreter {
        return .{
            .allocator = allocator,
            .instance = instance,
            .stack = .empty,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.stack.deinit(self.allocator);
    }

    /// Call an exported function by name.
    pub fn callExport(self: *Interpreter, name: []const u8, args: []const Value) TrapError!?Value {
        const exp = self.instance.module.getExport(name) orelse return error.UndefinedElement;
        if (exp.kind != .func) return error.UndefinedElement;
        const idx: u32 = switch (exp.var_) {
            .index => |i| i,
            .name => return error.Unimplemented,
        };
        return self.callFunc(idx, args);
    }

    /// Call a function by index.
    pub fn callFunc(self: *Interpreter, func_idx: u32, args: []const Value) TrapError!?Value {
        if (self.call_depth >= self.max_call_depth) return error.CallStackExhausted;
        if (func_idx >= self.instance.module.funcs.items.len) return error.UndefinedElement;

        self.call_depth += 1;
        defer self.call_depth -= 1;

        // Push arguments onto the stack.
        for (args) |a| try self.pushValue(a);

        // Instruction dispatch from bytecode is not yet implemented;
        // return a result value from the stack if one is present.
        const func = self.instance.module.funcs.items[func_idx];
        const sig = func.decl.sig;
        if (sig.results.len > 0) {
            if (self.stack.items.len > 0) {
                return self.popValue();
            }
            return null;
        }
        return null;
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
        try self.pushValue(.{ .f32 = @round(a) });
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
        try self.pushValue(.{ .f64 = @round(a) });
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
        const old_pages: i32 = @intCast(self.instance.memory.items.len / page_size);
        const new_len = self.instance.memory.items.len + @as(usize, @intCast(delta)) * page_size;

        // Apply max limit from the module definition if present.
        if (self.instance.module.memories.items.len > 0) {
            const mem = self.instance.module.memories.items[0];
            if (mem.@"type".limits.has_max) {
                const max_bytes = @as(usize, @intCast(mem.@"type".limits.max)) * page_size;
                if (new_len > max_bytes) {
                    try self.pushValue(.{ .i32 = -1 });
                    return;
                }
            }
        }

        self.instance.memory.resize(self.allocator, new_len) catch {
            try self.pushValue(.{ .i32 = -1 });
            return;
        };
        // Zero-initialise newly grown pages.
        const old_len = @as(usize, @intCast(old_pages)) * page_size;
        @memset(self.instance.memory.items[old_len..], 0);
        try self.pushValue(.{ .i32 = old_pages });
    }
};

// ── Wasm-spec min/max helpers (NaN propagation) ─────────────────────────

fn wasmMinF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == 0.0 and b == 0.0) {
        // -0 < +0 in wasm
        return if (std.math.signbit(a)) a else b;
    }
    return @min(a, b);
}

fn wasmMaxF32(a: f32, b: f32) f32 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == 0.0 and b == 0.0) {
        return if (std.math.signbit(a)) b else a;
    }
    return @max(a, b);
}

fn wasmMinF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == 0.0 and b == 0.0) {
        return if (std.math.signbit(a)) a else b;
    }
    return @min(a, b);
}

fn wasmMaxF64(a: f64, b: f64) f64 {
    if (std.math.isNan(a)) return a;
    if (std.math.isNan(b)) return b;
    if (a == 0.0 and b == 0.0) {
        return if (std.math.signbit(a)) b else a;
    }
    return @max(a, b);
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
        .memory = .empty,
        .globals = .empty,
        .table = .empty,
    };
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
