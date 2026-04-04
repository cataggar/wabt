//! WebAssembly feature flags.
//!
//! Controls which WebAssembly proposals are enabled during parsing
//! and validation. Mirrors the feature set from wabt's feature.def
//! and the dependency logic from feature.cc.

const std = @import("std");

/// Feature flag set. Each field corresponds to a WebAssembly proposal.
/// Field order and defaults match wabt's feature.def.
pub const Set = packed struct {
    exceptions: bool = true,
    mutable_globals: bool = true,
    sat_float_to_int: bool = true,
    sign_extension: bool = true,
    simd: bool = true,
    threads: bool = true,
    function_references: bool = true,
    multi_value: bool = true,
    tail_call: bool = true,
    bulk_memory: bool = true,
    reference_types: bool = true,
    annotations: bool = true,
    code_metadata: bool = false,
    gc: bool = true,
    memory64: bool = true,
    multi_memory: bool = false,
    extended_const: bool = true,
    relaxed_simd: bool = false,
    custom_page_sizes: bool = false,
    compact_imports: bool = false,
    wide_arithmetic: bool = false,

    const fields = @typeInfo(Set).@"struct".fields;

    /// Default feature set — features enabled by their default values.
    pub const mvp = Set{};

    /// All features enabled.
    pub const all = Set{
        .code_metadata = true,
        .multi_memory = true,
        .relaxed_simd = true,
        .custom_page_sizes = true,
        .compact_imports = true,
        .wide_arithmetic = true,
    };

    /// Enforce feature dependency chain from wabt's feature.cc:
    ///   exceptions        → reference_types
    ///   function_references → reference_types
    ///   gc                → function_references
    ///   reference_types   → bulk_memory
    pub fn updateDependencies(self: *Set) void {
        if (self.exceptions) self.reference_types = true;
        if (self.function_references) self.reference_types = true;
        if (self.gc) self.function_references = true;
        // Re-check after gc may have enabled function_references.
        if (self.function_references) self.reference_types = true;
        if (self.reference_types) self.bulk_memory = true;
    }

    /// Return a Set with every feature enabled.
    pub fn enableAll() Set {
        var s: Set = undefined;
        inline for (fields) |f| {
            @field(s, f.name) = true;
        }
        return s;
    }

    /// Check whether the named feature is at its default value.
    pub fn isDefault(self: Set, comptime feature: []const u8) bool {
        const default_val = comptime blk: {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, feature)) {
                    const ptr: *const bool = @ptrCast(f.default_value_ptr.?);
                    break :blk ptr.*;
                }
            }
            @compileError("unknown feature: " ++ feature);
        };
        return @field(self, feature) == default_val;
    }

    /// Count features whose current value differs from the default.
    pub fn count(self: Set) usize {
        var n: usize = 0;
        const defaults = Set{};
        inline for (fields) |f| {
            if (@field(self, f.name) != @field(defaults, f.name)) n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "default features" {
    const defaults = Set{};
    try std.testing.expect(defaults.mutable_globals);
    try std.testing.expect(defaults.sat_float_to_int);
    try std.testing.expect(defaults.sign_extension);
    try std.testing.expect(defaults.simd);
    try std.testing.expect(defaults.multi_value);
    try std.testing.expect(defaults.bulk_memory);
    try std.testing.expect(defaults.reference_types);
    try std.testing.expect(defaults.exceptions);
    try std.testing.expect(defaults.threads);
    try std.testing.expect(defaults.function_references);
    try std.testing.expect(defaults.tail_call);
    try std.testing.expect(defaults.annotations);
    try std.testing.expect(!defaults.code_metadata);
    try std.testing.expect(defaults.gc);
    try std.testing.expect(defaults.memory64);
    try std.testing.expect(!defaults.multi_memory);
    try std.testing.expect(defaults.extended_const);
    try std.testing.expect(!defaults.relaxed_simd);
    try std.testing.expect(!defaults.custom_page_sizes);
    try std.testing.expect(!defaults.compact_imports);
    try std.testing.expect(!defaults.wide_arithmetic);
}

test "updateDependencies cascades correctly" {
    // Enabling exceptions should pull in reference_types and bulk_memory.
    var s = Set{};
    s.reference_types = false;
    s.bulk_memory = false;
    s.exceptions = true;
    s.updateDependencies();
    try std.testing.expect(s.reference_types);
    try std.testing.expect(s.bulk_memory);

    // Enabling gc should pull in function_references → reference_types → bulk_memory.
    var g = Set{};
    g.reference_types = false;
    g.bulk_memory = false;
    g.function_references = false;
    g.gc = true;
    g.updateDependencies();
    try std.testing.expect(g.function_references);
    try std.testing.expect(g.reference_types);
    try std.testing.expect(g.bulk_memory);
}

test "enableAll enables every feature" {
    const a = Set.enableAll();
    try std.testing.expect(a.exceptions);
    try std.testing.expect(a.mutable_globals);
    try std.testing.expect(a.sat_float_to_int);
    try std.testing.expect(a.sign_extension);
    try std.testing.expect(a.simd);
    try std.testing.expect(a.threads);
    try std.testing.expect(a.function_references);
    try std.testing.expect(a.multi_value);
    try std.testing.expect(a.tail_call);
    try std.testing.expect(a.bulk_memory);
    try std.testing.expect(a.reference_types);
    try std.testing.expect(a.annotations);
    try std.testing.expect(a.code_metadata);
    try std.testing.expect(a.gc);
    try std.testing.expect(a.memory64);
    try std.testing.expect(a.multi_memory);
    try std.testing.expect(a.extended_const);
    try std.testing.expect(a.relaxed_simd);
    try std.testing.expect(a.custom_page_sizes);
    try std.testing.expect(a.compact_imports);
    try std.testing.expect(a.wide_arithmetic);
    // enableAll and the named constant should agree.
    try std.testing.expectEqual(Set.all, a);
}

test "count returns number of non-default features" {
    const defaults = Set{};
    try std.testing.expectEqual(@as(usize, 0), defaults.count());

    var s = Set{};
    s.exceptions = false; // default true → changed
    s.mutable_globals = false; // default true → changed
    try std.testing.expectEqual(@as(usize, 2), s.count());

    // all has 6 non-default features (the 6 still false/off by default).
    try std.testing.expectEqual(@as(usize, 6), Set.all.count());
}
