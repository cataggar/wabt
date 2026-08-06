//! WAST (`.wast`) lexical and structural helpers.
//!
//! Splits `.wast` source text into top-level commands, classifies them,
//! and decodes the string forms the spec-test syntax uses (`(module binary ...)`,
//! `(module quote ...)`, hex escapes). This module is purely textual: it does
//! not parse, validate, instantiate, or execute WebAssembly.
//!
//! Consumers are `wabt spec to-json` and the conformance runner in
//! cataggar/wamr, which executes the resulting commands on the WAMR engine.

const std = @import("std");
const types = @import("types.zig");
pub const Command = enum {
    module,
    assert_invalid,
    assert_malformed,
    assert_return,
    assert_trap,
    assert_exhaustion,
    assert_unlinkable,
    assert_exception,
    invoke,
    register,
    get,
    unknown,
};

pub fn classifyCommand(sexpr: []const u8) Command {
    // sexpr starts with '('; skip it and any whitespace to find the keyword.
    var i: usize = 1;
    i = skipWsAndComments(sexpr, i);
    // Skip leading annotations like (@a) before the keyword
    while (i + 1 < sexpr.len and sexpr[i] == '(' and sexpr[i + 1] == '@') {
        // Skip to matching ')' for this annotation
        var depth: usize = 1;
        i += 2;
        while (i < sexpr.len and depth > 0) : (i += 1) {
            if (sexpr[i] == '(') depth += 1;
            if (sexpr[i] == ')') depth -= 1;
        }
        i = skipWsAndComments(sexpr, i);
    }
    const word_start = i;
    while (i < sexpr.len and !isWhitespace(sexpr[i]) and sexpr[i] != '(' and sexpr[i] != ')' and sexpr[i] != ';') : (i += 1) {}
    const word = sexpr[word_start..i];

    if (std.mem.eql(u8, word, "module")) return .module;
    if (std.mem.eql(u8, word, "assert_invalid")) return .assert_invalid;
    if (std.mem.eql(u8, word, "assert_malformed")) return .assert_malformed;
    if (std.mem.eql(u8, word, "assert_return")) return .assert_return;
    if (std.mem.eql(u8, word, "assert_trap")) return .assert_trap;
    if (std.mem.eql(u8, word, "assert_exhaustion")) return .assert_exhaustion;
    if (std.mem.eql(u8, word, "assert_unlinkable")) return .assert_unlinkable;
    if (std.mem.eql(u8, word, "assert_exception")) return .assert_exception;
    if (std.mem.eql(u8, word, "invoke")) return .invoke;
    if (std.mem.eql(u8, word, "register")) return .register;
    if (std.mem.eql(u8, word, "get")) return .get;
    return .unknown;
}

pub fn isModuleDefinition(text: []const u8) bool {
    // Check for "(module definition $name ...)" — must have a $name
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 6 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 6], "module")) return false;
    i += 6;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 10 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 10], "definition")) return false;
    i += 10;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    // Must have $name after definition
    return i < text.len and text[i] == '$';
}

fn isBareModuleField(text: []const u8) bool {
    // Check if s-expression starts with a module field keyword (not a command)
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    const start = i;
    while (i < text.len and !isWhitespace(text[i]) and text[i] != ')' and text[i] != '(') : (i += 1) {}
    const word = text[start..i];
    return std.mem.eql(u8, word, "func") or std.mem.eql(u8, word, "memory") or
        std.mem.eql(u8, word, "table") or std.mem.eql(u8, word, "global") or
        std.mem.eql(u8, word, "type") or std.mem.eql(u8, word, "elem") or
        std.mem.eql(u8, word, "data") or std.mem.eql(u8, word, "import") or
        std.mem.eql(u8, word, "export") or std.mem.eql(u8, word, "start") or
        std.mem.eql(u8, word, "tag");
}

fn hasDefinitionKeyword(text: []const u8) bool {
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 6 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 6], "module")) return false;
    i += 6;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 10 >= text.len) return false;
    return std.mem.eql(u8, text[i .. i + 10], "definition");
}

pub fn stripDefinitionKeyword(allocator: std.mem.Allocator, text: []const u8) ?[]u8 {
    // "(module definition ...)" → "(module ...)"
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 6; // "module"
    const before_def = i;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 10; // "definition"
    // Also skip optional $name after definition
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i < text.len and text[i] == '$') {
        while (i < text.len and !isWhitespace(text[i]) and text[i] != ')') : (i += 1) {}
    }
    var buf = std.ArrayListUnmanaged(u8).empty;
    buf.appendSlice(allocator, text[0..before_def]) catch return null;
    buf.appendSlice(allocator, text[i..]) catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

pub fn isModuleInstance(text: []const u8) bool {
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 6 >= text.len) return false;
    if (!std.mem.eql(u8, text[i .. i + 6], "module")) return false;
    i += 6;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i + 8 >= text.len) return false;
    return std.mem.eql(u8, text[i .. i + 8], "instance");
}

pub fn extractModuleDefName(text: []const u8) ?[]const u8 {
    // "(module definition $name ...)" → "$name"
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 6; // skip "module"
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    i += 10; // skip "definition"
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    if (i >= text.len or text[i] != '$') return null;
    const start = i;
    while (i < text.len and !isWhitespace(text[i]) and text[i] != ')') : (i += 1) {}
    return text[start..i];
}

pub const SExpr = struct {
    text: []const u8,
    end: usize,
};

/// Extract a balanced s-expression starting at `start` in `source`.
/// Returns the slice and the position just past the closing ')'.
pub fn extractSExpr(source: []const u8, start: usize) ?SExpr {
    if (start >= source.len or source[start] != '(') return null;
    var depth: u32 = 0;
    var i = start;
    var in_string = false;
    while (i < source.len) : (i += 1) {
        if (in_string) {
            if (source[i] == '\\' and i + 1 < source.len) {
                i += 1;
                continue;
            }
            if (source[i] == '"') in_string = false;
            continue;
        }
        switch (source[i]) {
            ';' => {
                // Line comment ";;" — skip to end of line
                if (i + 1 < source.len and source[i + 1] == ';') {
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                    // Don't advance past the newline twice
                    if (i < source.len) continue;
                }
                // Block comment "(;" is handled by '(' branch; lone ';' is normal
            },
            '"' => in_string = true,
            '(' => {
                // Check for block comment "(;"
                if (i + 1 < source.len and source[i + 1] == ';') {
                    i = skipBlockComment(source, i);
                    // i now points past ";)", back up one because loop increments
                    if (i > 0) i -= 1;
                    continue;
                }
                depth += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return .{ .text = source[start .. i + 1], .end = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

/// Skip a block comment "(; ... ;)" starting at `pos`. Returns position after ";)".
fn skipBlockComment(source: []const u8, start: usize) usize {
    var i = start + 2; // skip "(;"
    var depth: u32 = 1;
    while (i + 1 < source.len and depth > 0) {
        if (source[i] == '(' and source[i + 1] == ';') {
            depth += 1;
            i += 2;
        } else if (source[i] == ';' and source[i + 1] == ')') {
            depth -= 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    return i;
}

/// Skip whitespace and comments (line comments ;;... and block comments (;...;)).
fn skipWsAndComments(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) {
        if (isWhitespace(source[i])) {
            i += 1;
        } else if (i + 1 < source.len and source[i] == ';' and source[i + 1] == ';') {
            // Line comment: skip to end of line
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        } else if (i + 1 < source.len and source[i] == '(' and source[i + 1] == ';') {
            i = skipBlockComment(source, i);
        } else {
            break;
        }
    }
    return i;
}

/// Check if `source[pos..]` starts with whitespace then `word` followed by a delimiter.
fn hasWordAt(source: []const u8, pos: usize, word: []const u8) bool {
    var i = pos;
    // Skip optional whitespace between '(' and keyword
    while (i < source.len and isWhitespace(source[i])) : (i += 1) {}
    if (i + word.len > source.len) return false;
    if (!std.mem.eql(u8, source[i .. i + word.len], word)) return false;
    // Must be followed by delimiter (whitespace, paren, or end)
    if (i + word.len >= source.len) return true;
    const next = source[i + word.len];
    return isWhitespace(next) or next == '(' or next == ')';
}

/// Check whether a module s-expression is `(module binary ...)` or `(module quote ...)`.
pub fn isBinaryOrQuoteModule(mod_text: []const u8) bool {
    return isBinaryModule(mod_text) or isQuoteModule(mod_text);
}

pub fn isBinaryModule(mod_text: []const u8) bool {
    const i = skipModulePrefix(mod_text);
    return i + 6 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 6], "binary");
}

pub fn isQuoteModule(mod_text: []const u8) bool {
    const i = skipModulePrefix(mod_text);
    return i + 5 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 5], "quote");
}

/// Skip past "(module" + optional whitespace + optional $name + whitespace.
fn skipModulePrefix(mod_text: []const u8) usize {
    var i: usize = 1; // skip '('
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    const mod_kw = "module";
    if (i + mod_kw.len > mod_text.len) return i;
    i += mod_kw.len;
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    if (i < mod_text.len and mod_text[i] == '$') {
        while (i < mod_text.len and !isWhitespace(mod_text[i]) and mod_text[i] != '(' and mod_text[i] != ')') : (i += 1) {}
        while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    }
    return i;
}

/// Decode `(module quote "..." "..." ...)` — extract and concatenate quoted WAT strings.
pub fn decodeQuoteStrings(allocator: std.mem.Allocator, mod_text: []const u8) ![]u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    var i = skipModulePrefix(mod_text);
    // Skip "quote" keyword
    if (i + 5 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 5], "quote")) i += 5;

    while (i < mod_text.len) {
        if (mod_text[i] == '"') {
            i += 1;
            while (i < mod_text.len and mod_text[i] != '"') {
                if (mod_text[i] == '\\' and i + 1 < mod_text.len) {
                    i += 1;
                    switch (mod_text[i]) {
                        'n' => { try result.append(allocator, '\n'); i += 1; },
                        't' => { try result.append(allocator, '\t'); i += 1; },
                        'r' => { try result.append(allocator, '\r'); i += 1; },
                        '\\' => { try result.append(allocator, '\\'); i += 1; },
                        '"' => { try result.append(allocator, '"'); i += 1; },
                        '\'' => { try result.append(allocator, '\''); i += 1; },
                        else => {
                            // \xx hex escape — decode to actual byte
                            if (i + 1 < mod_text.len) {
                                const hi = hexDigit(mod_text[i]);
                                const lo = hexDigit(mod_text[i + 1]);
                                if (hi != null and lo != null) {
                                    try result.append(allocator, hi.? * 16 + lo.?);
                                    i += 2;
                                    continue;
                                }
                            }
                            // Not a valid hex escape — pass through as-is
                            try result.append(allocator, '\\');
                            try result.append(allocator, mod_text[i]);
                            i += 1;
                        },
                    }
                } else {
                    try result.append(allocator, mod_text[i]);
                    i += 1;
                }
            }
            if (i < mod_text.len) i += 1; // skip closing "
            try result.append(allocator, ' '); // space between segments
        } else {
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Check if decoded WAT text contains illegal bytes (control chars, 0x7f, non-ASCII outside strings).
/// WAT source only allows: 0x09 (tab), 0x0a (LF), 0x0d (CR), 0x20-0x7e (printable ASCII)
/// outside of string literals and comments. Inside strings, \xx hex escapes are used
/// for non-printable bytes, so raw non-printable bytes are also illegal there.
fn hasIllegalWatBytes(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        // Check for empty identifiers: $""
        if (c == '$' and i + 2 < text.len and text[i + 1] == '"' and text[i + 2] == '"') {
            return true;
        }
        // Inside string literals, check for illegal raw bytes and invalid hex escapes
        if (c == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') : (i += 1) {
                if (text[i] == '\\' and i + 1 < text.len) {
                    const esc = text[i + 1];
                    // Check \xx hex escapes for UTF-8 validity in identifier strings
                    if (hexDigit(esc)) |h1| {
                        if (i + 2 < text.len) {
                            if (hexDigit(text[i + 2])) |h2| {
                                const byte_val = h1 * 16 + h2;
                                // Bytes >= 0x80 must form valid UTF-8 sequences
                                if (byte_val >= 0x80) {
                                    if (!validateHexUtf8(text, i)) return true;
                                }
                                i += 2; // skip \xx (loop will add 1)
                                continue;
                            }
                        }
                    }
                    i += 1; // skip escaped char
                    continue;
                }
                // Only printable ASCII (0x20-0x7e) allowed as raw bytes in WAT strings
                if (text[i] < 0x20 or text[i] >= 0x7f) return true;
            }
            continue;
        }
        // Skip line comments: ;; ... \n
        if (c == ';' and i + 1 < text.len and text[i + 1] == ';') {
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        // Skip block comments: (; ... ;)
        if (c == '(' and i + 1 < text.len and text[i + 1] == ';') {
            i += 2;
            var depth: usize = 1;
            while (i + 1 < text.len and depth > 0) {
                if (text[i] == '(' and text[i + 1] == ';') {
                    depth += 1;
                    i += 2;
                } else if (text[i] == ';' and text[i + 1] == ')') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (i > 0) i -= 1; // adjust for loop increment
            continue;
        }
        if (c == 0x7f) return true;
        if (c >= 0x80) return true; // non-ASCII outside strings/comments
        if (c < 0x20 and c != 0x09 and c != 0x0a and c != 0x0d) return true;
    }
    return false;
}

/// Check if a \xx hex escape sequence at position `pos` in WAT text starts a valid
/// UTF-8 multi-byte sequence using subsequent \xx escapes.
fn validateHexUtf8(text: []const u8, pos: usize) bool {
    // Decode the first byte from \xx at `pos`
    const b0 = decodeHexEscape(text, pos) orelse return false;
    if (b0 < 0x80) return true; // ASCII, always valid
    if (b0 < 0xc0) return false; // continuation byte without lead
    // Determine expected sequence length
    const seq_len: usize = if (b0 < 0xe0) 2 else if (b0 < 0xf0) 3 else if (b0 < 0xf8) 4 else return false;
    // Check that subsequent \xx escapes produce valid continuation bytes
    var offset = pos + 3; // skip first \xx (3 chars: \, h, h)
    for (1..seq_len) |_| {
        const cb = decodeHexEscape(text, offset) orelse return false;
        if (cb & 0xc0 != 0x80) return false; // not a continuation byte
        offset += 3;
    }
    // Check for overlong encodings
    if (seq_len == 2 and b0 < 0xc2) return false;
    if (seq_len == 3 and b0 == 0xe0) {
        const b1 = decodeHexEscape(text, pos + 3) orelse return false;
        if (b1 < 0xa0) return false;
    }
    if (seq_len == 4) {
        if (b0 == 0xf0) {
            const b1 = decodeHexEscape(text, pos + 3) orelse return false;
            if (b1 < 0x90) return false;
        }
        if (b0 == 0xf4) {
            const b1 = decodeHexEscape(text, pos + 3) orelse return false;
            if (b1 > 0x8f) return false;
        }
        if (b0 > 0xf4) return false;
    }
    return true;
}

/// Decode a \xx hex escape at the given position, returning the byte value.
fn decodeHexEscape(text: []const u8, pos: usize) ?u8 {
    if (pos + 2 >= text.len) return null;
    if (text[pos] != '\\') return null;
    const h1 = hexDigit(text[pos + 1]) orelse return null;
    const h2 = hexDigit(text[pos + 2]) orelse return null;
    return h1 * 16 + h2;
}

/// Decode `(module binary "\xx\xx" ...)` — extract hex-encoded binary bytes.
pub fn decodeWastHexStrings(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var res = std.ArrayListUnmanaged(u8).empty;
    errdefer res.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        // Skip line comments: ;; ... \n
        if (text[i] == ';' and i + 1 < text.len and text[i + 1] == ';') {
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            continue;
        }
        // Skip block comments: (; ... ;)
        if (text[i] == '(' and i + 1 < text.len and text[i + 1] == ';') {
            i += 2;
            var depth: usize = 1;
            while (i + 1 < text.len and depth > 0) {
                if (text[i] == '(' and text[i + 1] == ';') {
                    depth += 1;
                    i += 2;
                } else if (text[i] == ';' and text[i + 1] == ')') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            continue;
        }
        if (text[i] == '"') {
            i += 1;
            while (i < text.len and text[i] != '"') {
                if (text[i] == '\\' and i + 2 < text.len) {
                    const hi = hexDigit(text[i + 1]);
                    const lo = hexDigit(text[i + 2]);
                    if (hi != null and lo != null) {
                        try res.append(allocator, hi.? * 16 + lo.?);
                        i += 3;
                    } else {
                        try res.append(allocator, text[i]);
                        i += 1;
                    }
                } else {
                    try res.append(allocator, text[i]);
                    i += 1;
                }
            }
            if (i < text.len) i += 1; // skip closing "
        } else {
            i += 1;
        }
    }
    return res.toOwnedSlice(allocator);
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ── Whitespace helpers ──────────────────────────────────────────────────

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Skip whitespace and comments (line comments ";;" and block comments "(; ... ;)").
pub fn skipWhitespaceAndComments(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) {
        const c = source[i];
        if (isWhitespace(c)) {
            i += 1;
        } else if (c == ';' and i + 1 < source.len and source[i + 1] == ';') {
            // Line comment — skip to end of line
            while (i < source.len and source[i] != '\n') : (i += 1) {}
        } else if (c == '(' and i + 1 < source.len and source[i + 1] == ';') {
            i = skipBlockComment(source, i);
        } else {
            break;
        }
    }
    return i;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "extractSExpr basic" {
    const source = "(module (func))";
    const result = extractSExpr(source, 0).?;
    try std.testing.expectEqualStrings("(module (func))", result.text);
    try std.testing.expectEqual(@as(usize, 15), result.end);
}

test "extractSExpr with string containing parens" {
    const source =
        \\(assert_invalid (module) "bad (stuff)")
    ;
    const result = extractSExpr(source, 0).?;
    try std.testing.expectEqualStrings(source, result.text);
}

test "classifyCommand" {
    try std.testing.expectEqual(Command.module, classifyCommand("(module)"));
    try std.testing.expectEqual(Command.assert_invalid, classifyCommand("(assert_invalid (module))"));
    try std.testing.expectEqual(Command.assert_malformed, classifyCommand("(assert_malformed (module))"));
    try std.testing.expectEqual(Command.assert_return, classifyCommand("(assert_return (invoke))"));
    try std.testing.expectEqual(Command.unknown, classifyCommand("(foobar)"));
}

test "isBinaryOrQuoteModule" {
    try std.testing.expect(isBinaryOrQuoteModule("(module binary \"\\00\")"));
    try std.testing.expect(isBinaryOrQuoteModule("(module quote \"(func)\")"));
    try std.testing.expect(!isBinaryOrQuoteModule("(module (func))"));
}
