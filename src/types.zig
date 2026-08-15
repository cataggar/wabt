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
pub const one_byte_page_size: u32 = 1;

// ── Reference types ───────────────────────────────────────────────────────

pub const AbstractHeapType = enum(i32) {
    noexn = -0x0c,
    nofunc = -0x0d,
    noextern = -0x0e,
    none = -0x0f,
    func = -0x10,
    extern_ = -0x11,
    any = -0x12,
    eq = -0x13,
    i31 = -0x14,
    struct_ = -0x15,
    array = -0x16,
    exn = -0x17,

    pub fn fromCode(code: i64) ?AbstractHeapType {
        inline for (std.enums.values(AbstractHeapType)) |heap| {
            if (code == @intFromEnum(heap)) return heap;
        }
        return null;
    }

    pub fn nullableValType(self: AbstractHeapType) ValType {
        return switch (self) {
            .func => .funcref,
            .extern_ => .externref,
            .any => .anyref,
            .eq => .eqref,
            .i31 => .i31ref,
            .struct_ => .structref,
            .array => .arrayref,
            .exn => .exnref,
            .none => .nullref,
            .nofunc => .nullfuncref,
            .noextern => .nullexternref,
            .noexn => .nullexnref,
        };
    }

    pub fn nonNullableValType(self: AbstractHeapType) ValType {
        return switch (self) {
            .func => .ref_func,
            .extern_ => .ref_extern,
            .any => .ref_any,
            .eq => .ref_eq,
            .i31 => .ref_i31,
            .struct_ => .ref_struct,
            .array => .ref_array,
            .exn => .ref_exn,
            .none => .ref_none,
            .nofunc => .ref_nofunc,
            .noextern => .ref_noextern,
            .noexn => .ref_noexn,
        };
    }

    pub fn fromValType(vt: ValType) ?struct { nullable: bool, heap: AbstractHeapType } {
        return switch (vt) {
            .funcref => .{ .nullable = true, .heap = .func },
            .externref => .{ .nullable = true, .heap = .extern_ },
            .anyref => .{ .nullable = true, .heap = .any },
            .eqref => .{ .nullable = true, .heap = .eq },
            .i31ref => .{ .nullable = true, .heap = .i31 },
            .structref => .{ .nullable = true, .heap = .struct_ },
            .arrayref => .{ .nullable = true, .heap = .array },
            .exnref => .{ .nullable = true, .heap = .exn },
            .nullref => .{ .nullable = true, .heap = .none },
            .nullfuncref => .{ .nullable = true, .heap = .nofunc },
            .nullexternref => .{ .nullable = true, .heap = .noextern },
            .nullexnref => .{ .nullable = true, .heap = .noexn },
            .ref_func => .{ .nullable = false, .heap = .func },
            .ref_extern => .{ .nullable = false, .heap = .extern_ },
            .ref_any => .{ .nullable = false, .heap = .any },
            .ref_eq => .{ .nullable = false, .heap = .eq },
            .ref_i31 => .{ .nullable = false, .heap = .i31 },
            .ref_struct => .{ .nullable = false, .heap = .struct_ },
            .ref_array => .{ .nullable = false, .heap = .array },
            .ref_exn => .{ .nullable = false, .heap = .exn },
            .ref_none => .{ .nullable = false, .heap = .none },
            .ref_nofunc => .{ .nullable = false, .heap = .nofunc },
            .ref_noextern => .{ .nullable = false, .heap = .noextern },
            .ref_noexn => .{ .nullable = false, .heap = .noexn },
            else => null,
        };
    }
};

pub const HeapType = union(enum) {
    abstract: AbstractHeapType,
    concrete: u32,
};

pub const RefType = struct {
    nullable: bool,
    heap: HeapType,

    pub fn abstract(nullable: bool, heap: AbstractHeapType) RefType {
        return .{ .nullable = nullable, .heap = .{ .abstract = heap } };
    }

    pub fn concrete(nullable: bool, type_index: u32) RefType {
        return .{ .nullable = nullable, .heap = .{ .concrete = type_index } };
    }

    pub fn fromValType(vt: ValType) ?RefType {
        const abs = AbstractHeapType.fromValType(vt) orelse return switch (vt) {
            .concrete_ref => .concrete(false, invalid_index),
            .concrete_ref_null => .concrete(true, invalid_index),
            else => null,
        };
        return .abstract(abs.nullable, abs.heap);
    }

    pub fn fromValTypeAndIndex(vt: ValType, type_index: u32) ?RefType {
        if (type_index != invalid_index) {
            return switch (vt) {
                .concrete_ref => .concrete(false, type_index),
                .concrete_ref_null => .concrete(true, type_index),
                else => fromValType(vt),
            };
        }
        return fromValType(vt);
    }

    pub fn toValType(self: RefType) ValType {
        return switch (self.heap) {
            .abstract => |heap| if (self.nullable) heap.nullableValType() else heap.nonNullableValType(),
            .concrete => if (self.nullable) .concrete_ref_null else .concrete_ref,
        };
    }
};

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

    // GC packed types. Only valid as a struct field or array element type.
    i8 = 0x78,
    i16 = 0x77,

    // Reference types
    funcref = 0x70,
    externref = 0x6f,
    anyref = 0x6e,
    eqref = 0x6d,
    i31ref = 0x6c,
    structref = 0x6b,
    arrayref = 0x6a,
    exnref = 0x69,

    // Function signature marker
    func = 0x60,

    // GC composite types
    struct_ = 0x5f,
    array = 0x5e,

    // GC nullable bottom types (ref null <bottom>)
    nullfuncref = 0x73, // (ref null nofunc) — bottom of func hierarchy
    nullexternref = 0x72, // (ref null noextern) — bottom of extern hierarchy
    nullref = 0x71, // (ref null none) — bottom of internal hierarchy
    nullexnref = 0x74, // (ref null noexn) — bottom of exn hierarchy

    // Non-nullable abstract heap types (internal-only, not binary encoded)
    ref_func = -1, // (ref func) — non-nullable func
    ref_extern = -2, // (ref extern) — non-nullable extern
    ref_any = -3, // (ref any) — non-nullable any
    ref_none = -4, // (ref none) — non-nullable none (bottom)
    ref_nofunc = -5, // (ref nofunc) — non-nullable nofunc (bottom)
    ref_noextern = -6, // (ref noextern) — non-nullable noextern (bottom)
    ref_eq = -7, // (ref eq) — non-nullable eq
    ref_i31 = -8, // (ref i31) — non-nullable i31
    ref_struct = -9, // (ref struct) — non-nullable struct
    ref_array = -10, // (ref array) — non-nullable array
    ref_exn = -11, // (ref exn) — non-nullable exn
    ref_noexn = -12, // (ref noexn) — non-nullable noexn (bottom)
    concrete_ref = -13, // (ref <typeidx>) — type index stored out-of-line
    concrete_ref_null = -14, // (ref null <typeidx>) — type index stored out-of-line

    // Block void type
    void_ = 0x40,

    /// Returns `true` for reference types.
    pub fn isRefType(self: ValType) bool {
        return switch (self) {
            .funcref,
            .externref,
            .anyref,
            .eqref,
            .i31ref,
            .structref,
            .arrayref,
            .exnref,
            .nullfuncref,
            .nullexternref,
            .nullref,
            .nullexnref,
            .ref_func,
            .ref_extern,
            .ref_any,
            .ref_eq,
            .ref_i31,
            .ref_struct,
            .ref_array,
            .ref_none,
            .ref_nofunc,
            .ref_noextern,
            .ref_exn,
            .ref_noexn,
            .concrete_ref,
            .concrete_ref_null,
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

    /// Returns `true` for the GC packed types. These are storage types, not
    /// value types: they are legal only as a struct field or array element,
    /// and widen to `i32` when read.
    pub fn isPackedType(self: ValType) bool {
        return switch (self) {
            .i8, .i16 => true,
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
            .eqref => "eqref",
            .i31ref => "i31ref",
            .structref => "structref",
            .arrayref => "arrayref",
            .func => "func",
            .struct_ => "struct",
            .array => "array",
            .void_ => "void",
            .nullfuncref => "nullfuncref",
            .nullexternref => "nullexternref",
            .nullref => "nullref",
            .nullexnref => "nullexnref",
            .ref_func => "(ref func)",
            .ref_extern => "(ref extern)",
            .ref_any => "(ref any)",
            .ref_none => "(ref none)",
            .ref_nofunc => "(ref nofunc)",
            .ref_noextern => "(ref noextern)",
            .ref_eq => "(ref eq)",
            .ref_i31 => "(ref i31)",
            .ref_struct => "(ref struct)",
            .ref_array => "(ref array)",
            .ref_exn => "(ref exn)",
            .ref_noexn => "(ref noexn)",
            .concrete_ref => "(ref <typeidx>)",
            .concrete_ref_null => "(ref null <typeidx>)",
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
    /// Whether the custom-page-size flag was present. This remains distinct
    /// from `page_size` because explicitly stating 64 KiB is observable.
    has_page_size: bool = false,

    /// Returns `.i64` when the `memory64` proposal is in effect, `.i32`
    /// otherwise.
    pub fn indexType(self: Limits) ValType {
        return if (self.is_64) .i64 else .i32;
    }

    pub fn usesCustomPageSize(self: Limits) bool {
        return self.has_page_size or self.page_size != default_page_size;
    }
};

/// The current custom-page-sizes proposal admits only 1-byte and 64-KiB
/// pages. Return the binary exponent only for those exact values.
pub fn memoryPageSizeLog2(page_size: u32) ?u32 {
    return switch (page_size) {
        one_byte_page_size => 0,
        default_page_size => 16,
        else => null,
    };
}

/// Maximum encodable page count whose byte length fits the memory's address
/// space. The one-byte case is capped by the limits field's integer width.
pub fn memoryMaxPages(is_64: bool, page_size: u32) ?u64 {
    if (memoryPageSizeLog2(page_size) == null) return null;
    const max_count: u64 = if (is_64) std.math.maxInt(u64) else std.math.maxInt(u32);
    if (page_size == one_byte_page_size) return max_count;
    return max_count / page_size + 1;
}

// ── Composite types ──────────────────────────────────────────────────────

/// Function signature: parameter and result types.
pub const FuncType = struct {
    params: []const ValType = &.{},
    results: []const ValType = &.{},
    /// Concrete type indices parallel to params (0xFFFFFFFF = abstract).
    param_type_idxs: []const u32 = &.{},
    /// Concrete type indices parallel to results (0xFFFFFFFF = abstract).
    result_type_idxs: []const u32 = &.{},
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

/// Every `ValType` member with a binary encoding, paired with the byte the
/// WebAssembly spec assigns to it. Each byte is the one-byte s33 LEB128 form
/// of the type's negative code (e.g. `none` is `-0x0f`, encoded `0x71`).
const spec_valtype_bytes = [_]struct { ValType, u8 }{
    // Numeric types
    .{ .i32, 0x7f },
    .{ .i64, 0x7e },
    .{ .f32, 0x7d },
    .{ .f64, 0x7c },
    .{ .v128, 0x7b },
    // GC packed types
    .{ .i8, 0x78 },
    .{ .i16, 0x77 },
    // Nullable abstract reference types (shorthands for `(ref null <heap>)`)
    .{ .nullexnref, 0x74 }, // noexn    = -0x0c
    .{ .nullfuncref, 0x73 }, // nofunc   = -0x0d
    .{ .nullexternref, 0x72 }, // noextern = -0x0e
    .{ .nullref, 0x71 }, // none     = -0x0f
    .{ .funcref, 0x70 }, // func     = -0x10
    .{ .externref, 0x6f }, // extern   = -0x11
    .{ .anyref, 0x6e }, // any      = -0x12
    .{ .eqref, 0x6d }, // eq       = -0x13
    .{ .i31ref, 0x6c }, // i31      = -0x14
    .{ .structref, 0x6b }, // struct   = -0x15
    .{ .arrayref, 0x6a }, // array    = -0x16
    .{ .exnref, 0x69 }, // exn      = -0x17
    // Composite type forms
    .{ .func, 0x60 },
    .{ .struct_, 0x5f },
    .{ .array, 0x5e },
    // Empty block type
    .{ .void_, 0x40 },
};

// Drift guard: locks every binary-encoded `ValType` to its spec byte, proves
// the bytes are distinct, and proves the table is exhaustive over the members
// that have a binary encoding. A type added to `ValType` without a spec byte
// here fails this test instead of silently colliding with an unrelated type.
test "ValType binary encodings match the spec" {
    var seen_bytes = [_]bool{false} ** 256;
    for (spec_valtype_bytes) |entry| {
        const vt, const byte = entry;
        try std.testing.expectEqual(@as(i32, byte), @intFromEnum(vt));
        try std.testing.expect(!seen_bytes[byte]);
        seen_bytes[byte] = true;
    }

    // Exhaustiveness: every member is either in the table above or is an
    // internal-only marker, which must be negative so it can never be
    // confused with a byte read from a binary.
    inline for (@typeInfo(ValType).@"enum".fields) |field| {
        const vt: ValType = @enumFromInt(field.value);
        var in_table = false;
        for (spec_valtype_bytes) |entry| {
            if (entry[0] == vt) in_table = true;
        }
        if (!in_table) try std.testing.expect(field.value < 0);
    }
}

test "Limits.indexType" {
    const lim32 = Limits{};
    try std.testing.expectEqual(ValType.i32, lim32.indexType());

    const lim64 = Limits{ .is_64 = true };
    try std.testing.expectEqual(ValType.i64, lim64.indexType());
}

test "custom memory page-size domain and address-space bounds" {
    try std.testing.expectEqual(@as(?u32, 0), memoryPageSizeLog2(1));
    try std.testing.expectEqual(@as(?u32, 16), memoryPageSizeLog2(65536));
    try std.testing.expectEqual(@as(?u32, null), memoryPageSizeLog2(0));
    try std.testing.expectEqual(@as(?u32, null), memoryPageSizeLog2(2));
    try std.testing.expectEqual(@as(?u32, null), memoryPageSizeLog2(3));
    try std.testing.expectEqual(@as(?u32, null), memoryPageSizeLog2(32768));
    try std.testing.expectEqual(@as(?u32, null), memoryPageSizeLog2(131072));

    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u32)), memoryMaxPages(false, 1));
    try std.testing.expectEqual(@as(?u64, 1 << 16), memoryMaxPages(false, 65536));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), memoryMaxPages(true, 1));
    try std.testing.expectEqual(@as(?u64, 1 << 48), memoryMaxPages(true, 65536));
    try std.testing.expectEqual(@as(?u64, null), memoryMaxPages(false, 3));

    try std.testing.expect(!(Limits{}).usesCustomPageSize());
    try std.testing.expect((Limits{ .page_size = 1 }).usesCustomPageSize());
    try std.testing.expect((Limits{ .has_page_size = true }).usesCustomPageSize());
}

test "ValType.isRefType" {
    try std.testing.expect(ValType.funcref.isRefType());
    try std.testing.expect(ValType.externref.isRefType());
    try std.testing.expect(ValType.anyref.isRefType());
    try std.testing.expect(ValType.exnref.isRefType());
    try std.testing.expect(ValType.concrete_ref.isRefType());
    try std.testing.expect(ValType.concrete_ref_null.isRefType());

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

test "RefType carries abstract and concrete heap types" {
    const nullable_func = RefType.abstract(true, .func);
    try std.testing.expectEqual(ValType.funcref, nullable_func.toValType());

    const concrete = RefType.concrete(true, 7);
    try std.testing.expectEqual(ValType.concrete_ref_null, concrete.toValType());
    try std.testing.expectEqual(@as(u32, 7), concrete.heap.concrete);
    try std.testing.expectEqual(
        @as(i32, -0x10),
        @intFromEnum((RefType.fromValType(.ref_func) orelse unreachable).heap.abstract),
    );
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
