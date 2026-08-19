const std = @import("std");
const wabt = @import("wabt");

pub const Failure = struct {
    kind: Kind,
    selector: []const u8,

    pub const Kind = enum {
        empty,
        unknown,
    };
};

/// Apply comma-separated feature selectors from left to right.
///
/// Feature names use CLI-style kebab case. A leading `-` disables a feature;
/// `all` and `-all` set every feature at once.
pub fn apply(set: *wabt.Feature.Set, selectors: []const u8) ?Failure {
    var parts = std.mem.splitScalar(u8, selectors, ',');
    while (parts.next()) |selector| {
        if (selector.len == 0)
            return .{ .kind = .empty, .selector = selector };

        const enabled = selector[0] != '-';
        const name = if (enabled) selector else selector[1..];
        if (name.len == 0)
            return .{ .kind = .empty, .selector = selector };

        if (std.mem.eql(u8, name, "all")) {
            setAll(set, enabled);
        } else if (!setNamed(set, name, enabled)) {
            return .{ .kind = .unknown, .selector = selector };
        }
    }
    return null;
}

pub fn reportFailure(failure: Failure) void {
    switch (failure.kind) {
        .empty => std.debug.print(
            "error: empty feature selector in --features; expected feature, -feature, all, or -all\n",
            .{},
        ),
        .unknown => std.debug.print(
            "error: unknown feature selector '{s}' in --features\n",
            .{failure.selector},
        ),
    }
}

fn setAll(set: *wabt.Feature.Set, enabled: bool) void {
    inline for (std.meta.fields(wabt.Feature.Set)) |field| {
        @field(set, field.name) = enabled;
    }
}

fn setNamed(set: *wabt.Feature.Set, name: []const u8, enabled: bool) bool {
    inline for (std.meta.fields(wabt.Feature.Set)) |field| {
        if (cliNameEql(name, field.name)) {
            @field(set, field.name) = enabled;
            return true;
        }
    }
    return false;
}

fn cliNameEql(cli_name: []const u8, field_name: []const u8) bool {
    if (cli_name.len != field_name.len) return false;
    for (cli_name, field_name) |cli_char, field_char| {
        const expected = if (field_char == '_') '-' else field_char;
        if (cli_char != expected) return false;
    }
    return true;
}

test "feature selectors use kebab case and preserve order" {
    var features = wabt.Feature.Set{};
    try std.testing.expectEqual(
        @as(?Failure, null),
        apply(&features, "-all,simd,wide-arithmetic,-simd"),
    );
    try std.testing.expect(!features.exceptions);
    try std.testing.expect(!features.simd);
    try std.testing.expect(features.wide_arithmetic);
}

test "feature selectors allow duplicates and last selector wins" {
    var features = wabt.Feature.Set{};
    try std.testing.expectEqual(
        @as(?Failure, null),
        apply(&features, "-gc,gc,-gc"),
    );
    try std.testing.expect(!features.gc);

    try std.testing.expectEqual(@as(?Failure, null), apply(&features, "all,-all"));
    inline for (std.meta.fields(wabt.Feature.Set)) |field| {
        try std.testing.expect(!@field(features, field.name));
    }
}

test "feature selectors reject unknown and empty tokens" {
    var features = wabt.Feature.Set{};
    const unknown = apply(&features, "simd,no-such-feature").?;
    try std.testing.expectEqual(Failure.Kind.unknown, unknown.kind);
    try std.testing.expectEqualStrings("no-such-feature", unknown.selector);

    const empty_middle = apply(&features, "simd,,gc").?;
    try std.testing.expectEqual(Failure.Kind.empty, empty_middle.kind);
    const empty_name = apply(&features, "-").?;
    try std.testing.expectEqual(Failure.Kind.empty, empty_name.kind);
}
