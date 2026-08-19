const std = @import("std");

const corpus_json = @embedFile("fixtures/cross-feature-regression/corpus.json");

const Variant = struct {
    features: []const u8,
    wasm_tools_features: ?[]const u8 = null,
    expected_exit: u8,
};

const WatCase = struct {
    name: []const u8,
    surface: []const u8,
    wat: []const u8,
    variants: []const Variant,
};

const InvalidWatCase = struct {
    name: []const u8,
    surface: []const u8,
    failure_kind: []const u8,
    features: []const u8,
    expected_exit: u8,
    wat: []const u8,
};

const BinaryCase = struct {
    name: []const u8,
    surface: []const u8,
    failure_kind: []const u8,
    features: []const u8,
    expected_exit: u8,
    hex: []const u8,
};

const Corpus = struct {
    version: u32,
    wat_cases: []const WatCase,
    invalid_wat_cases: []const InvalidWatCase,
    binary_cases: []const BinaryCase,
};

test "cross-feature corpus has valid unique cases and every required surface" {
    const parsed = try std.json.parseFromSlice(
        Corpus,
        std.testing.allocator,
        corpus_json,
        .{},
    );
    defer parsed.deinit();
    const corpus = parsed.value;

    try std.testing.expectEqual(@as(u32, 1), corpus.version);
    try std.testing.expect(corpus.wat_cases.len > 0);
    try std.testing.expect(corpus.invalid_wat_cases.len > 0);
    try std.testing.expect(corpus.binary_cases.len > 0);

    var names = std.StringHashMap(void).init(std.testing.allocator);
    defer names.deinit();
    var surfaces = std.StringHashMap(void).init(std.testing.allocator);
    defer surfaces.deinit();
    const Statuses = struct { accepted: bool = false, rejected: bool = false };
    var statuses = std.StringHashMap(Statuses).init(std.testing.allocator);
    defer statuses.deinit();
    var saw_malformed = false;
    var saw_truncated = false;
    var saw_raw_dependency_combination = false;

    for (corpus.wat_cases) |case| {
        try addCase(&names, &surfaces, case.name, case.surface);
        try std.testing.expect(case.wat.len > 0);
        try std.testing.expect(case.variants.len > 0);
        for (case.variants) |variant| {
            try std.testing.expect(variant.features.len > 0);
            try expectExitStatus(variant.expected_exit);
            const status = try statuses.getOrPut(case.surface);
            if (!status.found_existing) status.value_ptr.* = .{};
            if (variant.expected_exit == 0) {
                status.value_ptr.accepted = true;
            } else {
                status.value_ptr.rejected = true;
            }
            if (std.mem.eql(u8, case.surface, "dependency") and
                hasDisabledSelector(variant.features))
            {
                saw_raw_dependency_combination = true;
            }
        }
    }
    for (corpus.invalid_wat_cases) |case| {
        try addCase(&names, &surfaces, case.name, case.surface);
        try std.testing.expect(case.features.len > 0);
        try std.testing.expect(case.wat.len > 0);
        try std.testing.expect(recordFailureKind(
            case.failure_kind,
            &saw_malformed,
            &saw_truncated,
        ));
        try expectExitStatus(case.expected_exit);
    }
    for (corpus.binary_cases) |case| {
        try addCase(&names, &surfaces, case.name, case.surface);
        try std.testing.expect(case.features.len > 0);
        try std.testing.expect(case.hex.len > 0 and case.hex.len % 2 == 0);
        try std.testing.expect(recordFailureKind(
            case.failure_kind,
            &saw_malformed,
            &saw_truncated,
        ));
        const bytes = try std.testing.allocator.alloc(u8, case.hex.len / 2);
        defer std.testing.allocator.free(bytes);
        _ = try std.fmt.hexToBytes(bytes, case.hex);
        try expectExitStatus(case.expected_exit);
    }

    for (&[_][]const u8{ "body", "constant", "declaration", "dependency", "malformed" }) |surface| {
        try std.testing.expect(surfaces.contains(surface));
    }
    for (&[_][]const u8{ "body", "constant", "declaration", "dependency" }) |surface| {
        const status = statuses.get(surface).?;
        try std.testing.expect(status.accepted and status.rejected);
    }
    try std.testing.expect(saw_raw_dependency_combination);
    try std.testing.expect(saw_malformed);
    try std.testing.expect(saw_truncated);
}

fn addCase(
    names: *std.StringHashMap(void),
    surfaces: *std.StringHashMap(void),
    name: []const u8,
    surface: []const u8,
) !void {
    try std.testing.expect(name.len > 0);
    try std.testing.expect(surface.len > 0);
    const result = try names.getOrPut(name);
    try std.testing.expect(!result.found_existing);
    try surfaces.put(surface, {});
}

fn expectExitStatus(status: u8) !void {
    try std.testing.expect(status == 0 or status == 1);
}

fn hasDisabledSelector(selectors: []const u8) bool {
    var parts = std.mem.splitScalar(u8, selectors, ',');
    while (parts.next()) |selector| {
        if (selector.len > 1 and selector[0] == '-') return true;
    }
    return false;
}

fn recordFailureKind(
    kind: []const u8,
    saw_malformed: *bool,
    saw_truncated: *bool,
) bool {
    if (std.mem.eql(u8, kind, "malformed")) {
        saw_malformed.* = true;
        return true;
    }
    if (std.mem.eql(u8, kind, "truncated")) {
        saw_truncated.* = true;
        return true;
    }
    return false;
}
