//! Runtime and CLI regression suite for `wabt module optimize`.
//!
//! Validates that `wabt module optimize` preserves observable WebAssembly
//! semantics (return values, side effects, host imports, start functions, and
//! traps) when executed under Wasmtime, enforces CLI safety/policy rules, and
//! reports binary size reductions across a representative corpus.

const std = @import("std");

const usage_text =
    \\Usage: optimize_regression [options]
    \\
    \\wabt module optimize runtime regression gate.
    \\
    \\Options:
    \\  --wabt <path>         Path to the wabt CLI binary (default: wabt)
    \\  --wasmtime <path>     Path to the wasmtime CLI binary
    \\  --work-dir <dir>      Working directory for generated artifacts
    \\  --require-wasmtime    Fail (not skip) when no usable Wasmtime is found
    \\  -h, --help            Print this help and exit
    \\
;

const CmdResult = struct {
    returncode: i32,
    stdout: []const u8,
    stderr: []const u8,
    combined: []const u8,
};

const Invocation = struct {
    export_name: []const u8,
    args: []const []const u8 = &.{},
    expected_stdout: ?[]const []const u8 = null,
    expected_trap: ?[]const u8 = null,
};

const BehavioralFixture = struct {
    name: []const u8,
    category: []const u8,
    wat: []const u8,
    invocations: []const Invocation,
    companion_wat: ?[]const u8 = null,
    companion_name: []const u8 = "host",
    expect_shrink: bool = true,
    optimize_flags: []const []const u8 = &.{},
};

const SizeRecord = struct {
    name: []const u8,
    category: []const u8,
    before_bytes: usize,
    after_bytes: usize,

    fn delta(self: SizeRecord) i64 {
        return @as(i64, @intCast(self.after_bytes)) - @as(i64, @intCast(self.before_bytes));
    }
};

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, text) catch {};
}

fn writeStderr(io: std.Io, text: []const u8) void {
    var stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, text) catch {};
}

fn printStdout(io: std.Io, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    writeStdout(io, msg);
}

fn printStderr(io: std.Io, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    writeStderr(io, msg);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn isDir(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn fileSize(io: std.Io, path: []const u8) !usize {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    return @intCast(stat.size);
}

fn runCmd(
    alloc: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) !CmdResult {
    const result = std.process.run(alloc, io, .{
        .argv = argv,
        .environ_map = env_map,
        .stdout_limit = std.Io.Limit.limited(1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
    }) catch |err| {
        const msg = try std.fmt.allocPrint(alloc, "failed to spawn process: {s}", .{@errorName(err)});
        return .{
            .returncode = 127,
            .stdout = "",
            .stderr = msg,
            .combined = msg,
        };
    };

    const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ result.stdout, result.stderr });
    const code: i32 = switch (result.term) {
        .exited => |c| c,
        .signal => |s| -@as(i32, @intCast(@backingInt(s))),
        else => -1,
    };
    return .{
        .returncode = code,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .combined = combined,
    };
}

fn resolveWasmtime(
    alloc: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    explicit: ?[]const u8,
) ?[]const u8 {
    const cand = blk: {
        if (explicit) |exp| {
            if (exp.len > 0) break :blk exp;
        }
        if (env_map.get("WASMTIME")) |val| {
            if (val.len > 0) break :blk val;
        }
        break :blk "wasmtime";
    };
    const res = runCmd(alloc, io, env_map, &.{ cand, "--version" }) catch return null;
    return if (res.returncode == 0) cand else null;
}

fn checkWabt(
    alloc: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    wabt_cand: []const u8,
) bool {
    if (fileExists(io, wabt_cand)) return true;
    const res = runCmd(alloc, io, env_map, &.{ wabt_cand, "version" }) catch return false;
    return res.returncode == 0;
}

fn extractTrapLine(stderr_text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stderr_text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.indexOf(u8, line, "wasm trap:")) |idx| {
            return std.mem.trim(u8, line[idx..], " \t\r\n");
        }
    }
    return null;
}

fn appendUleb(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value_in: usize) !void {
    var value = value_in;
    while (true) {
        var byte: u8 = @intCast(value & 0x7f);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        try out.append(alloc, byte);
        if (value == 0) break;
    }
}

fn makeCustomSection(alloc: std.mem.Allocator, name: []const u8, payload: []const u8) ![]const u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try appendUleb(alloc, &body, name.len);
    try body.appendSlice(alloc, name);
    try body.appendSlice(alloc, payload);

    var section: std.ArrayListUnmanaged(u8) = .empty;
    try section.append(alloc, 0x00);
    try appendUleb(alloc, &section, body.items.len);
    try section.appendSlice(alloc, body.items);
    return section.toOwnedSlice(alloc);
}

const fixtures = [_]BehavioralFixture{
    .{
        .name = "const-fold-i32",
        .category = "constant-folding",
        .expect_shrink = true,
        .wat =
        \\(module
        \\  (func (export "arith_wrap") (result i32)
        \\    ;; (0x7fffffff + 1) ^ ((0x80000000 - 1) + (65536 * 65536))
        \\    ;; = -2147483648 ^ (2147483647 + 0) = -1
        \\    (i32.xor
        \\      (i32.add (i32.const 0x7fffffff) (i32.const 1))
        \\      (i32.add
        \\        (i32.sub (i32.const 0x80000000) (i32.const 1))
        \\        (i32.mul (i32.const 65536) (i32.const 65536)))))
        \\
        \\  (func (export "bitops_shifts") (result i32)
        \\    ;; Bitwise & masked shifts/rotates with shift counts >= 32
        \\    (i32.add
        \\      (i32.xor
        \\        (i32.or (i32.const 0xf0a0) (i32.const 0x0f05))
        \\        (i32.and (i32.const 0xffff) (i32.const 0x5555)))
        \\      (i32.add
        \\        (i32.add
        \\          (i32.shl (i32.const 3) (i32.const 36))
        \\          (i32.shr_s (i32.const -64) (i32.const 35)))
        \\        (i32.add
        \\          (i32.shr_u (i32.const 0x80000000) (i32.const 63))
        \\          (i32.rotl
        \\            (i32.rotr (i32.const 0x12345678) (i32.const 40))
        \\            (i32.const 8))))))
        \\
        \\  (func (export "unary_ops") (result i32)
        \\    (i32.add
        \\      (i32.add
        \\        (i32.sub (i32.eqz (i32.const 0)) (i32.eqz (i32.const 99)))
        \\        (i32.add (i32.clz (i32.const 0x00010000)) (i32.ctz (i32.const 0x00080000))))
        \\      (i32.add
        \\        (i32.popcnt (i32.const 0x0f0f0f0f))
        \\        (i32.add
        \\          (i32.extend8_s (i32.const 0x00000080))
        \\          (i32.extend16_s (i32.const 0x0000ff80))))))
        \\
        \\  (func (export "comparisons") (result i32)
        \\    ;; Pack 10 boolean comparison results into a 10-bit mask:
        \\    ;; bit0: eq(7,7)=1
        \\    ;; bit1: ne(7,8)=1
        \\    ;; bit2: lt_s(-1,1)=1
        \\    ;; bit3: lt_u(-1,1)=0
        \\    ;; bit4: gt_s(1,-1)=1
        \\    ;; bit5: gt_u(-1,1)=1
        \\    ;; bit6: le_s(-1,-1)=1
        \\    ;; bit7: le_u(1,-1)=1
        \\    ;; bit8: ge_s(-2,-1)=0
        \\    ;; bit9: ge_u(-1,1)=1
        \\    ;; mask = 1 + 2 + 4 + 0 + 16 + 32 + 64 + 128 + 0 + 512 = 759
        \\    (i32.or
        \\      (i32.or
        \\        (i32.or
        \\          (i32.eq (i32.const 7) (i32.const 7))
        \\          (i32.shl (i32.ne (i32.const 7) (i32.const 8)) (i32.const 1)))
        \\        (i32.or
        \\          (i32.shl (i32.lt_s (i32.const -1) (i32.const 1)) (i32.const 2))
        \\          (i32.shl (i32.lt_u (i32.const -1) (i32.const 1)) (i32.const 3))))
        \\      (i32.or
        \\        (i32.or
        \\          (i32.shl (i32.gt_s (i32.const 1) (i32.const -1)) (i32.const 4))
        \\          (i32.shl (i32.gt_u (i32.const -1) (i32.const 1)) (i32.const 5)))
        \\        (i32.or
        \\          (i32.or
        \\            (i32.shl (i32.le_s (i32.const -1) (i32.const -1)) (i32.const 6))
        \\            (i32.shl (i32.le_u (i32.const 1) (i32.const -1)) (i32.const 7)))
        \\          (i32.or
        \\            (i32.shl (i32.ge_s (i32.const -2) (i32.const -1)) (i32.const 8))
        \\            (i32.shl (i32.ge_u (i32.const -1) (i32.const 1)) (i32.const 9)))))))
        \\)
        ,
        .invocations = &.{
            .{ .export_name = "arith_wrap", .expected_stdout = &.{"-1"} },
            .{ .export_name = "bitops_shifts", .expected_stdout = &.{"305463697"} },
            .{ .export_name = "unary_ops", .expected_stdout = &.{"-205"} },
            .{ .export_name = "comparisons", .expected_stdout = &.{"759"} },
        },
    },
    .{
        .name = "const-fold-i64",
        .category = "constant-folding",
        .expect_shrink = true,
        .wat =
        \\(module
        \\  (func (export "arith64_wrap") (result i64)
        \\    ;; (0x7fffffffffffffff + 1) ^ ((0x8000000000000000 - 1) + (0x100000000 * 0x100000000))
        \\    ;; = -1
        \\    (i64.xor
        \\      (i64.add (i64.const 0x7fffffffffffffff) (i64.const 1))
        \\      (i64.add
        \\        (i64.sub (i64.const 0x8000000000000000) (i64.const 1))
        \\        (i64.mul (i64.const 0x100000000) (i64.const 0x100000000)))))
        \\
        \\  (func (export "bitops_shifts64") (result i64)
        \\    (i64.add
        \\      (i64.xor
        \\        (i64.or (i64.const 0xf0f000000000) (i64.const 0x0f0f00000000))
        \\        (i64.and (i64.const 0xffff00000000) (i64.const 0x555500000000)))
        \\      (i64.add
        \\        (i64.add
        \\          (i64.shl (i64.const 5) (i64.const 68))
        \\          (i64.shr_s (i64.const -128) (i64.const 67)))
        \\        (i64.add
        \\          (i64.shr_u (i64.const 0x8000000000000000) (i64.const 127))
        \\          (i64.rotl
        \\            (i64.rotr (i64.const 0x0102030405060708) (i64.const 72))
        \\            (i64.const 8))))))
        \\
        \\  (func (export "unary64_ops") (result i64)
        \\    (i64.add
        \\      (i64.extend_i32_s
        \\        (i32.sub (i64.eqz (i64.const 0)) (i64.eqz (i64.const 1))))
        \\      (i64.add
        \\        (i64.add (i64.clz (i64.const 1)) (i64.ctz (i64.const 32)))
        \\        (i64.add
        \\          (i64.popcnt (i64.const 0xff00ff00))
        \\          (i64.add
        \\            (i64.extend8_s (i64.const 0x80))
        \\            (i64.add
        \\              (i64.extend16_s (i64.const 0x8000))
        \\              (i64.extend32_s (i64.const 0x80000000))))))))
        \\
        \\  (func (export "comparisons64") (result i32)
        \\    ;; bit0: eq=1, bit1: ne=1, bit2: lt_s=1, bit3: lt_u=0, bit4: gt_s=1,
        \\    ;; bit5: gt_u=1, bit6: le_s=1, bit7: le_u=1, bit8: ge_s=0, bit9: ge_u=1 -> 759
        \\    (i32.or
        \\      (i32.or
        \\        (i32.or
        \\          (i64.eq (i64.const 42) (i64.const 42))
        \\          (i32.shl (i64.ne (i64.const 42) (i64.const 43)) (i32.const 1)))
        \\        (i32.or
        \\          (i32.shl (i64.lt_s (i64.const -10) (i64.const 10)) (i32.const 2))
        \\          (i32.shl (i64.lt_u (i64.const -10) (i64.const 10)) (i32.const 3))))
        \\      (i32.or
        \\        (i32.or
        \\          (i32.shl (i64.gt_s (i64.const 10) (i64.const -10)) (i32.const 4))
        \\          (i32.shl (i64.gt_u (i64.const -10) (i64.const 10)) (i32.const 5)))
        \\        (i32.or
        \\          (i32.or
        \\            (i32.shl (i64.le_s (i64.const -10) (i64.const -10)) (i32.const 6))
        \\            (i32.shl (i64.le_u (i64.const 10) (i64.const -10)) (i32.const 7)))
        \\          (i32.or
        \\            (i32.shl (i64.ge_s (i64.const -20) (i64.const -10)) (i32.const 8))
        \\            (i32.shl (i64.ge_u (i64.const -10) (i64.const 10)) (i32.const 9)))))))
        \\)
        ,
        .invocations = &.{
            .{ .export_name = "arith64_wrap", .expected_stdout = &.{"-1"} },
            .{ .export_name = "bitops_shifts64", .expected_stdout = &.{"72811506911545161"} },
            .{ .export_name = "unary64_ops", .expected_stdout = &.{"-2147516459"} },
            .{ .export_name = "comparisons64", .expected_stdout = &.{"759"} },
        },
    },
    .{
        .name = "control-flow-simplification",
        .category = "control-flow",
        .expect_shrink = true,
        .wat =
        \\(module
        \\  (type $pair (func (result i32 i32)))
        \\  (global $side (mut i32) (i32.const 0))
        \\
        \\  (func (export "const_if_branches") (result i32)
        \\    (nop)
        \\    (block
        \\      (nop))
        \\    (if (i32.const 0)
        \\      (then (global.set $side (i32.const 999))))
        \\    (if (i32.const 1)
        \\      (then (global.set $side (i32.const 10))))
        \\    (i32.add
        \\      (global.get $side)
        \\      (i32.add
        \\        (if (result i32) (i32.const 5)
        \\          (then (i32.add (i32.const 11) (i32.const 21)))
        \\          (else (i32.const 500)))
        \\        (if (result i32) (i32.const 0)
        \\          (then (i32.const 600))
        \\          (else (i32.sub (i32.const 20) (i32.const 12)))))))
        \\
        \\  (func (export "nested_if_self_and_outer_br") (param i32) (result i32)
        \\    (block $outer (result i32)
        \\      ;; Truthy constant-if with branches targeting inner (0), the if itself (1), and $outer (2)
        \\      (if (result i32) (i32.const 1)
        \\        (then
        \\          (drop
        \\            (block $inner (result i32)
        \\              (i32.const 300)
        \\              (local.get 0)
        \\              (br_table 0 1 2 0)))
        \\          (i32.const 100)
        \\          (br_if 0 (i32.eq (local.get 0) (i32.const 0)))
        \\          (drop)
        \\          (i32.const 200))
        \\        (else
        \\          (i32.const 999)))
        \\      (i32.const 5)
        \\      (i32.add)))
        \\
        \\  (func (export "const_br_if_and_empty_blocks") (result i32)
        \\    (block (result i32)
        \\      (block)
        \\      (nop)
        \\      (i32.const 11)
        \\      (br_if 0 (i32.const 0))
        \\      (drop)
        \\      (i32.const 77)
        \\      (br_if 0 (i32.const 9))
        \\      (drop)
        \\      (i32.const 88)))
        \\
        \\  (func (export "multivalue_if") (type $pair) (result i32 i32)
        \\    (if (type $pair) (i32.const 0)
        \\      (then (i32.const 1) (i32.const 2))
        \\      (else
        \\        (i32.add (i32.const 30) (i32.const 12))
        \\        (i32.mul (i32.const 100) (i32.const 3)))))
        \\)
        ,
        .invocations = &.{
            .{ .export_name = "const_if_branches", .expected_stdout = &.{"50"} },
            .{ .export_name = "nested_if_self_and_outer_br", .args = &.{"0"}, .expected_stdout = &.{"105"} },
            .{ .export_name = "nested_if_self_and_outer_br", .args = &.{"1"}, .expected_stdout = &.{"305"} },
            .{ .export_name = "nested_if_self_and_outer_br", .args = &.{"2"}, .expected_stdout = &.{"300"} },
            .{ .export_name = "nested_if_self_and_outer_br", .args = &.{"3"}, .expected_stdout = &.{"205"} },
            .{ .export_name = "const_br_if_and_empty_blocks", .expected_stdout = &.{"77"} },
            .{ .export_name = "multivalue_if", .expected_stdout = &.{ "42", "300" } },
        },
    },
    .{
        .name = "dead-code-elimination",
        .category = "dead-code",
        .expect_shrink = true,
        .wat =
        \\(module
        \\  (memory 1)
        \\  (global $g (mut i32) (i32.const 0))
        \\
        \\  (func $record_call (param i32)
        \\    (global.set $g (i32.add (global.get $g) (local.get 0))))
        \\
        \\  (func $after_return_and_br_impl (param i32) (result i32)
        \\    (call $record_call (i32.const 5))
        \\    (i32.store (i32.const 0) (i32.const 40))
        \\    (if (result i32) (local.get 0)
        \\      (then
        \\        (call $record_call (i32.const 2))
        \\        (return (i32.add (global.get $g) (i32.load (i32.const 0))))
        \\        (global.set $g (i32.const 9999))
        \\        (i32.store (i32.const 0) (i32.const 8888))
        \\        (i32.const -1))
        \\      (else
        \\        (block $b (result i32)
        \\          (i32.store (i32.const 4) (i32.const 13))
        \\          (br $b (i32.add (global.get $g) (i32.load (i32.const 4))))
        \\          (global.set $g (i32.const 7777))
        \\          (i32.const -2))))
        \\    (return)
        \\    (global.set $g (i32.const 6666))
        \\    (i32.const -3))
        \\
        \\  (func (export "after_return_and_br") (param i32) (result i32)
        \\    (call $after_return_and_br_impl (local.get 0)))
        \\
        \\  (func (export "after_br_table") (param i32) (result i32)
        \\    (block $out (result i32)
        \\      (block $mid (result i32)
        \\        (i32.const 90)
        \\        (local.get 0)
        \\        (br_table $mid $out $mid)
        \\        (global.set $g (i32.const 5555))
        \\        (i32.const 1234))
        \\      (i32.add (i32.const 9))))
        \\
        \\  (func (export "run_and_read_state") (result i32)
        \\    (drop (call $after_return_and_br_impl (i32.const 1)))
        \\    (drop (call $after_return_and_br_impl (i32.const 0)))
        \\    (i32.add
        \\      (global.get $g)
        \\      (i32.add (i32.load (i32.const 0)) (i32.load (i32.const 4)))))
        \\)
        ,
        .invocations = &.{
            .{ .export_name = "after_return_and_br", .args = &.{"1"}, .expected_stdout = &.{"47"} },
            .{ .export_name = "after_return_and_br", .args = &.{"0"}, .expected_stdout = &.{"18"} },
            .{ .export_name = "after_br_table", .args = &.{"0"}, .expected_stdout = &.{"99"} },
            .{ .export_name = "after_br_table", .args = &.{"1"}, .expected_stdout = &.{"90"} },
            .{ .export_name = "run_and_read_state", .expected_stdout = &.{"65"} },
        },
    },
    .{
        .name = "dead-func-and-remap",
        .category = "dead-function-removal",
        .expect_shrink = true,
        .companion_name = "host",
        .companion_wat =
        \\(module
        \\  (func (export "add_bias") (param i32) (result i32)
        \\    (i32.add (local.get 0) (i32.const 100)))
        \\  (func (export "scale") (param i32) (result i32)
        \\    (i32.mul (local.get 0) (i32.const 3)))
        \\)
        ,
        .wat =
        \\(module
        \\  (type $unary (func (param i32) (result i32)))
        \\  (import "host" "add_bias" (func $imp_bias (param i32) (result i32)))
        \\  (import "host" "scale" (func $imp_scale (param i32) (result i32)))
        \\
        \\  (table $tab 4 funcref)
        \\  (memory 1)
        \\  (global $boot_val (mut i32) (i32.const 0))
        \\  (global $gref funcref (ref.func $from_global_ref))
        \\
        \\  (start $on_start)
        \\
        \\  ;; Active element segment at slot 0
        \\  (elem (i32.const 0) func $from_active_elem)
        \\  ;; Passive element segment loaded dynamically via table.init
        \\  (elem $passive_seg func $from_passive_elem)
        \\  ;; Declared element segment enabling ref.func in code
        \\  (elem declare func $from_declared_ref)
        \\
        \\  (func $dead_unused_0 (param i32) (result i32)
        \\    (i32.add (local.get 0) (i32.const 1111)))
        \\
        \\  (func $on_start
        \\    (global.set $boot_val (call $start_helper (i32.const 7)))
        \\    (i32.store (i32.const 0) (global.get $boot_val)))
        \\
        \\  (func $dead_unused_chain_a (result i32)
        \\    (call $dead_unused_chain_b))
        \\
        \\  (func $dead_unused_chain_b (result i32)
        \\    (call $dead_unused_0 (i32.const 2222)))
        \\
        \\  (func $start_helper (param i32) (result i32)
        \\    (call $imp_bias (local.get 0)))
        \\
        \\  (func $from_active_elem (type $unary) (param i32) (result i32)
        \\    (i32.add (call $imp_scale (local.get 0)) (i32.const 1)))
        \\
        \\  (func $from_passive_elem (type $unary) (param i32) (result i32)
        \\    (i32.add (call $imp_bias (local.get 0)) (i32.const 2)))
        \\
        \\  (func $from_declared_ref (type $unary) (param i32) (result i32)
        \\    (i32.add (local.get 0) (i32.const 30)))
        \\
        \\  (func $from_global_ref (type $unary) (param i32) (result i32)
        \\    (i32.add (local.get 0) (i32.const 40)))
        \\
        \\  (func $dead_from_folded_if (param i32) (result i32)
        \\    (i32.add (local.get 0) (i32.const 9999)))
        \\
        \\  (func $tail_callee (param i32) (result i32)
        \\    (call $imp_scale (i32.add (local.get 0) (global.get $boot_val))))
        \\
        \\  (func (export "check_start") (result i32)
        \\    (i32.add (global.get $boot_val) (i32.load (i32.const 0))))
        \\
        \\  (func (export "run_direct_and_tail") (param i32) (result i32)
        \\    (if (result i32) (i32.eq (i32.const 10) (i32.const 20))
        \\      (then (call $dead_from_folded_if (local.get 0)))
        \\      (else (return_call $tail_callee (local.get 0)))))
        \\
        \\  (func (export "run_table_dispatches") (param i32) (result i32)
        \\    ;; Slot 0 is already $from_active_elem; populate slots 1, 2, 3 from passive, declared, and global ref.func
        \\    (table.init $tab $passive_seg (i32.const 1) (i32.const 0) (i32.const 1))
        \\    (table.set $tab (i32.const 2) (ref.func $from_declared_ref))
        \\    (table.set $tab (i32.const 3) (global.get $gref))
        \\    (i32.add
        \\      (i32.add
        \\        (call_indirect $tab (type $unary) (local.get 0) (i32.const 0))
        \\        (call_indirect $tab (type $unary) (local.get 0) (i32.const 1)))
        \\      (i32.add
        \\        (call_indirect $tab (type $unary) (local.get 0) (i32.const 2))
        \\        (call_indirect $tab (type $unary) (local.get 0) (i32.const 3)))))
        \\)
        ,
        .invocations = &.{
            .{ .export_name = "check_start", .expected_stdout = &.{"214"} },
            .{ .export_name = "run_direct_and_tail", .args = &.{"5"}, .expected_stdout = &.{"336"} },
            .{ .export_name = "run_table_dispatches", .args = &.{"10"}, .expected_stdout = &.{"233"} },
        },
    },
    .{
        .name = "preserved-traps-and-effects",
        .category = "traps-and-effects",
        .expect_shrink = true,
        .wat =
        \\(module
        \\  (memory 1)
        \\  (global $state (mut i32) (i32.const 10))
        \\  (start $init)
        \\
        \\  (func $dead_helper (result i32)
        \\    (i32.const 424242))
        \\
        \\  (func $init
        \\    (global.set $state (i32.add (global.get $state) (i32.add (i32.const 2) (i32.const 3))))
        \\    (i32.store (i32.const 8) (i32.const 77)))
        \\
        \\  (func (export "read_initialized") (result i32)
        \\    (i32.add (global.get $state) (i32.load (i32.const 8))))
        \\
        \\  (func (export "trap_div_s_zero") (result i32)
        \\    (i32.div_s (i32.add (i32.const 10) (i32.const 5)) (i32.const 0)))
        \\
        \\  (func (export "trap_div_u_zero") (result i32)
        \\    (i32.div_u (i32.const 15) (i32.sub (i32.const 4) (i32.const 4))))
        \\
        \\  (func (export "trap_rem_s_zero64") (result i64)
        \\    (i64.rem_s (i64.const 99) (i64.const 0)))
        \\
        \\  (func (export "trap_div_s_overflow") (result i32)
        \\    (i32.div_s (i32.const -2147483648) (i32.const -1)))
        \\
        \\  (func (export "trap_oob_load") (result i32)
        \\    (i32.load (i32.const 65536)))
        \\
        \\  (func (export "trap_oob_store")
        \\    (i32.store (i32.const 65536) (i32.const 1)))
        \\
        \\  (func (export "trap_unreachable_after_effect") (result i32)
        \\    (global.set $state (i32.const 99))
        \\    (i32.store (i32.const 0) (i32.const 55))
        \\    (unreachable)
        \\    (i32.const 0))
        \\)
        ,
        .invocations = &.{
            .{ .export_name = "read_initialized", .expected_stdout = &.{"92"} },
            .{ .export_name = "trap_div_s_zero", .expected_trap = "integer divide by zero" },
            .{ .export_name = "trap_div_u_zero", .expected_trap = "integer divide by zero" },
            .{ .export_name = "trap_rem_s_zero64", .expected_trap = "integer divide by zero" },
            .{ .export_name = "trap_div_s_overflow", .expected_trap = "integer overflow" },
            .{ .export_name = "trap_oob_load", .expected_trap = "out of bounds memory access" },
            .{ .export_name = "trap_oob_store", .expected_trap = "out of bounds memory access" },
            .{ .export_name = "trap_unreachable_after_effect", .expected_trap = "unreachable" },
        },
    },
};

fn formatSignedInt(buf: []u8, val: i64) ![]const u8 {
    if (val >= 0) {
        return std.fmt.bufPrint(buf, "+{d}", .{val});
    }
    return std.fmt.bufPrint(buf, "{d}", .{val});
}

fn formatSignedPct(buf: []u8, delta_val: i64, before_bytes: usize) ![]const u8 {
    if (before_bytes == 0) {
        return std.fmt.bufPrint(buf, "+0.0%", .{});
    }
    const sign: u8 = if (delta_val >= 0) '+' else '-';
    const abs_delta: u64 = @intCast(if (delta_val >= 0) delta_val else -delta_val);
    const b: u64 = @intCast(before_bytes);
    const tenths = (abs_delta * 1000 + b / 2) / b;
    return std.fmt.bufPrint(buf, "{c}{d}.{d}%", .{ sign, tenths / 10, tenths % 10 });
}

fn formatInvocationLabel(alloc: std.mem.Allocator, fixture_name: []const u8, inv: Invocation) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(alloc, fixture_name);
    try buf.appendSlice(alloc, "::");
    try buf.appendSlice(alloc, inv.export_name);
    try buf.append(alloc, '(');
    for (inv.args, 0..) |a, idx| {
        if (idx > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, a);
    }
    try buf.append(alloc, ')');
    return buf.toOwnedSlice(alloc);
}

fn runBehavioralFixture(
    alloc: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    fixture: BehavioralFixture,
    work_dir: []const u8,
    wabt_path: []const u8,
    wasmtime: []const u8,
    sizes: *std.ArrayListUnmanaged(SizeRecord),
    failures: *std.ArrayListUnmanaged([]const u8),
) !bool {
    const cwd = std.Io.Dir.cwd();
    const case_dir = try std.fs.path.join(alloc, &.{ work_dir, fixture.name });
    try cwd.createDirPath(io, case_dir);

    const wat_filename = try std.fmt.allocPrint(alloc, "{s}.wat", .{fixture.name});
    const wat_path = try std.fs.path.join(alloc, &.{ case_dir, wat_filename });
    const before_wasm = try std.fs.path.join(alloc, &.{ case_dir, "before.wasm" });
    const after_wasm = try std.fs.path.join(alloc, &.{ case_dir, "after.wasm" });

    const wat_text = try std.fmt.allocPrint(alloc, "{s}\n", .{std.mem.trim(u8, fixture.wat, " \t\r\n")});
    try cwd.writeFile(io, .{ .sub_path = wat_path, .data = wat_text });

    var preload_args: std.ArrayListUnmanaged([]const u8) = .empty;
    if (fixture.companion_wat) |comp_wat_src| {
        const comp_wat_name = try std.fmt.allocPrint(alloc, "{s}.wat", .{fixture.companion_name});
        const comp_wasm_name = try std.fmt.allocPrint(alloc, "{s}.wasm", .{fixture.companion_name});
        const comp_wat = try std.fs.path.join(alloc, &.{ case_dir, comp_wat_name });
        const comp_wasm = try std.fs.path.join(alloc, &.{ case_dir, comp_wasm_name });
        const comp_text = try std.fmt.allocPrint(alloc, "{s}\n", .{std.mem.trim(u8, comp_wat_src, " \t\r\n")});
        try cwd.writeFile(io, .{ .sub_path = comp_wat, .data = comp_text });

        const comp_parse = try runCmd(alloc, io, env_map, &.{ wabt_path, "text", "parse", comp_wat, "-o", comp_wasm });
        if (comp_parse.returncode != 0) {
            try failures.append(
                alloc,
                try std.fmt.allocPrint(
                    alloc,
                    "{s}: companion parse failed ({d}):\n{s}",
                    .{ fixture.name, comp_parse.returncode, std.mem.trim(u8, comp_parse.combined, " \t\r\n") },
                ),
            );
            return false;
        }
        try preload_args.append(alloc, "--preload");
        try preload_args.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}", .{ fixture.companion_name, comp_wasm }));
    }

    const parse_res = try runCmd(alloc, io, env_map, &.{ wabt_path, "text", "parse", wat_path, "-o", before_wasm });
    if (parse_res.returncode != 0) {
        try failures.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "{s}: `wabt text parse` failed ({d}):\n{s}",
                .{ fixture.name, parse_res.returncode, std.mem.trim(u8, parse_res.combined, " \t\r\n") },
            ),
        );
        return false;
    }

    var opt_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try opt_argv.appendSlice(alloc, &.{ wabt_path, "module", "optimize" });
    try opt_argv.appendSlice(alloc, fixture.optimize_flags);
    try opt_argv.appendSlice(alloc, &.{ before_wasm, "-o", after_wasm });

    const opt_res = try runCmd(alloc, io, env_map, opt_argv.items);
    if (opt_res.returncode != 0) {
        try failures.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "{s}: `wabt module optimize` failed ({d}):\n{s}",
                .{ fixture.name, opt_res.returncode, std.mem.trim(u8, opt_res.combined, " \t\r\n") },
            ),
        );
        return false;
    }

    const val_res = try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "validate", after_wasm });
    if (val_res.returncode != 0) {
        try failures.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "{s}: `wabt module validate` failed on after.wasm ({d}):\n{s}",
                .{ fixture.name, val_res.returncode, std.mem.trim(u8, val_res.combined, " \t\r\n") },
            ),
        );
        return false;
    }

    const before_size = try fileSize(io, before_wasm);
    const after_size = try fileSize(io, after_wasm);
    try sizes.append(alloc, .{
        .name = fixture.name,
        .category = fixture.category,
        .before_bytes = before_size,
        .after_bytes = after_size,
    });

    if (fixture.expect_shrink and !(after_size < before_size)) {
        try failures.append(
            alloc,
            try std.fmt.allocPrint(
                alloc,
                "{s}: expected optimized binary to shrink, got {d} -> {d} bytes",
                .{ fixture.name, before_size, after_size },
            ),
        );
        return false;
    }

    var ok = true;
    for (fixture.invocations) |inv| {
        var before_cmd: std.ArrayListUnmanaged([]const u8) = .empty;
        try before_cmd.appendSlice(alloc, &.{ wasmtime, "run" });
        try before_cmd.appendSlice(alloc, preload_args.items);
        try before_cmd.appendSlice(alloc, &.{ "--invoke", inv.export_name, before_wasm });
        try before_cmd.appendSlice(alloc, inv.args);

        var after_cmd: std.ArrayListUnmanaged([]const u8) = .empty;
        try after_cmd.appendSlice(alloc, &.{ wasmtime, "run" });
        try after_cmd.appendSlice(alloc, preload_args.items);
        try after_cmd.appendSlice(alloc, &.{ "--invoke", inv.export_name, after_wasm });
        try after_cmd.appendSlice(alloc, inv.args);

        const before_run = try runCmd(alloc, io, env_map, before_cmd.items);
        const after_run = try runCmd(alloc, io, env_map, after_cmd.items);

        const label = try formatInvocationLabel(alloc, fixture.name, inv);
        if (before_run.returncode != after_run.returncode) {
            try failures.append(
                alloc,
                try std.fmt.allocPrint(
                    alloc,
                    "{s}: exit status mismatch: before={d}, after={d}\n--- before ---\n{s}\n--- after ---\n{s}",
                    .{
                        label,
                        before_run.returncode,
                        after_run.returncode,
                        std.mem.trim(u8, before_run.combined, " \t\r\n"),
                        std.mem.trim(u8, after_run.combined, " \t\r\n"),
                    },
                ),
            );
            ok = false;
            continue;
        }

        if (inv.expected_trap) |expected_trap| {
            if (before_run.returncode == 0) {
                try failures.append(
                    alloc,
                    try std.fmt.allocPrint(
                        alloc,
                        "{s}: expected trap '{s}', but execution succeeded",
                        .{ label, expected_trap },
                    ),
                );
                ok = false;
                continue;
            }
            const before_trap = extractTrapLine(before_run.stderr);
            const after_trap = extractTrapLine(after_run.stderr);
            if (before_trap == null or after_trap == null or !std.mem.eql(u8, before_trap.?, after_trap.?)) {
                try failures.append(
                    alloc,
                    try std.fmt.allocPrint(
                        alloc,
                        "{s}: trap line mismatch: before='{s}', after='{s}'\n--- before stderr ---\n{s}\n--- after stderr ---\n{s}",
                        .{
                            label,
                            before_trap orelse "<none>",
                            after_trap orelse "<none>",
                            std.mem.trim(u8, before_run.stderr, " \t\r\n"),
                            std.mem.trim(u8, after_run.stderr, " \t\r\n"),
                        },
                    ),
                );
                ok = false;
                continue;
            }
            if (std.mem.indexOf(u8, after_trap.?, expected_trap) == null) {
                try failures.append(
                    alloc,
                    try std.fmt.allocPrint(
                        alloc,
                        "{s}: expected trap containing '{s}', got '{s}'",
                        .{ label, expected_trap, after_trap.? },
                    ),
                );
                ok = false;
                continue;
            }
        } else {
            if (before_run.returncode != 0) {
                try failures.append(
                    alloc,
                    try std.fmt.allocPrint(
                        alloc,
                        "{s}: unexpected non-zero exit ({d}):\n{s}",
                        .{ label, before_run.returncode, std.mem.trim(u8, before_run.combined, " \t\r\n") },
                    ),
                );
                ok = false;
                continue;
            }
            if (!std.mem.eql(u8, before_run.stdout, after_run.stdout)) {
                try failures.append(
                    alloc,
                    try std.fmt.allocPrint(
                        alloc,
                        "{s}: stdout mismatch:\n  before: '{s}'\n  after:  '{s}'",
                        .{
                            label,
                            std.mem.trim(u8, before_run.stdout, " \t\r\n"),
                            std.mem.trim(u8, after_run.stdout, " \t\r\n"),
                        },
                    ),
                );
                ok = false;
                continue;
            }
            if (inv.expected_stdout) |expected_lines| {
                var actual_lines: std.ArrayListUnmanaged([]const u8) = .empty;
                var line_it = std.mem.splitScalar(u8, std.mem.trim(u8, after_run.stdout, " \t\r\n"), '\n');
                while (line_it.next()) |raw_line| {
                    const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
                    if (trimmed.len > 0) {
                        try actual_lines.append(alloc, trimmed);
                    }
                }
                var match = actual_lines.items.len == expected_lines.len;
                if (match) {
                    for (actual_lines.items, expected_lines) |act, exp| {
                        if (!std.mem.eql(u8, act, exp)) {
                            match = false;
                            break;
                        }
                    }
                }
                if (!match) {
                    try failures.append(
                        alloc,
                        try std.fmt.allocPrint(
                            alloc,
                            "{s}: stdout lines did not match expected output (got '{s}')",
                            .{ label, std.mem.trim(u8, after_run.stdout, " \t\r\n") },
                        ),
                    );
                    ok = false;
                    continue;
                }
            }
        }
    }

    return ok;
}

fn recordPolicy(
    alloc: std.mem.Allocator,
    io: std.Io,
    failures: *std.ArrayListUnmanaged([]const u8),
    name: []const u8,
    cond: bool,
    detail: []const u8,
) !void {
    if (cond) {
        try printStdout(io, alloc, "  PASS policy/{s}\n", .{name});
    } else {
        try failures.append(alloc, try std.fmt.allocPrint(alloc, "policy/{s}: {s}", .{ name, detail }));
        try printStdout(io, alloc, "  FAIL policy/{s}\n", .{name});
    }
}

fn runPolicyAndCliChecks(
    alloc: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    work_dir: []const u8,
    wabt_path: []const u8,
    wasmtime: []const u8,
    sizes: *std.ArrayListUnmanaged(SizeRecord),
    failures: *std.ArrayListUnmanaged([]const u8),
) !void {
    const cwd = std.Io.Dir.cwd();
    const policy_dir = try std.fs.path.join(alloc, &.{ work_dir, "policy-checks" });
    try cwd.createDirPath(io, policy_dir);

    // 1. Custom section rejected without --strip-custom, accepted with --strip-custom
    const base_wat = try std.fs.path.join(alloc, &.{ policy_dir, "custom_base.wat" });
    const base_wasm = try std.fs.path.join(alloc, &.{ policy_dir, "custom_base.wasm" });
    const custom_wasm = try std.fs.path.join(alloc, &.{ policy_dir, "with_custom.wasm" });
    const rejected_out = try std.fs.path.join(alloc, &.{ policy_dir, "rejected_custom_out.wasm" });
    const stripped_out = try std.fs.path.join(alloc, &.{ policy_dir, "stripped_custom_out.wasm" });

    try cwd.writeFile(io, .{
        .sub_path = base_wat,
        .data = "(module (func $dead (result i32) (i32.const 99)) (func (export \"answer\") (result i32) (i32.add (i32.const 19) (i32.const 23))))\n",
    });

    const parse_res = try runCmd(alloc, io, env_map, &.{ wabt_path, "text", "parse", base_wat, "-o", base_wasm });
    if (parse_res.returncode != 0) {
        try recordPolicy(
            alloc,
            io,
            failures,
            "custom-section-reject",
            false,
            try std.fmt.allocPrint(alloc, "setup parse failed: {s}", .{std.mem.trim(u8, parse_res.combined, " \t\r\n")}),
        );
    } else {
        const base_bytes = try cwd.readFileAlloc(io, base_wasm, alloc, std.Io.Limit.limited(1024 * 1024));
        const custom_sec = try makeCustomSection(alloc, "producer_meta", "custom-payload-bytes");
        const with_custom_bytes = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base_bytes, custom_sec });
        try cwd.writeFile(io, .{ .sub_path = custom_wasm, .data = with_custom_bytes });

        const reject_res = try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "optimize", custom_wasm, "-o", rejected_out });
        const rejected_exists = fileExists(io, rejected_out);
        try recordPolicy(
            alloc,
            io,
            failures,
            "custom-section-reject",
            reject_res.returncode != 0 and !rejected_exists,
            try std.fmt.allocPrint(
                alloc,
                "expected non-zero exit and no output file, got exit={d}, exists={any}",
                .{ reject_res.returncode, rejected_exists },
            ),
        );

        const strip_res = try runCmd(
            alloc,
            io,
            env_map,
            &.{ wabt_path, "module", "optimize", "--strip-custom", custom_wasm, "-o", stripped_out },
        );
        const stripped_exists = fileExists(io, stripped_out);
        const val_res = if (strip_res.returncode == 0 and stripped_exists)
            try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "validate", stripped_out })
        else
            strip_res;
        const before_exec = try runCmd(alloc, io, env_map, &.{ wasmtime, "run", "--invoke", "answer", custom_wasm });
        const after_exec = if (strip_res.returncode == 0 and stripped_exists)
            try runCmd(alloc, io, env_map, &.{ wasmtime, "run", "--invoke", "answer", stripped_out })
        else
            strip_res;

        var stripped_smaller = false;
        if (strip_res.returncode == 0 and stripped_exists) {
            const custom_size = try fileSize(io, custom_wasm);
            const stripped_size = try fileSize(io, stripped_out);
            stripped_smaller = stripped_size < custom_size;
            try sizes.append(alloc, .{
                .name = "custom-section-strip",
                .category = "policy",
                .before_bytes = custom_size,
                .after_bytes = stripped_size,
            });
        }

        const after_trimmed = std.mem.trim(u8, after_exec.stdout, " \t\r\n");
        try recordPolicy(
            alloc,
            io,
            failures,
            "custom-section-strip",
            strip_res.returncode == 0 and
                val_res.returncode == 0 and
                before_exec.returncode == 0 and
                after_exec.returncode == 0 and
                std.mem.eql(u8, before_exec.stdout, after_exec.stdout) and
                std.mem.eql(u8, after_trimmed, "42") and
                stripped_smaller,
            try std.fmt.allocPrint(
                alloc,
                "strip={d}, validate={d}, stdout='{s}'",
                .{ strip_res.returncode, val_res.returncode, after_trimmed },
            ),
        );
    }

    // 2. Unsupported proposals rejected cleanly before creating output
    const UnsupportedCase = struct {
        name: []const u8,
        wat: []const u8,
    };
    const unsupported_cases = [_]UnsupportedCase{
        .{ .name = "reject-simd", .wat = "(module (func (export \"f\") (drop (v128.const i32x4 1 2 3 4))))\n" },
        .{ .name = "reject-atomics", .wat = "(module (memory 1 1 shared) (func (export \"f\") (drop (i32.atomic.load (i32.const 0)))))\n" },
        .{ .name = "reject-gc-struct", .wat = "(module (type $s (struct (field i32))) (func (export \"f\")))\n" },
        .{ .name = "reject-exceptions-try-table", .wat = "(module (func (export \"f\") (block (try_table (catch_all 0) (nop)))))\n" },
    };

    for (unsupported_cases) |uc| {
        const u_wat = try std.fs.path.join(alloc, &.{ policy_dir, try std.fmt.allocPrint(alloc, "{s}.wat", .{uc.name}) });
        const u_wasm = try std.fs.path.join(alloc, &.{ policy_dir, try std.fmt.allocPrint(alloc, "{s}.wasm", .{uc.name}) });
        const u_out = try std.fs.path.join(alloc, &.{ policy_dir, try std.fmt.allocPrint(alloc, "{s}.out.wasm", .{uc.name}) });
        try cwd.writeFile(io, .{ .sub_path = u_wat, .data = uc.wat });

        const p_res = try runCmd(alloc, io, env_map, &.{ wabt_path, "text", "parse", u_wat, "-o", u_wasm });
        if (p_res.returncode != 0) {
            try recordPolicy(
                alloc,
                io,
                failures,
                uc.name,
                false,
                try std.fmt.allocPrint(alloc, "setup parse failed: {s}", .{std.mem.trim(u8, p_res.combined, " \t\r\n")}),
            );
            continue;
        }
        const o_res = try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "optimize", u_wasm, "-o", u_out });
        const out_exists = fileExists(io, u_out);
        try recordPolicy(
            alloc,
            io,
            failures,
            uc.name,
            o_res.returncode != 0 and !out_exists,
            try std.fmt.allocPrint(
                alloc,
                "expected rejection and no output file, got exit={d}, exists={any}",
                .{ o_res.returncode, out_exists },
            ),
        );
    }

    // 3. Missing -o and input/output path aliasing rejected without clobbering input
    const alias_in = try std.fs.path.join(alloc, &.{ policy_dir, "alias_input.wasm" });
    const original_bytes = try cwd.readFileAlloc(io, base_wasm, alloc, std.Io.Limit.limited(1024 * 1024));
    try cwd.writeFile(io, .{ .sub_path = alias_in, .data = original_bytes });

    const missing_o = try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "optimize", alias_in });
    const after_missing_bytes = try cwd.readFileAlloc(io, alias_in, alloc, std.Io.Limit.limited(1024 * 1024));
    try recordPolicy(
        alloc,
        io,
        failures,
        "reject-missing-output-flag",
        missing_o.returncode != 0 and std.mem.eql(u8, after_missing_bytes, original_bytes),
        try std.fmt.allocPrint(alloc, "expected non-zero exit and intact input, got exit={d}", .{missing_o.returncode}),
    );

    const same_path = try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "optimize", alias_in, "-o", alias_in });
    const dot_alias_path = try std.fmt.allocPrint(alloc, "{s}/./alias_input.wasm", .{policy_dir});
    const dot_alias = try runCmd(alloc, io, env_map, &.{ wabt_path, "module", "optimize", alias_in, "-o", dot_alias_path });
    const after_alias_bytes = try cwd.readFileAlloc(io, alias_in, alloc, std.Io.Limit.limited(1024 * 1024));
    const intact = std.mem.eql(u8, after_alias_bytes, original_bytes);
    try recordPolicy(
        alloc,
        io,
        failures,
        "reject-input-output-alias",
        same_path.returncode != 0 and dot_alias.returncode != 0 and intact,
        try std.fmt.allocPrint(
            alloc,
            "same_path={d}, dot_alias={d}, intact={any}",
            .{ same_path.returncode, dot_alias.returncode, intact },
        ),
    );
}

fn printSizeReport(io: std.Io, alloc: std.mem.Allocator, sizes: []const SizeRecord) !void {
    try printStdout(io, alloc, "\nByte-size report (before -> after):\n", .{});
    try printStdout(
        io,
        alloc,
        "  {s: <28} {s: <22} {s: >8} {s: >8} {s: >8} {s: >8}\n",
        .{ "Fixture", "Category", "Before", "After", "Delta", "Change" },
    );
    try printStdout(
        io,
        alloc,
        "  ---------------------------- ---------------------- -------- -------- -------- --------\n",
        .{},
    );

    var total_before: usize = 0;
    var total_after: usize = 0;
    var delta_buf: [32]u8 = undefined;
    var pct_buf: [32]u8 = undefined;

    for (sizes) |rec| {
        total_before += rec.before_bytes;
        total_after += rec.after_bytes;
        const d = rec.delta();
        const delta_str = try formatSignedInt(&delta_buf, d);
        const pct_str = try formatSignedPct(&pct_buf, d, rec.before_bytes);
        try printStdout(
            io,
            alloc,
            "  {s: <28} {s: <22} {d: >8} {d: >8} {s: >8} {s: >8}\n",
            .{ rec.name, rec.category, rec.before_bytes, rec.after_bytes, delta_str, pct_str },
        );
    }

    const total_delta = @as(i64, @intCast(total_after)) - @as(i64, @intCast(total_before));
    const total_delta_str = try formatSignedInt(&delta_buf, total_delta);
    const total_pct_str = try formatSignedPct(&pct_buf, total_delta, total_before);
    try printStdout(
        io,
        alloc,
        "  ---------------------------- ---------------------- -------- -------- -------- --------\n",
        .{},
    );
    try printStdout(
        io,
        alloc,
        "  {s: <28} {s: <22} {d: >8} {d: >8} {s: >8} {s: >8}\n",
        .{ "TOTAL", "all fixtures", total_before, total_after, total_delta_str, total_pct_str },
    );
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    var wabt_arg: []const u8 = "wabt";
    var wasmtime_arg: ?[]const u8 = null;
    var work_dir_arg: ?[]const u8 = null;
    var require_wasmtime = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(io, usage_text);
            return;
        } else if (std.mem.eql(u8, arg, "--wabt")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --wabt requires an argument\n");
                std.process.exit(2);
            }
            wabt_arg = args[i];
        } else if (std.mem.startsWith(u8, arg, "--wabt=")) {
            wabt_arg = arg["--wabt=".len..];
        } else if (std.mem.eql(u8, arg, "--wasmtime")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --wasmtime requires an argument\n");
                std.process.exit(2);
            }
            wasmtime_arg = args[i];
        } else if (std.mem.startsWith(u8, arg, "--wasmtime=")) {
            wasmtime_arg = arg["--wasmtime=".len..];
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --work-dir requires an argument\n");
                std.process.exit(2);
            }
            work_dir_arg = args[i];
        } else if (std.mem.startsWith(u8, arg, "--work-dir=")) {
            work_dir_arg = arg["--work-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--require-wasmtime")) {
            require_wasmtime = true;
        } else {
            try printStderr(io, alloc, "error: unknown argument '{s}'\n", .{arg});
            std.process.exit(2);
        }
    }

    try init.environ_map.put("NO_COLOR", "1");

    const wasmtime = resolveWasmtime(alloc, io, init.environ_map, wasmtime_arg) orelse {
        const msg = "no usable Wasmtime found (pass --wasmtime, set WASMTIME, or put `wasmtime` on PATH)";
        if (require_wasmtime) {
            try printStderr(io, alloc, "error: {s}\n", .{msg});
            std.process.exit(2);
        }
        try printStdout(io, alloc, "notice: optimize-regression skipped - {s}\n", .{msg});
        return;
    };

    if (!checkWabt(alloc, io, init.environ_map, wabt_arg)) {
        try printStderr(io, alloc, "error: wabt binary not found: {s}\n", .{wabt_arg});
        std.process.exit(2);
    }

    const cwd = std.Io.Dir.cwd();
    const tmp_base = blk: {
        if (init.environ_map.get("TMPDIR")) |t| {
            if (t.len > 0 and !std.mem.startsWith(u8, t, "/tmp")) break :blk t;
        }
        if (isDir(io, ".tmp")) break :blk ".tmp";
        break :blk ".zig-cache/tmp";
    };

    var sizes: std.ArrayListUnmanaged(SizeRecord) = .empty;
    var failures: std.ArrayListUnmanaged([]const u8) = .empty;
    var passed_fixtures: usize = 0;

    try printStdout(io, alloc, "optimize-regression: wabt={s} wasmtime={s}\n", .{ wabt_arg, wasmtime });

    const work_dir = work_dir_arg orelse try std.fmt.allocPrint(alloc, "{s}/optimize-regression", .{tmp_base});
    const cleanup_work_dir = (work_dir_arg == null);

    cwd.deleteTree(io, work_dir) catch {};
    try cwd.createDirPath(io, work_dir);
    defer if (cleanup_work_dir) {
        cwd.deleteTree(io, work_dir) catch {};
    };

    var delta_buf: [32]u8 = undefined;
    for (fixtures) |fixture| {
        if (try runBehavioralFixture(
            alloc,
            io,
            init.environ_map,
            fixture,
            work_dir,
            wabt_arg,
            wasmtime,
            &sizes,
            &failures,
        )) {
            passed_fixtures += 1;
            const rec = sizes.items[sizes.items.len - 1];
            const delta_str = try formatSignedInt(&delta_buf, rec.delta());
            try printStdout(
                io,
                alloc,
                "  PASS {s: <28} ({d} -> {d} bytes, {s})\n",
                .{ fixture.name, rec.before_bytes, rec.after_bytes, delta_str },
            );
        } else {
            try printStdout(io, alloc, "  FAIL {s}\n", .{fixture.name});
        }
    }

    try runPolicyAndCliChecks(
        alloc,
        io,
        init.environ_map,
        work_dir,
        wabt_arg,
        wasmtime,
        &sizes,
        &failures,
    );

    try printSizeReport(io, alloc, sizes.items);
    try printStdout(
        io,
        alloc,
        "\noptimize-regression: {d}/{d} behavioral fixtures passed, {d} failure(s)\n",
        .{ passed_fixtures, fixtures.len, failures.items.len },
    );

    if (failures.items.len > 0) {
        for (failures.items) |failure| {
            try printStderr(io, alloc, "\n--- FAILURE ---\n{s}\n", .{failure});
        }
        std.process.exit(1);
    }
}
