//! Vendor canonical WASI `.wit` files into the embedded `wasi-canon` tree.
//!
//! The CLI `@embedFile`s these so apps never need an on-disk `wit/deps/` copy
//! (issue 261). This tool fetches every package's `.wit` files from the
//! upstream git **tag** via the GitHub API (`gh`) and writes them under:
//!
//!     src/component/wit/wasi-canon/<version>/<package>/<file>.wit
//!
//! `deps/`, `deps.toml` and `deps.lock` are skipped — cross-package
//! references resolve against the other embedded packages at resolve time.
//!
//! Files are written with LF line endings (as served by GitHub); `.gitattributes`
//! (`* text=auto`) normalizes them in git, matching the existing 0.2.6 vendor.
//!
//! Usage:
//!     zig build vendor-wasi-wit                      # all version sets
//!     zig build vendor-wasi-wit -- --only 0.2.12     # one version dir
//!     zig build vendor-wasi-wit -- --list            # print the manifest
//!
//! Requires the GitHub CLI (`gh`) to be installed and authenticated.

const std = @import("std");

const dest_root = "src/component/wit/wasi-canon";

const usage_text =
    \\Usage: vendor-wasi-wit [options]
    \\
    \\Vendor canonical WASI `.wit` files into `src/component/wit/wasi-canon/`.
    \\
    \\Options:
    \\  --only <version>  Vendor only the given version dir(s); repeatable
    \\  --list            Print the manifest and exit
    \\  help, --help      Print this help and exit
    \\
;

pub const Pkg = struct {
    name: []const u8,
    dir: []const u8,
};

pub const VersionSet = struct {
    version: []const u8,
    repo: []const u8,
    ref: []const u8,
    packages: []const Pkg,
};

const core_p2_026 = [_]Pkg{
    .{ .name = "cli", .dir = "wasip2/cli" },
    .{ .name = "clocks", .dir = "wasip2/clocks" },
    .{ .name = "filesystem", .dir = "wasip2/filesystem" },
    .{ .name = "http", .dir = "wasip2/http" },
    .{ .name = "io", .dir = "wasip2/io" },
    .{ .name = "random", .dir = "wasip2/random" },
    .{ .name = "sockets", .dir = "wasip2/sockets" },
};

const core_p2_proposals = [_]Pkg{
    .{ .name = "cli", .dir = "proposals/cli/wit" },
    .{ .name = "clocks", .dir = "proposals/clocks/wit" },
    .{ .name = "filesystem", .dir = "proposals/filesystem/wit" },
    .{ .name = "http", .dir = "proposals/http/wit" },
    .{ .name = "io", .dir = "proposals/io/wit" },
    .{ .name = "random", .dir = "proposals/random/wit" },
    .{ .name = "sockets", .dir = "proposals/sockets/wit" },
};

const core_p3_proposals = [_]Pkg{
    .{ .name = "cli", .dir = "proposals/cli/wit" },
    .{ .name = "clocks", .dir = "proposals/clocks/wit" },
    .{ .name = "filesystem", .dir = "proposals/filesystem/wit" },
    .{ .name = "http", .dir = "proposals/http/wit" },
    .{ .name = "random", .dir = "proposals/random/wit" },
    .{ .name = "sockets", .dir = "proposals/sockets/wit" },
};

pub const manifest = [_]VersionSet{
    .{
        .version = "0.2.6",
        .repo = "WebAssembly/WASI",
        .ref = "v0.2.6",
        .packages = &core_p2_026,
    },
    .{
        .version = "0.2.12",
        .repo = "WebAssembly/WASI",
        .ref = "v0.2.12",
        .packages = &core_p2_proposals,
    },
    .{
        .version = "0.3.0",
        .repo = "WebAssembly/WASI",
        .ref = "v0.3.0",
        .packages = &core_p3_proposals,
    },
    // Off-by-default proposals, each in its own repo. The package's `.wit`
    // files live directly under `wit/`; the destination subdir is the bare
    // package name.
    .{
        .version = "0.2.0-rc.1",
        .repo = "WebAssembly/wasi-config",
        .ref = "v0.2.0-rc.1",
        .packages = &.{.{ .name = "config", .dir = "wit" }},
    },
    .{
        .version = "0.2.0-draft",
        .repo = "WebAssembly/wasi-keyvalue",
        .ref = "v0.2.0-draft",
        .packages = &.{.{ .name = "keyvalue", .dir = "wit" }},
    },
    .{
        .version = "0.2.0-rc-2024-10-28",
        .repo = "WebAssembly/wasi-nn",
        .ref = "0.2.0-rc-2024-10-28",
        .packages = &.{.{ .name = "nn", .dir = "wit" }},
    },
    .{
        .version = "0.2.0-draft",
        .repo = "WebAssembly/wasi-tls",
        .ref = "v0.2.0-draft+6781ae2",
        .packages = &.{.{ .name = "tls", .dir = "wit" }},
    },
};

fn writeStdout(io: std.Io, text: []const u8) !void {
    var stdout_file = std.Io.File.stdout();
    try stdout_file.writeStreamingAll(io, text);
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

fn urlQuote(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 0x0F] });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn ghApi(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    raw: bool,
) ![]u8 {
    const argv_json = [_][]const u8{ "gh", "api", path };
    const argv_raw = [_][]const u8{ "gh", "api", path, "-H", "Accept: application/vnd.github.raw" };
    const argv: []const []const u8 = if (raw) &argv_raw else &argv_json;

    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(16 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
    }) catch |err| {
        std.debug.print("error: failed to invoke `gh api`: {any}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        gpa.free(result.stdout);
        if (result.stderr.len > 0) {
            std.debug.print("{s}", .{result.stderr});
        }
        std.debug.print("gh api failed for '{s}'\n", .{path});
        std.process.exit(1);
    }
    return result.stdout;
}

const GhContentEntry = struct {
    name: []const u8,
    type: []const u8 = "",
};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn listWitFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    ref: []const u8,
    directory: []const u8,
) ![][]u8 {
    const q = try urlQuote(gpa, ref);
    defer gpa.free(q);
    const path = try std.fmt.allocPrint(
        gpa,
        "repos/{s}/contents/{s}?ref={s}",
        .{ repo, directory, q },
    );
    defer gpa.free(path);

    const json_bytes = try ghApi(gpa, io, path, false);
    defer gpa.free(json_bytes);

    var parsed = try std.json.parseFromSlice(
        []const GhContentEntry,
        gpa,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (parsed.value) |item| {
        if (std.mem.eql(u8, item.type, "file") and std.mem.endsWith(u8, item.name, ".wit")) {
            try names.append(gpa, try gpa.dupe(u8, item.name));
        }
    }

    const slice = try names.toOwnedSlice(gpa);
    std.mem.sort([]u8, slice, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return lessThanStr({}, a, b);
        }
    }.lt);
    return slice;
}

fn fetchFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    ref: []const u8,
    directory: []const u8,
    name: []const u8,
) ![]u8 {
    const q = try urlQuote(gpa, ref);
    defer gpa.free(q);
    const path = try std.fmt.allocPrint(
        gpa,
        "repos/{s}/contents/{s}/{s}?ref={s}",
        .{ repo, directory, name, q },
    );
    defer gpa.free(path);
    return ghApi(gpa, io, path, true);
}

fn normalizeLf(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, data.len);
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\r' and i + 1 < data.len and data[i + 1] == '\n') {
            continue;
        }
        out.appendAssumeCapacity(data[i]);
    }
    return out.toOwnedSlice(gpa);
}

fn vendor(gpa: std.mem.Allocator, io: std.Io, vs: VersionSet) !usize {
    var count: usize = 0;
    const cwd = std.Io.Dir.cwd();
    for (vs.packages) |pkg| {
        const dst_dir = try std.fs.path.join(gpa, &.{ dest_root, vs.version, pkg.name });
        defer gpa.free(dst_dir);
        try cwd.createDirPath(io, dst_dir);

        const names = try listWitFiles(gpa, io, vs.repo, vs.ref, pkg.dir);
        defer {
            for (names) |n| gpa.free(n);
            gpa.free(names);
        }
        if (names.len == 0) {
            std.debug.print(
                "  warning: no .wit files in {s}@{s}:{s}\n",
                .{ vs.repo, vs.ref, pkg.dir },
            );
        }
        for (names) |name| {
            const raw_data = try fetchFile(gpa, io, vs.repo, vs.ref, pkg.dir, name);
            defer gpa.free(raw_data);
            const normalized = try normalizeLf(gpa, raw_data);
            defer gpa.free(normalized);

            const file_path = try std.fs.path.join(gpa, &.{ dst_dir, name });
            defer gpa.free(file_path);
            try cwd.writeFile(io, .{
                .sub_path = file_path,
                .data = normalized,
            });
            count += 1;

            const line = try std.fmt.allocPrint(
                gpa,
                "  {s}/{s}/{s}\n",
                .{ vs.version, pkg.name, name },
            );
            defer gpa.free(line);
            try writeStdout(io, line);
        }
    }
    return count;
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var list_mode = false;
    var only_versions: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeStdout(init.io, usage_text);
            return;
        } else if (std.mem.eql(u8, arg, "--list")) {
            list_mode = true;
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --only requires a version argument\n", .{});
                std.process.exit(2);
            }
            try only_versions.append(arena, args[i]);
        } else if (std.mem.startsWith(u8, arg, "--only=")) {
            try only_versions.append(arena, arg["--only=".len..]);
        } else {
            std.debug.print("error: unrecognized argument '{s}'\n", .{arg});
            std.process.exit(2);
        }
    }

    if (list_mode) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);
        for (manifest) |vs| {
            var pkgs_buf: std.ArrayListUnmanaged(u8) = .empty;
            defer pkgs_buf.deinit(gpa);
            for (vs.packages, 0..) |p, idx| {
                if (idx > 0) try pkgs_buf.appendSlice(gpa, ", ");
                try pkgs_buf.appendSlice(gpa, p.name);
            }
            const line = try std.fmt.allocPrint(
                gpa,
                "{s:<24} {s}@{s}  [{s}]\n",
                .{ vs.version, vs.repo, vs.ref, pkgs_buf.items },
            );
            defer gpa.free(line);
            try out.appendSlice(gpa, line);
        }
        try writeStdout(init.io, out.items);
        return;
    }

    var total: usize = 0;
    for (manifest) |vs| {
        if (only_versions.items.len > 0 and !containsStr(only_versions.items, vs.version)) {
            continue;
        }
        const header = try std.fmt.allocPrint(
            gpa,
            "# {s}  <- {s}@{s}\n",
            .{ vs.version, vs.repo, vs.ref },
        );
        defer gpa.free(header);
        try writeStdout(init.io, header);
        total += try vendor(gpa, init.io, vs);
    }

    const footer = try std.fmt.allocPrint(gpa, "vendored {d} .wit file(s)\n", .{total});
    defer gpa.free(footer);
    try writeStdout(init.io, footer);
}

test "urlQuote encodes reserved characters and preserves unreserved" {
    const gpa = std.testing.allocator;
    const q1 = try urlQuote(gpa, "v0.2.6");
    defer gpa.free(q1);
    try std.testing.expectEqualStrings("v0.2.6", q1);

    const q2 = try urlQuote(gpa, "refs/tags/v0.2.0-rc+build 1");
    defer gpa.free(q2);
    try std.testing.expectEqualStrings("refs%2Ftags%2Fv0.2.0-rc%2Bbuild%201", q2);
}

test "normalizeLf strips CR before LF only" {
    const gpa = std.testing.allocator;
    const norm = try normalizeLf(gpa, "package wasi:io@0.2.6;\r\ninterface poll {\r\n}\n\rkeep-lone-cr");
    defer gpa.free(norm);
    try std.testing.expectEqualStrings("package wasi:io@0.2.6;\ninterface poll {\n}\n\rkeep-lone-cr", norm);
}

test "manifest versions and package counts match canonical vendor table" {
    try std.testing.expectEqual(@as(usize, 7), manifest.len);
    try std.testing.expectEqualStrings("0.2.6", manifest[0].version);
    try std.testing.expectEqual(@as(usize, 7), manifest[0].packages.len);
    try std.testing.expectEqualStrings("0.2.12", manifest[1].version);
    try std.testing.expectEqualStrings("0.3.0", manifest[2].version);
    try std.testing.expectEqualStrings("0.2.0-rc.1", manifest[3].version);
    try std.testing.expectEqualStrings("0.2.0-draft", manifest[4].version);
    try std.testing.expectEqualStrings("0.2.0-rc-2024-10-28", manifest[5].version);
    try std.testing.expectEqualStrings("0.2.0-draft", manifest[6].version);
}
