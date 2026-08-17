const std = @import("std");
const Feature = @import("Feature.zig");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const binary_instr = @import("binary/instr.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");
const text_writer = @import("text/Writer.zig");

const corpus_json = @embedFile("fixtures/typed-select-regression/corpus.json");

const ValidCase = struct {
    name: []const u8,
    family: []const u8,
    printed: ?[]const u8 = null,
    wat: []const u8,
};

const InvalidWatCase = struct {
    name: []const u8,
    family: []const u8,
    stage: []const u8,
    wabt_error: []const u8,
    wat: []const u8,
};

const BinaryCase = struct {
    name: []const u8,
    family: []const u8,
    printed: ?[]const u8 = null,
    type_index: u32 = 0,
    type_kind: []const u8 = "func",
    body_hex: []const u8,
};

const FeatureGateCase = struct {
    name: []const u8,
    gate: []const u8,
    wat: []const u8,
};

const InvalidBinaryCase = struct {
    name: []const u8,
    family: []const u8,
    validator_error: []const u8,
    binary_error: []const u8,
    scanner_error: ?[]const u8 = null,
    type_index: u32 = 0,
    type_kind: []const u8 = "func",
    body_hex: []const u8,
};

const Corpus = struct {
    version: u32,
    feature_gates: []FeatureGateCase,
    valid: []ValidCase,
    invalid_wat: []InvalidWatCase,
    valid_binary: []BinaryCase,
    invalid_binary: []InvalidBinaryCase,
};

fn parseCorpus(allocator: std.mem.Allocator) !std.json.Parsed(Corpus) {
    return std.json.parseFromSlice(Corpus, allocator, corpus_json, .{});
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn featureGateEnabled(gate: []const u8, features: Feature.Set) ?bool {
    if (std.mem.eql(u8, gate, "reference-types"))
        return features.reference_types;
    if (std.mem.eql(u8, gate, "function-references"))
        return features.reference_types and features.function_references;
    if (std.mem.eql(u8, gate, "gc"))
        return features.reference_types and features.gc;
    if (std.mem.eql(u8, gate, "exceptions"))
        return features.reference_types and features.exceptions;
    if (std.mem.eql(u8, gate, "function-references-or-gc"))
        return features.reference_types and
            (features.function_references or features.gc);
    return null;
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

fn appendTestType(
    module: *Mod.Module,
    allocator: std.mem.Allocator,
    kind: []const u8,
    type_index: u32,
) !void {
    var meta = Mod.TypeMeta{};
    const entry: Mod.TypeEntry = if (std.mem.eql(u8, kind, "func")) blk: {
        meta.kind = .func;
        break :blk .{ .func_type = .{} };
    } else if (std.mem.eql(u8, kind, "struct")) blk: {
        meta.kind = .struct_;
        break :blk .{ .struct_type = .{ .fields = .empty } };
    } else if (std.mem.eql(u8, kind, "array")) blk: {
        meta.kind = .array;
        break :blk .{ .array_type = .{
            .field = .{ .type = .i32 },
        } };
    } else if (std.mem.eql(u8, kind, "recursive-struct")) blk: {
        var fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
        errdefer fields.deinit(allocator);
        try fields.append(allocator, .{
            .type = .concrete_ref_null,
            .type_idx = type_index,
        });
        meta = .{
            .kind = .struct_,
            .in_rec_group = true,
            .rec_group = type_index,
            .rec_group_size = 1,
            .rec_position = 0,
        };
        break :blk .{ .struct_type = .{ .fields = fields } };
    } else {
        return error.InvalidTypeKind;
    };
    try module.module_types.append(allocator, entry);
    try module.type_meta.append(allocator, meta);
}

fn moduleWithBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    type_index: u32,
    type_kind: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(allocator);
    errdefer module.deinit();
    var func_type_idx: ?u32 = null;
    for (0..@as(usize, type_index) + 1) |i| {
        const kind = if (i == type_index) type_kind else "func";
        try appendTestType(&module, allocator, kind, @intCast(i));
        if (func_type_idx == null and std.mem.eql(u8, kind, "func"))
            func_type_idx = @intCast(i);
    }
    if (func_type_idx == null) {
        func_type_idx = @intCast(module.module_types.items.len);
        try appendTestType(&module, allocator, "func", func_type_idx.?);
    }
    try module.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = func_type_idx.? } },
        .code_bytes = body,
    });
    return module;
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

fn expectSerializedError(
    expected: []const u8,
    allocator: std.mem.Allocator,
    wasm: []const u8,
) !void {
    var module = binary_reader.readModule(allocator, wasm) catch |err| {
        try std.testing.expectEqualStrings(expected, @errorName(err));
        return;
    };
    defer module.deinit();
    try expectValidationError(expected, &module, .{});
}

fn countTypedSelects(module: *const Mod.Module) !usize {
    var count: usize = 0;
    for (module.funcs.items[module.num_func_imports..]) |func| {
        var pos: usize = 0;
        while (pos < func.code_bytes.len) {
            const decoded = try binary_instr.decode(func.code_bytes, &pos);
            try binary_instr.skipImmediates(decoded.shape, func.code_bytes, &pos);
            if (decoded.prefix == 0 and decoded.code == 0x1c) count += 1;
        }
    }
    return count;
}

fn expectScannerError(expected: []const u8, body: []const u8) !void {
    var pos: usize = 0;
    while (pos < body.len) {
        const decoded = binary_instr.decode(body, &pos) catch |err| {
            try std.testing.expectEqualStrings(expected, @errorName(err));
            return;
        };
        binary_instr.skipImmediates(decoded.shape, body, &pos) catch |err| {
            try std.testing.expectEqualStrings(expected, @errorName(err));
            return;
        };
    }
    return error.TestUnexpectedResult;
}

fn expectTextWriterError(expected: []const u8, module: *const Mod.Module) !void {
    if (text_writer.writeModule(std.testing.allocator, module)) |wat| {
        std.testing.allocator.free(wat);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqualStrings(expected, @errorName(err));
        return;
    }
}

test "typed select corpus validates and round-trips end to end" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);

    for (parsed.value.valid) |case| {
        try std.testing.expect(case.name.len > 0);
        try std.testing.expect(case.family.len > 0);
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try Validator.validate(&module, .{});
        try std.testing.expectEqual(@as(usize, 1), try countTypedSelects(&module));

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try Validator.validate(&decoded, .{});
        try std.testing.expectEqual(@as(usize, 1), try countTypedSelects(&decoded));

        const printed = try text_writer.writeModule(allocator, &decoded);
        defer allocator.free(printed);
        try std.testing.expect(contains(printed, "select (result "));
        if (case.printed) |fragment|
            try std.testing.expect(contains(printed, fragment));

        var reparsed = try text_parser.parseModule(allocator, printed);
        defer reparsed.deinit();
        try Validator.validate(&reparsed, .{});
        const rebuilt = try binary_writer.writeModule(allocator, &reparsed);
        defer allocator.free(rebuilt);
        var reread = try binary_reader.readModule(allocator, rebuilt);
        defer reread.deinit();
        try Validator.validate(&reread, .{});
        try std.testing.expectEqual(@as(usize, 1), try countTypedSelects(&reread));
    }
}

test "typed select invalid WAT rejects at parsing or validation" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();

    for (parsed.value.invalid_wat) |case| {
        if (std.mem.eql(u8, case.stage, "parse")) {
            if (text_parser.parseModule(allocator, case.wat)) |module_value| {
                var module = module_value;
                module.deinit();
                return error.TestUnexpectedResult;
            } else |err| {
                try std.testing.expectEqualStrings(case.wabt_error, @errorName(err));
                continue;
            }
        }
        try std.testing.expectEqualStrings("validation", case.stage);
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try expectValidationError(case.wabt_error, &module, .{});
    }
}

test "typed select binary vectors scan validate and print correctly" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();

    for (parsed.value.valid_binary) |case| {
        const body = try decodeHex(allocator, case.body_hex);
        defer allocator.free(body);
        var module = try moduleWithBody(
            allocator,
            body,
            case.type_index,
            case.type_kind,
        );
        defer module.deinit();
        try Validator.validate(&module, .{});
        try std.testing.expectEqual(@as(usize, 1), try countTypedSelects(&module));

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try Validator.validate(&decoded, .{});

        const printed = try text_writer.writeModule(allocator, &decoded);
        defer allocator.free(printed);
        if (case.printed) |fragment|
            try std.testing.expect(contains(printed, fragment));
        var reparsed = try text_parser.parseModule(allocator, printed);
        defer reparsed.deinit();
        try Validator.validate(&reparsed, .{});
        const rebuilt = try binary_writer.writeModule(allocator, &reparsed);
        defer allocator.free(rebuilt);
        var reread = try binary_reader.readModule(allocator, rebuilt);
        defer reread.deinit();
        try Validator.validate(&reread, .{});
        const reprinted = try text_writer.writeModule(allocator, &reread);
        defer allocator.free(reprinted);
        if (case.printed) |fragment|
            try std.testing.expect(contains(reprinted, fragment));
    }
}

test "typed select malformed binary vectors reject deterministically" {
    const allocator = std.testing.allocator;
    var parsed = try parseCorpus(allocator);
    defer parsed.deinit();

    for (parsed.value.invalid_binary) |case| {
        const body = try decodeHex(allocator, case.body_hex);
        defer allocator.free(body);
        var module = try moduleWithBody(
            allocator,
            body,
            case.type_index,
            case.type_kind,
        );
        defer module.deinit();
        try expectValidationError(case.validator_error, &module, .{});
        if (case.scanner_error) |expected| {
            try expectScannerError(expected, body);
            try expectTextWriterError(expected, &module);
        }

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        try expectSerializedError(case.binary_error, allocator, wasm);
    }
}

test "typed select enforces proposal gates on its declared type" {
    const allocator = std.testing.allocator;
    const numeric =
        "(module (func (result i32) i32.const 1 i32.const 2 i32.const 0 " ++
        "select (result i32)))";
    var numeric_module = try text_parser.parseModule(allocator, numeric);
    defer numeric_module.deinit();
    try expectValidationError(
        "UnsupportedOpcode",
        &numeric_module,
        .{ .features = .{ .reference_types = false } },
    );
    try Validator.validate(
        &numeric_module,
        .{ .features = .{ .multi_value = false } },
    );

    var vector_module = try text_parser.parseModule(
        allocator,
        "(module (func (result v128) unreachable select (result v128)))",
    );
    defer vector_module.deinit();
    try expectValidationError(
        "UnsupportedOpcode",
        &vector_module,
        .{ .features = .{ .simd = false } },
    );

    var corpus = try parseCorpus(allocator);
    defer corpus.deinit();
    for (corpus.value.feature_gates) |case| {
        try std.testing.expect(case.name.len > 0);
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();

        for (0..16) |bits| {
            var features = Feature.Set{};
            features.reference_types = (bits & 0x1) != 0;
            features.function_references = (bits & 0x2) != 0;
            features.gc = (bits & 0x4) != 0;
            features.exceptions = (bits & 0x8) != 0;
            const enabled = featureGateEnabled(case.gate, features) orelse
                return error.TestUnexpectedResult;
            if (enabled) {
                try Validator.validate(&module, .{ .features = features });
            } else {
                try expectValidationError(
                    "UnsupportedOpcode",
                    &module,
                    .{ .features = features },
                );
            }
        }
    }
}
