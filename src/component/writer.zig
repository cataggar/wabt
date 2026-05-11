//! Component Model binary format writer.
//!
//! Inverse of `loader.zig`: serializes a `Component` AST back into the
//! component binary format. Section emission uses a two-pass scheme —
//! each section's body is built in a temporary buffer, then the
//! `[section_id, leb_size, body]` triple is appended to the main
//! buffer. This avoids a separate size pre-computation pass and
//! mirrors what `wasm-tools` does in
//! `crates/wasm-encoder/src/component/`.
//!
//! Design intent: round-trip every component the loader accepts.
//! Acceptance test is `loader.load(encoder.encode(c)) == c` for every
//! corpus the loader's tests exercise (currently the 58 KB
//! `stdio-echo` Rust wasi-p2 fixture).
//!
//! Section ordering: components allow interleaved sections (unlike
//! core modules), so the encoder emits sections in the conventional
//! "imports first, then types, then aliases, then instance/canon/etc"
//! order produced by `wasm-tools component new`. Round-trip equality
//! is *structural* (both halves load to the same AST), not necessarily
//! byte-identical with the input — input components from external
//! tools may interleave differently.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ctypes = @import("types.zig");
const leb128 = @import("../leb128.zig");

// ── Component preamble constants ───────────────────────────────────────────

const wasm_magic: u32 = 0x6d736100;
const component_version: u32 = 0x0001_000d;

// ── Section IDs (must match loader.zig) ────────────────────────────────────

const SECTION_CUSTOM: u8 = 0;
const SECTION_CORE_MODULE: u8 = 1;
const SECTION_CORE_INSTANCE: u8 = 2;
const SECTION_CORE_TYPE: u8 = 3;
const SECTION_COMPONENT: u8 = 4;
const SECTION_INSTANCE: u8 = 5;
const SECTION_ALIAS: u8 = 6;
const SECTION_TYPE: u8 = 7;
const SECTION_CANON: u8 = 8;
const SECTION_START: u8 = 9;
const SECTION_IMPORT: u8 = 10;
const SECTION_EXPORT: u8 = 11;

pub const EncodeError = error{ OutOfMemory, ValueTooLarge };

/// Encode a `Component` AST into a component binary.
pub fn encode(allocator: Allocator, component: *const ctypes.Component) EncodeError![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit();

    try w.writeU32LE(wasm_magic);
    try w.writeU32LE(component_version);

    if (component.section_order) |order| {
        try writeOrdered(&w, component, order);
        return w.buf.toOwnedSlice(allocator);
    }

    // Custom sections are emitted up-front — the wit-component
    // encoding marker section needs to appear before the type section
    // for downstream tooling that scans for it positionally.
    for (component.custom_sections) |cs| try writeCustomSection(&w, cs);

    // Conventional section order. Some sections may be empty; we skip
    // emitting them in that case (the binary is shorter and still
    // structurally equivalent under loader's reading).
    //
    // Order is *forward-only* with respect to the index spaces:
    //   * types come first because imports may declare instance/func
    //     imports referencing them by type idx;
    //   * aliases and canons (which build on core instances and
    //     types) come *before* component instances (which may
    //     reference the lifted funcs the canons produce) and
    //     exports (which may reference the produced instances).
    //
    // Re-using an instance/alias/canon group later in the binary is
    // legal but wabt only emits each kind once.
    if (component.types.len > 0) try writeTypeSection(&w, component.types);
    if (component.imports.len > 0) try writeImportSection(&w, component.imports);
    if (component.core_modules.len > 0) try writeCoreModuleSection(&w, component.core_modules);
    if (component.core_types.len > 0) try writeCoreTypeSection(&w, component.core_types);
    if (component.components.len > 0) try writeNestedComponentSection(&w, component.components);
    if (component.core_instances.len > 0) try writeCoreInstanceSection(&w, component.core_instances);
    if (component.aliases.len > 0) try writeAliasSection(&w, component.aliases);
    if (component.canons.len > 0) try writeCanonSection(&w, component.canons);
    if (component.instances.len > 0) try writeInstanceSection(&w, component.instances);
    if (component.start) |s| try writeStartSection(&w, s);
    if (component.exports.len > 0) try writeExportSection(&w, component.exports);

    return w.buf.toOwnedSlice(allocator);
}

/// Drive section emission from `component.section_order`. Each entry
/// produces exactly one physical section containing
/// `component.<field>[start .. start+count]`.
fn writeOrdered(
    w: *Writer,
    component: *const ctypes.Component,
    order: []const ctypes.SectionEntry,
) EncodeError!void {
    for (order) |entry| {
        const s = entry.start;
        const n = entry.count;
        switch (entry.kind) {
            .custom => for (component.custom_sections[s .. s + n]) |cs| {
                try writeCustomSection(w, cs);
            },
            .core_module => try writeCoreModuleSection(w, component.core_modules[s .. s + n]),
            .core_instance => try writeCoreInstanceSection(w, component.core_instances[s .. s + n]),
            .core_type => try writeCoreTypeSection(w, component.core_types[s .. s + n]),
            .component => try writeNestedComponentSection(w, component.components[s .. s + n]),
            .instance => try writeInstanceSection(w, component.instances[s .. s + n]),
            .alias => try writeAliasSection(w, component.aliases[s .. s + n]),
            .type => try writeTypeSection(w, component.types[s .. s + n]),
            .canon => try writeCanonSection(w, component.canons[s .. s + n]),
            .start => if (component.start) |st| try writeStartSection(w, st),
            .import => try writeImportSection(w, component.imports[s .. s + n]),
            .@"export" => try writeExportSection(w, component.exports[s .. s + n]),
        }
    }
}

// ── Internal writer ─────────────────────────────────────────────────────────

const Writer = struct {
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8),

    fn init(allocator: Allocator) Writer {
        return .{ .allocator = allocator, .buf = .empty };
    }

    fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    fn appendByte(self: *Writer, b: u8) EncodeError!void {
        try self.buf.append(self.allocator, b);
    }

    fn appendSlice(self: *Writer, s: []const u8) EncodeError!void {
        try self.buf.appendSlice(self.allocator, s);
    }

    fn writeU32LE(self: *Writer, v: u32) EncodeError!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try self.appendSlice(&tmp);
    }

    fn writeU32Leb(self: *Writer, v: u32) EncodeError!void {
        var tmp: [leb128.max_u32_bytes]u8 = undefined;
        const n = leb128.writeU32Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeS64Leb(self: *Writer, v: i64) EncodeError!void {
        var tmp: [leb128.max_s64_bytes]u8 = undefined;
        const n = leb128.writeS64Leb128(&tmp, v);
        try self.appendSlice(tmp[0..n]);
    }

    fn writeName(self: *Writer, name: []const u8) EncodeError!void {
        if (name.len > std.math.maxInt(u32)) return error.ValueTooLarge;
        try self.writeU32Leb(@intCast(name.len));
        try self.appendSlice(name);
    }
};

/// Build a section body in a scratch buffer, then commit the
/// `[id, leb_size, body]` triple to the main writer.
fn emitSection(
    w: *Writer,
    id: u8,
    body: []const u8,
) EncodeError!void {
    if (body.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try w.appendByte(id);
    try w.writeU32Leb(@intCast(body.len));
    try w.appendSlice(body);
}

fn writeCustomSection(w: *Writer, cs: ctypes.CustomSection) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();
    try body.writeName(cs.name);
    try body.appendSlice(cs.payload);
    try emitSection(w, 0, body.buf.items);
}

// ── Section writers ─────────────────────────────────────────────────────────

fn writeCoreModuleSection(
    w: *Writer,
    core_modules: []const ctypes.CoreModule,
) EncodeError!void {
    // Each core module is its own section (id 1) — there is no count
    // prefix, just one section per module. (Same for nested components.)
    for (core_modules) |m| {
        try emitSection(w, SECTION_CORE_MODULE, m.data);
    }
}

fn writeNestedComponentSection(
    w: *Writer,
    components: []const *ctypes.Component,
) EncodeError!void {
    for (components) |child| {
        if (child.raw_bytes) |raw| {
            // Pass through verbatim — preserves original section
            // interleaving that the AST cannot represent.
            try emitSection(w, SECTION_COMPONENT, raw);
        } else {
            const child_bytes = try encode(w.allocator, child);
            defer w.allocator.free(child_bytes);
            try emitSection(w, SECTION_COMPONENT, child_bytes);
        }
    }
}

fn writeCoreInstanceSection(
    w: *Writer,
    core_instances: []const ctypes.CoreInstanceExpr,
) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (core_instances.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(core_instances.len));
    for (core_instances) |ci| try writeCoreInstanceExpr(&body, ci);
    try emitSection(w, SECTION_CORE_INSTANCE, body.buf.items);
}

fn writeCoreInstanceExpr(
    w: *Writer,
    ci: ctypes.CoreInstanceExpr,
) EncodeError!void {
    switch (ci) {
        .instantiate => |inst| {
            try w.appendByte(0x00);
            try w.writeU32Leb(inst.module_idx);
            if (inst.args.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(inst.args.len));
            for (inst.args) |arg| {
                try w.writeName(arg.name);
                try w.appendByte(0x12); // instance sort
                try w.writeU32Leb(arg.instance_idx);
            }
        },
        .exports => |exps| {
            try w.appendByte(0x01);
            if (exps.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(exps.len));
            for (exps) |e| {
                try w.writeName(e.name);
                try w.appendByte(@intFromEnum(e.sort_idx.sort));
                try w.writeU32Leb(e.sort_idx.idx);
            }
        },
    }
}

fn writeCoreTypeSection(
    w: *Writer,
    core_types: []const ctypes.CoreTypeDef,
) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (core_types.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(core_types.len));
    for (core_types) |ct| try writeCoreTypeDef(&body, ct);
    try emitSection(w, SECTION_CORE_TYPE, body.buf.items);
}

fn writeCoreTypeDef(w: *Writer, ct: ctypes.CoreTypeDef) EncodeError!void {
    switch (ct) {
        .func => |f| {
            try w.appendByte(0x60);
            if (f.params.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(f.params.len));
            for (f.params) |p| try w.appendByte(@intFromEnum(p));
            if (f.results.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(f.results.len));
            for (f.results) |r| try w.appendByte(@intFromEnum(r));
        },
        .module => |m| {
            try w.appendByte(0x50);
            const decl_count = m.imports.len + m.exports.len;
            if (decl_count > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(decl_count));
            for (m.imports) |imp| {
                try w.appendByte(0x00);
                try w.writeName(imp.module);
                try w.writeName(imp.name);
                try w.writeU32Leb(imp.type_idx);
            }
            for (m.exports) |exp| {
                try w.appendByte(0x01);
                try w.writeName(exp.name);
                try w.writeU32Leb(exp.type_idx);
            }
        },
    }
}

fn writeInstanceSection(
    w: *Writer,
    instances: []const ctypes.InstanceExpr,
) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (instances.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(instances.len));
    for (instances) |inst| try writeInstanceExpr(&body, inst);
    try emitSection(w, SECTION_INSTANCE, body.buf.items);
}

fn writeInstanceExpr(w: *Writer, ie: ctypes.InstanceExpr) EncodeError!void {
    switch (ie) {
        .instantiate => |inst| {
            try w.appendByte(0x00);
            try w.writeU32Leb(inst.component_idx);
            if (inst.args.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(inst.args.len));
            for (inst.args) |arg| {
                try w.writeName(arg.name);
                try writeSortIdx(w, arg.sort_idx);
            }
        },
        .exports => |exps| {
            try w.appendByte(0x01);
            if (exps.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(exps.len));
            for (exps) |e| {
                try writeExternName(w, e.name);
                try writeSortIdx(w, e.sort_idx);
            }
        },
    }
}

fn writeAliasSection(w: *Writer, aliases: []const ctypes.Alias) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (aliases.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(aliases.len));
    for (aliases) |a| try writeAlias(&body, a);
    try emitSection(w, SECTION_ALIAS, body.buf.items);
}

fn writeAlias(w: *Writer, a: ctypes.Alias) EncodeError!void {
    switch (a) {
        .instance_export => |ie| {
            try writeSort(w, ie.sort);
            // Tag 0x00 = component-instance export, 0x01 = core-instance
            // export. Disambiguate by whether the alias's sort is `core`.
            const is_core = ie.sort == .core;
            try w.appendByte(if (is_core) 0x01 else 0x00);
            try w.writeU32Leb(ie.instance_idx);
            try w.writeName(ie.name);
        },
        .outer => |o| {
            try writeSort(w, o.sort);
            try w.appendByte(0x02);
            try w.writeU32Leb(o.outer_count);
            try w.writeU32Leb(o.idx);
        },
    }
}

fn writeTypeSection(w: *Writer, types: []const ctypes.TypeDef) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (types.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(types.len));
    for (types) |td| try writeTypeDef(&body, td);
    try emitSection(w, SECTION_TYPE, body.buf.items);
}

fn writeTypeDef(w: *Writer, td: ctypes.TypeDef) EncodeError!void {
    switch (td) {
        .val => |vt| try writeValType(w, vt),
        .record => |r| {
            try w.appendByte(0x72);
            if (r.fields.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(r.fields.len));
            for (r.fields) |f| {
                try w.writeName(f.name);
                try writeValType(w, f.type);
            }
        },
        .variant => |v| {
            try w.appendByte(0x71);
            if (v.cases.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(v.cases.len));
            for (v.cases) |c| {
                try w.writeName(c.name);
                if (c.type) |vt| {
                    try w.appendByte(0x01);
                    try writeValType(w, vt);
                } else {
                    try w.appendByte(0x00);
                }
                // Trailing 0x00 = no `refines` (current spec; older drafts
                // emitted a u32 idx here).
                try w.appendByte(0x00);
            }
        },
        .list => |l| {
            try w.appendByte(0x70);
            try writeValType(w, l.element);
        },
        .tuple => |t| {
            try w.appendByte(0x6F);
            if (t.fields.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(t.fields.len));
            for (t.fields) |f| try writeValType(w, f);
        },
        .flags => |f| {
            try w.appendByte(0x6E);
            if (f.names.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(f.names.len));
            for (f.names) |n| try w.writeName(n);
        },
        .enum_ => |e| {
            try w.appendByte(0x6D);
            if (e.names.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(e.names.len));
            for (e.names) |n| try w.writeName(n);
        },
        .option => |o| {
            try w.appendByte(0x6B);
            try writeValType(w, o.inner);
        },
        .result => |r| {
            try w.appendByte(0x6A);
            if (r.ok) |vt| {
                try w.appendByte(0x01);
                try writeValType(w, vt);
            } else {
                try w.appendByte(0x00);
            }
            if (r.err) |vt| {
                try w.appendByte(0x01);
                try writeValType(w, vt);
            } else {
                try w.appendByte(0x00);
            }
        },
        .resource => |r| {
            // `(sub resource)` is encoded as `0x3F` followed by an
            // optional destructor:
            //   `0x00`                  → no destructor
            //   `0x01 <funcidx-u32leb>` → destructor at that idx
            // The representation type is always `i32` per spec and
            // is not emitted on the wire — `ResourceType.rep` is
            // descriptive only.
            try w.appendByte(0x3F);
            if (r.destructor) |d| {
                try w.appendByte(0x01);
                try w.writeU32Leb(d);
            } else {
                try w.appendByte(0x00);
            }
        },
        .func => |f| {
            try w.appendByte(0x40);
            if (f.params.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(f.params.len));
            for (f.params) |p| {
                try w.writeName(p.name);
                try writeValType(w, p.type);
            }
            switch (f.results) {
                .none => {
                    try w.appendByte(0x01);
                    try w.appendByte(0x00);
                },
                .unnamed => |vt| {
                    try w.appendByte(0x00);
                    try writeValType(w, vt);
                },
                .named => |list| {
                    try w.appendByte(0x01);
                    if (list.len > std.math.maxInt(u32)) return error.ValueTooLarge;
                    try w.writeU32Leb(@intCast(list.len));
                    for (list) |nv| {
                        try w.writeName(nv.name);
                        try writeValType(w, nv.type);
                    }
                },
            }
        },
        .component => |c| {
            try w.appendByte(0x41);
            if (c.decls.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(c.decls.len));
            for (c.decls) |d| try writeDecl(w, d);
        },
        .instance => |i| {
            try w.appendByte(0x42);
            if (i.decls.len > std.math.maxInt(u32)) return error.ValueTooLarge;
            try w.writeU32Leb(@intCast(i.decls.len));
            for (i.decls) |d| try writeDecl(w, d);
        },
    }
}

fn writeDecl(w: *Writer, d: ctypes.Decl) EncodeError!void {
    switch (d) {
        .core_type => |ct| {
            try w.appendByte(0x00);
            try writeCoreTypeDef(w, ct);
        },
        .type => |td| {
            try w.appendByte(0x01);
            try writeTypeDef(w, td);
        },
        .alias => |a| {
            try w.appendByte(0x02);
            try writeAlias(w, a);
        },
        .import => |imp| {
            try w.appendByte(0x03);
            try writeExternName(w, imp.name);
            try writeExternDesc(w, imp.desc);
        },
        .@"export" => |e| {
            try w.appendByte(0x04);
            try writeExternName(w, e.name);
            try writeExternDesc(w, e.desc);
        },
    }
}

fn writeCanonSection(w: *Writer, canons: []const ctypes.Canon) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (canons.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(canons.len));
    for (canons) |c| try writeCanon(&body, c);
    try emitSection(w, SECTION_CANON, body.buf.items);
}

fn writeCanon(w: *Writer, c: ctypes.Canon) EncodeError!void {
    switch (c) {
        .lift => |l| {
            try w.appendByte(0x00);
            try w.appendByte(0x00); // sub-tag 0x00
            try w.writeU32Leb(l.core_func_idx);
            try writeCanonOpts(w, l.opts);
            try w.writeU32Leb(l.type_idx);
        },
        .lower => |l| {
            try w.appendByte(0x01);
            try w.appendByte(0x00); // sub-tag 0x00
            try w.writeU32Leb(l.func_idx);
            try writeCanonOpts(w, l.opts);
        },
        .resource_new => |idx| {
            try w.appendByte(0x02);
            try w.writeU32Leb(idx);
        },
        .resource_drop => |idx| {
            try w.appendByte(0x03);
            try w.writeU32Leb(idx);
        },
        .resource_rep => |idx| {
            try w.appendByte(0x04);
            try w.writeU32Leb(idx);
        },
    }
}

fn writeCanonOpts(w: *Writer, opts: []const ctypes.CanonOpt) EncodeError!void {
    if (opts.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try w.writeU32Leb(@intCast(opts.len));
    for (opts) |o| {
        switch (o) {
            .string_encoding => |se| switch (se) {
                .utf8 => try w.appendByte(0x00),
                .utf16 => try w.appendByte(0x01),
                .latin1_utf16 => try w.appendByte(0x02),
            },
            .memory => |idx| {
                try w.appendByte(0x03);
                try w.writeU32Leb(idx);
            },
            .realloc => |idx| {
                try w.appendByte(0x04);
                try w.writeU32Leb(idx);
            },
            .post_return => |idx| {
                try w.appendByte(0x05);
                try w.writeU32Leb(idx);
            },
        }
    }
}

fn writeStartSection(w: *Writer, start: ctypes.Start) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    try body.writeU32Leb(start.func_idx);
    if (start.args.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(start.args.len));
    for (start.args) |a| try body.writeU32Leb(a);
    try body.writeU32Leb(start.results);
    try emitSection(w, SECTION_START, body.buf.items);
}

fn writeImportSection(w: *Writer, imports: []const ctypes.ImportDecl) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (imports.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(imports.len));
    for (imports) |imp| {
        try writeExternName(&body, imp.name);
        try writeExternDesc(&body, imp.desc);
    }
    try emitSection(w, SECTION_IMPORT, body.buf.items);
}

fn writeExportSection(w: *Writer, exports: []const ctypes.ExportDecl) EncodeError!void {
    var body = Writer.init(w.allocator);
    defer body.deinit();

    if (exports.len > std.math.maxInt(u32)) return error.ValueTooLarge;
    try body.writeU32Leb(@intCast(exports.len));
    for (exports) |e| {
        try writeExternName(&body, e.name);
        // Top-level exports require a sort_idx. Synthesize one from
        // the descriptor if missing (decls inside a component-type body
        // never set sort_idx; if such a decl reaches this path it's a
        // construction bug — fall back to a best-effort guess so we
        // at least produce a valid binary).
        const si = e.sort_idx orelse synthSortIdxFromDesc(e.desc);
        try writeSortIdx(&body, si);
        // Emit the un-ascribed (`0x00`) form when the descriptor is
        // exactly what the sort_idx would already imply. Tools like
        // `wasm-tools component new` *require* the omitted form for
        // type exports — they reject `0x01 type=eq{idx}` even when
        // the descriptor is identical to the sort's inferred form.
        // Otherwise emit the explicit (`0x01`) form. Both round-trip
        // through our loader.
        if (descMatchesSort(e.desc, si)) {
            try body.appendByte(0x00);
        } else {
            try body.appendByte(0x01);
            try writeExternDesc(&body, e.desc);
        }
    }
    try emitSection(w, SECTION_EXPORT, body.buf.items);
}

/// True iff `desc` is exactly what `synthSortIdxFromDesc` would
/// reconstruct from the sort_idx — meaning we can omit the explicit
/// descriptor on the wire.
fn descMatchesSort(desc: ctypes.ExternDesc, si: ctypes.SortIdx) bool {
    return switch (desc) {
        .type => |bound| switch (bound) {
            .eq => |idx| si.sort == .type and si.idx == idx,
            .sub_resource => false,
        },
        // For func/component/instance, the omitted form derives the
        // descriptor's type from the runtime sort_idx lookup. When
        // we have no concrete type and the AST stores `idx = 0` as a
        // placeholder, emitting the un-ascribed form lets the loader
        // re-derive the correct type — which is more robust than
        // emitting an explicit `idx=0` that may not actually point
        // at the right type-space entry.
        .func => |idx| si.sort == .func and idx == 0,
        .instance => |idx| si.sort == .instance and idx == 0,
        .component => |idx| si.sort == .component and idx == 0,
        else => false,
    };
}

fn synthSortIdxFromDesc(desc: ctypes.ExternDesc) ctypes.SortIdx {
    return switch (desc) {
        .module => .{ .sort = .{ .core = .module }, .idx = 0 },
        .func => |idx| .{ .sort = .func, .idx = idx },
        .value => .{ .sort = .value, .idx = 0 },
        .type => |bound| switch (bound) {
            .eq => |idx| .{ .sort = .type, .idx = idx },
            .sub_resource => .{ .sort = .type, .idx = 0 },
        },
        .component => |idx| .{ .sort = .component, .idx = idx },
        .instance => |idx| .{ .sort = .instance, .idx = idx },
    };
}

// ── Shared encoders for nested forms ───────────────────────────────────────

fn writeValType(w: *Writer, vt: ctypes.ValType) EncodeError!void {
    switch (vt) {
        .bool => try w.writeS64Leb(-1), // 0x7F → -1 in s33
        .s8 => try w.writeS64Leb(-2),
        .u8 => try w.writeS64Leb(-3),
        .s16 => try w.writeS64Leb(-4),
        .u16 => try w.writeS64Leb(-5),
        .s32 => try w.writeS64Leb(-6),
        .u32 => try w.writeS64Leb(-7),
        .s64 => try w.writeS64Leb(-8),
        .u64 => try w.writeS64Leb(-9),
        .f32 => try w.writeS64Leb(-10),
        .f64 => try w.writeS64Leb(-11),
        .char => try w.writeS64Leb(-12),
        .string => try w.writeS64Leb(-13),
        .own => |idx| {
            // 0x69 → -23 in s33
            try w.writeS64Leb(-23);
            try w.writeU32Leb(idx);
        },
        .borrow => |idx| {
            // 0x68 → -24 in s33
            try w.writeS64Leb(-24);
            try w.writeU32Leb(idx);
        },
        .type_idx => |idx| {
            // Non-negative values are type indices in s33 form.
            try w.writeS64Leb(@intCast(idx));
        },
        // Compound forms are not emitted as standalone valtypes — they
        // appear only as `TypeDef` entries. Reaching them here means the
        // AST is malformed; emit as a type index reference to the slot
        // (caller bug — but better than crashing).
        .record, .variant, .list, .tuple, .flags, .enum_, .option, .result => {
            const idx = switch (vt) {
                .record => |i| i,
                .variant => |i| i,
                .list => |i| i,
                .tuple => |i| i,
                .flags => |i| i,
                .enum_ => |i| i,
                .option => |i| i,
                .result => |i| i,
                else => unreachable,
            };
            try w.writeS64Leb(@intCast(idx));
        },
    }
}

fn writeSort(w: *Writer, sort: ctypes.Sort) EncodeError!void {
    switch (sort) {
        .core => |cs| {
            try w.appendByte(0x00);
            try w.appendByte(@intFromEnum(cs));
        },
        .func => try w.appendByte(0x01),
        .value => try w.appendByte(0x02),
        .type => try w.appendByte(0x03),
        .component => try w.appendByte(0x04),
        .instance => try w.appendByte(0x05),
    }
}

fn writeSortIdx(w: *Writer, si: ctypes.SortIdx) EncodeError!void {
    try writeSort(w, si.sort);
    try w.writeU32Leb(si.idx);
}

fn writeExternDesc(w: *Writer, desc: ctypes.ExternDesc) EncodeError!void {
    switch (desc) {
        .module => |idx| {
            try w.appendByte(0x00);
            try w.appendByte(0x11); // module sort
            try w.writeU32Leb(idx);
        },
        .func => |idx| {
            try w.appendByte(0x01);
            try w.writeU32Leb(idx);
        },
        .value => |vt| {
            try w.appendByte(0x02);
            try writeValType(w, vt);
        },
        .type => |bound| {
            try w.appendByte(0x03);
            switch (bound) {
                .eq => |idx| {
                    try w.appendByte(0x00);
                    try w.writeU32Leb(idx);
                },
                .sub_resource => try w.appendByte(0x01),
            }
        },
        .component => |idx| {
            try w.appendByte(0x04);
            try w.writeU32Leb(idx);
        },
        .instance => |idx| {
            try w.appendByte(0x05);
            try w.writeU32Leb(idx);
        },
    }
}

/// Write an importname'/exportname'. We always emit the 0x00 prefix
/// (plain name) — versioned-name support requires re-parsing the
/// embedded `@<semver>` suffix from the name string, which the loader
/// strips, so that information is no longer round-trippable through
/// the AST. For real fixtures this is fine because the externname
/// already includes the `@<semver>` text inline (e.g.
/// `"wasi:io/poll@0.2.6"`); the Component Model treats both forms as
/// equivalent for the purpose of import/export matching.
fn writeExternName(w: *Writer, name: []const u8) EncodeError!void {
    try w.appendByte(0x00);
    try w.writeName(name);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const loader = @import("loader.zig");

test "encode: empty component round-trips" {
    const allocator = std.testing.allocator;

    const empty = ctypes.Component{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = &.{},
        .canons = &.{},
        .imports = &.{},
        .exports = &.{},
    };

    const bytes = try encode(allocator, &empty);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 }, bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try loader.load(bytes, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), decoded.imports.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.exports.len);
}

test "encode: stdio-echo round-trips structurally" {
    const allocator = std.testing.allocator;

    // Same fixture used by loader.zig's regression test. Encoding the
    // loaded AST and re-loading must produce the same import/export
    // counts and identifiers — full byte-equality is not expected
    // because external tools may interleave sections differently.
    const data = @embedFile("fixtures/stdio-echo.wasm");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const c1 = try loader.load(data, arena.allocator());

    const bytes = try encode(allocator, &c1);
    defer allocator.free(bytes);

    const c2 = try loader.load(bytes, arena.allocator());

    try std.testing.expectEqual(c1.imports.len, c2.imports.len);
    try std.testing.expectEqual(c1.exports.len, c2.exports.len);
    try std.testing.expectEqual(c1.core_modules.len, c2.core_modules.len);
    try std.testing.expectEqual(c1.types.len, c2.types.len);
    try std.testing.expectEqual(c1.canons.len, c2.canons.len);
    try std.testing.expectEqual(c1.aliases.len, c2.aliases.len);
    try std.testing.expectEqual(c1.instances.len, c2.instances.len);
    try std.testing.expectEqual(c1.core_instances.len, c2.core_instances.len);
    try std.testing.expectEqual(c1.core_types.len, c2.core_types.len);

    // Spot-check the actual import/export names match in order.
    for (c1.imports, c2.imports) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
    }
    for (c1.exports, c2.exports) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
    }
}

test "encode: component with one record type" {
    const allocator = std.testing.allocator;

    const fields = [_]ctypes.Field{
        .{ .name = "x", .type = .s32 },
        .{ .name = "y", .type = .s32 },
    };
    const types = [_]ctypes.TypeDef{
        .{ .record = .{ .fields = &fields } },
    };
    const c = ctypes.Component{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = &types,
        .canons = &.{},
        .imports = &.{},
        .exports = &.{},
    };

    const bytes = try encode(allocator, &c);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try loader.load(bytes, arena.allocator());

    try std.testing.expectEqual(@as(usize, 1), decoded.types.len);
    try std.testing.expect(decoded.types[0] == .record);
    try std.testing.expectEqual(@as(usize, 2), decoded.types[0].record.fields.len);
    try std.testing.expectEqualStrings("x", decoded.types[0].record.fields[0].name);
    try std.testing.expect(decoded.types[0].record.fields[0].type == .s32);
}

test "encode: import+export round-trip" {
    const allocator = std.testing.allocator;

    const types = [_]ctypes.TypeDef{
        .{ .func = .{ .params = &.{}, .results = .{ .unnamed = .s32 } } },
    };
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "host:env/get-pid", .desc = .{ .func = 0 } },
    };
    const exports = [_]ctypes.ExportDecl{
        .{
            .name = "do-thing",
            .desc = .{ .func = 0 },
            .sort_idx = .{ .sort = .func, .idx = 0 },
        },
    };
    const c = ctypes.Component{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = &types,
        .canons = &.{},
        .imports = &imports,
        .exports = &exports,
    };

    const bytes = try encode(allocator, &c);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try loader.load(bytes, arena.allocator());

    try std.testing.expectEqual(@as(usize, 1), decoded.imports.len);
    try std.testing.expectEqualStrings("host:env/get-pid", decoded.imports[0].name);
    try std.testing.expect(decoded.imports[0].desc == .func);

    try std.testing.expectEqual(@as(usize, 1), decoded.exports.len);
    try std.testing.expectEqualStrings("do-thing", decoded.exports[0].name);
    try std.testing.expect(decoded.exports[0].desc == .func);
}

test "encode: section_order interleaves type+import+alias for resource sharing" {
    // Mimic the shape `wasm-tools component new --adapt` produces:
    //
    //   type 0 = instance { (sub resource) "error" }
    //   import "wasi:io/error"   instance(type 0)        -> instance idx 0
    //   alias  export 0 "error"  type                    -> type idx 1
    //   type 2 = instance { (alias outer 1 1) (eq 1) "error" }
    //   import "wasi:io/streams" instance(type 2)        -> instance idx 1
    //
    // The conventional order ("all types first, then imports, then
    // aliases") would put alias output at type idx 28 instead of 1,
    // breaking the `(alias outer 1 1)` ref inside the io/streams
    // instance type body. `section_order` preserves the interleaving
    // and keeps the references valid.
    const allocator = std.testing.allocator;

    const error_decls = [_]ctypes.Decl{
        .{ .@"export" = .{
            .name = "error",
            .desc = .{ .type = .sub_resource },
        } },
    };
    const streams_decls = [_]ctypes.Decl{
        .{ .alias = .{ .outer = .{
            .sort = .type,
            .outer_count = 1,
            .idx = 1,
        } } },
        .{ .@"export" = .{
            .name = "error",
            .desc = .{ .type = .{ .eq = 1 } },
        } },
    };
    const types = [_]ctypes.TypeDef{
        .{ .instance = .{ .decls = &error_decls } },
        .{ .instance = .{ .decls = &streams_decls } },
    };
    const imports = [_]ctypes.ImportDecl{
        .{ .name = "wasi:io/error@0.2.6", .desc = .{ .instance = 0 } },
        .{ .name = "wasi:io/streams@0.2.6", .desc = .{ .instance = 1 } },
    };
    const aliases = [_]ctypes.Alias{
        .{ .instance_export = .{
            .sort = .type,
            .instance_idx = 0,
            .name = "error",
        } },
    };

    const order = [_]ctypes.SectionEntry{
        .{ .kind = .type, .start = 0, .count = 1 },
        .{ .kind = .import, .start = 0, .count = 1 },
        .{ .kind = .alias, .start = 0, .count = 1 },
        .{ .kind = .type, .start = 1, .count = 1 },
        .{ .kind = .import, .start = 1, .count = 1 },
    };

    const c = ctypes.Component{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &aliases,
        .types = &types,
        .canons = &.{},
        .imports = &imports,
        .exports = &.{},
        .section_order = &order,
    };

    const bytes = try encode(allocator, &c);
    defer allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try loader.load(bytes, arena.allocator());

    try std.testing.expectEqual(@as(usize, 2), decoded.types.len);
    try std.testing.expectEqual(@as(usize, 2), decoded.imports.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.aliases.len);
    try std.testing.expectEqualStrings("wasi:io/error@0.2.6", decoded.imports[0].name);
    try std.testing.expectEqualStrings("wasi:io/streams@0.2.6", decoded.imports[1].name);
    // Alias placed between the imports — its output is type idx 1, so
    // the streams instance's `(alias outer 1 1)` resolves correctly.
    try std.testing.expect(decoded.aliases[0] == .instance_export);
    try std.testing.expectEqualStrings("error", decoded.aliases[0].instance_export.name);
}

test "encode: section_order with no entries emits empty body after preamble" {
    const allocator = std.testing.allocator;

    const c = ctypes.Component{
        .core_modules = &.{},
        .core_instances = &.{},
        .core_types = &.{},
        .components = &.{},
        .instances = &.{},
        .aliases = &.{},
        .types = &.{},
        .canons = &.{},
        .imports = &.{},
        .exports = &.{},
        .section_order = &.{},
    };

    const bytes = try encode(allocator, &c);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 }, bytes);
}
