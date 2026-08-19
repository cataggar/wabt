const std = @import("std");
const Feature = @import("Feature.zig");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");
const text_writer = @import("text/Writer.zig");
const types = @import("types.zig");

const GateCase = struct {
    name: []const u8,
    wat: []const u8,
    features: Feature.Set,
    error_: Validator.Error,
};

fn without(comptime feature: []const u8) Feature.Set {
    var features = Feature.Set{};
    @field(features, feature) = false;
    return features;
}

fn expectValidationError(
    expected: Validator.Error,
    module: *const Mod.Module,
    features: Feature.Set,
) !void {
    try std.testing.expectError(
        expected,
        Validator.validate(module, .{ .features = features }),
    );
}

fn expectAcceptedTextAndBinary(wat: []const u8, features: Feature.Set) !void {
    const allocator = std.testing.allocator;
    var module = try text_parser.parseModule(allocator, wat);
    defer module.deinit();
    try Validator.validate(&module, .{ .features = features });

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try Validator.validate(&decoded, .{ .features = features });
}

fn expectRejectedTextAndBinary(
    expected: Validator.Error,
    wat: []const u8,
    features: Feature.Set,
) !void {
    const allocator = std.testing.allocator;
    var module = try text_parser.parseModule(allocator, wat);
    defer module.deinit();
    try expectValidationError(expected, &module, features);

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try expectValidationError(expected, &decoded, features);
}

test "declaration feature gates cover every module surface" {
    const allocator = std.testing.allocator;
    const cases = [_]GateCase{
        .{
            .name = "dead-v128-type",
            .wat = "(module (type (func (param v128))))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "imported-v128-param",
            .wat = "(module (import \"m\" \"f\" (func (param v128))))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "defined-v128-param",
            .wat = "(module (func (param v128)))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "v128-local",
            .wat = "(module (func (local v128)))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "externref-table",
            .wat = "(module (table 1 externref))",
            .features = without("reference_types"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "imported-externref-table",
            .wat = "(module (import \"m\" \"t\" (table 1 externref)))",
            .features = without("reference_types"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "defined-table64",
            .wat = "(module (table i64 1 funcref))",
            .features = without("memory64"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "imported-table64",
            .wat = "(module (import \"m\" \"t\" (table i64 1 funcref)))",
            .features = without("memory64"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "v128-global-and-constant",
            .wat = "(module (global v128 (v128.const i32x4 0 0 0 0)))",
            .features = without("simd"),
            .error_ = error.ConstantExprRequired,
        },
        .{
            .name = "imported-v128-global",
            .wat = "(module (import \"m\" \"g\" (global v128)))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "v128-block-result",
            .wat = "(module (func (block (result v128) unreachable) drop))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "tag-declaration",
            .wat = "(module (tag))",
            .features = without("exceptions"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "imported-tag-declaration",
            .wat = "(module (import \"m\" \"e\" (tag)))",
            .features = without("exceptions"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "tag-v128-param",
            .wat = "(module (tag (param v128)))",
            .features = without("simd"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "element-expression-type",
            .wat = "(module (elem funcref))",
            .features = without("reference_types"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "dead-struct-type",
            .wat = "(module (type (struct)))",
            .features = without("gc"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "dead-array-type",
            .wat = "(module (type (array i32)))",
            .features = without("gc"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "recursive-concrete-struct",
            .wat = "(module (rec " ++
                "(type $s (struct (field (ref null $s))))))",
            .features = without("gc"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "function-subtype",
            .wat = "(module (type (sub (func))))",
            .features = without("gc"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "final-function-subtype",
            .wat = "(module (type (sub final (func))))",
            .features = without("gc"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "recursive-function-type",
            .wat = "(module (rec (type (func))))",
            .features = without("gc"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "multi-result-function",
            .wat = "(module (type (func (result i32 i64))))",
            .features = without("multi_value"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "block-parameter",
            .wat = "(module (type $t (func (param i32))) " ++
                "(func i32.const 0 (block (type $t) drop)))",
            .features = without("multi_value"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "imported-mutable-global",
            .wat = "(module (import \"m\" \"g\" (global (mut i32))))",
            .features = without("mutable_globals"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "exported-mutable-global",
            .wat = "(module (global (export \"g\") (mut i32) (i32.const 0)))",
            .features = without("mutable_globals"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "passive-data",
            .wat = "(module (data \"x\"))",
            .features = without("bulk_memory"),
            .error_ = error.UnsupportedOpcode,
        },
        .{
            .name = "empty-passive-data",
            .wat = "(module (data \"\"))",
            .features = without("bulk_memory"),
            .error_ = error.UnsupportedOpcode,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("declaration gate case failed: {s}\n", .{case.name});
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try Validator.validate(&module, .{});
        try expectValidationError(case.error_, &module, case.features);

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try Validator.validate(&decoded, .{});
        try expectValidationError(case.error_, &decoded, case.features);
    }
}

test "reference declaration gates preserve raw feature combinations" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        wat: []const u8,
        features: Feature.Set,
        enabled: bool,
    }{
        .{
            .name = "nullable-abstract-func-needs-only-reference-types",
            .wat = "(module (type (func (param (ref null func)))))",
            .features = .{
                .reference_types = true,
                .function_references = false,
                .gc = false,
            },
            .enabled = true,
        },
        .{
            .name = "nonnull-abstract-func-needs-function-references",
            .wat = "(module (type (func (param (ref func)))))",
            .features = .{
                .reference_types = true,
                .function_references = false,
                .gc = true,
            },
            .enabled = false,
        },
        .{
            .name = "concrete-func-allows-gc",
            .wat = "(module (type $f (func)) " ++
                "(type (func (param (ref null $f)))))",
            .features = .{
                .reference_types = true,
                .function_references = false,
                .gc = true,
            },
            .enabled = true,
        },
        .{
            .name = "concrete-func-needs-function-references-or-gc",
            .wat = "(module (type $f (func)) " ++
                "(type (func (param (ref null $f)))))",
            .features = .{
                .reference_types = true,
                .function_references = false,
                .gc = false,
            },
            .enabled = false,
        },
        .{
            .name = "exception-ref-needs-reference-types-too",
            .wat = "(module (type (func (param exnref))))",
            .features = .{
                .reference_types = false,
                .exceptions = true,
            },
            .enabled = false,
        },
    };

    for (cases) |case| {
        errdefer std.debug.print("raw feature case failed: {s}\n", .{case.name});
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        if (case.enabled) {
            try Validator.validate(&module, .{ .features = case.features });
        } else {
            try expectValidationError(error.UnsupportedOpcode, &module, case.features);
        }
    }
}

test "MVP declaration exceptions match wasm-tools" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        "(module (table 1 funcref))",
        "(module (func) (table 1 funcref) " ++
            "(elem (i32.const 0) func 0))",
        "(module (global (mut i32) (i32.const 0)))",
    };
    for (cases) |wat| {
        var module = try text_parser.parseModule(allocator, wat);
        defer module.deinit();
        try Validator.validate(&module, .{
            .features = .{
                .reference_types = false,
                .mutable_globals = false,
            },
        });
    }
}

test "indexed block signatures always require multi-value" {
    const indexed = [_][]const u8{
        "(module (type $t (func)) (func (block (type $t))))",
        "(module (type $t (func (result i32))) " ++
            "(func (block (type $t) i32.const 0) drop))",
        "(module (type $t (func (param i32))) " ++
            "(func i32.const 0 (block (type $t) drop)))",
        "(module (type $t (func (result i32 i64))) " ++
            "(func (block (type $t) i32.const 0 i64.const 0) drop drop))",
    };
    for (indexed) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(
            error.UnsupportedOpcode,
            wat,
            without("multi_value"),
        );
    }

    // The inline empty and single-value encodings are MVP blocktypes, even
    // when an identical function type happens to exist in the type section.
    try expectAcceptedTextAndBinary(
        "(module (type (func (result i32))) " ++
            "(func (block (result i32) i32.const 0) drop (block)))",
        without("multi_value"),
    );
}

test "indexed block signatures retain malformed precedence" {
    const allocator = std.testing.allocator;
    var module = Mod.Module.init(allocator);
    defer module.deinit();
    try module.module_types.append(allocator, .{ .func_type = .{} });

    try module.funcs.append(allocator, .{
        .decl = .{ .type_var = .{ .index = 0 } },
        .code_bytes = &.{ 0x02, 0x01, 0x0b, 0x0b },
    });
    try expectValidationError(
        error.InvalidTypeIndex,
        &module,
        without("multi_value"),
    );

    module.funcs.items[0].code_bytes = &.{ 0x02, 0x80 };
    try expectValidationError(
        error.UnexpectedEnd,
        &module,
        without("multi_value"),
    );
}

test "recursive concrete function references require GC" {
    const function_references_only = Feature.Set{
        .reference_types = true,
        .function_references = true,
        .gc = false,
    };
    const gc_only = Feature.Set{
        .reference_types = true,
        .function_references = false,
        .gc = true,
    };

    const recursive = [_][]const u8{
        // A standalone type is an implicit singleton recursion group.
        "(module (type $f (func (param (ref null $f)))))",
        "(module (rec (type $f (func (param (ref null $f))))))",
        "(module (rec " ++
            "(type $a (func (param (ref null $b)))) " ++
            "(type $b (func (param (ref null $a))))))",
        "(module (type $s (struct (field (ref null $s)))))",
        "(module (type $a (array (ref null $a))))",
    };
    for (recursive) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(
            error.UnsupportedOpcode,
            wat,
            function_references_only,
        );
    }

    // GC itself is sufficient for a concrete function reference.
    try expectAcceptedTextAndBinary(recursive[0], gc_only);

    // A reference to a function type in an earlier recursion group is not
    // recursive and remains a function-references use.
    const backward =
        "(module (type $a (func)) " ++
        "(type $b (func (param (ref null $a)))))";
    try expectAcceptedTextAndBinary(backward, function_references_only);
    try expectRejectedTextAndBinary(
        error.UnsupportedOpcode,
        backward,
        .{
            .reference_types = true,
            .function_references = false,
            .gc = false,
        },
    );
}

test "forward concrete references cannot cross recursion groups" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidModule,
        text_parser.parseModule(
            allocator,
            "(module (type $a (func (param (ref null $b)))) " ++
                "(type $b (func)))",
        ),
    );

    // The binary reader can retain the complete type section before the
    // validator sees it, so validate the source-group ordering explicitly.
    var module = Mod.Module.init(allocator);
    defer module.deinit();
    const params = try allocator.dupe(types.ValType, &.{.concrete_ref_null});
    const param_idxs = try allocator.dupe(u32, &.{1});
    try module.module_types.append(allocator, .{ .func_type = .{
        .params = params,
        .param_type_idxs = param_idxs,
    } });
    try module.type_meta.append(allocator, .{});
    try module.module_types.append(allocator, .{ .func_type = .{} });
    try module.type_meta.append(allocator, .{});
    try expectValidationError(error.InvalidTypeIndex, &module, Feature.Set{});

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try expectValidationError(error.InvalidTypeIndex, &decoded, Feature.Set{});
}

test "declared supertypes must precede their subtypes" {
    const invalid = [_][]const u8{
        "(module (type (sub 0 (func))))",
        "(module (type (sub 1 (func))) (type (sub (func))))",
    };
    for (invalid) |wat|
        try expectRejectedTextAndBinary(
            error.InvalidTypeIndex,
            wat,
            Feature.Set{},
        );

    const valid = [_][]const u8{
        "(module (type (sub (func))) (type (sub 0 (func))))",
        "(module (rec (type (sub (func))) (type (sub 0 (func)))))",
    };
    for (valid) |wat|
        try expectAcceptedTextAndBinary(wat, Feature.Set{});

    // Ordering is diagnosed before finality, kind, or structural subtyping.
    try expectRejectedTextAndBinary(
        error.InvalidTypeIndex,
        "(module (type (sub 1 (func))) (type (sub final (struct))))",
        Feature.Set{},
    );

    // Programmatic modules receive the same bounds-and-order check.
    const allocator = std.testing.allocator;
    var module = Mod.Module.init(allocator);
    defer module.deinit();
    try module.module_types.append(allocator, .{ .func_type = .{} });
    try module.type_meta.append(allocator, .{
        .is_sub = true,
        .is_final = false,
        .parent = 9,
    });
    try expectValidationError(error.InvalidTypeIndex, &module, Feature.Set{});
}

test "table expression initializers require function references" {
    const no_function_references = Feature.Set{
        .reference_types = true,
        .function_references = false,
        .gc = true,
    };
    const cases = [_][]const u8{
        "(module (table 1 funcref (ref.null func)))",
        "(module (func $f) (elem declare func $f) " ++
            "(table 1 funcref (ref.func $f)))",
        "(module (type $f (func)) " ++
            "(table 1 (ref null $f) (ref.null $f)))",
    };
    for (cases) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(
            error.UnsupportedOpcode,
            wat,
            no_function_references,
        );
    }

    const mvp_features = Feature.Set{
        .reference_types = false,
        .function_references = false,
        .gc = false,
        .exceptions = false,
    };
    try expectAcceptedTextAndBinary(
        "(module (table 1 funcref))",
        mvp_features,
    );
    try expectAcceptedTextAndBinary(
        "(module (import \"m\" \"t\" (table 1 funcref)))",
        mvp_features,
    );
}

test "table64 declarations require memory64" {
    const allocator = std.testing.allocator;
    const no_memory64 = without("memory64");
    const table64 = [_][]const u8{
        "(module (table i64 1 funcref))",
        "(module (import \"m\" \"t\" (table i64 1 funcref)))",
        "(module (func) (table i64 1 funcref) " ++
            "(elem (table 0) (i64.const 0) func 0))",
    };
    for (table64) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(
            error.UnsupportedOpcode,
            wat,
            no_memory64,
        );
    }

    const table32 = [_][]const u8{
        "(module (table 1 funcref))",
        "(module (import \"m\" \"t\" (table 1 funcref)))",
        "(module (func) (table 1 funcref) " ++
            "(elem (i32.const 0) func 0))",
    };
    for (table32) |wat|
        try expectAcceptedTextAndBinary(wat, no_memory64);

    // Programmatic modules must use the limits, not the parser-only mirror.
    var module = Mod.Module.init(allocator);
    defer module.deinit();
    try module.tables.append(allocator, .{ .type = .{
        .elem_type = .funcref,
        .limits = .{ .initial = 1, .is_64 = true },
    } });
    try expectValidationError(
        error.UnsupportedOpcode,
        &module,
        no_memory64,
    );

    // Structural limit errors are diagnosed before the proposal gate.
    module.tables.items[0].type.limits = .{
        .initial = 2,
        .max = 1,
        .has_max = true,
        .is_64 = true,
    };
    try expectValidationError(error.InvalidLimits, &module, no_memory64);

    module.tables.items[0].type.limits = .{ .initial = 1 };
    module.tables.items[0].is_table64 = true;
    try Validator.validate(&module, .{ .features = no_memory64 });

    // With the proposal enabled, the offset follows the table's index type;
    // when it is disabled, the declaration gate is reported first.
    var wrong_offset = try text_parser.parseModule(
        allocator,
        "(module (func) (table i64 1 funcref) " ++
            "(elem (table 0) (i32.const 0) func 0))",
    );
    defer wrong_offset.deinit();
    try expectValidationError(error.TypeMismatch, &wrong_offset, Feature.Set{});
    try expectValidationError(
        error.UnsupportedOpcode,
        &wrong_offset,
        no_memory64,
    );
}

test "table initializer presence survives empty bodies and round trips" {
    const allocator = std.testing.allocator;
    const end_only = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x07, 0x01, 0x40, 0x00, 0x70, 0x00, 0x01,
        0x0b,
    };
    var empty = try binary_reader.readModule(allocator, &end_only);
    defer empty.deinit();
    try std.testing.expect(empty.tables.items[0].has_init_expr);
    try std.testing.expect(empty.tables.items[0].hasInitExpr());
    try std.testing.expectEqual(@as(usize, 0), empty.tables.items[0].init_expr_bytes.len);
    try expectValidationError(error.TypeMismatch, &empty, Feature.Set{});
    try expectValidationError(
        error.UnsupportedOpcode,
        &empty,
        without("function_references"),
    );

    const encoded = try binary_writer.writeModule(allocator, &empty);
    defer allocator.free(encoded);
    var reread = try binary_reader.readModule(allocator, encoded);
    defer reread.deinit();
    try std.testing.expect(reread.tables.items[0].has_init_expr);
    try std.testing.expectEqual(@as(usize, 0), reread.tables.items[0].init_expr_bytes.len);
    try expectValidationError(error.TypeMismatch, &reread, Feature.Set{});
    try std.testing.expectError(
        error.UnsupportedOpcode,
        text_writer.writeModule(allocator, &empty),
    );

    const valid = [_]struct {
        wat: []const u8,
        is_64: bool,
    }{
        .{ .wat = "(module (table 1 funcref (ref.null func)))", .is_64 = false },
        .{ .wat = "(module (table i64 1 funcref (ref.null func)))", .is_64 = true },
        .{
            .wat = "(module (func $f) (elem declare func $f) " ++
                "(table 1 funcref (ref.func $f)))",
            .is_64 = false,
        },
    };
    for (valid) |case| {
        var parsed = try text_parser.parseModule(allocator, case.wat);
        defer parsed.deinit();
        try std.testing.expect(parsed.tables.items[0].has_init_expr);
        try std.testing.expectEqual(case.is_64, parsed.tables.items[0].type.limits.is_64);
        try Validator.validate(&parsed, .{});

        const wasm = try binary_writer.writeModule(allocator, &parsed);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try std.testing.expect(decoded.tables.items[0].has_init_expr);
        try std.testing.expectEqual(case.is_64, decoded.tables.items[0].type.limits.is_64);
        try std.testing.expectEqual(case.is_64, decoded.tables.items[0].is_table64);
        try Validator.validate(&decoded, .{});

        const printed = try text_writer.writeModule(allocator, &decoded);
        defer allocator.free(printed);
        var reparsed = try text_parser.parseModule(allocator, printed);
        defer reparsed.deinit();
        try std.testing.expect(reparsed.tables.items[0].has_init_expr);
        try std.testing.expectEqual(case.is_64, reparsed.tables.items[0].type.limits.is_64);
        try Validator.validate(&reparsed, .{});

        const reencoded = try binary_writer.writeModule(allocator, &reparsed);
        defer allocator.free(reencoded);
        var roundtripped = try binary_reader.readModule(allocator, reencoded);
        defer roundtripped.deinit();
        try std.testing.expectEqual(case.is_64, roundtripped.tables.items[0].type.limits.is_64);
        try Validator.validate(&roundtripped, .{});
    }

    var shapes = try text_parser.parseModule(
        allocator,
        "(module (type $f (func)) " ++
            "(import \"m\" \"t\" (table 1 (ref $f))) " ++
            "(table funcref (elem)))",
    );
    defer shapes.deinit();
    try std.testing.expect(!shapes.tables.items[0].hasInitExpr());
    try std.testing.expect(!shapes.tables.items[1].hasInitExpr());
    try Validator.validate(&shapes, .{});

    var missing = try text_parser.parseModule(
        allocator,
        "(module (type $f (func)) (table 1 (ref $f)))",
    );
    defer missing.deinit();
    try expectValidationError(error.TypeMismatch, &missing, Feature.Set{});
}

test "element segment kinds enforce bulk memory" {
    const no_bulk = Feature.Set{
        .bulk_memory = false,
        .reference_types = false,
        .function_references = false,
        .gc = false,
        .exceptions = false,
    };
    const no_bulk_with_references = Feature.Set{
        .bulk_memory = false,
        .reference_types = true,
        .function_references = false,
        .gc = false,
    };
    const passive_and_declared = [_][]const u8{
        "(module (func) (elem func 0))",
        "(module (func) (elem declare func 0))",
    };
    for (passive_and_declared) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(error.UnsupportedOpcode, wat, no_bulk);
    }
    const passive_and_declared_expressions = [_][]const u8{
        "(module (elem funcref (ref.null func)))",
        "(module (elem declare funcref (ref.null func)))",
    };
    for (passive_and_declared_expressions) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(
            error.UnsupportedOpcode,
            wat,
            no_bulk_with_references,
        );
    }

    const active = [_][]const u8{
        "(module (func) (table 1 funcref) " ++
            "(elem (i32.const 0) func 0))",
        "(module (import \"m\" \"t\" (table 1 funcref)) (func) " ++
            "(elem (table 0) (i32.const 0) func 0))",
    };
    for (active) |wat|
        try expectAcceptedTextAndBinary(wat, no_bulk);

    // Active expression segments do not use bulk memory, but still use
    // reference types. Passive expression segments need both proposals.
    const active_expression =
        "(module (table 1 funcref) " ++
        "(elem (i32.const 0) funcref (ref.null func)))";
    try expectAcceptedTextAndBinary(
        active_expression,
        no_bulk_with_references,
    );
    try expectAcceptedTextAndBinary(
        "(module (import \"m\" \"t\" (table 1 funcref)) " ++
            "(elem (table 0) (i32.const 0) funcref (ref.null func)))",
        no_bulk_with_references,
    );
    try expectRejectedTextAndBinary(
        error.ConstantExprRequired,
        active_expression,
        no_bulk,
    );
}

test "passive data segments enforce bulk memory by kind" {
    const allocator = std.testing.allocator;
    const no_bulk = without("bulk_memory");
    const passive = [_][]const u8{
        "(module (data \"x\"))",
        "(module (data \"\"))",
    };
    for (passive) |wat| {
        try expectAcceptedTextAndBinary(wat, Feature.Set{});
        try expectRejectedTextAndBinary(
            error.UnsupportedOpcode,
            wat,
            no_bulk,
        );
    }

    const active = [_][]const u8{
        "(module (memory 1) (data (i32.const 0) \"\"))",
        "(module (memory 1) (data (i32.const 0) \"x\"))",
        "(module (memory 1) (memory 1) " ++
            "(data (memory 1) (i32.const 0) \"x\"))",
    };
    for (active) |wat|
        try expectAcceptedTextAndBinary(wat, no_bulk);

    var indexed = try text_parser.parseModule(allocator, active[2]);
    defer indexed.deinit();
    try std.testing.expectEqual(types.SegmentKind.active, indexed.data_segments.items[0].kind);
    try std.testing.expectEqual(@as(types.Index, 1), indexed.data_segments.items[0].memory_var.index);
    const indexed_wasm = try binary_writer.writeModule(allocator, &indexed);
    defer allocator.free(indexed_wasm);
    var decoded_indexed = try binary_reader.readModule(allocator, indexed_wasm);
    defer decoded_indexed.deinit();
    try std.testing.expectEqual(types.SegmentKind.active, decoded_indexed.data_segments.items[0].kind);
    try std.testing.expectEqual(@as(types.Index, 1), decoded_indexed.data_segments.items[0].memory_var.index);
    try Validator.validate(&decoded_indexed, .{ .features = no_bulk });

    var no_count = try text_parser.parseModule(
        allocator,
        "(module (data \"\"))",
    );
    defer no_count.deinit();
    no_count.has_data_count = false;
    try expectValidationError(error.UnsupportedOpcode, &no_count, no_bulk);

    var active_no_count = try text_parser.parseModule(
        allocator,
        "(module (memory 1) (data (i32.const 0) \"\"))",
    );
    defer active_no_count.deinit();
    active_no_count.has_data_count = false;
    try Validator.validate(&active_no_count, .{ .features = no_bulk });

    // A data-count section does not make an active segment passive, and a
    // passive segment still needs bulk memory when that section is absent.
    const active_with_count = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01, 0x0c, 0x01, 0x01,
        0x0b, 0x06, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x00,
    };
    var counted = try binary_reader.readModule(allocator, &active_with_count);
    defer counted.deinit();
    try std.testing.expect(counted.has_data_count);
    try Validator.validate(&counted, .{ .features = no_bulk });

    const passive_without_count = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0b, 0x03, 0x01, 0x01, 0x00,
    };
    var uncounted = try binary_reader.readModule(allocator, &passive_without_count);
    defer uncounted.deinit();
    try std.testing.expect(!uncounted.has_data_count);
    try expectValidationError(
        error.UnsupportedOpcode,
        &uncounted,
        no_bulk,
    );
}

test "data segment structural errors precede bulk memory gates" {
    const allocator = std.testing.allocator;
    const no_bulk = without("bulk_memory");

    var bad_index = Mod.Module.init(allocator);
    defer bad_index.deinit();
    try bad_index.data_segments.append(allocator, .{
        .kind = .active,
        .memory_var = .{ .index = 1 },
        .offset_expr_bytes = &.{ 0x41, 0x00 },
    });
    try expectValidationError(
        error.InvalidMemoryIndex,
        &bad_index,
        no_bulk,
    );

    try bad_index.memories.append(allocator, .{
        .type = .{ .limits = .{ .initial = 1 } },
    });
    bad_index.data_segments.items[0].memory_var.index = 0;
    bad_index.data_segments.items[0].offset_expr_bytes = &.{ 0x41, 0x80 };
    try expectValidationError(error.UnexpectedEnd, &bad_index, no_bulk);

    const invalid_flag = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0b, 0x03, 0x01, 0x03, 0x00,
    };
    try std.testing.expectError(
        error.InvalidSection,
        binary_reader.readModule(allocator, &invalid_flag),
    );

    const bad_count = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0c, 0x01, 0x00, 0x0b, 0x03, 0x01, 0x01, 0x00,
    };
    try std.testing.expectError(
        error.InvalidSection,
        binary_reader.readModule(allocator, &bad_count),
    );
}

test "element segment malformed encodings and indices take precedence" {
    const allocator = std.testing.allocator;
    const invalid_flag = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x09, 0x06, 0x01, 0x08, 0x41, 0x00, 0x0b, 0x00,
    };
    try std.testing.expectError(
        error.InvalidSection,
        binary_reader.readModule(allocator, &invalid_flag),
    );
    const invalid_elem_kind = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x09, 0x04, 0x01, 0x01, 0x01, 0x00,
    };
    try std.testing.expectError(
        error.InvalidSection,
        binary_reader.readModule(allocator, &invalid_elem_kind),
    );

    var module = Mod.Module.init(allocator);
    defer module.deinit();
    var passive = Mod.ElemSegment{
        .kind = .passive,
        .elem_type = .ref_func,
    };
    try passive.elem_var_indices.append(allocator, .{ .index = 7 });
    try module.elem_segments.append(allocator, passive);
    try expectValidationError(
        error.InvalidFuncIndex,
        &module,
        without("bulk_memory"),
    );

    module.elem_segments.items[0].elem_var_indices.items[0].index = 0;
    module.elem_segments.items[0].elem_type = .concrete_ref_null;
    module.elem_segments.items[0].elem_type_idx = 9;
    module.elem_segments.items[0].uses_elem_exprs = true;
    try expectValidationError(
        error.InvalidTypeIndex,
        &module,
        without("bulk_memory"),
    );
}

test "tag result errors retain repository precedence" {
    const allocator = std.testing.allocator;
    var module = try text_parser.parseModule(
        allocator,
        "(module (type $t (func (result v128))) (tag (type $t)))",
    );
    defer module.deinit();
    try expectValidationError(error.TypeMismatch, &module, Feature.Set{});
    try expectValidationError(error.TypeMismatch, &module, without("simd"));
}

fn moduleWithGlobal(
    allocator: std.mem.Allocator,
    value_type: types.ValType,
    init: []const u8,
) !Mod.Module {
    var module = Mod.Module.init(allocator);
    errdefer module.deinit();
    try module.globals.append(allocator, .{
        .type = .{ .val_type = value_type },
        .init_expr_bytes = init,
    });
    return module;
}

test "constant instruction gates and malformed immediates keep precedence" {
    const allocator = std.testing.allocator;
    const wat_cases = [_]GateCase{
        .{
            .name = "v128-const",
            .wat = "(module (global v128 (v128.const i32x4 0 0 0 0)))",
            .features = without("simd"),
            .error_ = error.ConstantExprRequired,
        },
        .{
            .name = "ref-null-func",
            .wat = "(module (global funcref (ref.null func)))",
            .features = without("reference_types"),
            .error_ = error.ConstantExprRequired,
        },
        .{
            .name = "ref-func",
            .wat = "(module (func $f) (elem declare func $f) " ++
                "(global funcref (ref.func $f)))",
            .features = without("reference_types"),
            .error_ = error.ConstantExprRequired,
        },
        .{
            .name = "ref-null-exn",
            .wat = "(module (global exnref (ref.null exn)))",
            .features = without("exceptions"),
            .error_ = error.ConstantExprRequired,
        },
        .{
            .name = "ref-i31",
            .wat = "(module (global i31ref (ref.i31 (i32.const 0))))",
            .features = without("gc"),
            .error_ = error.ConstantExprRequired,
        },
    };

    for (wat_cases) |case| {
        errdefer std.debug.print("constant gate case failed: {s}\n", .{case.name});
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try Validator.validate(&module, .{});
        try expectValidationError(case.error_, &module, case.features);
    }

    const malformed = [_]struct {
        value_type: types.ValType,
        init: []const u8,
        features: Feature.Set,
        error_: Validator.Error,
    }{
        .{
            .value_type = .v128,
            .init = &.{ 0xfd, 0x0c, 0x00 },
            .features = without("simd"),
            .error_ = error.UnexpectedEnd,
        },
        .{
            .value_type = .funcref,
            .init = &.{0xd0},
            .features = without("reference_types"),
            .error_ = error.UnexpectedEnd,
        },
        .{
            .value_type = .funcref,
            .init = &.{ 0xd0, 0x00 },
            .features = without("reference_types"),
            .error_ = error.InvalidTypeIndex,
        },
        .{
            .value_type = .funcref,
            .init = &.{ 0xd2, 0x80 },
            .features = without("reference_types"),
            .error_ = error.UnexpectedEnd,
        },
        .{
            .value_type = .funcref,
            .init = &.{ 0xd2, 0x00 },
            .features = without("reference_types"),
            .error_ = error.InvalidFuncIndex,
        },
        .{
            .value_type = .i31ref,
            .init = &.{ 0xfb, 0x9c },
            .features = without("gc"),
            .error_ = error.UnexpectedEnd,
        },
        .{
            .value_type = .f32,
            .init = &.{ 0x43, 0x00 },
            .features = Feature.Set{},
            .error_ = error.UnexpectedEnd,
        },
    };

    for (malformed) |case| {
        var module = try moduleWithGlobal(allocator, case.value_type, case.init);
        defer module.deinit();
        try expectValidationError(case.error_, &module, case.features);
    }
}

test "declaration gates do not mask structural errors" {
    const allocator = std.testing.allocator;

    {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.module_types.append(allocator, .{ .func_type = .{} });
        const func_type = &module.module_types.items[0].func_type;
        func_type.params = try allocator.dupe(types.ValType, &.{.concrete_ref_null});
        func_type.param_type_idxs = try allocator.dupe(u32, &.{9});
        try expectValidationError(
            error.InvalidTypeIndex,
            &module,
            without("reference_types"),
        );
    }

    {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.tables.append(allocator, .{ .type = .{
            .elem_type = .externref,
            .limits = .{
                .initial = 2,
                .max = 1,
                .has_max = true,
            },
        } });
        try expectValidationError(
            error.InvalidLimits,
            &module,
            without("reference_types"),
        );
    }

    {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.module_types.append(allocator, .{ .func_type = .{} });
        try module.funcs.append(allocator, .{
            .decl = .{ .type_var = .{ .index = 0 } },
            .code_bytes = &.{ 0x02, 0x01, 0x0b, 0x0b },
        });
        try expectValidationError(
            error.InvalidTypeIndex,
            &module,
            without("multi_value"),
        );
    }
}
