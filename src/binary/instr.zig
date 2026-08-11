//! Where one instruction ends and the next begins.
//!
//! Both the binary reader and the text writer have to walk a run of encoded
//! instructions: the reader to find the `end` that closes a constant
//! expression, the writer to print a function body. Getting this wrong is
//! quiet rather than loud -- a mis-sized immediate is read as an opcode, and
//! the scan wanders off into the middle of the next instruction -- so the two
//! share one description of what each opcode carries rather than keeping a
//! copy each.

const std = @import("std");
const leb128 = @import("../leb128.zig");
const types = @import("../types.zig");

pub const Error = error{
    /// A run of instructions ends in the middle of one.
    TruncatedBody,
    /// An opcode this module has no description of. Reported rather than
    /// guessed at, because guessing desynchronises the whole scan.
    UnsupportedOpcode,
};

/// The immediate operands that follow an opcode. Most opcodes take none;
/// the rest fall into these shapes, which is what makes decoding a body
/// tractable without a per-opcode table of 540 entries.
pub const Imm = enum {
    none,
    /// A block signature: `0x40`, a single value type, or a type index.
    block_type,
    /// One u32 index (label, function, local, global, table, ...).
    index,
    /// Two u32 indices, in the order the binary format writes them.
    index_pair,
    /// Two u32 indices that the text format states in the opposite order
    /// from the binary one, as `memory.init` and `table.init` do.
    index_pair_swapped,
    /// An optional table index followed by `(type N)`. The binary form
    /// writes the type first, so the two are also swapped here.
    call_indirect,
    /// A vector of label indices plus the default label.
    br_table,
    /// Alignment, an optional memory index, and an offset.
    mem_arg,
    /// A memarg followed by a lane index.
    mem_arg_lane,
    /// A single lane index byte.
    lane,
    /// Sixteen lane index bytes.
    shuffle,
    /// A sixteen byte vector constant.
    v128,
    s32,
    s64,
    f32,
    f64,
    /// A heap type, for `ref.null`.
    heap_type,
    /// A vector of value types, for the typed `select`.
    select_types,
    /// A block signature followed by a vector of catch clauses.
    try_table,
    /// The single reserved byte carried by `atomic.fence`.
    reserved_byte,
};

/// Immediate shape for an opcode, or null when this writer has no way to
/// print it. Returning null is deliberate: emitting a mnemonic without its
/// operands, or skipping the instruction, would produce wat that no longer
/// means what the module said.
pub fn immediateShape(prefix: u8, code: u32) ?Imm {
    return switch (prefix) {
        0 => switch (code) {
            0x02, 0x03, 0x04 => .block_type,
            // Legacy exception handling is not supported (see #366), and
            // the lexer has no keywords for it, so there is nothing valid
            // to print.
            0x06, 0x07, 0x09, 0x18, 0x19 => null,
            0x00, 0x01, 0x05, 0x0a, 0x0b, 0x0f, 0x1a, 0x1b => .none,
            0x08, 0x0c, 0x0d, 0x10, 0x12, 0x14, 0x15 => .index,
            0x0e => .br_table,
            0x11, 0x13 => .call_indirect,
            0x1c => .select_types,
            0x1f => .try_table,
            0x20...0x26 => .index,
            0x28...0x3e => .mem_arg,
            0x3f, 0x40 => .index,
            0x41 => .s32,
            0x42 => .s64,
            0x43 => .f32,
            0x44 => .f64,
            0x45...0xc4 => .none,
            0xd0 => .heap_type,
            0xd1, 0xd3, 0xd4 => .none,
            0xd2, 0xd5, 0xd6 => .index,
            else => null,
        },
        0xfc => switch (code) {
            0x00...0x07 => .none,
            0x08, 0x0c => .index_pair_swapped,
            0x0a, 0x0e => .index_pair,
            0x09, 0x0b, 0x0d, 0x0f, 0x10, 0x11 => .index,
            0x13...0x16 => .none,
            else => null,
        },
        0xfd => switch (code) {
            0x00...0x0b => .mem_arg,
            0x0c => .v128,
            0x0d => .shuffle,
            0x15...0x22 => .lane,
            0x54...0x5b => .mem_arg_lane,
            0x5c, 0x5d => .mem_arg,
            else => .none,
        },
        0xfe => switch (code) {
            0x03 => .reserved_byte,
            else => .mem_arg,
        },
        else => null,
    };
}

/// An opcode and the shape of the immediates that follow it.
pub const Decoded = struct { prefix: u8, code: u32, shape: Imm };

/// Read the opcode at `pos`, advancing past it and its prefix.
pub fn decode(bytes: []const u8, pos: *usize) Error!Decoded {
    const byte = bytes[pos.*];
    pos.* += 1;

    var prefix: u8 = 0;
    var code: u32 = byte;
    if (byte == 0xfc or byte == 0xfd or byte == 0xfe or byte == 0xfb) {
        prefix = byte;
        code = try readU32At(bytes, pos);
    }

    return .{
        .prefix = prefix,
        .code = code,
        .shape = immediateShape(prefix, code) orelse return error.UnsupportedOpcode,
    };
}


fn readU32At(bytes: []const u8, pos: *usize) Error!u32 {
    const r = leb128.readU32Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
    pos.* += r.bytes_read;
    return r.value;
}

fn readU64At(bytes: []const u8, pos: *usize) Error!u64 {
    const r = leb128.readU64Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
    pos.* += r.bytes_read;
    return r.value;
}

fn readS64At(bytes: []const u8, pos: *usize) Error!i64 {
    const r = leb128.readS64Leb128(bytes[pos.*..]) catch return error.TruncatedBody;
    pos.* += r.bytes_read;
    return r.value;
}

fn skipBytes(n: usize, bytes: []const u8, pos: *usize) Error!void {
    if (pos.* + n > bytes.len) return error.TruncatedBody;
    pos.* += n;
}

/// Step over a block signature: `0x40`, a reference type, a value type, or an
/// s33 type index.
fn skipBlockType(bytes: []const u8, pos: *usize) Error!void {
    if (pos.* >= bytes.len) return error.TruncatedBody;
    const byte = bytes[pos.*];
    if (byte == 0x63 or byte == 0x64) {
        pos.* += 1;
        return skipHeapType(bytes, pos);
    }
    if (byte < 0x80) {
        pos.* += 1;
        return;
    }
    _ = try readS64At(bytes, pos);
}

/// Step over a heap type, which is an s33 and so may span several bytes.
fn skipHeapType(bytes: []const u8, pos: *usize) Error!void {
    if (pos.* >= bytes.len) return error.TruncatedBody;
    if (bytes[pos.*] < 0x80) {
        pos.* += 1;
        return;
    }
    _ = try readS64At(bytes, pos);
}

/// A memarg is an alignment, an optional memory index that bit `0x40` of the
/// alignment announces, and an offset.
fn skipMemArg(bytes: []const u8, pos: *usize) Error!void {
    const raw = try readU32At(bytes, pos);
    if ((raw & 0x40) != 0) _ = try readU32At(bytes, pos);
    _ = try readU64At(bytes, pos);
}

/// Step over an opcode's immediates without interpreting them, leaving `pos`
/// on the next opcode. This must consume exactly what the text writer's
/// `writeImmediates` consumes for the same shape; a test holds them together.
pub fn skipImmediates(shape: Imm, bytes: []const u8, pos: *usize) Error!void {
    switch (shape) {
        .none => {},
        .block_type => try skipBlockType(bytes, pos),
        .index => _ = try readU32At(bytes, pos),
        .index_pair, .index_pair_swapped, .call_indirect => {
            _ = try readU32At(bytes, pos);
            _ = try readU32At(bytes, pos);
        },
        .br_table => {
            const count = try readU32At(bytes, pos);
            for (0..count + 1) |_| _ = try readU32At(bytes, pos);
        },
        .mem_arg => try skipMemArg(bytes, pos),
        .mem_arg_lane => {
            try skipMemArg(bytes, pos);
            try skipBytes(1, bytes, pos);
        },
        .lane, .reserved_byte => try skipBytes(1, bytes, pos),
        .shuffle, .v128 => try skipBytes(16, bytes, pos),
        .s32, .s64 => _ = try readS64At(bytes, pos),
        .f32 => try skipBytes(4, bytes, pos),
        .f64 => try skipBytes(8, bytes, pos),
        .heap_type => try skipHeapType(bytes, pos),
        .select_types => {
            const count = try readU32At(bytes, pos);
            try skipBytes(count, bytes, pos);
        },
        .try_table => {
            try skipBlockType(bytes, pos);
            const count = try readU32At(bytes, pos);
            for (0..count) |_| {
                if (pos.* >= bytes.len) return error.TruncatedBody;
                const kind = bytes[pos.*];
                pos.* += 1;
                if (kind > 0x03) return error.UnsupportedOpcode;
                if (kind == 0x00 or kind == 0x01) _ = try readU32At(bytes, pos);
                _ = try readU32At(bytes, pos);
            }
        },
    }
}
