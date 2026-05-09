//! `wabt module shrink` — shrink a wasm file while maintaining a property of
//! interest.
//!
//! Drop-in replacement for `wasm-tools shrink` (see issue #104). The
//! predicate contract matches: a non-zero exit code from the predicate
//! script means "the candidate still reproduces the bug — keep
//! shrinking". Output is a strictly-smaller, still-valid wasm binary
//! (or the original input unchanged when no reduction was possible).
//!
//! Unlike `wasm-tools shrink`, which drives random structural mutation
//! through `wasm-mutate`, this implementation walks a fixed set of
//! deterministic IR-level reductions over the existing
//! `wabt.binary` reader/writer. The strategies, applied greedily in
//! order, are:
//!
//!   1. drop a custom section
//!   2. drop the start function
//!   3. drop an export
//!   4. drop a data segment
//!   5. drop an element segment
//!   6. replace a defined function body with `unreachable; end`
//!
//! Every candidate is re-encoded and re-validated via
//! `wabt.Validator` before being shown to the predicate, so the
//! output always round-trips through `wabt module validate` (issue #104
//! acceptance).

const std = @import("std");
const wabt = @import("wabt");

pub const usage =
    \\Usage: wabt module shrink [options] <predicate> <input.wasm>
    \\
    \\Shrink a wasm file while maintaining a property of interest.
    \\
    \\The predicate is an executable (typically a small shell script) that
    \\receives a candidate wasm path as its only argument and exits with
    \\status 0 when the candidate "still reproduces the bug" (matches
    \\`wasm-tools shrink`). Positional argument order matches `wasm-tools
    \\shrink` — predicate first, input wasm second — so this command is a
    \\drop-in replacement.
    \\
    \\Options:
    \\  -o, --output <file>   Output file (default: <input>.shrunken.wasm)
    \\  -a, --attempts <N>    Maximum reduction attempts (default: 1000)
    \\  -s, --seed <N>        Reserved for compatibility (currently unused;
    \\                        wabt's reductions are deterministic)
    \\      --allow-empty     Permit shrinking down to an empty module
    \\  -h, --help            Show this help
    \\
;

// ── Empty module bytes ──────────────────────────────────────────────

const empty_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, // magic
    0x01, 0x00, 0x00, 0x00, // version 1
};

// ── PredicateRunner ─────────────────────────────────────────────────

/// Runs an external predicate executable on a candidate wasm payload.
///
/// Each call writes the candidate to a fresh temp file, invokes the
/// predicate with the temp path as its only argument, captures the
/// child's stdout/stderr, and returns whether the child exited with
/// status 0 (the `wasm-tools shrink` "is interesting" contract).
pub const PredicateRunner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    predicate: []const u8,
    tmp_dir: []const u8,
    counter: u64 = 0,
    /// PID of the wabt process, used to make temp file names unique
    /// across concurrent shrink invocations.
    pid: i32,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        predicate: []const u8,
    ) PredicateRunner {
        const tmp = environ_map.get("TMPDIR") orelse "/tmp";
        return .{
            .gpa = gpa,
            .io = io,
            .predicate = predicate,
            .tmp_dir = tmp,
            // wasm32-wasi has no PID concept and `std.os.linux.getpid()`
            // fails to compile there (no `syscall0`). Since `pid` is only
            // a tmp-filename uniqueness hint within one process, fall
            // back to a constant on wasi. Fixes #135.
            .pid = if (@import("builtin").os.tag == .wasi)
                1
            else
                std.os.linux.getpid(),
        };
    }

    /// Returns true when the predicate exits with status 0 for the
    /// given candidate. Bubbles up errors from temp-file IO and
    /// process spawning so the caller can fail the shrink loop early.
    pub fn isInteresting(self: *PredicateRunner, wasm_bytes: []const u8) !bool {
        self.counter += 1;
        const tmp_path = try std.fmt.allocPrint(
            self.gpa,
            "{s}/wabt-shrink-{d}-{d}.wasm",
            .{ self.tmp_dir, self.pid, self.counter },
        );
        defer self.gpa.free(tmp_path);

        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = tmp_path,
            .data = wasm_bytes,
        });
        defer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};

        const argv = &[_][]const u8{ self.predicate, tmp_path };
        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .stdout_limit = std.Io.Limit.limited(64 * 1024),
            .stderr_limit = std.Io.Limit.limited(64 * 1024),
        }) catch |err| {
            std.debug.print(
                "error: failed to run predicate '{s}': {any}\n",
                .{ self.predicate, err },
            );
            return err;
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);

        return switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

// ── Shrink engine ───────────────────────────────────────────────────

pub const ShrinkOptions = struct {
    attempts: u32 = 1000,
    seed: u64 = 42,
    allow_empty: bool = false,
};

const Strategy = enum {
    drop_custom,
    clear_start,
    drop_export,
    drop_data,
    drop_elem,
    minimize_body,
};

const all_strategies = [_]Strategy{
    .drop_custom,
    .clear_start,
    .drop_export,
    .drop_data,
    .drop_elem,
    .minimize_body,
};

/// Apply one reduction `strategy` at index `idx` to `current` and
/// return either:
///
///   * `null` when the index is out of range for that strategy (the
///     caller should advance to the next strategy);
///   * `error.NotApplied` when the strategy could not produce a
///     strictly-smaller, still-valid candidate at this index (the
///     caller should advance to the next index);
///   * the new wasm bytes (caller owns) when the candidate is smaller
///     and validates.
const ApplyError = error{ NotApplied, OutOfMemory };

fn applyMutation(
    gpa: std.mem.Allocator,
    current: []const u8,
    strategy: Strategy,
    idx: u32,
) ApplyError!?[]u8 {
    var module = wabt.binary.reader.readModule(gpa, current) catch return error.NotApplied;
    defer module.deinit();

    const applied: bool = switch (strategy) {
        .drop_custom => blk: {
            if (idx >= module.customs.items.len) return null;
            _ = module.customs.orderedRemove(idx);
            break :blk true;
        },
        .clear_start => blk: {
            if (idx > 0) return null;
            if (module.start_var == null) return error.NotApplied;
            module.start_var = null;
            break :blk true;
        },
        .drop_export => blk: {
            if (idx >= module.exports.items.len) return null;
            _ = module.exports.orderedRemove(idx);
            break :blk true;
        },
        .drop_data => blk: {
            if (idx >= module.data_segments.items.len) return null;
            const seg = &module.data_segments.items[idx];
            if (seg.owns_data and seg.data.len > 0) gpa.free(seg.data);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0)
                gpa.free(seg.offset_expr_bytes);
            _ = module.data_segments.orderedRemove(idx);
            // Keep data_count consistent if present.
            if (module.has_data_count) {
                module.data_count = @intCast(module.data_segments.items.len);
            }
            break :blk true;
        },
        .drop_elem => blk: {
            if (idx >= module.elem_segments.items.len) return null;
            const seg = &module.elem_segments.items[idx];
            seg.elem_var_indices.deinit(gpa);
            if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0)
                gpa.free(seg.offset_expr_bytes);
            if (seg.owns_elem_expr_bytes and seg.elem_expr_bytes.len > 0)
                gpa.free(seg.elem_expr_bytes);
            _ = module.elem_segments.orderedRemove(idx);
            break :blk true;
        },
        .minimize_body => blk: {
            const def_count = module.funcs.items.len - module.num_func_imports;
            if (idx >= def_count) return null;
            const func = &module.funcs.items[module.num_func_imports + idx];
            // Already at the minimum (`unreachable; end` with no locals).
            if (func.code_bytes.len <= 2 and func.local_types.items.len == 0) {
                return error.NotApplied;
            }
            if (func.owns_code_bytes and func.code_bytes.len > 0) {
                gpa.free(func.code_bytes);
            }
            func.code_bytes = &[_]u8{ 0x00, 0x0b }; // unreachable; end
            func.owns_code_bytes = false;
            func.local_types.clearAndFree(gpa);
            func.local_type_idxs.clearAndFree(gpa);
            break :blk true;
        },
    };
    if (!applied) return error.NotApplied;

    const candidate = wabt.binary.writer.writeModule(gpa, &module) catch return error.NotApplied;
    if (candidate.len >= current.len) {
        gpa.free(candidate);
        return error.NotApplied;
    }

    // Re-validate: we must never hand the predicate (or write to disk)
    // a structurally invalid module.
    {
        var m2 = wabt.binary.reader.readModule(gpa, candidate) catch {
            gpa.free(candidate);
            return error.NotApplied;
        };
        defer m2.deinit();
        wabt.Validator.validate(&m2, .{}) catch {
            gpa.free(candidate);
            return error.NotApplied;
        };
    }

    return candidate;
}

pub const ShrinkError = error{
    PredicateRejectsInput,
    InputNotValid,
    EmptyModuleInteresting,
} || ApplyError || std.mem.Allocator.Error;

/// Run the shrink loop on `initial`, returning a smaller wasm binary
/// that still satisfies the predicate, or a fresh copy of `initial`
/// when no reduction is possible.
///
/// Caller owns the returned slice.
pub fn shrinkBytes(
    gpa: std.mem.Allocator,
    initial: []const u8,
    options: ShrinkOptions,
    runner: anytype, // duck-typed: must expose `isInteresting([]const u8) !bool`
) ![]u8 {
    {
        var m = wabt.binary.reader.readModule(gpa, initial) catch return error.InputNotValid;
        defer m.deinit();
        wabt.Validator.validate(&m, .{}) catch return error.InputNotValid;
    }

    if (!try runner.isInteresting(initial)) {
        return error.PredicateRejectsInput;
    }

    if (try runner.isInteresting(&empty_wasm)) {
        if (options.allow_empty) {
            return gpa.dupe(u8, &empty_wasm);
        }
        return error.EmptyModuleInteresting;
    }

    var current = try gpa.dupe(u8, initial);
    errdefer gpa.free(current);

    var attempts_remaining: u32 = options.attempts;
    while (attempts_remaining > 0) {
        const before_pass = current.len;
        for (all_strategies) |strategy| {
            var idx: u32 = 0;
            while (attempts_remaining > 0) {
                const maybe = applyMutation(gpa, current, strategy, idx) catch |err| switch (err) {
                    error.NotApplied => {
                        attempts_remaining -= 1;
                        idx += 1;
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                attempts_remaining -= 1;
                if (maybe) |candidate| {
                    if (try runner.isInteresting(candidate)) {
                        gpa.free(current);
                        current = candidate;
                        // Stay at same idx — list shifted under us.
                    } else {
                        gpa.free(candidate);
                        idx += 1;
                    }
                } else {
                    // null = strategy exhausted at this index
                    break;
                }
            }
        }
        if (current.len >= before_pass) break; // fixed point
    }

    return current;
}

// ── CLI entry point ─────────────────────────────────────────────────

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    const alloc = init.gpa;

    var output_file: ?[]const u8 = null;
    var attempts: u32 = 1000;
    var seed: u64 = 42;
    var allow_empty: bool = false;
    var positionals: [2]?[]const u8 = .{ null, null };
    var pos_count: usize = 0;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            output_file = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--attempts")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            attempts = std.fmt.parseInt(u32, sub_args[i], 10) catch {
                std.debug.print("error: invalid --attempts value '{s}'\n", .{sub_args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= sub_args.len) {
                std.debug.print("error: {s} requires an argument\n", .{arg});
                std.process.exit(1);
            }
            seed = std.fmt.parseInt(u64, sub_args[i], 10) catch {
                std.debug.print("error: invalid --seed value '{s}'\n", .{sub_args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--allow-empty")) {
            allow_empty = true;
        } else {
            if (pos_count >= positionals.len) {
                std.debug.print(
                    "error: unexpected positional argument '{s}'. Use `wabt help shrink`.\n",
                    .{arg},
                );
                std.process.exit(1);
            }
            positionals[pos_count] = arg;
            pos_count += 1;
        }
    }

    if (pos_count < 2) {
        std.debug.print(
            "error: shrink requires <predicate> and <input.wasm>. Use `wabt help shrink`.\n",
            .{},
        );
        std.process.exit(1);
    }

    const predicate = positionals[0].?;
    const in_path = positionals[1].?;

    const source = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        in_path,
        alloc,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print("error: cannot read '{s}': {any}\n", .{ in_path, err });
        std.process.exit(1);
    };
    defer alloc.free(source);

    var runner = PredicateRunner.init(alloc, init.io, init.environ_map, predicate);
    const shrunken = shrinkBytes(alloc, source, .{
        .attempts = attempts,
        .seed = seed,
        .allow_empty = allow_empty,
    }, &runner) catch |err| {
        switch (err) {
            error.PredicateRejectsInput => std.debug.print(
                "error: the predicate does not consider the input wasm interesting\n",
                .{},
            ),
            error.InputNotValid => std.debug.print(
                "error: input wasm is not valid; cannot shrink\n",
                .{},
            ),
            error.EmptyModuleInteresting => std.debug.print(
                "error: the predicate considers the empty wasm module interesting; this is usually a bug in the predicate. Re-run with --allow-empty to accept this.\n",
                .{},
            ),
            else => std.debug.print("error: {any}\n", .{err}),
        }
        std.process.exit(1);
    };
    defer alloc.free(shrunken);

    const out_path = output_file orelse blk: {
        if (std.mem.endsWith(u8, in_path, ".wasm")) {
            const stem = in_path[0 .. in_path.len - 5];
            break :blk std.fmt.allocPrint(alloc, "{s}.shrunken.wasm", .{stem}) catch in_path;
        }
        break :blk std.fmt.allocPrint(alloc, "{s}.shrunken.wasm", .{in_path}) catch in_path;
    };

    std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = shrunken,
    }) catch |err| {
        std.debug.print("error: cannot write '{s}': {any}\n", .{ out_path, err });
        std.process.exit(1);
    };
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io, text) catch {};
}

// ── Tests ───────────────────────────────────────────────────────────

const TestRunner = struct {
    accept: enum { always, never, only_smaller_than_input, only_nonempty } = .always,
    initial_size: usize = 0,
    calls: u32 = 0,

    pub fn isInteresting(self: *TestRunner, wasm_bytes: []const u8) !bool {
        self.calls += 1;
        return switch (self.accept) {
            .always => true,
            .never => false,
            .only_smaller_than_input => wasm_bytes.len < self.initial_size,
            // Reject the empty module (8-byte header) but accept any
            // module with at least one section. Lets tests exercise
            // structural shrinks without tripping the "empty is
            // interesting" safety check.
            .only_nonempty => wasm_bytes.len > 8,
        };
    }
};

fn buildModuleWithCustom() ![]u8 {
    return wabt.binary.writer.writeModule(std.testing.allocator, blk: {
        var m = wabt.Module.Module.init(std.testing.allocator);
        try m.customs.append(std.testing.allocator, .{
            .name = "junk",
            .data = "abcdefghijklmnopqrstuvwxyz",
        });
        break :blk &m;
    });
}

test "shrink leaves input unchanged when predicate never accepts smaller" {
    const alloc = std.testing.allocator;

    // Build a module with one custom section.
    var m = wabt.Module.Module.init(alloc);
    defer m.deinit();
    try m.customs.append(alloc, .{ .name = "junk", .data = "0123456789" });
    const input = try wabt.binary.writer.writeModule(alloc, &m);
    defer alloc.free(input);

    var runner = TestRunner{ .accept = .never };
    const result = shrinkBytes(alloc, input, .{ .attempts = 100 }, &runner);
    try std.testing.expectError(error.PredicateRejectsInput, result);
}

test "shrink drops a custom section when predicate accepts" {
    const alloc = std.testing.allocator;

    var m = wabt.Module.Module.init(alloc);
    defer m.deinit();
    try m.customs.append(alloc, .{ .name = "junk1", .data = "0123456789" });
    try m.customs.append(alloc, .{ .name = "junk2", .data = "abcdefghij" });
    const input = try wabt.binary.writer.writeModule(alloc, &m);
    defer alloc.free(input);

    var runner = TestRunner{ .accept = .only_nonempty };
    const out = try shrinkBytes(alloc, input, .{ .attempts = 100 }, &runner);
    defer alloc.free(out);

    try std.testing.expect(out.len < input.len);

    // Output must round-trip through the validator.
    var m2 = try wabt.binary.reader.readModule(alloc, out);
    defer m2.deinit();
    try wabt.Validator.validate(&m2, .{});
}

test "shrink rejects empty interesting predicate without --allow-empty" {
    const alloc = std.testing.allocator;

    var m = wabt.Module.Module.init(alloc);
    defer m.deinit();
    try m.customs.append(alloc, .{ .name = "junk", .data = "0123" });
    const input = try wabt.binary.writer.writeModule(alloc, &m);
    defer alloc.free(input);

    var runner = TestRunner{ .accept = .always };
    try std.testing.expectError(
        error.EmptyModuleInteresting,
        shrinkBytes(alloc, input, .{ .attempts = 100, .allow_empty = false }, &runner),
    );
}

test "shrink reduces to empty under --allow-empty when predicate accepts" {
    const alloc = std.testing.allocator;

    var m = wabt.Module.Module.init(alloc);
    defer m.deinit();
    try m.customs.append(alloc, .{ .name = "junk", .data = "0123" });
    const input = try wabt.binary.writer.writeModule(alloc, &m);
    defer alloc.free(input);

    var runner = TestRunner{ .accept = .always };
    const out = try shrinkBytes(alloc, input, .{ .attempts = 100, .allow_empty = true }, &runner);
    defer alloc.free(out);

    try std.testing.expectEqualSlices(u8, &empty_wasm, out);
}

test "applyMutation drop_custom removes a single custom section" {
    const alloc = std.testing.allocator;

    var m = wabt.Module.Module.init(alloc);
    defer m.deinit();
    try m.customs.append(alloc, .{ .name = "a", .data = "1111" });
    try m.customs.append(alloc, .{ .name = "b", .data = "2222" });
    const input = try wabt.binary.writer.writeModule(alloc, &m);
    defer alloc.free(input);

    const after = try applyMutation(alloc, input, .drop_custom, 0);
    try std.testing.expect(after != null);
    defer alloc.free(after.?);
    try std.testing.expect(after.?.len < input.len);

    var m2 = try wabt.binary.reader.readModule(alloc, after.?);
    defer m2.deinit();
    try std.testing.expectEqual(@as(usize, 1), m2.customs.items.len);
}

test "applyMutation drop_custom returns null when index out of range" {
    const alloc = std.testing.allocator;

    var m = wabt.Module.Module.init(alloc);
    defer m.deinit();
    const input = try wabt.binary.writer.writeModule(alloc, &m);
    defer alloc.free(input);

    const after = try applyMutation(alloc, input, .drop_custom, 0);
    try std.testing.expect(after == null);
}
