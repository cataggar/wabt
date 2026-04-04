//! WebAssembly opcodes.
//!
//! Each opcode maps to a WebAssembly instruction. Multi-byte opcodes
//! use a prefix byte followed by a LEB128-encoded index. Single-byte
//! opcodes (0x00–0xFF) are stored directly; prefixed opcodes use
//! `(prefix << 8) | code` as the enum discriminant.

const std = @import("std");
const Feature = @import("Feature.zig");

// ── Prefix bytes ─────────────────────────────────────────────────────────

pub const prefix_math: u8 = 0xfc;
pub const prefix_simd: u8 = 0xfd;
pub const prefix_threads: u8 = 0xfe;

// ── Opcode enum ──────────────────────────────────────────────────────────

pub const Code = enum(u32) {
    // Control flow (0x00–0x1f)
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    @"if" = 0x04,
    @"else" = 0x05,
    try_ = 0x06,
    catch_ = 0x07,
    throw = 0x08,
    rethrow = 0x09,
    throw_ref = 0x0a,
    end = 0x0b,
    br = 0x0c,
    br_if = 0x0d,
    br_table = 0x0e,
    @"return" = 0x0f,
    call = 0x10,
    call_indirect = 0x11,
    return_call = 0x12,
    return_call_indirect = 0x13,
    call_ref = 0x14,
    return_call_ref = 0x15,
    delegate = 0x18,
    catch_all = 0x19,
    drop = 0x1a,
    select = 0x1b,
    select_t = 0x1c,
    try_table = 0x1f,

    // Variables (0x20–0x24)
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,

    // Table (0x25–0x26)
    table_get = 0x25,
    table_set = 0x26,

    // Memory load/store (0x28–0x3e)
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2a,
    f64_load = 0x2b,
    i32_load8_s = 0x2c,
    i32_load8_u = 0x2d,
    i32_load16_s = 0x2e,
    i32_load16_u = 0x2f,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3a,
    i32_store16 = 0x3b,
    i64_store8 = 0x3c,
    i64_store16 = 0x3d,
    i64_store32 = 0x3e,
    memory_size = 0x3f,
    memory_grow = 0x40,

    // Constants (0x41–0x44)
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // Comparison i32 (0x45–0x4f)
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4a,
    i32_gt_u = 0x4b,
    i32_le_s = 0x4c,
    i32_le_u = 0x4d,
    i32_ge_s = 0x4e,
    i32_ge_u = 0x4f,

    // Comparison i64 (0x50–0x5a)
    i64_eqz = 0x50,
    i64_eq = 0x51,
    i64_ne = 0x52,
    i64_lt_s = 0x53,
    i64_lt_u = 0x54,
    i64_gt_s = 0x55,
    i64_gt_u = 0x56,
    i64_le_s = 0x57,
    i64_le_u = 0x58,
    i64_ge_s = 0x59,
    i64_ge_u = 0x5a,

    // Comparison f32 (0x5b–0x60)
    f32_eq = 0x5b,
    f32_ne = 0x5c,
    f32_lt = 0x5d,
    f32_gt = 0x5e,
    f32_le = 0x5f,
    f32_ge = 0x60,

    // Comparison f64 (0x61–0x66)
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,

    // I32 arithmetic (0x67–0x78)
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6a,
    i32_sub = 0x6b,
    i32_mul = 0x6c,
    i32_div_s = 0x6d,
    i32_div_u = 0x6e,
    i32_rem_s = 0x6f,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,

    // I64 arithmetic (0x79–0x8a)
    i64_clz = 0x79,
    i64_ctz = 0x7a,
    i64_popcnt = 0x7b,
    i64_add = 0x7c,
    i64_sub = 0x7d,
    i64_mul = 0x7e,
    i64_div_s = 0x7f,
    i64_div_u = 0x80,
    i64_rem_s = 0x81,
    i64_rem_u = 0x82,
    i64_and = 0x83,
    i64_or = 0x84,
    i64_xor = 0x85,
    i64_shl = 0x86,
    i64_shr_s = 0x87,
    i64_shr_u = 0x88,
    i64_rotl = 0x89,
    i64_rotr = 0x8a,

    // F32 arithmetic (0x8b–0x98)
    f32_abs = 0x8b,
    f32_neg = 0x8c,
    f32_ceil = 0x8d,
    f32_floor = 0x8e,
    f32_trunc = 0x8f,
    f32_nearest = 0x90,
    f32_sqrt = 0x91,
    f32_add = 0x92,
    f32_sub = 0x93,
    f32_mul = 0x94,
    f32_div = 0x95,
    f32_min = 0x96,
    f32_max = 0x97,
    f32_copysign = 0x98,

    // F64 arithmetic (0x99–0xa6)
    f64_abs = 0x99,
    f64_neg = 0x9a,
    f64_ceil = 0x9b,
    f64_floor = 0x9c,
    f64_trunc = 0x9d,
    f64_nearest = 0x9e,
    f64_sqrt = 0x9f,
    f64_add = 0xa0,
    f64_sub = 0xa1,
    f64_mul = 0xa2,
    f64_div = 0xa3,
    f64_min = 0xa4,
    f64_max = 0xa5,
    f64_copysign = 0xa6,

    // Conversions (0xa7–0xbf)
    i32_wrap_i64 = 0xa7,
    i32_trunc_f32_s = 0xa8,
    i32_trunc_f32_u = 0xa9,
    i32_trunc_f64_s = 0xaa,
    i32_trunc_f64_u = 0xab,
    i64_extend_i32_s = 0xac,
    i64_extend_i32_u = 0xad,
    i64_trunc_f32_s = 0xae,
    i64_trunc_f32_u = 0xaf,
    i64_trunc_f64_s = 0xb0,
    i64_trunc_f64_u = 0xb1,
    f32_convert_i32_s = 0xb2,
    f32_convert_i32_u = 0xb3,
    f32_convert_i64_s = 0xb4,
    f32_convert_i64_u = 0xb5,
    f32_demote_f64 = 0xb6,
    f64_convert_i32_s = 0xb7,
    f64_convert_i32_u = 0xb8,
    f64_convert_i64_s = 0xb9,
    f64_convert_i64_u = 0xba,
    f64_promote_f32 = 0xbb,
    i32_reinterpret_f32 = 0xbc,
    i64_reinterpret_f64 = 0xbd,
    f32_reinterpret_i32 = 0xbe,
    f64_reinterpret_i64 = 0xbf,

    // Sign extension (0xc0–0xc4)
    i32_extend8_s = 0xc0,
    i32_extend16_s = 0xc1,
    i64_extend8_s = 0xc2,
    i64_extend16_s = 0xc3,
    i64_extend32_s = 0xc4,

    // Reference types (0xd0–0xd6)
    ref_null = 0xd0,
    ref_is_null = 0xd1,
    ref_func = 0xd2,
    ref_as_non_null = 0xd4,
    br_on_null = 0xd5,
    br_on_non_null = 0xd6,

    // -- Math prefix (0xfc << 8 | code) --

    // Saturating float-to-int
    i32_trunc_sat_f32_s = 0xfc00,
    i32_trunc_sat_f32_u = 0xfc01,
    i32_trunc_sat_f64_s = 0xfc02,
    i32_trunc_sat_f64_u = 0xfc03,
    i64_trunc_sat_f32_s = 0xfc04,
    i64_trunc_sat_f32_u = 0xfc05,
    i64_trunc_sat_f64_s = 0xfc06,
    i64_trunc_sat_f64_u = 0xfc07,

    // Bulk memory
    memory_init = 0xfc08,
    data_drop = 0xfc09,
    memory_copy = 0xfc0a,
    memory_fill = 0xfc0b,
    table_init = 0xfc0c,
    elem_drop = 0xfc0d,
    table_copy = 0xfc0e,

    // Reference types (table ops)
    table_grow = 0xfc0f,
    table_size = 0xfc10,
    table_fill = 0xfc11,

    // Wide arithmetic
    i64_add128 = 0xfc13,
    i64_sub128 = 0xfc14,
    i64_mul_wide_s = 0xfc15,
    i64_mul_wide_u = 0xfc16,

    // -- SIMD prefix (0xfd << 8 | code) --

    // SIMD load/store
    v128_load = 0xfd00,
    v128_load8x8_s = 0xfd01,
    v128_load8x8_u = 0xfd02,
    v128_load16x4_s = 0xfd03,
    v128_load16x4_u = 0xfd04,
    v128_load32x2_s = 0xfd05,
    v128_load32x2_u = 0xfd06,
    v128_load8_splat = 0xfd07,
    v128_load16_splat = 0xfd08,
    v128_load32_splat = 0xfd09,
    v128_load64_splat = 0xfd0a,
    v128_store = 0xfd0b,
    v128_const = 0xfd0c,

    // SIMD shuffle/swizzle/splat
    i8x16_shuffle = 0xfd0d,
    i8x16_swizzle = 0xfd0e,
    i8x16_splat = 0xfd0f,
    i16x8_splat = 0xfd10,
    i32x4_splat = 0xfd11,
    i64x2_splat = 0xfd12,
    f32x4_splat = 0xfd13,
    f64x2_splat = 0xfd14,

    // SIMD extract/replace lane
    i8x16_extract_lane_s = 0xfd15,
    i8x16_extract_lane_u = 0xfd16,
    i8x16_replace_lane = 0xfd17,
    i16x8_extract_lane_s = 0xfd18,
    i16x8_extract_lane_u = 0xfd19,
    i16x8_replace_lane = 0xfd1a,
    i32x4_extract_lane = 0xfd1b,
    i32x4_replace_lane = 0xfd1c,
    i64x2_extract_lane = 0xfd1d,
    i64x2_replace_lane = 0xfd1e,
    f32x4_extract_lane = 0xfd1f,
    f32x4_replace_lane = 0xfd20,
    f64x2_extract_lane = 0xfd21,
    f64x2_replace_lane = 0xfd22,

    // SIMD i8x16 comparison
    i8x16_eq = 0xfd23,
    i8x16_ne = 0xfd24,
    i8x16_lt_s = 0xfd25,
    i8x16_lt_u = 0xfd26,
    i8x16_gt_s = 0xfd27,
    i8x16_gt_u = 0xfd28,
    i8x16_le_s = 0xfd29,
    i8x16_le_u = 0xfd2a,
    i8x16_ge_s = 0xfd2b,
    i8x16_ge_u = 0xfd2c,

    // SIMD i16x8 comparison
    i16x8_eq = 0xfd2d,
    i16x8_ne = 0xfd2e,
    i16x8_lt_s = 0xfd2f,
    i16x8_lt_u = 0xfd30,
    i16x8_gt_s = 0xfd31,
    i16x8_gt_u = 0xfd32,
    i16x8_le_s = 0xfd33,
    i16x8_le_u = 0xfd34,
    i16x8_ge_s = 0xfd35,
    i16x8_ge_u = 0xfd36,

    // SIMD i32x4 comparison
    i32x4_eq = 0xfd37,
    i32x4_ne = 0xfd38,
    i32x4_lt_s = 0xfd39,
    i32x4_lt_u = 0xfd3a,
    i32x4_gt_s = 0xfd3b,
    i32x4_gt_u = 0xfd3c,
    i32x4_le_s = 0xfd3d,
    i32x4_le_u = 0xfd3e,
    i32x4_ge_s = 0xfd3f,
    i32x4_ge_u = 0xfd40,

    // SIMD f32x4 comparison
    f32x4_eq = 0xfd41,
    f32x4_ne = 0xfd42,
    f32x4_lt = 0xfd43,
    f32x4_gt = 0xfd44,
    f32x4_le = 0xfd45,
    f32x4_ge = 0xfd46,

    // SIMD f64x2 comparison
    f64x2_eq = 0xfd47,
    f64x2_ne = 0xfd48,
    f64x2_lt = 0xfd49,
    f64x2_gt = 0xfd4a,
    f64x2_le = 0xfd4b,
    f64x2_ge = 0xfd4c,

    // SIMD v128 bitwise
    v128_not = 0xfd4d,
    v128_and = 0xfd4e,
    v128_andnot = 0xfd4f,
    v128_or = 0xfd50,
    v128_xor = 0xfd51,
    v128_bitselect = 0xfd52,
    v128_any_true = 0xfd53,

    // SIMD v128 load/store lane
    v128_load8_lane = 0xfd54,
    v128_load16_lane = 0xfd55,
    v128_load32_lane = 0xfd56,
    v128_load64_lane = 0xfd57,
    v128_store8_lane = 0xfd58,
    v128_store16_lane = 0xfd59,
    v128_store32_lane = 0xfd5a,
    v128_store64_lane = 0xfd5b,
    v128_load32_zero = 0xfd5c,
    v128_load64_zero = 0xfd5d,

    // SIMD f32x4/f64x2 conversion
    f32x4_demote_f64x2_zero = 0xfd5e,
    f64x2_promote_low_f32x4 = 0xfd5f,

    // SIMD i8x16 arithmetic
    i8x16_abs = 0xfd60,
    i8x16_neg = 0xfd61,
    i8x16_popcnt = 0xfd62,
    i8x16_all_true = 0xfd63,
    i8x16_bitmask = 0xfd64,
    i8x16_narrow_i16x8_s = 0xfd65,
    i8x16_narrow_i16x8_u = 0xfd66,

    // SIMD f32x4 rounding
    f32x4_ceil = 0xfd67,
    f32x4_floor = 0xfd68,
    f32x4_trunc = 0xfd69,
    f32x4_nearest = 0xfd6a,

    // SIMD i8x16 shifts & arithmetic
    i8x16_shl = 0xfd6b,
    i8x16_shr_s = 0xfd6c,
    i8x16_shr_u = 0xfd6d,
    i8x16_add = 0xfd6e,
    i8x16_add_sat_s = 0xfd6f,
    i8x16_add_sat_u = 0xfd70,
    i8x16_sub = 0xfd71,
    i8x16_sub_sat_s = 0xfd72,
    i8x16_sub_sat_u = 0xfd73,

    // SIMD f64x2 rounding
    f64x2_ceil = 0xfd74,
    f64x2_floor = 0xfd75,

    // SIMD i8x16 min/max
    i8x16_min_s = 0xfd76,
    i8x16_min_u = 0xfd77,
    i8x16_max_s = 0xfd78,
    i8x16_max_u = 0xfd79,

    // SIMD f64x2 rounding (continued)
    f64x2_trunc = 0xfd7a,

    // SIMD i8x16 avgr
    i8x16_avgr_u = 0xfd7b,

    // SIMD i16x8/i32x4 pairwise
    i16x8_extadd_pairwise_i8x16_s = 0xfd7c,
    i16x8_extadd_pairwise_i8x16_u = 0xfd7d,
    i32x4_extadd_pairwise_i16x8_s = 0xfd7e,
    i32x4_extadd_pairwise_i16x8_u = 0xfd7f,

    // SIMD i16x8 arithmetic
    i16x8_abs = 0xfd80,
    i16x8_neg = 0xfd81,
    i16x8_q15mulr_sat_s = 0xfd82,
    i16x8_all_true = 0xfd83,
    i16x8_bitmask = 0xfd84,
    i16x8_narrow_i32x4_s = 0xfd85,
    i16x8_narrow_i32x4_u = 0xfd86,
    i16x8_extend_low_i8x16_s = 0xfd87,
    i16x8_extend_high_i8x16_s = 0xfd88,
    i16x8_extend_low_i8x16_u = 0xfd89,
    i16x8_extend_high_i8x16_u = 0xfd8a,
    i16x8_shl = 0xfd8b,
    i16x8_shr_s = 0xfd8c,
    i16x8_shr_u = 0xfd8d,
    i16x8_add = 0xfd8e,
    i16x8_add_sat_s = 0xfd8f,
    i16x8_add_sat_u = 0xfd90,
    i16x8_sub = 0xfd91,
    i16x8_sub_sat_s = 0xfd92,
    i16x8_sub_sat_u = 0xfd93,

    // SIMD f64x2 rounding (continued)
    f64x2_nearest = 0xfd94,

    // SIMD i16x8 arithmetic (continued)
    i16x8_mul = 0xfd95,
    i16x8_min_s = 0xfd96,
    i16x8_min_u = 0xfd97,
    i16x8_max_s = 0xfd98,
    i16x8_max_u = 0xfd99,
    i16x8_avgr_u = 0xfd9b,
    i16x8_extmul_low_i8x16_s = 0xfd9c,
    i16x8_extmul_high_i8x16_s = 0xfd9d,
    i16x8_extmul_low_i8x16_u = 0xfd9e,
    i16x8_extmul_high_i8x16_u = 0xfd9f,

    // SIMD i32x4 arithmetic
    i32x4_abs = 0xfda0,
    i32x4_neg = 0xfda1,
    i32x4_all_true = 0xfda3,
    i32x4_bitmask = 0xfda4,
    i32x4_extend_low_i16x8_s = 0xfda7,
    i32x4_extend_high_i16x8_s = 0xfda8,
    i32x4_extend_low_i16x8_u = 0xfda9,
    i32x4_extend_high_i16x8_u = 0xfdaa,
    i32x4_shl = 0xfdab,
    i32x4_shr_s = 0xfdac,
    i32x4_shr_u = 0xfdad,
    i32x4_add = 0xfdae,
    i32x4_sub = 0xfdb1,
    i32x4_mul = 0xfdb5,
    i32x4_min_s = 0xfdb6,
    i32x4_min_u = 0xfdb7,
    i32x4_max_s = 0xfdb8,
    i32x4_max_u = 0xfdb9,
    i32x4_dot_i16x8_s = 0xfdba,
    i32x4_extmul_low_i16x8_s = 0xfdbc,
    i32x4_extmul_high_i16x8_s = 0xfdbd,
    i32x4_extmul_low_i16x8_u = 0xfdbe,
    i32x4_extmul_high_i16x8_u = 0xfdbf,

    // SIMD i64x2 arithmetic
    i64x2_abs = 0xfdc0,
    i64x2_neg = 0xfdc1,
    i64x2_all_true = 0xfdc3,
    i64x2_bitmask = 0xfdc4,
    i64x2_extend_low_i32x4_s = 0xfdc7,
    i64x2_extend_high_i32x4_s = 0xfdc8,
    i64x2_extend_low_i32x4_u = 0xfdc9,
    i64x2_extend_high_i32x4_u = 0xfdca,
    i64x2_shl = 0xfdcb,
    i64x2_shr_s = 0xfdcc,
    i64x2_shr_u = 0xfdcd,
    i64x2_add = 0xfdce,
    i64x2_sub = 0xfdd1,
    i64x2_mul = 0xfdd5,
    i64x2_eq = 0xfdd6,
    i64x2_ne = 0xfdd7,
    i64x2_lt_s = 0xfdd8,
    i64x2_gt_s = 0xfdd9,
    i64x2_le_s = 0xfdda,
    i64x2_ge_s = 0xfddb,
    i64x2_extmul_low_i32x4_s = 0xfddc,
    i64x2_extmul_high_i32x4_s = 0xfddd,
    i64x2_extmul_low_i32x4_u = 0xfdde,
    i64x2_extmul_high_i32x4_u = 0xfddf,

    // SIMD f32x4 arithmetic
    f32x4_abs = 0xfde0,
    f32x4_neg = 0xfde1,
    f32x4_sqrt = 0xfde3,
    f32x4_add = 0xfde4,
    f32x4_sub = 0xfde5,
    f32x4_mul = 0xfde6,
    f32x4_div = 0xfde7,
    f32x4_min = 0xfde8,
    f32x4_max = 0xfde9,
    f32x4_pmin = 0xfdea,
    f32x4_pmax = 0xfdeb,

    // SIMD f64x2 arithmetic
    f64x2_abs = 0xfdec,
    f64x2_neg = 0xfded,
    f64x2_sqrt = 0xfdef,
    f64x2_add = 0xfdf0,
    f64x2_sub = 0xfdf1,
    f64x2_mul = 0xfdf2,
    f64x2_div = 0xfdf3,
    f64x2_min = 0xfdf4,
    f64x2_max = 0xfdf5,
    f64x2_pmin = 0xfdf6,
    f64x2_pmax = 0xfdf7,

    // SIMD conversion
    i32x4_trunc_sat_f32x4_s = 0xfdf8,
    i32x4_trunc_sat_f32x4_u = 0xfdf9,
    f32x4_convert_i32x4_s = 0xfdfa,
    f32x4_convert_i32x4_u = 0xfdfb,
    i32x4_trunc_sat_f64x2_s_zero = 0xfdfc,
    i32x4_trunc_sat_f64x2_u_zero = 0xfdfd,
    f64x2_convert_low_i32x4_s = 0xfdfe,
    f64x2_convert_low_i32x4_u = 0xfdff,

    // Relaxed SIMD (0xfd, 0x100+)
    i8x16_relaxed_swizzle = 0xfd_100,
    i32x4_relaxed_trunc_f32x4_s = 0xfd_101,
    i32x4_relaxed_trunc_f32x4_u = 0xfd_102,
    i32x4_relaxed_trunc_f64x2_s_zero = 0xfd_103,
    i32x4_relaxed_trunc_f64x2_u_zero = 0xfd_104,
    f32x4_relaxed_madd = 0xfd_105,
    f32x4_relaxed_nmadd = 0xfd_106,
    f64x2_relaxed_madd = 0xfd_107,
    f64x2_relaxed_nmadd = 0xfd_108,
    i8x16_relaxed_laneselect = 0xfd_109,
    i16x8_relaxed_laneselect = 0xfd_10a,
    i32x4_relaxed_laneselect = 0xfd_10b,
    i64x2_relaxed_laneselect = 0xfd_10c,
    f32x4_relaxed_min = 0xfd_10d,
    f32x4_relaxed_max = 0xfd_10e,
    f64x2_relaxed_min = 0xfd_10f,
    f64x2_relaxed_max = 0xfd_110,
    i16x8_relaxed_q15mulr_s = 0xfd_111,
    i16x8_dot_i8x16_i7x16_s = 0xfd_112,
    i32x4_dot_i8x16_i7x16_add_s = 0xfd_113,

    // -- Threads prefix (0xfe << 8 | code) --

    memory_atomic_notify = 0xfe00,
    memory_atomic_wait32 = 0xfe01,
    memory_atomic_wait64 = 0xfe02,
    atomic_fence = 0xfe03,

    // Atomic loads
    i32_atomic_load = 0xfe10,
    i64_atomic_load = 0xfe11,
    i32_atomic_load8_u = 0xfe12,
    i32_atomic_load16_u = 0xfe13,
    i64_atomic_load8_u = 0xfe14,
    i64_atomic_load16_u = 0xfe15,
    i64_atomic_load32_u = 0xfe16,

    // Atomic stores
    i32_atomic_store = 0xfe17,
    i64_atomic_store = 0xfe18,
    i32_atomic_store8 = 0xfe19,
    i32_atomic_store16 = 0xfe1a,
    i64_atomic_store8 = 0xfe1b,
    i64_atomic_store16 = 0xfe1c,
    i64_atomic_store32 = 0xfe1d,

    // Atomic RMW add
    i32_atomic_rmw_add = 0xfe1e,
    i64_atomic_rmw_add = 0xfe1f,
    i32_atomic_rmw8_add_u = 0xfe20,
    i32_atomic_rmw16_add_u = 0xfe21,
    i64_atomic_rmw8_add_u = 0xfe22,
    i64_atomic_rmw16_add_u = 0xfe23,
    i64_atomic_rmw32_add_u = 0xfe24,

    // Atomic RMW sub
    i32_atomic_rmw_sub = 0xfe25,
    i64_atomic_rmw_sub = 0xfe26,
    i32_atomic_rmw8_sub_u = 0xfe27,
    i32_atomic_rmw16_sub_u = 0xfe28,
    i64_atomic_rmw8_sub_u = 0xfe29,
    i64_atomic_rmw16_sub_u = 0xfe2a,
    i64_atomic_rmw32_sub_u = 0xfe2b,

    // Atomic RMW and
    i32_atomic_rmw_and = 0xfe2c,
    i64_atomic_rmw_and = 0xfe2d,
    i32_atomic_rmw8_and_u = 0xfe2e,
    i32_atomic_rmw16_and_u = 0xfe2f,
    i64_atomic_rmw8_and_u = 0xfe30,
    i64_atomic_rmw16_and_u = 0xfe31,
    i64_atomic_rmw32_and_u = 0xfe32,

    // Atomic RMW or
    i32_atomic_rmw_or = 0xfe33,
    i64_atomic_rmw_or = 0xfe34,
    i32_atomic_rmw8_or_u = 0xfe35,
    i32_atomic_rmw16_or_u = 0xfe36,
    i64_atomic_rmw8_or_u = 0xfe37,
    i64_atomic_rmw16_or_u = 0xfe38,
    i64_atomic_rmw32_or_u = 0xfe39,

    // Atomic RMW xor
    i32_atomic_rmw_xor = 0xfe3a,
    i64_atomic_rmw_xor = 0xfe3b,
    i32_atomic_rmw8_xor_u = 0xfe3c,
    i32_atomic_rmw16_xor_u = 0xfe3d,
    i64_atomic_rmw8_xor_u = 0xfe3e,
    i64_atomic_rmw16_xor_u = 0xfe3f,
    i64_atomic_rmw32_xor_u = 0xfe40,

    // Atomic RMW xchg
    i32_atomic_rmw_xchg = 0xfe41,
    i64_atomic_rmw_xchg = 0xfe42,
    i32_atomic_rmw8_xchg_u = 0xfe43,
    i32_atomic_rmw16_xchg_u = 0xfe44,
    i64_atomic_rmw8_xchg_u = 0xfe45,
    i64_atomic_rmw16_xchg_u = 0xfe46,
    i64_atomic_rmw32_xchg_u = 0xfe47,

    // Atomic RMW cmpxchg
    i32_atomic_rmw_cmpxchg = 0xfe48,
    i64_atomic_rmw_cmpxchg = 0xfe49,
    i32_atomic_rmw8_cmpxchg_u = 0xfe4a,
    i32_atomic_rmw16_cmpxchg_u = 0xfe4b,
    i64_atomic_rmw8_cmpxchg_u = 0xfe4c,
    i64_atomic_rmw16_cmpxchg_u = 0xfe4d,
    i64_atomic_rmw32_cmpxchg_u = 0xfe4e,

    _,

    // ── Helper methods ───────────────────────────────────────────────

    /// Returns true if this is a prefixed (multi-byte) opcode.
    pub fn isPrefixed(self: Code) bool {
        return @intFromEnum(self) > 0xff;
    }

    /// Get the prefix byte (0 for single-byte opcodes).
    pub fn getPrefix(self: Code) u8 {
        const raw = @intFromEnum(self);
        if (raw <= 0xff) return 0;
        // 4-hex-digit values (0xPPCC): prefix is top byte
        if (raw <= 0xffff) return @truncate(raw >> 8);
        // 5+ hex-digit values (0xPPCCC, e.g. relaxed SIMD 0xfd100+)
        return @truncate(raw >> 12);
    }

    /// Get the sub-opcode (code after prefix, or the single byte itself).
    pub fn getCode(self: Code) u32 {
        const raw = @intFromEnum(self);
        if (raw <= 0xff) return raw;
        const pfx: u32 = self.getPrefix();
        if (raw <= 0xffff) return raw - (pfx << 8);
        return raw - (pfx << 12);
    }

    /// Encode this opcode into `buf`, returning the number of bytes written.
    /// Single-byte opcodes produce 1 byte. Prefixed opcodes produce the
    /// prefix byte followed by a LEB128-encoded sub-opcode.
    pub fn getBytes(self: Code, buf: *[6]u8) u8 {
        const raw = @intFromEnum(self);
        if (raw <= 0xff) {
            buf[0] = @truncate(raw);
            return 1;
        }
        const pfx = self.getPrefix();
        const code = self.getCode();
        buf[0] = pfx;
        // LEB128-encode the sub-opcode.
        var val = code;
        var i: u8 = 1;
        while (val >= 0x80) : (i += 1) {
            buf[i] = @as(u8, @truncate(val)) | 0x80;
            val >>= 7;
        }
        buf[i] = @truncate(val);
        return i + 1;
    }

    /// Check if this opcode is enabled by the given feature set.
    pub fn isEnabled(self: Code, features: Feature.Set) bool {
        return switch (self) {
            // Exception handling
            .try_,
            .catch_,
            .throw,
            .rethrow,
            .throw_ref,
            .delegate,
            .catch_all,
            .try_table,
            => features.exceptions,

            // Tail calls
            .return_call,
            .return_call_indirect,
            => features.tail_call,

            // Function references
            .call_ref,
            .return_call_ref,
            .ref_as_non_null,
            .br_on_null,
            .br_on_non_null,
            => features.function_references,

            // Sign extension
            .i32_extend8_s,
            .i32_extend16_s,
            .i64_extend8_s,
            .i64_extend16_s,
            .i64_extend32_s,
            => features.sign_extension,

            // Saturating float-to-int
            .i32_trunc_sat_f32_s,
            .i32_trunc_sat_f32_u,
            .i32_trunc_sat_f64_s,
            .i32_trunc_sat_f64_u,
            .i64_trunc_sat_f32_s,
            .i64_trunc_sat_f32_u,
            .i64_trunc_sat_f64_s,
            .i64_trunc_sat_f64_u,
            => features.sat_float_to_int,

            // Bulk memory
            .memory_init,
            .data_drop,
            .memory_copy,
            .memory_fill,
            .table_init,
            .elem_drop,
            .table_copy,
            => features.bulk_memory,

            // Reference types
            .table_get,
            .table_set,
            .table_grow,
            .table_size,
            .table_fill,
            .ref_null,
            .ref_is_null,
            .ref_func,
            => features.reference_types,

            // Multi-value (select_t enabled by default)
            .select_t => features.multi_value,

            // Wide arithmetic
            .i64_add128,
            .i64_sub128,
            .i64_mul_wide_s,
            .i64_mul_wide_u,
            => features.wide_arithmetic,

            // Relaxed SIMD
            .i8x16_relaxed_swizzle,
            .i32x4_relaxed_trunc_f32x4_s,
            .i32x4_relaxed_trunc_f32x4_u,
            .i32x4_relaxed_trunc_f64x2_s_zero,
            .i32x4_relaxed_trunc_f64x2_u_zero,
            .f32x4_relaxed_madd,
            .f32x4_relaxed_nmadd,
            .f64x2_relaxed_madd,
            .f64x2_relaxed_nmadd,
            .i8x16_relaxed_laneselect,
            .i16x8_relaxed_laneselect,
            .i32x4_relaxed_laneselect,
            .i64x2_relaxed_laneselect,
            .f32x4_relaxed_min,
            .f32x4_relaxed_max,
            .f64x2_relaxed_min,
            .f64x2_relaxed_max,
            .i16x8_relaxed_q15mulr_s,
            .i16x8_dot_i8x16_i7x16_s,
            .i32x4_dot_i8x16_i7x16_add_s,
            => features.relaxed_simd,

            // Threads / atomics
            .memory_atomic_notify,
            .memory_atomic_wait32,
            .memory_atomic_wait64,
            .atomic_fence,
            .i32_atomic_load,
            .i64_atomic_load,
            .i32_atomic_load8_u,
            .i32_atomic_load16_u,
            .i64_atomic_load8_u,
            .i64_atomic_load16_u,
            .i64_atomic_load32_u,
            .i32_atomic_store,
            .i64_atomic_store,
            .i32_atomic_store8,
            .i32_atomic_store16,
            .i64_atomic_store8,
            .i64_atomic_store16,
            .i64_atomic_store32,
            .i32_atomic_rmw_add,
            .i64_atomic_rmw_add,
            .i32_atomic_rmw8_add_u,
            .i32_atomic_rmw16_add_u,
            .i64_atomic_rmw8_add_u,
            .i64_atomic_rmw16_add_u,
            .i64_atomic_rmw32_add_u,
            .i32_atomic_rmw_sub,
            .i64_atomic_rmw_sub,
            .i32_atomic_rmw8_sub_u,
            .i32_atomic_rmw16_sub_u,
            .i64_atomic_rmw8_sub_u,
            .i64_atomic_rmw16_sub_u,
            .i64_atomic_rmw32_sub_u,
            .i32_atomic_rmw_and,
            .i64_atomic_rmw_and,
            .i32_atomic_rmw8_and_u,
            .i32_atomic_rmw16_and_u,
            .i64_atomic_rmw8_and_u,
            .i64_atomic_rmw16_and_u,
            .i64_atomic_rmw32_and_u,
            .i32_atomic_rmw_or,
            .i64_atomic_rmw_or,
            .i32_atomic_rmw8_or_u,
            .i32_atomic_rmw16_or_u,
            .i64_atomic_rmw8_or_u,
            .i64_atomic_rmw16_or_u,
            .i64_atomic_rmw32_or_u,
            .i32_atomic_rmw_xor,
            .i64_atomic_rmw_xor,
            .i32_atomic_rmw8_xor_u,
            .i32_atomic_rmw16_xor_u,
            .i64_atomic_rmw8_xor_u,
            .i64_atomic_rmw16_xor_u,
            .i64_atomic_rmw32_xor_u,
            .i32_atomic_rmw_xchg,
            .i64_atomic_rmw_xchg,
            .i32_atomic_rmw8_xchg_u,
            .i32_atomic_rmw16_xchg_u,
            .i64_atomic_rmw8_xchg_u,
            .i64_atomic_rmw16_xchg_u,
            .i64_atomic_rmw32_xchg_u,
            .i32_atomic_rmw_cmpxchg,
            .i64_atomic_rmw_cmpxchg,
            .i32_atomic_rmw8_cmpxchg_u,
            .i32_atomic_rmw16_cmpxchg_u,
            .i64_atomic_rmw8_cmpxchg_u,
            .i64_atomic_rmw16_cmpxchg_u,
            .i64_atomic_rmw32_cmpxchg_u,
            => features.threads,

            // SIMD (non-relaxed)
            .v128_load,
            .v128_load8x8_s,
            .v128_load8x8_u,
            .v128_load16x4_s,
            .v128_load16x4_u,
            .v128_load32x2_s,
            .v128_load32x2_u,
            .v128_load8_splat,
            .v128_load16_splat,
            .v128_load32_splat,
            .v128_load64_splat,
            .v128_store,
            .v128_const,
            .i8x16_shuffle,
            .i8x16_swizzle,
            .i8x16_splat,
            .i16x8_splat,
            .i32x4_splat,
            .i64x2_splat,
            .f32x4_splat,
            .f64x2_splat,
            .i8x16_extract_lane_s,
            .i8x16_extract_lane_u,
            .i8x16_replace_lane,
            .i16x8_extract_lane_s,
            .i16x8_extract_lane_u,
            .i16x8_replace_lane,
            .i32x4_extract_lane,
            .i32x4_replace_lane,
            .i64x2_extract_lane,
            .i64x2_replace_lane,
            .f32x4_extract_lane,
            .f32x4_replace_lane,
            .f64x2_extract_lane,
            .f64x2_replace_lane,
            .i8x16_eq,
            .i8x16_ne,
            .i8x16_lt_s,
            .i8x16_lt_u,
            .i8x16_gt_s,
            .i8x16_gt_u,
            .i8x16_le_s,
            .i8x16_le_u,
            .i8x16_ge_s,
            .i8x16_ge_u,
            .i16x8_eq,
            .i16x8_ne,
            .i16x8_lt_s,
            .i16x8_lt_u,
            .i16x8_gt_s,
            .i16x8_gt_u,
            .i16x8_le_s,
            .i16x8_le_u,
            .i16x8_ge_s,
            .i16x8_ge_u,
            .i32x4_eq,
            .i32x4_ne,
            .i32x4_lt_s,
            .i32x4_lt_u,
            .i32x4_gt_s,
            .i32x4_gt_u,
            .i32x4_le_s,
            .i32x4_le_u,
            .i32x4_ge_s,
            .i32x4_ge_u,
            .f32x4_eq,
            .f32x4_ne,
            .f32x4_lt,
            .f32x4_gt,
            .f32x4_le,
            .f32x4_ge,
            .f64x2_eq,
            .f64x2_ne,
            .f64x2_lt,
            .f64x2_gt,
            .f64x2_le,
            .f64x2_ge,
            .v128_not,
            .v128_and,
            .v128_andnot,
            .v128_or,
            .v128_xor,
            .v128_bitselect,
            .v128_any_true,
            .v128_load8_lane,
            .v128_load16_lane,
            .v128_load32_lane,
            .v128_load64_lane,
            .v128_store8_lane,
            .v128_store16_lane,
            .v128_store32_lane,
            .v128_store64_lane,
            .v128_load32_zero,
            .v128_load64_zero,
            .f32x4_demote_f64x2_zero,
            .f64x2_promote_low_f32x4,
            .i8x16_abs,
            .i8x16_neg,
            .i8x16_popcnt,
            .i8x16_all_true,
            .i8x16_bitmask,
            .i8x16_narrow_i16x8_s,
            .i8x16_narrow_i16x8_u,
            .f32x4_ceil,
            .f32x4_floor,
            .f32x4_trunc,
            .f32x4_nearest,
            .i8x16_shl,
            .i8x16_shr_s,
            .i8x16_shr_u,
            .i8x16_add,
            .i8x16_add_sat_s,
            .i8x16_add_sat_u,
            .i8x16_sub,
            .i8x16_sub_sat_s,
            .i8x16_sub_sat_u,
            .f64x2_ceil,
            .f64x2_floor,
            .i8x16_min_s,
            .i8x16_min_u,
            .i8x16_max_s,
            .i8x16_max_u,
            .f64x2_trunc,
            .i8x16_avgr_u,
            .i16x8_extadd_pairwise_i8x16_s,
            .i16x8_extadd_pairwise_i8x16_u,
            .i32x4_extadd_pairwise_i16x8_s,
            .i32x4_extadd_pairwise_i16x8_u,
            .i16x8_abs,
            .i16x8_neg,
            .i16x8_q15mulr_sat_s,
            .i16x8_all_true,
            .i16x8_bitmask,
            .i16x8_narrow_i32x4_s,
            .i16x8_narrow_i32x4_u,
            .i16x8_extend_low_i8x16_s,
            .i16x8_extend_high_i8x16_s,
            .i16x8_extend_low_i8x16_u,
            .i16x8_extend_high_i8x16_u,
            .i16x8_shl,
            .i16x8_shr_s,
            .i16x8_shr_u,
            .i16x8_add,
            .i16x8_add_sat_s,
            .i16x8_add_sat_u,
            .i16x8_sub,
            .i16x8_sub_sat_s,
            .i16x8_sub_sat_u,
            .f64x2_nearest,
            .i16x8_mul,
            .i16x8_min_s,
            .i16x8_min_u,
            .i16x8_max_s,
            .i16x8_max_u,
            .i16x8_avgr_u,
            .i16x8_extmul_low_i8x16_s,
            .i16x8_extmul_high_i8x16_s,
            .i16x8_extmul_low_i8x16_u,
            .i16x8_extmul_high_i8x16_u,
            .i32x4_abs,
            .i32x4_neg,
            .i32x4_all_true,
            .i32x4_bitmask,
            .i32x4_extend_low_i16x8_s,
            .i32x4_extend_high_i16x8_s,
            .i32x4_extend_low_i16x8_u,
            .i32x4_extend_high_i16x8_u,
            .i32x4_shl,
            .i32x4_shr_s,
            .i32x4_shr_u,
            .i32x4_add,
            .i32x4_sub,
            .i32x4_mul,
            .i32x4_min_s,
            .i32x4_min_u,
            .i32x4_max_s,
            .i32x4_max_u,
            .i32x4_dot_i16x8_s,
            .i32x4_extmul_low_i16x8_s,
            .i32x4_extmul_high_i16x8_s,
            .i32x4_extmul_low_i16x8_u,
            .i32x4_extmul_high_i16x8_u,
            .i64x2_abs,
            .i64x2_neg,
            .i64x2_all_true,
            .i64x2_bitmask,
            .i64x2_extend_low_i32x4_s,
            .i64x2_extend_high_i32x4_s,
            .i64x2_extend_low_i32x4_u,
            .i64x2_extend_high_i32x4_u,
            .i64x2_shl,
            .i64x2_shr_s,
            .i64x2_shr_u,
            .i64x2_add,
            .i64x2_sub,
            .i64x2_mul,
            .i64x2_eq,
            .i64x2_ne,
            .i64x2_lt_s,
            .i64x2_gt_s,
            .i64x2_le_s,
            .i64x2_ge_s,
            .i64x2_extmul_low_i32x4_s,
            .i64x2_extmul_high_i32x4_s,
            .i64x2_extmul_low_i32x4_u,
            .i64x2_extmul_high_i32x4_u,
            .f32x4_abs,
            .f32x4_neg,
            .f32x4_sqrt,
            .f32x4_add,
            .f32x4_sub,
            .f32x4_mul,
            .f32x4_div,
            .f32x4_min,
            .f32x4_max,
            .f32x4_pmin,
            .f32x4_pmax,
            .f64x2_abs,
            .f64x2_neg,
            .f64x2_sqrt,
            .f64x2_add,
            .f64x2_sub,
            .f64x2_mul,
            .f64x2_div,
            .f64x2_min,
            .f64x2_max,
            .f64x2_pmin,
            .f64x2_pmax,
            .i32x4_trunc_sat_f32x4_s,
            .i32x4_trunc_sat_f32x4_u,
            .f32x4_convert_i32x4_s,
            .f32x4_convert_i32x4_u,
            .i32x4_trunc_sat_f64x2_s_zero,
            .i32x4_trunc_sat_f64x2_u_zero,
            .f64x2_convert_low_i32x4_s,
            .f64x2_convert_low_i32x4_u,
            => features.simd,

            // MVP opcodes — always enabled
            .@"unreachable",
            .nop,
            .block,
            .loop,
            .@"if",
            .@"else",
            .end,
            .br,
            .br_if,
            .br_table,
            .@"return",
            .call,
            .call_indirect,
            .drop,
            .select,
            .local_get,
            .local_set,
            .local_tee,
            .global_get,
            .global_set,
            .i32_load,
            .i64_load,
            .f32_load,
            .f64_load,
            .i32_load8_s,
            .i32_load8_u,
            .i32_load16_s,
            .i32_load16_u,
            .i64_load8_s,
            .i64_load8_u,
            .i64_load16_s,
            .i64_load16_u,
            .i64_load32_s,
            .i64_load32_u,
            .i32_store,
            .i64_store,
            .f32_store,
            .f64_store,
            .i32_store8,
            .i32_store16,
            .i64_store8,
            .i64_store16,
            .i64_store32,
            .memory_size,
            .memory_grow,
            .i32_const,
            .i64_const,
            .f32_const,
            .f64_const,
            .i32_eqz,
            .i32_eq,
            .i32_ne,
            .i32_lt_s,
            .i32_lt_u,
            .i32_gt_s,
            .i32_gt_u,
            .i32_le_s,
            .i32_le_u,
            .i32_ge_s,
            .i32_ge_u,
            .i64_eqz,
            .i64_eq,
            .i64_ne,
            .i64_lt_s,
            .i64_lt_u,
            .i64_gt_s,
            .i64_gt_u,
            .i64_le_s,
            .i64_le_u,
            .i64_ge_s,
            .i64_ge_u,
            .f32_eq,
            .f32_ne,
            .f32_lt,
            .f32_gt,
            .f32_le,
            .f32_ge,
            .f64_eq,
            .f64_ne,
            .f64_lt,
            .f64_gt,
            .f64_le,
            .f64_ge,
            .i32_clz,
            .i32_ctz,
            .i32_popcnt,
            .i32_add,
            .i32_sub,
            .i32_mul,
            .i32_div_s,
            .i32_div_u,
            .i32_rem_s,
            .i32_rem_u,
            .i32_and,
            .i32_or,
            .i32_xor,
            .i32_shl,
            .i32_shr_s,
            .i32_shr_u,
            .i32_rotl,
            .i32_rotr,
            .i64_clz,
            .i64_ctz,
            .i64_popcnt,
            .i64_add,
            .i64_sub,
            .i64_mul,
            .i64_div_s,
            .i64_div_u,
            .i64_rem_s,
            .i64_rem_u,
            .i64_and,
            .i64_or,
            .i64_xor,
            .i64_shl,
            .i64_shr_s,
            .i64_shr_u,
            .i64_rotl,
            .i64_rotr,
            .f32_abs,
            .f32_neg,
            .f32_ceil,
            .f32_floor,
            .f32_trunc,
            .f32_nearest,
            .f32_sqrt,
            .f32_add,
            .f32_sub,
            .f32_mul,
            .f32_div,
            .f32_min,
            .f32_max,
            .f32_copysign,
            .f64_abs,
            .f64_neg,
            .f64_ceil,
            .f64_floor,
            .f64_trunc,
            .f64_nearest,
            .f64_sqrt,
            .f64_add,
            .f64_sub,
            .f64_mul,
            .f64_div,
            .f64_min,
            .f64_max,
            .f64_copysign,
            .i32_wrap_i64,
            .i32_trunc_f32_s,
            .i32_trunc_f32_u,
            .i32_trunc_f64_s,
            .i32_trunc_f64_u,
            .i64_extend_i32_s,
            .i64_extend_i32_u,
            .i64_trunc_f32_s,
            .i64_trunc_f32_u,
            .i64_trunc_f64_s,
            .i64_trunc_f64_u,
            .f32_convert_i32_s,
            .f32_convert_i32_u,
            .f32_convert_i64_s,
            .f32_convert_i64_u,
            .f32_demote_f64,
            .f64_convert_i32_s,
            .f64_convert_i32_u,
            .f64_convert_i64_s,
            .f64_convert_i64_u,
            .f64_promote_f32,
            .i32_reinterpret_f32,
            .i64_reinterpret_f64,
            .f32_reinterpret_i32,
            .f64_reinterpret_i64,
            => true,

            // Unknown/unnamed values — assume enabled
            _ => true,
        };
    }

    /// Get the text name of this opcode (matching wabt's text format).
    pub fn name(self: Code) []const u8 {
        return switch (self) {
            .@"unreachable" => "unreachable",
            .nop => "nop",
            .block => "block",
            .loop => "loop",
            .@"if" => "if",
            .@"else" => "else",
            .try_ => "try",
            .catch_ => "catch",
            .throw => "throw",
            .rethrow => "rethrow",
            .throw_ref => "throw_ref",
            .end => "end",
            .br => "br",
            .br_if => "br_if",
            .br_table => "br_table",
            .@"return" => "return",
            .call => "call",
            .call_indirect => "call_indirect",
            .return_call => "return_call",
            .return_call_indirect => "return_call_indirect",
            .call_ref => "call_ref",
            .return_call_ref => "return_call_ref",
            .delegate => "delegate",
            .catch_all => "catch_all",
            .drop => "drop",
            .select => "select",
            .select_t => "select",
            .try_table => "try_table",
            .local_get => "local.get",
            .local_set => "local.set",
            .local_tee => "local.tee",
            .global_get => "global.get",
            .global_set => "global.set",
            .table_get => "table.get",
            .table_set => "table.set",
            .i32_load => "i32.load",
            .i64_load => "i64.load",
            .f32_load => "f32.load",
            .f64_load => "f64.load",
            .i32_load8_s => "i32.load8_s",
            .i32_load8_u => "i32.load8_u",
            .i32_load16_s => "i32.load16_s",
            .i32_load16_u => "i32.load16_u",
            .i64_load8_s => "i64.load8_s",
            .i64_load8_u => "i64.load8_u",
            .i64_load16_s => "i64.load16_s",
            .i64_load16_u => "i64.load16_u",
            .i64_load32_s => "i64.load32_s",
            .i64_load32_u => "i64.load32_u",
            .i32_store => "i32.store",
            .i64_store => "i64.store",
            .f32_store => "f32.store",
            .f64_store => "f64.store",
            .i32_store8 => "i32.store8",
            .i32_store16 => "i32.store16",
            .i64_store8 => "i64.store8",
            .i64_store16 => "i64.store16",
            .i64_store32 => "i64.store32",
            .memory_size => "memory.size",
            .memory_grow => "memory.grow",
            .i32_const => "i32.const",
            .i64_const => "i64.const",
            .f32_const => "f32.const",
            .f64_const => "f64.const",
            .i32_eqz => "i32.eqz",
            .i32_eq => "i32.eq",
            .i32_ne => "i32.ne",
            .i32_lt_s => "i32.lt_s",
            .i32_lt_u => "i32.lt_u",
            .i32_gt_s => "i32.gt_s",
            .i32_gt_u => "i32.gt_u",
            .i32_le_s => "i32.le_s",
            .i32_le_u => "i32.le_u",
            .i32_ge_s => "i32.ge_s",
            .i32_ge_u => "i32.ge_u",
            .i64_eqz => "i64.eqz",
            .i64_eq => "i64.eq",
            .i64_ne => "i64.ne",
            .i64_lt_s => "i64.lt_s",
            .i64_lt_u => "i64.lt_u",
            .i64_gt_s => "i64.gt_s",
            .i64_gt_u => "i64.gt_u",
            .i64_le_s => "i64.le_s",
            .i64_le_u => "i64.le_u",
            .i64_ge_s => "i64.ge_s",
            .i64_ge_u => "i64.ge_u",
            .f32_eq => "f32.eq",
            .f32_ne => "f32.ne",
            .f32_lt => "f32.lt",
            .f32_gt => "f32.gt",
            .f32_le => "f32.le",
            .f32_ge => "f32.ge",
            .f64_eq => "f64.eq",
            .f64_ne => "f64.ne",
            .f64_lt => "f64.lt",
            .f64_gt => "f64.gt",
            .f64_le => "f64.le",
            .f64_ge => "f64.ge",
            .i32_clz => "i32.clz",
            .i32_ctz => "i32.ctz",
            .i32_popcnt => "i32.popcnt",
            .i32_add => "i32.add",
            .i32_sub => "i32.sub",
            .i32_mul => "i32.mul",
            .i32_div_s => "i32.div_s",
            .i32_div_u => "i32.div_u",
            .i32_rem_s => "i32.rem_s",
            .i32_rem_u => "i32.rem_u",
            .i32_and => "i32.and",
            .i32_or => "i32.or",
            .i32_xor => "i32.xor",
            .i32_shl => "i32.shl",
            .i32_shr_s => "i32.shr_s",
            .i32_shr_u => "i32.shr_u",
            .i32_rotl => "i32.rotl",
            .i32_rotr => "i32.rotr",
            .i64_clz => "i64.clz",
            .i64_ctz => "i64.ctz",
            .i64_popcnt => "i64.popcnt",
            .i64_add => "i64.add",
            .i64_sub => "i64.sub",
            .i64_mul => "i64.mul",
            .i64_div_s => "i64.div_s",
            .i64_div_u => "i64.div_u",
            .i64_rem_s => "i64.rem_s",
            .i64_rem_u => "i64.rem_u",
            .i64_and => "i64.and",
            .i64_or => "i64.or",
            .i64_xor => "i64.xor",
            .i64_shl => "i64.shl",
            .i64_shr_s => "i64.shr_s",
            .i64_shr_u => "i64.shr_u",
            .i64_rotl => "i64.rotl",
            .i64_rotr => "i64.rotr",
            .f32_abs => "f32.abs",
            .f32_neg => "f32.neg",
            .f32_ceil => "f32.ceil",
            .f32_floor => "f32.floor",
            .f32_trunc => "f32.trunc",
            .f32_nearest => "f32.nearest",
            .f32_sqrt => "f32.sqrt",
            .f32_add => "f32.add",
            .f32_sub => "f32.sub",
            .f32_mul => "f32.mul",
            .f32_div => "f32.div",
            .f32_min => "f32.min",
            .f32_max => "f32.max",
            .f32_copysign => "f32.copysign",
            .f64_abs => "f64.abs",
            .f64_neg => "f64.neg",
            .f64_ceil => "f64.ceil",
            .f64_floor => "f64.floor",
            .f64_trunc => "f64.trunc",
            .f64_nearest => "f64.nearest",
            .f64_sqrt => "f64.sqrt",
            .f64_add => "f64.add",
            .f64_sub => "f64.sub",
            .f64_mul => "f64.mul",
            .f64_div => "f64.div",
            .f64_min => "f64.min",
            .f64_max => "f64.max",
            .f64_copysign => "f64.copysign",
            .i32_wrap_i64 => "i32.wrap_i64",
            .i32_trunc_f32_s => "i32.trunc_f32_s",
            .i32_trunc_f32_u => "i32.trunc_f32_u",
            .i32_trunc_f64_s => "i32.trunc_f64_s",
            .i32_trunc_f64_u => "i32.trunc_f64_u",
            .i64_extend_i32_s => "i64.extend_i32_s",
            .i64_extend_i32_u => "i64.extend_i32_u",
            .i64_trunc_f32_s => "i64.trunc_f32_s",
            .i64_trunc_f32_u => "i64.trunc_f32_u",
            .i64_trunc_f64_s => "i64.trunc_f64_s",
            .i64_trunc_f64_u => "i64.trunc_f64_u",
            .f32_convert_i32_s => "f32.convert_i32_s",
            .f32_convert_i32_u => "f32.convert_i32_u",
            .f32_convert_i64_s => "f32.convert_i64_s",
            .f32_convert_i64_u => "f32.convert_i64_u",
            .f32_demote_f64 => "f32.demote_f64",
            .f64_convert_i32_s => "f64.convert_i32_s",
            .f64_convert_i32_u => "f64.convert_i32_u",
            .f64_convert_i64_s => "f64.convert_i64_s",
            .f64_convert_i64_u => "f64.convert_i64_u",
            .f64_promote_f32 => "f64.promote_f32",
            .i32_reinterpret_f32 => "i32.reinterpret_f32",
            .i64_reinterpret_f64 => "i64.reinterpret_f64",
            .f32_reinterpret_i32 => "f32.reinterpret_i32",
            .f64_reinterpret_i64 => "f64.reinterpret_i64",
            .i32_extend8_s => "i32.extend8_s",
            .i32_extend16_s => "i32.extend16_s",
            .i64_extend8_s => "i64.extend8_s",
            .i64_extend16_s => "i64.extend16_s",
            .i64_extend32_s => "i64.extend32_s",
            .ref_null => "ref.null",
            .ref_is_null => "ref.is_null",
            .ref_func => "ref.func",
            .ref_as_non_null => "ref.as_non_null",
            .br_on_null => "br_on_null",
            .br_on_non_null => "br_on_non_null",
            .i32_trunc_sat_f32_s => "i32.trunc_sat_f32_s",
            .i32_trunc_sat_f32_u => "i32.trunc_sat_f32_u",
            .i32_trunc_sat_f64_s => "i32.trunc_sat_f64_s",
            .i32_trunc_sat_f64_u => "i32.trunc_sat_f64_u",
            .i64_trunc_sat_f32_s => "i64.trunc_sat_f32_s",
            .i64_trunc_sat_f32_u => "i64.trunc_sat_f32_u",
            .i64_trunc_sat_f64_s => "i64.trunc_sat_f64_s",
            .i64_trunc_sat_f64_u => "i64.trunc_sat_f64_u",
            .memory_init => "memory.init",
            .data_drop => "data.drop",
            .memory_copy => "memory.copy",
            .memory_fill => "memory.fill",
            .table_init => "table.init",
            .elem_drop => "elem.drop",
            .table_copy => "table.copy",
            .table_grow => "table.grow",
            .table_size => "table.size",
            .table_fill => "table.fill",
            .i64_add128 => "i64.add128",
            .i64_sub128 => "i64.sub128",
            .i64_mul_wide_s => "i64.mul_wide_s",
            .i64_mul_wide_u => "i64.mul_wide_u",
            .v128_load => "v128.load",
            .v128_load8x8_s => "v128.load8x8_s",
            .v128_load8x8_u => "v128.load8x8_u",
            .v128_load16x4_s => "v128.load16x4_s",
            .v128_load16x4_u => "v128.load16x4_u",
            .v128_load32x2_s => "v128.load32x2_s",
            .v128_load32x2_u => "v128.load32x2_u",
            .v128_load8_splat => "v128.load8_splat",
            .v128_load16_splat => "v128.load16_splat",
            .v128_load32_splat => "v128.load32_splat",
            .v128_load64_splat => "v128.load64_splat",
            .v128_store => "v128.store",
            .v128_const => "v128.const",
            .i8x16_shuffle => "i8x16.shuffle",
            .i8x16_swizzle => "i8x16.swizzle",
            .i8x16_splat => "i8x16.splat",
            .i16x8_splat => "i16x8.splat",
            .i32x4_splat => "i32x4.splat",
            .i64x2_splat => "i64x2.splat",
            .f32x4_splat => "f32x4.splat",
            .f64x2_splat => "f64x2.splat",
            .i8x16_extract_lane_s => "i8x16.extract_lane_s",
            .i8x16_extract_lane_u => "i8x16.extract_lane_u",
            .i8x16_replace_lane => "i8x16.replace_lane",
            .i16x8_extract_lane_s => "i16x8.extract_lane_s",
            .i16x8_extract_lane_u => "i16x8.extract_lane_u",
            .i16x8_replace_lane => "i16x8.replace_lane",
            .i32x4_extract_lane => "i32x4.extract_lane",
            .i32x4_replace_lane => "i32x4.replace_lane",
            .i64x2_extract_lane => "i64x2.extract_lane",
            .i64x2_replace_lane => "i64x2.replace_lane",
            .f32x4_extract_lane => "f32x4.extract_lane",
            .f32x4_replace_lane => "f32x4.replace_lane",
            .f64x2_extract_lane => "f64x2.extract_lane",
            .f64x2_replace_lane => "f64x2.replace_lane",
            .i8x16_eq => "i8x16.eq",
            .i8x16_ne => "i8x16.ne",
            .i8x16_lt_s => "i8x16.lt_s",
            .i8x16_lt_u => "i8x16.lt_u",
            .i8x16_gt_s => "i8x16.gt_s",
            .i8x16_gt_u => "i8x16.gt_u",
            .i8x16_le_s => "i8x16.le_s",
            .i8x16_le_u => "i8x16.le_u",
            .i8x16_ge_s => "i8x16.ge_s",
            .i8x16_ge_u => "i8x16.ge_u",
            .i16x8_eq => "i16x8.eq",
            .i16x8_ne => "i16x8.ne",
            .i16x8_lt_s => "i16x8.lt_s",
            .i16x8_lt_u => "i16x8.lt_u",
            .i16x8_gt_s => "i16x8.gt_s",
            .i16x8_gt_u => "i16x8.gt_u",
            .i16x8_le_s => "i16x8.le_s",
            .i16x8_le_u => "i16x8.le_u",
            .i16x8_ge_s => "i16x8.ge_s",
            .i16x8_ge_u => "i16x8.ge_u",
            .i32x4_eq => "i32x4.eq",
            .i32x4_ne => "i32x4.ne",
            .i32x4_lt_s => "i32x4.lt_s",
            .i32x4_lt_u => "i32x4.lt_u",
            .i32x4_gt_s => "i32x4.gt_s",
            .i32x4_gt_u => "i32x4.gt_u",
            .i32x4_le_s => "i32x4.le_s",
            .i32x4_le_u => "i32x4.le_u",
            .i32x4_ge_s => "i32x4.ge_s",
            .i32x4_ge_u => "i32x4.ge_u",
            .f32x4_eq => "f32x4.eq",
            .f32x4_ne => "f32x4.ne",
            .f32x4_lt => "f32x4.lt",
            .f32x4_gt => "f32x4.gt",
            .f32x4_le => "f32x4.le",
            .f32x4_ge => "f32x4.ge",
            .f64x2_eq => "f64x2.eq",
            .f64x2_ne => "f64x2.ne",
            .f64x2_lt => "f64x2.lt",
            .f64x2_gt => "f64x2.gt",
            .f64x2_le => "f64x2.le",
            .f64x2_ge => "f64x2.ge",
            .v128_not => "v128.not",
            .v128_and => "v128.and",
            .v128_andnot => "v128.andnot",
            .v128_or => "v128.or",
            .v128_xor => "v128.xor",
            .v128_bitselect => "v128.bitselect",
            .v128_any_true => "v128.any_true",
            .v128_load8_lane => "v128.load8_lane",
            .v128_load16_lane => "v128.load16_lane",
            .v128_load32_lane => "v128.load32_lane",
            .v128_load64_lane => "v128.load64_lane",
            .v128_store8_lane => "v128.store8_lane",
            .v128_store16_lane => "v128.store16_lane",
            .v128_store32_lane => "v128.store32_lane",
            .v128_store64_lane => "v128.store64_lane",
            .v128_load32_zero => "v128.load32_zero",
            .v128_load64_zero => "v128.load64_zero",
            .f32x4_demote_f64x2_zero => "f32x4.demote_f64x2_zero",
            .f64x2_promote_low_f32x4 => "f64x2.promote_low_f32x4",
            .i8x16_abs => "i8x16.abs",
            .i8x16_neg => "i8x16.neg",
            .i8x16_popcnt => "i8x16.popcnt",
            .i8x16_all_true => "i8x16.all_true",
            .i8x16_bitmask => "i8x16.bitmask",
            .i8x16_narrow_i16x8_s => "i8x16.narrow_i16x8_s",
            .i8x16_narrow_i16x8_u => "i8x16.narrow_i16x8_u",
            .f32x4_ceil => "f32x4.ceil",
            .f32x4_floor => "f32x4.floor",
            .f32x4_trunc => "f32x4.trunc",
            .f32x4_nearest => "f32x4.nearest",
            .i8x16_shl => "i8x16.shl",
            .i8x16_shr_s => "i8x16.shr_s",
            .i8x16_shr_u => "i8x16.shr_u",
            .i8x16_add => "i8x16.add",
            .i8x16_add_sat_s => "i8x16.add_sat_s",
            .i8x16_add_sat_u => "i8x16.add_sat_u",
            .i8x16_sub => "i8x16.sub",
            .i8x16_sub_sat_s => "i8x16.sub_sat_s",
            .i8x16_sub_sat_u => "i8x16.sub_sat_u",
            .f64x2_ceil => "f64x2.ceil",
            .f64x2_floor => "f64x2.floor",
            .i8x16_min_s => "i8x16.min_s",
            .i8x16_min_u => "i8x16.min_u",
            .i8x16_max_s => "i8x16.max_s",
            .i8x16_max_u => "i8x16.max_u",
            .f64x2_trunc => "f64x2.trunc",
            .i8x16_avgr_u => "i8x16.avgr_u",
            .i16x8_extadd_pairwise_i8x16_s => "i16x8.extadd_pairwise_i8x16_s",
            .i16x8_extadd_pairwise_i8x16_u => "i16x8.extadd_pairwise_i8x16_u",
            .i32x4_extadd_pairwise_i16x8_s => "i32x4.extadd_pairwise_i16x8_s",
            .i32x4_extadd_pairwise_i16x8_u => "i32x4.extadd_pairwise_i16x8_u",
            .i16x8_abs => "i16x8.abs",
            .i16x8_neg => "i16x8.neg",
            .i16x8_q15mulr_sat_s => "i16x8.q15mulr_sat_s",
            .i16x8_all_true => "i16x8.all_true",
            .i16x8_bitmask => "i16x8.bitmask",
            .i16x8_narrow_i32x4_s => "i16x8.narrow_i32x4_s",
            .i16x8_narrow_i32x4_u => "i16x8.narrow_i32x4_u",
            .i16x8_extend_low_i8x16_s => "i16x8.extend_low_i8x16_s",
            .i16x8_extend_high_i8x16_s => "i16x8.extend_high_i8x16_s",
            .i16x8_extend_low_i8x16_u => "i16x8.extend_low_i8x16_u",
            .i16x8_extend_high_i8x16_u => "i16x8.extend_high_i8x16_u",
            .i16x8_shl => "i16x8.shl",
            .i16x8_shr_s => "i16x8.shr_s",
            .i16x8_shr_u => "i16x8.shr_u",
            .i16x8_add => "i16x8.add",
            .i16x8_add_sat_s => "i16x8.add_sat_s",
            .i16x8_add_sat_u => "i16x8.add_sat_u",
            .i16x8_sub => "i16x8.sub",
            .i16x8_sub_sat_s => "i16x8.sub_sat_s",
            .i16x8_sub_sat_u => "i16x8.sub_sat_u",
            .f64x2_nearest => "f64x2.nearest",
            .i16x8_mul => "i16x8.mul",
            .i16x8_min_s => "i16x8.min_s",
            .i16x8_min_u => "i16x8.min_u",
            .i16x8_max_s => "i16x8.max_s",
            .i16x8_max_u => "i16x8.max_u",
            .i16x8_avgr_u => "i16x8.avgr_u",
            .i16x8_extmul_low_i8x16_s => "i16x8.extmul_low_i8x16_s",
            .i16x8_extmul_high_i8x16_s => "i16x8.extmul_high_i8x16_s",
            .i16x8_extmul_low_i8x16_u => "i16x8.extmul_low_i8x16_u",
            .i16x8_extmul_high_i8x16_u => "i16x8.extmul_high_i8x16_u",
            .i32x4_abs => "i32x4.abs",
            .i32x4_neg => "i32x4.neg",
            .i32x4_all_true => "i32x4.all_true",
            .i32x4_bitmask => "i32x4.bitmask",
            .i32x4_extend_low_i16x8_s => "i32x4.extend_low_i16x8_s",
            .i32x4_extend_high_i16x8_s => "i32x4.extend_high_i16x8_s",
            .i32x4_extend_low_i16x8_u => "i32x4.extend_low_i16x8_u",
            .i32x4_extend_high_i16x8_u => "i32x4.extend_high_i16x8_u",
            .i32x4_shl => "i32x4.shl",
            .i32x4_shr_s => "i32x4.shr_s",
            .i32x4_shr_u => "i32x4.shr_u",
            .i32x4_add => "i32x4.add",
            .i32x4_sub => "i32x4.sub",
            .i32x4_mul => "i32x4.mul",
            .i32x4_min_s => "i32x4.min_s",
            .i32x4_min_u => "i32x4.min_u",
            .i32x4_max_s => "i32x4.max_s",
            .i32x4_max_u => "i32x4.max_u",
            .i32x4_dot_i16x8_s => "i32x4.dot_i16x8_s",
            .i32x4_extmul_low_i16x8_s => "i32x4.extmul_low_i16x8_s",
            .i32x4_extmul_high_i16x8_s => "i32x4.extmul_high_i16x8_s",
            .i32x4_extmul_low_i16x8_u => "i32x4.extmul_low_i16x8_u",
            .i32x4_extmul_high_i16x8_u => "i32x4.extmul_high_i16x8_u",
            .i64x2_abs => "i64x2.abs",
            .i64x2_neg => "i64x2.neg",
            .i64x2_all_true => "i64x2.all_true",
            .i64x2_bitmask => "i64x2.bitmask",
            .i64x2_extend_low_i32x4_s => "i64x2.extend_low_i32x4_s",
            .i64x2_extend_high_i32x4_s => "i64x2.extend_high_i32x4_s",
            .i64x2_extend_low_i32x4_u => "i64x2.extend_low_i32x4_u",
            .i64x2_extend_high_i32x4_u => "i64x2.extend_high_i32x4_u",
            .i64x2_shl => "i64x2.shl",
            .i64x2_shr_s => "i64x2.shr_s",
            .i64x2_shr_u => "i64x2.shr_u",
            .i64x2_add => "i64x2.add",
            .i64x2_sub => "i64x2.sub",
            .i64x2_mul => "i64x2.mul",
            .i64x2_eq => "i64x2.eq",
            .i64x2_ne => "i64x2.ne",
            .i64x2_lt_s => "i64x2.lt_s",
            .i64x2_gt_s => "i64x2.gt_s",
            .i64x2_le_s => "i64x2.le_s",
            .i64x2_ge_s => "i64x2.ge_s",
            .i64x2_extmul_low_i32x4_s => "i64x2.extmul_low_i32x4_s",
            .i64x2_extmul_high_i32x4_s => "i64x2.extmul_high_i32x4_s",
            .i64x2_extmul_low_i32x4_u => "i64x2.extmul_low_i32x4_u",
            .i64x2_extmul_high_i32x4_u => "i64x2.extmul_high_i32x4_u",
            .f32x4_abs => "f32x4.abs",
            .f32x4_neg => "f32x4.neg",
            .f32x4_sqrt => "f32x4.sqrt",
            .f32x4_add => "f32x4.add",
            .f32x4_sub => "f32x4.sub",
            .f32x4_mul => "f32x4.mul",
            .f32x4_div => "f32x4.div",
            .f32x4_min => "f32x4.min",
            .f32x4_max => "f32x4.max",
            .f32x4_pmin => "f32x4.pmin",
            .f32x4_pmax => "f32x4.pmax",
            .f64x2_abs => "f64x2.abs",
            .f64x2_neg => "f64x2.neg",
            .f64x2_sqrt => "f64x2.sqrt",
            .f64x2_add => "f64x2.add",
            .f64x2_sub => "f64x2.sub",
            .f64x2_mul => "f64x2.mul",
            .f64x2_div => "f64x2.div",
            .f64x2_min => "f64x2.min",
            .f64x2_max => "f64x2.max",
            .f64x2_pmin => "f64x2.pmin",
            .f64x2_pmax => "f64x2.pmax",
            .i32x4_trunc_sat_f32x4_s => "i32x4.trunc_sat_f32x4_s",
            .i32x4_trunc_sat_f32x4_u => "i32x4.trunc_sat_f32x4_u",
            .f32x4_convert_i32x4_s => "f32x4.convert_i32x4_s",
            .f32x4_convert_i32x4_u => "f32x4.convert_i32x4_u",
            .i32x4_trunc_sat_f64x2_s_zero => "i32x4.trunc_sat_f64x2_s_zero",
            .i32x4_trunc_sat_f64x2_u_zero => "i32x4.trunc_sat_f64x2_u_zero",
            .f64x2_convert_low_i32x4_s => "f64x2.convert_low_i32x4_s",
            .f64x2_convert_low_i32x4_u => "f64x2.convert_low_i32x4_u",
            .i8x16_relaxed_swizzle => "i8x16.relaxed_swizzle",
            .i32x4_relaxed_trunc_f32x4_s => "i32x4.relaxed_trunc_f32x4_s",
            .i32x4_relaxed_trunc_f32x4_u => "i32x4.relaxed_trunc_f32x4_u",
            .i32x4_relaxed_trunc_f64x2_s_zero => "i32x4.relaxed_trunc_f64x2_s_zero",
            .i32x4_relaxed_trunc_f64x2_u_zero => "i32x4.relaxed_trunc_f64x2_u_zero",
            .f32x4_relaxed_madd => "f32x4.relaxed_madd",
            .f32x4_relaxed_nmadd => "f32x4.relaxed_nmadd",
            .f64x2_relaxed_madd => "f64x2.relaxed_madd",
            .f64x2_relaxed_nmadd => "f64x2.relaxed_nmadd",
            .i8x16_relaxed_laneselect => "i8x16.relaxed_laneselect",
            .i16x8_relaxed_laneselect => "i16x8.relaxed_laneselect",
            .i32x4_relaxed_laneselect => "i32x4.relaxed_laneselect",
            .i64x2_relaxed_laneselect => "i64x2.relaxed_laneselect",
            .f32x4_relaxed_min => "f32x4.relaxed_min",
            .f32x4_relaxed_max => "f32x4.relaxed_max",
            .f64x2_relaxed_min => "f64x2.relaxed_min",
            .f64x2_relaxed_max => "f64x2.relaxed_max",
            .i16x8_relaxed_q15mulr_s => "i16x8.relaxed_q15mulr_s",
            .i16x8_dot_i8x16_i7x16_s => "i16x8.relaxed_dot_i8x16_i7x16_s",
            .i32x4_dot_i8x16_i7x16_add_s => "i32x4.relaxed_dot_i8x16_i7x16_add_s",
            .memory_atomic_notify => "memory.atomic.notify",
            .memory_atomic_wait32 => "memory.atomic.wait32",
            .memory_atomic_wait64 => "memory.atomic.wait64",
            .atomic_fence => "atomic.fence",
            .i32_atomic_load => "i32.atomic.load",
            .i64_atomic_load => "i64.atomic.load",
            .i32_atomic_load8_u => "i32.atomic.load8_u",
            .i32_atomic_load16_u => "i32.atomic.load16_u",
            .i64_atomic_load8_u => "i64.atomic.load8_u",
            .i64_atomic_load16_u => "i64.atomic.load16_u",
            .i64_atomic_load32_u => "i64.atomic.load32_u",
            .i32_atomic_store => "i32.atomic.store",
            .i64_atomic_store => "i64.atomic.store",
            .i32_atomic_store8 => "i32.atomic.store8",
            .i32_atomic_store16 => "i32.atomic.store16",
            .i64_atomic_store8 => "i64.atomic.store8",
            .i64_atomic_store16 => "i64.atomic.store16",
            .i64_atomic_store32 => "i64.atomic.store32",
            .i32_atomic_rmw_add => "i32.atomic.rmw.add",
            .i64_atomic_rmw_add => "i64.atomic.rmw.add",
            .i32_atomic_rmw8_add_u => "i32.atomic.rmw8.add_u",
            .i32_atomic_rmw16_add_u => "i32.atomic.rmw16.add_u",
            .i64_atomic_rmw8_add_u => "i64.atomic.rmw8.add_u",
            .i64_atomic_rmw16_add_u => "i64.atomic.rmw16.add_u",
            .i64_atomic_rmw32_add_u => "i64.atomic.rmw32.add_u",
            .i32_atomic_rmw_sub => "i32.atomic.rmw.sub",
            .i64_atomic_rmw_sub => "i64.atomic.rmw.sub",
            .i32_atomic_rmw8_sub_u => "i32.atomic.rmw8.sub_u",
            .i32_atomic_rmw16_sub_u => "i32.atomic.rmw16.sub_u",
            .i64_atomic_rmw8_sub_u => "i64.atomic.rmw8.sub_u",
            .i64_atomic_rmw16_sub_u => "i64.atomic.rmw16.sub_u",
            .i64_atomic_rmw32_sub_u => "i64.atomic.rmw32.sub_u",
            .i32_atomic_rmw_and => "i32.atomic.rmw.and",
            .i64_atomic_rmw_and => "i64.atomic.rmw.and",
            .i32_atomic_rmw8_and_u => "i32.atomic.rmw8.and_u",
            .i32_atomic_rmw16_and_u => "i32.atomic.rmw16.and_u",
            .i64_atomic_rmw8_and_u => "i64.atomic.rmw8.and_u",
            .i64_atomic_rmw16_and_u => "i64.atomic.rmw16.and_u",
            .i64_atomic_rmw32_and_u => "i64.atomic.rmw32.and_u",
            .i32_atomic_rmw_or => "i32.atomic.rmw.or",
            .i64_atomic_rmw_or => "i64.atomic.rmw.or",
            .i32_atomic_rmw8_or_u => "i32.atomic.rmw8.or_u",
            .i32_atomic_rmw16_or_u => "i32.atomic.rmw16.or_u",
            .i64_atomic_rmw8_or_u => "i64.atomic.rmw8.or_u",
            .i64_atomic_rmw16_or_u => "i64.atomic.rmw16.or_u",
            .i64_atomic_rmw32_or_u => "i64.atomic.rmw32.or_u",
            .i32_atomic_rmw_xor => "i32.atomic.rmw.xor",
            .i64_atomic_rmw_xor => "i64.atomic.rmw.xor",
            .i32_atomic_rmw8_xor_u => "i32.atomic.rmw8.xor_u",
            .i32_atomic_rmw16_xor_u => "i32.atomic.rmw16.xor_u",
            .i64_atomic_rmw8_xor_u => "i64.atomic.rmw8.xor_u",
            .i64_atomic_rmw16_xor_u => "i64.atomic.rmw16.xor_u",
            .i64_atomic_rmw32_xor_u => "i64.atomic.rmw32.xor_u",
            .i32_atomic_rmw_xchg => "i32.atomic.rmw.xchg",
            .i64_atomic_rmw_xchg => "i64.atomic.rmw.xchg",
            .i32_atomic_rmw8_xchg_u => "i32.atomic.rmw8.xchg_u",
            .i32_atomic_rmw16_xchg_u => "i32.atomic.rmw16.xchg_u",
            .i64_atomic_rmw8_xchg_u => "i64.atomic.rmw8.xchg_u",
            .i64_atomic_rmw16_xchg_u => "i64.atomic.rmw16.xchg_u",
            .i64_atomic_rmw32_xchg_u => "i64.atomic.rmw32.xchg_u",
            .i32_atomic_rmw_cmpxchg => "i32.atomic.rmw.cmpxchg",
            .i64_atomic_rmw_cmpxchg => "i64.atomic.rmw.cmpxchg",
            .i32_atomic_rmw8_cmpxchg_u => "i32.atomic.rmw8.cmpxchg_u",
            .i32_atomic_rmw16_cmpxchg_u => "i32.atomic.rmw16.cmpxchg_u",
            .i64_atomic_rmw8_cmpxchg_u => "i64.atomic.rmw8.cmpxchg_u",
            .i64_atomic_rmw16_cmpxchg_u => "i64.atomic.rmw16.cmpxchg_u",
            .i64_atomic_rmw32_cmpxchg_u => "i64.atomic.rmw32.cmpxchg_u",
            _ => "<unknown>",
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "opcode encoding — single-byte values" {
    try std.testing.expectEqual(@as(u32, 0x00), @intFromEnum(Code.@"unreachable"));
    try std.testing.expectEqual(@as(u32, 0x0b), @intFromEnum(Code.end));
    try std.testing.expectEqual(@as(u32, 0x41), @intFromEnum(Code.i32_const));
    try std.testing.expectEqual(@as(u32, 0xbf), @intFromEnum(Code.f64_reinterpret_i64));
}

test "opcode encoding — prefixed values" {
    try std.testing.expectEqual(@as(u32, 0xfc00), @intFromEnum(Code.i32_trunc_sat_f32_s));
    try std.testing.expectEqual(@as(u32, 0xfd0c), @intFromEnum(Code.v128_const));
    try std.testing.expectEqual(@as(u32, 0xfe00), @intFromEnum(Code.memory_atomic_notify));
    try std.testing.expectEqual(@as(u32, 0xfe4e), @intFromEnum(Code.i64_atomic_rmw32_cmpxchg_u));
}

test "isPrefixed" {
    try std.testing.expect(!Code.nop.isPrefixed());
    try std.testing.expect(!Code.i32_const.isPrefixed());
    try std.testing.expect(Code.i32_trunc_sat_f32_s.isPrefixed());
    try std.testing.expect(Code.v128_load.isPrefixed());
    try std.testing.expect(Code.memory_atomic_notify.isPrefixed());
}

test "getPrefix" {
    try std.testing.expectEqual(@as(u8, 0), Code.nop.getPrefix());
    try std.testing.expectEqual(@as(u8, 0), Code.@"return".getPrefix());
    try std.testing.expectEqual(prefix_math, Code.i32_trunc_sat_f32_s.getPrefix());
    try std.testing.expectEqual(prefix_simd, Code.v128_const.getPrefix());
    try std.testing.expectEqual(prefix_threads, Code.memory_atomic_notify.getPrefix());
}

test "getCode" {
    try std.testing.expectEqual(@as(u32, 0x01), Code.nop.getCode());
    try std.testing.expectEqual(@as(u32, 0x41), Code.i32_const.getCode());
    try std.testing.expectEqual(@as(u32, 0x00), Code.i32_trunc_sat_f32_s.getCode());
    try std.testing.expectEqual(@as(u32, 0x07), Code.i64_trunc_sat_f64_u.getCode());
    try std.testing.expectEqual(@as(u32, 0x0c), Code.v128_const.getCode());
    try std.testing.expectEqual(@as(u32, 0x00), Code.memory_atomic_notify.getCode());
}

test "getBytes — single-byte opcode" {
    var buf: [6]u8 = undefined;
    const len = Code.nop.getBytes(&buf);
    try std.testing.expectEqual(@as(u8, 1), len);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
}

test "getBytes — prefixed opcode (small code)" {
    var buf: [6]u8 = undefined;
    const len = Code.i32_trunc_sat_f32_s.getBytes(&buf);
    try std.testing.expectEqual(@as(u8, 2), len);
    try std.testing.expectEqual(prefix_math, buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
}

test "getBytes — SIMD opcode" {
    var buf: [6]u8 = undefined;
    const len = Code.v128_const.getBytes(&buf);
    try std.testing.expectEqual(@as(u8, 2), len);
    try std.testing.expectEqual(prefix_simd, buf[0]);
    try std.testing.expectEqual(@as(u8, 0x0c), buf[1]);
}

test "getBytes — relaxed SIMD opcode (LEB128 multi-byte)" {
    var buf: [6]u8 = undefined;
    // i8x16_relaxed_swizzle = 0xfd_100, sub-opcode = 0x100
    const len = Code.i8x16_relaxed_swizzle.getBytes(&buf);
    try std.testing.expectEqual(@as(u8, 3), len);
    try std.testing.expectEqual(prefix_simd, buf[0]);
    // 0x100 in LEB128 = 0x80 0x02
    try std.testing.expectEqual(@as(u8, 0x80), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[2]);
}

test "isEnabled — MVP opcodes always enabled" {
    const mvp = Feature.Set{};
    try std.testing.expect(Code.nop.isEnabled(mvp));
    try std.testing.expect(Code.i32_add.isEnabled(mvp));
    try std.testing.expect(Code.i32_const.isEnabled(mvp));
    try std.testing.expect(Code.call.isEnabled(mvp));
    try std.testing.expect(Code.end.isEnabled(mvp));
}

test "isEnabled — feature-gated opcodes respect flags" {
    const none = Feature.Set{
        .mutable_globals = false,
        .sat_float_to_int = false,
        .sign_extension = false,
        .simd = false,
        .multi_value = false,
        .bulk_memory = false,
        .reference_types = false,
    };

    // Exceptions
    try std.testing.expect(!Code.try_.isEnabled(none));
    try std.testing.expect(!Code.catch_.isEnabled(none));
    try std.testing.expect(!Code.throw.isEnabled(none));
    var with_exc = none;
    with_exc.exceptions = true;
    try std.testing.expect(Code.try_.isEnabled(with_exc));

    // Tail call
    try std.testing.expect(!Code.return_call.isEnabled(none));
    var with_tail = none;
    with_tail.tail_call = true;
    try std.testing.expect(Code.return_call.isEnabled(with_tail));

    // Saturating float-to-int
    try std.testing.expect(!Code.i32_trunc_sat_f32_s.isEnabled(none));
    var with_sat = none;
    with_sat.sat_float_to_int = true;
    try std.testing.expect(Code.i32_trunc_sat_f32_s.isEnabled(with_sat));

    // Sign extension
    try std.testing.expect(!Code.i32_extend8_s.isEnabled(none));
    var with_sign = none;
    with_sign.sign_extension = true;
    try std.testing.expect(Code.i32_extend8_s.isEnabled(with_sign));

    // SIMD
    try std.testing.expect(!Code.v128_load.isEnabled(none));
    var with_simd = none;
    with_simd.simd = true;
    try std.testing.expect(Code.v128_load.isEnabled(with_simd));

    // Threads
    try std.testing.expect(!Code.memory_atomic_notify.isEnabled(none));
    var with_threads = none;
    with_threads.threads = true;
    try std.testing.expect(Code.memory_atomic_notify.isEnabled(with_threads));

    // Bulk memory
    try std.testing.expect(!Code.memory_init.isEnabled(none));
    var with_bulk = none;
    with_bulk.bulk_memory = true;
    try std.testing.expect(Code.memory_init.isEnabled(with_bulk));

    // Reference types
    try std.testing.expect(!Code.ref_null.isEnabled(none));
    var with_ref = none;
    with_ref.reference_types = true;
    try std.testing.expect(Code.ref_null.isEnabled(with_ref));

    // Function references
    try std.testing.expect(!Code.call_ref.isEnabled(none));
    var with_funcref = none;
    with_funcref.function_references = true;
    try std.testing.expect(Code.call_ref.isEnabled(with_funcref));

    // Multi-value (select_t)
    try std.testing.expect(!Code.select_t.isEnabled(none));
    var with_mv = none;
    with_mv.multi_value = true;
    try std.testing.expect(Code.select_t.isEnabled(with_mv));

    // Wide arithmetic
    try std.testing.expect(!Code.i64_add128.isEnabled(none));
    var with_wide = none;
    with_wide.wide_arithmetic = true;
    try std.testing.expect(Code.i64_add128.isEnabled(with_wide));

    // Relaxed SIMD
    try std.testing.expect(!Code.i8x16_relaxed_swizzle.isEnabled(none));
    var with_relaxed = none;
    with_relaxed.relaxed_simd = true;
    try std.testing.expect(Code.i8x16_relaxed_swizzle.isEnabled(with_relaxed));
}

test "isEnabled — default features enable expected proposals" {
    const defaults = Feature.Set{};
    // These should be enabled by default
    try std.testing.expect(Code.i32_trunc_sat_f32_s.isEnabled(defaults));
    try std.testing.expect(Code.i32_extend8_s.isEnabled(defaults));
    try std.testing.expect(Code.v128_load.isEnabled(defaults));
    try std.testing.expect(Code.memory_init.isEnabled(defaults));
    try std.testing.expect(Code.ref_null.isEnabled(defaults));
    try std.testing.expect(Code.select_t.isEnabled(defaults));
    // These should NOT be enabled by default
    try std.testing.expect(!Code.try_.isEnabled(defaults));
    try std.testing.expect(!Code.return_call.isEnabled(defaults));
    try std.testing.expect(!Code.memory_atomic_notify.isEnabled(defaults));
    try std.testing.expect(!Code.i8x16_relaxed_swizzle.isEnabled(defaults));
    try std.testing.expect(!Code.i64_add128.isEnabled(defaults));
}

test "name — spot checks" {
    try std.testing.expectEqualStrings("unreachable", Code.@"unreachable".name());
    try std.testing.expectEqualStrings("i32.const", Code.i32_const.name());
    try std.testing.expectEqualStrings("memory.size", Code.memory_size.name());
    try std.testing.expectEqualStrings("i32.trunc_sat_f32_s", Code.i32_trunc_sat_f32_s.name());
    try std.testing.expectEqualStrings("v128.const", Code.v128_const.name());
    try std.testing.expectEqualStrings("memory.atomic.notify", Code.memory_atomic_notify.name());
    try std.testing.expectEqualStrings("<unknown>", (@as(Code, @enumFromInt(0xFFFF))).name());
}
