//! Spec test infrastructure for running .wast-style assertions.
//!
//! Provides helpers for `assert_invalid`, `assert_malformed`, and a
//! simple suite runner, along with concrete tests that exercise the
//! WebAssembly validation rules.

const std = @import("std");
const binary_reader = @import("binary/reader.zig");
const Validator = @import("Validator.zig");
const Interp = @import("interp/Interpreter.zig");
const Mod = @import("Module.zig");
const types = @import("types.zig");

// ── Public types ────────────────────────────────────────────────────────

/// Result of running a spec test assertion.
pub const AssertResult = enum {
    pass,
    fail,
    skip,
};

/// Run an assert_invalid test: the module bytes should fail validation.
pub fn assertInvalid(allocator: std.mem.Allocator, wasm_bytes: []const u8) AssertResult {
    return assertInvalidWithOptions(allocator, wasm_bytes, .{});
}

/// Run an assert_invalid test with explicit validator options.
pub fn assertInvalidWithOptions(allocator: std.mem.Allocator, wasm_bytes: []const u8, options: Validator.Options) AssertResult {
    var module = binary_reader.readModule(allocator, wasm_bytes) catch return .pass;
    defer module.deinit();
    Validator.validate(&module, options) catch return .pass;
    return .fail; // should have failed but didn't
}

/// Run an assert_malformed test: the module bytes should fail to parse.
pub fn assertMalformed(allocator: std.mem.Allocator, wasm_bytes: []const u8) AssertResult {
    var module = binary_reader.readModule(allocator, wasm_bytes) catch return .pass;
    defer module.deinit();
    return .fail; // should have failed parsing
}

/// A simple spec test suite runner that tallies pass/fail/skip counts.
pub const Suite = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn run(self: *Suite, name: []const u8, result: AssertResult) void {
        _ = name;
        switch (result) {
            .pass => self.passed += 1,
            .fail => self.failed += 1,
            .skip => self.skipped += 1,
        }
    }

    pub fn summary(self: Suite) void {
        std.debug.print("Spec tests: {} passed, {} failed, {} skipped\n", .{ self.passed, self.failed, self.skipped });
    }
};

// ── Test data ───────────────────────────────────────────────────────────

/// Valid minimal wasm module (just header).
const valid_empty_module = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
};

/// Bad magic number.
const bad_magic = [_]u8{
    0x00, 0x00, 0x00, 0x00, // wrong magic
    0x01, 0x00, 0x00, 0x00, // version 1
};

/// Bad version.
const bad_version = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x02, 0x00, 0x00, 0x00, // version 2 (invalid)
};

/// Truncated — only 4 bytes (missing version).
const truncated = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic only
};

/// Module with an export referencing a non-existent function.
const bad_export_index = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
    // Export section (id=7)
    0x07, 0x07, // section id=7, size=7
    0x01, // 1 export
    0x03, 0x62, 0x61, 0x64, // "bad"
    0x00, // kind = func
    0x63, // func index 99 (out of range)
};

/// Module with duplicate export names.
const duplicate_exports = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
    // Memory section (id=5)
    0x05, 0x03, // section id=5, size=3
    0x01, // 1 memory
    0x00, 0x01, // limits: no max, initial=1
    // Export section (id=7)
    0x07, 0x0d, // section id=7, size=13
    0x02, // 2 exports
    0x03, 0x6d, 0x65, 0x6d, // "mem"
    0x02, // kind = memory
    0x00, // memory index 0
    0x03, 0x6d, 0x65, 0x6d, // "mem" (duplicate)
    0x02, // kind = memory
    0x00, // memory index 0
};

/// Module with two memories (no multi-memory feature).
const two_memories = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
    // Memory section (id=5)
    0x05, 0x05, // section id=5, size=5
    0x02, // 2 memories
    0x00, 0x01, // limits: no max, initial=1
    0x00, 0x02, // limits: no max, initial=2
};

/// Valid module with memory + export.
const valid_mem_export = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
    // Memory section (id=5)
    0x05, 0x03, // section id=5, size=3
    0x01, // 1 memory
    0x00, 0x01, // limits: no max, initial=1
    // Export section (id=7)
    0x07, 0x07, // section id=7, size=7
    0x01, // 1 export
    0x03, 0x6d, 0x65, 0x6d, // "mem"
    0x02, // kind = memory
    0x00, // memory index 0
};

// ── Tests ───────────────────────────────────────────────────────────────

test "assert_malformed: bad magic" {
    const result = assertMalformed(std.testing.allocator, &bad_magic);
    try std.testing.expectEqual(AssertResult.pass, result);
}

test "assert_malformed: bad version" {
    const result = assertMalformed(std.testing.allocator, &bad_version);
    try std.testing.expectEqual(AssertResult.pass, result);
}

test "assert_malformed: truncated" {
    const result = assertMalformed(std.testing.allocator, &truncated);
    try std.testing.expectEqual(AssertResult.pass, result);
}

test "assert_invalid: bad export index" {
    const result = assertInvalid(std.testing.allocator, &bad_export_index);
    try std.testing.expectEqual(AssertResult.pass, result);
}

test "assert_invalid: duplicate exports" {
    const result = assertInvalid(std.testing.allocator, &duplicate_exports);
    try std.testing.expectEqual(AssertResult.pass, result);
}

test "assert_invalid: too many memories" {
    const result = assertInvalidWithOptions(std.testing.allocator, &two_memories, .{ .features = .{ .multi_memory = false } });
    try std.testing.expectEqual(AssertResult.pass, result);
}

test "valid module passes validation" {
    const allocator = std.testing.allocator;

    var module = try binary_reader.readModule(allocator, &valid_mem_export);
    defer module.deinit();

    try Validator.validate(&module, .{});

    try std.testing.expectEqual(@as(usize, 1), module.memories.items.len);
    try std.testing.expectEqual(@as(usize, 1), module.exports.items.len);
}

test "Suite runner tallies results" {
    var suite = Suite{};

    suite.run("malformed magic", assertMalformed(std.testing.allocator, &bad_magic));
    suite.run("malformed version", assertMalformed(std.testing.allocator, &bad_version));
    suite.run("malformed truncated", assertMalformed(std.testing.allocator, &truncated));
    suite.run("invalid bad export", assertInvalid(std.testing.allocator, &bad_export_index));
    suite.run("invalid duplicate exports", assertInvalid(std.testing.allocator, &duplicate_exports));
    suite.run("invalid too many memories", assertInvalidWithOptions(std.testing.allocator, &two_memories, .{ .features = .{ .multi_memory = false } }));

    // A valid module should *fail* the assertInvalid check
    suite.run("valid should fail assert_invalid", assertInvalid(std.testing.allocator, &valid_empty_module));

    // Tally: 6 pass (malformed/invalid) + 1 fail (valid module didn't fail)
    try std.testing.expectEqual(@as(u32, 6), suite.passed);
    try std.testing.expectEqual(@as(u32, 1), suite.failed);
    try std.testing.expectEqual(@as(u32, 0), suite.skipped);
}
