//! Component-Model extern-name parsing and version rewriting.
//!
//! Component imports/exports carry names in the WIT externname grammar:
//!
//!   externname  ::= [ns ":"]? pkg "/" iface ("@" version)?
//!   ns          ::= identifier         (e.g. "wasi", "azure")
//!   pkg         ::= identifier         (e.g. "io", "codegen")
//!   iface       ::= ("/" identifier)+  (e.g. "error", "streams")
//!   version     ::= semver             (e.g. "0.2.6", "0.2.10")
//!
//! `wabt component compose` needs to (a) detect when the same
//! `ns:pkg/iface` appears at multiple versions across the seam and
//! (b) rewrite version strings to a single target. This module
//! provides the parse + compare + rewrite primitives; the conflict
//! detector and byte-level rewriter live in sibling modules.

const std = @import("std");

/// Parsed components of an externname. `version` is null when the
/// name carries no `@x.y.z` suffix.
pub const Parts = struct {
    /// Namespace prefix (e.g. "wasi"). Empty slice when the name has
    /// no `ns:` prefix.
    ns: []const u8,
    /// Package name (e.g. "io"). Always non-empty in well-formed
    /// names — a parse that yields an empty pkg is rejected with
    /// null.
    pkg: []const u8,
    /// Interface path after the first `/` (e.g. "error",
    /// "incoming-handler"). Always non-empty.
    iface: []const u8,
    /// Version suffix without the leading `@`, e.g. "0.2.6". Null if
    /// the name is un-versioned.
    version: ?[]const u8,
};

/// Split an extern name into its `(ns, pkg, iface, version)` parts.
/// Returns null when the name doesn't conform to the
/// `[ns:]pkg/iface[@ver]` shape — callers should treat such names as
/// opaque and skip version-related processing.
pub fn parse(name: []const u8) ?Parts {
    if (name.len == 0) return null;
    var rest = name;

    var ns: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon_idx| {
        ns = rest[0..colon_idx];
        rest = rest[colon_idx + 1 ..];
    }

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash_idx == 0) return null;
    const pkg = rest[0..slash_idx];
    rest = rest[slash_idx + 1 ..];
    if (rest.len == 0) return null;

    var iface = rest;
    var version: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '@')) |at_idx| {
        iface = rest[0..at_idx];
        if (iface.len == 0) return null;
        const v = rest[at_idx + 1 ..];
        if (v.len == 0) return null;
        version = v;
    }

    return .{ .ns = ns, .pkg = pkg, .iface = iface, .version = version };
}

/// A semantic version restricted to the major.minor.patch shape used
/// by the WIT registry. Pre-release / build metadata is rejected —
/// the only versions wabt's compose has to reconcile come from
/// generators (jco / zig-wasm) and runtimes (wasmtime) whose
/// real-world output is strictly three numeric components.
pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(s: []const u8) ?SemVer {
        var parts: [3]u32 = .{ 0, 0, 0 };
        var seen: usize = 0;
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |part| {
            if (seen == 3) return null;
            if (part.len == 0) return null;
            for (part) |c| if (c < '0' or c > '9') return null;
            const n = std.fmt.parseInt(u32, part, 10) catch return null;
            parts[seen] = n;
            seen += 1;
        }
        if (seen != 3) return null;
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    /// Order: -1 if a<b, 0 if equal, +1 if a>b.
    pub fn cmp(a: SemVer, b: SemVer) i2 {
        if (a.major != b.major) return if (a.major < b.major) -1 else 1;
        if (a.minor != b.minor) return if (a.minor < b.minor) -1 else 1;
        if (a.patch != b.patch) return if (a.patch < b.patch) -1 else 1;
        return 0;
    }
};

/// One rewrite rule. `from_version == null` is treated as a wildcard
/// — any version of the matching `(ns, pkg)` is rewritten to
/// `to_version`. `iface` is null to apply to every interface within
/// the package (the common case — the wasi patch-compat contract is
/// per-package, not per-interface).
pub const Rule = struct {
    ns: []const u8,
    pkg: []const u8,
    /// Optional iface filter. `null` matches every iface in `pkg`.
    iface: ?[]const u8 = null,
    /// Optional source-version filter. `null` matches every version.
    from_version: ?[]const u8 = null,
    to_version: []const u8,
};

/// Apply the first matching rule to `name`. Returns either an
/// arena-allocated rewritten copy or `name` unchanged when no rule
/// matches. The returned slice may alias `name`; callers must not
/// mutate it.
pub fn rewrite(arena: std.mem.Allocator, name: []const u8, rules: []const Rule) ![]const u8 {
    const parts = parse(name) orelse return name;
    const cur_ver = parts.version orelse return name;

    for (rules) |rule| {
        if (!std.mem.eql(u8, rule.ns, parts.ns)) continue;
        if (!std.mem.eql(u8, rule.pkg, parts.pkg)) continue;
        if (rule.iface) |want_iface| {
            if (!std.mem.eql(u8, want_iface, parts.iface)) continue;
        }
        if (rule.from_version) |want_ver| {
            if (!std.mem.eql(u8, want_ver, cur_ver)) continue;
        }
        if (std.mem.eql(u8, rule.to_version, cur_ver)) return name;

        const prefix_len = name.len - cur_ver.len;
        var buf = try arena.alloc(u8, prefix_len + rule.to_version.len);
        @memcpy(buf[0..prefix_len], name[0..prefix_len]);
        @memcpy(buf[prefix_len..], rule.to_version);
        return buf;
    }
    return name;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse: standard wasi-style name with version" {
    const p = parse("wasi:io/error@0.2.6").?;
    try testing.expectEqualStrings("wasi", p.ns);
    try testing.expectEqualStrings("io", p.pkg);
    try testing.expectEqualStrings("error", p.iface);
    try testing.expectEqualStrings("0.2.6", p.version.?);
}

test "parse: multi-segment iface preserved verbatim" {
    const p = parse("wasi:http/incoming-handler@0.2.10").?;
    try testing.expectEqualStrings("incoming-handler", p.iface);
    try testing.expectEqualStrings("0.2.10", p.version.?);
}

test "parse: no version yields null version" {
    const p = parse("wasi:cli/stdout").?;
    try testing.expect(p.version == null);
    try testing.expectEqualStrings("stdout", p.iface);
}

test "parse: no namespace prefix" {
    const p = parse("docs:adder/add@0.1.0").?;
    try testing.expectEqualStrings("docs", p.ns);

    const q = parse("pkg/iface@1.0.0").?;
    try testing.expectEqualStrings("", q.ns);
    try testing.expectEqualStrings("pkg", q.pkg);
    try testing.expectEqualStrings("iface", q.iface);
    try testing.expectEqualStrings("1.0.0", q.version.?);
}

test "parse: rejects malformed names" {
    try testing.expect(parse("") == null);
    try testing.expect(parse("no-slash") == null);
    try testing.expect(parse("ns:") == null);
    try testing.expect(parse("ns:pkg") == null);
    try testing.expect(parse("/iface") == null);
    try testing.expect(parse("pkg/") == null);
    try testing.expect(parse("pkg/iface@") == null);
    try testing.expect(parse("pkg/@1.0.0") == null);
}

test "SemVer.parse + cmp: 0.2.6 < 0.2.10" {
    const a = SemVer.parse("0.2.6").?;
    const b = SemVer.parse("0.2.10").?;
    try testing.expectEqual(@as(i2, -1), a.cmp(b));
    try testing.expectEqual(@as(i2, 1), b.cmp(a));
    try testing.expectEqual(@as(i2, 0), a.cmp(a));
}

test "SemVer.parse: rejects malformed" {
    try testing.expect(SemVer.parse("") == null);
    try testing.expect(SemVer.parse("1.2") == null);
    try testing.expect(SemVer.parse("1.2.3.4") == null);
    try testing.expect(SemVer.parse("1.2.x") == null);
    try testing.expect(SemVer.parse("1..3") == null);
    try testing.expect(SemVer.parse("-1.2.3") == null);
}

test "rewrite: matching rule replaces version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try rewrite(arena.allocator(), "wasi:io/error@0.2.10", &rules);
    try testing.expectEqualStrings("wasi:io/error@0.2.6", out);
}

test "rewrite: iface filter scopes the substitution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .iface = "streams", .to_version = "0.2.6" },
    };
    try testing.expectEqualStrings(
        "wasi:io/streams@0.2.6",
        try rewrite(arena.allocator(), "wasi:io/streams@0.2.10", &rules),
    );
    try testing.expectEqualStrings(
        "wasi:io/error@0.2.10",
        try rewrite(arena.allocator(), "wasi:io/error@0.2.10", &rules),
    );
}

test "rewrite: from_version filter scopes by source version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .from_version = "0.2.10", .to_version = "0.2.6" },
    };
    try testing.expectEqualStrings(
        "wasi:io/error@0.2.6",
        try rewrite(arena.allocator(), "wasi:io/error@0.2.10", &rules),
    );
    try testing.expectEqualStrings(
        "wasi:io/error@0.2.8",
        try rewrite(arena.allocator(), "wasi:io/error@0.2.8", &rules),
    );
}

test "rewrite: no matching rule returns input unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const in = "wasi:cli/stdout@0.2.10";
    const out = try rewrite(arena.allocator(), in, &rules);
    try testing.expectEqualStrings(in, out);
    try testing.expectEqual(in.ptr, out.ptr);
}

test "rewrite: unversioned name passes through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const in = "wasi:io/error";
    const out = try rewrite(arena.allocator(), in, &rules);
    try testing.expectEqualStrings(in, out);
    try testing.expectEqual(in.ptr, out.ptr);
}

test "rewrite: target == current is a no-op (no alloc)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const in = "wasi:io/error@0.2.6";
    const out = try rewrite(arena.allocator(), in, &rules);
    try testing.expectEqual(in.ptr, out.ptr);
}

test "rewrite: extends the encoded name length (0.2.6 -> 0.2.10)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rules = [_]Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.10" },
    };
    const out = try rewrite(arena.allocator(), "wasi:io/error@0.2.6", &rules);
    try testing.expectEqualStrings("wasi:io/error@0.2.10", out);
}
