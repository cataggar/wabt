//! WIT lexer.
//!
//! Tokenizes WIT (the WebAssembly Interface Types text format) for the
//! parser in `parser.zig`. The token set is the full WIT lexical
//! grammar from the Component Model spec (see
//! `wasm-tools/crates/wit-parser/src/ast/lex.rs` for the reference
//! implementation). The parser may still reject some token sequences
//! as unsupported features (see `parser.zig`), but the lexer accepts
//! the entire vocabulary so the parser can be extended without
//! revisiting the lexer.
//!
//! Lexical conventions:
//!   * Identifiers are kebab-case ASCII (`[a-zA-Z][-a-zA-Z0-9]*`),
//!     plus the explicit form `%foo-bar` for using keywords as
//!     identifiers.
//!   * `//` line comments and `/* … */` block comments are skipped.
//!     `///` and `/** … */` are doc comments and are returned as
//!     `doc_comment` / `doc_block` tokens — the parser attaches them
//!     to the next item.
//!   * Integers are bare decimal digits (only used in `@semver`
//!     today; no leading sign, no other bases).
//!   * Strings are not part of the WIT grammar (used only via
//!     `package id:name@semver` where the semver is bare digits and
//!     `.`).
//!
//! Spans are byte offsets into the input. The lexer never copies
//! source; tokens borrow.

const std = @import("std");

pub const Token = enum {
    eof,

    // doc comments returned as tokens; non-doc comments are skipped.
    doc_comment,
    doc_block,

    // punctuation
    eq,
    comma,
    colon,
    period,
    semicolon,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lt,
    gt,
    arrow,
    star,
    at,
    slash,
    plus,
    minus,

    // keywords
    kw_use,
    kw_type,
    kw_func,
    kw_u8,
    kw_u16,
    kw_u32,
    kw_u64,
    kw_s8,
    kw_s16,
    kw_s32,
    kw_s64,
    kw_f32,
    kw_f64,
    kw_char,
    kw_record,
    kw_resource,
    kw_own,
    kw_borrow,
    kw_flags,
    kw_variant,
    kw_enum,
    kw_bool,
    kw_string,
    kw_option,
    kw_result,
    kw_future,
    kw_stream,
    kw_error_context,
    kw_list,
    kw_underscore,
    kw_as,
    kw_from,
    kw_static,
    kw_interface,
    kw_tuple,
    kw_import,
    kw_export,
    kw_world,
    kw_package,
    kw_constructor,
    kw_async,
    kw_include,
    kw_with,

    // Bare identifier (`foo-bar`) and explicit identifier (`%foo`).
    id,
    explicit_id,

    integer,
};

pub const Span = struct {
    start: u32,
    end: u32,

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Tok = struct {
    tag: Token,
    span: Span,
};

pub const LexError = error{
    UnterminatedBlockComment,
    UnexpectedChar,
    EmptyExplicitId,
    InvalidEscape,
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,

    pub fn init(source: []const u8) Lexer {
        var l = Lexer{ .source = source };
        // Eat optional UTF-8 BOM.
        if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
            l.pos = 3;
        }
        return l;
    }

    fn peek(self: *const Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekAt(self: *const Lexer, off: u32) ?u8 {
        const p = self.pos + off;
        if (p >= self.source.len) return null;
        return self.source[p];
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
    }

    pub fn next(self: *Lexer) LexError!Tok {
        // Skip whitespace + non-doc comments. Doc comments are
        // returned as tokens.
        while (true) {
            const c = self.peek() orelse return .{ .tag = .eof, .span = .{ .start = self.pos, .end = self.pos } };
            switch (c) {
                ' ', '\t', '\n', '\r' => self.advance(),
                '/' => {
                    // Could be a comment (`//` or `/*`) or a bare slash
                    // punctuation (used in interface refs like
                    // `pkg:foo/bar`). Look at the next byte.
                    const c1 = self.peekAt(1) orelse break;
                    if (c1 == '/') {
                        // `//` line or `///` doc.
                        const is_doc = (self.peekAt(2) orelse 0) == '/' and (self.peekAt(3) orelse 0) != '/';
                        const start = self.pos;
                        // Skip to end of line.
                        while (self.peek()) |cc| {
                            if (cc == '\n') break;
                            self.advance();
                        }
                        const end = self.pos;
                        if (is_doc) {
                            return .{ .tag = .doc_comment, .span = .{ .start = start, .end = end } };
                        }
                    } else if (c1 == '*') {
                        const is_doc = (self.peekAt(2) orelse 0) == '*' and (self.peekAt(3) orelse 0) != '*' and (self.peekAt(3) orelse 0) != '/';
                        const start = self.pos;
                        self.advance();
                        self.advance();
                        var depth: u32 = 1;
                        while (depth > 0) {
                            const cc = self.peek() orelse return error.UnterminatedBlockComment;
                            if (cc == '/' and (self.peekAt(1) orelse 0) == '*') {
                                self.advance();
                                self.advance();
                                depth += 1;
                            } else if (cc == '*' and (self.peekAt(1) orelse 0) == '/') {
                                self.advance();
                                self.advance();
                                depth -= 1;
                            } else {
                                self.advance();
                            }
                        }
                        if (is_doc) {
                            return .{ .tag = .doc_block, .span = .{ .start = start, .end = self.pos } };
                        }
                    } else {
                        // Bare slash — break out so the punctuation
                        // switch below emits `.slash`.
                        break;
                    }
                },
                else => break,
            }
        }

        const start = self.pos;
        const c = self.peek() orelse return .{ .tag = .eof, .span = .{ .start = self.pos, .end = self.pos } };

        // Single-char punctuation and `->` arrow.
        switch (c) {
            '=' => {
                self.advance();
                return .{ .tag = .eq, .span = .{ .start = start, .end = self.pos } };
            },
            ',' => {
                self.advance();
                return .{ .tag = .comma, .span = .{ .start = start, .end = self.pos } };
            },
            ':' => {
                self.advance();
                return .{ .tag = .colon, .span = .{ .start = start, .end = self.pos } };
            },
            '.' => {
                self.advance();
                return .{ .tag = .period, .span = .{ .start = start, .end = self.pos } };
            },
            ';' => {
                self.advance();
                return .{ .tag = .semicolon, .span = .{ .start = start, .end = self.pos } };
            },
            '(' => {
                self.advance();
                return .{ .tag = .lparen, .span = .{ .start = start, .end = self.pos } };
            },
            ')' => {
                self.advance();
                return .{ .tag = .rparen, .span = .{ .start = start, .end = self.pos } };
            },
            '{' => {
                self.advance();
                return .{ .tag = .lbrace, .span = .{ .start = start, .end = self.pos } };
            },
            '}' => {
                self.advance();
                return .{ .tag = .rbrace, .span = .{ .start = start, .end = self.pos } };
            },
            '<' => {
                self.advance();
                return .{ .tag = .lt, .span = .{ .start = start, .end = self.pos } };
            },
            '>' => {
                self.advance();
                return .{ .tag = .gt, .span = .{ .start = start, .end = self.pos } };
            },
            '-' => {
                self.advance();
                if (self.peek() == @as(u8, '>')) {
                    self.advance();
                    return .{ .tag = .arrow, .span = .{ .start = start, .end = self.pos } };
                }
                return .{ .tag = .minus, .span = .{ .start = start, .end = self.pos } };
            },
            '*' => {
                self.advance();
                return .{ .tag = .star, .span = .{ .start = start, .end = self.pos } };
            },
            '@' => {
                self.advance();
                return .{ .tag = .at, .span = .{ .start = start, .end = self.pos } };
            },
            '/' => {
                // Already handled comments above; bare `/` is a token
                // (used in interface refs like `pkg:foo/bar`).
                self.advance();
                return .{ .tag = .slash, .span = .{ .start = start, .end = self.pos } };
            },
            '+' => {
                self.advance();
                return .{ .tag = .plus, .span = .{ .start = start, .end = self.pos } };
            },
            '_' => {
                // Underscore can be bare keyword `_` (only when followed by
                // non-id-continuation) or part of an identifier (rare in WIT
                // but legal in `%foo_bar`). The unadorned `_` form is the
                // wildcard — there's a `kw_underscore` token.
                if (!isIdContinue(self.peekAt(1) orelse 0)) {
                    self.advance();
                    return .{ .tag = .kw_underscore, .span = .{ .start = start, .end = self.pos } };
                }
                // Else fallthrough into id lexing below.
                return self.lexId();
            },
            '0'...'9' => return self.lexInteger(),
            '%' => return self.lexExplicitId(),
            'a'...'z', 'A'...'Z' => return self.lexIdOrKeyword(),
            else => return self.lexErrorHere(error.UnexpectedChar),
        }
    }

    fn lexId(self: *Lexer) LexError!Tok {
        const start = self.pos;
        // Already past the first char's classification check; consume the
        // first byte and continue.
        self.advance();
        while (self.peek()) |cc| {
            if (!isIdContinue(cc)) break;
            self.advance();
        }
        return .{ .tag = .id, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexExplicitId(self: *Lexer) LexError!Tok {
        const start = self.pos;
        self.advance(); // %
        if (self.peek() == null or !isIdStart(self.peek().?)) {
            return error.EmptyExplicitId;
        }
        self.advance();
        while (self.peek()) |cc| {
            if (!isIdContinue(cc)) break;
            self.advance();
        }
        return .{ .tag = .explicit_id, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexIdOrKeyword(self: *Lexer) LexError!Tok {
        const start = self.pos;
        self.advance();
        while (self.peek()) |cc| {
            if (!isIdContinue(cc)) break;
            self.advance();
        }
        const text = self.source[start..self.pos];
        const kw = keywordTag(text) orelse return .{ .tag = .id, .span = .{ .start = start, .end = self.pos } };
        return .{ .tag = kw, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexInteger(self: *Lexer) LexError!Tok {
        const start = self.pos;
        while (self.peek()) |cc| {
            if (cc < '0' or cc > '9') break;
            self.advance();
        }
        return .{ .tag = .integer, .span = .{ .start = start, .end = self.pos } };
    }

    fn lexErrorHere(self: *Lexer, err: LexError) LexError {
        // For now we just return the error tag; a richer diagnostic
        // surface (line/col reporting) can wrap this later.
        _ = self;
        return err;
    }
};

fn isIdStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdContinue(c: u8) bool {
    return isIdStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

fn keywordTag(text: []const u8) ?Token {
    // Match the full WIT keyword list (mirrors `wasm-tools` lex.rs).
    // The parser may reject some at semantic level (e.g. `stream`,
    // `future`, `async`); accepting them lexically lets us point at
    // a precise span when we do.
    const Kw = struct { name: []const u8, tag: Token };
    const table = [_]Kw{
        .{ .name = "use", .tag = .kw_use },
        .{ .name = "type", .tag = .kw_type },
        .{ .name = "func", .tag = .kw_func },
        .{ .name = "u8", .tag = .kw_u8 },
        .{ .name = "u16", .tag = .kw_u16 },
        .{ .name = "u32", .tag = .kw_u32 },
        .{ .name = "u64", .tag = .kw_u64 },
        .{ .name = "s8", .tag = .kw_s8 },
        .{ .name = "s16", .tag = .kw_s16 },
        .{ .name = "s32", .tag = .kw_s32 },
        .{ .name = "s64", .tag = .kw_s64 },
        .{ .name = "f32", .tag = .kw_f32 },
        .{ .name = "f64", .tag = .kw_f64 },
        .{ .name = "char", .tag = .kw_char },
        .{ .name = "record", .tag = .kw_record },
        .{ .name = "resource", .tag = .kw_resource },
        .{ .name = "own", .tag = .kw_own },
        .{ .name = "borrow", .tag = .kw_borrow },
        .{ .name = "flags", .tag = .kw_flags },
        .{ .name = "variant", .tag = .kw_variant },
        .{ .name = "enum", .tag = .kw_enum },
        .{ .name = "bool", .tag = .kw_bool },
        .{ .name = "string", .tag = .kw_string },
        .{ .name = "option", .tag = .kw_option },
        .{ .name = "result", .tag = .kw_result },
        .{ .name = "future", .tag = .kw_future },
        .{ .name = "stream", .tag = .kw_stream },
        .{ .name = "error-context", .tag = .kw_error_context },
        .{ .name = "list", .tag = .kw_list },
        .{ .name = "as", .tag = .kw_as },
        .{ .name = "from", .tag = .kw_from },
        .{ .name = "static", .tag = .kw_static },
        .{ .name = "interface", .tag = .kw_interface },
        .{ .name = "tuple", .tag = .kw_tuple },
        .{ .name = "import", .tag = .kw_import },
        .{ .name = "export", .tag = .kw_export },
        .{ .name = "world", .tag = .kw_world },
        .{ .name = "package", .tag = .kw_package },
        .{ .name = "constructor", .tag = .kw_constructor },
        .{ .name = "async", .tag = .kw_async },
        .{ .name = "include", .tag = .kw_include },
        .{ .name = "with", .tag = .kw_with },
    };
    for (table) |kw| {
        if (std.mem.eql(u8, text, kw.name)) return kw.tag;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn expectSequence(source: []const u8, expected: []const Token) !void {
    var lex = Lexer.init(source);
    for (expected) |e| {
        const t = try lex.next();
        try std.testing.expectEqual(e, t.tag);
    }
    const eof = try lex.next();
    try std.testing.expectEqual(Token.eof, eof.tag);
}

test "lex: punctuation" {
    try expectSequence(
        "{}();,:.<>->/@*+-=",
        &.{ .lbrace, .rbrace, .lparen, .rparen, .semicolon, .comma, .colon, .period, .lt, .gt, .arrow, .slash, .at, .star, .plus, .minus, .eq },
    );
}

test "lex: keywords" {
    try expectSequence(
        "package world interface use func record variant enum flags option result tuple list",
        &.{ .kw_package, .kw_world, .kw_interface, .kw_use, .kw_func, .kw_record, .kw_variant, .kw_enum, .kw_flags, .kw_option, .kw_result, .kw_tuple, .kw_list },
    );
}

test "lex: primitives" {
    try expectSequence(
        "u8 u16 u32 u64 s8 s16 s32 s64 f32 f64 bool char string",
        &.{ .kw_u8, .kw_u16, .kw_u32, .kw_u64, .kw_s8, .kw_s16, .kw_s32, .kw_s64, .kw_f32, .kw_f64, .kw_bool, .kw_char, .kw_string },
    );
}

test "lex: identifiers and integers" {
    try expectSequence(
        "foo bar-baz qux1 %use 42 0",
        &.{ .id, .id, .id, .explicit_id, .integer, .integer },
    );
}

test "lex: doc comments" {
    var lex = Lexer.init(
        \\/// World comment.
        \\world adder { }
    );
    const t1 = try lex.next();
    try std.testing.expectEqual(Token.doc_comment, t1.tag);
    try std.testing.expectEqualStrings("/// World comment.", t1.span.slice(lex.source));
    const t2 = try lex.next();
    try std.testing.expectEqual(Token.kw_world, t2.tag);
}

test "lex: skip line and block comments" {
    try expectSequence(
        "// comment\n/* block */\nworld",
        &.{.kw_world},
    );
}

test "lex: package decl tokens" {
    try expectSequence(
        "package docs:adder@0.1.0;",
        &.{ .kw_package, .id, .colon, .id, .at, .integer, .period, .integer, .period, .integer, .semicolon },
    );
}

test "lex: import with interface ref" {
    try expectSequence(
        "import docs:adder/add@0.1.0;",
        &.{ .kw_import, .id, .colon, .id, .slash, .id, .at, .integer, .period, .integer, .period, .integer, .semicolon },
    );
}

test "lex: full wamr adder example" {
    const source =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\    add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\    export add;
        \\}
    ;
    // Just count how many tokens we get; the count itself acts as a
    // smoke test for the lexer.
    var lex = Lexer.init(source);
    var n: u32 = 0;
    while (true) {
        const t = try lex.next();
        if (t.tag == .eof) break;
        n += 1;
        if (n > 1000) return error.TooManyTokens;
    }
    try std.testing.expect(n > 20);
    try std.testing.expect(n < 60);
}

test "lex: explicit-id form" {
    var lex = Lexer.init("%record");
    const t = try lex.next();
    try std.testing.expectEqual(Token.explicit_id, t.tag);
    try std.testing.expectEqualStrings("%record", t.span.slice(lex.source));
}

test "lex: empty explicit id rejected" {
    var lex = Lexer.init("% ");
    try std.testing.expectError(error.EmptyExplicitId, lex.next());
}

test "lex: unterminated block comment rejected" {
    var lex = Lexer.init("/* hi");
    try std.testing.expectError(error.UnterminatedBlockComment, lex.next());
}
