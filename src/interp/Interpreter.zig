//! WebAssembly interpreter.
//!
//! Stack-based interpreter that executes WebAssembly modules directly,
//! without compilation to native code.

const std = @import("std");
const Module = @import("../Module.zig").Module;

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
};

/// Runtime value.
pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

/// Interpreter instance.
pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    module: *const Module,

    pub fn init(allocator: std.mem.Allocator, module: *const Module) Interpreter {
        return .{ .allocator = allocator, .module = module };
    }

    pub fn deinit(self: *Interpreter) void {
        _ = self;
        // TODO: free runtime state
    }
};

test "create interpreter" {
    var module = Module.init(std.testing.allocator);
    defer module.deinit();

    var interp = Interpreter.init(std.testing.allocator, &module);
    defer interp.deinit();
}
