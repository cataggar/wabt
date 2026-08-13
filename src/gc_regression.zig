const std = @import("std");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const binary_instr = @import("binary/instr.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");
const text_writer = @import("text/Writer.zig");

const corpus_json = @embedFile("fixtures/gc-regression/corpus.json");
const gc_subopcode_count = 0x1f;

const ValidCase = struct {
    name: []const u8,
    family: []const u8,
    subopcodes: []u32,
    wat: []const u8,
};

const InvalidWatCase = struct {
    name: []const u8,
    family: []const u8,
    wabt_error: []const u8,
    wat: []const u8,
};

const InvalidBinaryCase = struct {
    name: []const u8,
    family: []const u8,
    wabt_error: []const u8,
    binary_error: []const u8,
    body_hex: []const u8,
};

const Corpus = struct {
    version: u32,
    valid: []ValidCase,
    invalid_wat: []InvalidWatCase,
    invalid_binary: []InvalidBinaryCase,
};

fn parseCorpus(allocator: std.mem.Allocator) !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, allocator, corpus_json, .{});
}

fn expectValidationError(
    expected: []const u8,
    module: *const Mod.Module,
    options: Validator.Options,
) !void {
    Validator.validate(module, options) catch |err| {
        try std.testing.expectEqualStrings(expected, @errorName(err));
        return;
    };
    return error.TestUnexpectedResult;
}

fn collectGcSubopcodes(module: *const Mod.Module, counts: *[gc_subopcode_count]u8) !void {
    for (module.funcs.items[module.num_func_imports..]) |func| {
        var pos: usize = 0;
        while (pos < func.code_bytes.len) {
            const decoded = try binary_instr.decode(func.code_bytes, &pos);
            if (decoded.prefix == 0xfb) {
                try std.testing.expect(decoded.code < gc_subopcode_count);
                const sub: usize = @intCast(decoded.code);
                try std.testing.expect(counts[sub] < std.math.maxInt(u8));
                counts[sub] += 1;
            }
            try binary_instr.skipImmediates(decoded.shape, func.code_bytes, &pos);
        }
    }
}

fn moduleWithBody(allocator: std.mem.Allocator, body: []const u8) !Mod.Module {
    var module = Mod.Module.init(allocator);
    errdefer module.deinit();
    try module.module_types.append(allocator, .{ .func_type = .{} });
    try module.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = body,
    });
    return module;
}

fn decodeHex(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (source.len % 2 != 0) return error.InvalidHex;
    const bytes = try allocator.alloc(u8, source.len / 2);
    errdefer allocator.free(bytes);
    for (bytes, 0..) |*byte, i| {
        const high = try std.fmt.charToDigit(source[i * 2], 16);
        const low = try std.fmt.charToDigit(source[i * 2 + 1], 16);
        byte.* = high << 4 | low;
    }
    return bytes;
}

fn expectSerializedError(expected: []const u8, allocator: std.mem.Allocator, wasm: []const u8) !void {
    var module = binary_reader.readModule(allocator, wasm) catch |err| {
        try std.testing.expectEqualStrings(expected, @errorName(err));
        return;
    };
    defer module.deinit();
    try expectValidationError(expected, &module, .{});
}

test "GC regression corpus covers every core subopcode end to end" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);

    var expected_counts = [_]u8{0} ** gc_subopcode_count;
    var binary_counts = [_]u8{0} ** gc_subopcode_count;

    for (parsed.value.valid) |case| {
        try std.testing.expect(case.name.len > 0);
        try std.testing.expect(case.family.len > 0);

        var case_expected = [_]bool{false} ** gc_subopcode_count;
        for (case.subopcodes) |sub| {
            try std.testing.expect(sub < gc_subopcode_count);
            try std.testing.expect(!case_expected[sub]);
            case_expected[sub] = true;
            expected_counts[sub] += 1;
        }

        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try Validator.validate(&module, .{});
        try expectValidationError(
            "UnsupportedOpcode",
            &module,
            .{ .features = .{ .gc = false } },
        );

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try Validator.validate(&decoded, .{});

        var case_actual = [_]u8{0} ** gc_subopcode_count;
        try collectGcSubopcodes(&decoded, &case_actual);
        for (case_actual, 0..) |count, sub| {
            try std.testing.expectEqual(@as(u8, if (case_expected[sub]) 1 else 0), count);
            binary_counts[sub] += count;
        }

        const printed = try text_writer.writeModule(allocator, &decoded);
        defer allocator.free(printed);
        var reparsed = try text_parser.parseModule(allocator, printed);
        defer reparsed.deinit();
        try Validator.validate(&reparsed, .{});

        const rebuilt = try binary_writer.writeModule(allocator, &reparsed);
        defer allocator.free(rebuilt);
        var reread = try binary_reader.readModule(allocator, rebuilt);
        defer reread.deinit();
        try Validator.validate(&reread, .{});
    }

    for (0..gc_subopcode_count) |sub| {
        try std.testing.expectEqual(@as(u8, 1), expected_counts[sub]);
        try std.testing.expectEqual(@as(u8, 1), binary_counts[sub]);
    }
}

test "GC regression invalid WAT spans semantic families" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();

    for (parsed.value.invalid_wat) |case| {
        try std.testing.expect(case.name.len > 0);
        try std.testing.expect(case.family.len > 0);
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try expectValidationError(case.wabt_error, &module, .{});
    }
}

test "GC regression malformed binary immediates fail IR and serialized validation" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();

    for (parsed.value.invalid_binary) |case| {
        try std.testing.expect(case.name.len > 0);
        try std.testing.expect(case.family.len > 0);
        const body = try decodeHex(allocator, case.body_hex);
        defer allocator.free(body);

        var module = try moduleWithBody(allocator, body);
        defer module.deinit();
        try expectValidationError(case.wabt_error, &module, .{});

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        try expectSerializedError(case.binary_error, allocator, wasm);
    }
}
