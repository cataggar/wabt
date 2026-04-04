//! WebAssembly text format lexer.
//!
//! Tokenizes .wat/.wast source text into a stream of tokens
//! for consumption by the parser.

const std = @import("std");

pub const TokenKind = enum {
    // Structure
    l_paren,
    r_paren,

    // Keywords
    kw_module,
    kw_func,
    kw_param,
    kw_result,
    kw_local,
    kw_global,
    kw_memory,
    kw_table,
    kw_type,
    kw_import,
    kw_export,

    // Literals
    integer,
    float,
    string,

    // Identifiers
    identifier,

    // Special
    eof,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    offset: usize,
};

/// Lexer state.
pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return .{ .kind = .eof, .text = "", .offset = self.pos };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '(' => {
                self.pos += 1;
                return .{ .kind = .l_paren, .text = "(", .offset = start };
            },
            ')' => {
                self.pos += 1;
                return .{ .kind = .r_paren, .text = ")", .offset = start };
            },
            else => {
                // consume until whitespace or paren
                while (self.pos < self.source.len and
                    self.source[self.pos] != ' ' and
                    self.source[self.pos] != '\n' and
                    self.source[self.pos] != '\r' and
                    self.source[self.pos] != '\t' and
                    self.source[self.pos] != '(' and
                    self.source[self.pos] != ')')
                {
                    self.pos += 1;
                }
                const text = self.source[start..self.pos];
                const kind = classifyKeyword(text);
                return .{ .kind = kind, .text = text, .offset = start };
            },
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                self.pos += 1;
            } else if (c == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') {
                // line comment
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn classifyKeyword(text: []const u8) TokenKind {
        const map = .{
            .{ "module", TokenKind.kw_module },
            .{ "func", TokenKind.kw_func },
            .{ "param", TokenKind.kw_param },
            .{ "result", TokenKind.kw_result },
            .{ "local", TokenKind.kw_local },
            .{ "global", TokenKind.kw_global },
            .{ "memory", TokenKind.kw_memory },
            .{ "table", TokenKind.kw_table },
            .{ "type", TokenKind.kw_type },
            .{ "import", TokenKind.kw_import },
            .{ "export", TokenKind.kw_export },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        if (text.len > 0 and text[0] == '$') return .identifier;
        return .invalid;
    }
};

test "lex module skeleton" {
    var lexer = Lexer.init("(module)");
    try std.testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try std.testing.expectEqual(TokenKind.kw_module, lexer.next().kind);
    try std.testing.expectEqual(TokenKind.r_paren, lexer.next().kind);
    try std.testing.expectEqual(TokenKind.eof, lexer.next().kind);
}
