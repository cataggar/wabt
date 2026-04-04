//! WebAssembly module validator.
//!
//! Validates a parsed Module against the WebAssembly specification,
//! checking types, imports, exports, function bodies, and more.

const std = @import("std");
const Module = @import("Module.zig").Module;
const Feature = @import("Feature.zig");

pub const Error = error{
    InvalidType,
    InvalidFunction,
    InvalidMemory,
    InvalidTable,
    InvalidGlobal,
    InvalidExport,
    InvalidImport,
    InvalidElement,
    InvalidData,
    InvalidStart,
    TypeMismatch,
};

/// Validate a WebAssembly module.
pub fn validate(module: *const Module) Error!void {
    _ = module;
    // TODO: implement validation passes
}

test "validate empty module" {
    var module = Module.init(std.testing.allocator);
    defer module.deinit();
    try validate(&module);
}
