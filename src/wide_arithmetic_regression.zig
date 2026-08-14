const std = @import("std");
const Mod = @import("Module.zig");
const Validator = @import("Validator.zig");
const binary_instr = @import("binary/instr.zig");
const binary_reader = @import("binary/reader.zig");
const binary_writer = @import("binary/writer.zig");
const text_parser = @import("text/Parser.zig");
const text_writer = @import("text/Writer.zig");

const wide_options: Validator.Options = .{
    .features = .{ .wide_arithmetic = true },
};

const opcodes = [_]struct {
    mnemonic: []const u8,
    subopcode: u8,
    operand_count: usize,
}{
    .{ .mnemonic = "i64.add128", .subopcode = 0x13, .operand_count = 4 },
    .{ .mnemonic = "i64.sub128", .subopcode = 0x14, .operand_count = 4 },
    .{ .mnemonic = "i64.mul_wide_s", .subopcode = 0x15, .operand_count = 2 },
    .{ .mnemonic = "i64.mul_wide_u", .subopcode = 0x16, .operand_count = 2 },
};

fn expectWatValidationError(expected: Validator.Error, source: []const u8) !void {
    var module = try text_parser.parseModule(std.testing.allocator, source);
    defer module.deinit();
    try std.testing.expectError(expected, Validator.validate(&module, wide_options));
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

test "wide arithmetic valid signatures consume exactly their operands" {
    const valid = [_][]const u8{
        "(module (func (param i64 i64 i64 i64) (result i64 i64) local.get 0 local.get 1 local.get 2 local.get 3 i64.add128))",
        "(module (func (param i64 i64 i64 i64) (result i64 i64) local.get 0 local.get 1 local.get 2 local.get 3 i64.sub128))",
        "(module (func (param i64 i64) (result i64 i64) local.get 0 local.get 1 i64.mul_wide_s))",
        "(module (func (param i64 i64) (result i64 i64) local.get 0 local.get 1 i64.mul_wide_u))",
        // The i32 sentinel below the operands must survive. This proves each
        // opcode consumes exactly four or two i64 values, not one more.
        "(module (func (result i32) i32.const 7 i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128 drop drop))",
        "(module (func (result i32) i32.const 7 i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128 drop drop))",
        "(module (func (result i32) i32.const 7 i64.const 0 i64.const 0 i64.mul_wide_s drop drop))",
        "(module (func (result i32) i32.const 7 i64.const 0 i64.const 0 i64.mul_wide_u drop drop))",
    };
    for (valid) |source| {
        var module = try text_parser.parseModule(std.testing.allocator, source);
        defer module.deinit();
        try Validator.validate(&module, wide_options);
    }

    for (valid[0..4]) |source| {
        var module = try text_parser.parseModule(std.testing.allocator, source);
        defer module.deinit();
        try std.testing.expectError(
            error.UnsupportedOpcode,
            Validator.validate(&module, .{}),
        );
    }
}

test "wide arithmetic rejects missing and mistyped operands at every position" {
    const invalid = [_][]const u8{
        // Missing one operand for each opcode.
        "(module (func i64.const 0 i64.const 0 i64.const 0 i64.add128 drop drop))",
        "(module (func i64.const 0 i64.const 0 i64.const 0 i64.sub128 drop drop))",
        "(module (func i64.const 0 i64.mul_wide_s drop drop))",
        "(module (func i64.const 0 i64.mul_wide_u drop drop))",
        // add128: wrong type in operand positions 0, 1, 2, and 3.
        "(module (func i32.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128 drop drop))",
        "(module (func i64.const 0 i32.const 0 i64.const 0 i64.const 0 i64.add128 drop drop))",
        "(module (func i64.const 0 i64.const 0 i32.const 0 i64.const 0 i64.add128 drop drop))",
        "(module (func i64.const 0 i64.const 0 i64.const 0 i32.const 0 i64.add128 drop drop))",
        // sub128: wrong type in operand positions 0, 1, 2, and 3.
        "(module (func i32.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128 drop drop))",
        "(module (func i64.const 0 i32.const 0 i64.const 0 i64.const 0 i64.sub128 drop drop))",
        "(module (func i64.const 0 i64.const 0 i32.const 0 i64.const 0 i64.sub128 drop drop))",
        "(module (func i64.const 0 i64.const 0 i64.const 0 i32.const 0 i64.sub128 drop drop))",
        // Both operand positions of each multiply.
        "(module (func i32.const 0 i64.const 0 i64.mul_wide_s drop drop))",
        "(module (func i64.const 0 i32.const 0 i64.mul_wide_s drop drop))",
        "(module (func i32.const 0 i64.const 0 i64.mul_wide_u drop drop))",
        "(module (func i64.const 0 i32.const 0 i64.mul_wide_u drop drop))",
    };
    for (invalid) |source| try expectWatValidationError(error.TypeMismatch, source);
}

test "wide arithmetic produces exactly two concrete i64 results" {
    const invalid = [_][]const u8{
        // One declared result leaves the low limb below the high limb.
        "(module (func (result i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128))",
        "(module (func (result i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128))",
        "(module (func (result i64) i64.const 0 i64.const 0 i64.mul_wide_s))",
        "(module (func (result i64) i64.const 0 i64.const 0 i64.mul_wide_u))",
        // Three declared results require a value the instruction did not make.
        "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128))",
        "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128))",
        "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 i64.mul_wide_s))",
        "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 i64.mul_wide_u))",
        // Each result position is constrained to i64.
        "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128))",
        "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128))",
        "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128))",
        "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128))",
        "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.mul_wide_s))",
        "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.mul_wide_s))",
        "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.mul_wide_u))",
        "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.mul_wide_u))",
    };
    for (invalid) |source| try expectWatValidationError(error.TypeMismatch, source);
}

test "wide arithmetic unreachable operands stay polymorphic but results do not" {
    const valid = [_][]const u8{
        "(module (func (result i64 i64) unreachable i64.add128))",
        "(module (func (result i64 i64) unreachable i64.sub128))",
        "(module (func (result i64 i64) unreachable i64.mul_wide_s))",
        "(module (func (result i64 i64) unreachable i64.mul_wide_u))",
    };
    for (valid) |source| {
        var module = try text_parser.parseModule(std.testing.allocator, source);
        defer module.deinit();
        try Validator.validate(&module, wide_options);
    }

    const constrained = [_][]const u8{
        "(module (func (result i32 i64) unreachable i64.add128))",
        "(module (func (result i32 i64) unreachable i64.sub128))",
        "(module (func (result i32 i64) unreachable i64.mul_wide_s))",
        "(module (func (result i32 i64) unreachable i64.mul_wide_u))",
    };
    for (constrained) |source| {
        try expectWatValidationError(error.TypeMismatch, source);
    }
}

test "wide arithmetic binary and text round trips preserve all four opcodes" {
    const allocator = std.testing.allocator;
    const source =
        \\(module
        \\  (func (param i64 i64 i64 i64) (result i64 i64)
        \\    local.get 0 local.get 1 local.get 2 local.get 3 i64.add128)
        \\  (func (param i64 i64 i64 i64) (result i64 i64)
        \\    local.get 0 local.get 1 local.get 2 local.get 3 i64.sub128)
        \\  (func (param i64 i64) (result i64 i64)
        \\    local.get 0 local.get 1 i64.mul_wide_s)
        \\  (func (param i64 i64) (result i64 i64)
        \\    local.get 0 local.get 1 i64.mul_wide_u))
    ;

    var parsed = try text_parser.parseModule(allocator, source);
    defer parsed.deinit();
    try Validator.validate(&parsed, wide_options);

    for (opcodes, parsed.funcs.items) |opcode, func| {
        const func_type = switch (parsed.module_types.items[func.decl.type_var.index]) {
            .func_type => |ft| ft,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(opcode.operand_count, func_type.params.len);
        try std.testing.expectEqual(@as(usize, 2), func_type.results.len);
        try std.testing.expect(std.mem.indexOf(
            u8,
            func.code_bytes,
            &.{ 0xfc, opcode.subopcode },
        ) != null);
    }

    const wasm = try binary_writer.writeModule(allocator, &parsed);
    defer allocator.free(wasm);
    var decoded = try binary_reader.readModule(allocator, wasm);
    defer decoded.deinit();
    try Validator.validate(&decoded, wide_options);

    const printed = try text_writer.writeModule(allocator, &decoded);
    defer allocator.free(printed);
    for (opcodes) |opcode| {
        try std.testing.expect(std.mem.indexOf(u8, printed, opcode.mnemonic) != null);
    }

    var reparsed = try text_parser.parseModule(allocator, printed);
    defer reparsed.deinit();
    try Validator.validate(&reparsed, wide_options);
    const rebuilt = try binary_writer.writeModule(allocator, &reparsed);
    defer allocator.free(rebuilt);
    try std.testing.expectEqualSlices(u8, wasm, rebuilt);
}

test "wide arithmetic malformed and neighboring binary subopcodes are rejected" {
    const allocator = std.testing.allocator;
    const validator_cases = [_]struct {
        body: []const u8,
        expected: Validator.Error,
    }{
        .{ .body = &.{0xfc}, .expected = error.UnexpectedEnd },
        .{ .body = &.{ 0xfc, 0x93 }, .expected = error.UnexpectedEnd },
        .{
            .body = &.{ 0xfc, 0x80, 0x80, 0x80, 0x80, 0x80, 0x0b },
            .expected = error.UnexpectedEnd,
        },
        .{ .body = &.{ 0xfc, 0x12, 0x0b }, .expected = error.UnknownOpcode },
        .{ .body = &.{ 0xfc, 0x17, 0x0b }, .expected = error.UnknownOpcode },
    };
    for (validator_cases) |case| {
        var built = try moduleWithBody(allocator, case.body);
        defer built.deinit();
        try std.testing.expectError(
            case.expected,
            Validator.validate(&built, wide_options),
        );
    }

    // The binary reader rejects bodies missing their required final `end`
    // before the validator sees them.
    for (validator_cases[0..2]) |case| {
        var built = try moduleWithBody(allocator, case.body);
        defer built.deinit();
        const wasm = try binary_writer.writeModule(allocator, &built);
        defer allocator.free(wasm);
        try std.testing.expectError(
            error.InvalidSection,
            binary_reader.readModule(allocator, wasm),
        );
    }

    // Malformed LEB and unknown neighboring subopcodes retain a final `end`,
    // so they cross the binary reader and are rejected by validation.
    for (validator_cases[2..]) |case| {
        var built = try moduleWithBody(allocator, case.body);
        defer built.deinit();
        const wasm = try binary_writer.writeModule(allocator, &built);
        defer allocator.free(wasm);
        var decoded = try binary_reader.readModule(allocator, wasm);
        defer decoded.deinit();
        try std.testing.expectError(
            case.expected,
            Validator.validate(&decoded, wide_options),
        );
    }

    // Overlong but in-range u32 LEB encodings remain valid and carry no
    // immediate bytes after the subopcode.
    const padded = [_]u8{
        0x00, // unreachable supplies the four operands polymorphically
        0xfc, 0x93, 0x00, // i64.add128
        0x1a, 0x1a, 0x0b,
    };
    var module = try moduleWithBody(allocator, &padded);
    defer module.deinit();
    try Validator.validate(&module, wide_options);
    var pos: usize = 1;
    const decoded = try binary_instr.decode(&padded, &pos);
    try std.testing.expectEqual(@as(u32, 0x13), decoded.code);
    try std.testing.expectEqual(binary_instr.Imm.none, decoded.shape);
    try std.testing.expectEqual(@as(usize, 4), pos);
}
