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
//! (custom, core_module, core_instance, core_type, alias, canon,
//! start, value) are copied verbatim — preserving the original
//! section interleaving that the AST cannot represent. Sections that
//! do carry externnames (top-level import, top-level export, instance
//! inline-exports, and type-body import/export decls inside
//! component/instance types) are parsed item-by-item; each item's
//! name is rewritten, the rest of the item's bytes are copied
//! verbatim. Nested-component sections recurse.
//!
//! Scope intentionally excludes alias `instance_export.name` and
//! `instantiate.args[].name` slots: in real-world wasm-tools / jco
//! output those carry instance-internal labels (method names,
//! resource names) that do not carry the `@<semver>` suffix the
//! parser recognizes, so the rewriter would not produce any
//! substitution there. Widening that scope is a no-op for those
//! inputs and a no-cost addition if a future fixture demands it.

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
                try copyU32(&r, &w, arena); // component_idx
                const arg_count = try r.readU32();
                try writeU32Leb(&w, arena, arg_count);
                var j: u32 = 0;
                while (j < arg_count) : (j += 1) {
                    try copyName(&r, &w, arena);
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
