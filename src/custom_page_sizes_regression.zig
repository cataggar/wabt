const std = @import("std");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");
const text_writer = @import("text/Writer.zig");
const types = @import("types.zig");

const custom_options: Validator.Options = .{
    .features = .{ .custom_page_sizes = true },
};

fn expectWatRejected(source: []const u8) !void {
    var module = text_parser.parseModule(std.testing.allocator, source) catch return;
    defer module.deinit();
    return error.TestUnexpectedResult;
}

fn expectWatLimitsError(source: []const u8) !void {
    var module = try text_parser.parseModule(std.testing.allocator, source);
    defer module.deinit();
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(&module, custom_options),
    );
}

fn moduleWithSection(
    allocator: std.mem.Allocator,
    section_id: u8,
    payload: []const u8,
) ![]u8 {
    try std.testing.expect(payload.len < 128);
    const bytes = try allocator.alloc(u8, 10 + payload.len);
    const preamble = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    @memcpy(bytes[0..8], &preamble);
    bytes[8] = section_id;
    bytes[9] = @intCast(payload.len);
    @memcpy(bytes[10..], payload);
    return bytes;
}

test "custom page sizes reject every value outside the current two-value domain" {
    const invalid = [_][]const u8{
        "(module (memory 1 (pagesize 0)))",
        "(module (memory (pagesize 2) (data \"x\")))",
        "(module (memory 1 (pagesize 2)))",
        "(module (memory 1 (pagesize 3)))",
        "(module (memory 1 (pagesize 32768)))",
        "(module (memory 1 (pagesize 65535)))",
        "(module (memory 1 (pagesize 65537)))",
        "(module (memory 1 (pagesize 131072)))",
        "(module (memory 1 (pagesize 4294967295)))",
        "(module (memory 1 (pagesize 4294967296)))",
        "(module (memory $m i64 1 (pagesize 3)))",
        "(module (memory $m (import \"a\" \"b\") 1 (pagesize 3)))",
        "(module (import \"a\" \"b\" (memory $m 1 (pagesize 3))))",
        "(module (memory $a 1 (pagesize 1)) (memory $b 1 (pagesize 3)))",
        "(module (table 1 (pagesize 1) funcref))",
    };
    for (invalid) |source| try expectWatRejected(source);

    for (&[_]u32{ 1, 65536 }) |page_size| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "(module (memory 0 (pagesize {d})))",
            .{page_size},
        );
        defer std.testing.allocator.free(source);
        var module = try text_parser.parseModule(std.testing.allocator, source);
        defer module.deinit();
        try std.testing.expectEqual(page_size, module.memories.items[0].type.limits.page_size);
        try std.testing.expect(module.memories.items[0].type.limits.has_page_size);
    }
}

test "inline data abbreviations infer bounds from their selected page size" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        page_size: u32,
        data_len: usize,
        pages: u64,
    }{
        .{ .page_size = 1, .data_len = 0, .pages = 0 },
        .{ .page_size = 1, .data_len = 1, .pages = 1 },
        .{ .page_size = 1, .data_len = 2, .pages = 2 },
        .{ .page_size = 65536, .data_len = 0, .pages = 0 },
        .{ .page_size = 65536, .data_len = 1, .pages = 1 },
        .{ .page_size = 65536, .data_len = 65535, .pages = 1 },
        .{ .page_size = 65536, .data_len = 65536, .pages = 1 },
        .{ .page_size = 65536, .data_len = 65537, .pages = 2 },
    };

    for (cases) |case| {
        const payload = try allocator.alloc(u8, case.data_len);
        defer allocator.free(payload);
        @memset(payload, 'x');
        const source = try std.fmt.allocPrint(
            allocator,
            "(module (memory (pagesize {d}) (data \"{s}\")))",
            .{ case.page_size, payload },
        );
        defer allocator.free(source);

        var parsed = try text_parser.parseModule(allocator, source);
        defer parsed.deinit();
        try Validator.validate(&parsed, custom_options);
        const parsed_limits = parsed.memories.items[0].type.limits;
        try std.testing.expectEqual(case.pages, parsed_limits.initial);
        try std.testing.expectEqual(case.pages, parsed_limits.max);
        try std.testing.expect(parsed_limits.has_max);
        try std.testing.expectEqual(case.page_size, parsed_limits.page_size);
        try std.testing.expect(parsed_limits.has_page_size);
        try std.testing.expectEqual(case.data_len, parsed.data_segments.items[0].data.len);

        const wasm = try binary_writer.writeModule(allocator, &parsed);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try Validator.validate(&decoded, custom_options);
        try std.testing.expectEqual(case.pages, decoded.memories.items[0].type.limits.initial);
        try std.testing.expectEqual(case.page_size, decoded.memories.items[0].type.limits.page_size);
        try std.testing.expect(decoded.memories.items[0].type.limits.has_page_size);
        try std.testing.expectEqual(case.data_len, decoded.data_segments.items[0].data.len);

        const printed = try text_writer.writeModule(allocator, &decoded);
        defer allocator.free(printed);
        var reparsed = try text_parser.parseModule(allocator, printed);
        defer reparsed.deinit();
        try Validator.validate(&reparsed, custom_options);
        const rebuilt = try binary_writer.writeModule(allocator, &reparsed);
        defer allocator.free(rebuilt);
        try std.testing.expectEqualSlices(u8, wasm, rebuilt);
    }
}

test "inline data accepts spec order permutations and infers page and address sizes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        source: []const u8,
        is_64: bool,
        page_size: u32,
        has_page_size: bool,
        pages: u64,
        exports: usize,
    }{
        .{
            .source = "(module (memory (data \"x\")))",
            .is_64 = false,
            .page_size = 65536,
            .has_page_size = false,
            .pages = 1,
            .exports = 0,
        },
        .{
            .source = "(module (memory (export \"m\") (data \"x\")))",
            .is_64 = false,
            .page_size = 65536,
            .has_page_size = false,
            .pages = 1,
            .exports = 1,
        },
        .{
            .source = "(module (memory (export \"m\") i64 (data \"x\")))",
            .is_64 = true,
            .page_size = 65536,
            .has_page_size = false,
            .pages = 1,
            .exports = 1,
        },
        .{
            .source = "(module (memory (export \"m\") (pagesize 1) (data \"x\")))",
            .is_64 = false,
            .page_size = 1,
            .has_page_size = true,
            .pages = 1,
            .exports = 1,
        },
        .{
            .source = "(module (memory (export \"m\") i64 (pagesize 1) (data \"x\")))",
            .is_64 = true,
            .page_size = 1,
            .has_page_size = true,
            .pages = 1,
            .exports = 1,
        },
        .{
            .source = "(module (memory $m (export \"a\") (export \"b\") i64 (pagesize 1) (data \"xyz\")))",
            .is_64 = true,
            .page_size = 1,
            .has_page_size = true,
            .pages = 3,
            .exports = 2,
        },
    };
    for (cases) |case| {
        var module = try text_parser.parseModule(allocator, case.source);
        defer module.deinit();
        const limits = module.memories.items[0].type.limits;
        try std.testing.expectEqual(case.is_64, limits.is_64);
        try std.testing.expectEqual(case.page_size, limits.page_size);
        try std.testing.expectEqual(case.has_page_size, limits.has_page_size);
        try std.testing.expectEqual(case.pages, limits.initial);
        try std.testing.expectEqual(case.pages, limits.max);
        try std.testing.expect(limits.has_max);
        try std.testing.expectEqual(case.exports, module.exports.items.len);
        try std.testing.expectEqual(@as(u8, if (case.is_64) 0x42 else 0x41), module.data_segments.items[0].offset_expr_bytes[0]);
    }

    var imported = try text_parser.parseModule(
        allocator,
        "(module (memory $m (export \"m\") (import \"a\" \"b\") i64 1 (pagesize 1)))",
    );
    defer imported.deinit();
    try std.testing.expect(imported.memories.items[0].is_import);
    try std.testing.expect(imported.memories.items[0].type.limits.is_64);
    try std.testing.expectEqual(@as(u32, 1), imported.memories.items[0].type.limits.page_size);
    try std.testing.expectEqual(@as(usize, 1), imported.exports.items.len);
}

test "inline data rejects fields outside the spec grammar order" {
    const wrong_order = [_][]const u8{
        "(module (memory i64 (export \"m\") (data \"x\")))",
        "(module (memory (pagesize 1) i64 (data \"x\")))",
        "(module (memory (pagesize 1) (export \"m\") (data \"x\")))",
        "(module (memory (export \"m\") i64 (export \"n\") (data \"x\")))",
        "(module (memory i64 (import \"m\" \"n\") 1))",
        "(module (memory (data \"x\") (pagesize 1)))",
        "(module (memory (data \"x\") i64))",
        "(module (memory (pagesize 1) 1))",
        "(module (memory (pagesize 1) (import \"m\" \"n\") 1))",
        "(module (memory i64 i64 (data \"x\")))",
        "(module (memory (pagesize 1) (pagesize 1) (data \"x\")))",
    };
    for (wrong_order) |source| try expectWatRejected(source);
}

test "inline data memory64 and custom page sizes are independently gated" {
    const allocator = std.testing.allocator;
    var both = try text_parser.parseModule(
        allocator,
        "(module (memory (export \"m\") i64 (pagesize 1) (data \"xyz\")))",
    );
    defer both.deinit();
    try Validator.validate(&both, .{ .features = .{
        .memory64 = true,
        .custom_page_sizes = true,
    } });
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(&both, .{ .features = .{
            .memory64 = false,
            .custom_page_sizes = true,
        } }),
    );
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(&both, .{ .features = .{
            .memory64 = true,
            .custom_page_sizes = false,
        } }),
    );

    var memory64_only = try text_parser.parseModule(
        allocator,
        "(module (memory i64 (data \"x\")))",
    );
    defer memory64_only.deinit();
    try Validator.validate(&memory64_only, .{ .features = .{
        .memory64 = true,
        .custom_page_sizes = false,
    } });
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(&memory64_only, .{ .features = .{
            .memory64 = false,
            .custom_page_sizes = true,
        } }),
    );

    var custom_only = try text_parser.parseModule(
        allocator,
        "(module (memory (pagesize 1) (data \"x\")))",
    );
    defer custom_only.deinit();
    try Validator.validate(&custom_only, .{ .features = .{
        .memory64 = false,
        .custom_page_sizes = true,
    } });
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(&custom_only, .{ .features = .{
            .memory64 = true,
            .custom_page_sizes = false,
        } }),
    );

    var default_features = try text_parser.parseModule(
        std.testing.allocator,
        "(module (memory (pagesize 1) (data \"xyz\")))",
    );
    defer default_features.deinit();
    try std.testing.expectError(error.InvalidLimits, Validator.validate(&default_features, .{}));
}

test "custom page-size validation follows address width, features, and shared limits" {
    const valid = [_][]const u8{
        "(module (memory 4294967295 (pagesize 1)))",
        "(module (memory 65536 (pagesize 65536)))",
        "(module (memory i64 18446744073709551615 (pagesize 1)))",
        "(module (memory i64 281474976710656 (pagesize 65536)))",
        "(module (memory 0 4294967295 shared (pagesize 1)))",
        "(module (memory i64 0 281474976710656 shared (pagesize 65536)))",
    };
    for (valid) |source| {
        var module = try text_parser.parseModule(std.testing.allocator, source);
        defer module.deinit();
        try Validator.validate(&module, custom_options);
    }

    const invalid = [_][]const u8{
        "(module (memory 65537 (pagesize 65536)))",
        "(module (memory 0 65537 (pagesize 65536)))",
        "(module (memory i64 281474976710657 (pagesize 65536)))",
        "(module (memory i64 0 281474976710657 (pagesize 65536)))",
        "(module (memory 1 shared (pagesize 1)))",
        "(module (memory 2 1 shared (pagesize 1)))",
    };
    for (invalid) |source| try expectWatLimitsError(source);

    var one_byte = try text_parser.parseModule(
        std.testing.allocator,
        "(module (memory 1 (pagesize 1)))",
    );
    defer one_byte.deinit();
    try std.testing.expectError(error.InvalidLimits, Validator.validate(&one_byte, .{}));

    var explicit_default = try text_parser.parseModule(
        std.testing.allocator,
        "(module (memory 1 (pagesize 65536)))",
    );
    defer explicit_default.deinit();
    try std.testing.expectError(error.InvalidLimits, Validator.validate(&explicit_default, .{}));

    var implicit_default = try text_parser.parseModule(
        std.testing.allocator,
        "(module (memory 1))",
    );
    defer implicit_default.deinit();
    try Validator.validate(&implicit_default, .{});

    var memory64 = try text_parser.parseModule(
        std.testing.allocator,
        "(module (memory i64 1 (pagesize 1)))",
    );
    defer memory64.deinit();
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(
            &memory64,
            .{ .features = .{ .custom_page_sizes = true, .memory64 = false } },
        ),
    );

    var shared = try text_parser.parseModule(
        std.testing.allocator,
        "(module (memory 1 2 shared (pagesize 1)))",
    );
    defer shared.deinit();
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(
            &shared,
            .{ .features = .{ .custom_page_sizes = true, .threads = false } },
        ),
    );
}

test "shared tables are rejected without changing ordinary tables or shared memories" {
    const invalid_tables = [_][]const u8{
        "(module (table 0 1 shared funcref))",
        "(module (table $t (import \"m\" \"t\") 0 1 shared funcref))",
        "(module (import \"m\" \"t\" (table 0 1 shared funcref)))",
    };
    for (invalid_tables) |source| try expectWatRejected(source);

    const allocator = std.testing.allocator;
    var module = try text_parser.parseModule(
        allocator,
        "(module (table 0 1 funcref) (memory 0 1 shared))",
    );
    defer module.deinit();
    try Validator.validate(&module, .{});

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try Validator.validate(&decoded, .{});
    try std.testing.expect(!decoded.tables.items[0].type.limits.is_shared);
    try std.testing.expect(decoded.memories.items[0].type.limits.is_shared);
}

test "imported defined named shared and multiple custom memories round-trip exactly" {
    const allocator = std.testing.allocator;
    const source =
        \\(module
        \\  (memory $inline (import "a" "inline") 0 4294967295 shared (pagesize 1))
        \\  (import "b" "standalone" (memory $standalone i64 0 281474976710656 shared (pagesize 65536)))
        \\  (memory $defined 1 (pagesize 1))
        \\  (export "inline" (memory $inline))
        \\  (export "standalone" (memory $standalone))
        \\  (export "defined" (memory $defined)))
    ;
    var parsed = try text_parser.parseModule(allocator, source);
    defer parsed.deinit();
    try Validator.validate(&parsed, custom_options);

    const wasm = try binary_writer.writeModule(allocator, &parsed);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try Validator.validate(&decoded, custom_options);

    try std.testing.expectEqual(@as(usize, 3), decoded.memories.items.len);
    try std.testing.expectEqual(@as(u32, 1), decoded.memories.items[0].type.limits.page_size);
    try std.testing.expectEqual(@as(u32, 65536), decoded.memories.items[1].type.limits.page_size);
    try std.testing.expectEqual(@as(u32, 1), decoded.memories.items[2].type.limits.page_size);
    for (decoded.memories.items) |memory| {
        try std.testing.expect(memory.type.limits.has_page_size);
    }

    const printed = try text_writer.writeModule(allocator, &decoded);
    defer allocator.free(printed);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, printed, "(pagesize 0x1)"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, printed, "(pagesize 0x10000)"));

    var reparsed = try text_parser.parseModule(allocator, printed);
    defer reparsed.deinit();
    try Validator.validate(&reparsed, custom_options);
    const rebuilt = try binary_writer.writeModule(allocator, &reparsed);
    defer allocator.free(rebuilt);
    var reread = try binary_reader.readModule(allocator, rebuilt);
    defer reread.deinit();
    try Validator.validate(&reread, custom_options);
    for (decoded.memories.items, reread.memories.items) |before, after| {
        try std.testing.expectEqual(before.type.limits.page_size, after.type.limits.page_size);
        try std.testing.expectEqual(before.type.limits.has_page_size, after.type.limits.has_page_size);
    }
}

test "binary reader accepts only log2 zero or sixteen and preserves explicit default" {
    const allocator = std.testing.allocator;
    const valid = [_][]const u8{
        &.{ 0x01, 0x08, 0x00, 0x00 },
        &.{ 0x01, 0x08, 0x00, 0x10 },
        &.{ 0x01, 0x08, 0x00, 0x80, 0x00 },
    };
    for (valid, 0..) |payload, i| {
        const wasm = try moduleWithSection(allocator, 5, payload);
        defer allocator.free(wasm);
        var module = try binary_reader.readModule(allocator, wasm);
        defer module.deinit();
        try std.testing.expect(module.memories.items[0].type.limits.has_page_size);
        try std.testing.expectEqual(
            @as(u32, if (i == 1) 65536 else 1),
            module.memories.items[0].type.limits.page_size,
        );
    }

    const invalid_memory = [_][]const u8{
        &.{ 0x01, 0x08, 0x00, 0x01 },
        &.{ 0x01, 0x08, 0x00, 0x0f },
        &.{ 0x01, 0x08, 0x00, 0x11 },
        &.{ 0x01, 0x08, 0x00, 0xff, 0xff, 0xff, 0xff, 0x0f },
        &.{ 0x01, 0x08, 0x00, 0x80, 0x80, 0x80, 0x80, 0x10 },
        &.{ 0x01, 0x10, 0x00 },
        &.{ 0x01, 0x0a, 0x00, 0x00 },
        &.{ 0x01, 0x00, 0x80, 0x80, 0x80, 0x80, 0x10 },
        &.{ 0x01, 0x04, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 },
    };
    for (invalid_memory) |payload| {
        const wasm = try moduleWithSection(allocator, 5, payload);
        defer allocator.free(wasm);
        try std.testing.expectError(
            error.InvalidLimits,
            binary_reader.readModule(allocator, wasm),
        );
    }

    const truncated = try moduleWithSection(allocator, 5, &.{ 0x01, 0x08, 0x00 });
    defer allocator.free(truncated);
    try std.testing.expectError(
        error.UnexpectedEof,
        binary_reader.readModule(allocator, truncated),
    );

    const custom_table = try moduleWithSection(
        allocator,
        4,
        &.{ 0x01, 0x70, 0x08, 0x00, 0x00 },
    );
    defer allocator.free(custom_table);
    try std.testing.expectError(
        error.InvalidLimits,
        binary_reader.readModule(allocator, custom_table),
    );
}

test "binary reader rejects shared-table flags and still accepts shared memories" {
    const allocator = std.testing.allocator;
    const shared_tables = [_][]const u8{
        // Defined table with max + shared.
        &.{ 0x01, 0x70, 0x03, 0x00, 0x01 },
        // Defined table64 with max + shared.
        &.{ 0x01, 0x70, 0x07, 0x00, 0x01 },
    };
    for (shared_tables) |payload| {
        const wasm = try moduleWithSection(allocator, 4, payload);
        defer allocator.free(wasm);
        try std.testing.expectError(
            error.InvalidLimits,
            binary_reader.readModule(allocator, wasm),
        );
    }

    const imported_shared_table = try moduleWithSection(
        allocator,
        2,
        &.{ 0x01, 0x01, 'm', 0x01, 't', 0x01, 0x70, 0x03, 0x00, 0x01 },
    );
    defer allocator.free(imported_shared_table);
    try std.testing.expectError(
        error.InvalidLimits,
        binary_reader.readModule(allocator, imported_shared_table),
    );

    const shared_memory = try moduleWithSection(
        allocator,
        5,
        &.{ 0x01, 0x03, 0x00, 0x01 },
    );
    defer allocator.free(shared_memory);
    var module = try binary_reader.readModule(allocator, shared_memory);
    defer module.deinit();
    try std.testing.expect(module.memories.items[0].type.limits.is_shared);
    try Validator.validate(&module, .{});
}

test "binary writer rejects invalid programmatic page sizes without normalizing" {
    const allocator = std.testing.allocator;
    const invalid = [_]types.Limits{
        .{ .initial = 1, .page_size = 0, .has_page_size = true },
        .{ .initial = 1, .page_size = 2, .has_page_size = true },
        .{ .initial = 1, .page_size = 3 },
        .{ .initial = 65537, .page_size = 65536, .has_page_size = true },
        .{ .initial = 1, .is_shared = true, .page_size = 1, .has_page_size = true },
    };
    for (invalid) |limits| {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.memories.append(allocator, .{ .type = .{ .limits = limits } });
        try std.testing.expectError(
            error.InvalidLimits,
            binary_writer.writeModule(allocator, &module),
        );
    }

    var table_module = Mod.Module.init(allocator);
    defer table_module.deinit();
    try table_module.tables.append(allocator, .{
        .type = .{
            .elem_type = .funcref,
            .limits = .{ .initial = 1, .page_size = 1, .has_page_size = true },
        },
    });
    try std.testing.expectError(
        error.InvalidLimits,
        binary_writer.writeModule(allocator, &table_module),
    );

    var shared_table_without_max = Mod.Module.init(allocator);
    defer shared_table_without_max.deinit();
    try shared_table_without_max.tables.append(allocator, .{
        .type = .{
            .elem_type = .funcref,
            .limits = .{ .initial = 1, .is_shared = true },
        },
    });
    try std.testing.expectError(
        error.InvalidLimits,
        binary_writer.writeModule(allocator, &shared_table_without_max),
    );

    var shared_table = Mod.Module.init(allocator);
    defer shared_table.deinit();
    try shared_table.tables.append(allocator, .{
        .type = .{
            .elem_type = .funcref,
            .limits = .{
                .initial = 1,
                .max = 2,
                .has_max = true,
                .is_shared = true,
            },
        },
    });
    try std.testing.expectError(
        error.InvalidLimits,
        Validator.validate(&shared_table, .{}),
    );
    try std.testing.expectError(
        error.InvalidLimits,
        binary_writer.writeModule(allocator, &shared_table),
    );

    var imported_shared_table = Mod.Module.init(allocator);
    defer imported_shared_table.deinit();
    try imported_shared_table.imports.append(allocator, .{
        .module_name = "m",
        .field_name = "t",
        .kind = .table,
        .table = .{
            .elem_type = .funcref,
            .limits = .{
                .initial = 1,
                .max = 2,
                .has_max = true,
                .is_shared = true,
            },
        },
    });
    try std.testing.expectError(
        error.InvalidLimits,
        binary_writer.writeModule(allocator, &imported_shared_table),
    );

    var imported = Mod.Module.init(allocator);
    defer imported.deinit();
    try imported.imports.append(allocator, .{
        .module_name = "m",
        .field_name = "n",
        .kind = .memory,
        .memory = .{ .limits = .{
            .initial = 1,
            .page_size = 3,
            .has_page_size = true,
        } },
    });
    try std.testing.expectError(
        error.InvalidLimits,
        binary_writer.writeModule(allocator, &imported),
    );

    const valid = [_]types.Limits{
        .{ .initial = 1, .page_size = 1 },
        .{ .initial = 1, .page_size = 65536, .has_page_size = true },
    };
    for (valid) |limits| {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.memories.append(allocator, .{ .type = .{ .limits = limits } });
        const wasm = try binary_writer.writeModule(allocator, &module);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try std.testing.expectEqual(limits.page_size, decoded.memories.items[0].type.limits.page_size);
        try std.testing.expect(decoded.memories.items[0].type.limits.has_page_size);
    }
}

test "text writer rejects invalid programmatic limits by output kind" {
    const allocator = std.testing.allocator;

    const invalid_page_sizes = [_]types.Limits{
        .{ .initial = 1, .page_size = 0, .has_page_size = true },
        .{ .initial = 1, .page_size = 2, .has_page_size = true },
        .{ .initial = 1, .page_size = 3 },
    };
    for (invalid_page_sizes) |limits| {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.memories.append(allocator, .{ .type = .{ .limits = limits } });
        try std.testing.expectError(
            error.InvalidLimits,
            text_writer.writeModule(allocator, &module),
        );
    }

    var table_page_size = Mod.Module.init(allocator);
    defer table_page_size.deinit();
    try table_page_size.tables.append(allocator, .{ .type = .{
        .elem_type = .funcref,
        .limits = .{ .initial = 1, .page_size = 1, .has_page_size = true },
    } });
    try std.testing.expectError(
        error.InvalidLimits,
        text_writer.writeModule(allocator, &table_page_size),
    );

    var shared_table = Mod.Module.init(allocator);
    defer shared_table.deinit();
    try shared_table.tables.append(allocator, .{ .type = .{
        .elem_type = .funcref,
        .limits = .{
            .initial = 1,
            .max = 2,
            .has_max = true,
            .is_shared = true,
        },
    } });
    try std.testing.expectError(
        error.InvalidLimits,
        text_writer.writeModule(allocator, &shared_table),
    );

    var shared_without_max = Mod.Module.init(allocator);
    defer shared_without_max.deinit();
    try shared_without_max.memories.append(allocator, .{ .type = .{ .limits = .{
        .initial = 1,
        .is_shared = true,
    } } });
    try std.testing.expectError(
        error.InvalidLimits,
        text_writer.writeModule(allocator, &shared_without_max),
    );

    const invalid_bounds = [_]types.Limits{
        .{ .initial = 65537 },
        .{ .initial = 0, .max = 65537, .has_max = true },
        .{ .initial = 2, .max = 1, .has_max = true },
        .{ .initial = 4294967296, .page_size = 1, .has_page_size = true },
        .{ .initial = 281474976710657, .is_64 = true },
    };
    for (invalid_bounds) |limits| {
        var module = Mod.Module.init(allocator);
        defer module.deinit();
        try module.memories.append(allocator, .{ .type = .{ .limits = limits } });
        try std.testing.expectError(
            error.InvalidLimits,
            text_writer.writeModule(allocator, &module),
        );
    }

    var table_bounds = Mod.Module.init(allocator);
    defer table_bounds.deinit();
    try table_bounds.tables.append(allocator, .{ .type = .{
        .elem_type = .funcref,
        .limits = .{ .initial = 4294967296, .is_64 = true },
    } });
    try std.testing.expectError(
        error.InvalidLimits,
        text_writer.writeModule(allocator, &table_bounds),
    );
}

test "text writer round-trips valid memory and table limit forms" {
    const allocator = std.testing.allocator;
    var module = Mod.Module.init(allocator);
    defer module.deinit();

    try module.tables.append(allocator, .{ .type = .{
        .elem_type = .funcref,
        .limits = .{ .initial = 1, .max = 2, .has_max = true },
    } });
    try module.memories.append(allocator, .{ .type = .{ .limits = .{
        .initial = 1,
        .page_size = 1,
        .has_page_size = true,
    } } });
    try module.memories.append(allocator, .{ .type = .{ .limits = .{
        .initial = 1,
        .page_size = 65536,
        .has_page_size = true,
    } } });
    try module.memories.append(allocator, .{ .type = .{ .limits = .{
        .initial = 1,
        .max = 2,
        .has_max = true,
        .is_shared = true,
    } } });

    const wat = try text_writer.writeModule(allocator, &module);
    defer allocator.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(table (;0;) 1 2 funcref)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(memory (;0;) 1 (pagesize 0x1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(memory (;1;) 1 (pagesize 0x10000))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wat, "(memory (;2;) 1 2 shared)") != null);

    var reparsed = try text_parser.parseModule(allocator, wat);
    defer reparsed.deinit();
    try Validator.validate(&reparsed, custom_options);
    try std.testing.expectEqual(@as(usize, 1), reparsed.tables.items.len);
    try std.testing.expectEqual(@as(usize, 3), reparsed.memories.items.len);
    try std.testing.expectEqual(@as(u32, 1), reparsed.memories.items[0].type.limits.page_size);
    try std.testing.expect(reparsed.memories.items[0].type.limits.has_page_size);
    try std.testing.expectEqual(@as(u32, 65536), reparsed.memories.items[1].type.limits.page_size);
    try std.testing.expect(reparsed.memories.items[1].type.limits.has_page_size);
    try std.testing.expect(reparsed.memories.items[2].type.limits.is_shared);

    const wasm = try binary_writer.writeModule(allocator, &reparsed);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try Validator.validate(&decoded, custom_options);
    try std.testing.expectEqual(@as(u32, 1), decoded.memories.items[0].type.limits.page_size);
    try std.testing.expect(decoded.memories.items[1].type.limits.has_page_size);
    try std.testing.expect(decoded.memories.items[2].type.limits.is_shared);
}
