//! Byte-level component rewriter for externname version substitution.
//!
//! Component imports/exports carry their interface names as inline
//! WIT externnames (e.g. `wasi:io/error@0.2.6`). When `wabt component
//! compose` aligns a version mismatch across a seam (issue #209) the
//! consumer + provider binaries must both emit the chosen version
//! across every name slot — not just the top-level imports — because
//! the wrapper passes those nested bytes through verbatim via
//! `passthroughComponent`, and the wasmtime instantiation seam expects
//! instantiate-arg names to match the nested component's import
//! decls verbatim.
//!
//! The rewriter walks a component byte stream and rebuilds it with
//! every `extern_name.parse`-recognized name run through
//! `extern_name.rewrite(rules)`. Sections that don't carry externnames
//! (most custom sections, core_type, alias, canon, start, value) are
//! copied verbatim — preserving the original section interleaving
//! that the AST cannot represent. Sections that DO carry externnames
//! are parsed item-by-item; each item's name is rewritten, the rest
//! of the item's bytes are copied verbatim. Nested-component sections
//! recurse.
//!
//! Coverage:
//!
//!   * top-level import section (id=10) — #209/#210
//!   * top-level export section (id=11) — #209/#210
//!   * type section (id=7), descending into component-/instance-type
//!     bodies' import + export decls — #209/#210
//!   * component-instance section (id=5):
//!       - instantiate arg names (plain `name` slots whose string
//!         content carries the externname grammar) — #212
//!       - inline-export names (externname-prefix slots) — #209/#210
//!   * core-instance section (id=2):
//!       - instantiate arg names (plain `name` slots) — #212
//!       - inline-export names (plain `name` slots) — #212
//!   * core-module section (id=1): descend into the embedded core
//!     wasm; rewrite the `mod` field of each core import (core
//!     section id=2). Core import `fld` fields, all other core
//!     sections, and the core wasm preamble pass through verbatim
//!     — #212.
//!   * nested-component section (id=4): recurse into the body — #209.
//!   * custom section (id=0), name = `name` / `component-name`:
//!     parse subsections, scan each name string for embedded
//!     externname substrings (e.g. `"ty-wasi:io/error@0.2.10"`),
//!     rewrite each one's `@ver` suffix. Other custom sections
//!     (producer metadata, `component-type:…:encoded world`) pass
//!     through verbatim because their layout is opaque. Cosmetic;
//!     wasmtime ignores debug names but `wasm-tools dump` / `jco
//!     wit` walk them — #214.
//!
//! Scope intentionally excludes alias `instance_export.name` — it
//! references an export *within* a source instance (a method or
//! resource name, not a package externname).
//!
//! Wrapper-side wiring (provider Instantiate args matching the
//! wrapper's outer-import indexes) is NOT this module's job — that
//! lives in `src/tools/component_compose.zig`'s wrapper construction,
//! see issue #214.
//!
//! All section size LEBs at every nesting level recompute when an
//! externname's encoded byte length changes (e.g. `@0.2.10` →
//! `@0.2.6` shortens by 2 bytes per occurrence).

const std = @import("std");
const leb128 = @import("../leb128.zig");
const extern_name = @import("extern_name.zig");

pub const Error = error{
    OutOfMemory,
    UnexpectedEnd,
    InvalidEncoding,
    InvalidUtf8,
    Overflow,
};

const Allocator = std.mem.Allocator;

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEnd;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn peekByte(self: *const Reader) Error!u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEnd;
        return self.data[self.pos];
    }

    fn readU32(self: *Reader) Error!u32 {
        const slice = self.data[self.pos..];
        const r = leb128.readU32Leb128(slice) catch return error.UnexpectedEnd;
        self.pos += r.bytes_read;
        return r.value;
    }

    fn readU64(self: *Reader) Error!u64 {
        const slice = self.data[self.pos..];
        const r = leb128.readU64Leb128(slice) catch return error.UnexpectedEnd;
        self.pos += r.bytes_read;
        return r.value;
    }

    fn readS33(self: *Reader) Error!i64 {
        const slice = self.data[self.pos..];
        const r = leb128.readS64Leb128(slice) catch |err| switch (err) {
            error.Overflow => return error.InvalidEncoding,
            error.UnexpectedEnd => return error.UnexpectedEnd,
        };
        if (r.value < -(@as(i64, 1) << 32) or r.value >= (@as(i64, 1) << 32))
            return error.InvalidEncoding;
        self.pos += r.bytes_read;
        return r.value;
    }

    fn readBytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEnd;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readName(self: *Reader) Error![]const u8 {
        const len = try self.readU32();
        const bytes = try self.readBytes(len);
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        return bytes;
    }
};

fn writeU32Leb(w: *std.ArrayListUnmanaged(u8), arena: Allocator, v: u32) Error!void {
    var buf: [5]u8 = undefined;
    const n = leb128.writeU32Leb128(&buf, v);
    try w.appendSlice(arena, buf[0..n]);
}

const magic_bytes: [4]u8 = .{ 0x00, 0x61, 0x73, 0x6d };
const version_bytes: [4]u8 = .{ 0x0d, 0x00, 0x01, 0x00 };

/// Rewrite extern names in a component binary per `rules`. Returns
/// arena-allocated freshly-encoded bytes; the input is unchanged.
pub fn apply(arena: Allocator, bytes: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    if (bytes.len < 8) return error.UnexpectedEnd;
    if (!std.mem.eql(u8, bytes[0..4], &magic_bytes)) return error.InvalidEncoding;
    if (!std.mem.eql(u8, bytes[4..8], &version_bytes)) return error.InvalidEncoding;

    var out = std.ArrayListUnmanaged(u8).empty;
    try out.appendSlice(arena, bytes[0..8]);

    var r = Reader{ .data = bytes, .pos = 8 };
    while (r.remaining() > 0) {
        const id = try r.readByte();
        const size = try r.readU32();
        const body_start = r.pos;
        if (body_start + size > r.data.len) return error.UnexpectedEnd;
        const body = r.data[body_start .. body_start + size];
        r.pos = body_start + size;

        const new_body_opt: ?[]const u8 = switch (id) {
            // Section IDs that may carry component-level externnames.
            0 => try rewriteCustomSection(arena, body, rules),
            1 => try rewriteCoreModuleSection(arena, body, rules),
            2 => try rewriteCoreInstanceSection(arena, body, rules),
            4 => try apply(arena, body, rules),
            5 => try rewriteInstanceSection(arena, body, rules),
            7 => try rewriteTypeSection(arena, body, rules),
            10 => try rewriteImportSection(arena, body, rules),
            11 => try rewriteExportSection(arena, body, rules),
            else => null,
        };

        if (new_body_opt) |new_body| {
            try out.append(arena, id);
            try writeU32Leb(&out, arena, @intCast(new_body.len));
            try out.appendSlice(arena, new_body);
        } else {
            // Verbatim — emit the source bytes for the entire section.
            try out.append(arena, id);
            try writeU32Leb(&out, arena, size);
            try out.appendSlice(arena, body);
        }
    }

    return out.toOwnedSlice(arena);
}

// ── Section-body rewriters ─────────────────────────────────────────────────

fn rewriteImportSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try rewriteExternNameSlot(&r, &w, arena, rules);
        try copyExternDesc(&r, &w, arena);
    }
    return w.toOwnedSlice(arena);
}

fn rewriteExportSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try rewriteExternNameSlot(&r, &w, arena, rules);
        try copySortIdx(&r, &w, arena);
        const has_desc = try r.readByte();
        try w.append(arena, has_desc);
        switch (has_desc) {
            0x00 => {},
            0x01 => try copyExternDesc(&r, &w, arena),
            else => return error.InvalidEncoding,
        }
    }
    return w.toOwnedSlice(arena);
}

fn rewriteInstanceSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const tag = try r.readByte();
        try w.append(arena, tag);
        switch (tag) {
            0x00 => {
                // instantiate: component_idx + count + (plain-name + sortidx)*
                //
                // The arg `name` is a plain `name` (no externname prefix
                // byte) but its string content is the externname form
                // when it provides a top-level component package
                // (e.g. `wasi:io/error@0.2.10`); see issue #212 site 2.
                // Non-externname strings pass through unchanged.
                try copyU32(&r, &w, arena); // component_idx
                const arg_count = try r.readU32();
                try writeU32Leb(&w, arena, arg_count);
                var j: u32 = 0;
                while (j < arg_count) : (j += 1) {
                    try rewritePlainName(&r, &w, arena, rules);
                    try copySortIdx(&r, &w, arena);
                }
            },
            0x01 => {
                // inline exports: count + (externname + sortidx)*
                const exp_count = try r.readU32();
                try writeU32Leb(&w, arena, exp_count);
                var j: u32 = 0;
                while (j < exp_count) : (j += 1) {
                    try rewriteExternNameSlot(&r, &w, arena, rules);
                    try copySortIdx(&r, &w, arena);
                }
            },
            else => return error.InvalidEncoding,
        }
    }
    return w.toOwnedSlice(arena);
}

/// Component-level core-instance section (id=2) rewriter (issue #212).
///
/// Core-instance grammar:
///
///   coreinstance       ::= coreinstanceexpr
///   coreinstanceexpr   ::= 0x00 m:<moduleidx>  arg*:vec(coreinstantiatearg)
///                       |  0x01 export*:vec(coreinlineexport)
///   coreinstantiatearg ::= n:<name> 0x12 i:<coreinstanceidx>
///   coreinlineexport   ::= n:<name> s:<coresort> i:<coreidx>
///
/// Both `name` slots are plain names (no externname prefix byte) but
/// their string content carries the externname grammar in real
/// `wasm-tools component new` output — the core-instance instantiate
/// arg names declare which top-level component-package imports back
/// the core module's `(import "wasi:io/poll@0.2.10" "..." ...)` entries.
fn rewriteCoreInstanceSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const tag = try r.readByte();
        try w.append(arena, tag);
        switch (tag) {
            0x00 => {
                try copyU32(&r, &w, arena); // moduleidx
                const arg_count = try r.readU32();
                try writeU32Leb(&w, arena, arg_count);
                var j: u32 = 0;
                while (j < arg_count) : (j += 1) {
                    try rewritePlainName(&r, &w, arena, rules);
                    // 0x12 (instance sort) + instance idx
                    const sort_byte = try r.readByte();
                    try w.append(arena, sort_byte);
                    try copyU32(&r, &w, arena);
                }
            },
            0x01 => {
                const exp_count = try r.readU32();
                try writeU32Leb(&w, arena, exp_count);
                var j: u32 = 0;
                while (j < exp_count) : (j += 1) {
                    try rewritePlainName(&r, &w, arena, rules);
                    const sort_byte = try r.readByte();
                    try w.append(arena, sort_byte);
                    try copyU32(&r, &w, arena);
                }
            },
            else => return error.InvalidEncoding,
        }
    }
    return w.toOwnedSlice(arena);
}

fn rewriteTypeSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try rewriteOneTypeDef(&r, &w, arena, rules);
    }
    return w.toOwnedSlice(arena);
}

/// Component-level core-module section (id=1) rewriter (issue #212).
///
/// The section's body is a raw core wasm binary (`\x00asm` magic +
/// version + core sections). Only the **core import section** (core
/// id=2) carries externname-grammar strings — the `mod` field of
/// each import is what links the core module to a top-level
/// component-package import (e.g. `(import "wasi:io/poll@0.2.10"
/// "[resource-drop]pollable" ...)`). The `fld` field is the method
/// or resource name within the interface and is not an externname.
///
/// All other core sections (custom, type, function, table, memory,
/// global, export, start, element, code, data, datacount) carry no
/// externname strings and pass through verbatim. We still walk past
/// them via section headers so we can recompute the import section's
/// size LEB when its body length changes.
fn rewriteCoreModuleSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    if (body.len < 8) return error.UnexpectedEnd;
    var w = std.ArrayListUnmanaged(u8).empty;
    // Core preamble: 4 bytes magic + 4 bytes version. We don't
    // validate them here — the loader's pre-pass already ensured the
    // component as a whole is well-formed, and a malformed inner
    // core module will surface at the post-encoding loader.load
    // re-validation.
    try w.appendSlice(arena, body[0..8]);

    var r = Reader{ .data = body, .pos = 8 };
    while (r.remaining() > 0) {
        const id = try r.readByte();
        const size = try r.readU32();
        const body_start = r.pos;
        if (body_start + size > r.data.len) return error.UnexpectedEnd;
        const sec_body = r.data[body_start .. body_start + size];
        r.pos = body_start + size;

        if (id == 2) {
            const new_body = try rewriteCoreImportSection(arena, sec_body, rules);
            try w.append(arena, id);
            try writeU32Leb(&w, arena, @intCast(new_body.len));
            try w.appendSlice(arena, new_body);
        } else {
            try w.append(arena, id);
            try writeU32Leb(&w, arena, size);
            try w.appendSlice(arena, sec_body);
        }
    }
    return w.toOwnedSlice(arena);
}

fn rewriteCoreImportSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // module name — the externname-grammar carrier.
        try rewritePlainName(&r, &w, arena, rules);
        // field name — method / resource name within the interface,
        // never an externname.
        try copyName(&r, &w, arena);
        // importdesc — variable length; track src position and copy
        // verbatim after advancing the reader.
        const desc_start = r.pos;
        try skipCoreImportDesc(&r);
        try w.appendSlice(arena, r.data[desc_start..r.pos]);
    }
    return w.toOwnedSlice(arena);
}

fn skipCoreImportDesc(r: *Reader) Error!void {
    const kind = try r.readByte();
    switch (kind) {
        0x00 => _ = try r.readU32(), // func: typeidx
        0x01 => {
            // table: reftype byte + limits
            _ = try r.readByte();
            try skipCoreLimits(r);
        },
        0x02 => try skipCoreLimits(r), // memory: limits
        0x03 => {
            // global: valtype byte + mut byte
            _ = try r.readByte();
            _ = try r.readByte();
        },
        0x04 => {
            // tag: attribute byte + sig idx
            _ = try r.readByte();
            _ = try r.readU32();
        },
        else => return error.InvalidEncoding,
    }
}

/// Skip past a core-wasm `limits` structure. Mirrors the byte layout
/// `src/binary/reader.zig:readLimits` consumes — flag bits encode
/// has_max (0x01), is_shared (0x02), is_64 (0x04), and custom
/// page-size (0x08).
fn skipCoreLimits(r: *Reader) Error!void {
    const flags = try r.readByte();
    if (flags & 0x04 != 0) {
        _ = try r.readU64();
        if (flags & 0x01 != 0) _ = try r.readU64();
    } else {
        _ = try r.readU32();
        if (flags & 0x01 != 0) _ = try r.readU32();
    }
    if (flags & 0x08 != 0) _ = try r.readU32();
}

// ── #214 cosmetic: rewrite externnames embedded in name custom sections ──
//
// `wasm-tools component new` emits debug-name custom sections
// (`name` for core wasm and `component-name` for component-level)
// containing strings of the form `"ty-wasi:io/error@0.2.10"` etc.
// These never affect instantiation — wasmtime ignores them — but
// downstream cosmetic tools (`wasm-tools dump`, `jco wit`) walk them
// and complain when their version suffix doesn't match the binary's
// outer-import surface.
//
// We scan each name string for embedded externname-shape substrings
// and rewrite each one's `@ver` suffix through `extern_name.rewrite`.
// Other custom sections (producer metadata, `component-type:…:encoded
// world`) pass through verbatim because their byte layout is opaque
// to this module and rewriting them would risk corrupting
// downstream consumers.

fn rewriteCustomSection(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error!?[]u8 {
    var r = Reader{ .data = body };
    const sec_name_len = r.readU32() catch return @as(?[]u8, null);
    if (r.pos + sec_name_len > r.data.len) return @as(?[]u8, null);
    const sec_name = r.data[r.pos .. r.pos + sec_name_len];
    r.pos += sec_name_len;

    if (!std.mem.eql(u8, sec_name, "name") and
        !std.mem.eql(u8, sec_name, "component-name"))
    {
        return null; // copy verbatim
    }

    const payload = r.data[r.pos..];
    const new_payload = rewriteNameSectionPayload(arena, payload, rules) catch {
        return null; // parse failure → verbatim
    };
    if (new_payload.ptr == payload.ptr) return null;

    var w = std.ArrayListUnmanaged(u8).empty;
    try writeU32Leb(&w, arena, @intCast(sec_name.len));
    try w.appendSlice(arena, sec_name);
    try w.appendSlice(arena, new_payload);
    return try w.toOwnedSlice(arena);
}

fn rewriteNameSectionPayload(arena: Allocator, body: []const u8, rules: []const extern_name.Rule) Error![]const u8 {
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    var any_change = false;

    while (r.remaining() > 0) {
        const subsec_id = try r.readByte();
        const subsec_size = try r.readU32();
        const sub_body_start = r.pos;
        if (sub_body_start + subsec_size > r.data.len) return error.UnexpectedEnd;
        const sub_body = r.data[sub_body_start .. sub_body_start + subsec_size];
        r.pos = sub_body_start + subsec_size;

        const new_sub: []const u8 = rewriteNameSubsection(arena, subsec_id, sub_body, rules) catch sub_body;
        if (new_sub.ptr != sub_body.ptr) any_change = true;

        try w.append(arena, subsec_id);
        try writeU32Leb(&w, arena, @intCast(new_sub.len));
        try w.appendSlice(arena, new_sub);
    }

    if (!any_change) return body;
    return try w.toOwnedSlice(arena);
}

/// Rewrite a single name subsection. Subsection id 0 is the module
/// name (single `name` payload); all other ids per the wasm spec
/// carry `namemap = vec(idx + name)`. Indirect name maps (locals,
/// labels, fields) use `vec(idx + namemap)` — we handle those by
/// trying namemap first and falling back via `error.InvalidEncoding`
/// (which the caller treats as a verbatim-copy directive).
fn rewriteNameSubsection(arena: Allocator, id: u8, body: []const u8, rules: []const extern_name.Rule) Error![]const u8 {
    if (id == 0) {
        var r = Reader{ .data = body };
        const len = try r.readU32();
        if (r.pos + len != body.len) return error.InvalidEncoding;
        const name = body[r.pos .. r.pos + len];
        const new_name = try rewriteEmbeddedExternNames(arena, name, rules);
        if (new_name.ptr == name.ptr) return body;
        var w = std.ArrayListUnmanaged(u8).empty;
        try writeU32Leb(&w, arena, @intCast(new_name.len));
        try w.appendSlice(arena, new_name);
        return try w.toOwnedSlice(arena);
    }

    // namemap form: vec(idx + name). If parsing doesn't consume the
    // full body cleanly, bail to verbatim copy via error.InvalidEncoding.
    var r = Reader{ .data = body };
    var w = std.ArrayListUnmanaged(u8).empty;
    var any_change = false;
    const count = try r.readU32();
    try writeU32Leb(&w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const idx = try r.readU32();
        const len = try r.readU32();
        if (r.pos + len > body.len) return error.UnexpectedEnd;
        const name = body[r.pos .. r.pos + len];
        r.pos += len;
        const new_name = try rewriteEmbeddedExternNames(arena, name, rules);
        if (new_name.ptr != name.ptr) any_change = true;
        try writeU32Leb(&w, arena, idx);
        try writeU32Leb(&w, arena, @intCast(new_name.len));
        try w.appendSlice(arena, new_name);
    }
    if (r.pos != body.len) return error.InvalidEncoding;
    if (!any_change) return body;
    return try w.toOwnedSlice(arena);
}

/// Scan `s` for substrings that look like externnames
/// (`[ns:]?pkg/iface[@digits.digits.digits]`) and rewrite each one's
/// `@ver` suffix per the rule list. Identifier chars include
/// alphanumerics, `-`, and `_`; identifiers must start with an
/// alpha character. Returns `s` unchanged when no rule fires.
///
/// The scanner tries each position as a potential externname start,
/// not just identifier-boundary positions — this lets debug strings
/// like `"ty-wasi:io/error@0.2.10"` (with a static `"ty-"` prefix)
/// pick up the embedded `wasi:io/error@0.2.10` match even though
/// `ty-wasi` is one greedy identifier.
fn rewriteEmbeddedExternNames(arena: Allocator, s: []const u8, rules: []const extern_name.Rule) Error![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    var any_change = false;
    var i: usize = 0;
    while (i < s.len) {
        if (matchExternNameAt(s, i)) |end| {
            const orig = s[i..end];
            const rewritten = try extern_name.rewrite(arena, orig, rules);
            if (rewritten.ptr != orig.ptr) {
                try out.appendSlice(arena, rewritten);
                any_change = true;
                i = end;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    if (!any_change) return s;
    return try out.toOwnedSlice(arena);
}

fn matchExternNameAt(s: []const u8, start: usize) ?usize {
    if (start >= s.len) return null;
    if (!isExternNameIdentStart(s[start])) return null;

    var i = start;
    while (i < s.len and isExternNameIdentChar(s[i])) i += 1;
    if (i == start) return null;
    if (i >= s.len) return null;

    // Optional `<ns>:` prefix.
    if (s[i] == ':') {
        i += 1;
        const pkg_start = i;
        while (i < s.len and isExternNameIdentChar(s[i])) i += 1;
        if (i == pkg_start) return null;
        if (i >= s.len) return null;
    } else if (s[i] != '/') {
        return null;
    }

    // Slash separator.
    if (s[i] != '/') return null;
    i += 1;

    // Iface ident.
    const iface_start = i;
    while (i < s.len and isExternNameIdentChar(s[i])) i += 1;
    if (i == iface_start) return null;

    // Optional `@digits.digits.digits` suffix.
    if (i < s.len and s[i] == '@') {
        const at_pos = i;
        i += 1;
        const v_start = i;
        while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
        if (i == v_start) {
            // `@` with no version digits — back up; the @ probably
            // belongs to surrounding text.
            i = at_pos;
        }
    }

    return i;
}

fn isExternNameIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isExternNameIdentChar(c: u8) bool {
    return isExternNameIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
}

// ── Type-def walking ──────────────────────────────────────────────────────

fn rewriteOneTypeDef(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator, rules: []const extern_name.Rule) Error!void {
    const start = r.pos;
    const peek = try r.peekByte();
    switch (peek) {
        0x41 => {
            // component type — walk decls
            _ = try r.readByte();
            try w.append(arena, 0x41);
            try rewriteDeclList(r, w, arena, rules, .component_type);
        },
        0x42 => {
            // instance type — walk decls
            _ = try r.readByte();
            try w.append(arena, 0x42);
            try rewriteDeclList(r, w, arena, rules, .instance_type);
        },
        else => {
            // Other deftype — no externnames inside, copy verbatim by
            // skipping with the parser.
            try skipTypeDef(r);
            try w.appendSlice(arena, r.data[start..r.pos]);
        },
    }
}

const DeclScope = enum { component_type, instance_type };

fn rewriteDeclList(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator, rules: []const extern_name.Rule, scope: DeclScope) Error!void {
    const count = try r.readU32();
    try writeU32Leb(w, arena, count);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const tag = try r.readByte();
        try w.append(arena, tag);
        switch (tag) {
            0x00 => {
                // core_type — copy verbatim
                const ct_start = r.pos;
                try skipCoreType(r);
                try w.appendSlice(arena, r.data[ct_start..r.pos]);
            },
            0x01 => {
                // nested type def — may itself be a component/instance type
                try rewriteOneTypeDef(r, w, arena, rules);
            },
            0x02 => {
                // alias — copy verbatim
                const al_start = r.pos;
                try skipAlias(r);
                try w.appendSlice(arena, r.data[al_start..r.pos]);
            },
            0x03 => {
                if (scope != .component_type) return error.InvalidEncoding;
                try rewriteExternNameSlot(r, w, arena, rules);
                try copyExternDesc(r, w, arena);
            },
            0x04 => {
                try rewriteExternNameSlot(r, w, arena, rules);
                try copyExternDesc(r, w, arena);
            },
            else => return error.InvalidEncoding,
        }
    }
}

// ── Slot rewriter & verbatim copiers ───────────────────────────────────────

fn rewriteExternNameSlot(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator, rules: []const extern_name.Rule) Error!void {
    const prefix = try r.readByte();
    if (prefix > 0x02) return error.InvalidEncoding;
    try w.append(arena, prefix);
    const len = try r.readU32();
    const name = try r.readBytes(len);
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    const new_name = try extern_name.rewrite(arena, name, rules);
    try writeU32Leb(w, arena, @intCast(new_name.len));
    try w.appendSlice(arena, new_name);
    if (prefix == 0x02) {
        // versionsuffix: len + bytes — copy verbatim (rewrite only
        // touches the in-line `@ver` suffix on the importname itself).
        try copyName(r, w, arena);
    }
}

/// Rewrite a plain `name` slot (no externname prefix byte). The
/// string content is run through `extern_name.rewrite`; non-extern
/// strings (e.g. `"env"`, `"__main_module__"`, method names) pass
/// through unchanged because `extern_name.parse` returns null for
/// them. Used by:
///   * core-instance instantiate arg names (component section id=2)
///   * core-instance inline-export names (component section id=2)
///   * component-instance instantiate arg names (component section id=5)
///   * core wasm import `module` names (core section id=2 inside id=1)
fn rewritePlainName(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator, rules: []const extern_name.Rule) Error!void {
    const len = try r.readU32();
    const name = try r.readBytes(len);
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidUtf8;
    const new_name = try extern_name.rewrite(arena, name, rules);
    try writeU32Leb(w, arena, @intCast(new_name.len));
    try w.appendSlice(arena, new_name);
}

fn copyName(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator) Error!void {
    const len = try r.readU32();
    try writeU32Leb(w, arena, len);
    const bytes = try r.readBytes(len);
    try w.appendSlice(arena, bytes);
}

fn copyU32(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator) Error!void {
    const v = try r.readU32();
    try writeU32Leb(w, arena, v);
}

fn copySortIdx(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator) Error!void {
    const start = r.pos;
    try skipSortIdx(r);
    try w.appendSlice(arena, r.data[start..r.pos]);
}

fn copyExternDesc(r: *Reader, w: *std.ArrayListUnmanaged(u8), arena: Allocator) Error!void {
    const start = r.pos;
    try skipExternDesc(r);
    try w.appendSlice(arena, r.data[start..r.pos]);
}

// ── Skip helpers (advance reader without producing AST) ────────────────────

fn skipSortIdx(r: *Reader) Error!void {
    const sort = try r.readByte();
    switch (sort) {
        0x00 => _ = try r.readByte(), // core sort discriminator
        0x01, 0x02, 0x03, 0x04, 0x05 => {},
        else => return error.InvalidEncoding,
    }
    _ = try r.readU32();
}

fn skipExternDesc(r: *Reader) Error!void {
    const tag = try r.readByte();
    switch (tag) {
        0x00 => {
            const sub = try r.readByte();
            if (sub != 0x11) return error.InvalidEncoding;
            _ = try r.readU32();
        },
        0x01 => _ = try r.readU32(),
        0x02 => try skipValType(r),
        0x03 => {
            const bt = try r.readByte();
            switch (bt) {
                0x00 => _ = try r.readU32(),
                0x01 => {},
                else => return error.InvalidEncoding,
            }
        },
        0x04 => _ = try r.readU32(),
        0x05 => _ = try r.readU32(),
        else => return error.InvalidEncoding,
    }
}

fn skipValType(r: *Reader) Error!void {
    const raw = try r.readS33();
    if (raw >= 0) return; // type_idx
    if (raw < -64) return error.InvalidEncoding;
    const tag: u8 = @intCast(raw + 0x80);
    switch (tag) {
        0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x7A, 0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73 => {},
        0x69, 0x68 => _ = try r.readU32(),
        else => return error.InvalidEncoding,
    }
}

fn skipCoreValType(r: *Reader) Error!void {
    _ = try r.readByte();
}

fn skipTypeDef(r: *Reader) Error!void {
    const tag = try r.peekByte();
    if (tag == 0x72 or tag == 0x71 or tag == 0x70 or tag == 0x6F or
        tag == 0x6E or tag == 0x6D or tag == 0x6B or tag == 0x6A or
        tag == 0x3F or tag == 0x40 or tag == 0x41 or tag == 0x42)
    {
        try skipCompoundTypeDef(r);
    } else {
        try skipValType(r);
    }
}

fn skipCompoundTypeDef(r: *Reader) Error!void {
    const tag = try r.readByte();
    switch (tag) {
        0x72 => {
            // record: vec<field>
            const n = try r.readU32();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                _ = try r.readName();
                try skipValType(r);
            }
        },
        0x71 => {
            // variant: vec<case>
            const n = try r.readU32();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                _ = try r.readName();
                const has_type = try r.readByte();
                if (has_type != 0) try skipValType(r);
                const trailer = try r.readByte();
                if (trailer != 0x00) return error.InvalidEncoding;
            }
        },
        0x70 => try skipValType(r), // list
        0x6F => {
            // tuple
            const n = try r.readU32();
            var i: u32 = 0;
            while (i < n) : (i += 1) try skipValType(r);
        },
        0x6E, 0x6D => {
            // flags / enum
            const n = try r.readU32();
            var i: u32 = 0;
            while (i < n) : (i += 1) _ = try r.readName();
        },
        0x6B => try skipValType(r), // option
        0x6A => {
            // result
            const has_ok = try r.readByte();
            if (has_ok != 0) try skipValType(r);
            const has_err = try r.readByte();
            if (has_err != 0) try skipValType(r);
        },
        0x3F => {
            // resource
            try skipCoreValType(r);
            const has_dtor = try r.readByte();
            if (has_dtor != 0) _ = try r.readU32();
        },
        0x40 => {
            // func type
            const pn = try r.readU32();
            var i: u32 = 0;
            while (i < pn) : (i += 1) {
                _ = try r.readName();
                try skipValType(r);
            }
            const res_tag = try r.readByte();
            switch (res_tag) {
                0x00 => try skipValType(r),
                0x01 => {
                    const zero = try r.readByte();
                    if (zero != 0x00) return error.InvalidEncoding;
                },
                else => return error.InvalidEncoding,
            }
        },
        0x41 => try skipDeclList(r, .component_type),
        0x42 => try skipDeclList(r, .instance_type),
        else => return error.InvalidEncoding,
    }
}

fn skipDeclList(r: *Reader, scope: DeclScope) Error!void {
    const n = try r.readU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const tag = try r.readByte();
        switch (tag) {
            0x00 => try skipCoreType(r),
            0x01 => try skipTypeDef(r),
            0x02 => try skipAlias(r),
            0x03 => {
                if (scope != .component_type) return error.InvalidEncoding;
                try skipExternNameSlot(r);
                try skipExternDesc(r);
            },
            0x04 => {
                try skipExternNameSlot(r);
                try skipExternDesc(r);
            },
            else => return error.InvalidEncoding,
        }
    }
}

fn skipExternNameSlot(r: *Reader) Error!void {
    const prefix = try r.readByte();
    if (prefix > 0x02) return error.InvalidEncoding;
    _ = try r.readName();
    if (prefix == 0x02) _ = try r.readName();
}

fn skipCoreType(r: *Reader) Error!void {
    const tag = try r.readByte();
    switch (tag) {
        0x60 => {
            // core func type
            const pn = try r.readU32();
            var i: u32 = 0;
            while (i < pn) : (i += 1) try skipCoreValType(r);
            const rn = try r.readU32();
            i = 0;
            while (i < rn) : (i += 1) try skipCoreValType(r);
        },
        0x50 => {
            // core module type
            const dn = try r.readU32();
            var i: u32 = 0;
            while (i < dn) : (i += 1) {
                const dt = try r.readByte();
                switch (dt) {
                    0x00 => {
                        _ = try r.readName();
                        _ = try r.readName();
                        _ = try r.readU32();
                    },
                    0x01 => {
                        _ = try r.readName();
                        _ = try r.readU32();
                    },
                    else => return error.InvalidEncoding,
                }
            }
        },
        else => return error.InvalidEncoding,
    }
}

fn skipAlias(r: *Reader) Error!void {
    try skipSort(r);
    const target = try r.readByte();
    switch (target) {
        0x00 => {
            // instance export
            _ = try r.readU32();
            _ = try r.readName();
        },
        0x01 => {
            // core instance export
            _ = try r.readU32();
            _ = try r.readName();
        },
        0x02 => {
            // outer
            _ = try r.readU32();
            _ = try r.readU32();
        },
        else => return error.InvalidEncoding,
    }
}

fn skipSort(r: *Reader) Error!void {
    const b = try r.readByte();
    switch (b) {
        0x00 => _ = try r.readByte(),
        0x01, 0x02, 0x03, 0x04, 0x05 => {},
        else => return error.InvalidEncoding,
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const loader = @import("loader.zig");
const writer = @import("writer.zig");
const ctypes = @import("types.zig");

test "apply: empty rules is identity on a real component fixture" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const data = @embedFile("fixtures/stdio-echo.wasm");
    const out = try apply(ar, data, &.{});

    // Body content must round-trip through the loader.
    const c1 = try loader.load(data, ar);
    const c2 = try loader.load(out, ar);
    try testing.expectEqual(c1.imports.len, c2.imports.len);
    try testing.expectEqual(c1.exports.len, c2.exports.len);
    try testing.expectEqual(c1.types.len, c2.types.len);
    for (c1.imports, c2.imports) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
    }
    for (c1.exports, c2.exports) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
    }
}

test "apply: rewrites top-level import name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } },
    };
    const types = [_]ctypes.TypeDef{
        .{ .instance = .{ .decls = &.{} } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &cons_imports, .exports = &.{},
    };
    const bytes = try writer.encode(ar, &consumer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes, &rules);

    const loaded = try loader.load(out, ar);
    try testing.expectEqual(@as(usize, 1), loaded.imports.len);
    try testing.expectEqualStrings("wasi:io/error@0.2.6", loaded.imports[0].name);
}

test "apply: rewrites top-level export name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const types = [_]ctypes.TypeDef{
        .{ .instance = .{ .decls = &.{} } },
    };
    const exports = [_]ctypes.ExportDecl{
        .{
            .name = "wasi:io/streams@0.2.10",
            .desc = .{ .instance = 0 },
            .sort_idx = .{ .sort = .instance, .idx = 0 },
        },
    };
    // Without an actual instance to alias, the export can't refer to
    // a real sort_idx. We construct a component that has a single
    // instance import + a re-export so the encoded bytes are valid.
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/streams@0.2.10", .desc = .{ .instance = 0 } },
    };
    _ = imports; // not currently used — the exported alias path would
    // require a wrapping instance section. For the rewriter test we
    // only need the export-section bytes; the loader doesn't care
    // about cross-section index validity.

    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &.{}, .exports = &exports,
    };
    const bytes = try writer.encode(ar, &consumer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes, &rules);

    const loaded = try loader.load(out, ar);
    try testing.expectEqual(@as(usize, 1), loaded.exports.len);
    try testing.expectEqualStrings("wasi:io/streams@0.2.6", loaded.exports[0].name);
}

test "apply: rewrites import name nested in component-type body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // A type section with one component-type that has a single
    // import decl pointing at a versioned interface.
    const inner_instance_type = ctypes.TypeDef{ .instance = .{ .decls = &.{} } };
    const ct_decls = [_]ctypes.Decl{
        .{ .type = inner_instance_type },
        .{ .import = .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } } },
    };
    const ct = ctypes.TypeDef{ .component = .{ .decls = &ct_decls } };
    const types = [_]ctypes.TypeDef{ct};
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &.{}, .exports = &.{},
    };
    const bytes = try writer.encode(ar, &consumer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes, &rules);

    const loaded = try loader.load(out, ar);
    try testing.expectEqual(@as(usize, 1), loaded.types.len);
    try testing.expect(loaded.types[0] == .component);
    const decls = loaded.types[0].component.decls;
    var found = false;
    for (decls) |d| {
        if (d == .import) {
            try testing.expectEqualStrings("wasi:io/error@0.2.6", d.import.name);
            found = true;
        }
    }
    try testing.expect(found);
}

test "apply: leaves unrelated names alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } },
        .{ .name = "wasi:cli/stdout@0.2.10", .desc = .{ .instance = 0 } },
    };
    const types = [_]ctypes.TypeDef{
        .{ .instance = .{ .decls = &.{} } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &cons_imports, .exports = &.{},
    };
    const bytes = try writer.encode(ar, &consumer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes, &rules);
    const loaded = try loader.load(out, ar);
    try testing.expectEqualStrings("wasi:io/error@0.2.6", loaded.imports[0].name);
    try testing.expectEqualStrings("wasi:cli/stdout@0.2.10", loaded.imports[1].name);
}

test "apply: extending the version string (0.2.6 → 0.2.10) round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const cons_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.6", .desc = .{ .instance = 0 } },
    };
    const types = [_]ctypes.TypeDef{
        .{ .instance = .{ .decls = &.{} } },
    };
    const consumer: ctypes.Component = .{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &types, .canons = &.{},
        .imports = &cons_imports, .exports = &.{},
    };
    const bytes = try writer.encode(ar, &consumer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.10" },
    };
    const out = try apply(ar, bytes, &rules);
    const loaded = try loader.load(out, ar);
    try testing.expectEqualStrings("wasi:io/error@0.2.10", loaded.imports[0].name);
}

test "apply: recurses through nested-component import sections (regression for #212 site 2)" {
    // A wrapping component embeds another component as a nested
    // component section. The nested component has its own top-level
    // import declaring `wasi:http/types@0.2.10`. The rewriter's id=4
    // dispatch (`apply` recurses) must descend through and rewrite
    // the nested component's import name.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const nested_imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:http/types@0.2.10", .desc = .{ .instance = 0 } },
    };
    const nested_types = [_]ctypes.TypeDef{
        .{ .instance = .{ .decls = &.{} } },
    };
    const nested = ctypes.Component{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &nested_types, .canons = &.{},
        .imports = &nested_imports, .exports = &.{},
    };
    const nested_bytes = try writer.encode(ar, &nested);

    var passthrough = nested;
    passthrough.raw_bytes = nested_bytes;
    var passthrough_ptr = passthrough;
    const components_arr = [_]*ctypes.Component{&passthrough_ptr};

    const outer = ctypes.Component{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &components_arr,
        .instances = &.{}, .aliases = &.{},
        .types = &.{}, .canons = &.{},
        .imports = &.{}, .exports = &.{},
    };
    const outer_bytes = try writer.encode(ar, &outer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "http", .to_version = "0.2.6" },
    };
    const out = try apply(ar, outer_bytes, &rules);

    // Re-load and walk the nested component's imports — the rewrite
    // must have reached through the id=4 boundary.
    const loaded = try loader.load(out, ar);
    try testing.expectEqual(@as(usize, 1), loaded.components.len);
    try testing.expectEqual(@as(usize, 1), loaded.components[0].imports.len);
    try testing.expectEqualStrings(
        "wasi:http/types@0.2.6",
        loaded.components[0].imports[0].name,
    );

    // And no @0.2.10 byte sequence survives anywhere.
    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") == null);
}

// ── #214 audit: confirm #213's recursion reaches deeper sites ──────────────

test "apply: rewrites a nested component's component-type-body import (audit for #214 site A.1)" {
    // outer component
    //   → component section (id=4) carrying nested component bytes
    //     → nested component
    //       → type section (id=7)
    //         → component-type (0x41)
    //           → instance type decl (slot for desc)
    //           → import decl: "wasi:io/error@0.2.10"
    //
    // #213's apply() recurses on id=4; the nested type section walker
    // handles 0x41 / 0x03 decls. This test pins that contract end-to-end.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const inner_instance_type = ctypes.TypeDef{ .instance = .{ .decls = &.{} } };
    const ct_decls = [_]ctypes.Decl{
        .{ .type = inner_instance_type },
        .{ .import = .{ .name = "wasi:io/error@0.2.10", .desc = .{ .instance = 0 } } },
    };
    const ct = ctypes.TypeDef{ .component = .{ .decls = &ct_decls } };
    const nested_types = [_]ctypes.TypeDef{ct};
    const nested = ctypes.Component{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &nested_types, .canons = &.{},
        .imports = &.{}, .exports = &.{},
    };
    const nested_bytes = try writer.encode(ar, &nested);

    var passthrough = nested;
    passthrough.raw_bytes = nested_bytes;
    var passthrough_ptr = passthrough;
    const components_arr = [_]*ctypes.Component{&passthrough_ptr};

    const outer = ctypes.Component{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &components_arr,
        .instances = &.{}, .aliases = &.{},
        .types = &.{}, .canons = &.{},
        .imports = &.{}, .exports = &.{},
    };
    const outer_bytes = try writer.encode(ar, &outer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, outer_bytes, &rules);

    // No @0.2.10 substring may survive at any depth.
    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") == null);
    try testing.expect(std.mem.indexOf(u8, out, "wasi:io/error@0.2.6") != null);

    // Loader walks deep enough that we can re-verify structurally.
    const loaded = try loader.load(out, ar);
    try testing.expectEqual(@as(usize, 1), loaded.components.len);
    const inner_types = loaded.components[0].types;
    try testing.expect(inner_types.len >= 1);
    try testing.expect(inner_types[0] == .component);
    var found = false;
    for (inner_types[0].component.decls) |d| {
        if (d == .import) {
            try testing.expectEqualStrings("wasi:io/error@0.2.6", d.import.name);
            found = true;
        }
    }
    try testing.expect(found);
}

test "apply: rewrites a nested component's core_module imports (audit for #214 site A.2)" {
    // outer component
    //   → component section (id=4) carrying nested component bytes
    //     → nested component
    //       → core_module section (id=1) carrying raw core wasm
    //         → core import section (core id=2)
    //           → (import "wasi:io/poll@0.2.10" "[resource-drop]pollable" ...)
    //
    // #213's apply() recurses on id=4 and the nested rewriteCoreModuleSection
    // walks the embedded core wasm import section.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Hand-roll a minimal core wasm: preamble + type section + import section.
    var core_bytes = std.ArrayListUnmanaged(u8).empty;
    try core_bytes.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // type section: 1 type, () -> ().
    try core_bytes.appendSlice(ar, &.{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 });
    // import section: 1 import.
    {
        var imp = std.ArrayListUnmanaged(u8).empty;
        try imp.append(ar, 0x01);
        const m = "wasi:io/poll@0.2.10";
        try imp.append(ar, m.len);
        try imp.appendSlice(ar, m);
        const f = "[resource-drop]pollable";
        try imp.append(ar, f.len);
        try imp.appendSlice(ar, f);
        try imp.append(ar, 0x00); // func desc
        try imp.append(ar, 0x00); // typeidx 0
        try core_bytes.append(ar, 0x02);
        try core_bytes.append(ar, @intCast(imp.items.len));
        try core_bytes.appendSlice(ar, imp.items);
    }

    const core_modules = [_]ctypes.CoreModule{
        .{ .data = core_bytes.items },
    };
    const nested = ctypes.Component{
        .core_modules = &core_modules, .core_instances = &.{},
        .core_types = &.{}, .components = &.{},
        .instances = &.{}, .aliases = &.{},
        .types = &.{}, .canons = &.{},
        .imports = &.{}, .exports = &.{},
    };
    const nested_bytes = try writer.encode(ar, &nested);

    var passthrough = nested;
    passthrough.raw_bytes = nested_bytes;
    var passthrough_ptr = passthrough;
    const components_arr = [_]*ctypes.Component{&passthrough_ptr};

    const outer = ctypes.Component{
        .core_modules = &.{}, .core_instances = &.{},
        .core_types = &.{}, .components = &components_arr,
        .instances = &.{}, .aliases = &.{},
        .types = &.{}, .canons = &.{},
        .imports = &.{}, .exports = &.{},
    };
    const outer_bytes = try writer.encode(ar, &outer);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, outer_bytes, &rules);

    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") == null);
    try testing.expect(std.mem.indexOf(u8, out, "wasi:io/poll@0.2.6") != null);
    // The field name is not an externname — it survives unchanged.
    try testing.expect(std.mem.indexOf(u8, out, "[resource-drop]pollable") != null);
}

// ── #212: core_instance + core_module section rewrites ─────────────────────

test "rewriteCoreInstanceSection: rewrites instantiate arg name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Hand-rolled core_instance section body:
    //   count = 1
    //   instance[0]:
    //     tag = 0x00 (instantiate)
    //     module_idx = 0
    //     arg_count = 1
    //     arg[0]: name = "wasi:io/poll@0.2.10", sort = 0x12, inst_idx = 5
    var body = std.ArrayListUnmanaged(u8).empty;
    try body.append(ar, 0x01); // count
    try body.append(ar, 0x00); // instantiate
    try body.append(ar, 0x00); // module_idx
    try body.append(ar, 0x01); // arg_count
    const arg_name = "wasi:io/poll@0.2.10";
    try body.append(ar, arg_name.len);
    try body.appendSlice(ar, arg_name);
    try body.append(ar, 0x12); // instance sort
    try body.append(ar, 0x05); // inst_idx

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try rewriteCoreInstanceSection(ar, body.items, &rules);

    // Re-read to verify: expect "wasi:io/poll@0.2.6" with len 18.
    var r2 = Reader{ .data = out };
    try testing.expectEqual(@as(u32, 1), try r2.readU32());
    try testing.expectEqual(@as(u8, 0x00), try r2.readByte());
    try testing.expectEqual(@as(u32, 0), try r2.readU32());
    try testing.expectEqual(@as(u32, 1), try r2.readU32());
    const out_name = try r2.readName();
    try testing.expectEqualStrings("wasi:io/poll@0.2.6", out_name);
    try testing.expectEqual(@as(u8, 0x12), try r2.readByte());
    try testing.expectEqual(@as(u32, 5), try r2.readU32());
}

test "rewriteCoreInstanceSection: rewrites inline-export name + leaves non-extern names alone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // body:
    //   count = 1
    //   instance[0]:
    //     tag = 0x01 (inline exports)
    //     export_count = 2
    //     export[0]: name = "wasi:io/streams@0.2.10", sort = 0x12, idx = 3
    //     export[1]: name = "memory",                  sort = 0x02, idx = 0
    var body = std.ArrayListUnmanaged(u8).empty;
    try body.append(ar, 0x01); // count
    try body.append(ar, 0x01); // inline exports
    try body.append(ar, 0x02); // export_count
    const n1 = "wasi:io/streams@0.2.10";
    try body.append(ar, n1.len);
    try body.appendSlice(ar, n1);
    try body.append(ar, 0x12);
    try body.append(ar, 0x03);
    const n2 = "memory";
    try body.append(ar, n2.len);
    try body.appendSlice(ar, n2);
    try body.append(ar, 0x02);
    try body.append(ar, 0x00);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try rewriteCoreInstanceSection(ar, body.items, &rules);

    var r2 = Reader{ .data = out };
    try testing.expectEqual(@as(u32, 1), try r2.readU32());
    try testing.expectEqual(@as(u8, 0x01), try r2.readByte());
    try testing.expectEqual(@as(u32, 2), try r2.readU32());
    try testing.expectEqualStrings("wasi:io/streams@0.2.6", try r2.readName());
    try testing.expectEqual(@as(u8, 0x12), try r2.readByte());
    try testing.expectEqual(@as(u32, 3), try r2.readU32());
    try testing.expectEqualStrings("memory", try r2.readName());
    try testing.expectEqual(@as(u8, 0x02), try r2.readByte());
    try testing.expectEqual(@as(u32, 0), try r2.readU32());
}

test "rewriteCoreImportSection: rewrites module name across multiple imports + import descs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Build a core wasm import section body with three imports
    // covering func/memory/global desc shapes:
    //   1. module="wasi:io/poll@0.2.10" field="[resource-drop]pollable"
    //      desc = func typeidx=0
    //   2. module="env"                    field="memory"
    //      desc = memory limits flags=0x00 min=0
    //   3. module="wasi:random/random@0.2.10" field="get-random-bytes"
    //      desc = global valtype=0x7f mut=0x00
    var body = std.ArrayListUnmanaged(u8).empty;
    try body.append(ar, 0x03); // count

    const m1 = "wasi:io/poll@0.2.10";
    try body.append(ar, m1.len);
    try body.appendSlice(ar, m1);
    const f1 = "[resource-drop]pollable";
    try body.append(ar, f1.len);
    try body.appendSlice(ar, f1);
    try body.append(ar, 0x00); // func desc
    try body.append(ar, 0x00); // typeidx 0

    const m2 = "env";
    try body.append(ar, m2.len);
    try body.appendSlice(ar, m2);
    const f2 = "memory";
    try body.append(ar, f2.len);
    try body.appendSlice(ar, f2);
    try body.append(ar, 0x02); // memory desc
    try body.append(ar, 0x00); // limits flags = min only
    try body.append(ar, 0x00); // min

    const m3 = "wasi:random/random@0.2.10";
    try body.append(ar, m3.len);
    try body.appendSlice(ar, m3);
    const f3 = "get-random-bytes";
    try body.append(ar, f3.len);
    try body.appendSlice(ar, f3);
    try body.append(ar, 0x03); // global desc
    try body.append(ar, 0x7f); // i32
    try body.append(ar, 0x00); // immutable

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
        .{ .ns = "wasi", .pkg = "random", .to_version = "0.2.6" },
    };
    const out = try rewriteCoreImportSection(ar, body.items, &rules);

    var r2 = Reader{ .data = out };
    try testing.expectEqual(@as(u32, 3), try r2.readU32());

    try testing.expectEqualStrings("wasi:io/poll@0.2.6", try r2.readName());
    try testing.expectEqualStrings("[resource-drop]pollable", try r2.readName());
    try testing.expectEqual(@as(u8, 0x00), try r2.readByte());
    try testing.expectEqual(@as(u32, 0), try r2.readU32());

    try testing.expectEqualStrings("env", try r2.readName());
    try testing.expectEqualStrings("memory", try r2.readName());
    try testing.expectEqual(@as(u8, 0x02), try r2.readByte());
    try testing.expectEqual(@as(u8, 0x00), try r2.readByte());
    try testing.expectEqual(@as(u32, 0), try r2.readU32());

    try testing.expectEqualStrings("wasi:random/random@0.2.6", try r2.readName());
    try testing.expectEqualStrings("get-random-bytes", try r2.readName());
    try testing.expectEqual(@as(u8, 0x03), try r2.readByte());
    try testing.expectEqual(@as(u8, 0x7f), try r2.readByte());
    try testing.expectEqual(@as(u8, 0x00), try r2.readByte());
}

test "rewriteCoreModuleSection: rewrites imports across surrounding sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // A minimal core wasm body with one type section and one
    // import section. The import section is sandwiched between a
    // custom section before and a custom section after, so we
    // exercise the verbatim-copy path for non-import sections.
    var body = std.ArrayListUnmanaged(u8).empty;
    // Preamble: \x00asm + version 1.
    try body.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // Custom section (id 0): name="x", payload="hi".
    try body.append(ar, 0x00);
    try body.append(ar, 0x04); // size
    try body.append(ar, 0x01);
    try body.append(ar, 'x');
    try body.append(ar, 'h');
    try body.append(ar, 'i');
    // Type section (id 1): 1 type, () -> ().
    try body.append(ar, 0x01);
    try body.append(ar, 0x04); // size
    try body.append(ar, 0x01); // count
    try body.append(ar, 0x60); // func
    try body.append(ar, 0x00); // 0 params
    try body.append(ar, 0x00); // 0 results
    // Import section (id 2): 1 import.
    {
        var imp = std.ArrayListUnmanaged(u8).empty;
        try imp.append(ar, 0x01); // count
        const m = "wasi:io/poll@0.2.10";
        try imp.append(ar, m.len);
        try imp.appendSlice(ar, m);
        const f = "[resource-drop]pollable";
        try imp.append(ar, f.len);
        try imp.appendSlice(ar, f);
        try imp.append(ar, 0x00); // func desc
        try imp.append(ar, 0x00); // typeidx 0
        try body.append(ar, 0x02);
        try body.append(ar, @intCast(imp.items.len));
        try body.appendSlice(ar, imp.items);
    }
    // Another custom section after.
    try body.append(ar, 0x00);
    try body.append(ar, 0x04); // size
    try body.append(ar, 0x01);
    try body.append(ar, 'y');
    try body.append(ar, 'b');
    try body.append(ar, 'e');

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try rewriteCoreModuleSection(ar, body.items, &rules);

    // Output must (a) preserve the preamble + custom sections + type
    // section verbatim, (b) rewrite the import section's module
    // name, and (c) contain no `@0.2.10` substring anywhere.
    try testing.expectEqualSlices(u8, "\x00asm", out[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x00, 0x00 }, out[4..8]);
    try testing.expect(std.mem.indexOf(u8, out, "wasi:io/poll@0.2.6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") == null);
    // Custom-section payloads survive.
    try testing.expect(std.mem.indexOf(u8, out, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ybe") != null);
    // Type section's `(func)` body survives.
    try testing.expect(std.mem.indexOf(u8, out, &.{ 0x60, 0x00, 0x00 }) != null);
}

test "rewriteCoreModuleSection: empty core wasm (no sections) round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const body = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try rewriteCoreModuleSection(ar, &body, &rules);
    try testing.expectEqualSlices(u8, &body, out);
}

test "apply: rewrites every @0.2.10 site at component + core levels (e2e for #212)" {
    // Build a component byte stream by hand combining:
    //   - top-level import (component section id=10) — addressed by #210
    //   - top-level export (component section id=11) — addressed by #210
    //   - core_module section (component id=1) whose inner core wasm
    //     import section references `wasi:io/poll@0.2.10`         — #212 site 3
    //   - core_instance section (component id=2) whose instantiate
    //     args reference `wasi:io/poll@0.2.10`                    — #212 site 1
    //   - instance section (component id=5) whose instantiate args
    //     reference `wasi:http/types@0.2.10`                       — #212 site 2 (component-side)
    //
    // After `apply` with the canonical rules, zero `@0.2.10`
    // substring may survive.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    var bytes = std.ArrayListUnmanaged(u8).empty;
    // Component preamble.
    try bytes.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    // ── Section id=1 (core_module) — one tiny core wasm with a
    //     single (import "wasi:io/poll@0.2.10" "x" (func 0)) entry.
    {
        var core = std.ArrayListUnmanaged(u8).empty;
        try core.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
        // type section: 1 type, () -> ().
        try core.appendSlice(ar, &.{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 });
        // import section: 1 import, mod="wasi:io/poll@0.2.10", fld="x", func 0.
        var imp = std.ArrayListUnmanaged(u8).empty;
        try imp.append(ar, 0x01); // count
        const m = "wasi:io/poll@0.2.10";
        try imp.append(ar, m.len);
        try imp.appendSlice(ar, m);
        try imp.append(ar, 0x01);
        try imp.append(ar, 'x');
        try imp.append(ar, 0x00); // func desc
        try imp.append(ar, 0x00); // typeidx
        try core.append(ar, 0x02);
        try core.append(ar, @intCast(imp.items.len));
        try core.appendSlice(ar, imp.items);
        try bytes.append(ar, 0x01); // section id 1
        try bytes.append(ar, @intCast(core.items.len));
        try bytes.appendSlice(ar, core.items);
    }

    // ── Section id=2 (core_instance) — one instantiate of module 0
    //     with one arg named `wasi:io/poll@0.2.10`.
    {
        var ci = std.ArrayListUnmanaged(u8).empty;
        try ci.append(ar, 0x01); // count
        try ci.append(ar, 0x00); // instantiate
        try ci.append(ar, 0x00); // module_idx 0
        try ci.append(ar, 0x01); // arg_count
        const n = "wasi:io/poll@0.2.10";
        try ci.append(ar, n.len);
        try ci.appendSlice(ar, n);
        try ci.append(ar, 0x12);
        try ci.append(ar, 0x00); // inst_idx
        try bytes.append(ar, 0x02);
        try bytes.append(ar, @intCast(ci.items.len));
        try bytes.appendSlice(ar, ci.items);
    }

    // ── Section id=7 (type) — define one empty instance type as a
    //     type slot to back the import/export descs.
    try bytes.appendSlice(ar, &.{ 0x07, 0x03, 0x01, 0x42, 0x00 });

    // ── Section id=10 (import) — one component-level instance
    //     import named `wasi:http/types@0.2.10`.
    {
        var imp = std.ArrayListUnmanaged(u8).empty;
        try imp.append(ar, 0x01); // count
        try imp.append(ar, 0x00); // prefix
        const n = "wasi:http/types@0.2.10";
        try imp.append(ar, n.len);
        try imp.appendSlice(ar, n);
        try imp.append(ar, 0x05); // instance desc
        try imp.append(ar, 0x00); // type idx 0
        try bytes.append(ar, 0x0a);
        try bytes.append(ar, @intCast(imp.items.len));
        try bytes.appendSlice(ar, imp.items);
    }

    // ── Section id=11 (export) — one re-export named `wasi:http/
    //     outgoing-handler@0.2.10` pointing at instance 0.
    {
        var exp = std.ArrayListUnmanaged(u8).empty;
        try exp.append(ar, 0x01); // count
        try exp.append(ar, 0x00); // prefix
        const n = "wasi:http/outgoing-handler@0.2.10";
        try exp.append(ar, n.len);
        try exp.appendSlice(ar, n);
        try exp.append(ar, 0x05); // sort: instance
        try exp.append(ar, 0x00); // sort idx 0
        try exp.append(ar, 0x00); // no explicit desc
        try bytes.append(ar, 0x0b);
        try bytes.append(ar, @intCast(exp.items.len));
        try bytes.appendSlice(ar, exp.items);
    }

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
        .{ .ns = "wasi", .pkg = "http", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes.items, &rules);

    // Every @0.2.10 site has been rewritten — including the ones
    // inside the embedded core wasm and the core-instance args.
    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") == null);
    // The rewritten strings are still present at the right surface.
    try testing.expect(std.mem.indexOf(u8, out, "wasi:io/poll@0.2.6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wasi:http/types@0.2.6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wasi:http/outgoing-handler@0.2.6") != null);
}

// ── #214 cosmetic: `name` / `component-name` custom section ────────────────

test "matchExternNameAt: recognizes standard patterns" {
    // Bare pkg/iface, no ns, no version.
    try testing.expectEqual(@as(?usize, 9), matchExternNameAt("pkg/iface", 0));
    // ns:pkg/iface, no version.
    try testing.expectEqual(@as(?usize, 11), matchExternNameAt("ns:pkg/face", 0));
    // Standard wasi-style with version.
    try testing.expectEqual(@as(?usize, 19), matchExternNameAt("wasi:io/error@0.2.6", 0));
    // Embedded after a `ty-` prefix: matching at offset 0 picks up
    // "ty-wasi:io/error@0.2.6" as a whole, but starting at offset 3
    // recovers the inner "wasi:..." externname.
    const s = "ty-wasi:io/error@0.2.6";
    try testing.expectEqual(@as(?usize, 22), matchExternNameAt(s, 0)); // greedy: ns="ty-wasi"
    try testing.expectEqual(@as(?usize, 22), matchExternNameAt(s, 3)); // ns="wasi"
}

test "matchExternNameAt: rejects non-externname patterns" {
    try testing.expectEqual(@as(?usize, null), matchExternNameAt("", 0));
    try testing.expectEqual(@as(?usize, null), matchExternNameAt("just-text", 0));
    try testing.expectEqual(@as(?usize, null), matchExternNameAt("missing-slash", 0));
    try testing.expectEqual(@as(?usize, null), matchExternNameAt("/leading-slash", 0));
    // Trailing `@` without digits — the @ stays out of the match.
    try testing.expectEqual(@as(?usize, 9), matchExternNameAt("pkg/iface@", 0));
}

test "rewriteEmbeddedExternNames: rewrites only the embedded substring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try rewriteEmbeddedExternNames(ar, "ty-wasi:io/error@0.2.10", &rules);
    try testing.expectEqualStrings("ty-wasi:io/error@0.2.6", out);

    // Multiple embedded externnames in one string get rewritten in
    // a single pass.
    const out2 = try rewriteEmbeddedExternNames(
        ar,
        "alias[wasi:io/error@0.2.10 -> wasi:io/streams@0.2.10]",
        &rules,
    );
    try testing.expectEqualStrings(
        "alias[wasi:io/error@0.2.6 -> wasi:io/streams@0.2.6]",
        out2,
    );

    // No matches: pointer identity is preserved (signals no allocation).
    const in = "no-extern-name-here";
    const out3 = try rewriteEmbeddedExternNames(ar, in, &rules);
    try testing.expectEqual(in.ptr, out3.ptr);
}

test "apply: rewrites externnames inside the `name` custom section (#214 cosmetic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // Build a component with one custom section named "name" whose
    // payload has a namemap subsection (id=4) listing one entry whose
    // name string carries an embedded extern_name.
    var bytes = std.ArrayListUnmanaged(u8).empty;
    try bytes.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    var ns_payload = std.ArrayListUnmanaged(u8).empty;
    // Subsection: id=4 (type names), namemap.
    var subsec = std.ArrayListUnmanaged(u8).empty;
    try subsec.append(ar, 0x01); // count = 1
    try subsec.append(ar, 0x00); // idx = 0
    const debug_name = "ty-wasi:io/error@0.2.10";
    try subsec.append(ar, @intCast(debug_name.len));
    try subsec.appendSlice(ar, debug_name);
    try ns_payload.append(ar, 0x04); // subsec id
    try ns_payload.append(ar, @intCast(subsec.items.len));
    try ns_payload.appendSlice(ar, subsec.items);

    var custom_body = std.ArrayListUnmanaged(u8).empty;
    const sec_name = "name";
    try custom_body.append(ar, @intCast(sec_name.len));
    try custom_body.appendSlice(ar, sec_name);
    try custom_body.appendSlice(ar, ns_payload.items);

    try bytes.append(ar, 0x00); // custom section id
    try bytes.append(ar, @intCast(custom_body.items.len));
    try bytes.appendSlice(ar, custom_body.items);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes.items, &rules);

    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") == null);
    try testing.expect(std.mem.indexOf(u8, out, "ty-wasi:io/error@0.2.6") != null);
}

test "apply: leaves non-`name` custom sections verbatim (#214 cosmetic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    var bytes = std.ArrayListUnmanaged(u8).empty;
    try bytes.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    // Custom section named "producers" with arbitrary payload that
    // happens to contain `@0.2.10`. Must survive untouched because
    // we only rewrite name / component-name sections.
    var custom_body = std.ArrayListUnmanaged(u8).empty;
    const sec_name = "producers";
    try custom_body.append(ar, @intCast(sec_name.len));
    try custom_body.appendSlice(ar, sec_name);
    const payload = "free-form-text-@0.2.10";
    try custom_body.appendSlice(ar, payload);

    try bytes.append(ar, 0x00);
    try bytes.append(ar, @intCast(custom_body.items.len));
    try bytes.appendSlice(ar, custom_body.items);

    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes.items, &rules);
    try testing.expect(std.mem.indexOf(u8, out, "@0.2.10") != null);
}

test "apply: malformed `name` section falls back to verbatim copy (#214 cosmetic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // A `name` section whose subsection body doesn't parse as namemap:
    // partial garbage bytes. The rewriter should bail to verbatim copy.
    var bytes = std.ArrayListUnmanaged(u8).empty;
    try bytes.appendSlice(ar, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    var ns_payload = std.ArrayListUnmanaged(u8).empty;
    // Subsection id=99 (unknown) + size=3 + payload that won't parse
    // as namemap (count=5 but only 1 byte left).
    try ns_payload.append(ar, 99);
    try ns_payload.append(ar, 0x03);
    try ns_payload.appendSlice(ar, &.{ 0x05, 0xff, 0xee });

    var custom_body = std.ArrayListUnmanaged(u8).empty;
    const sec_name = "name";
    try custom_body.append(ar, @intCast(sec_name.len));
    try custom_body.appendSlice(ar, sec_name);
    try custom_body.appendSlice(ar, ns_payload.items);

    try bytes.append(ar, 0x00);
    try bytes.append(ar, @intCast(custom_body.items.len));
    try bytes.appendSlice(ar, custom_body.items);

    // No rule will fire, so the cleanest assertion is "this didn't
    // crash and the output round-trips through apply".
    const rules = [_]extern_name.Rule{
        .{ .ns = "wasi", .pkg = "io", .to_version = "0.2.6" },
    };
    const out = try apply(ar, bytes.items, &rules);
    // Section content survives verbatim.
    try testing.expect(std.mem.indexOf(u8, out, &.{ 0x05, 0xff, 0xee }) != null);
}
