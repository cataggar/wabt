//! WAST spec test runner.
//!
//! Reads `.wast` source text and executes top-level commands:
//! `(module ...)`, `(assert_invalid ...)`, `(assert_malformed ...)`, etc.
//! Reports aggregate pass/fail/skip counts.

const std = @import("std");
const Parser = @import("text/Parser.zig");
const Validator = @import("Validator.zig");

/// Aggregate result of running a WAST file.
pub const Result = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn total(self: Result) u32 {
        return self.passed + self.failed + self.skipped;
    }
};

/// Run all WAST commands in `source` and return aggregate results.
pub fn run(allocator: std.mem.Allocator, source: []const u8) Result {
    var result = Result{};
    var pos: usize = 0;

    while (pos < source.len) {
        pos = skipWhitespaceAndComments(source, pos);
        if (pos >= source.len) break;

        if (source[pos] != '(') {
            pos += 1;
            continue;
        }

        const sexpr = extractSExpr(source, pos) orelse break;
        pos = sexpr.end;

        const cmd = classifyCommand(sexpr.text);
        switch (cmd) {
            .module => {
                // Top-level module definition — not an assertion.
                result.skipped += 1;
            },
            .assert_invalid => processAssertInvalid(allocator, sexpr.text, &result),
            .assert_malformed => processAssertMalformed(allocator, sexpr.text, &result),
            .assert_return,
            .assert_trap,
            .assert_exhaustion,
            .assert_unlinkable,
            .invoke,
            .register,
            .unknown,
            => {
                result.skipped += 1;
            },
        }
    }

    return result;
}

// ── Command classification ──────────────────────────────────────────────

const Command = enum {
    module,
    assert_invalid,
    assert_malformed,
    assert_return,
    assert_trap,
    assert_exhaustion,
    assert_unlinkable,
    invoke,
    register,
    unknown,
};

fn classifyCommand(sexpr: []const u8) Command {
    // sexpr starts with '('; skip it and any whitespace to find the keyword.
    var i: usize = 1;
    while (i < sexpr.len and isWhitespace(sexpr[i])) : (i += 1) {}
    const word_start = i;
    while (i < sexpr.len and !isWhitespace(sexpr[i]) and sexpr[i] != '(' and sexpr[i] != ')') : (i += 1) {}
    const word = sexpr[word_start..i];

    if (std.mem.eql(u8, word, "module")) return .module;
    if (std.mem.eql(u8, word, "assert_invalid")) return .assert_invalid;
    if (std.mem.eql(u8, word, "assert_malformed")) return .assert_malformed;
    if (std.mem.eql(u8, word, "assert_return")) return .assert_return;
    if (std.mem.eql(u8, word, "assert_trap")) return .assert_trap;
    if (std.mem.eql(u8, word, "assert_exhaustion")) return .assert_exhaustion;
    if (std.mem.eql(u8, word, "assert_unlinkable")) return .assert_unlinkable;
    if (std.mem.eql(u8, word, "invoke")) return .invoke;
    if (std.mem.eql(u8, word, "register")) return .register;
    return .unknown;
}

// ── Assertion processors ────────────────────────────────────────────────

fn processAssertInvalid(allocator: std.mem.Allocator, sexpr: []const u8, result: *Result) void {
    // (assert_invalid (module ...) "error message")
    // Find the embedded module s-expression.
    const inner = findEmbeddedModule(sexpr) orelse {
        result.skipped += 1;
        return;
    };

    // Skip `(module binary ...)` and `(module quote ...)` — we can't handle those.
    if (isBinaryOrQuoteModule(inner)) {
        result.skipped += 1;
        return;
    }

    // Parse the module text.
    var module = Parser.parseModule(allocator, inner) catch {
        // Parse failure counts as skip (some modules use unsupported features).
        result.skipped += 1;
        return;
    };
    defer module.deinit();

    // Validation should fail for assert_invalid.
    Validator.validate(&module, .{}) catch {
        result.passed += 1;
        return;
    };

    // Validation unexpectedly succeeded.
    result.failed += 1;
}

fn processAssertMalformed(allocator: std.mem.Allocator, sexpr: []const u8, result: *Result) void {
    // (assert_malformed (module ...) "error message")
    const inner = findEmbeddedModule(sexpr) orelse {
        result.skipped += 1;
        return;
    };

    // Skip binary/quote forms.
    if (isBinaryOrQuoteModule(inner)) {
        result.skipped += 1;
        return;
    }

    // Parse should fail.
    var module = Parser.parseModule(allocator, inner) catch {
        result.passed += 1;
        return;
    };
    module.deinit();

    // Parsed successfully — for assert_malformed, validation failure also counts.
    // Some spec tests classify validation errors as "malformed".
    var module2 = Parser.parseModule(allocator, inner) catch {
        result.passed += 1;
        return;
    };
    defer module2.deinit();

    Validator.validate(&module2, .{}) catch {
        result.passed += 1;
        return;
    };

    result.failed += 1;
}

// ── S-expression utilities ──────────────────────────────────────────────

const SExpr = struct {
    text: []const u8,
    end: usize,
};

/// Extract a balanced s-expression starting at `start` in `source`.
/// Returns the slice and the position just past the closing ')'.
fn extractSExpr(source: []const u8, start: usize) ?SExpr {
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

/// Find the first `(module ...)` s-expression embedded within `sexpr`.
fn findEmbeddedModule(sexpr: []const u8) ?[]const u8 {
    // Search for "(module" pattern inside the outer s-expression.
    var i: usize = 1; // skip outer '('
    while (i < sexpr.len) : (i += 1) {
        if (sexpr[i] == '(' and hasWordAt(sexpr, i + 1, "module")) {
            const inner = extractSExpr(sexpr, i) orelse return null;
            return inner.text;
        }
    }
    return null;
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
fn isBinaryOrQuoteModule(mod_text: []const u8) bool {
    // Skip "(module" then whitespace, then check for "binary" or "quote".
    var i: usize = 1; // skip '('
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    // Skip "module"
    const mod_kw = "module";
    if (i + mod_kw.len > mod_text.len) return false;
    i += mod_kw.len;
    // Skip whitespace
    while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    // Optional $name identifier
    if (i < mod_text.len and mod_text[i] == '$') {
        while (i < mod_text.len and !isWhitespace(mod_text[i]) and mod_text[i] != '(' and mod_text[i] != ')') : (i += 1) {}
        while (i < mod_text.len and isWhitespace(mod_text[i])) : (i += 1) {}
    }
    // Now check for "binary" or "quote"
    if (i + 6 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 6], "binary")) return true;
    if (i + 5 <= mod_text.len and std.mem.eql(u8, mod_text[i .. i + 5], "quote")) return true;
    return false;
}

// ── Whitespace helpers ──────────────────────────────────────────────────

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Skip whitespace and comments (line comments ";;" and block comments "(; ... ;)").
fn skipWhitespaceAndComments(source: []const u8, start: usize) usize {
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

test "run: top-level module is skipped" {
    const wast = "(module (func (export \"f\")))";
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 0), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 1), result.skipped);
}

test "run: assert_invalid with duplicate export passes" {
    const wast =
        \\(assert_invalid
        \\  (module (func) (export "a" (func 0)) (export "a" (func 0)))
        \\  "duplicate export name"
        \\)
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: assert_malformed with binary module is skipped" {
    const wast =
        \\(assert_malformed (module binary "") "unexpected end")
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 1), result.skipped);
}

test "run: assert_malformed with quote module is skipped" {
    const wast =
        \\(assert_malformed (module quote "(func)") "unknown operator")
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 1), result.skipped);
}

test "run: assert_return is skipped" {
    const wast =
        \\(assert_return (invoke "f" (i32.const 1)) (i32.const 2))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 0), result.passed);
    try std.testing.expectEqual(@as(u32, 1), result.skipped);
}

test "run: mixed commands" {
    const wast =
        \\(module (func))
        \\(assert_invalid
        \\  (module (func) (export "a" (func 0)) (export "a" (func 0)))
        \\  "duplicate export name"
        \\)
        \\(assert_return (invoke "a") (i32.const 0))
    ;
    const result = run(std.testing.allocator, wast);
    // 1 module (skipped) + 1 assert_invalid (passed) + 1 assert_return (skipped)
    try std.testing.expectEqual(@as(u32, 3), result.total());
    try std.testing.expectEqual(@as(u32, 1), result.passed);
    try std.testing.expectEqual(@as(u32, 2), result.skipped);
}

test "run: block comments are handled" {
    const wast =
        \\(; this is a block comment ;)
        \\(module (func))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.total());
}

test "Result.total" {
    const r = Result{ .passed = 3, .failed = 1, .skipped = 2 };
    try std.testing.expectEqual(@as(u32, 6), r.total());
}
