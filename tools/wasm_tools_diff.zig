//! Unified differential test runner comparing `wabt` against `wasm-tools 1.250.0`.
//!
//! Usage:
//!   wasm-tools-diff [--suite <all|cross-feature|gc|typed-select|wide-arithmetic|custom-page-sizes|feature-gate|declaration-feature-gate>] [--keep-work] [--work-dir <dir>] <path-to-wabt> <path-to-wasm-tools>

const std = @import("std");

const expected_wasm_tools_version = "wasm-tools 1.250.0";

const usage_text =
    \\Usage: wasm-tools-diff [options] <path-to-wabt> <path-to-wasm-tools>
    \\
    \\Run differential regression suites comparing wabt against wasm-tools 1.250.0.
    \\
    \\Options:
    \\  --suite <name>     Suite to run (default: all):
    \\                       all
    \\                       cross-feature
    \\                       gc
    \\                       typed-select
    \\                       wide-arithmetic
    \\                       custom-page-sizes
    \\                       feature-gate
    \\                       declaration-feature-gate
    \\  --work-dir <dir>   Materialization directory below zig-out/
    \\  --keep-work        Keep materialized files after a successful run
    \\  help, --help       Print this help and exit
    \\
;

pub const Suite = enum {
    all,
    cross_feature,
    gc,
    typed_select,
    wide_arithmetic,
    custom_page_sizes,
    feature_gate,
    declaration_feature_gate,

    pub fn parse(s: []const u8) ?Suite {
        if (std.mem.eql(u8, s, "all")) return .all;
        if (std.mem.eql(u8, s, "cross-feature")) return .cross_feature;
        if (std.mem.eql(u8, s, "gc")) return .gc;
        if (std.mem.eql(u8, s, "typed-select")) return .typed_select;
        if (std.mem.eql(u8, s, "wide-arithmetic")) return .wide_arithmetic;
        if (std.mem.eql(u8, s, "custom-page-sizes")) return .custom_page_sizes;
        if (std.mem.eql(u8, s, "feature-gate")) return .feature_gate;
        if (std.mem.eql(u8, s, "declaration-feature-gate")) return .declaration_feature_gate;
        return null;
    }

    pub fn defaultWorkDir(self: Suite) []const u8 {
        return switch (self) {
            .all => "zig-out/wasm-tools-diff-matrix",
            .cross_feature => "zig-out/cross-feature-matrix",
            .gc => "zig-out/gc-regression-matrix",
            .typed_select => "zig-out/typed-select-matrix",
            .wide_arithmetic => "zig-out/wide-arithmetic-matrix",
            .custom_page_sizes => "zig-out/custom-page-sizes-matrix",
            .feature_gate => "zig-out/feature-gate-matrix",
            .declaration_feature_gate => "zig-out/declaration-feature-gate-matrix",
        };
    }

    pub fn subdirName(self: Suite) []const u8 {
        return switch (self) {
            .all => "all",
            .cross_feature => "cross-feature",
            .gc => "gc",
            .typed_select => "typed-select",
            .wide_arithmetic => "wide-arithmetic",
            .custom_page_sizes => "custom-page-sizes",
            .feature_gate => "feature-gate",
            .declaration_feature_gate => "declaration-feature-gate",
        };
    }
};

const CmdResult = struct {
    exit_code: ?u8,
    signal_num: ?u32,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: CmdResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    fn accepted(self: CmdResult) bool {
        return self.exit_code != null and self.exit_code.? == 0;
    }

    fn rejected(self: CmdResult) bool {
        return self.exit_code != null and self.exit_code.? == 1;
    }

    fn matchesExit(self: CmdResult, expected: u8) bool {
        return self.exit_code != null and self.exit_code.? == expected;
    }

    fn summary(self: CmdResult, gpa: std.mem.Allocator) ![]u8 {
        const err_trimmed = std.mem.trim(u8, self.stderr, " \t\r\n");
        const out_trimmed = std.mem.trim(u8, self.stdout, " \t\r\n");
        const output = if (err_trimmed.len > 0)
            err_trimmed
        else if (out_trimmed.len > 0)
            out_trimmed
        else
            "(no output)";

        var last_line = output;
        if (std.mem.lastIndexOfScalar(u8, output, '\n')) |idx| {
            last_line = std.mem.trim(u8, output[idx + 1 ..], "\r");
        }
        if (self.exit_code) |code| {
            return std.fmt.allocPrint(gpa, "exit {d}: {s}", .{ code, last_line });
        }
        if (self.signal_num) |sig| {
            return std.fmt.allocPrint(gpa, "killed by signal {d}: {s}", .{ sig, last_line });
        }
        return std.fmt.allocPrint(gpa, "{s}", .{last_line});
    }
};

fn runCmd(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !CmdResult {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(16 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024 * 1024),
    }) catch |err| {
        const msg = try std.fmt.allocPrint(gpa, "could not execute: {any}", .{err});
        return .{
            .exit_code = null,
            .signal_num = null,
            .stdout = try gpa.dupe(u8, ""),
            .stderr = msg,
        };
    };

    return switch (result.term) {
        .exited => |code| .{
            .exit_code = code,
            .signal_num = null,
            .stdout = result.stdout,
            .stderr = result.stderr,
        },
        .signal => |sig| .{
            .exit_code = null,
            .signal_num = @backingInt(sig),
            .stdout = result.stdout,
            .stderr = result.stderr,
        },
        else => .{
            .exit_code = null,
            .signal_num = null,
            .stdout = result.stdout,
            .stderr = result.stderr,
        },
    };
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var stdout_file = std.Io.File.stdout();
    try stdout_file.writeStreamingAll(io, text);
}

const Counter = struct {
    passed: usize = 0,
    total: usize = 0,
};

const Matrix = struct {
    gpa: std.mem.Allocator,
    phases: std.StringHashMapUnmanaged(Counter) = .empty,
    groups: std.StringHashMapUnmanaged(Counter) = .empty,
    case_counter: Counter = .{},
    mismatches: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *Matrix) void {
        var pit = self.phases.iterator();
        while (pit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.phases.deinit(self.gpa);

        var git = self.groups.iterator();
        while (git.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
        }
        self.groups.deinit(self.gpa);

        for (self.mismatches.items) |m| {
            self.gpa.free(m);
        }
        self.mismatches.deinit(self.gpa);
    }

    fn addCount(
        gpa: std.mem.Allocator,
        map: *std.StringHashMapUnmanaged(Counter),
        key: []const u8,
        ok: bool,
    ) !void {
        const gop = try map.getOrPut(gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, key);
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.total += 1;
        if (ok) gop.value_ptr.passed += 1;
    }

    fn check(
        self: *Matrix,
        phase: []const u8,
        case_name: []const u8,
        ok: bool,
        detail: []const u8,
    ) !bool {
        try addCount(self.gpa, &self.phases, phase, ok);
        if (!ok) {
            const msg = try std.fmt.allocPrint(
                self.gpa,
                "{s} [{s}]: {s}",
                .{ case_name, phase, detail },
            );
            try self.mismatches.append(self.gpa, msg);
        }
        return ok;
    }

    fn checkWithSurface(
        self: *Matrix,
        phase: []const u8,
        surface: []const u8,
        case_name: []const u8,
        result: CmdResult,
        expected_exit: u8,
    ) !void {
        const ok = result.matchesExit(expected_exit);
        try addCount(self.gpa, &self.phases, phase, ok);
        try addCount(self.gpa, &self.groups, surface, ok);
        if (!ok) {
            const sum = try result.summary(self.gpa);
            defer self.gpa.free(sum);
            const msg = try std.fmt.allocPrint(
                self.gpa,
                "{s} [{s}]: expected exit {d}, got {s}",
                .{ case_name, phase, expected_exit, sum },
            );
            try self.mismatches.append(self.gpa, msg);
        }
    }

    fn finishFamilyCase(self: *Matrix, family: []const u8, passed: bool) !void {
        try addCount(self.gpa, &self.groups, family, passed);
        self.case_counter.total += 1;
        if (passed) self.case_counter.passed += 1;
    }

    fn finishCase(self: *Matrix, passed: bool) void {
        self.case_counter.total += 1;
        if (passed) self.case_counter.passed += 1;
    }

    fn totalChecks(self: *const Matrix) Counter {
        var c = Counter{};
        var it = self.phases.iterator();
        while (it.next()) |entry| {
            c.passed += entry.value_ptr.passed;
            c.total += entry.value_ptr.total;
        }
        return c;
    }

    fn sortedKeys(
        gpa: std.mem.Allocator,
        map: *const std.StringHashMapUnmanaged(Counter),
    ) ![][]const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer list.deinit(gpa);
        var it = map.keyIterator();
        while (it.next()) |k| {
            try list.append(gpa, k.*);
        }
        const slice = try list.toOwnedSlice(gpa);
        std.mem.sort([]const u8, slice, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return slice;
    }

    fn printMismatches(self: *const Matrix) void {
        if (self.mismatches.items.len > 0) {
            std.debug.print("Mismatches:\n", .{});
            for (self.mismatches.items) |m| {
                std.debug.print("  {s}\n", .{m});
            }
        }
    }
};

fn pairDetail(gpa: std.mem.Allocator, wabt_res: CmdResult, tools_res: CmdResult) ![]u8 {
    const w_sum = try wabt_res.summary(gpa);
    defer gpa.free(w_sum);
    const t_sum = try tools_res.summary(gpa);
    defer gpa.free(t_sum);
    return std.fmt.allocPrint(gpa, "wabt {s}; wasm-tools {s}", .{ w_sum, t_sum });
}

fn appendUleb(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try list.append(gpa, byte);
        if (v == 0) break;
    }
}

fn appendS33(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, value: i64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @intCast(@as(u64, @bitCast(v)) & 0x7F);
        v >>= 7;
        const done = (v == 0 and (byte & 0x40) == 0) or (v == -1 and (byte & 0x40) != 0);
        try list.append(gpa, if (done) byte else (byte | 0x80));
        if (done) break;
    }
}

fn appendSection(
    list: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    section_id: u8,
    payload: []const u8,
) !void {
    try list.append(gpa, section_id);
    try appendUleb(list, gpa, payload.len);
    try list.appendSlice(gpa, payload);
}

fn moduleWithSimpleBody(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "\x00asm\x01\x00\x00\x00");
    try out.appendSlice(gpa, &[_]u8{ 1, 4, 1, 0x60, 0, 0 });
    try out.appendSlice(gpa, &[_]u8{ 3, 2, 1, 0 });

    var code_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer code_payload.deinit(gpa);
    try code_payload.append(gpa, 1);
    try appendUleb(&code_payload, gpa, 1 + body.len);
    try code_payload.append(gpa, 0);
    try code_payload.appendSlice(gpa, body);

    try appendSection(&out, gpa, 10, code_payload.items);
    return out.toOwnedSlice(gpa);
}

fn decodeHex(gpa: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    if (hex_str.len % 2 != 0) return error.InvalidHex;
    const buf = try gpa.alloc(u8, hex_str.len / 2);
    errdefer gpa.free(buf);
    _ = try std.fmt.hexToBytes(buf, hex_str);
    return buf;
}

fn prepareWorkDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    const allowed_root = try cwd.realPathFileAlloc(io, "zig-out", gpa);
    defer gpa.free(allowed_root);

    // Ensure the parent of work_dir exists so we can resolve it safely.
    const parent_rel = std.fs.path.dirname(work_dir) orelse {
        std.debug.print("error: --work-dir must be below {s}\n", .{allowed_root});
        std.process.exit(2);
    };
    const base_name = std.fs.path.basename(work_dir);
    if (base_name.len == 0 or std.mem.eql(u8, base_name, ".") or std.mem.eql(u8, base_name, "..")) {
        std.debug.print("error: --work-dir must be below {s}\n", .{allowed_root});
        std.process.exit(2);
    }
    try cwd.createDirPath(io, parent_rel);
    const parent_real = try cwd.realPathFileAlloc(io, parent_rel, gpa);
    defer gpa.free(parent_real);

    const is_below = std.mem.eql(u8, parent_real, allowed_root) or
        (std.mem.startsWith(u8, parent_real, allowed_root) and
            parent_real.len > allowed_root.len and
            parent_real[allowed_root.len] == std.fs.path.sep);
    if (!is_below) {
        std.debug.print("error: --work-dir must be below {s}\n", .{allowed_root});
        std.process.exit(2);
    }

    cwd.deleteTree(io, work_dir) catch {};
    try cwd.createDirPath(io, work_dir);
}

fn finishWorkDir(
    io: std.Io,
    work_dir: []const u8,
    keep_work: bool,
    failed: bool,
) void {
    if (!keep_work and !failed) {
        std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    }
}

// ── 1. cross-feature suite ───────────────────────────────────────────────────

const CrossVariant = struct {
    features: []const u8,
    wasm_tools_features: ?[]const u8 = null,
    expected_exit: u8,
};

const CrossWatCase = struct {
    name: []const u8,
    surface: []const u8,
    wat: []const u8,
    variants: []const CrossVariant,
};

const CrossInvalidWatCase = struct {
    name: []const u8,
    surface: []const u8,
    failure_kind: []const u8,
    features: []const u8,
    expected_exit: u8,
    wat: []const u8,
};

const CrossBinaryCase = struct {
    name: []const u8,
    surface: []const u8,
    failure_kind: []const u8,
    features: []const u8,
    expected_exit: u8,
    hex: []const u8,
};

const CrossCorpus = struct {
    version: u32,
    wat_cases: []const CrossWatCase,
    invalid_wat_cases: []const CrossInvalidWatCase,
    binary_cases: []const CrossBinaryCase,
};

fn validateCrossCorpus(gpa: std.mem.Allocator, corpus: CrossCorpus) !void {
    if (corpus.version != 1) return error.InvalidCorpusVersion;
    var names = std.StringHashMapUnmanaged(void){};
    defer names.deinit(gpa);

    for (corpus.wat_cases) |case| {
        if (case.name.len == 0 or case.surface.len == 0 or case.wat.len == 0 or case.variants.len == 0) {
            return error.InvalidCorpusEntry;
        }
        const gop = try names.getOrPut(gpa, case.name);
        if (gop.found_existing) return error.DuplicateCorpusCaseName;
        for (case.variants) |variant| {
            if (variant.features.len == 0) return error.InvalidCorpusVariant;
            if (variant.expected_exit != 0 and variant.expected_exit != 1) return error.InvalidExpectedExit;
        }
    }

    for (corpus.invalid_wat_cases) |case| {
        if (case.name.len == 0 or case.surface.len == 0 or case.wat.len == 0 or case.features.len == 0) {
            return error.InvalidCorpusEntry;
        }
        if (case.expected_exit != 0 and case.expected_exit != 1) return error.InvalidExpectedExit;
        if (!std.mem.eql(u8, case.failure_kind, "malformed") and !std.mem.eql(u8, case.failure_kind, "truncated")) {
            return error.InvalidFailureKind;
        }
        const gop = try names.getOrPut(gpa, case.name);
        if (gop.found_existing) return error.DuplicateCorpusCaseName;
    }

    for (corpus.binary_cases) |case| {
        if (case.name.len == 0 or case.surface.len == 0 or case.hex.len == 0 or case.features.len == 0) {
            return error.InvalidCorpusEntry;
        }
        if (case.expected_exit != 0 and case.expected_exit != 1) return error.InvalidExpectedExit;
        if (!std.mem.eql(u8, case.failure_kind, "malformed") and !std.mem.eql(u8, case.failure_kind, "truncated")) {
            return error.InvalidFailureKind;
        }
        const decoded = try decodeHex(gpa, case.hex);
        gpa.free(decoded);
        const gop = try names.getOrPut(gpa, case.name);
        if (gop.found_existing) return error.DuplicateCorpusCaseName;
    }
}

fn runCrossFeatureSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    const corpus_bytes = try cwd.readFileAlloc(
        io,
        "src/fixtures/cross-feature-regression/corpus.json",
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(corpus_bytes);

    var parsed = try std.json.parseFromSlice(CrossCorpus, gpa, corpus_bytes, .{});
    defer parsed.deinit();
    const corpus = parsed.value;
    try validateCrossCorpus(gpa, corpus);

    try prepareWorkDir(gpa, io, work_dir);
    var matrix = Matrix{ .gpa = gpa };
    defer matrix.deinit();

    for (corpus.wat_cases) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const wat_name = try std.fmt.allocPrint(gpa, "{s}.wat", .{case.name});
        defer gpa.free(wat_name);
        const wat_path = try std.fs.path.join(gpa, &.{ case_dir, wat_name });
        defer gpa.free(wat_path);

        const tools_wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm-tools.wasm", .{case.name});
        defer gpa.free(tools_wasm_name);
        const tools_wasm = try std.fs.path.join(gpa, &.{ case_dir, tools_wasm_name });
        defer gpa.free(tools_wasm);

        try cwd.writeFile(io, .{ .sub_path = wat_path, .data = case.wat });

        const tools_parse = try runCmd(gpa, io, &.{ wasm_tools, "parse", wat_path, "-o", tools_wasm });
        defer tools_parse.deinit(gpa);
        try matrix.checkWithSurface("wasm-tools-parse", case.surface, case.name, tools_parse, 0);

        for (case.variants, 0..) |variant, index| {
            const features = variant.features;
            const tools_features = variant.wasm_tools_features orelse features;
            const expected_exit = variant.expected_exit;
            const variant_name = try std.fmt.allocPrint(gpa, "{s}/{d}:{s}", .{ case.name, index, features });
            defer gpa.free(variant_name);

            const wabt_wasm_name = try std.fmt.allocPrint(gpa, "{s}.{d}.wabt.wasm", .{ case.name, index });
            defer gpa.free(wabt_wasm_name);
            const wabt_wasm = try std.fs.path.join(gpa, &.{ case_dir, wabt_wasm_name });
            defer gpa.free(wabt_wasm);

            const wabt_feat_arg = try std.fmt.allocPrint(gpa, "--features={s}", .{features});
            defer gpa.free(wabt_feat_arg);
            const tools_feat_arg = try std.fmt.allocPrint(gpa, "--features={s}", .{tools_features});
            defer gpa.free(tools_feat_arg);

            const wabt_wat = try runCmd(gpa, io, &.{ wabt, "text", "parse", wabt_feat_arg, wat_path, "-o", wabt_wasm });
            defer wabt_wat.deinit(gpa);
            const tools_wat = try runCmd(gpa, io, &.{ wasm_tools, "validate", tools_feat_arg, wat_path });
            defer tools_wat.deinit(gpa);

            try matrix.checkWithSurface("wabt-wat", case.surface, variant_name, wabt_wat, expected_exit);
            try matrix.checkWithSurface("wasm-tools-wat", case.surface, variant_name, tools_wat, expected_exit);

            if (tools_parse.accepted()) {
                const wabt_binary = try runCmd(gpa, io, &.{ wabt, "module", "validate", wabt_feat_arg, tools_wasm });
                defer wabt_binary.deinit(gpa);
                const tools_binary = try runCmd(gpa, io, &.{ wasm_tools, "validate", tools_feat_arg, tools_wasm });
                defer tools_binary.deinit(gpa);

                try matrix.checkWithSurface("wabt-binary", case.surface, variant_name, wabt_binary, expected_exit);
                try matrix.checkWithSurface("wasm-tools-binary", case.surface, variant_name, tools_binary, expected_exit);
            }

            if (expected_exit == 0 and wabt_wat.accepted()) {
                const tools_on_wabt = try runCmd(gpa, io, &.{ wasm_tools, "validate", tools_feat_arg, wabt_wasm });
                defer tools_on_wabt.deinit(gpa);
                try matrix.checkWithSurface("wasm-tools-on-wabt", case.surface, variant_name, tools_on_wabt, 0);
            }
        }
    }

    for (corpus.invalid_wat_cases) |case| {
        const wat_name = try std.fmt.allocPrint(gpa, "{s}.wat", .{case.name});
        defer gpa.free(wat_name);
        const wat_path = try std.fs.path.join(gpa, &.{ work_dir, wat_name });
        defer gpa.free(wat_path);

        const out_name = try std.fmt.allocPrint(gpa, "{s}.wabt.wasm", .{case.name});
        defer gpa.free(out_name);
        const out_path = try std.fs.path.join(gpa, &.{ work_dir, out_name });
        defer gpa.free(out_path);

        try cwd.writeFile(io, .{ .sub_path = wat_path, .data = case.wat });

        const feat_arg = try std.fmt.allocPrint(gpa, "--features={s}", .{case.features});
        defer gpa.free(feat_arg);

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "text", "parse", feat_arg, wat_path, "-o", out_path });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_arg, wat_path });
        defer tools_res.deinit(gpa);

        try matrix.checkWithSurface("wabt-invalid-wat", case.surface, case.name, wabt_res, case.expected_exit);
        try matrix.checkWithSurface("wasm-tools-invalid-wat", case.surface, case.name, tools_res, case.expected_exit);
    }

    for (corpus.binary_cases) |case| {
        const wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{case.name});
        defer gpa.free(wasm_name);
        const wasm_path = try std.fs.path.join(gpa, &.{ work_dir, wasm_name });
        defer gpa.free(wasm_path);

        const bytes = try decodeHex(gpa, case.hex);
        defer gpa.free(bytes);
        try cwd.writeFile(io, .{ .sub_path = wasm_path, .data = bytes });

        const feat_arg = try std.fmt.allocPrint(gpa, "--features={s}", .{case.features});
        defer gpa.free(feat_arg);

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "module", "validate", feat_arg, wasm_path });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_arg, wasm_path });
        defer tools_res.deinit(gpa);

        try matrix.checkWithSurface("wabt-malformed-binary", case.surface, case.name, wabt_res, case.expected_exit);
        try matrix.checkWithSurface("wasm-tools-malformed-binary", case.surface, case.name, tools_res, case.expected_exit);
    }

    const case_count = corpus.wat_cases.len + corpus.invalid_wat_cases.len + corpus.binary_cases.len;
    const checks = matrix.totalChecks();

    var report_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer report_buf.deinit(gpa);

    const header = try std.fmt.allocPrint(
        gpa,
        "Cross-feature differential matrix: {d} cases, {d}/{d} checks\nSurfaces:\n",
        .{ case_count, checks.passed, checks.total },
    );
    defer gpa.free(header);
    try report_buf.appendSlice(gpa, header);

    const surface_keys = try Matrix.sortedKeys(gpa, &matrix.groups);
    defer gpa.free(surface_keys);
    for (surface_keys) |k| {
        const c = matrix.groups.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    try report_buf.appendSlice(gpa, "Phases:\n");
    const phase_keys = try Matrix.sortedKeys(gpa, &matrix.phases);
    defer gpa.free(phase_keys);
    for (phase_keys) |k| {
        const c = matrix.phases.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    try writeStdout(io, report_buf.items);
    matrix.printMismatches();

    const failed = matrix.mismatches.items.len > 0;
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── 2. gc suite ──────────────────────────────────────────────────────────────

const GcValidCase = struct {
    name: []const u8,
    family: []const u8,
    subopcodes: []const u32,
    wat: []const u8,
};

const GcInvalidWatCase = struct {
    name: []const u8,
    family: []const u8,
    wabt_error: []const u8 = "",
    wat: []const u8,
};

const GcInvalidBinaryCase = struct {
    name: []const u8,
    family: []const u8,
    wabt_error: []const u8 = "",
    binary_error: []const u8 = "",
    body_hex: []const u8,
};

const GcCorpus = struct {
    version: u32,
    valid: []const GcValidCase,
    invalid_wat: []const GcInvalidWatCase,
    invalid_binary: []const GcInvalidBinaryCase,
};

fn runGcSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    const corpus_bytes = try cwd.readFileAlloc(
        io,
        "src/fixtures/gc-regression/corpus.json",
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(corpus_bytes);

    var parsed = try std.json.parseFromSlice(GcCorpus, gpa, corpus_bytes, .{});
    defer parsed.deinit();
    const corpus = parsed.value;

    const gc_subopcode_count = 0x1F;
    var seen_counts: [gc_subopcode_count]usize = @splat(0);
    for (corpus.valid) |case| {
        for (case.subopcodes) |sub| {
            if (sub >= gc_subopcode_count) return error.InvalidGcSubopcode;
            seen_counts[sub] += 1;
        }
    }
    for (seen_counts) |cnt| {
        if (cnt != 1) return error.InvalidGcSubopcodeManifest;
    }

    try prepareWorkDir(gpa, io, work_dir);
    var matrix = Matrix{ .gpa = gpa };
    defer matrix.deinit();

    for (corpus.valid) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(source);
        const wabt_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.wasm", .{ case_dir, case.name });
        defer gpa.free(wabt_wasm);
        const tools_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm-tools.wasm", .{ case_dir, case.name });
        defer gpa.free(tools_wasm);

        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        var passed = true;
        const wabt_wat = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", wabt_wasm });
        defer wabt_wat.deinit(gpa);
        const tools_wat = try runCmd(gpa, io, &.{ wasm_tools, "validate", source });
        defer tools_wat.deinit(gpa);

        const wat_detail = try pairDetail(gpa, wabt_wat, tools_wat);
        defer gpa.free(wat_detail);
        if (!try matrix.check("wat-verdict", case.name, wabt_wat.accepted() and tools_wat.accepted(), wat_detail)) {
            passed = false;
        }

        const tools_parse = try runCmd(gpa, io, &.{ wasm_tools, "parse", source, "-o", tools_wasm });
        defer tools_parse.deinit(gpa);
        const tools_binary = if (tools_parse.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", tools_wasm })
        else
            null;
        defer if (tools_binary) |tb| tb.deinit(gpa);

        const tp_sum = try tools_parse.summary(gpa);
        defer gpa.free(tp_sum);
        const tb_sum = if (tools_binary) |tb| try tb.summary(gpa) else try gpa.dupe(u8, tp_sum);
        defer gpa.free(tb_sum);
        const ref_detail = try std.fmt.allocPrint(gpa, "parse {s}; validate {s}", .{ tp_sum, tb_sum });
        defer gpa.free(ref_detail);

        const ref_ok = tools_parse.accepted() and (tools_binary != null and tools_binary.?.accepted());
        if (!try matrix.check("wasm-tools-reference", case.name, ref_ok, ref_detail)) {
            passed = false;
        }

        if (wabt_wat.accepted()) {
            const wabt_binary = try runCmd(gpa, io, &.{ wabt, "module", "validate", wabt_wasm });
            defer wabt_binary.deinit(gpa);
            const tools_on_wabt = try runCmd(gpa, io, &.{ wasm_tools, "validate", wabt_wasm });
            defer tools_on_wabt.deinit(gpa);

            const bin_detail = try pairDetail(gpa, wabt_binary, tools_on_wabt);
            defer gpa.free(bin_detail);
            if (!try matrix.check("binary-verdict", case.name, wabt_binary.accepted() and tools_on_wabt.accepted(), bin_detail)) {
                passed = false;
            }

            const tow_sum = try tools_on_wabt.summary(gpa);
            defer gpa.free(tow_sum);
            if (!try matrix.check("wasm-tools-on-wabt-output", case.name, tools_on_wabt.accepted(), tow_sum)) {
                passed = false;
            }

            const gc_disabled = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=-gc", wabt_wasm });
            defer gc_disabled.deinit(gpa);
            const gd_sum = try gc_disabled.summary(gpa);
            defer gpa.free(gd_sum);
            const gd_detail = try std.fmt.allocPrint(gpa, "{s} (expected validation rejection exit 1)", .{gd_sum});
            defer gpa.free(gd_detail);
            if (!try matrix.check("feature-disabled", case.name, gc_disabled.rejected(), gd_detail)) {
                passed = false;
            }

            const printed = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.printed.wat", .{ case_dir, case.name });
            defer gpa.free(printed);
            const reparsed = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.reparsed.wasm", .{ case_dir, case.name });
            defer gpa.free(reparsed);
            const canonical_before = try std.fmt.allocPrint(gpa, "{s}/{s}.canonical-before.wat", .{ case_dir, case.name });
            defer gpa.free(canonical_before);
            const canonical_after = try std.fmt.allocPrint(gpa, "{s}/{s}.canonical-after.wat", .{ case_dir, case.name });
            defer gpa.free(canonical_after);

            const print_result = try runCmd(gpa, io, &.{ wabt, "text", "print", wabt_wasm, "-o", printed });
            defer print_result.deinit(gpa);
            const reparse_result = if (print_result.accepted())
                try runCmd(gpa, io, &.{ wabt, "text", "parse", printed, "-o", reparsed })
            else
                null;
            defer if (reparse_result) |r| r.deinit(gpa);

            const wabt_revalidate = if (reparse_result != null and reparse_result.?.accepted())
                try runCmd(gpa, io, &.{ wabt, "module", "validate", reparsed })
            else
                null;
            defer if (wabt_revalidate) |r| r.deinit(gpa);

            const tools_revalidate = if (reparse_result != null and reparse_result.?.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "validate", reparsed })
            else
                null;
            defer if (tools_revalidate) |r| r.deinit(gpa);

            const tools_printed_wat = if (print_result.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "validate", printed })
            else
                null;
            defer if (tools_printed_wat) |r| r.deinit(gpa);

            const canonical_before_result = try runCmd(gpa, io, &.{ wasm_tools, "print", wabt_wasm, "-o", canonical_before });
            defer canonical_before_result.deinit(gpa);

            const canonical_after_result = if (reparse_result != null and reparse_result.?.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "print", reparsed, "-o", canonical_after })
            else
                null;
            defer if (canonical_after_result) |r| r.deinit(gpa);

            var canonical_equal = false;
            if (canonical_before_result.accepted() and canonical_after_result != null and canonical_after_result.?.accepted()) {
                const b_bytes = cwd.readFileAlloc(io, canonical_before, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
                defer if (b_bytes) |b| gpa.free(b);
                const a_bytes = cwd.readFileAlloc(io, canonical_after, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
                defer if (a_bytes) |a| gpa.free(a);
                if (b_bytes != null and a_bytes != null) {
                    canonical_equal = std.mem.eql(u8, b_bytes.?, a_bytes.?);
                }
            }

            const roundtrip_ok = print_result.accepted() and
                (reparse_result != null and reparse_result.?.accepted()) and
                (wabt_revalidate != null and wabt_revalidate.?.accepted()) and
                (tools_revalidate != null and tools_revalidate.?.accepted()) and
                (tools_printed_wat != null and tools_printed_wat.?.accepted()) and
                canonical_equal;

            if (!try matrix.check(
                "canonical-roundtrip",
                case.name,
                roundtrip_ok,
                "print/reparse/validation failed or wasm-tools canonical text changed",
            )) {
                passed = false;
            }
        } else {
            for (&[_][]const u8{
                "binary-verdict",
                "wasm-tools-on-wabt-output",
                "feature-disabled",
                "canonical-roundtrip",
            }) |phase| {
                _ = try matrix.check(phase, case.name, false, "WAT conversion did not produce binary");
                passed = false;
            }
        }

        try matrix.finishFamilyCase(case.family, passed);
    }

    for (corpus.invalid_wat) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(source);
        const output = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.wasm", .{ case_dir, case.name });
        defer gpa.free(output);
        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", output });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", source });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check(
            "wat-verdict",
            case.name,
            wabt_res.rejected() and tools_res.rejected(),
            detail,
        );
        try matrix.finishFamilyCase(case.family, passed);
    }

    for (corpus.invalid_binary) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ case_dir, case.name });
        defer gpa.free(wasm);
        const body = try decodeHex(gpa, case.body_hex);
        defer gpa.free(body);
        const mod_bytes = try moduleWithSimpleBody(gpa, body);
        defer gpa.free(mod_bytes);
        try cwd.writeFile(io, .{ .sub_path = wasm, .data = mod_bytes });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "module", "validate", wasm });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", wasm });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check(
            "binary-verdict",
            case.name,
            wabt_res.rejected() and tools_res.rejected(),
            detail,
        );
        try matrix.finishFamilyCase(case.family, passed);
    }

    const checks = matrix.totalChecks();
    var report_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer report_buf.deinit(gpa);

    const header = try std.fmt.allocPrint(
        gpa,
        "GC differential matrix: {d}/{d} cases, {d}/{d} checks\nChecks:\n",
        .{ matrix.case_counter.passed, matrix.case_counter.total, checks.passed, checks.total },
    );
    defer gpa.free(header);
    try report_buf.appendSlice(gpa, header);

    const phase_keys = try Matrix.sortedKeys(gpa, &matrix.phases);
    defer gpa.free(phase_keys);
    for (phase_keys) |k| {
        const c = matrix.phases.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    try report_buf.appendSlice(gpa, "Families:\n");
    const fam_keys = try Matrix.sortedKeys(gpa, &matrix.groups);
    defer gpa.free(fam_keys);
    for (fam_keys) |k| {
        const c = matrix.groups.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    try report_buf.appendSlice(gpa, "Opcodes (31):");
    for (0..gc_subopcode_count) |sub| {
        const op = try std.fmt.allocPrint(gpa, " 0xfb{x:0>2}", .{sub});
        defer gpa.free(op);
        try report_buf.appendSlice(gpa, op);
    }
    try report_buf.append(gpa, '\n');

    const failed = matrix.mismatches.items.len > 0;
    if (keep_work or failed) {
        const mat_line = try std.fmt.allocPrint(gpa, "Materialized corpus: {s}\n", .{work_dir});
        defer gpa.free(mat_line);
        try report_buf.appendSlice(gpa, mat_line);
    }

    try writeStdout(io, report_buf.items);
    matrix.printMismatches();
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── 3. typed-select suite ────────────────────────────────────────────────────

const TsFeatureGateCase = struct {
    name: []const u8,
    gate: []const u8,
    wat: []const u8,
};

const TsValidCase = struct {
    name: []const u8,
    family: []const u8,
    printed: ?[]const u8 = null,
    wat: []const u8,
};

const TsInvalidWatCase = struct {
    name: []const u8,
    family: []const u8,
    stage: []const u8 = "",
    wabt_error: []const u8 = "",
    wat: []const u8,
};

const TsBinaryCase = struct {
    name: []const u8,
    family: []const u8,
    printed: ?[]const u8 = null,
    validator_error: []const u8 = "",
    binary_error: []const u8 = "",
    scanner_error: ?[]const u8 = null,
    type_index: u32 = 0,
    type_kind: []const u8 = "func",
    body_hex: []const u8,
};

const TsCorpus = struct {
    version: u32,
    feature_gates: []const TsFeatureGateCase,
    valid: []const TsValidCase,
    invalid_wat: []const TsInvalidWatCase,
    valid_binary: []const TsBinaryCase,
    invalid_binary: []const TsBinaryCase,
};

const ts_gate_features = [_][]const u8{
    "reference-types",
    "function-references",
    "gc",
    "exceptions",
};

fn tsGateEnabled(gate: []const u8, mask: u4) !bool {
    const ref_types = (mask & (1 << 0)) != 0;
    const func_refs = (mask & (1 << 1)) != 0;
    const gc = (mask & (1 << 2)) != 0;
    const exceptions = (mask & (1 << 3)) != 0;

    if (std.mem.eql(u8, gate, "reference-types")) return ref_types;
    if (std.mem.eql(u8, gate, "function-references")) return ref_types and func_refs;
    if (std.mem.eql(u8, gate, "gc")) return ref_types and gc;
    if (std.mem.eql(u8, gate, "exceptions")) return ref_types and exceptions;
    if (std.mem.eql(u8, gate, "function-references-or-gc")) return ref_types and (func_refs or gc);
    return error.UnknownFeatureGate;
}

fn appendTsTypeEntry(
    list: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    kind: []const u8,
    type_index: u32,
) !void {
    if (std.mem.eql(u8, kind, "func")) {
        try list.appendSlice(gpa, &[_]u8{ 0x60, 0, 0 });
    } else if (std.mem.eql(u8, kind, "struct")) {
        try list.appendSlice(gpa, &[_]u8{ 0x5F, 0 });
    } else if (std.mem.eql(u8, kind, "array")) {
        try list.appendSlice(gpa, &[_]u8{ 0x5E, 0x7F, 0 });
    } else if (std.mem.eql(u8, kind, "recursive-struct")) {
        try list.appendSlice(gpa, &[_]u8{ 0x4E, 1, 0x5F, 1, 0x63 });
        try appendS33(list, gpa, @intCast(type_index));
        try list.append(gpa, 0);
    } else {
        return error.UnknownTypeKind;
    }
}

fn tsModuleWithBody(gpa: std.mem.Allocator, case: TsBinaryCase, body: []const u8) ![]u8 {
    var entries_bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer entries_bytes.deinit(gpa);

    var entry_count: u32 = 0;
    var function_type_index: ?u32 = null;

    var idx: u32 = 0;
    while (idx <= case.type_index) : (idx += 1) {
        const kind = if (idx == case.type_index) case.type_kind else "func";
        try appendTsTypeEntry(&entries_bytes, gpa, kind, idx);
        entry_count += 1;
        if (function_type_index == null and std.mem.eql(u8, kind, "func")) {
            function_type_index = idx;
        }
    }
    if (function_type_index == null) {
        function_type_index = case.type_index + 1;
        try appendTsTypeEntry(&entries_bytes, gpa, "func", function_type_index.?);
        entry_count += 1;
    }

    var type_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer type_payload.deinit(gpa);
    try appendUleb(&type_payload, gpa, entry_count);
    try type_payload.appendSlice(gpa, entries_bytes.items);

    var func_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer func_payload.deinit(gpa);
    try func_payload.append(gpa, 1);
    try appendUleb(&func_payload, gpa, function_type_index.?);

    var code_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer code_payload.deinit(gpa);
    try code_payload.append(gpa, 1);
    try appendUleb(&code_payload, gpa, 1 + body.len);
    try code_payload.append(gpa, 0);
    try code_payload.appendSlice(gpa, body);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x00asm\x01\x00\x00\x00");
    try appendSection(&out, gpa, 1, type_payload.items);
    try appendSection(&out, gpa, 3, func_payload.items);
    try appendSection(&out, gpa, 10, code_payload.items);
    return out.toOwnedSlice(gpa);
}

fn runTsBinaryCase(
    gpa: std.mem.Allocator,
    io: std.Io,
    matrix: *Matrix,
    case: TsBinaryCase,
    valid: bool,
    work_dir: []const u8,
    wabt: []const u8,
    wasm_tools: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
    defer gpa.free(case_dir);
    try cwd.createDirPath(io, case_dir);

    const binary = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ case_dir, case.name });
    defer gpa.free(binary);
    const body = try decodeHex(gpa, case.body_hex);
    defer gpa.free(body);
    const mod_bytes = try tsModuleWithBody(gpa, case, body);
    defer gpa.free(mod_bytes);
    try cwd.writeFile(io, .{ .sub_path = binary, .data = mod_bytes });

    const wabt_res = try runCmd(gpa, io, &.{ wabt, "module", "validate", binary });
    defer wabt_res.deinit(gpa);
    const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", binary });
    defer tools_res.deinit(gpa);

    const verdict_ok = if (valid)
        wabt_res.accepted() and tools_res.accepted()
    else
        wabt_res.rejected() and tools_res.rejected();

    const detail = try pairDetail(gpa, wabt_res, tools_res);
    defer gpa.free(detail);
    var passed = try matrix.check(
        if (valid) "valid-binary-verdict" else "invalid-binary-verdict",
        case.name,
        verdict_ok,
        detail,
    );

    if (valid) {
        const printed = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(printed);
        const reparsed = try std.fmt.allocPrint(gpa, "{s}/{s}.reparsed.wasm", .{ case_dir, case.name });
        defer gpa.free(reparsed);

        const print_res = try runCmd(gpa, io, &.{ wabt, "text", "print", binary, "-o", printed });
        defer print_res.deinit(gpa);
        const tools_printed = if (print_res.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", printed })
        else
            null;
        defer if (tools_printed) |r| r.deinit(gpa);

        const reparse_res = if (print_res.accepted())
            try runCmd(gpa, io, &.{ wabt, "text", "parse", printed, "-o", reparsed })
        else
            null;
        defer if (reparse_res) |r| r.deinit(gpa);

        const tools_reparsed = if (reparse_res != null and reparse_res.?.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", reparsed })
        else
            null;
        defer if (tools_reparsed) |r| r.deinit(gpa);

        const out_ok = print_res.accepted() and
            (tools_printed != null and tools_printed.?.accepted()) and
            (reparse_res != null and reparse_res.?.accepted()) and
            (tools_reparsed != null and tools_reparsed.?.accepted());

        if (!try matrix.check(
            "valid-binary-output",
            case.name,
            out_ok,
            "wabt print/reparse output was not accepted by wasm-tools",
        )) {
            passed = false;
        }
    }

    try matrix.finishFamilyCase(case.family, passed);
}

fn runTypedSelectSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    const corpus_bytes = try cwd.readFileAlloc(
        io,
        "src/fixtures/typed-select-regression/corpus.json",
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(corpus_bytes);

    var parsed = try std.json.parseFromSlice(TsCorpus, gpa, corpus_bytes, .{});
    defer parsed.deinit();
    const corpus = parsed.value;
    if (corpus.version != 1) return error.InvalidCorpusVersion;

    try prepareWorkDir(gpa, io, work_dir);
    var matrix = Matrix{ .gpa = gpa };
    defer matrix.deinit();

    for (corpus.feature_gates) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(source);
        const binary = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ case_dir, case.name });
        defer gpa.free(binary);
        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        const wabt_parse = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", binary });
        defer wabt_parse.deinit(gpa);
        const wabt_validate = if (wabt_parse.accepted())
            try runCmd(gpa, io, &.{ wabt, "module", "validate", binary })
        else
            null;
        defer if (wabt_validate) |r| r.deinit(gpa);
        const tools_default = try runCmd(gpa, io, &.{ wasm_tools, "validate", source });
        defer tools_default.deinit(gpa);

        const wp_sum = try wabt_parse.summary(gpa);
        defer gpa.free(wp_sum);
        const wv_sum = if (wabt_validate) |r| try r.summary(gpa) else try gpa.dupe(u8, wp_sum);
        defer gpa.free(wv_sum);
        const td_sum = try tools_default.summary(gpa);
        defer gpa.free(td_sum);
        const def_detail = try std.fmt.allocPrint(gpa, "parse {s}; validate {s}; wasm-tools {s}", .{ wp_sum, wv_sum, td_sum });
        defer gpa.free(def_detail);

        var passed = try matrix.check(
            "feature-gate-default",
            case.name,
            wabt_parse.accepted() and (wabt_validate != null and wabt_validate.?.accepted()) and tools_default.accepted(),
            def_detail,
        );

        for (0..16) |mask_usize| {
            const mask: u4 = @intCast(mask_usize);
            var settings_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer settings_buf.deinit(gpa);
            try settings_buf.appendSlice(gpa, "--features=");
            var bits: [4]u8 = undefined;
            for (ts_gate_features, 0..) |feat, bit| {
                if (bit > 0) try settings_buf.append(gpa, ',');
                const enabled = (mask & (@as(u4, 1) << @intCast(bit))) != 0;
                bits[bit] = if (enabled) '1' else '0';
                if (!enabled) try settings_buf.append(gpa, '-');
                try settings_buf.appendSlice(gpa, feat);
            }

            const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", settings_buf.items, source });
            defer tools_res.deinit(gpa);
            const expected = try tsGateEnabled(case.gate, mask);
            const verdict_matches = if (expected) tools_res.accepted() else tools_res.rejected();

            const combo_name = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ case.name, &bits });
            defer gpa.free(combo_name);
            const tr_sum = try tools_res.summary(gpa);
            defer gpa.free(tr_sum);
            const combo_detail = try std.fmt.allocPrint(
                gpa,
                "gate {s}, expected {s}; {s}",
                .{ case.gate, if (expected) "accept" else "reject", tr_sum },
            );
            defer gpa.free(combo_detail);

            if (!try matrix.check("feature-gate-combination", combo_name, verdict_matches, combo_detail)) {
                passed = false;
            }
        }

        try matrix.finishFamilyCase("feature-gate", passed);
    }

    for (corpus.valid) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(source);
        const wabt_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.wasm", .{ case_dir, case.name });
        defer gpa.free(wabt_wasm);
        const tools_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.tools.wasm", .{ case_dir, case.name });
        defer gpa.free(tools_wasm);
        const printed = try std.fmt.allocPrint(gpa, "{s}/{s}.printed.wat", .{ case_dir, case.name });
        defer gpa.free(printed);
        const reparsed = try std.fmt.allocPrint(gpa, "{s}/{s}.reparsed.wasm", .{ case_dir, case.name });
        defer gpa.free(reparsed);
        const canonical_before = try std.fmt.allocPrint(gpa, "{s}/{s}.before.wat", .{ case_dir, case.name });
        defer gpa.free(canonical_before);
        const canonical_after = try std.fmt.allocPrint(gpa, "{s}/{s}.after.wat", .{ case_dir, case.name });
        defer gpa.free(canonical_after);

        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        var passed = true;
        const wabt_wat = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", wabt_wasm });
        defer wabt_wat.deinit(gpa);
        const tools_wat = try runCmd(gpa, io, &.{ wasm_tools, "validate", source });
        defer tools_wat.deinit(gpa);

        const wat_detail = try pairDetail(gpa, wabt_wat, tools_wat);
        defer gpa.free(wat_detail);
        if (!try matrix.check("wat-verdict", case.name, wabt_wat.accepted() and tools_wat.accepted(), wat_detail)) {
            passed = false;
        }

        const tools_parse = try runCmd(gpa, io, &.{ wasm_tools, "parse", source, "-o", tools_wasm });
        defer tools_parse.deinit(gpa);
        const wabt_on_tools = if (tools_parse.accepted())
            try runCmd(gpa, io, &.{ wabt, "module", "validate", tools_wasm })
        else
            null;
        defer if (wabt_on_tools) |r| r.deinit(gpa);

        const tp_sum = try tools_parse.summary(gpa);
        defer gpa.free(tp_sum);
        const wot_sum = if (wabt_on_tools) |r| try r.summary(gpa) else try gpa.dupe(u8, tp_sum);
        defer gpa.free(wot_sum);
        const ref_detail = try std.fmt.allocPrint(gpa, "parse {s}; validate {s}", .{ tp_sum, wot_sum });
        defer gpa.free(ref_detail);

        if (!try matrix.check(
            "wabt-on-reference-binary",
            case.name,
            tools_parse.accepted() and (wabt_on_tools != null and wabt_on_tools.?.accepted()),
            ref_detail,
        )) {
            passed = false;
        }

        if (wabt_wat.accepted()) {
            const wabt_binary = try runCmd(gpa, io, &.{ wabt, "module", "validate", wabt_wasm });
            defer wabt_binary.deinit(gpa);
            const tools_binary = try runCmd(gpa, io, &.{ wasm_tools, "validate", wabt_wasm });
            defer tools_binary.deinit(gpa);

            const bin_detail = try pairDetail(gpa, wabt_binary, tools_binary);
            defer gpa.free(bin_detail);
            if (!try matrix.check("binary-verdict", case.name, wabt_binary.accepted() and tools_binary.accepted(), bin_detail)) {
                passed = false;
            }

            const disabled = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=-reference-types", wabt_wasm });
            defer disabled.deinit(gpa);
            const dis_sum = try disabled.summary(gpa);
            defer gpa.free(dis_sum);
            if (!try matrix.check("reference-types-disabled", case.name, disabled.rejected(), dis_sum)) {
                passed = false;
            }

            const print_res = try runCmd(gpa, io, &.{ wabt, "text", "print", wabt_wasm, "-o", printed });
            defer print_res.deinit(gpa);
            const tools_printed = if (print_res.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "validate", printed })
            else
                null;
            defer if (tools_printed) |r| r.deinit(gpa);
            const reparse_res = if (print_res.accepted())
                try runCmd(gpa, io, &.{ wabt, "text", "parse", printed, "-o", reparsed })
            else
                null;
            defer if (reparse_res) |r| r.deinit(gpa);
            const wabt_revalidate = if (reparse_res != null and reparse_res.?.accepted())
                try runCmd(gpa, io, &.{ wabt, "module", "validate", reparsed })
            else
                null;
            defer if (wabt_revalidate) |r| r.deinit(gpa);
            const tools_revalidate = if (reparse_res != null and reparse_res.?.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "validate", reparsed })
            else
                null;
            defer if (tools_revalidate) |r| r.deinit(gpa);

            const before_res = try runCmd(gpa, io, &.{ wasm_tools, "print", wabt_wasm, "-o", canonical_before });
            defer before_res.deinit(gpa);
            const after_res = if (reparse_res != null and reparse_res.?.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "print", reparsed, "-o", canonical_after })
            else
                null;
            defer if (after_res) |r| r.deinit(gpa);

            var canonical_equal = false;
            if (before_res.accepted() and after_res != null and after_res.?.accepted()) {
                const b_bytes = cwd.readFileAlloc(io, canonical_before, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
                defer if (b_bytes) |b| gpa.free(b);
                const a_bytes = cwd.readFileAlloc(io, canonical_after, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
                defer if (a_bytes) |a| gpa.free(a);
                if (b_bytes != null and a_bytes != null) {
                    canonical_equal = std.mem.eql(u8, b_bytes.?, a_bytes.?);
                }
            }

            const out_ok = print_res.accepted() and
                (tools_printed != null and tools_printed.?.accepted()) and
                (reparse_res != null and reparse_res.?.accepted()) and
                (wabt_revalidate != null and wabt_revalidate.?.accepted()) and
                (tools_revalidate != null and tools_revalidate.?.accepted()) and
                canonical_equal;

            if (!try matrix.check(
                "wabt-output",
                case.name,
                out_ok,
                "print/reparse validation failed or wasm-tools canonical text changed",
            )) {
                passed = false;
            }
        } else {
            for (&[_][]const u8{
                "binary-verdict",
                "reference-types-disabled",
                "wabt-output",
            }) |phase| {
                _ = try matrix.check(phase, case.name, false, "WAT conversion produced no binary");
                passed = false;
            }
        }

        try matrix.finishFamilyCase(case.family, passed);
    }

    for (corpus.invalid_wat) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(source);
        const output = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ case_dir, case.name });
        defer gpa.free(output);
        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", output });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", source });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check(
            "invalid-wat-verdict",
            case.name,
            wabt_res.rejected() and tools_res.rejected(),
            detail,
        );
        try matrix.finishFamilyCase(case.family, passed);
    }

    for (corpus.valid_binary) |case| {
        try runTsBinaryCase(gpa, io, &matrix, case, true, work_dir, wabt, wasm_tools);
    }
    for (corpus.invalid_binary) |case| {
        try runTsBinaryCase(gpa, io, &matrix, case, false, work_dir, wabt, wasm_tools);
    }

    const checks = matrix.totalChecks();
    var report_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer report_buf.deinit(gpa);

    const header = try std.fmt.allocPrint(
        gpa,
        "Typed select differential matrix: {d}/{d} cases, {d}/{d} checks\nChecks:\n",
        .{ matrix.case_counter.passed, matrix.case_counter.total, checks.passed, checks.total },
    );
    defer gpa.free(header);
    try report_buf.appendSlice(gpa, header);

    const phase_keys = try Matrix.sortedKeys(gpa, &matrix.phases);
    defer gpa.free(phase_keys);
    for (phase_keys) |k| {
        const c = matrix.phases.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    try report_buf.appendSlice(gpa, "Families:\n");
    const fam_keys = try Matrix.sortedKeys(gpa, &matrix.groups);
    defer gpa.free(fam_keys);
    for (fam_keys) |k| {
        const c = matrix.groups.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    try writeStdout(io, report_buf.items);
    matrix.printMismatches();

    const failed = matrix.mismatches.items.len > 0;
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── 4. wide-arithmetic suite ─────────────────────────────────────────────────

const NamedWat = struct {
    name: []const u8,
    wat: []const u8,
};

const NamedBytes = struct {
    name: []const u8,
    bytes: []const u8,
};

const wide_valid_cases = [_]NamedWat{
    .{
        .name = "add128",
        .wat = "(module (func (param i64 i64 i64 i64) (result i64 i64) local.get 0 local.get 1 local.get 2 local.get 3 i64.add128))",
    },
    .{
        .name = "sub128",
        .wat = "(module (func (param i64 i64 i64 i64) (result i64 i64) local.get 0 local.get 1 local.get 2 local.get 3 i64.sub128))",
    },
    .{
        .name = "mul-wide-s",
        .wat = "(module (func (param i64 i64) (result i64 i64) local.get 0 local.get 1 i64.mul_wide_s))",
    },
    .{
        .name = "mul-wide-u",
        .wat = "(module (func (param i64 i64) (result i64 i64) local.get 0 local.get 1 i64.mul_wide_u))",
    },
    .{
        .name = "add128-unreachable",
        .wat = "(module (func (result i64 i64) unreachable i64.add128))",
    },
    .{
        .name = "sub128-unreachable",
        .wat = "(module (func (result i64 i64) unreachable i64.sub128))",
    },
    .{
        .name = "mul-wide-s-unreachable",
        .wat = "(module (func (result i64 i64) unreachable i64.mul_wide_s))",
    },
    .{
        .name = "mul-wide-u-unreachable",
        .wat = "(module (func (result i64 i64) unreachable i64.mul_wide_u))",
    },
};

const wide_invalid_wat_cases = [_]NamedWat{
    .{
        .name = "add128-missing-operand",
        .wat = "(module (func i64.const 0 i64.const 0 i64.const 0 i64.add128 drop drop))",
    },
    .{
        .name = "sub128-missing-operand",
        .wat = "(module (func i64.const 0 i64.const 0 i64.const 0 i64.sub128 drop drop))",
    },
    .{
        .name = "mul-wide-s-missing-operand",
        .wat = "(module (func i64.const 0 i64.mul_wide_s drop drop))",
    },
    .{
        .name = "mul-wide-u-missing-operand",
        .wat = "(module (func i64.const 0 i64.mul_wide_u drop drop))",
    },
    .{
        .name = "add128-wrong-operand",
        .wat = "(module (func i64.const 0 i64.const 0 i32.const 0 i64.const 0 i64.add128 drop drop))",
    },
    .{
        .name = "sub128-wrong-operand",
        .wat = "(module (func i64.const 0 i64.const 0 i64.const 0 i32.const 0 i64.sub128 drop drop))",
    },
    .{
        .name = "mul-wide-s-wrong-operand",
        .wat = "(module (func i32.const 0 i64.const 0 i64.mul_wide_s drop drop))",
    },
    .{
        .name = "mul-wide-u-wrong-operand",
        .wat = "(module (func i64.const 0 i32.const 0 i64.mul_wide_u drop drop))",
    },
    .{
        .name = "add128-result-count",
        .wat = "(module (func (result i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128))",
    },
    .{
        .name = "sub128-result-count",
        .wat = "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128))",
    },
    .{
        .name = "mul-wide-s-result-count",
        .wat = "(module (func (result i64) i64.const 0 i64.const 0 i64.mul_wide_s))",
    },
    .{
        .name = "mul-wide-u-result-count",
        .wat = "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 i64.mul_wide_u))",
    },
    .{
        .name = "add128-result-type",
        .wat = "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.add128))",
    },
    .{
        .name = "sub128-result-type",
        .wat = "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.const 0 i64.const 0 i64.sub128))",
    },
    .{
        .name = "mul-wide-s-result-type",
        .wat = "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.mul_wide_s))",
    },
    .{
        .name = "mul-wide-u-result-type",
        .wat = "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.mul_wide_u))",
    },
    .{
        .name = "add128-unreachable-result",
        .wat = "(module (func (result i32 i64) unreachable i64.add128))",
    },
    .{
        .name = "sub128-unreachable-result",
        .wat = "(module (func (result i32 i64) unreachable i64.sub128))",
    },
    .{
        .name = "mul-wide-s-unreachable-result",
        .wat = "(module (func (result i32 i64) unreachable i64.mul_wide_s))",
    },
    .{
        .name = "mul-wide-u-unreachable-result",
        .wat = "(module (func (result i32 i64) unreachable i64.mul_wide_u))",
    },
};

const wide_invalid_binary_cases = [_]NamedBytes{
    .{ .name = "truncated-prefix", .bytes = &[_]u8{0xFC} },
    .{ .name = "malformed-subopcode-leb", .bytes = &[_]u8{ 0xFC, 0x80, 0x80, 0x80, 0x80, 0x80, 0x0B } },
    .{ .name = "unknown-before-wide", .bytes = &[_]u8{ 0xFC, 0x12, 0x0B } },
    .{ .name = "unknown-after-wide", .bytes = &[_]u8{ 0xFC, 0x17, 0x0B } },
};

fn runWideArithmeticSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    try prepareWorkDir(gpa, io, work_dir);
    var matrix = Matrix{ .gpa = gpa };
    defer matrix.deinit();

    const wast_res = try runCmd(gpa, io, &.{
        wasm_tools,
        "wast",
        "--color",
        "never",
        "--features=wide-arithmetic",
        "test/spec-new/wide-arithmetic.wast",
    });
    defer wast_res.deinit(gpa);
    const wast_sum = try wast_res.summary(gpa);
    defer gpa.free(wast_sum);
    _ = try matrix.check("proposal-wast", "wide-arithmetic.wast", wast_res.accepted(), wast_sum);

    for (wide_valid_cases) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.name });
        defer gpa.free(source);
        const wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.wasm", .{ case_dir, case.name });
        defer gpa.free(wasm);
        const disabled_wasm = try std.fmt.allocPrint(gpa, "{s}/disabled.wasm", .{case_dir});
        defer gpa.free(disabled_wasm);
        const printed = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.wat", .{ case_dir, case.name });
        defer gpa.free(printed);
        const reparsed = try std.fmt.allocPrint(gpa, "{s}/{s}.reparsed.wasm", .{ case_dir, case.name });
        defer gpa.free(reparsed);

        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        var passed = true;
        const wabt_enabled = try runCmd(gpa, io, &.{ wabt, "text", "parse", "--enable-wide-arithmetic", source, "-o", wasm });
        defer wabt_enabled.deinit(gpa);
        const tools_enabled = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=wide-arithmetic", source });
        defer tools_enabled.deinit(gpa);

        const en_detail = try pairDetail(gpa, wabt_enabled, tools_enabled);
        defer gpa.free(en_detail);
        if (!try matrix.check("wat-enabled", case.name, wabt_enabled.accepted() and tools_enabled.accepted(), en_detail)) {
            passed = false;
        }

        const wabt_disabled = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", disabled_wasm });
        defer wabt_disabled.deinit(gpa);
        const tools_disabled = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=-wide-arithmetic", source });
        defer tools_disabled.deinit(gpa);

        const dis_detail = try pairDetail(gpa, wabt_disabled, tools_disabled);
        defer gpa.free(dis_detail);
        if (!try matrix.check("wat-disabled", case.name, wabt_disabled.rejected() and tools_disabled.rejected(), dis_detail)) {
            passed = false;
        }

        if (wabt_enabled.accepted()) {
            const wabt_binary = try runCmd(gpa, io, &.{ wabt, "module", "validate", "--enable-wide-arithmetic", wasm });
            defer wabt_binary.deinit(gpa);
            const tools_binary = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=wide-arithmetic", wasm });
            defer tools_binary.deinit(gpa);

            const bin_en_detail = try pairDetail(gpa, wabt_binary, tools_binary);
            defer gpa.free(bin_en_detail);
            if (!try matrix.check("binary-enabled", case.name, wabt_binary.accepted() and tools_binary.accepted(), bin_en_detail)) {
                passed = false;
            }

            const wabt_bin_dis = try runCmd(gpa, io, &.{ wabt, "module", "validate", wasm });
            defer wabt_bin_dis.deinit(gpa);
            const tools_bin_dis = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=-wide-arithmetic", wasm });
            defer tools_bin_dis.deinit(gpa);

            const bin_dis_detail = try pairDetail(gpa, wabt_bin_dis, tools_bin_dis);
            defer gpa.free(bin_dis_detail);
            if (!try matrix.check("binary-disabled", case.name, wabt_bin_dis.rejected() and tools_bin_dis.rejected(), bin_dis_detail)) {
                passed = false;
            }

            const print_res = try runCmd(gpa, io, &.{ wabt, "text", "print", wasm, "-o", printed });
            defer print_res.deinit(gpa);
            const tools_on_printed = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=wide-arithmetic", printed });
            defer tools_on_printed.deinit(gpa);

            const pr_sum = try print_res.summary(gpa);
            defer gpa.free(pr_sum);
            const top_sum = try tools_on_printed.summary(gpa);
            defer gpa.free(top_sum);
            const out_detail = try std.fmt.allocPrint(gpa, "print {s}; validate {s}", .{ pr_sum, top_sum });
            defer gpa.free(out_detail);
            if (!try matrix.check("wasm-tools-on-wabt-output", case.name, print_res.accepted() and tools_on_printed.accepted(), out_detail)) {
                passed = false;
            }

            const reparse_res = try runCmd(gpa, io, &.{ wabt, "text", "parse", "--enable-wide-arithmetic", printed, "-o", reparsed });
            defer reparse_res.deinit(gpa);
            const wabt_reval = try runCmd(gpa, io, &.{ wabt, "module", "validate", "--enable-wide-arithmetic", reparsed });
            defer wabt_reval.deinit(gpa);
            const tools_reval = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=wide-arithmetic", reparsed });
            defer tools_reval.deinit(gpa);

            const rp_sum = try reparse_res.summary(gpa);
            defer gpa.free(rp_sum);
            const wr_sum = try wabt_reval.summary(gpa);
            defer gpa.free(wr_sum);
            const tr_sum = try tools_reval.summary(gpa);
            defer gpa.free(tr_sum);
            const rt_detail = try std.fmt.allocPrint(gpa, "reparse {s}; wabt {s}; wasm-tools {s}", .{ rp_sum, wr_sum, tr_sum });
            defer gpa.free(rt_detail);

            if (!try matrix.check(
                "wabt-roundtrip",
                case.name,
                reparse_res.accepted() and wabt_reval.accepted() and tools_reval.accepted(),
                rt_detail,
            )) {
                passed = false;
            }
        } else {
            for (&[_][]const u8{
                "binary-enabled",
                "binary-disabled",
                "wasm-tools-on-wabt-output",
                "wabt-roundtrip",
            }) |phase| {
                _ = try matrix.check(phase, case.name, false, "wabt did not produce a binary");
                passed = false;
            }
        }

        matrix.finishCase(passed);
    }

    for (wide_invalid_wat_cases) |case| {
        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ work_dir, case.name });
        defer gpa.free(source);
        const out_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ work_dir, case.name });
        defer gpa.free(out_wasm);
        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "text", "parse", "--enable-wide-arithmetic", source, "-o", out_wasm });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=wide-arithmetic", source });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check("invalid-wat", case.name, wabt_res.rejected() and tools_res.rejected(), detail);
        matrix.finishCase(passed);
    }

    for (wide_invalid_binary_cases) |case| {
        const wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ work_dir, case.name });
        defer gpa.free(wasm);
        const mod_bytes = try moduleWithSimpleBody(gpa, case.bytes);
        defer gpa.free(mod_bytes);
        try cwd.writeFile(io, .{ .sub_path = wasm, .data = mod_bytes });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "module", "validate", "--enable-wide-arithmetic", wasm });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=wide-arithmetic", wasm });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check("invalid-binary", case.name, wabt_res.rejected() and tools_res.rejected(), detail);
        matrix.finishCase(passed);
    }

    const checks = matrix.totalChecks();
    var report_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer report_buf.deinit(gpa);

    const header = try std.fmt.allocPrint(
        gpa,
        "Wide arithmetic differential matrix: {d}/{d} cases, {d}/{d} checks\n",
        .{ matrix.case_counter.passed, matrix.case_counter.total, checks.passed, checks.total },
    );
    defer gpa.free(header);
    try report_buf.appendSlice(gpa, header);

    const phase_keys = try Matrix.sortedKeys(gpa, &matrix.phases);
    defer gpa.free(phase_keys);
    for (phase_keys) |k| {
        const c = matrix.phases.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }
    try report_buf.appendSlice(gpa, "  opcodes: 0xfc13 0xfc14 0xfc15 0xfc16\n");

    const failed = matrix.mismatches.items.len > 0;
    if (keep_work or failed) {
        const mat_line = try std.fmt.allocPrint(gpa, "Materialized matrix: {s}\n", .{work_dir});
        defer gpa.free(mat_line);
        try report_buf.appendSlice(gpa, mat_line);
    }

    try writeStdout(io, report_buf.items);
    matrix.printMismatches();
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── 5. custom-page-sizes suite ───────────────────────────────────────────────

const cps_wasm_features = "-all,custom-page-sizes,memory64,multi-memory,threads";
const cps_wasm_features_disabled = "-all,memory64,multi-memory,threads";
const cps_wabt_feature = "--enable-custom-page-sizes";

const CpsWatCase = struct {
    name: []const u8,
    wat: []const u8,
    custom: bool,
    page_one_count: usize = 0,
    page_default_count: usize = 0,
};

const cps_valid_wat_cases = [_]CpsWatCase{
    .{ .name = "implicit-default", .wat = "(module (memory $m 1))", .custom = false },
    .{ .name = "ordinary-table", .wat = "(module (table $t 1 2 funcref))", .custom = false },
    .{
        .name = "defined-named-memory32-page1",
        .wat = "(module (memory $m 1 (pagesize 1)) (export \"m\" (memory $m)))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "defined-explicit-default",
        .wat = "(module (memory $m 1 (pagesize 65536)))",
        .custom = true,
        .page_default_count = 1,
    },
    .{
        .name = "standalone-import-memory32",
        .wat = "(module (import \"a\" \"b\" (memory $m 0 4294967295 (pagesize 1))))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "inline-import-memory64",
        .wat = "(module (memory $m (import \"a\" \"b\") i64 0 18446744073709551615 (pagesize 1)))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "shared-memory32",
        .wat = "(module (memory $m 0 4294967295 shared (pagesize 1)))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "shared-memory64-explicit-default",
        .wat = "(module (memory $m i64 0 281474976710656 shared (pagesize 65536)))",
        .custom = true,
        .page_default_count = 1,
    },
    .{
        .name = "memory32-page1-upper-bound",
        .wat = "(module (memory 4294967295 (pagesize 1)))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "memory32-default-upper-bound",
        .wat = "(module (memory 65536 (pagesize 65536)))",
        .custom = true,
        .page_default_count = 1,
    },
    .{
        .name = "memory64-page1-upper-bound",
        .wat = "(module (memory i64 18446744073709551615 (pagesize 1)))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "multiple-mixed-named",
        .wat = "(module (memory $a 1 (pagesize 1)) (memory $b i64 281474976710656 (pagesize 65536)) (export \"a\" (memory $a)) (export \"b\" (memory $b)))",
        .custom = true,
        .page_one_count = 1,
        .page_default_count = 1,
    },
    .{
        .name = "inline-data-page1",
        .wat = "(module (memory (pagesize 1) (data \"xyz\")))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "inline-data-named-export-page1",
        .wat = "(module (memory $m (export \"m\") (pagesize 1) (data \"xyz\")))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "inline-data-export-memory64-page1",
        .wat = "(module (memory (export \"m\") i64 (pagesize 1) (data \"x\")))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "inline-data-named-export-memory64-page1",
        .wat = "(module (memory $m (export \"m\") i64 (pagesize 1) (data \"x\")))",
        .custom = true,
        .page_one_count = 1,
    },
    .{
        .name = "inline-data-empty-explicit-default",
        .wat = "(module (memory (pagesize 65536) (data \"\")))",
        .custom = true,
        .page_default_count = 1,
    },
};

const cps_invalid_wat_cases = [_]NamedWat{
    .{ .name = "page-zero", .wat = "(module (memory 1 (pagesize 0)))" },
    .{ .name = "page-two", .wat = "(module (memory 1 (pagesize 2)))" },
    .{ .name = "page-three", .wat = "(module (memory 1 (pagesize 3)))" },
    .{ .name = "page-intermediate-power", .wat = "(module (memory 1 (pagesize 32768)))" },
    .{ .name = "page-non-power-upper", .wat = "(module (memory 1 (pagesize 65537)))" },
    .{ .name = "page-u32-max", .wat = "(module (memory 1 (pagesize 4294967295)))" },
    .{ .name = "page-u32-overflow", .wat = "(module (memory 1 (pagesize 4294967296)))" },
    .{ .name = "defined-memory64-page-three", .wat = "(module (memory $m i64 1 (pagesize 3)))" },
    .{ .name = "standalone-import-page-three", .wat = "(module (import \"a\" \"b\" (memory $m 1 (pagesize 3))))" },
    .{ .name = "inline-import-page-three", .wat = "(module (memory $m (import \"a\" \"b\") 1 (pagesize 3)))" },
    .{ .name = "shared-without-max", .wat = "(module (memory 1 shared (pagesize 1)))" },
    .{ .name = "max-below-min", .wat = "(module (memory 2 1 shared (pagesize 1)))" },
    .{ .name = "memory32-default-min-overflow", .wat = "(module (memory 65537 (pagesize 65536)))" },
    .{ .name = "memory32-default-max-overflow", .wat = "(module (memory 0 65537 (pagesize 65536)))" },
    .{ .name = "memory32-page1-count-overflow", .wat = "(module (memory 4294967296 (pagesize 1)))" },
    .{ .name = "memory64-default-count-overflow", .wat = "(module (memory i64 281474976710657 (pagesize 65536)))" },
    .{ .name = "memory64-count-u64-overflow", .wat = "(module (memory i64 18446744073709551616 (pagesize 1)))" },
    .{ .name = "multiple-second-invalid", .wat = "(module (memory $a 1 (pagesize 1)) (memory $b 1 (pagesize 3)))" },
    .{ .name = "table-page-size", .wat = "(module (table 1 (pagesize 1) funcref))" },
    .{ .name = "shared-table-defined", .wat = "(module (table 0 1 shared funcref))" },
    .{ .name = "shared-table-imported", .wat = "(module (import \"m\" \"t\" (table 0 1 shared funcref)))" },
    .{ .name = "page-size-before-shared", .wat = "(module (memory 1 2 (pagesize 1) shared))" },
    .{ .name = "duplicate-page-size", .wat = "(module (memory 1 (pagesize 1) (pagesize 1)))" },
    .{ .name = "inline-data-invalid-page-size", .wat = "(module (memory (pagesize 2) (data \"x\")))" },
    .{ .name = "inline-data-page-size-after-data", .wat = "(module (memory (data \"x\") (pagesize 1)))" },
    .{ .name = "inline-data-export-after-page-size", .wat = "(module (memory (pagesize 1) (export \"m\") (data \"x\")))" },
    .{ .name = "inline-data-export-after-memory64", .wat = "(module (memory i64 (export \"m\") (data \"x\")))" },
    .{ .name = "inline-data-memory64-after-page-size", .wat = "(module (memory (pagesize 1) i64 (data \"x\")))" },
    .{ .name = "inline-data-import-after-memory64", .wat = "(module (memory i64 (import \"m\" \"n\") 1))" },
    .{ .name = "inline-data-memory64-after-data", .wat = "(module (memory (data \"x\") i64))" },
};

fn buildLimitsBytes(
    gpa: std.mem.Allocator,
    flags: u8,
    minimum: u64,
    maximum: ?u64,
    log2: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, flags);
    try appendUleb(&out, gpa, minimum);
    if ((flags & 0x01) != 0) {
        try appendUleb(&out, gpa, maximum.?);
    }
    try out.appendSlice(gpa, log2);
    return out.toOwnedSlice(gpa);
}

fn buildMemoriesModule(gpa: std.mem.Allocator, entries: []const []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(gpa);
    try appendUleb(&payload, gpa, entries.len);
    for (entries) |e| try payload.appendSlice(gpa, e);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x00asm\x01\x00\x00\x00");
    try appendSection(&out, gpa, 5, payload.items);
    return out.toOwnedSlice(gpa);
}

fn buildImportedMemoryModule(gpa: std.mem.Allocator, entry: []const u8) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(gpa);
    try appendUleb(&payload, gpa, 1);
    try payload.appendSlice(gpa, "\x01m\x01n\x02");
    try payload.appendSlice(gpa, entry);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x00asm\x01\x00\x00\x00");
    try appendSection(&out, gpa, 2, payload.items);
    return out.toOwnedSlice(gpa);
}

fn buildSectionModule(gpa: std.mem.Allocator, section_id: u8, payload: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x00asm\x01\x00\x00\x00");
    try appendSection(&out, gpa, section_id, payload);
    return out.toOwnedSlice(gpa);
}

fn countSubstrings(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

fn markerCountsOk(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    page_one: usize,
    page_default: usize,
) bool {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch return false;
    defer gpa.free(text);
    return countSubstrings(text, "(pagesize 0x1)") == page_one and
        countSubstrings(text, "(pagesize 0x10000)") == page_default;
}

const CpsBinaryCase = struct {
    name: []const u8,
    wasm: []u8,
    custom: bool,
    page_one_count: usize = 0,
    page_default_count: usize = 0,
};

fn runCustomPageSizesSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    try prepareWorkDir(gpa, io, work_dir);
    var matrix = Matrix{ .gpa = gpa };
    defer matrix.deinit();

    const feat_en_arg = "--features=" ++ cps_wasm_features;
    const feat_dis_arg = "--features=" ++ cps_wasm_features_disabled;

    for (cps_valid_wat_cases) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const source = try std.fmt.allocPrint(gpa, "{s}/input.wat", .{case_dir});
        defer gpa.free(source);
        const wasm = try std.fmt.allocPrint(gpa, "{s}/wabt.wasm", .{case_dir});
        defer gpa.free(wasm);
        const disabled_wasm = try std.fmt.allocPrint(gpa, "{s}/disabled.wasm", .{case_dir});
        defer gpa.free(disabled_wasm);
        const printed = try std.fmt.allocPrint(gpa, "{s}/printed.wat", .{case_dir});
        defer gpa.free(printed);
        const reparsed = try std.fmt.allocPrint(gpa, "{s}/reparsed.wasm", .{case_dir});
        defer gpa.free(reparsed);
        const canonical_before = try std.fmt.allocPrint(gpa, "{s}/canonical-before.wat", .{case_dir});
        defer gpa.free(canonical_before);
        const canonical_after = try std.fmt.allocPrint(gpa, "{s}/canonical-after.wat", .{case_dir});
        defer gpa.free(canonical_after);

        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        var passed = true;
        const wabt_en = try runCmd(gpa, io, &.{ wabt, "text", "parse", cps_wabt_feature, source, "-o", wasm });
        defer wabt_en.deinit(gpa);
        const tools_en = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, source });
        defer tools_en.deinit(gpa);

        const en_detail = try pairDetail(gpa, wabt_en, tools_en);
        defer gpa.free(en_detail);
        if (!try matrix.check("wat-enabled", case.name, wabt_en.accepted() and tools_en.accepted(), en_detail)) {
            passed = false;
        }

        const wabt_dis = try runCmd(gpa, io, &.{ wabt, "text", "parse", source, "-o", disabled_wasm });
        defer wabt_dis.deinit(gpa);
        const tools_dis = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_dis_arg, source });
        defer tools_dis.deinit(gpa);

        const dis_ok = if (case.custom)
            wabt_dis.rejected() and tools_dis.rejected()
        else
            wabt_dis.accepted() and tools_dis.accepted();
        const dis_detail = try pairDetail(gpa, wabt_dis, tools_dis);
        defer gpa.free(dis_detail);
        if (!try matrix.check("wat-disabled", case.name, dis_ok, dis_detail)) {
            passed = false;
        }

        if (wabt_en.accepted()) {
            const wabt_bin = try runCmd(gpa, io, &.{ wabt, "module", "validate", cps_wabt_feature, wasm });
            defer wabt_bin.deinit(gpa);
            const tools_bin = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, wasm });
            defer tools_bin.deinit(gpa);

            const bin_en_detail = try pairDetail(gpa, wabt_bin, tools_bin);
            defer gpa.free(bin_en_detail);
            if (!try matrix.check("binary-enabled", case.name, wabt_bin.accepted() and tools_bin.accepted(), bin_en_detail)) {
                passed = false;
            }

            const wabt_bin_dis = try runCmd(gpa, io, &.{ wabt, "module", "validate", wasm });
            defer wabt_bin_dis.deinit(gpa);
            const tools_bin_dis = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_dis_arg, wasm });
            defer tools_bin_dis.deinit(gpa);

            const bin_dis_ok = if (case.custom)
                wabt_bin_dis.rejected() and tools_bin_dis.rejected()
            else
                wabt_bin_dis.accepted() and tools_bin_dis.accepted();
            const bin_dis_detail = try pairDetail(gpa, wabt_bin_dis, tools_bin_dis);
            defer gpa.free(bin_dis_detail);
            if (!try matrix.check("binary-disabled", case.name, bin_dis_ok, bin_dis_detail)) {
                passed = false;
            }

            const print_res = try runCmd(gpa, io, &.{ wabt, "text", "print", wasm, "-o", printed });
            defer print_res.deinit(gpa);
            const marker_ok = print_res.accepted() and markerCountsOk(gpa, io, printed, case.page_one_count, case.page_default_count);

            const tools_on_printed = if (print_res.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, printed })
            else
                null;
            defer if (tools_on_printed) |r| r.deinit(gpa);

            const reparse_res = if (print_res.accepted())
                try runCmd(gpa, io, &.{ wabt, "text", "parse", cps_wabt_feature, printed, "-o", reparsed })
            else
                null;
            defer if (reparse_res) |r| r.deinit(gpa);

            const wabt_reval = if (reparse_res != null and reparse_res.?.accepted())
                try runCmd(gpa, io, &.{ wabt, "module", "validate", cps_wabt_feature, reparsed })
            else
                null;
            defer if (wabt_reval) |r| r.deinit(gpa);

            const tools_reval = if (reparse_res != null and reparse_res.?.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, reparsed })
            else
                null;
            defer if (tools_reval) |r| r.deinit(gpa);

            const cb_res = try runCmd(gpa, io, &.{ wasm_tools, "print", wasm, "-o", canonical_before });
            defer cb_res.deinit(gpa);
            const ca_res = if (reparse_res != null and reparse_res.?.accepted())
                try runCmd(gpa, io, &.{ wasm_tools, "print", reparsed, "-o", canonical_after })
            else
                null;
            defer if (ca_res) |r| r.deinit(gpa);

            var canonical_equal = false;
            if (cb_res.accepted() and ca_res != null and ca_res.?.accepted()) {
                const b_bytes = cwd.readFileAlloc(io, canonical_before, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
                defer if (b_bytes) |b| gpa.free(b);
                const a_bytes = cwd.readFileAlloc(io, canonical_after, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
                defer if (a_bytes) |a| gpa.free(a);
                if (b_bytes != null and a_bytes != null) {
                    canonical_equal = std.mem.eql(u8, b_bytes.?, a_bytes.?);
                }
            }

            const roundtrip_ok = marker_ok and
                (tools_on_printed != null and tools_on_printed.?.accepted()) and
                (reparse_res != null and reparse_res.?.accepted()) and
                (wabt_reval != null and wabt_reval.?.accepted()) and
                (tools_reval != null and tools_reval.?.accepted()) and
                canonical_equal;

            const pr_sum = try print_res.summary(gpa);
            defer gpa.free(pr_sum);
            const rp_sum = if (reparse_res) |r| try r.summary(gpa) else try gpa.dupe(u8, pr_sum);
            defer gpa.free(rp_sum);
            const rt_detail = try std.fmt.allocPrint(
                gpa,
                "print {s}; reparse {s}; marker counts ok={any}; canonical equal={any}",
                .{ pr_sum, rp_sum, marker_ok, canonical_equal },
            );
            defer gpa.free(rt_detail);

            if (!try matrix.check("text-binary-roundtrip", case.name, roundtrip_ok, rt_detail)) {
                passed = false;
            }
        } else {
            for (&[_][]const u8{
                "binary-enabled",
                "binary-disabled",
                "text-binary-roundtrip",
            }) |phase| {
                _ = try matrix.check(phase, case.name, false, "wabt did not produce a binary");
                passed = false;
            }
        }

        matrix.finishCase(passed);
    }

    // Build valid binary cases
    const lim_overlong_zero = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{ 0x80, 0x00 });
    defer gpa.free(lim_overlong_zero);
    const lim_exp_default = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{16});
    defer gpa.free(lim_exp_default);
    const lim_imp_default = try buildLimitsBytes(gpa, 0x00, 0, null, &.{});
    defer gpa.free(lim_imp_default);
    const lim_imp_page1 = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{0});
    defer gpa.free(lim_imp_page1);
    const lim_m64_shared_p1 = try buildLimitsBytes(gpa, 0x0F, 0, 0xFFFFFFFFFFFFFFFF, &[_]u8{0});
    defer gpa.free(lim_m64_shared_p1);

    const valid_bin_cases = [_]CpsBinaryCase{
        .{
            .name = "binary-overlong-log2-zero",
            .wasm = try buildMemoriesModule(gpa, &.{lim_overlong_zero}),
            .custom = true,
            .page_one_count = 1,
        },
        .{
            .name = "binary-explicit-default",
            .wasm = try buildMemoriesModule(gpa, &.{lim_exp_default}),
            .custom = true,
            .page_default_count = 1,
        },
        .{
            .name = "binary-implicit-default",
            .wasm = try buildMemoriesModule(gpa, &.{lim_imp_default}),
            .custom = false,
        },
        .{
            .name = "binary-imported-page1",
            .wasm = try buildImportedMemoryModule(gpa, lim_imp_page1),
            .custom = true,
            .page_one_count = 1,
        },
        .{
            .name = "binary-memory64-shared-page1",
            .wasm = try buildMemoriesModule(gpa, &.{lim_m64_shared_p1}),
            .custom = true,
            .page_one_count = 1,
        },
    };
    defer for (valid_bin_cases) |c| gpa.free(c.wasm);

    for (valid_bin_cases) |case| {
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.name });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const wasm = try std.fmt.allocPrint(gpa, "{s}/input.wasm", .{case_dir});
        defer gpa.free(wasm);
        const printed = try std.fmt.allocPrint(gpa, "{s}/printed.wat", .{case_dir});
        defer gpa.free(printed);
        const reparsed = try std.fmt.allocPrint(gpa, "{s}/reparsed.wasm", .{case_dir});
        defer gpa.free(reparsed);
        try cwd.writeFile(io, .{ .sub_path = wasm, .data = case.wasm });

        var passed = true;
        const wabt_en = try runCmd(gpa, io, &.{ wabt, "module", "validate", cps_wabt_feature, wasm });
        defer wabt_en.deinit(gpa);
        const tools_en = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, wasm });
        defer tools_en.deinit(gpa);

        const en_detail = try pairDetail(gpa, wabt_en, tools_en);
        defer gpa.free(en_detail);
        if (!try matrix.check("valid-binary-enabled", case.name, wabt_en.accepted() and tools_en.accepted(), en_detail)) {
            passed = false;
        }

        const wabt_dis = try runCmd(gpa, io, &.{ wabt, "module", "validate", wasm });
        defer wabt_dis.deinit(gpa);
        const tools_dis = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_dis_arg, wasm });
        defer tools_dis.deinit(gpa);

        const dis_ok = if (case.custom)
            wabt_dis.rejected() and tools_dis.rejected()
        else
            wabt_dis.accepted() and tools_dis.accepted();
        const dis_detail = try pairDetail(gpa, wabt_dis, tools_dis);
        defer gpa.free(dis_detail);
        if (!try matrix.check("valid-binary-disabled", case.name, dis_ok, dis_detail)) {
            passed = false;
        }

        const print_res = try runCmd(gpa, io, &.{ wabt, "text", "print", wasm, "-o", printed });
        defer print_res.deinit(gpa);
        const marker_ok = print_res.accepted() and markerCountsOk(gpa, io, printed, case.page_one_count, case.page_default_count);

        const reparse_res = if (print_res.accepted())
            try runCmd(gpa, io, &.{ wabt, "text", "parse", cps_wabt_feature, printed, "-o", reparsed })
        else
            null;
        defer if (reparse_res) |r| r.deinit(gpa);

        const wabt_reval = if (reparse_res != null and reparse_res.?.accepted())
            try runCmd(gpa, io, &.{ wabt, "module", "validate", cps_wabt_feature, reparsed })
        else
            null;
        defer if (wabt_reval) |r| r.deinit(gpa);

        const tools_reval = if (reparse_res != null and reparse_res.?.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, reparsed })
        else
            null;
        defer if (tools_reval) |r| r.deinit(gpa);

        const rt_ok = marker_ok and
            (reparse_res != null and reparse_res.?.accepted()) and
            (wabt_reval != null and wabt_reval.?.accepted()) and
            (tools_reval != null and tools_reval.?.accepted());

        const pr_sum = try print_res.summary(gpa);
        defer gpa.free(pr_sum);
        const rp_sum = if (reparse_res) |r| try r.summary(gpa) else try gpa.dupe(u8, pr_sum);
        defer gpa.free(rp_sum);
        const rt_detail = try std.fmt.allocPrint(
            gpa,
            "print {s}; reparse {s}; marker counts ok={any}",
            .{ pr_sum, rp_sum, marker_ok },
        );
        defer gpa.free(rt_detail);

        if (!try matrix.check("valid-binary-roundtrip", case.name, rt_ok, rt_detail)) {
            passed = false;
        }

        matrix.finishCase(passed);
    }

    for (cps_invalid_wat_cases) |case| {
        const source = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ work_dir, case.name });
        defer gpa.free(source);
        const out_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ work_dir, case.name });
        defer gpa.free(out_wasm);
        try cwd.writeFile(io, .{ .sub_path = source, .data = case.wat });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "text", "parse", cps_wabt_feature, source, "-o", out_wasm });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, source });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check("invalid-wat", case.name, wabt_res.rejected() and tools_res.rejected(), detail);
        matrix.finishCase(passed);
    }

    // Build invalid binary cases
    var u32_max_leb: std.ArrayListUnmanaged(u8) = .empty;
    defer u32_max_leb.deinit(gpa);
    try appendUleb(&u32_max_leb, gpa, 0xFFFFFFFF);

    const lim_log2_1 = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{1});
    defer gpa.free(lim_log2_1);
    const lim_log2_15 = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{15});
    defer gpa.free(lim_log2_15);
    const lim_log2_17 = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{17});
    defer gpa.free(lim_log2_17);
    const lim_log2_u32_max = try buildLimitsBytes(gpa, 0x08, 0, null, u32_max_leb.items);
    defer gpa.free(lim_log2_u32_max);
    const lim_log2_overflow = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10 });
    defer gpa.free(lim_log2_overflow);
    const lim_truncated_log2 = try buildLimitsBytes(gpa, 0x08, 0, null, &.{});
    defer gpa.free(lim_truncated_log2);
    const lim_unknown_flags = try buildLimitsBytes(gpa, 0x10, 0, null, &.{});
    defer gpa.free(lim_unknown_flags);
    const lim_shared_no_max = try buildLimitsBytes(gpa, 0x0A, 0, null, &[_]u8{0});
    defer gpa.free(lim_shared_no_max);
    const lim_m32_def_overflow = try buildLimitsBytes(gpa, 0x08, 65537, null, &[_]u8{16});
    defer gpa.free(lim_m32_def_overflow);
    const lim_m64_def_overflow = try buildLimitsBytes(gpa, 0x0C, (@as(u64, 1) << 48) + 1, null, &[_]u8{16});
    defer gpa.free(lim_m64_def_overflow);
    const lim_imp_log2_3 = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{3});
    defer gpa.free(lim_imp_log2_3);

    var table_custom_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer table_custom_payload.deinit(gpa);
    try table_custom_payload.appendSlice(gpa, &[_]u8{ 0x01, 0x70 });
    try table_custom_payload.appendSlice(gpa, lim_imp_page1);

    const lim_table_shared = try buildLimitsBytes(gpa, 0x03, 0, 1, &.{});
    defer gpa.free(lim_table_shared);
    var table_shared_payload: std.ArrayListUnmanaged(u8) = .empty;
    defer table_shared_payload.deinit(gpa);
    try table_shared_payload.appendSlice(gpa, &[_]u8{ 0x01, 0x70 });
    try table_shared_payload.appendSlice(gpa, lim_table_shared);

    const invalid_bin_cases = [_]struct { name: []const u8, wasm: []u8 }{
        .{ .name = "binary-log2-one", .wasm = try buildMemoriesModule(gpa, &.{lim_log2_1}) },
        .{ .name = "binary-log2-fifteen", .wasm = try buildMemoriesModule(gpa, &.{lim_log2_15}) },
        .{ .name = "binary-log2-seventeen", .wasm = try buildMemoriesModule(gpa, &.{lim_log2_17}) },
        .{ .name = "binary-log2-u32-max", .wasm = try buildMemoriesModule(gpa, &.{lim_log2_u32_max}) },
        .{ .name = "binary-log2-overflow", .wasm = try buildMemoriesModule(gpa, &.{lim_log2_overflow}) },
        .{
            .name = "binary-memory32-limit-overflow",
            .wasm = try buildMemoriesModule(gpa, &.{&[_]u8{ 0x00, 0x80, 0x80, 0x80, 0x80, 0x10 }}),
        },
        .{
            .name = "binary-memory64-limit-overflow",
            .wasm = try buildMemoriesModule(gpa, &.{&[_]u8{ 0x04, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }}),
        },
        .{ .name = "binary-truncated-log2", .wasm = try buildMemoriesModule(gpa, &.{lim_truncated_log2}) },
        .{ .name = "binary-unknown-flags", .wasm = try buildMemoriesModule(gpa, &.{lim_unknown_flags}) },
        .{ .name = "binary-shared-without-max", .wasm = try buildMemoriesModule(gpa, &.{lim_shared_no_max}) },
        .{ .name = "binary-table-custom-page", .wasm = try buildSectionModule(gpa, 4, table_custom_payload.items) },
        .{ .name = "binary-table-shared", .wasm = try buildSectionModule(gpa, 4, table_shared_payload.items) },
        .{ .name = "binary-memory32-default-overflow", .wasm = try buildMemoriesModule(gpa, &.{lim_m32_def_overflow}) },
        .{ .name = "binary-memory64-default-overflow", .wasm = try buildMemoriesModule(gpa, &.{lim_m64_def_overflow}) },
        .{ .name = "binary-import-log2-three", .wasm = try buildImportedMemoryModule(gpa, lim_imp_log2_3) },
        .{
            .name = "binary-multiple-second-invalid",
            .wasm = try buildMemoriesModule(gpa, &.{ lim_imp_page1, lim_log2_1 }),
        },
    };
    defer for (invalid_bin_cases) |c| gpa.free(c.wasm);

    for (invalid_bin_cases) |case| {
        const wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ work_dir, case.name });
        defer gpa.free(wasm);
        try cwd.writeFile(io, .{ .sub_path = wasm, .data = case.wasm });

        const wabt_res = try runCmd(gpa, io, &.{ wabt, "module", "validate", cps_wabt_feature, wasm });
        defer wabt_res.deinit(gpa);
        const tools_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_en_arg, wasm });
        defer tools_res.deinit(gpa);

        const detail = try pairDetail(gpa, wabt_res, tools_res);
        defer gpa.free(detail);
        const passed = try matrix.check("invalid-binary", case.name, wabt_res.rejected() and tools_res.rejected(), detail);
        matrix.finishCase(passed);
    }

    const checks = matrix.totalChecks();
    var report_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer report_buf.deinit(gpa);

    const header = try std.fmt.allocPrint(
        gpa,
        "Custom page-size differential matrix: {d}/{d} cases, {d}/{d} checks\n",
        .{ matrix.case_counter.passed, matrix.case_counter.total, checks.passed, checks.total },
    );
    defer gpa.free(header);
    try report_buf.appendSlice(gpa, header);

    const phase_keys = try Matrix.sortedKeys(gpa, &matrix.phases);
    defer gpa.free(phase_keys);
    for (phase_keys) |k| {
        const c = matrix.phases.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }
    try report_buf.appendSlice(gpa, "  accepted page sizes: 1, 65536 bytes\n");

    const failed = matrix.mismatches.items.len > 0;
    if (keep_work or failed) {
        const mat_line = try std.fmt.allocPrint(gpa, "Materialized matrix: {s}\n", .{work_dir});
        defer gpa.free(mat_line);
        try report_buf.appendSlice(gpa, mat_line);
    }

    try writeStdout(io, report_buf.items);
    matrix.printMismatches();
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── 6. feature-gate suite ────────────────────────────────────────────────────

const WabtGateMode = enum {
    default,
    wide,
    library_only,
};

const FeatureGateCase = struct {
    family: []const u8,
    feature: []const u8,
    wat: []const u8,
    wabt_mode: WabtGateMode = .default,
};

const feature_gate_cases = [_]FeatureGateCase{
    .{ .family = "exceptions", .feature = "exceptions", .wat = "(module (tag $e) (func throw $e))" },
    .{ .family = "tail-call", .feature = "tail-call", .wat = "(module (func $callee) (func return_call $callee))" },
    .{
        .family = "function-references",
        .feature = "function-references",
        .wat = "(module (func (result (ref func)) ref.null func ref.as_non_null))",
    },
    .{ .family = "sign-extension", .feature = "sign-extension", .wat = "(module (func i32.const 0 i32.extend8_s drop))" },
    .{
        .family = "saturating-float-to-int",
        .feature = "saturating-float-to-int",
        .wat = "(module (func f32.const 0 i32.trunc_sat_f32_s drop))",
    },
    .{
        .family = "bulk-memory",
        .feature = "bulk-memory",
        .wat = "(module (memory 1) (func i32.const 0 i32.const 0 i32.const 0 memory.copy))",
    },
    .{
        .family = "reference-types",
        .feature = "reference-types",
        .wat = "(module (table 1 funcref) (func i32.const 0 table.get 0 drop))",
    },
    .{
        .family = "typed-select",
        .feature = "reference-types",
        .wat = "(module (func i32.const 1 i32.const 2 i32.const 0 select (result i32) drop))",
    },
    .{ .family = "gc", .feature = "gc", .wat = "(module (func i32.const 0 ref.i31 drop))" },
    .{
        .family = "wide-arithmetic",
        .feature = "wide-arithmetic",
        .wat = "(module (func (result i64 i64) unreachable i64.add128))",
        .wabt_mode = .wide,
    },
    .{ .family = "simd", .feature = "simd", .wat = "(module (func v128.const i32x4 0 0 0 0 drop))" },
    .{
        .family = "relaxed-simd",
        .feature = "relaxed-simd",
        .wat = "(module (func unreachable i8x16.relaxed_swizzle drop))",
        .wabt_mode = .library_only,
    },
    .{
        .family = "threads",
        .feature = "threads",
        .wat = "(module (memory 1 1 shared) (func i32.const 0 i32.atomic.load drop))",
    },
};

fn runFeatureGateSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    try prepareWorkDir(gpa, io, work_dir);
    var matrix = Matrix{ .gpa = gpa };
    defer matrix.deinit();

    for (feature_gate_cases) |case| {
        const mismatch_count = matrix.mismatches.items.len;
        const case_dir = try std.fs.path.join(gpa, &.{ work_dir, case.family });
        defer gpa.free(case_dir);
        try cwd.createDirPath(io, case_dir);

        const wat = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ case_dir, case.family });
        defer gpa.free(wat);
        const tools_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm-tools.wasm", .{ case_dir, case.family });
        defer gpa.free(tools_wasm);
        try cwd.writeFile(io, .{ .sub_path = wat, .data = case.wat });

        const dis_arg = try std.fmt.allocPrint(gpa, "--features=all,-{s}", .{case.feature});
        defer gpa.free(dis_arg);

        const tools_wat_en = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=all", wat });
        defer tools_wat_en.deinit(gpa);
        const tools_wat_dis = try runCmd(gpa, io, &.{ wasm_tools, "validate", dis_arg, wat });
        defer tools_wat_dis.deinit(gpa);

        const twe_sum = try tools_wat_en.summary(gpa);
        defer gpa.free(twe_sum);
        _ = try matrix.check("wasm-tools-wat-enabled", case.family, tools_wat_en.accepted(), twe_sum);

        const twd_sum = try tools_wat_dis.summary(gpa);
        defer gpa.free(twd_sum);
        _ = try matrix.check("wasm-tools-wat-disabled", case.family, tools_wat_dis.rejected(), twd_sum);

        const tools_parse = try runCmd(gpa, io, &.{ wasm_tools, "parse", wat, "-o", tools_wasm });
        defer tools_parse.deinit(gpa);
        const tools_bin_en = if (tools_parse.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=all", tools_wasm })
        else
            null;
        defer if (tools_bin_en) |r| r.deinit(gpa);
        const tools_bin_dis = if (tools_parse.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", dis_arg, tools_wasm })
        else
            null;
        defer if (tools_bin_dis) |r| r.deinit(gpa);

        const tp_sum = try tools_parse.summary(gpa);
        defer gpa.free(tp_sum);
        const tbe_sum = if (tools_bin_en) |r| try r.summary(gpa) else try gpa.dupe(u8, tp_sum);
        defer gpa.free(tbe_sum);
        const tbd_sum = if (tools_bin_dis) |r| try r.summary(gpa) else try gpa.dupe(u8, tp_sum);
        defer gpa.free(tbd_sum);

        const ben_detail = try std.fmt.allocPrint(gpa, "parse {s}; validate {s}", .{ tp_sum, tbe_sum });
        defer gpa.free(ben_detail);
        _ = try matrix.check(
            "wasm-tools-binary-enabled",
            case.family,
            tools_parse.accepted() and (tools_bin_en != null and tools_bin_en.?.accepted()),
            ben_detail,
        );

        const bdis_detail = try std.fmt.allocPrint(gpa, "parse {s}; validate {s}", .{ tp_sum, tbd_sum });
        defer gpa.free(bdis_detail);
        _ = try matrix.check(
            "wasm-tools-binary-disabled",
            case.family,
            tools_parse.accepted() and (tools_bin_dis != null and tools_bin_dis.?.rejected()),
            bdis_detail,
        );

        if (case.wabt_mode == .library_only) {
            matrix.finishCase(matrix.mismatches.items.len == mismatch_count);
            continue;
        }

        const wabt_wasm = try std.fmt.allocPrint(gpa, "{s}/{s}.wabt.wasm", .{ case_dir, case.family });
        defer gpa.free(wabt_wasm);

        const wabt_parse = if (case.wabt_mode == .wide)
            try runCmd(gpa, io, &.{ wabt, "text", "parse", "--enable-wide-arithmetic", wat, "-o", wabt_wasm })
        else
            try runCmd(gpa, io, &.{ wabt, "text", "parse", wat, "-o", wabt_wasm });
        defer wabt_parse.deinit(gpa);

        const wabt_val = if (wabt_parse.accepted())
            (if (case.wabt_mode == .wide)
                try runCmd(gpa, io, &.{ wabt, "module", "validate", "--enable-wide-arithmetic", wabt_wasm })
            else
                try runCmd(gpa, io, &.{ wabt, "module", "validate", wabt_wasm }))
        else
            null;
        defer if (wabt_val) |r| r.deinit(gpa);

        const wp_sum = try wabt_parse.summary(gpa);
        defer gpa.free(wp_sum);
        const wv_sum = if (wabt_val) |r| try r.summary(gpa) else try gpa.dupe(u8, wp_sum);
        defer gpa.free(wv_sum);

        _ = try matrix.check("wabt-enabled-wat", case.family, wabt_parse.accepted(), wp_sum);
        _ = try matrix.check(
            "wabt-enabled-binary",
            case.family,
            wabt_parse.accepted() and (wabt_val != null and wabt_val.?.accepted()),
            wv_sum,
        );

        if (case.wabt_mode == .wide and wabt_parse.accepted()) {
            const wide_dis_wasm = try std.fmt.allocPrint(gpa, "{s}/wide-disabled.wasm", .{case_dir});
            defer gpa.free(wide_dis_wasm);
            const wabt_parse_dis = try runCmd(gpa, io, &.{ wabt, "text", "parse", wat, "-o", wide_dis_wasm });
            defer wabt_parse_dis.deinit(gpa);
            const wabt_bin_dis = try runCmd(gpa, io, &.{ wabt, "module", "validate", wabt_wasm });
            defer wabt_bin_dis.deinit(gpa);

            const wpd_sum = try wabt_parse_dis.summary(gpa);
            defer gpa.free(wpd_sum);
            const wbd_sum = try wabt_bin_dis.summary(gpa);
            defer gpa.free(wbd_sum);

            _ = try matrix.check("wabt-disabled-wat-alias", case.family, wabt_parse_dis.rejected(), wpd_sum);
            _ = try matrix.check("wabt-disabled-binary-alias", case.family, wabt_bin_dis.rejected(), wbd_sum);
        }

        matrix.finishCase(matrix.mismatches.items.len == mismatch_count);
    }

    const checks = matrix.totalChecks();
    var report_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer report_buf.deinit(gpa);

    const header = try std.fmt.allocPrint(
        gpa,
        "Function-body feature matrix: {d}/{d} families, {d}/{d} checks\n",
        .{ matrix.case_counter.passed, matrix.case_counter.total, checks.passed, checks.total },
    );
    defer gpa.free(header);
    try report_buf.appendSlice(gpa, header);

    const phase_keys = try Matrix.sortedKeys(gpa, &matrix.phases);
    defer gpa.free(phase_keys);
    for (phase_keys) |k| {
        const c = matrix.phases.get(k).?;
        const line = try std.fmt.allocPrint(gpa, "  {s}: {d}/{d}\n", .{ k, c.passed, c.total });
        defer gpa.free(line);
        try report_buf.appendSlice(gpa, line);
    }

    const failed = matrix.mismatches.items.len > 0;
    if (keep_work or failed) {
        const mat_line = try std.fmt.allocPrint(gpa, "Materialized matrix: {s}\n", .{work_dir});
        defer gpa.free(mat_line);
        try report_buf.appendSlice(gpa, mat_line);
    }

    try writeStdout(io, report_buf.items);
    matrix.printMismatches();
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── 7. declaration-feature-gate suite ────────────────────────────────────────

const DeclCase = struct {
    name: []const u8,
    features: []const u8,
    accepted: bool,
    wat: []const u8,
};

const DeclBinaryCase = struct {
    name: []const u8,
    accepted: bool,
    hex: []const u8,
};

const decl_cases = [_]DeclCase{
    .{ .name = "dead-v128-type", .features = "all,-simd", .accepted = false, .wat = "(module (type (func (param v128))))" },
    .{ .name = "imported-v128-param", .features = "all,-simd", .accepted = false, .wat = "(module (import \"m\" \"f\" (func (param v128))))" },
    .{ .name = "defined-v128-param", .features = "all,-simd", .accepted = false, .wat = "(module (func (param v128)))" },
    .{ .name = "v128-local", .features = "all,-simd", .accepted = false, .wat = "(module (func (local v128)))" },
    .{ .name = "v128-global", .features = "all,-simd", .accepted = false, .wat = "(module (global v128 (v128.const i32x4 0 0 0 0)))" },
    .{ .name = "imported-v128-global", .features = "all,-simd", .accepted = false, .wat = "(module (import \"m\" \"g\" (global v128)))" },
    .{ .name = "v128-block-result", .features = "all,-simd", .accepted = false, .wat = "(module (func (block (result v128) unreachable) drop))" },
    .{ .name = "externref-table", .features = "all,-reference-types", .accepted = false, .wat = "(module (table 1 externref))" },
    .{ .name = "imported-externref-table", .features = "all,-reference-types", .accepted = false, .wat = "(module (import \"m\" \"t\" (table 1 externref)))" },
    .{ .name = "defined-table64", .features = "all,-memory64", .accepted = false, .wat = "(module (table i64 1 funcref))" },
    .{ .name = "imported-table64", .features = "all,-memory64", .accepted = false, .wat = "(module (import \"m\" \"t\" (table i64 1 funcref)))" },
    .{ .name = "ordinary-table32-without-memory64", .features = "all,-memory64", .accepted = true, .wat = "(module (table 1 funcref))" },
    .{ .name = "mvp-funcref-table", .features = "all,-reference-types", .accepted = true, .wat = "(module (table 1 funcref))" },
    .{ .name = "mvp-function-index-element", .features = "all,-reference-types", .accepted = true, .wat = "(module (func) (table 1 funcref) (elem (i32.const 0) func 0))" },
    .{ .name = "expression-element", .features = "all,-reference-types", .accepted = false, .wat = "(module (func) (elem funcref (ref.func 0)))" },
    .{ .name = "tag", .features = "all,-exceptions", .accepted = false, .wat = "(module (tag))" },
    .{ .name = "imported-tag", .features = "all,-exceptions", .accepted = false, .wat = "(module (import \"m\" \"e\" (tag)))" },
    .{ .name = "tag-v128-param", .features = "all,-simd", .accepted = false, .wat = "(module (tag (param v128)))" },
    .{ .name = "tag-result", .features = "all", .accepted = true, .wat = "(module (type $t (func (result i32))) (tag (type $t)))" },
    .{ .name = "tag-v128-result", .features = "all,-simd", .accepted = false, .wat = "(module (type $t (func (result v128))) (tag (type $t)))" },
    .{ .name = "dead-struct", .features = "all,-gc", .accepted = false, .wat = "(module (type (struct)))" },
    .{ .name = "dead-array", .features = "all,-gc", .accepted = false, .wat = "(module (type (array i32)))" },
    .{ .name = "recursive-concrete-struct", .features = "all,-gc", .accepted = false, .wat = "(module (rec (type $s (struct (field (ref null $s))))))" },
    .{ .name = "recursive-func", .features = "all,-gc", .accepted = false, .wat = "(module (rec (type (func))))" },
    .{ .name = "function-subtype", .features = "all,-gc", .accepted = false, .wat = "(module (type $p (sub (func))) (type (sub $p (func))))" },
    .{ .name = "self-supertype", .features = "all", .accepted = false, .wat = "(module (type (sub 0 (func))))" },
    .{ .name = "forward-supertype", .features = "all", .accepted = false, .wat = "(module (type (sub 1 (func))) (type (sub (func))))" },
    .{ .name = "backward-supertype", .features = "all", .accepted = true, .wat = "(module (type (sub (func))) (type (sub 0 (func))))" },
    .{ .name = "recursive-group-backward-supertype", .features = "all", .accepted = true, .wat = "(module (rec (type (sub (func))) (type (sub 0 (func)))))" },
    .{ .name = "final-subtype-without-parent", .features = "all,-gc", .accepted = true, .wat = "(module (type (sub final (func))))" },
    .{ .name = "nullable-abstract-func", .features = "all,-function-references,-gc", .accepted = true, .wat = "(module (type (func (param (ref null func)))))" },
    .{ .name = "nonnull-abstract-func", .features = "all,-function-references", .accepted = false, .wat = "(module (type (func (param (ref func)))))" },
    .{ .name = "concrete-func-via-gc", .features = "all,-function-references", .accepted = true, .wat = "(module (type $f (func)) (type (func (param (ref null $f)))))" },
    .{ .name = "concrete-func-disabled", .features = "all,-function-references,-gc", .accepted = false, .wat = "(module (type $f (func)) (type (func (param (ref null $f)))))" },
    .{ .name = "exception-ref-without-reference-types", .features = "all,-reference-types", .accepted = false, .wat = "(module (type (func (param exnref))))" },
    .{ .name = "exception-ref-without-exceptions", .features = "all,-exceptions", .accepted = false, .wat = "(module (type (func (param exnref))))" },
    .{ .name = "multi-result-function", .features = "all,-multi-value", .accepted = false, .wat = "(module (type (func (result i32 i64))))" },
    .{ .name = "block-parameter", .features = "all,-multi-value", .accepted = false, .wat = "(module (type $t (func (param i32))) (func i32.const 0 (block (type $t) drop)))" },
    .{ .name = "indexed-empty-block", .features = "all,-multi-value", .accepted = false, .wat = "(module (type $t (func)) (func (block (type $t))))" },
    .{ .name = "indexed-one-result-block", .features = "all,-multi-value", .accepted = false, .wat = "(module (type $t (func (result i32))) (func (block (type $t) i32.const 0) drop))" },
    .{ .name = "inline-one-result-block", .features = "all,-multi-value", .accepted = true, .wat = "(module (func (block (result i32) i32.const 0) drop))" },
    .{ .name = "self-recursive-function-type", .features = "all,-gc", .accepted = false, .wat = "(module (type $f (func (param (ref null $f)))))" },
    .{ .name = "backward-concrete-function-type", .features = "all,-gc", .accepted = true, .wat = "(module (type $a (func)) (type $b (func (param (ref null $a)))))" },
    .{ .name = "mutually-recursive-function-types", .features = "all,-gc", .accepted = false, .wat = "(module (rec (type $a (func (param (ref null $b)))) (type $b (func (param (ref null $a))))))" },
    .{ .name = "table-ref-null-initializer", .features = "all,-function-references", .accepted = false, .wat = "(module (table 1 funcref (ref.null func)))" },
    .{ .name = "table64-ref-null-initializer", .features = "all", .accepted = true, .wat = "(module (table i64 1 funcref (ref.null func)))" },
    .{ .name = "table64-ref-null-initializer-without-memory64", .features = "all,-memory64", .accepted = false, .wat = "(module (table i64 1 funcref (ref.null func)))" },
    .{ .name = "table-ref-func-initializer", .features = "all,-function-references", .accepted = false, .wat = "(module (func $f) (elem declare func $f) (table 1 funcref (ref.func $f)))" },
    .{ .name = "table-concrete-initializer", .features = "all,-function-references", .accepted = false, .wat = "(module (type $f (func)) (table 1 (ref null $f) (ref.null $f)))" },
    .{ .name = "ordinary-table-without-function-references", .features = "all,-function-references", .accepted = true, .wat = "(module (table 1 funcref))" },
    .{ .name = "imported-table-without-function-references", .features = "all,-function-references", .accepted = true, .wat = "(module (import \"m\" \"t\" (table 1 funcref)))" },
    .{ .name = "passive-function-index-element", .features = "all,-bulk-memory", .accepted = false, .wat = "(module (func) (elem func 0))" },
    .{ .name = "declared-function-index-element", .features = "all,-bulk-memory", .accepted = false, .wat = "(module (func) (elem declare func 0))" },
    .{ .name = "active-function-index-element-without-bulk", .features = "all,-bulk-memory", .accepted = true, .wat = "(module (func) (table 1 funcref) (elem (i32.const 0) func 0))" },
    .{ .name = "active-imported-table-element-without-bulk", .features = "all,-bulk-memory", .accepted = true, .wat = "(module (import \"m\" \"t\" (table 1 funcref)) (func) (elem (table 0) (i32.const 0) func 0))" },
    .{ .name = "active-expression-element-without-bulk", .features = "all,-bulk-memory", .accepted = true, .wat = "(module (table 1 funcref) (elem (i32.const 0) funcref (ref.null func)))" },
    .{ .name = "passive-expression-element-without-bulk", .features = "all,-bulk-memory", .accepted = false, .wat = "(module (elem funcref (ref.null func)))" },
    .{ .name = "declared-expression-element-without-bulk", .features = "all,-bulk-memory", .accepted = false, .wat = "(module (elem declare funcref (ref.null func)))" },
    .{ .name = "passive-data-without-bulk", .features = "all,-bulk-memory", .accepted = false, .wat = "(module (data \"x\"))" },
    .{ .name = "empty-passive-data-without-bulk", .features = "all,-bulk-memory", .accepted = false, .wat = "(module (data \"\"))" },
    .{ .name = "active-data-without-bulk", .features = "all,-bulk-memory", .accepted = true, .wat = "(module (memory 1) (data (i32.const 0) \"x\"))" },
    .{ .name = "indexed-active-data-without-bulk", .features = "all,-bulk-memory", .accepted = true, .wat = "(module (memory 1) (memory 1) (data (memory 1) (i32.const 0) \"x\"))" },
    .{ .name = "imported-mutable-global", .features = "all,-mutable-global", .accepted = false, .wat = "(module (import \"m\" \"g\" (global (mut i32))))" },
    .{ .name = "exported-mutable-global", .features = "all,-mutable-global", .accepted = false, .wat = "(module (global (export \"g\") (mut i32) (i32.const 0)))" },
    .{ .name = "defined-mutable-global", .features = "all,-mutable-global", .accepted = true, .wat = "(module (global (mut i32) (i32.const 0)))" },
    .{ .name = "ref-null-constant", .features = "all,-reference-types", .accepted = false, .wat = "(module (global funcref (ref.null func)))" },
    .{ .name = "ref-func-constant", .features = "all,-reference-types", .accepted = false, .wat = "(module (func $f) (elem declare func $f) (global funcref (ref.func $f)))" },
    .{ .name = "gc-constant", .features = "all,-gc", .accepted = false, .wat = "(module (global i31ref (ref.i31 (i32.const 0))))" },
};

const decl_binary_cases = [_]DeclBinaryCase{
    .{
        .name = "initialized-table-reserved-zero",
        .accepted = true,
        .hex = "0061736d010000000409014000700001d0700b",
    },
    .{
        .name = "initialized-table-reserved-one",
        .accepted = false,
        .hex = "0061736d010000000409014001700001d0700b",
    },
    .{
        .name = "initialized-table-reserved-truncated",
        .accepted = false,
        .hex = "0061736d0100000004020140",
    },
    .{
        .name = "initialized-table64-limits",
        .accepted = true,
        .hex = "0061736d010000000409014000700401d0700b",
    },
};

fn runDeclarationFeatureGateSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    const cwd = std.Io.Dir.cwd();
    try prepareWorkDir(gpa, io, work_dir);

    var passed_checks: usize = 0;
    var total_checks: usize = 0;
    var passed_cases: usize = 0;
    var mismatches: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (mismatches.items) |m| gpa.free(m);
        mismatches.deinit(gpa);
    }

    for (decl_cases) |case| {
        var case_ok = true;
        const wat_path = try std.fmt.allocPrint(gpa, "{s}/{s}.wat", .{ work_dir, case.name });
        defer gpa.free(wat_path);
        const wasm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ work_dir, case.name });
        defer gpa.free(wasm_path);
        try cwd.writeFile(io, .{ .sub_path = wat_path, .data = case.wat });

        const feat_arg = try std.fmt.allocPrint(gpa, "--features={s}", .{case.features});
        defer gpa.free(feat_arg);

        const wat_res = try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_arg, wat_path });
        defer wat_res.deinit(gpa);
        total_checks += 1;
        if (wat_res.accepted() == case.accepted) {
            passed_checks += 1;
        } else {
            case_ok = false;
            const sum = try wat_res.summary(gpa);
            defer gpa.free(sum);
            try mismatches.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s} [wat]: expected accepted={any}, got {s}",
                .{ case.name, case.accepted, sum },
            ));
        }

        const parsed = try runCmd(gpa, io, &.{ wasm_tools, "parse", wat_path, "-o", wasm_path });
        defer parsed.deinit(gpa);
        const bin_res = if (parsed.accepted())
            try runCmd(gpa, io, &.{ wasm_tools, "validate", feat_arg, wasm_path })
        else
            null;
        defer if (bin_res) |r| r.deinit(gpa);

        total_checks += 1;
        if (parsed.accepted() and bin_res != null and bin_res.?.accepted() == case.accepted) {
            passed_checks += 1;
        } else {
            case_ok = false;
            const p_sum = try parsed.summary(gpa);
            defer gpa.free(p_sum);
            const b_sum = if (bin_res) |r| try r.summary(gpa) else try gpa.dupe(u8, p_sum);
            defer gpa.free(b_sum);
            try mismatches.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s} [binary]: parse {s}; validate {s}",
                .{ case.name, p_sum, b_sum },
            ));
        }

        if (case_ok) passed_cases += 1;
    }

    for (decl_binary_cases) |case| {
        const wasm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.wasm", .{ work_dir, case.name });
        defer gpa.free(wasm_path);
        const bytes = try decodeHex(gpa, case.hex);
        defer gpa.free(bytes);
        try cwd.writeFile(io, .{ .sub_path = wasm_path, .data = bytes });

        const res = try runCmd(gpa, io, &.{ wasm_tools, "validate", "--features=all", wasm_path });
        defer res.deinit(gpa);
        total_checks += 1;
        if (res.accepted() == case.accepted) {
            passed_checks += 1;
            passed_cases += 1;
        } else {
            const sum = try res.summary(gpa);
            defer gpa.free(sum);
            try mismatches.append(gpa, try std.fmt.allocPrint(
                gpa,
                "{s} [raw-binary]: expected accepted={any}, got {s}",
                .{ case.name, case.accepted, sum },
            ));
        }
    }

    const case_count = decl_cases.len + decl_binary_cases.len;
    const line = try std.fmt.allocPrint(
        gpa,
        "Declaration/constant wasm-tools oracle: {d}/{d} cases, {d}/{d} checks\n",
        .{ passed_cases, case_count, passed_checks, total_checks },
    );
    defer gpa.free(line);
    try writeStdout(io, line);

    if (mismatches.items.len > 0) {
        std.debug.print("Mismatches:\n", .{});
        for (mismatches.items) |m| {
            std.debug.print("  {s}\n", .{m});
        }
    }

    const failed = mismatches.items.len > 0;
    finishWorkDir(io, work_dir, keep_work, failed);
    return !failed;
}

// ── CLI entry point ──────────────────────────────────────────────────────────

fn runSingleSuite(
    gpa: std.mem.Allocator,
    io: std.Io,
    suite: Suite,
    wabt: []const u8,
    wasm_tools: []const u8,
    work_dir: []const u8,
    keep_work: bool,
) !bool {
    return switch (suite) {
        .all => unreachable,
        .cross_feature => runCrossFeatureSuite(gpa, io, wabt, wasm_tools, work_dir, keep_work),
        .gc => runGcSuite(gpa, io, wabt, wasm_tools, work_dir, keep_work),
        .typed_select => runTypedSelectSuite(gpa, io, wabt, wasm_tools, work_dir, keep_work),
        .wide_arithmetic => runWideArithmeticSuite(gpa, io, wabt, wasm_tools, work_dir, keep_work),
        .custom_page_sizes => runCustomPageSizesSuite(gpa, io, wabt, wasm_tools, work_dir, keep_work),
        .feature_gate => runFeatureGateSuite(gpa, io, wabt, wasm_tools, work_dir, keep_work),
        .declaration_feature_gate => runDeclarationFeatureGateSuite(gpa, io, wasm_tools, work_dir, keep_work),
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var suite: Suite = .all;
    var keep_work = false;
    var work_dir_override: ?[]const u8 = null;
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeStdout(init.io, usage_text);
            return;
        } else if (std.mem.eql(u8, arg, "--keep-work")) {
            keep_work = true;
        } else if (std.mem.eql(u8, arg, "--suite")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --suite requires a suite name\n", .{});
                std.process.exit(2);
            }
            suite = Suite.parse(args[i]) orelse {
                std.debug.print("error: unknown suite '{s}'\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--suite=")) {
            const val = arg["--suite=".len..];
            suite = Suite.parse(val) orelse {
                std.debug.print("error: unknown suite '{s}'\n", .{val});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --work-dir requires a directory path\n", .{});
                std.process.exit(2);
            }
            work_dir_override = args[i];
        } else if (std.mem.startsWith(u8, arg, "--work-dir=")) {
            work_dir_override = arg["--work-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unrecognized option '{s}'\n", .{arg});
            std.process.exit(2);
        } else {
            try positionals.append(arena, arg);
        }
    }

    const needs_wabt = suite != .declaration_feature_gate;
    if (positionals.items.len != 2 and !(suite == .declaration_feature_gate and positionals.items.len == 1)) {
        std.debug.print(
            "error: expected <path-to-wabt> and <path-to-wasm-tools>\n{s}",
            .{usage_text},
        );
        std.process.exit(2);
    }

    const cwd = std.Io.Dir.cwd();
    const wabt = if (positionals.items.len == 2)
        cwd.realPathFileAlloc(init.io, positionals.items[0], gpa) catch |err| {
            std.debug.print("error: cannot resolve wabt path '{s}': {any}\n", .{ positionals.items[0], err });
            std.process.exit(2);
        }
    else
        try gpa.dupe(u8, "");
    defer gpa.free(wabt);

    const wasm_tools_arg = if (positionals.items.len == 2) positionals.items[1] else positionals.items[0];
    const wasm_tools = cwd.realPathFileAlloc(init.io, wasm_tools_arg, gpa) catch |err| {
        std.debug.print("error: cannot resolve wasm-tools path '{s}': {any}\n", .{ wasm_tools_arg, err });
        std.process.exit(2);
    };
    defer gpa.free(wasm_tools);

    const wt_version = try runCmd(gpa, init.io, &.{ wasm_tools, "--version" });
    defer wt_version.deinit(gpa);
    const wt_trimmed = std.mem.trim(u8, wt_version.stdout, " \t\r\n");
    if (!wt_version.accepted() or !std.mem.startsWith(u8, wt_trimmed, expected_wasm_tools_version) or
        (wt_trimmed.len > expected_wasm_tools_version.len and !std.ascii.isWhitespace(wt_trimmed[expected_wasm_tools_version.len])))
    {
        const sum = try wt_version.summary(gpa);
        defer gpa.free(sum);
        std.debug.print(
            "error: expected {s}, got {s}\n",
            .{ expected_wasm_tools_version, if (wt_trimmed.len > 0) wt_trimmed else sum },
        );
        std.process.exit(2);
    }

    if (needs_wabt) {
        const wabt_version = try runCmd(gpa, init.io, &.{ wabt, "version" });
        defer wabt_version.deinit(gpa);
        if (!wabt_version.accepted()) {
            const sum = try wabt_version.summary(gpa);
            defer gpa.free(sum);
            std.debug.print("error: wabt CLI failed its version command: {s}\n", .{sum});
            std.process.exit(2);
        }
    }

    if (suite == .all) {
        const all_suites = [_]Suite{
            .cross_feature,
            .gc,
            .typed_select,
            .wide_arithmetic,
            .custom_page_sizes,
            .feature_gate,
            .declaration_feature_gate,
        };
        var all_ok = true;
        for (all_suites) |s| {
            const dir = if (work_dir_override) |base|
                try std.fs.path.join(gpa, &.{ base, s.subdirName() })
            else
                try gpa.dupe(u8, s.defaultWorkDir());
            defer gpa.free(dir);
            if (!try runSingleSuite(gpa, init.io, s, wabt, wasm_tools, dir, keep_work)) {
                all_ok = false;
            }
        }
        if (!all_ok) std.process.exit(1);
    } else {
        const dir = work_dir_override orelse suite.defaultWorkDir();
        const ok = try runSingleSuite(gpa, init.io, suite, wabt, wasm_tools, dir, keep_work);
        if (!ok) std.process.exit(1);
    }
}

test "checked-in corpora parse and validate cleanly" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const cross_bytes = try cwd.readFileAlloc(
        io,
        "src/fixtures/cross-feature-regression/corpus.json",
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(cross_bytes);
    var cross_parsed = try std.json.parseFromSlice(CrossCorpus, gpa, cross_bytes, .{});
    defer cross_parsed.deinit();
    try validateCrossCorpus(gpa, cross_parsed.value);

    const gc_bytes = try cwd.readFileAlloc(
        io,
        "src/fixtures/gc-regression/corpus.json",
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(gc_bytes);
    var gc_parsed = try std.json.parseFromSlice(GcCorpus, gpa, gc_bytes, .{});
    defer gc_parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), gc_parsed.value.version);
    try std.testing.expectEqual(@as(usize, 5), gc_parsed.value.valid.len);
    for (gc_parsed.value.invalid_binary) |b| {
        const body = try decodeHex(gpa, b.body_hex);
        defer gpa.free(body);
        const mod = try moduleWithSimpleBody(gpa, body);
        gpa.free(mod);
    }

    const ts_bytes = try cwd.readFileAlloc(
        io,
        "src/fixtures/typed-select-regression/corpus.json",
        gpa,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer gpa.free(ts_bytes);
    var ts_parsed = try std.json.parseFromSlice(TsCorpus, gpa, ts_bytes, .{});
    defer ts_parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), ts_parsed.value.version);
    for (ts_parsed.value.valid_binary) |b| {
        const body = try decodeHex(gpa, b.body_hex);
        defer gpa.free(body);
        const mod = try tsModuleWithBody(gpa, b, body);
        gpa.free(mod);
    }
    for (ts_parsed.value.invalid_binary) |b| {
        const body = try decodeHex(gpa, b.body_hex);
        defer gpa.free(body);
        const mod = try tsModuleWithBody(gpa, b, body);
        gpa.free(mod);
    }
}

test "custom-page-sizes binary generators produce valid headers" {
    const gpa = std.testing.allocator;

    const lim = try buildLimitsBytes(gpa, 0x08, 0, null, &[_]u8{16});
    defer gpa.free(lim);
    const mod_bytes = try buildMemoriesModule(gpa, &.{lim});
    defer gpa.free(mod_bytes);
    try std.testing.expect(std.mem.startsWith(u8, mod_bytes, "\x00asm\x01\x00\x00\x00"));
}
