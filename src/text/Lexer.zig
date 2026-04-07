//! WebAssembly text format lexer.
//!
//! Tokenizes .wat/.wast source text into a stream of tokens
//! for consumption by the parser.

const std = @import("std");

pub const TokenKind = enum {
    // Structure
    l_paren,
    r_paren,

    // Module-level keywords
    kw_module,
    kw_type,
    kw_func,
    kw_table,
    kw_memory,
    kw_global,
    kw_import,
    kw_export,
    kw_start,
    kw_elem,
    kw_data,
    kw_tag,
    kw_rec,
    kw_definition,

    // Inline keywords
    kw_param,
    kw_result,
    kw_local,
    kw_mut,
    kw_offset,
    kw_align,
    kw_declare,
    kw_item,

    // Value type keywords
    kw_i32,
    kw_i64,
    kw_f32,
    kw_f64,
    kw_v128,
    kw_funcref,
    kw_externref,
    kw_anyref,

    // Bare reference keywords (GC proposal)
    kw_ref,
    kw_null,

    // Reference keywords
    kw_ref_null,
    kw_ref_func,
    kw_ref_extern,
    kw_ref_test,
    kw_ref_cast,

    // Control instructions
    kw_block,
    kw_loop,
    kw_if,
    kw_then,
    kw_else,
    kw_end,
    kw_unreachable,
    kw_nop,
    kw_br,
    kw_br_if,
    kw_br_table,
    kw_return,
    kw_call,
    kw_call_indirect,
    kw_return_call,
    kw_return_call_indirect,

    // Parametric
    kw_drop,
    kw_select,

    // Variable
    kw_local_get,
    kw_local_set,
    kw_local_tee,
    kw_global_get,
    kw_global_set,

    // Memory instructions
    kw_memory_size,
    kw_memory_grow,

    // Numeric const
    kw_i32_const,
    kw_i64_const,
    kw_f32_const,
    kw_f64_const,

    // Generic opcode (for instructions not explicitly listed)
    opcode,

    // Literals
    integer,
    float,
    string,

    // Identifiers ($name)
    identifier,

    // Nat after = (like offset=N, align=N)
    nat_eq,

    // Special
    eof,
    invalid,
    annotation,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    offset: usize,
};

/// Lexer state — converts WAT source text into a stream of tokens.
pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    /// Returns the next token from the source.
    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return .{ .kind = .eof, .text = "", .offset = self.pos };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        switch (c) {
            '(' => {
                // Check for block comment start "(;"
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') {
                    self.skipBlockComment();
                    return self.next();
                }
                // Check for annotation "(@id"
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '@') {
                    self.pos += 2; // skip '(' and '@'
                    const id_start = self.pos;
                    while (self.pos < self.source.len and isWordChar(self.source[self.pos])) {
                        self.pos += 1;
                    }
                    // Empty annotation id: (@) or (@ x) — return invalid
                    if (self.pos == id_start) {
                        return .{ .kind = .invalid, .text = self.source[start..self.pos], .offset = start };
                    }
                    return .{ .kind = .annotation, .text = self.source[start..self.pos], .offset = start };
                }
                self.pos += 1;
                return .{ .kind = .l_paren, .text = "(", .offset = start };
            },
            ')' => {
                self.pos += 1;
                return .{ .kind = .r_paren, .text = ")", .offset = start };
            },
            '"' => return self.lexString(start),
            else => return self.lexWord(start),
        }
    }

    /// Lex a quoted string literal with escape sequences.
    fn lexString(self: *Lexer, start: usize) Token {
        // Skip opening quote
        self.pos += 1;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '"') {
                self.pos += 1;
                // Reject glued tokens: string immediately followed by word/string/id
                if (self.pos < self.source.len) {
                    const nc = self.source[self.pos];
                    if (isWordChar(nc) or nc == '$' or nc == '"') {
                        self.consumeGluedContent();
                        return .{ .kind = .invalid, .text = self.source[start..self.pos], .offset = start };
                    }
                }
                return .{ .kind = .string, .text = self.source[start..self.pos], .offset = start };
            }
            if (ch == '\\') {
                // Skip escape sequence
                self.pos += 1;
                if (self.pos < self.source.len) {
                    self.pos += 1;
                    // For \xx hex escapes the second hex digit is consumed by the next iteration
                }
                continue;
            }
            self.pos += 1;
        }
        // Unterminated string
        return .{ .kind = .invalid, .text = self.source[start..self.pos], .offset = start };
    }

    /// Lex a word token (keyword, number, identifier, or opcode).
    fn lexWord(self: *Lexer, start: usize) Token {
        // Identifiers start with '$'
        if (self.source[start] == '$') {
            self.pos += 1;
            while (self.pos < self.source.len and isIdChar(self.source[self.pos])) {
                self.pos += 1;
            }
            // Reject identifier glued to string
            if (self.pos < self.source.len and self.source[self.pos] == '"') {
                self.consumeGluedContent();
                return .{ .kind = .invalid, .text = self.source[start..self.pos], .offset = start };
            }
            const text = self.source[start..self.pos];
            return .{ .kind = .identifier, .text = text, .offset = start };
        }

        // Consume word chars (non-whitespace, non-paren, non-quote, non-semicolon-starting-comment)
        while (self.pos < self.source.len and isWordChar(self.source[self.pos])) {
            self.pos += 1;
        }

        const text = self.source[start..self.pos];
        if (text.len == 0) {
            self.pos += 1;
            return .{ .kind = .invalid, .text = self.source[start..self.pos], .offset = start };
        }

        // Reject word glued to string (e.g. data"a", 0"a")
        if (self.pos < self.source.len and self.source[self.pos] == '"') {
            self.consumeGluedContent();
            return .{ .kind = .invalid, .text = self.source[start..self.pos], .offset = start };
        }

        // Check for nat_eq pattern: word=number (e.g., offset=0, align=4)
        if (self.pos < self.source.len and self.source[self.pos] == '=') {
            const eq_pos = self.pos;
            self.pos += 1; // skip '='
            // Consume the number after '='
            while (self.pos < self.source.len and isWordChar(self.source[self.pos])) {
                self.pos += 1;
            }
            return .{ .kind = .nat_eq, .text = self.source[start..self.pos], .offset = eq_pos };
        }

        // Classify the word
        const kind = classifyWord(text);
        return .{ .kind = kind, .text = text, .offset = start };
    }

    fn isWordChar(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', '(', ')', '"', ';', '=' => false,
            else => c >= 0x21 and c <= 0x7e,
        };
    }

    fn isIdChar(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '\r', '(', ')', '"', ';' => false,
            else => c >= 0x21 and c <= 0x7e,
        };
    }

    /// Consume remaining glued content (strings, words, identifiers) without separators.
    fn consumeGluedContent(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const gc = self.source[self.pos];
            if (gc == '"') {
                self.pos += 1;
                while (self.pos < self.source.len and self.source[self.pos] != '"') {
                    if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) self.pos += 1;
                    self.pos += 1;
                }
                if (self.pos < self.source.len) self.pos += 1;
            } else if (isWordChar(gc) or gc == '$') {
                self.pos += 1;
            } else break;
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                self.pos += 1;
            } else if (c == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') {
                // Line comment: ;; to end of line
                while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') {
                    self.pos += 1;
                }
            } else if (c == '(' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') {
                self.skipBlockComment();
            } else {
                break;
            }
        }
    }

    /// Skip a block comment "(; ... ;)" with nesting support.
    fn skipBlockComment(self: *Lexer) void {
        // Skip opening "(;"
        self.pos += 2;
        var depth: usize = 1;
        while (self.pos + 1 < self.source.len and depth > 0) {
            if (self.source[self.pos] == '(' and self.source[self.pos + 1] == ';') {
                depth += 1;
                self.pos += 2;
            } else if (self.source[self.pos] == ';' and self.source[self.pos + 1] == ')') {
                depth -= 1;
                self.pos += 2;
            } else {
                self.pos += 1;
            }
        }
        // If we ran out of input with depth > 0, we're at eof (malformed comment).
        // If depth == 0 and only one byte left, check the last byte.
        if (depth > 0 and self.pos < self.source.len) {
            self.pos = self.source.len;
        }
    }
};

/// Classify a word token into its specific TokenKind.
pub fn classifyWord(text: []const u8) TokenKind {
    if (text.len == 0) return .invalid;

    // Check for numeric literal: starts with digit, or +/- followed by digit
    if (isNumStart(text)) {
        if (!hasValidNumberChars(text)) return .invalid;
        return classifyNumber(text);
    }

    // Bare "inf", "nan", "nan:0x..." are float literals
    if (eql(text, "inf") or eql(text, "nan")) return .float;
    if (text.len > 4 and std.mem.startsWith(u8, text, "nan:")) return .float;

    // Exact keyword matching
    const kind = matchKeyword(text);
    if (kind != .invalid) return kind;

    // If it contains a dot, treat as generic opcode
    if (std.mem.indexOfScalar(u8, text, '.') != null) return .opcode;

    return .invalid;
}

fn isNumStart(text: []const u8) bool {
    if (text.len == 0) return false;
    const first = text[0];
    if (first >= '0' and first <= '9') return true;
    if ((first == '+' or first == '-') and text.len > 1) {
        const second = text[1];
        if (second >= '0' and second <= '9') return true;
        // +inf, -inf, +nan, -nan
        if (text.len >= 4) {
            const rest = text[1..];
            if (std.mem.startsWith(u8, rest, "inf")) return true;
            if (std.mem.startsWith(u8, rest, "nan")) return true;
        }
    }
    return false;
}

fn classifyNumber(text: []const u8) TokenKind {
    // Special float values
    const base = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    if (std.mem.eql(u8, base, "inf")) return .float;
    if (std.mem.startsWith(u8, base, "nan")) return .float;

    // Check if this is a hex number (0x prefix)
    const is_hex = (base.len > 2 and base[0] == '0' and (base[1] == 'x' or base[1] == 'X'));

    // Check for float indicators
    // For hex: only '.' and 'p'/'P' indicate float (e/E are hex digits)
    // For decimal: '.', 'e', 'E', 'p', 'P' indicate float
    for (text) |ch| {
        switch (ch) {
            '.' => return .float,
            'p', 'P' => return .float,
            'e', 'E' => if (!is_hex) return .float,
            else => {},
        }
    }
    return .integer;
}

/// Check that a number-starting word only contains valid number characters.
/// Rejects glued tokens like `0drop`, `0$l` where a number runs into a keyword/identifier.
fn hasValidNumberChars(text: []const u8) bool {
    var i: usize = 0;
    // Skip optional sign
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    // Handle special values: inf, nan, nan:0x...
    if (i < text.len) {
        const rest = text[i..];
        if (std.mem.startsWith(u8, rest, "inf") and rest.len == 3) return true;
        if (std.mem.startsWith(u8, rest, "nan")) return true;
    }
    // Check hex prefix
    const is_hex = (i + 2 <= text.len and text[i] == '0' and
        (text[i + 1] == 'x' or text[i + 1] == 'X'));
    if (is_hex) i += 2;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c >= '0' and c <= '9') continue;
        if (c == '_' or c == '.' or c == '+' or c == '-') continue;
        if (c == 'e' or c == 'E' or c == 'p' or c == 'P') continue;
        if (is_hex and ((c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) continue;
        return false;
    }
    return true;
}

fn matchKeyword(text: []const u8) TokenKind {
    // This uses a series of checks organized by first character for efficiency.
    // Module-level keywords
    if (eql(text, "module")) return .kw_module;
    if (eql(text, "type")) return .kw_type;
    if (eql(text, "func")) return .kw_func;
    if (eql(text, "table")) return .kw_table;
    if (eql(text, "memory")) return .kw_memory;
    if (eql(text, "global")) return .kw_global;
    if (eql(text, "import")) return .kw_import;
    if (eql(text, "export")) return .kw_export;
    if (eql(text, "start")) return .kw_start;
    if (eql(text, "elem")) return .kw_elem;
    if (eql(text, "data")) return .kw_data;
    if (eql(text, "tag")) return .kw_tag;
    if (eql(text, "rec")) return .kw_rec;
    if (eql(text, "definition")) return .kw_definition;

    // Inline keywords
    if (eql(text, "param")) return .kw_param;
    if (eql(text, "result")) return .kw_result;
    if (eql(text, "local")) return .kw_local;
    if (eql(text, "mut")) return .kw_mut;
    if (eql(text, "offset")) return .kw_offset;
    if (eql(text, "align")) return .kw_align;
    if (eql(text, "declare")) return .kw_declare;
    if (eql(text, "item")) return .kw_item;

    // Value type keywords
    if (eql(text, "i32")) return .kw_i32;
    if (eql(text, "i64")) return .kw_i64;
    if (eql(text, "f32")) return .kw_f32;
    if (eql(text, "f64")) return .kw_f64;
    if (eql(text, "v128")) return .kw_v128;
    if (eql(text, "funcref")) return .kw_funcref;
    if (eql(text, "externref")) return .kw_externref;
    if (eql(text, "anyref")) return .kw_anyref;

    // Bare reference keywords (GC proposal)
    if (eql(text, "ref")) return .kw_ref;
    if (eql(text, "null")) return .kw_null;

    // Reference keywords (dot-separated)
    if (eql(text, "ref.null")) return .kw_ref_null;
    if (eql(text, "ref.func")) return .kw_ref_func;
    if (eql(text, "ref.extern")) return .kw_ref_extern;
    if (eql(text, "ref.test")) return .kw_ref_test;
    if (eql(text, "ref.cast")) return .kw_ref_cast;

    // Control instructions
    if (eql(text, "block")) return .kw_block;
    if (eql(text, "loop")) return .kw_loop;
    if (eql(text, "if")) return .kw_if;
    if (eql(text, "then")) return .kw_then;
    if (eql(text, "else")) return .kw_else;
    if (eql(text, "end")) return .kw_end;
    if (eql(text, "unreachable")) return .kw_unreachable;
    if (eql(text, "nop")) return .kw_nop;
    if (eql(text, "br")) return .kw_br;
    if (eql(text, "br_if")) return .kw_br_if;
    if (eql(text, "br_table")) return .kw_br_table;
    if (eql(text, "return")) return .kw_return;
    if (eql(text, "call")) return .kw_call;
    if (eql(text, "call_indirect")) return .kw_call_indirect;
    if (eql(text, "return_call")) return .kw_return_call;
    if (eql(text, "return_call_indirect")) return .kw_return_call_indirect;

    // Parametric
    if (eql(text, "drop")) return .kw_drop;
    if (eql(text, "select")) return .kw_select;

    // Variable instructions (dot-separated)
    if (eql(text, "local.get")) return .kw_local_get;
    if (eql(text, "local.set")) return .kw_local_set;
    if (eql(text, "local.tee")) return .kw_local_tee;
    if (eql(text, "global.get")) return .kw_global_get;
    if (eql(text, "global.set")) return .kw_global_set;

    // Memory instructions (dot-separated)
    if (eql(text, "memory.size")) return .kw_memory_size;
    if (eql(text, "memory.grow")) return .kw_memory_grow;

    // Numeric const instructions (dot-separated)
    if (eql(text, "i32.const")) return .kw_i32_const;
    if (eql(text, "i64.const")) return .kw_i64_const;
    if (eql(text, "f32.const")) return .kw_f32_const;
    if (eql(text, "f64.const")) return .kw_f64_const;

    return .invalid;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn collectTokenKinds(source: []const u8, buf: []TokenKind) []TokenKind {
    var lexer = Lexer.init(source);
    var i: usize = 0;
    while (i < buf.len) {
        const tok = lexer.next();
        buf[i] = tok.kind;
        i += 1;
        if (tok.kind == .eof) break;
    }
    return buf[0..i];
}

test "lex module skeleton" {
    var buf: [8]TokenKind = undefined;
    const kinds = collectTokenKinds("(module)", &buf);
    try testing.expectEqual(@as(usize, 4), kinds.len);
    try testing.expectEqual(TokenKind.l_paren, kinds[0]);
    try testing.expectEqual(TokenKind.kw_module, kinds[1]);
    try testing.expectEqual(TokenKind.r_paren, kinds[2]);
    try testing.expectEqual(TokenKind.eof, kinds[3]);
}

test "lex line comments" {
    var buf: [8]TokenKind = undefined;
    const kinds = collectTokenKinds(";; this is a comment\n(module)", &buf);
    try testing.expectEqual(@as(usize, 4), kinds.len);
    try testing.expectEqual(TokenKind.l_paren, kinds[0]);
    try testing.expectEqual(TokenKind.kw_module, kinds[1]);
    try testing.expectEqual(TokenKind.r_paren, kinds[2]);
    try testing.expectEqual(TokenKind.eof, kinds[3]);
}

test "lex block comments including nested" {
    var buf: [8]TokenKind = undefined;
    // Simple block comment
    const kinds1 = collectTokenKinds("(; comment ;)(module)", &buf);
    try testing.expectEqual(@as(usize, 4), kinds1.len);
    try testing.expectEqual(TokenKind.l_paren, kinds1[0]);

    // Nested block comment
    var buf2: [8]TokenKind = undefined;
    const kinds2 = collectTokenKinds("(; outer (; inner ;) still outer ;)(module)", &buf2);
    try testing.expectEqual(@as(usize, 4), kinds2.len);
    try testing.expectEqual(TokenKind.l_paren, kinds2[0]);
    try testing.expectEqual(TokenKind.kw_module, kinds2[1]);
}

test "lex string literal" {
    var lexer = Lexer.init("\"hello world\"");
    const tok = lexer.next();
    try testing.expectEqual(TokenKind.string, tok.kind);
    try testing.expectEqualStrings("\"hello world\"", tok.text);

    // String with escapes
    var lexer2 = Lexer.init("\"line\\none\"");
    const tok2 = lexer2.next();
    try testing.expectEqual(TokenKind.string, tok2.kind);
}

test "lex integer and float literals" {
    // Decimal integer
    var lexer = Lexer.init("42");
    try testing.expectEqual(TokenKind.integer, lexer.next().kind);

    // Hex integer
    var lexer2 = Lexer.init("0xFF");
    try testing.expectEqual(TokenKind.integer, lexer2.next().kind);

    // Signed integer
    var lexer3 = Lexer.init("-7");
    try testing.expectEqual(TokenKind.integer, lexer3.next().kind);

    // Decimal float
    var lexer4 = Lexer.init("3.14");
    try testing.expectEqual(TokenKind.float, lexer4.next().kind);

    // Hex float
    var lexer5 = Lexer.init("0x1.5p10");
    try testing.expectEqual(TokenKind.float, lexer5.next().kind);

    // inf and nan
    var lexer6 = Lexer.init("inf");
    try testing.expectEqual(TokenKind.float, lexer6.next().kind);

    var lexer7 = Lexer.init("nan");
    try testing.expectEqual(TokenKind.float, lexer7.next().kind);

    var lexer8 = Lexer.init("nan:0x7fc00000");
    try testing.expectEqual(TokenKind.float, lexer8.next().kind);
}

test "lex identifiers" {
    var lexer = Lexer.init("$foo $bar $my_func");
    const t1 = lexer.next();
    try testing.expectEqual(TokenKind.identifier, t1.kind);
    try testing.expectEqualStrings("$foo", t1.text);

    const t2 = lexer.next();
    try testing.expectEqual(TokenKind.identifier, t2.kind);
    try testing.expectEqualStrings("$bar", t2.text);

    const t3 = lexer.next();
    try testing.expectEqual(TokenKind.identifier, t3.kind);
    try testing.expectEqualStrings("$my_func", t3.text);
}

test "lex value type keywords" {
    var buf: [12]TokenKind = undefined;
    const kinds = collectTokenKinds("i32 i64 f32 f64 v128 funcref externref", &buf);
    try testing.expectEqual(TokenKind.kw_i32, kinds[0]);
    try testing.expectEqual(TokenKind.kw_i64, kinds[1]);
    try testing.expectEqual(TokenKind.kw_f32, kinds[2]);
    try testing.expectEqual(TokenKind.kw_f64, kinds[3]);
    try testing.expectEqual(TokenKind.kw_v128, kinds[4]);
    try testing.expectEqual(TokenKind.kw_funcref, kinds[5]);
    try testing.expectEqual(TokenKind.kw_externref, kinds[6]);
}

test "lex dot-separated instructions" {
    var lexer = Lexer.init("i32.const local.get memory.grow i32.add f64.mul");

    try testing.expectEqual(TokenKind.kw_i32_const, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_local_get, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_memory_grow, lexer.next().kind);
    // Unknown dot-instructions → generic opcode
    try testing.expectEqual(TokenKind.opcode, lexer.next().kind);
    try testing.expectEqual(TokenKind.opcode, lexer.next().kind);
}

test "lex realistic WAT snippet" {
    const source =
        \\(module
        \\  (type $sig (func (param i32 i32) (result i32)))
        \\  (func $add (type $sig) (param $a i32) (param $b i32) (result i32)
        \\    local.get $a
        \\    local.get $b
        \\    i32.add)
        \\  (export "add" (func $add)))
    ;

    var lexer = Lexer.init(source);
    // (module
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_module, lexer.next().kind);

    // (type $sig (func (param i32 i32) (result i32)))
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind); // (
    try testing.expectEqual(TokenKind.kw_type, lexer.next().kind); // type
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $sig
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind); // (
    try testing.expectEqual(TokenKind.kw_func, lexer.next().kind); // func
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind); // (
    try testing.expectEqual(TokenKind.kw_param, lexer.next().kind); // param
    try testing.expectEqual(TokenKind.kw_i32, lexer.next().kind); // i32
    try testing.expectEqual(TokenKind.kw_i32, lexer.next().kind); // i32
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind); // )
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind); // (
    try testing.expectEqual(TokenKind.kw_result, lexer.next().kind); // result
    try testing.expectEqual(TokenKind.kw_i32, lexer.next().kind); // i32
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind); // )
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind); // )
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind); // ) closes type

    // (func $add (type $sig) ...
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind); // (
    try testing.expectEqual(TokenKind.kw_func, lexer.next().kind); // func
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $add
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind); // (
    try testing.expectEqual(TokenKind.kw_type, lexer.next().kind); // type
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $sig
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind); // )

    // (param $a i32) (param $b i32) (result i32)
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_param, lexer.next().kind);
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $a
    try testing.expectEqual(TokenKind.kw_i32, lexer.next().kind);
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_param, lexer.next().kind);
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $b
    try testing.expectEqual(TokenKind.kw_i32, lexer.next().kind);
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_result, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_i32, lexer.next().kind);
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind);

    // local.get $a  local.get $b  i32.add)
    try testing.expectEqual(TokenKind.kw_local_get, lexer.next().kind);
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $a
    try testing.expectEqual(TokenKind.kw_local_get, lexer.next().kind);
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $b
    try testing.expectEqual(TokenKind.opcode, lexer.next().kind); // i32.add
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind); // )

    // (export "add" (func $add))
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_export, lexer.next().kind);
    try testing.expectEqual(TokenKind.string, lexer.next().kind); // "add"
    try testing.expectEqual(TokenKind.l_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_func, lexer.next().kind);
    try testing.expectEqual(TokenKind.identifier, lexer.next().kind); // $add
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind);

    // Closing )
    try testing.expectEqual(TokenKind.r_paren, lexer.next().kind);
    try testing.expectEqual(TokenKind.eof, lexer.next().kind);
}

test "lex nat_eq token" {
    var lexer = Lexer.init("offset=0");
    const tok = lexer.next();
    try testing.expectEqual(TokenKind.nat_eq, tok.kind);
    try testing.expectEqualStrings("offset=0", tok.text);
}

test "lex reference keywords" {
    var lexer = Lexer.init("ref.null ref.func ref.extern");
    try testing.expectEqual(TokenKind.kw_ref_null, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_ref_func, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_ref_extern, lexer.next().kind);
}

test "lex control and parametric keywords" {
    var lexer = Lexer.init("block loop if then else end unreachable nop br br_if br_table return call call_indirect drop select");
    try testing.expectEqual(TokenKind.kw_block, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_loop, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_if, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_then, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_else, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_end, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_unreachable, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_nop, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_br, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_br_if, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_br_table, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_return, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_call, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_call_indirect, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_drop, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_select, lexer.next().kind);
}

test "lex anyref keyword" {
    var lexer = Lexer.init("anyref");
    try testing.expectEqual(TokenKind.kw_anyref, lexer.next().kind);
}

test "lex rec keyword" {
    var lexer = Lexer.init("rec");
    try testing.expectEqual(TokenKind.kw_rec, lexer.next().kind);
}

test "lex definition keyword" {
    var lexer = Lexer.init("definition");
    try testing.expectEqual(TokenKind.kw_definition, lexer.next().kind);
}

test "lex bare ref and null keywords" {
    var lexer = Lexer.init("ref null");
    try testing.expectEqual(TokenKind.kw_ref, lexer.next().kind);
    try testing.expectEqual(TokenKind.kw_null, lexer.next().kind);
}

test "lex annotation token" {
    var buf: [8]TokenKind = undefined;
    const kinds = collectTokenKinds("(@name foo)", &buf);
    try testing.expectEqual(@as(usize, 4), kinds.len);
    try testing.expectEqual(TokenKind.annotation, kinds[0]);
    try testing.expectEqual(TokenKind.invalid, kinds[1]); // "foo" is not a keyword
    try testing.expectEqual(TokenKind.r_paren, kinds[2]);
    try testing.expectEqual(TokenKind.eof, kinds[3]);

    // Verify annotation text includes (@
    var lexer = Lexer.init("(@custom stuff)");
    const tok = lexer.next();
    try testing.expectEqual(TokenKind.annotation, tok.kind);
    try testing.expectEqualStrings("(@custom", tok.text);
}
