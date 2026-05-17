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
    /// Two or more files in the same directory carry differing
    /// `package <ns>:<name>[@<ver>];` declarations.
    PackageDeclConflict,
    /// No file in the directory carries a `package <ns>:<name>;`
    /// declaration — qualified-name resolution would fail.
    NoPackageDeclInDirectory,
};

/// Optional diagnostic populated by the resolver on errors that
/// have a path-level explanation. Mirrors `parser.ParseDiagnostic`
/// but uses file paths instead of byte spans.
pub const ResolveDiagnostic = struct {
    msg: []const u8 = "",
    path: []const u8 = "",
    path2: []const u8 = "",
};

/// Lightweight scanner: returns the byte range `[start, end)` of
/// the first `package <ns>:<name>[@<ver>];` declaration in `buf`,
/// skipping only leading whitespace, `//` / `///` line comments,
/// `/* … */` block comments, and `@<id>(<args>?)` annotations
/// before the decl. Returns null if no leading decl is found
/// (the file may still contain `package` mid-stream, but that's
/// not a top-level decl).
pub fn scanForPackageDecl(buf: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i < buf.len) {
        const c = buf[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => i += 1,
            '/' => {
                if (i + 1 >= buf.len) return null;
                if (buf[i + 1] == '/') {
                    while (i < buf.len and buf[i] != '\n') i += 1;
                } else if (buf[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < buf.len and !(buf[i] == '*' and buf[i + 1] == '/')) i += 1;
                    if (i + 1 < buf.len) i += 2;
                } else {
                    return null;
                }
            },
            '@' => {
                // Skip annotation: `@` <id> `(<balanced parens>)`?
                i += 1;
                // skip id chars
                while (i < buf.len and isIdentChar(buf[i])) i += 1;
                // skip optional `( ... )`
                while (i < buf.len and (buf[i] == ' ' or buf[i] == '\t' or buf[i] == '\r' or buf[i] == '\n')) i += 1;
                if (i < buf.len and buf[i] == '(') {
                    var depth: usize = 1;
                    i += 1;
                    while (i < buf.len and depth > 0) : (i += 1) {
                        if (buf[i] == '(') depth += 1;
                        if (buf[i] == ')') depth -= 1;
                    }
                }
            },
            'p' => {
                // Look for `package ` literal.
                if (i + 8 <= buf.len and std.mem.eql(u8, buf[i .. i + 8], "package ")) {
                    const decl_start = i;
                    // Advance until the next `;` or end of buf.
                    while (i < buf.len and buf[i] != ';') i += 1;
                    if (i >= buf.len) return null;
                    return .{ .start = decl_start, .end = i + 1 };
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

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
        if (self.findInterfaceWithPkg(ref)) |hit| return hit.iface;
        return null;
    }

    /// Like `findInterface` but also returns the package the interface
    /// was found in. Needed by `metadata_encode` to compute qualified
    /// names for short in-package references — e.g. a `use foo.{T};`
    /// inside an interface located in `wasi:cli` must resolve `foo` as
    /// `wasi:cli/foo`, not as a ref into the world's main package.
    pub fn findInterfaceWithPkg(self: Resolver, ref: ast.InterfaceRef) ?Lookup {
        return self.findInterfaceWithPkgCtx(ref, null);
    }

    /// Variant of `findInterfaceWithPkg` that accepts a `ctx_pkg`
    /// fallback package id. When `ref.package == null` (a short ref
    /// like `use error.{error};`) the lookup tries `ctx_pkg` first
    /// — this is the package the *consuming* interface lives in.
    /// Falls back to `self.main` if `ctx_pkg` is null or doesn't
    /// contain the named interface. Same package matched (relaxed
    /// version compare) as `findInterfaceWithPkg`.
    pub fn findInterfaceWithPkgCtx(self: Resolver, ref: ast.InterfaceRef, ctx_pkg: ?ast.PackageId) ?Lookup {
        if (ref.package == null) {
            if (ctx_pkg) |cp| {
                if (self.main.package) |mp| {
                    if (packageMatches(mp, cp)) {
                        if (findInterfaceInDoc(self.main, ref.name)) |i| {
                            return .{ .iface = i, .pkg = mp };
                        }
                    }
                }
                for (self.deps) |dep| {
                    if (dep.package) |dp| {
                        if (packageMatches(dp, cp)) {
                            if (findInterfaceInDoc(dep, ref.name)) |i| {
                                return .{ .iface = i, .pkg = dp };
                            }
                        }
                    }
                }
                // Fall through to the original main-only lookup.
            }
            if (findInterfaceInDoc(self.main, ref.name)) |i| {
                return .{ .iface = i, .pkg = self.main.package orelse return null };
            }
            return null;
        }

        const target_pkg = ref.package.?;
        if (self.main.package) |mp| {
            if (packageMatches(mp, target_pkg)) {
                if (findInterfaceInDoc(self.main, ref.name)) |i| return .{ .iface = i, .pkg = mp };
            }
        }
        for (self.deps) |dep| {
            if (dep.package) |dp| {
                if (packageMatches(dp, target_pkg)) {
                    if (findInterfaceInDoc(dep, ref.name)) |i| return .{ .iface = i, .pkg = dp };
                }
            }
        }
        return null;
    }

    pub const Lookup = struct {
        iface: ast.Interface,
        pkg: ast.PackageId,
    };

    /// Look up a world by reference. Same package-matching rules as
    /// `findInterfaceWithPkg`. Used by `metadata_encode` to expand
    /// `include` items.
    pub fn findWorld(self: Resolver, ref: ast.InterfaceRef) ?WorldLookup {
        return self.findWorldCtx(ref, null);
    }

    pub fn findWorldCtx(self: Resolver, ref: ast.InterfaceRef, ctx_pkg: ?ast.PackageId) ?WorldLookup {
        if (ref.package == null) {
            if (ctx_pkg) |cp| {
                if (self.main.package) |mp| {
                    if (packageMatches(mp, cp)) {
                        if (findWorldInDoc(self.main, ref.name)) |w| return .{ .world = w, .pkg = mp };
                    }
                }
                for (self.deps) |dep| {
                    if (dep.package) |dp| {
                        if (packageMatches(dp, cp)) {
                            if (findWorldInDoc(dep, ref.name)) |w| return .{ .world = w, .pkg = dp };
                        }
                    }
                }
            }
            if (findWorldInDoc(self.main, ref.name)) |w| {
                return .{ .world = w, .pkg = self.main.package orelse return null };
            }
            return null;
        }
        const target_pkg = ref.package.?;
        if (self.main.package) |mp| {
            if (packageMatches(mp, target_pkg)) {
                if (findWorldInDoc(self.main, ref.name)) |w| return .{ .world = w, .pkg = mp };
            }
        }
        for (self.deps) |dep| {
            if (dep.package) |dp| {
                if (packageMatches(dp, target_pkg)) {
                    if (findWorldInDoc(dep, ref.name)) |w| return .{ .world = w, .pkg = dp };
                }
            }
        }
        return null;
    }

    pub const WorldLookup = struct {
        world: ast.World,
        pkg: ast.PackageId,
    };
};

fn findWorldInDoc(doc: ast.Document, name: []const u8) ?ast.World {
    for (doc.items) |it| {
        if (it == .world and std.mem.eql(u8, it.world.name, name)) return it.world;
    }
    return null;
}

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
/// Read every top-level `*.wit` file under `dir` (sorted, non-recursive)
/// and concatenate them into a single source buffer, separated by '\n'.
///
/// Canonical WIT directories often have a single `package <id>;`
/// declaration that's inherited by every other file in the same
/// directory (e.g. `wasi-http/wit/proxy.wit` carries the package
/// decl; `types.wit` and `handler.wit` don't). To produce a parser-
/// digestible buffer we:
///
///   1. Scan each file for a leading `package` decl.
///   2. Require the directory contain exactly one DISTINCT decl
///      (multiple files may carry it as long as they match); error
///      with `PackageDeclConflict` on a mismatch and
///      `NoPackageDeclInDirectory` if none has one.
///   3. Concat the canonical decl-bearing file FIRST (with its
///      decl intact), then other files alphabetically afterwards
///      with any duplicate decl stripped.
///
/// Returns the concatenated buffer (caller frees) and the list of
/// file paths included (in concat order).
///
/// Empty result (no `.wit` files found) → returns `text.len == 0`.
pub fn readWitDir(
    alloc: Allocator,
    io: std.Io,
    dir_path: []const u8,
    diag: ?*ResolveDiagnostic,
) ResolveError!struct { text: []u8, paths: [][]const u8 } {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return error.FileSystemError;
    defer dir.close(io);

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e);
        entries.deinit(alloc);
    }
    var it = dir.iterate();
    while ((it.next(io) catch return error.FileSystemError)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wit")) continue;
        try entries.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    if (entries.items.len == 0) {
        return .{ .text = try alloc.alloc(u8, 0), .paths = try alloc.alloc([]const u8, 0) };
    }

    // Read every file into memory, scan each for its leading package
    // decl, and validate consistency.
    const FileEntry = struct {
        name: []const u8,
        full_path: []const u8,
        buf: []u8,
        pkg_start: usize,
        pkg_end: usize,
        has_pkg: bool,
    };
    var files = try alloc.alloc(FileEntry, entries.items.len);
    defer {
        for (files) |f| {
            alloc.free(f.full_path);
            alloc.free(f.buf);
        }
        alloc.free(files);
    }
    var canonical_decl: ?[]const u8 = null;
    var canonical_path: []const u8 = "";
    var first_decl_idx: ?usize = null;
    for (entries.items, 0..) |name, i| {
        const full = std.fs.path.join(alloc, &.{ dir_path, name }) catch return error.FileSystemError;
        const buf = std.Io.Dir.cwd().readFileAlloc(
            io,
            full,
            alloc,
            std.Io.Limit.limited(1 << 20),
        ) catch return error.FileSystemError;
        files[i] = .{
            .name = name,
            .full_path = full,
            .buf = buf,
            .pkg_start = 0,
            .pkg_end = 0,
            .has_pkg = false,
        };
        if (scanForPackageDecl(buf)) |range| {
            files[i].pkg_start = range.start;
            files[i].pkg_end = range.end;
            files[i].has_pkg = true;
            const decl_text = std.mem.trim(u8, buf[range.start..range.end], " \t\r\n");
            if (canonical_decl) |canon| {
                if (!std.mem.eql(u8, canon, decl_text)) {
                    if (diag) |d| d.* = .{
                        .msg = "files in the same WIT directory have differing `package` decls",
                        .path = canonical_path,
                        .path2 = full,
                    };
                    return error.PackageDeclConflict;
                }
            } else {
                canonical_decl = decl_text;
                canonical_path = full;
                first_decl_idx = i;
            }
        }
    }

    if (first_decl_idx == null) {
        if (diag) |d| d.* = .{
            .msg = "no `package <ns>:<name>[@<ver>];` decl found in any file under this directory",
            .path = dir_path,
        };
        return error.NoPackageDeclInDirectory;
    }

    var combined: std.ArrayListUnmanaged(u8) = .empty;
    errdefer combined.deinit(alloc);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }

    // Emit order: the package-bearing file first (decl intact), then
    // every other file in alphabetical order with any duplicate decl
    // stripped.
    const first = first_decl_idx.?;
    {
        const f = files[first];
        try combined.appendSlice(alloc, f.buf);
        try combined.append(alloc, '\n');
        try paths.append(alloc, try alloc.dupe(u8, f.full_path));
    }
    for (files, 0..) |f, i| {
        if (i == first) continue;
        try paths.append(alloc, try alloc.dupe(u8, f.full_path));
        if (f.has_pkg) {
            // Strip the duplicate decl; keep surrounding content.
            try combined.appendSlice(alloc, f.buf[0..f.pkg_start]);
            try combined.appendSlice(alloc, f.buf[f.pkg_end..]);
        } else {
            try combined.appendSlice(alloc, f.buf);
        }
        try combined.append(alloc, '\n');
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
    return parseLayoutWithDiag(arena, io, root, null);
}

/// Like `parseLayout` but also populates `diag` on errors that have
/// a file-path-level explanation (`PackageDeclConflict`,
/// `NoPackageDeclInDirectory`).
pub fn parseLayoutWithDiag(
    arena: Allocator,
    io: std.Io,
    root: []const u8,
    diag: ?*ResolveDiagnostic,
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
    const main_combined = try readWitDir(arena, io, root, diag);
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
                const combined = try readWitDir(arena, io, entry_path, diag);
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

test "scanForPackageDecl: finds leading decl past whitespace/comments/annotations" {
    // Plain package decl at the very start.
    {
        const buf = "package wasi:http@0.2.6;\ninterface i { f: func(); }";
        const r = scanForPackageDecl(buf).?;
        try std.testing.expectEqualStrings("package wasi:http@0.2.6;", buf[r.start..r.end]);
    }
    // Leading line + block comments.
    {
        const buf =
            \\// header comment
            \\/* block */
            \\package wasi:http@0.2.6;
        ;
        const r = scanForPackageDecl(buf).?;
        try std.testing.expectEqualStrings("package wasi:http@0.2.6;", buf[r.start..r.end]);
    }
    // Leading doc comments + annotations.
    {
        const buf =
            \\/// doc
            \\@since(version = 0.2.0)
            \\package wasi:http@0.2.6;
        ;
        const r = scanForPackageDecl(buf).?;
        try std.testing.expectEqualStrings("package wasi:http@0.2.6;", buf[r.start..r.end]);
    }
    // No leading decl — returns null.
    {
        const buf = "interface i { f: func(); }";
        try std.testing.expect(scanForPackageDecl(buf) == null);
    }
    // `package` appearing mid-stream is NOT a leading decl.
    {
        const buf = "interface i { f: func(); }\npackage wasi:http@0.2.6;";
        try std.testing.expect(scanForPackageDecl(buf) == null);
    }
}

test "resolver #195p2: multi-file primary package — decl in non-first file" {
    // Repro mirrors wasi-http/wit/: handler.wit (no pkg decl),
    // proxy.wit (carries the decl), types.wit (no pkg decl).
    // Alphabetical concat → decl mid-stream → parse fails pre-fix.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a-handler.wit",
        .data = "interface handler { handle: func(); }",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "b-proxy.wit",
        .data = "package wasi:http@0.2.6;\nworld w { import handler; }",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "c-types.wit",
        .data = "interface types { t: func(); }",
    });

    const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const res = try parseLayoutWithDiag(allocator, std.testing.io, tmp_root, null);
    try std.testing.expect(res.main.package != null);
    try std.testing.expectEqualStrings("wasi", res.main.package.?.namespace);
    try std.testing.expectEqualStrings("http", res.main.package.?.name);
    try std.testing.expectEqualStrings("0.2.6", res.main.package.?.version.?);
    // All three files' items should be merged into one document.
    // Order: items from the decl-bearing file first (just `world w`),
    // then alphabetical others (`handler` then `types`).
    try std.testing.expectEqual(@as(usize, 3), res.main.items.len);
}

test "resolver #195p2: package decl conflict between files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.wit",
        .data = "package wasi:http@0.2.6;\ninterface i { f: func(); }",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "b.wit",
        .data = "package wasi:http@0.2.5;\ninterface j { f: func(); }",
    });

    const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var diag: ResolveDiagnostic = .{};
    const got = parseLayoutWithDiag(allocator, std.testing.io, tmp_root, &diag);
    try std.testing.expectError(error.PackageDeclConflict, got);
    try std.testing.expect(diag.msg.len > 0);
    try std.testing.expect(diag.path.len > 0);
    try std.testing.expect(diag.path2.len > 0);
}

test "resolver #195p2: no package decl in directory" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.wit",
        .data = "interface i { f: func(); }",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "b.wit",
        .data = "interface j { f: func(); }",
    });

    const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var diag: ResolveDiagnostic = .{};
    const got = parseLayoutWithDiag(allocator, std.testing.io, tmp_root, &diag);
    try std.testing.expectError(error.NoPackageDeclInDirectory, got);
    try std.testing.expect(diag.msg.len > 0);
}

test "resolver #195p2: duplicate-but-matching package decls are deduped" {
    // wasi-http does NOT actually do this (only one file carries the
    // decl), but other multi-file packages might. Verify the resolver
    // accepts duplicated identical decls.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "a.wit",
        .data = "package ex:p@1.0.0;\ninterface ia { f: func(); }",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "b.wit",
        .data = "package ex:p@1.0.0;\ninterface ib { f: func(); }",
    });

    const tmp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const res = try parseLayoutWithDiag(allocator, std.testing.io, tmp_root, null);
    try std.testing.expect(res.main.package != null);
    try std.testing.expectEqualStrings("ex", res.main.package.?.namespace);
    try std.testing.expectEqualStrings("p", res.main.package.?.name);
    try std.testing.expectEqual(@as(usize, 2), res.main.items.len);
}

test "resolver #195p2: canonical wasi-http proxy world resolves through the layout" {
    // Phase 2 acceptance for #195. Assembles a temp WIT tree that
    // mirrors the canonical wasi-http@0.2.6 layout (http/* as the
    // main package, cli/clocks/filesystem/io/random/sockets under
    // deps/) and asserts parseLayout resolves all packages.
    //
    // Source files are vendored at src/component/wit/wasi-canon/
    // (added in #200 / Phase 1). We copy them out at test time
    // using the runtime IO interface — simpler than @embedFile-ing
    // 33 files a second time.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    // Build the layout: <tmp>/wit/ (main = http) +
    // <tmp>/wit/deps/{cli,clocks,filesystem,io,random,sockets}/.
    try tmp.dir.createDirPath(io, "wit");
    try tmp.dir.createDirPath(io, "wit/deps");

    const pkgs = [_]struct { src_dir: []const u8, dst_rel: []const u8 }{
        .{ .src_dir = "src/component/wit/wasi-canon/http", .dst_rel = "wit" },
        .{ .src_dir = "src/component/wit/wasi-canon/cli", .dst_rel = "wit/deps/cli" },
        .{ .src_dir = "src/component/wit/wasi-canon/clocks", .dst_rel = "wit/deps/clocks" },
        .{ .src_dir = "src/component/wit/wasi-canon/filesystem", .dst_rel = "wit/deps/filesystem" },
        .{ .src_dir = "src/component/wit/wasi-canon/io", .dst_rel = "wit/deps/io" },
        .{ .src_dir = "src/component/wit/wasi-canon/random", .dst_rel = "wit/deps/random" },
        .{ .src_dir = "src/component/wit/wasi-canon/sockets", .dst_rel = "wit/deps/sockets" },
    };

    for (pkgs) |pkg| {
        try tmp.dir.createDirPath(io, pkg.dst_rel);
        var src = try cwd.openDir(io, pkg.src_dir, .{ .iterate = true });
        defer src.close(io);
        var it = src.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".wit")) continue;
            const src_path = try std.fs.path.join(allocator, &.{ pkg.src_dir, entry.name });
            const buf = try cwd.readFileAlloc(io, src_path, allocator, std.Io.Limit.limited(1 << 20));
            const dst_path = try std.fs.path.join(allocator, &.{ pkg.dst_rel, entry.name });
            try tmp.dir.writeFile(io, .{ .sub_path = dst_path, .data = buf });
        }
    }

    const tmp_wit = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/wit", .{tmp.sub_path});
    var diag: ResolveDiagnostic = .{};
    const res = parseLayoutWithDiag(allocator, io, tmp_wit, &diag) catch |err| {
        std.debug.print(
            "\nparseLayout failed: {s}\n  msg: {s}\n  path: {s}\n  path2: {s}\n",
            .{ @errorName(err), diag.msg, diag.path, diag.path2 },
        );
        return err;
    };

    // Main package is wasi:http@0.2.6.
    try std.testing.expect(res.main.package != null);
    try std.testing.expectEqualStrings("wasi", res.main.package.?.namespace);
    try std.testing.expectEqualStrings("http", res.main.package.?.name);
    try std.testing.expectEqualStrings("0.2.6", res.main.package.?.version.?);

    // All 6 dep packages are present and named.
    try std.testing.expectEqual(@as(usize, 6), res.deps.len);
    var saw_cli = false;
    var saw_clocks = false;
    var saw_filesystem = false;
    var saw_io = false;
    var saw_random = false;
    var saw_sockets = false;
    for (res.deps) |dep| {
        try std.testing.expect(dep.package != null);
        const n = dep.package.?.name;
        if (std.mem.eql(u8, n, "cli")) saw_cli = true;
        if (std.mem.eql(u8, n, "clocks")) saw_clocks = true;
        if (std.mem.eql(u8, n, "filesystem")) saw_filesystem = true;
        if (std.mem.eql(u8, n, "io")) saw_io = true;
        if (std.mem.eql(u8, n, "random")) saw_random = true;
        if (std.mem.eql(u8, n, "sockets")) saw_sockets = true;
    }
    try std.testing.expect(saw_cli);
    try std.testing.expect(saw_clocks);
    try std.testing.expect(saw_filesystem);
    try std.testing.expect(saw_io);
    try std.testing.expect(saw_random);
    try std.testing.expect(saw_sockets);
}

test "resolver #216: bundled wasi-cli adapter deps now expose stdin" {
    // After #216 the bundled `adapters/wasi-preview1/wit/deps/wasi-cli`
    // is the FULL canonical wasi:cli@0.2.6 set instead of a trimmed
    // slice that only carried stdout + stderr. Users authoring their
    // own world against the bundled WIT can now `import wasi:cli/
    // stdin@0.2.6;` without `UnknownInterface`.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();
    const io = std.testing.io;

    const res = try parseLayout(allocator, io, "adapters/wasi-preview1/wit");

    // Find the wasi:cli dep and verify it declares a `stdin` interface.
    var found_stdin = false;
    for (res.deps) |dep| {
        if (dep.package == null) continue;
        if (!std.mem.eql(u8, dep.package.?.name, "cli")) continue;
        for (dep.items) |item| {
            if (item != .interface) continue;
            if (std.mem.eql(u8, item.interface.name, "stdin")) {
                found_stdin = true;
                break;
            }
        }
    }
    try std.testing.expect(found_stdin);
}
