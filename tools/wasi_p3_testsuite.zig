//! WASI Preview 3 (wasm32-wasip3) component decode + round-trip gate for wabt.
//!
//! Feeds wabt the real-world `wasm32-wasip3` components from the upstream WASI
//! testsuite and exercises wabt's component loader + writer on each one:
//!   1. `wabt component objdump <fixture>.wasm`
//!   2. `wabt component objdump <fixture>.wasm -o <reemit.wasm>` and verifies
//!      that `<reemit.wasm>` is byte-identical to `<fixture>.wasm>`.

const std = @import("std");

const usage_text =
    \\Usage: wasi_p3_testsuite [options]
    \\
    \\WASI Preview 3 (wasm32-wasip3) component decode + round-trip gate for wabt.
    \\
    \\Options:
    \\  --wabt <path>     Path to the wabt CLI binary (default: wabt)
    \\  --suite <dir>     Path to the vendored wasm32-wasip3 testsuite directory
    \\                    (default: tests/wasi-testsuite/tests/rust/testsuite/wasm32-wasip3)
    \\  --skip <path>     Skip-list JSON (default: tests/wasi-p3-testsuite-skip.json)
    \\  --require-suite   Fail (not skip) when the testsuite is not vendored
    \\  -h, --help        Print this help and exit
    \\
;

const Failure = struct {
    name: []const u8,
    err: []const u8,
};

const CmdResult = struct {
    code: i32,
    combined: []const u8,
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

fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
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
        .stdout_limit = std.Io.Limit.limited(4 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(4 * 1024 * 1024),
    }) catch |err| {
        return .{
            .code = 127,
            .combined = try std.fmt.allocPrint(alloc, "failed to spawn process: {s}", .{@errorName(err)}),
        };
    };

    const combined = try std.fmt.allocPrint(alloc, "{s}{s}", .{ result.stdout, result.stderr });
    const code: i32 = switch (result.term) {
        .exited => |c| c,
        .signal => |s| -@as(i32, @intCast(@backingInt(s))),
        else => -1,
    };
    return .{
        .code = code,
        .combined = combined,
    };
}

fn resolveSuiteName(alloc: std.mem.Allocator, io: std.Io, suite_dir: []const u8) ![]const u8 {
    const fallback = std.fs.path.basename(suite_dir);
    const manifest_path = try std.fs.path.join(alloc, &.{ suite_dir, "manifest.json" });
    if (!isFile(io, manifest_path)) return fallback;

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        alloc,
        std.Io.Limit.limited(1024 * 1024),
    ) catch return fallback;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return fallback;
    if (parsed.value == .object) {
        if (parsed.value.object.get("name")) |name_val| {
            if (name_val == .string) {
                return name_val.string;
            }
        }
    }
    return fallback;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    var wabt_path: []const u8 = "wabt";
    var suite_dir: []const u8 = "tests/wasi-testsuite/tests/rust/testsuite/wasm32-wasip3";
    var skip_path: []const u8 = "tests/wasi-p3-testsuite-skip.json";
    var require_suite = false;

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
            wabt_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--wabt=")) {
            wabt_path = arg["--wabt=".len..];
        } else if (std.mem.eql(u8, arg, "--suite")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --suite requires an argument\n");
                std.process.exit(2);
            }
            suite_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--suite=")) {
            suite_dir = arg["--suite=".len..];
        } else if (std.mem.eql(u8, arg, "--skip")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --skip requires an argument\n");
                std.process.exit(2);
            }
            skip_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--skip=")) {
            skip_path = arg["--skip=".len..];
        } else if (std.mem.eql(u8, arg, "--require-suite")) {
            require_suite = true;
        } else {
            try printStderr(io, alloc, "error: unknown argument '{s}'\n", .{arg});
            std.process.exit(2);
        }
    }

    const cwd = std.Io.Dir.cwd();
    const name = try resolveSuiteName(alloc, io, suite_dir);

    var skip: std.StringHashMapUnmanaged([]const u8) = .{};
    if (isFile(io, skip_path)) {
        const skip_bytes = try cwd.readFileAlloc(io, skip_path, alloc, std.Io.Limit.limited(16 * 1024 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, skip_bytes, .{});
        if (parsed.value == .object) {
            if (parsed.value.object.get(name)) |suite_entry| {
                if (suite_entry == .object) {
                    var it = suite_entry.object.iterator();
                    while (it.next()) |entry| {
                        const key = entry.key_ptr.*;
                        if (std.mem.startsWith(u8, key, "_")) continue;
                        if (entry.value_ptr.* == .string) {
                            try skip.put(alloc, key, entry.value_ptr.string);
                        }
                    }
                }
            }
        }
    }

    var fixtures: std.ArrayListUnmanaged([]const u8) = .empty;
    if (cwd.openDir(io, suite_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wasm")) {
                try fixtures.append(alloc, try alloc.dupe(u8, entry.name));
            }
        }
    } else |_| {}

    std.mem.sort([]const u8, fixtures.items, {}, lessThanStr);
    if (fixtures.items.len == 0) {
        const msg = try std.fmt.allocPrint(
            alloc,
            "wasm32-wasip3 testsuite not found under '{s}'; init the `tests/wasi-testsuite` submodule to enable the P3 component decode gate (#267 Phase 4)",
            .{suite_dir},
        );
        if (require_suite) {
            try printStdout(io, alloc, "::error::{s}\n", .{msg});
            std.process.exit(1);
        }
        try printStdout(io, alloc, "::notice::{s}; skipping.\n", .{msg});
        return;
    }

    const tmp_base = blk: {
        if (init.environ_map.get("TMPDIR")) |t| {
            if (t.len > 0 and !std.mem.startsWith(u8, t, "/tmp")) break :blk t;
        }
        break :blk ".zig-cache/tmp";
    };

    try printStdout(
        io,
        alloc,
        "wasi-p3-testsuite: suite={s} wabt={s} ({d} fixtures)\n",
        .{ name, wabt_path, fixtures.items.len },
    );

    var passed_count: usize = 0;
    var skipped_count: usize = 0;
    var failed: std.ArrayListUnmanaged(Failure) = .empty;

    for (fixtures.items) |wasm_file| {
        const fname = wasm_file[0 .. wasm_file.len - ".wasm".len];
        if (skip.get(fname)) |reason| {
            skipped_count += 1;
            try printStdout(io, alloc, "  SKIP {s: <28} - {s}\n", .{ fname, reason });
            continue;
        }

        const wasm_path = try std.fs.path.join(alloc, &.{ suite_dir, wasm_file });

        // 1. Decode: wabt's component loader must parse the component.
        const decode_res = try runCmd(
            alloc,
            io,
            init.environ_map,
            &.{ wabt_path, "component", "objdump", wasm_path },
        );
        if (decode_res.code != 0) {
            const trimmed = std.mem.trim(u8, decode_res.combined, " \t\r\n");
            const err_msg = try std.fmt.allocPrint(
                alloc,
                "`wabt component objdump` exited {d}\n{s}",
                .{ decode_res.code, trimmed },
            );
            try failed.append(alloc, .{ .name = fname, .err = err_msg });
            try printStdout(io, alloc, "  FAIL {s}\n", .{fname});
            continue;
        }

        // 2. Round-trip: re-emit via `objdump -o` (loader -> writer) and
        //    require the output to be byte-identical to the input.
        const tmp_dir = try std.fmt.allocPrint(alloc, "{s}/wasip3-rt-{s}", .{ tmp_base, fname });
        cwd.deleteTree(io, tmp_dir) catch {};
        try cwd.createDirPath(io, tmp_dir);
        defer cwd.deleteTree(io, tmp_dir) catch {};

        const out_path = try std.fs.path.join(alloc, &.{ tmp_dir, "reemit.wasm" });
        const rt_res = try runCmd(
            alloc,
            io,
            init.environ_map,
            &.{ wabt_path, "component", "objdump", wasm_path, "-o", out_path },
        );

        var rt_err: ?[]const u8 = null;
        if (rt_res.code != 0) {
            const trimmed = std.mem.trim(u8, rt_res.combined, " \t\r\n");
            rt_err = try std.fmt.allocPrint(
                alloc,
                "`wabt component objdump -o` exited {d}\n{s}",
                .{ rt_res.code, trimmed },
            );
        } else {
            const original = try cwd.readFileAlloc(io, wasm_path, alloc, std.Io.Limit.limited(64 * 1024 * 1024));
            const reemit = try cwd.readFileAlloc(io, out_path, alloc, std.Io.Limit.limited(64 * 1024 * 1024));
            if (!std.mem.eql(u8, reemit, original)) {
                rt_err = try std.fmt.allocPrint(
                    alloc,
                    "round-trip not byte-identical (input {d} bytes, re-emit {d} bytes)",
                    .{ original.len, reemit.len },
                );
            }
        }

        if (rt_err) |err_msg| {
            try failed.append(alloc, .{ .name = fname, .err = err_msg });
            try printStdout(io, alloc, "  FAIL {s}\n", .{fname});
        } else {
            passed_count += 1;
            try printStdout(io, alloc, "  PASS {s}\n", .{fname});
        }
    }

    try printStdout(
        io,
        alloc,
        "\nwasi-p3-testsuite: {d} passed, {d} skipped, {d} failed\n",
        .{ passed_count, skipped_count, failed.items.len },
    );
    for (failed.items) |f| {
        try printStdout(io, alloc, "\n--- {s} ---\n{s}\n", .{ f.name, f.err });
    }
    if (failed.items.len > 0) {
        std.process.exit(1);
    }
}
