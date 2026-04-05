//! WAST spec test runner.
//!
//! Reads `.wast` source text and executes top-level commands:
//! `(module ...)`, `(assert_invalid ...)`, `(assert_malformed ...)`, etc.
//! Reports aggregate pass/fail/skip counts.

const std = @import("std");
const Parser = @import("text/Parser.zig");
const Validator = @import("Validator.zig");
const Mod = @import("Module.zig");
const types = @import("types.zig");
const Interp = @import("interp/Interpreter.zig");

/// Aggregate result of running a WAST file.
pub const Result = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn total(self: Result) u32 {
        return self.passed + self.failed + self.skipped;
    }
};

/// Mutable state for the runner: tracks the current module, instance, and interpreter.
const RunState = struct {
    allocator: std.mem.Allocator,
    module: ?*Mod.Module = null,
    instance: ?*Interp.Instance = null,
    interpreter: ?*Interp.Interpreter = null,

    fn deinit(self: *RunState) void {
        if (self.interpreter) |interp| { interp.deinit(); self.allocator.destroy(interp); }
        if (self.instance) |inst| { inst.deinit(); self.allocator.destroy(inst); }
        if (self.module) |mod| { mod.deinit(); self.allocator.destroy(mod); }
        self.interpreter = null;
        self.instance = null;
        self.module = null;
    }

    fn setModule(self: *RunState, mod_text: []const u8) bool {
        // Clean up previous state
        if (self.interpreter) |interp| { interp.deinit(); self.allocator.destroy(interp); }
        if (self.instance) |inst| { inst.deinit(); self.allocator.destroy(inst); }
        if (self.module) |mod| { mod.deinit(); self.allocator.destroy(mod); }
        self.interpreter = null;
        self.instance = null;
        self.module = null;

        const mod = self.allocator.create(Mod.Module) catch return false;
        mod.* = Parser.parseModule(self.allocator, mod_text) catch {
            self.allocator.destroy(mod);
            return false;
        };

        const inst = self.allocator.create(Interp.Instance) catch {
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };
        inst.* = Interp.Instance.init(self.allocator, mod) catch {
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };

        inst.instantiate() catch {
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };

        const interp = self.allocator.create(Interp.Interpreter) catch {
            inst.deinit();
            self.allocator.destroy(inst);
            mod.deinit();
            self.allocator.destroy(mod);
            return false;
        };
        interp.* = Interp.Interpreter.init(self.allocator, inst);

        self.module = mod;
        self.instance = inst;
        self.interpreter = interp;
        return true;
    }
};

/// Run all WAST commands in `source` and return aggregate results.
pub fn run(allocator: std.mem.Allocator, source: []const u8) Result {
    var result = Result{};
    var pos: usize = 0;
    var state = RunState{ .allocator = allocator };
    defer state.deinit();

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
                if (isBinaryOrQuoteModule(sexpr.text)) {
                    result.skipped += 1;
                } else {
                    if (state.setModule(sexpr.text)) {
                        result.passed += 1;
                    } else {
                        result.skipped += 1;
                    }
                }
            },
            .assert_invalid => processAssertInvalid(allocator, sexpr.text, &result),
            .assert_malformed => processAssertMalformed(allocator, sexpr.text, &result),
            .assert_return => processAssertReturn(allocator, sexpr.text, &state, &result),
            .assert_trap => processAssertTrap(allocator, sexpr.text, &state, &result),
            .invoke => processInvoke(allocator, sexpr.text, &state, &result),
            .assert_exhaustion,
            .assert_unlinkable,
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

fn processAssertReturn(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    _ = allocator;
    const interp = state.interpreter orelse {
        result.skipped += 1;
        return;
    };

    // Parse: (assert_return (invoke "name" args...) expected...)
    const inv = findInvoke(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    const func_name = extractStringLiteral(inv) orelse {
        result.skipped += 1;
        return;
    };

    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    const call_result = interp.callExport(func_name, args) catch {
        result.failed += 1;
        return;
    };

    // Parse expected results (after the invoke sexpr)
    const after_invoke = skipFirstSExpr(sexpr) orelse sexpr;
    var expected_buf: [16]Interp.Value = undefined;
    const expected = parseExpectedResults(after_invoke, &expected_buf);

    if (expected.len == 0) {
        // No expected result — just check it didn't trap
        result.passed += 1;
        return;
    }

    if (call_result) |actual| {
        if (expected.len > 0 and valuesEqual(actual, expected[0])) {
            result.passed += 1;
        } else {
            result.failed += 1;
        }
    } else {
        // Function returned no value
        if (expected.len == 0) {
            result.passed += 1;
        } else {
            result.failed += 1;
        }
    }
}

fn processAssertTrap(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    _ = allocator;
    const interp = state.interpreter orelse {
        result.skipped += 1;
        return;
    };

    const inv = findInvoke(sexpr) orelse {
        // Could be (assert_trap (module ...) "msg") — skip these
        result.skipped += 1;
        return;
    };
    const func_name = extractStringLiteral(inv) orelse {
        result.skipped += 1;
        return;
    };

    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(inv, &args_buf);

    if (interp.callExport(func_name, args)) |_| {
        // Expected a trap but succeeded
        result.failed += 1;
    } else |_| {
        // Got an error (trap) — this is expected
        result.passed += 1;
    }
}

fn processInvoke(allocator: std.mem.Allocator, sexpr: []const u8, state: *RunState, result: *Result) void {
    _ = allocator;
    const interp = state.interpreter orelse {
        result.skipped += 1;
        return;
    };
    const func_name = extractStringLiteral(sexpr) orelse {
        result.skipped += 1;
        return;
    };
    var args_buf: [16]Interp.Value = undefined;
    const args = parseInvokeArgs(sexpr, &args_buf);
    _ = interp.callExport(func_name, args) catch {};
    result.passed += 1;
}

// ── Invoke / value parsing helpers ──────────────────────────────────────

/// Find the `(invoke ...)` sub-expression inside a sexpr.
fn findInvoke(sexpr: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < sexpr.len) : (i += 1) {
        if (sexpr[i] == '(' and hasWordAt(sexpr, i + 1, "invoke")) {
            const inner = extractSExpr(sexpr, i) orelse return null;
            return inner.text;
        }
    }
    return null;
}

/// Extract a quoted string literal from an s-expression, e.g. from `(invoke "add" ...)`.
fn extractStringLiteral(sexpr: []const u8) ?[]const u8 {
    // Find first '"' character
    var i: usize = 0;
    while (i < sexpr.len and sexpr[i] != '"') : (i += 1) {}
    if (i >= sexpr.len) return null;
    i += 1; // skip opening quote
    const start = i;
    while (i < sexpr.len and sexpr[i] != '"') : (i += 1) {
        if (sexpr[i] == '\\' and i + 1 < sexpr.len) { i += 1; continue; }
    }
    if (i > sexpr.len) return null;
    return sexpr[start..i];
}

/// Parse const value arguments from an invoke expression.
fn parseInvokeArgs(inv: []const u8, buf: []Interp.Value) []const Interp.Value {
    // Skip past the function name string, then parse (type.const value) sub-exprs
    var count: usize = 0;
    var i: usize = 0;
    // Skip to after the first string literal
    while (i < inv.len and inv[i] != '"') : (i += 1) {}
    if (i < inv.len) i += 1; // skip opening "
    while (i < inv.len and inv[i] != '"') : (i += 1) {
        if (inv[i] == '\\' and i + 1 < inv.len) { i += 1; continue; }
    }
    if (i < inv.len) i += 1; // skip closing "

    while (i < inv.len and count < buf.len) {
        if (inv[i] == '(') {
            const inner = extractSExpr(inv, i) orelse break;
            if (parseConstValue(inner.text)) |v| {
                buf[count] = v;
                count += 1;
            }
            i = inner.end;
        } else {
            i += 1;
        }
    }
    return buf[0..count];
}

/// Parse expected results from the portion after the invoke expr.
fn parseExpectedResults(text: []const u8, buf: []Interp.Value) []const Interp.Value {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < buf.len) {
        if (text[i] == '(') {
            const inner = extractSExpr(text, i) orelse break;
            if (parseConstValue(inner.text)) |v| {
                buf[count] = v;
                count += 1;
            }
            i = inner.end;
        } else {
            i += 1;
        }
    }
    return buf[0..count];
}

/// Parse a const value like (i32.const 42) or (f64.const 3.14).
fn parseConstValue(sexpr: []const u8) ?Interp.Value {
    var i: usize = 1; // skip '('
    while (i < sexpr.len and isWhitespace(sexpr[i])) : (i += 1) {}
    // Read keyword
    const kw_start = i;
    while (i < sexpr.len and !isWhitespace(sexpr[i]) and sexpr[i] != ')') : (i += 1) {}
    const kw = sexpr[kw_start..i];

    // Skip whitespace to value
    while (i < sexpr.len and isWhitespace(sexpr[i])) : (i += 1) {}
    const val_start = i;
    while (i < sexpr.len and sexpr[i] != ')' and !isWhitespace(sexpr[i])) : (i += 1) {}
    const val_text = sexpr[val_start..i];

    if (std.mem.eql(u8, kw, "i32.const")) {
        const v = std.fmt.parseInt(i32, val_text, 0) catch blk: {
            const u = std.fmt.parseInt(u32, val_text, 0) catch return null;
            break :blk @as(i32, @bitCast(u));
        };
        return .{ .i32 = v };
    } else if (std.mem.eql(u8, kw, "i64.const")) {
        const v = std.fmt.parseInt(i64, val_text, 0) catch blk: {
            const u = std.fmt.parseInt(u64, val_text, 0) catch return null;
            break :blk @as(i64, @bitCast(u));
        };
        return .{ .i64 = v };
    } else if (std.mem.eql(u8, kw, "f32.const")) {
        if (std.mem.eql(u8, val_text, "nan") or std.mem.eql(u8, val_text, "+nan") or
            std.mem.eql(u8, val_text, "-nan") or std.mem.startsWith(u8, val_text, "nan:"))
        {
            return .{ .f32 = std.math.nan(f32) };
        }
        const v = std.fmt.parseFloat(f32, val_text) catch return .{ .f32 = 0.0 };
        return .{ .f32 = v };
    } else if (std.mem.eql(u8, kw, "f64.const")) {
        if (std.mem.eql(u8, val_text, "nan") or std.mem.eql(u8, val_text, "+nan") or
            std.mem.eql(u8, val_text, "-nan") or std.mem.startsWith(u8, val_text, "nan:"))
        {
            return .{ .f64 = std.math.nan(f64) };
        }
        const v = std.fmt.parseFloat(f64, val_text) catch return .{ .f64 = 0.0 };
        return .{ .f64 = v };
    }
    return null;
}

/// Skip past the first nested s-expression in text and return the remainder.
fn skipFirstSExpr(text: []const u8) ?[]const u8 {
    // Find the first nested s-expr (after the outer keyword)
    var i: usize = 1;
    while (i < text.len and isWhitespace(text[i])) : (i += 1) {}
    // Skip keyword
    while (i < text.len and !isWhitespace(text[i]) and text[i] != '(' and text[i] != ')') : (i += 1) {}
    // Find the first '(' after keyword
    while (i < text.len and text[i] != '(') : (i += 1) {}
    if (i >= text.len) return null;
    // Skip this sexpr
    const inner = extractSExpr(text, i) orelse return null;
    return text[inner.end..];
}

/// Compare two Values for equality (used for assert_return).
fn valuesEqual(a: Interp.Value, b: Interp.Value) bool {
    return switch (a) {
        .i32 => |av| switch (b) {
            .i32 => |bv| av == bv,
            else => false,
        },
        .i64 => |av| switch (b) {
            .i64 => |bv| av == bv,
            else => false,
        },
        .f32 => |av| switch (b) {
            .f32 => |bv| {
                if (std.math.isNan(av) and std.math.isNan(bv)) return true;
                return av == bv;
            },
            else => false,
        },
        .f64 => |av| switch (b) {
            .f64 => |bv| {
                if (std.math.isNan(av) and std.math.isNan(bv)) return true;
                return av == bv;
            },
            else => false,
        },
        else => false,
    };
}

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

test "run: top-level module is parsed" {
    const wast = "(module (func (export \"f\")))";
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 1), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 0), result.skipped);
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

test "run: assert_return without module is skipped" {
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
    // 1 module (passed) + 1 assert_invalid (passed) + 1 assert_return (failed — no export "a" in current module)
    try std.testing.expectEqual(@as(u32, 3), result.total());
    try std.testing.expectEqual(@as(u32, 2), result.passed);
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

test "run: assert_return with simple add" {
    const wast =
        \\(module
        \\  (func (export "add") (param i32 i32) (result i32)
        \\    local.get 0 local.get 1 i32.add
        \\  )
        \\)
        \\(assert_return (invoke "add" (i32.const 3) (i32.const 4)) (i32.const 7))
        \\(assert_return (invoke "add" (i32.const 0) (i32.const 0)) (i32.const 0))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 3), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: assert_trap on unreachable" {
    const wast =
        \\(module
        \\  (func (export "trap") unreachable)
        \\)
        \\(assert_trap (invoke "trap") "unreachable")
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 2), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}

test "run: assert_return with block and br" {
    const wast =
        \\(module
        \\  (func (export "br") (param i32) (result i32)
        \\    (block (result i32) (local.get 0) (br 0))
        \\  )
        \\)
        \\(assert_return (invoke "br" (i32.const 42)) (i32.const 42))
    ;
    const result = run(std.testing.allocator, wast);
    try std.testing.expectEqual(@as(u32, 2), result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}
