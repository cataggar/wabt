//! wabt — WebAssembly Binary Toolkit
//!
//! A Zig implementation of tools for working with WebAssembly.
//! Provides parsing, validation, interpretation, and transformation
//! of WebAssembly modules in both binary (.wasm) and text (.wat) formats.

pub const types = @import("types.zig");
pub const Opcode = @import("Opcode.zig");
pub const Feature = @import("Feature.zig");
pub const Module = @import("Module.zig");
pub const Validator = @import("Validator.zig");
pub const CWriter = @import("CWriter.zig");
pub const Decompiler = @import("Decompiler.zig");

pub const leb128 = @import("leb128.zig");

pub const binary = struct {
    pub const reader = @import("binary/reader.zig");
    pub const writer = @import("binary/writer.zig");
};

pub const text = struct {
    pub const Lexer = @import("text/Lexer.zig");
    pub const Parser = @import("text/Parser.zig");
    pub const Writer = @import("text/Writer.zig");
};

pub const interp = struct {
    pub const Interpreter = @import("interp/Interpreter.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("integration_tests.zig");
    _ = @import("spec_tests.zig");
}
