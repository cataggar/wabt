//! Multi-package WIT resolver.
//!
//! Mirrors the directory layout convention used by `wasm-tools`'s
//! `wit-parser::Resolve::push_dir` (and accepted by `wasm-tools
//! component embed --deps`):
//!
//! ```text
//!   <root>/*.wit                  ← the "main" package (concatenated)
//!   <root>/deps/<pkg-dir>/*.wit   ← one dependency package per subdir
//!   <root>/deps/<pkg>.wit         ← single-file dependency package
//! ```
//!
//! Parsing is one-AST-per-package (each `*.wit` directory is
//! concatenated into a single source for a single `parser.parse` call).
//! The resolver keeps the parsed docs around and lets
//! `metadata_encode.encodeWorldFromResolver` look up qualified
//! interface references across the package set.
//!
//! The wamr fixtures (`zig-calculator-cmd`, `mixed-zig-rust-calc`)
//! use this exact layout: `wit/world.wit` + `wit/deps/adder/world.wit`.
//! Before this resolver, `encodeWorld` only saw the main doc and
//! would fail with `error.UnknownInterface` whenever the world
//! imported an interface declared in a sibling package.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const parser = @import("parser.zig");

pub const ResolveError = parser.ParseError || error{
    /// File or directory IO failure during deps walk.
    FileSystemError,
    /// `<root>` not found, or `<root>/deps/<entry>` not a recognized
    /// shape (file or directory).
    InvalidLayout,
    /// A `*.wit` file under `<root>` was empty.
    EmptyWit,
};

pub const Resolver = struct {
    /// The "main" parsed doc — the package the world being embedded
    /// belongs to. Always present.
    main: ast.Document,
    /// Sibling packages found under `<root>/deps/`. May be empty.
    deps: []const ast.Document,

    pub fn init(main: ast.Document, deps: []const ast.Document) Resolver {
        return .{ .main = main, .deps = deps };
    }

    /// Look up the interface body for an interface reference.
    ///
    ///   * `ref.package == null`  → look in `self.main`.
    ///   * `ref.package != null`  → search `self.main` then `self.deps`
    ///     for a doc whose `package` declaration matches `ref.package`.
    pub fn findInterface(self: Resolver, ref: ast.InterfaceRef) ?ast.Interface {
        const target_pkg = ref.package orelse {
            return findInterfaceInDoc(self.main, ref.name);
        };

        if (self.main.package) |mp| {
            if (packageMatches(mp, target_pkg)) {
                if (findInterfaceInDoc(self.main, ref.name)) |i| return i;
            }
        }
        for (self.deps) |dep| {
            if (dep.package) |dp| {
                if (packageMatches(dp, target_pkg)) {
                    if (findInterfaceInDoc(dep, ref.name)) |i| return i;
                }
            }
        }
        return null;
    }
};

fn findInterfaceInDoc(doc: ast.Document, name: []const u8) ?ast.Interface {
    for (doc.items) |it| {
        if (it == .interface and std.mem.eql(u8, it.interface.name, name)) {
            return it.interface;
        }
    }
    return null;
}

/// Two `PackageId`s match when their namespace + name match, and
/// either both versions match exactly or one of them is unspecified.
/// This is the relaxed comparison `wasm-tools` performs when resolving
/// a `<ns>:<pkg>/<iface>[@<ver>]` ref against the packages it knows
/// about — wamr's fixtures pin the version on the ref but a number
/// of upstream patterns leave it off in the dep package's own
/// `package <id>;` line.
fn packageMatches(have: ast.PackageId, want: ast.PackageId) bool {
    if (!std.mem.eql(u8, have.namespace, want.namespace)) return false;
    if (!std.mem.eql(u8, have.name, want.name)) return false;
    const have_v = have.version orelse return true;
    const want_v = want.version orelse return true;
    return std.mem.eql(u8, have_v, want_v);
}

// ── filesystem walker ───────────────────────────────────────────────────────

/// Describe a `*.wit` source. `path` is informational only (used in
/// error messages); the source text drives parsing.
pub const WitSource = struct {
    path: []const u8,
    text: []const u8,
};

/// Read every top-level `*.wit` file under `dir` (sorted, non-recursive)
/// and concatenate them, separated by '\n'. Returns the concatenated
/// buffer (caller frees) and the list of file paths included.
///
/// Empty result → no `.wit` files found.
pub fn readWitDir(
    alloc: Allocator,
    io: std.Io,
    dir_path: []const u8,
) !struct { text: []u8, paths: [][]const u8 } {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wit")) continue;
        try entries.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var combined: std.ArrayListUnmanaged(u8) = .empty;
    errdefer combined.deinit(alloc);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }

    for (entries.items) |name| {
        const full = try std.fs.path.join(alloc, &.{ dir_path, name });
        const buf = try std.Io.Dir.cwd().readFileAlloc(
            io,
            full,
            alloc,
            std.Io.Limit.limited(1 << 20),
        );
        defer alloc.free(buf);
        try combined.appendSlice(alloc, buf);
        try combined.append(alloc, '\n');
        try paths.append(alloc, full);
    }
    return .{
        .text = try combined.toOwnedSlice(alloc),
        .paths = try paths.toOwnedSlice(alloc),
    };
}

/// Parse the multi-package WIT layout rooted at `root`.
///
///   * If `root` is a directory: top-level `*.wit` files form the main
///     package; entries under `<root>/deps/` form sibling packages.
///   * If `root` is a single file: it's the only `wit` source; no deps.
///
/// All parsed `Document`s are allocated into `arena`. Returned
/// `Resolver` borrows from `arena`; caller's responsibility to keep
/// the arena alive at least as long as the resolver is used.
pub fn parseLayout(
    arena: Allocator,
    io: std.Io,
    root: []const u8,
) ResolveError!Resolver {
    const stat = std.Io.Dir.cwd().statFile(io, root, .{}) catch return error.InvalidLayout;

    if (stat.kind != .directory) {
        const buf = std.Io.Dir.cwd().readFileAlloc(
            io,
            root,
            arena,
            std.Io.Limit.limited(1 << 20),
        ) catch return error.FileSystemError;
        if (buf.len == 0) return error.EmptyWit;
        const main = try parser.parse(arena, buf, null);
        return Resolver.init(main, &.{});
    }

    // Read main package.
    const main_combined = readWitDir(arena, io, root) catch return error.FileSystemError;
    if (main_combined.text.len == 0) return error.EmptyWit;
    const main = try parser.parse(arena, main_combined.text, null);

    // Walk deps/ if present.
    const deps_path = std.fs.path.join(arena, &.{ root, "deps" }) catch return error.FileSystemError;
    const deps_stat = std.Io.Dir.cwd().statFile(io, deps_path, .{}) catch {
        return Resolver.init(main, &.{});
    };
    if (deps_stat.kind != .directory) return Resolver.init(main, &.{});

    var dep_docs: std.ArrayListUnmanaged(ast.Document) = .empty;
    var deps_dir = std.Io.Dir.cwd().openDir(io, deps_path, .{ .iterate = true }) catch
        return error.FileSystemError;
    defer deps_dir.close(io);

    var dep_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var dep_kinds: std.ArrayListUnmanaged(std.Io.File.Kind) = .empty;
    var iter = deps_dir.iterate();
    while ((iter.next(io) catch return error.FileSystemError)) |entry| {
        try dep_names.append(arena, try arena.dupe(u8, entry.name));
        try dep_kinds.append(arena, entry.kind);
    }

    // Sort deps for deterministic ordering.
    const indices: []usize = arena.alloc(usize, dep_names.items.len) catch return error.FileSystemError;
    for (indices, 0..) |*p, i| p.* = i;
    std.mem.sort(usize, indices, dep_names.items, struct {
        fn lt(names: [][]const u8, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, names[a], names[b]);
        }
    }.lt);

    for (indices) |i| {
        const name = dep_names.items[i];
        const kind = dep_kinds.items[i];
        const entry_path = try std.fs.path.join(arena, &.{ deps_path, name });
        switch (kind) {
            .directory => {
                const combined = readWitDir(arena, io, entry_path) catch return error.FileSystemError;
                if (combined.text.len == 0) continue;
                const doc = try parser.parse(arena, combined.text, null);
                try dep_docs.append(arena, doc);
            },
            .file => {
                if (!std.mem.endsWith(u8, name, ".wit")) continue;
                const buf = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    entry_path,
                    arena,
                    std.Io.Limit.limited(1 << 20),
                ) catch return error.FileSystemError;
                if (buf.len == 0) continue;
                const doc = try parser.parse(arena, buf, null);
                try dep_docs.append(arena, doc);
            },
            else => continue,
        }
    }

    return Resolver.init(main, try dep_docs.toOwnedSlice(arena));
}

// ── tests ───────────────────────────────────────────────────────────────────

test "resolver: same-package interface lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const src =
        \\package docs:adder@0.1.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
        \\world adder { export add; }
    ;
    const doc = try parser.parse(ar, src, null);
    const res = Resolver.init(doc, &.{});

    const ref: ast.InterfaceRef = .{ .package = null, .name = "add" };
    const iface = res.findInterface(ref);
    try std.testing.expect(iface != null);
    try std.testing.expectEqualStrings("add", iface.?.name);
}

test "resolver: cross-package interface lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const main_src =
        \\package docs:zigcalc@0.1.0;
        \\world app { import docs:adder/add@0.1.0; }
    ;
    const dep_src =
        \\package docs:adder@0.1.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
        \\world adder { export add; }
    ;
    const main_doc = try parser.parse(ar, main_src, null);
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(ast.Document, 1);
    deps[0] = dep_doc;
    const res = Resolver.init(main_doc, deps);

    const ref: ast.InterfaceRef = .{
        .package = .{ .namespace = "docs", .name = "adder", .version = "0.1.0" },
        .name = "add",
    };
    const iface = res.findInterface(ref);
    try std.testing.expect(iface != null);
    try std.testing.expectEqualStrings("add", iface.?.name);
    try std.testing.expectEqual(@as(usize, 1), iface.?.items.len);
}

test "resolver: package version mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const dep_src =
        \\package docs:adder@0.2.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
    ;
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(ast.Document, 1);
    deps[0] = dep_doc;
    const main_doc = try parser.parse(ar, "package docs:zigcalc@0.1.0;", null);
    const res = Resolver.init(main_doc, deps);

    const ref: ast.InterfaceRef = .{
        .package = .{ .namespace = "docs", .name = "adder", .version = "0.1.0" },
        .name = "add",
    };
    try std.testing.expect(res.findInterface(ref) == null);
}

test "resolver: package missing version on either side matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const dep_src =
        \\package docs:adder;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
    ;
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(ast.Document, 1);
    deps[0] = dep_doc;
    const main_doc = try parser.parse(ar, "package docs:zigcalc;", null);
    const res = Resolver.init(main_doc, deps);

    const ref: ast.InterfaceRef = .{
        .package = .{ .namespace = "docs", .name = "adder", .version = "0.1.0" },
        .name = "add",
    };
    const iface = res.findInterface(ref);
    try std.testing.expect(iface != null);
}
