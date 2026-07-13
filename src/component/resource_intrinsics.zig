//! Shared handling for core canonical resource intrinsic field names.

const std = @import("std");
const wtypes = @import("../types.zig");
const ctypes = @import("types.zig");

pub const Kind = enum {
    drop,
    new,
    rep,

    /// The fixed core signature of this canonical resource intrinsic.
    pub fn coreSignature(self: Kind) CoreSignature {
        return .{
            .params = &one_i32,
            .results = if (self == .drop) &no_values else &one_i32,
        };
    }

    /// Validate a declared core function signature.
    pub fn validateCoreSignature(
        self: Kind,
        params: []const wtypes.ValType,
        results: []const wtypes.ValType,
    ) error{InvalidCoreSignature}!void {
        if (!self.coreSignature().matches(params, results))
            return error.InvalidCoreSignature;
    }

    /// Construct the canonical operation for a component resource type.
    pub fn canon(self: Kind, type_idx: u32) ctypes.Canon {
        return switch (self) {
            .drop => .{ .resource_drop = type_idx },
            .new => .{ .resource_new = type_idx },
            .rep => .{ .resource_rep = type_idx },
        };
    }
};

pub const Intrinsic = struct {
    kind: Kind,
    /// The field-name suffix following `[resource-{drop,new,rep}]`.
    resource: []const u8,
};

pub const CoreSignature = struct {
    params: []const wtypes.ValType,
    results: []const wtypes.ValType,

    pub fn matches(
        self: CoreSignature,
        params: []const wtypes.ValType,
        results: []const wtypes.ValType,
    ) bool {
        return std.mem.eql(wtypes.ValType, self.params, params) and
            std.mem.eql(wtypes.ValType, self.results, results);
    }
};

const one_i32 = [_]wtypes.ValType{.i32};
const no_values = [_]wtypes.ValType{};

/// Classify an exact canonical resource intrinsic prefix. The returned
/// resource suffix aliases `field`.
pub fn classify(field: []const u8) ?Intrinsic {
    const prefixes = [_]struct {
        name: []const u8,
        kind: Kind,
    }{
        .{ .name = "[resource-drop]", .kind = .drop },
        .{ .name = "[resource-new]", .kind = .new },
        .{ .name = "[resource-rep]", .kind = .rep },
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, field, prefix.name)) {
            return .{
                .kind = prefix.kind,
                .resource = field[prefix.name.len..],
            };
        }
    }
    return null;
}

test "classify canonical resource intrinsic fields" {
    const cases = [_]struct {
        field: []const u8,
        kind: Kind,
        resource: []const u8,
    }{
        .{ .field = "[resource-drop]input-stream", .kind = .drop, .resource = "input-stream" },
        .{ .field = "[resource-new]thing", .kind = .new, .resource = "thing" },
        .{ .field = "[resource-rep]thing", .kind = .rep, .resource = "thing" },
        .{ .field = "[resource-drop]", .kind = .drop, .resource = "" },
    };
    for (cases) |case| {
        const intrinsic = classify(case.field).?;
        try std.testing.expectEqual(case.kind, intrinsic.kind);
        try std.testing.expectEqualStrings(case.resource, intrinsic.resource);
    }

    try std.testing.expect(classify("[method]input-stream.read") == null);
    try std.testing.expect(classify("[resource-clone]thing") == null);
    try std.testing.expect(classify("resource-drop]thing") == null);
}

test "resource intrinsic signatures are fixed and validated" {
    const i32_values = [_]wtypes.ValType{.i32};
    const i64_values = [_]wtypes.ValType{.i64};

    try Kind.drop.validateCoreSignature(&i32_values, &.{});
    try Kind.new.validateCoreSignature(&i32_values, &i32_values);
    try Kind.rep.validateCoreSignature(&i32_values, &i32_values);
    try std.testing.expectError(
        error.InvalidCoreSignature,
        Kind.drop.validateCoreSignature(&i32_values, &i32_values),
    );
    try std.testing.expectError(
        error.InvalidCoreSignature,
        Kind.new.validateCoreSignature(&i64_values, &i32_values),
    );
}

test "resource intrinsic kinds construct canonical operations" {
    try std.testing.expectEqual(ctypes.Canon{ .resource_drop = 7 }, Kind.drop.canon(7));
    try std.testing.expectEqual(ctypes.Canon{ .resource_new = 8 }, Kind.new.canon(8));
    try std.testing.expectEqual(ctypes.Canon{ .resource_rep = 9 }, Kind.rep.canon(9));
}
