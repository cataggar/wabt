const std = @import("std");
const Feature = @import("Feature.zig");
const Validator = @import("Validator.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");

const Family = enum {
    exceptions,
    tail_call,
    function_references,
    sign_extension,
    sat_float_to_int,
    bulk_memory,
    reference_types,
    typed_select,
    gc,
    wide_arithmetic,
    simd,
    relaxed_simd,
    threads,
};

const Case = struct {
    family: Family,
    wat: []const u8,
};

const cases = [_]Case{
    .{
        .family = .exceptions,
        .wat = "(module (tag $e) (func throw $e))",
    },
    .{
        .family = .tail_call,
        .wat = "(module (func $callee) (func return_call $callee))",
    },
    .{
        .family = .function_references,
        .wat = "(module (func (result (ref func)) ref.null func ref.as_non_null))",
    },
    .{
        .family = .sign_extension,
        .wat = "(module (func i32.const 0 i32.extend8_s drop))",
    },
    .{
        .family = .sat_float_to_int,
        .wat = "(module (func f32.const 0 i32.trunc_sat_f32_s drop))",
    },
    .{
        .family = .bulk_memory,
        .wat = "(module (memory 1) (func i32.const 0 i32.const 0 i32.const 0 memory.copy))",
    },
    .{
        .family = .reference_types,
        .wat = "(module (table 1 funcref) (func i32.const 0 table.get 0 drop))",
    },
    .{
        .family = .typed_select,
        .wat = "(module (func i32.const 1 i32.const 2 i32.const 0 select (result i32) drop))",
    },
    .{
        .family = .gc,
        .wat = "(module (func i32.const 0 ref.i31 drop))",
    },
    .{
        .family = .wide_arithmetic,
        .wat = "(module (func (result i64 i64) unreachable i64.add128))",
    },
    .{
        .family = .simd,
        .wat = "(module (func v128.const i32x4 0 0 0 0 drop))",
    },
    .{
        .family = .relaxed_simd,
        .wat = "(module (func unreachable i8x16.relaxed_swizzle drop))",
    },
    .{
        .family = .threads,
        // The body gate is independent of the shared-memory declaration gate.
        .wat = "(module (memory 1) (func i32.const 0 i32.atomic.load drop))",
    },
};

fn featuresFor(family: Family, enabled: bool) Feature.Set {
    var features = Feature.Set{};
    switch (family) {
        .exceptions => features.exceptions = enabled,
        .tail_call => features.tail_call = enabled,
        .function_references => features.function_references = enabled,
        .sign_extension => features.sign_extension = enabled,
        .sat_float_to_int => features.sat_float_to_int = enabled,
        .bulk_memory => features.bulk_memory = enabled,
        .reference_types, .typed_select => features.reference_types = enabled,
        .gc => features.gc = enabled,
        .wide_arithmetic => features.wide_arithmetic = enabled,
        .simd => features.simd = enabled,
        .relaxed_simd => features.relaxed_simd = enabled,
        .threads => features.threads = enabled,
    }
    return features;
}

test "feature-gate WAT and binary matrix covers every typed family" {
    const allocator = std.testing.allocator;

    for (cases) |case| {
        const enabled = Validator.Options{ .features = featuresFor(case.family, true) };
        const disabled = Validator.Options{ .features = featuresFor(case.family, false) };

        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try Validator.validate(&module, enabled);
        try std.testing.expectError(
            error.UnsupportedOpcode,
            Validator.validate(&module, disabled),
        );

        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try Validator.validate(&decoded, enabled);
        try std.testing.expectError(
            error.UnsupportedOpcode,
            Validator.validate(&decoded, disabled),
        );
    }
}

test "body gates preserve raw caller-controlled feature combinations" {
    const allocator = std.testing.allocator;
    const raw_cases = [_]struct {
        wat: []const u8,
        features: Feature.Set,
    }{
        .{
            .wat = "(module (func unreachable ref.as_non_null drop))",
            .features = .{
                .function_references = true,
                .reference_types = false,
            },
        },
        .{
            .wat = "(module (func unreachable ref.i31 drop))",
            .features = .{
                .gc = true,
                .function_references = false,
                .reference_types = false,
            },
        },
        .{
            .wat = "(module (func unreachable i8x16.relaxed_swizzle drop))",
            .features = .{
                .relaxed_simd = true,
                .simd = false,
            },
        },
    };

    for (raw_cases) |case| {
        var module = try text_parser.parseModule(allocator, case.wat);
        defer module.deinit();
        try Validator.validate(&module, .{ .features = case.features });
    }
}
