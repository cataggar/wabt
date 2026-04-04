//! WebAssembly text format parser.
//!
//! Parses .wat/.wast token streams into Module IR.

const std = @import("std");
const Lexer = @import("Lexer.zig").Lexer;
const TokenKind = @import("Lexer.zig").TokenKind;
const Module = @import("../Module.zig").Module;

pub const ParseError = error{
    UnexpectedToken,
    InvalidModule,
    OutOfMemory,
};

/// Parse a WebAssembly text format source into a Module.
pub fn parseModule(allocator: std.mem.Allocator, source: []const u8) ParseError!Module {
    var lexer = Lexer.init(source);

    // Expect (module ...)
    if (lexer.next().kind != .l_paren) return error.UnexpectedToken;
    if (lexer.next().kind != .kw_module) return error.UnexpectedToken;

    var module = Module.init(allocator);
    errdefer module.deinit();

    // Skip to closing paren (stub — just consume tokens)
    var depth: u32 = 1;
    while (depth > 0) {
        const tok = lexer.next();
        switch (tok.kind) {
            .l_paren => depth += 1,
            .r_paren => depth -= 1,
            .eof => return error.InvalidModule,
            else => {},
        }
    }

    return module;
}

test "parse empty module" {
    var module = try parseModule(std.testing.allocator, "(module)");
    defer module.deinit();
}

test "reject missing module keyword" {
    try std.testing.expectError(error.UnexpectedToken, parseModule(std.testing.allocator, "(func)"));
}
