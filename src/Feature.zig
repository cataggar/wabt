//! WebAssembly feature flags.
//!
//! Controls which WebAssembly proposals are enabled during parsing
//! and validation. Mirrors the feature set from the C++ implementation.

const std = @import("std");

/// Feature flag set. Each field corresponds to a WebAssembly proposal.
pub const Set = packed struct {
    exceptions: bool = false,
    mutable_globals: bool = true,
    saturating_float_to_int: bool = true,
    sign_extension: bool = true,
    simd: bool = true,
    threads: bool = false,
    multi_value: bool = true,
    tail_call: bool = false,
    bulk_memory: bool = true,
    reference_types: bool = true,
    annotations: bool = false,
    gc: bool = false,
    memory64: bool = false,
    extended_const: bool = false,
    relaxed_simd: bool = false,
    function_references: bool = false,

    pub const mvp = Set{};
    pub const all = Set{
        .exceptions = true,
        .threads = true,
        .tail_call = true,
        .annotations = true,
        .gc = true,
        .memory64 = true,
        .extended_const = true,
        .relaxed_simd = true,
        .function_references = true,
    };
};

test "default features" {
    const defaults = Set{};
    try std.testing.expect(defaults.multi_value);
    try std.testing.expect(defaults.bulk_memory);
    try std.testing.expect(!defaults.gc);
}
