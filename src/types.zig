//! Core WebAssembly types.
//!
//! Value types, reference types, function signatures, limits,
//! memory/table/global types, import/export descriptors, and
//! related enumerations matching the wabt C++ headers (type.h).

const std = @import("std");

// ── Type aliases ──────────────────────────────────────────────────────────

pub const Index = u32;
pub const Address = u64;
pub const Offset = usize;

pub const invalid_index: Index = std.math.maxInt(Index);
pub const invalid_address: Address = std.math.maxInt(Address);
pub const invalid_offset: Offset = std.math.maxInt(Offset);
pub const default_page_size: u32 = 0x10000; // 64 KiB

// ── Value types ───────────────────────────────────────────────────────────

/// WebAssembly value types using the binary-format encoding (signed LEB128
/// compatible).  The discriminant values match wabt's `Type` enum from
/// `type.h`.
pub const ValType = enum(i32) {
    // Numeric types
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    v128 = 0x7b,

    // GC packed types
    i8 = 0x7a,
    i16 = 0x79,

    // Reference types
    funcref = 0x70,
    externref = 0x6f,
    anyref = 0x6e,
    exnref = 0x69,

    // Typed references (GC proposal)
    ref = 0x64,
    ref_null = 0x63,

    // Function signature marker
    func = 0x60,

    // GC composite types
    struct_ = 0x5f,
    array = 0x5e,

    // GC nullable bottom types (ref null <bottom>)
    nullfuncref = 0x73,   // (ref null nofunc) — bottom of func hierarchy
    nullexternref = 0x72, // (ref null noextern) — bottom of extern hierarchy
    nullref = 0x71,       // (ref null none) — bottom of internal hierarchy
    nullexnref = 0x68,    // (ref null noexn) — bottom of exn hierarchy

    // Non-nullable abstract heap types (internal-only, not binary encoded)
    ref_func = -1,     // (ref func) — non-nullable func
    ref_extern = -2,   // (ref extern) — non-nullable extern
    ref_any = -3,      // (ref any) — non-nullable any
    ref_none = -4,     // (ref none) — non-nullable none (bottom)
    ref_nofunc = -5,   // (ref nofunc) — non-nullable nofunc (bottom)
    ref_noextern = -6, // (ref noextern) — non-nullable noextern (bottom)

    // Block void type
    void_ = 0x40,

    /// Returns `true` for reference types (funcref, externref, anyref,
    /// exnref, ref, ref_null).
    pub fn isRefType(self: ValType) bool {
        return switch (self) {
            .funcref, .externref, .anyref, .exnref, .ref, .ref_null,
            .nullfuncref, .nullexternref, .nullref, .nullexnref,
            .ref_func, .ref_extern, .ref_any, .ref_none, .ref_nofunc, .ref_noextern,
            => true,
            else => false,
        };
    }

    /// Returns `true` for numeric types (i32, i64, f32, f64, v128).
    pub fn isNumType(self: ValType) bool {
        return switch (self) {
            .i32, .i64, .f32, .f64, .v128 => true,
            else => false,
        };
    }

    /// Returns a human-readable name for the value type.
    pub fn name(self: ValType) []const u8 {
        return switch (self) {
            .i32 => "i32",
            .i64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
            .v128 => "v128",
            .i8 => "i8",
            .i16 => "i16",
            .funcref => "funcref",
            .externref => "externref",
            .anyref => "anyref",
            .exnref => "exnref",
            .ref => "ref",
            .ref_null => "ref_null",
            .func => "func",
            .struct_ => "struct",
            .array => "array",
            .void_ => "void",
        };
    }
};

// ── Limits ────────────────────────────────────────────────────────────────

/// Limits describe size constraints for memories and tables.
pub const Limits = struct {
    initial: u64 = 0,
    max: u64 = 0,
    has_max: bool = false,
    is_shared: bool = false,
    is_64: bool = false,
    page_size: u32 = default_page_size,

    /// Returns `.i64` when the `memory64` proposal is in effect, `.i32`
    /// otherwise.
    pub fn indexType(self: Limits) ValType {
        return if (self.is_64) .i64 else .i32;
    }
};

// ── Composite types ──────────────────────────────────────────────────────

/// Function signature: parameter and result types.
pub const FuncType = struct {
    params: []const ValType = &.{},
    results: []const ValType = &.{},
};

/// Memory type.
pub const MemoryType = struct {
    limits: Limits = .{},
};

/// Table type.
pub const TableType = struct {
    elem_type: ValType = .funcref,
    limits: Limits = .{},
};

/// Mutability of a global.
pub const Mutability = enum { immutable, mutable };

/// Global type.
pub const GlobalType = struct {
    val_type: ValType = .i32,
    mutability: Mutability = .immutable,
};

/// Tag type (exception-handling proposal).
pub const TagType = struct {
    sig: FuncType = .{},
};

// ── External / Import / Export kinds ─────────────────────────────────────

/// External kind identifiers used in the import/export sections.
pub const ExternalKind = enum(u8) {
    func = 0,
    table = 1,
    memory = 2,
    global = 3,
    tag = 4,
};

// ── Label types ──────────────────────────────────────────────────────────

/// Structured-control-flow label types used during validation.
pub const LabelType = enum {
    func,
    init_expr,
    block,
    loop,
    if_,
    else_,
    try_,
    try_table,
    catch_,
};

// ── Data / Element segment helpers ───────────────────────────────────────

/// Whether a data or element segment is active, passive, or declared.
pub const SegmentKind = enum {
    active,
    passive,
    declared,
};

/// Bit-flags carried by the segment prefix byte in the binary format.
pub const SegmentFlags = packed struct(u8) {
    passive: bool = false,
    explicit_index: bool = false,
    use_elem_exprs: bool = false,
    _padding: u5 = 0,
};

// ── Exception-handling helpers ───────────────────────────────────────────

/// Catch clause kind used by `try_table`.
pub const CatchKind = enum {
    catch_,
    catch_ref,
    catch_all,
    catch_all_ref,
};

// ── Tests ─────────────────────────────────────────────────────────────────

test "ValType encoding" {
    try std.testing.expectEqual(@as(i32, 0x7f), @intFromEnum(ValType.i32));
    try std.testing.expectEqual(@as(i32, 0x7e), @intFromEnum(ValType.i64));
    try std.testing.expectEqual(@as(i32, 0x7d), @intFromEnum(ValType.f32));
    try std.testing.expectEqual(@as(i32, 0x7c), @intFromEnum(ValType.f64));
    try std.testing.expectEqual(@as(i32, 0x7b), @intFromEnum(ValType.v128));
    try std.testing.expectEqual(@as(i32, 0x70), @intFromEnum(ValType.funcref));
    try std.testing.expectEqual(@as(i32, 0x6f), @intFromEnum(ValType.externref));
    try std.testing.expectEqual(@as(i32, 0x6e), @intFromEnum(ValType.anyref));
    try std.testing.expectEqual(@as(i32, 0x69), @intFromEnum(ValType.exnref));
    try std.testing.expectEqual(@as(i32, 0x60), @intFromEnum(ValType.func));
    try std.testing.expectEqual(@as(i32, 0x40), @intFromEnum(ValType.void_));
}

test "Limits.indexType" {
    const lim32 = Limits{};
    try std.testing.expectEqual(ValType.i32, lim32.indexType());

    const lim64 = Limits{ .is_64 = true };
    try std.testing.expectEqual(ValType.i64, lim64.indexType());
}

test "ValType.isRefType" {
    try std.testing.expect(ValType.funcref.isRefType());
    try std.testing.expect(ValType.externref.isRefType());
    try std.testing.expect(ValType.anyref.isRefType());
    try std.testing.expect(ValType.exnref.isRefType());
    try std.testing.expect(ValType.ref.isRefType());
    try std.testing.expect(ValType.ref_null.isRefType());

    try std.testing.expect(!ValType.i32.isRefType());
    try std.testing.expect(!ValType.f64.isRefType());
    try std.testing.expect(!ValType.void_.isRefType());
}

test "ValType.isNumType" {
    try std.testing.expect(ValType.i32.isNumType());
    try std.testing.expect(ValType.i64.isNumType());
    try std.testing.expect(ValType.f32.isNumType());
    try std.testing.expect(ValType.f64.isNumType());
    try std.testing.expect(ValType.v128.isNumType());

    try std.testing.expect(!ValType.funcref.isNumType());
    try std.testing.expect(!ValType.void_.isNumType());
}

test "ValType.name" {
    try std.testing.expectEqualStrings("i32", ValType.i32.name());
    try std.testing.expectEqualStrings("funcref", ValType.funcref.name());
    try std.testing.expectEqualStrings("void", ValType.void_.name());
}

test "sentinel constants" {
    try std.testing.expectEqual(@as(Index, 0xFFFF_FFFF), invalid_index);
    try std.testing.expectEqual(@as(Address, 0xFFFF_FFFF_FFFF_FFFF), invalid_address);
    try std.testing.expectEqual(@as(u32, 0x10000), default_page_size);
}

test "SegmentFlags layout" {
    const flags = SegmentFlags{ .passive = true, .explicit_index = true };
    try std.testing.expectEqual(@as(u8, 0b011), @as(u8, @bitCast(flags)));
}
