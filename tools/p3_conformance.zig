//! WASI Preview 3 (component-model-async) conformance gate for wabt.
//!
//! wabt is a toolkit: it produces components, it does not run them. This gate
//! validates that the components wabt produces from P3 guest fixtures are
//! accepted by upstream Wasmtime. For each `tests/p3/<name>.wat` fixture it runs:
//!
//!   1. `wabt text parse <name>.wat -o core.wasm`
//!   2. `wabt component embed -w hello world.wit core.wasm -o embed.wasm`
//!   3. `wabt component new embed.wasm -o component.wasm`
//!   4. `wasmtime compile <p3 flags> component.wasm -o component.cwasm`

const std = @import("std");

const world_name = "hello";

const wasmtime_flags = [_][]const u8{
    "-W", "component-model-async",
    "-W", "component-model-async-stackful",
    "-W", "component-model-more-async-builtins",
    "-W", "component-model-error-context",
};

const usage_text =
    \\Usage: p3_conformance [options]
    \\
    \\wabt WASI Preview 3 conformance gate.
    \\
    \\Options:
    \\  --wabt <path>         Path to the wabt CLI binary (default: wabt)
    \\  --fixtures <dir>      Directory of <name>.wat fixtures (default: tests/p3)
    \\  --skip <path>         Skip-list JSON (default: tests/p3-conformance-skip.json)
    \\  --require-wasmtime    Fail (not skip) when no usable Wasmtime is found
    \\  -h, --help            Print this help and exit
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
        .stdout_limit = std.Io.Limit.limited(1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
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

fn resolveWasmtime(
    alloc: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) ?[]const u8 {
    const cand = blk: {
        if (env_map.get("WASMTIME")) |val| {
            if (val.len > 0) break :blk val;
        }
        break :blk "wasmtime";
    };
    const result = std.process.run(alloc, io, .{
        .argv = &.{ cand, "--version" },
        .environ_map = env_map,
        .stdout_limit = std.Io.Limit.limited(1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
    }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    return switch (result.term) {
        .exited => |code| if (code == 0) cand else null,
        else => null,
    };
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn formatCmdForError(alloc: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (argv, 0..) |arg, i| {
        if (i > 0) try buf.append(alloc, ' ');
        if (i == 0) {
            try buf.appendSlice(alloc, std.fs.path.basename(arg));
        } else {
            try buf.appendSlice(alloc, arg);
        }
    }
    return buf.toOwnedSlice(alloc);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);

    var wabt_path: []const u8 = "wabt";
    var fixtures_dir: []const u8 = "tests/p3";
    var skip_path: []const u8 = "tests/p3-conformance-skip.json";
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
            wabt_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--wabt=")) {
            wabt_path = arg["--wabt=".len..];
        } else if (std.mem.eql(u8, arg, "--fixtures")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --fixtures requires an argument\n");
                std.process.exit(2);
            }
            fixtures_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--fixtures=")) {
            fixtures_dir = arg["--fixtures=".len..];
        } else if (std.mem.eql(u8, arg, "--skip")) {
            i += 1;
            if (i >= args.len) {
                writeStderr(io, "error: --skip requires an argument\n");
                std.process.exit(2);
            }
            skip_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--skip=")) {
            skip_path = arg["--skip=".len..];
        } else if (std.mem.eql(u8, arg, "--require-wasmtime")) {
            require_wasmtime = true;
        } else {
            try printStderr(io, alloc, "error: unknown argument '{s}'\n", .{arg});
            std.process.exit(2);
        }
    }

    const world_wit = try std.fs.path.join(alloc, &.{ fixtures_dir, "world.wit" });
    if (!isFile(io, world_wit)) {
        try printStderr(io, alloc, "error: shared world WIT not found: {s}\n", .{world_wit});
        std.process.exit(2);
    }

    const cwd = std.Io.Dir.cwd();
    var skip: std.StringHashMapUnmanaged([]const u8) = .{};
    if (isFile(io, skip_path)) {
        const skip_bytes = try cwd.readFileAlloc(io, skip_path, alloc, std.Io.Limit.limited(16 * 1024 * 1024));
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, skip_bytes, .{});
        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, "_")) continue;
                if (entry.value_ptr.* == .string) {
                    try skip.put(alloc, key, entry.value_ptr.string);
                }
            }
        }
    }

    const wasmtime = resolveWasmtime(alloc, io, init.environ_map) orelse {
        const msg = "no usable Wasmtime found (set WASMTIME or put `wasmtime` on PATH; needs P3 feature flags, e.g. wasmtime >= 46)";
        if (require_wasmtime) {
            try printStderr(io, alloc, "error: {s}\n", .{msg});
            std.process.exit(2);
        }
        try printStdout(io, alloc, "notice: p3-conformance skipped - {s}\n", .{msg});
        return;
    };

    var wat_files: std.ArrayListUnmanaged([]const u8) = .empty;
    if (cwd.openDir(io, fixtures_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".wat")) {
                try wat_files.append(alloc, try alloc.dupe(u8, entry.name));
            }
        }
    } else |_| {}

    std.mem.sort([]const u8, wat_files.items, {}, lessThanStr);
    if (wat_files.items.len == 0) {
        try printStderr(io, alloc, "error: no .wat fixtures under {s}\n", .{fixtures_dir});
        std.process.exit(2);
    }

    const tmp_base = blk: {
        if (init.environ_map.get("TMPDIR")) |t| {
            if (t.len > 0 and !std.mem.startsWith(u8, t, "/tmp")) break :blk t;
        }
        break :blk ".zig-cache/tmp";
    };

    var passed_count: usize = 0;
    var skipped_count: usize = 0;
    var failed: std.ArrayListUnmanaged(Failure) = .empty;

    try printStdout(io, alloc, "p3-conformance: wabt={s} wasmtime={s}\n", .{ wabt_path, wasmtime });

    for (wat_files.items) |wat_file| {
        const name = wat_file[0 .. wat_file.len - ".wat".len];
        if (skip.get(name)) |reason| {
            skipped_count += 1;
            try printStdout(io, alloc, "  SKIP {s: <20} - {s}\n", .{ name, reason });
            continue;
        }

        const wat_path = try std.fs.path.join(alloc, &.{ fixtures_dir, wat_file });
        const tmp_dir = try std.fmt.allocPrint(alloc, "{s}/p3-{s}", .{ tmp_base, name });
        cwd.deleteTree(io, tmp_dir) catch {};
        try cwd.createDirPath(io, tmp_dir);
        defer cwd.deleteTree(io, tmp_dir) catch {};

        const core = try std.fs.path.join(alloc, &.{ tmp_dir, "core.wasm" });
        const embed = try std.fs.path.join(alloc, &.{ tmp_dir, "embed.wasm" });
        const comp = try std.fs.path.join(alloc, &.{ tmp_dir, "component.wasm" });
        const cwasm = try std.fs.path.join(alloc, &.{ tmp_dir, "component.cwasm" });

        const step1 = [_][]const u8{ wabt_path, "text", "parse", wat_path, "-o", core };
        const step2 = [_][]const u8{ wabt_path, "component", "embed", "-w", world_name, world_wit, core, "-o", embed };
        const step3 = [_][]const u8{ wabt_path, "component", "new", embed, "-o", comp };
        const step4 = [_][]const u8{
            wasmtime,
            "compile",
            wasmtime_flags[0],
            wasmtime_flags[1],
            wasmtime_flags[2],
            wasmtime_flags[3],
            wasmtime_flags[4],
            wasmtime_flags[5],
            wasmtime_flags[6],
            wasmtime_flags[7],
            comp,
            "-o",
            cwasm,
        };

        const steps = [_][]const []const u8{ &step1, &step2, &step3, &step4 };
        var step_err: ?[]const u8 = null;
        for (steps) |cmd| {
            const res = try runCmd(alloc, io, init.environ_map, cmd);
            if (res.code != 0) {
                const cmd_str = try formatCmdForError(alloc, cmd);
                const trimmed = std.mem.trim(u8, res.combined, " \t\r\n");
                step_err = try std.fmt.allocPrint(alloc, "`{s}` exited {d}\n{s}", .{ cmd_str, res.code, trimmed });
                break;
            }
        }

        if (step_err) |err_msg| {
            try failed.append(alloc, .{ .name = name, .err = err_msg });
            try printStdout(io, alloc, "  FAIL {s}\n", .{name});
        } else {
            passed_count += 1;
            try printStdout(io, alloc, "  PASS {s}\n", .{name});
        }
    }

    try printStdout(
        io,
        alloc,
        "\np3-conformance: {d} passed, {d} skipped, {d} failed\n",
        .{ passed_count, skipped_count, failed.items.len },
    );
    for (failed.items) |f| {
        try printStderr(io, alloc, "\n--- {s} ---\n{s}\n", .{ f.name, f.err });
    }
    if (failed.items.len > 0) {
        std.process.exit(1);
    }
}
