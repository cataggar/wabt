//! WebAssembly text format parser.
//!
//! Parses .wat source text into Module IR. Handles all top-level module
//! fields: type, func, table, memory, global, import, export, start,
//! elem, data.

const std = @import("std");
const Lex = @import("Lexer.zig");
const Lexer = Lex.Lexer;
const TokenKind = Lex.TokenKind;
const types = @import("../types.zig");
const Mod = @import("../Module.zig");
const leb128 = @import("../leb128.zig");
const Opcode = @import("../Opcode.zig");
const Validator = @import("../Validator.zig");
const binary_reader = @import("../binary/reader.zig");
const binary_writer = @import("../binary/writer.zig");
const TextWriter = @import("Writer.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidModule,
    InvalidType,
    InvalidNumber,
    OutOfMemory,
};

/// Parse a WebAssembly text format source into a Module.
/// Why a module was rejected as malformed, and where.
///
/// `error.InvalidModule` is raised by any of several dozen checks and on its
/// own says nothing about which, so a caller that wants to report something
/// useful asks for one of these.
pub const Diagnostic = struct {
    /// Byte offset into the source of the token the check had just read.
    offset: usize,
    /// Name of the parser function that rejected the input.
    check: []const u8,
    /// Line in Parser.zig of the check that rejected it.
    parser_line: u32,

    /// One-based line and column of `offset` within `source`.
    pub fn position(self: Diagnostic, source: []const u8) struct { line: u32, column: u32 } {
        var line: u32 = 1;
        var column: u32 = 1;
        for (source[0..@min(self.offset, source.len)]) |c| {
            if (c == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        return .{ .line = line, .column = column };
    }

    /// The source line `offset` falls on, without its line ending.
    pub fn sourceLine(self: Diagnostic, source: []const u8) []const u8 {
        const at = @min(self.offset, source.len);
        const start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |i| i + 1 else 0;
        const end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
        return source[start..end];
    }
};

pub fn parseModule(allocator: std.mem.Allocator, source: []const u8) ParseError!Mod.Module {
    return parseModuleDiag(allocator, source, null);
}

/// As `parseModule`, but writes to `diagnostic` when the module is rejected as
/// malformed, so the caller can say where and why rather than only that it was.
pub fn parseModuleDiag(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: ?*?Diagnostic,
) ParseError!Mod.Module {
    var p = Parser{ .lexer = Lexer.init(source), .allocator = allocator };
    errdefer if (diagnostic) |d| {
        d.* = p.diagnostic;
    };
    defer p.func_names.deinit(allocator);
    defer p.type_names.deinit(allocator);
    defer p.local_names.deinit(allocator);
    defer p.global_names.deinit(allocator);
    defer p.table_names.deinit(allocator);
    defer p.tag_names.deinit(allocator);
    defer p.memory_names.deinit(allocator);
    defer p.data_names.deinit(allocator);
    defer p.elem_names.deinit(allocator);
    defer p.label_stack.deinit(allocator);
    defer p.collected_type_refs.deinit(allocator);
    var module = Mod.Module.init(allocator);
    errdefer module.deinit();
    p.module = &module;

    // Pre-scan: collect function, type, global, table, memory, and data names for forward references.
    prescanNames(source, &p.func_names, &p.type_names, &p.global_names, &p.table_names, &p.memory_names, &p.data_names, allocator);

    try p.expect(.l_paren);
    // Skip any annotations between '(' and 'module'
    while (p.peek().kind == .annotation) {
        _ = p.advance();
        try p.skipAnnotation();
    }
    try p.expect(.kw_module);

    // Skip annotations after 'module'
    while (p.peek().kind == .annotation) {
        _ = p.advance();
        try p.skipAnnotation();
    }

    // Optional module name
    if (p.peek().kind == .identifier) {
        module.name = p.advance().text;
    }

    // Parse module fields — two passes:
    // Pass 1: process only (type ...) declarations to build the type section first.
    // This ensures explicit type indices are assigned before implicit function types.
    p.module = &module;
    const saved_pos = p.lexer.pos;
    const saved_peeked = p.peeked;

    while (p.peek().kind == .l_paren or p.peek().kind == .annotation or p.peek().kind == .invalid) {
        if (p.peek().kind == .annotation) {
            _ = p.advance();
            try p.skipAnnotation();
            continue;
        }
        if (p.peek().kind == .invalid) {
            _ = p.advance();
            p.markMalformed(@src());
            continue;
        }
        _ = p.advance(); // consume '('
        // Skip annotations between '(' and keyword
        while (p.peek().kind == .annotation) {
            _ = p.advance();
            try p.skipAnnotation();
        }
        const kw = p.advance();
        switch (kw.kind) {
            .kw_type => try p.parseType(&module),
            .kw_rec => try p.parseRec(&module),
            else => try p.skipSExpr(),
        }
        p.skipAnnotations();
        try p.expect(.r_paren);
    }

    // Canonicalize rec groups for iso-recursive type equivalence
    p.canonicalizeTypes(&module);

    // Record declared type count (before implicit types from funcs/blocks are added)
    module.num_declared_types = @intCast(module.module_types.items.len);

    // Pass 2: process all other declarations (skip type/rec which were already handled).
    p.lexer.pos = saved_pos;
    p.peeked = saved_peeked;
    const pass1_malformed = p.malformed;
    p.malformed = false; // Reset malformed flag for Pass 2
    var seen_non_import_def = false; // Track if we've seen func/global/table/memory definitions

    while (p.peek().kind == .l_paren or p.peek().kind == .annotation or p.peek().kind == .invalid) {
        // Skip annotations: (@id ...) — consume tokens until matching ')'
        if (p.peek().kind == .annotation) {
            _ = p.advance(); // consume annotation token
            try p.skipAnnotation();
            continue;
        }
        if (p.peek().kind == .invalid) {
            _ = p.advance();
            p.markMalformed(@src());
            continue;
        }
        _ = p.advance(); // consume '('
        // Skip annotations between '(' and keyword
        while (p.peek().kind == .annotation) {
            _ = p.advance();
            try p.skipAnnotation();
        }
        const kw = p.advance();
        switch (kw.kind) {
            .kw_type, .kw_rec => try p.skipSExpr(), // already processed
            .kw_func => {
                try p.parseFunc(&module);
                // Check if this was an inline import (don't set seen_non_import_def)
                // Inline imports have is_import set on the last func added
                const last = module.funcs.items[module.funcs.items.len - 1];
                if (!last.is_import) seen_non_import_def = true;
            },
            .kw_table => {
                try p.parseTable(&module);
                const last = module.tables.items[module.tables.items.len - 1];
                if (!last.is_import) seen_non_import_def = true;
            },
            .kw_memory => {
                try p.parseMemory(&module);
                const last = module.memories.items[module.memories.items.len - 1];
                if (!last.is_import) seen_non_import_def = true;
            },
            .kw_global => {
                try p.parseGlobal(&module);
                const last = module.globals.items[module.globals.items.len - 1];
                if (!last.is_import) seen_non_import_def = true;
            },
            .kw_import => {
                if (seen_non_import_def) p.markMalformed(@src());
                try p.parseImport(&module);
            },
            .kw_export => try p.parseExport(&module),
            .kw_start => try p.parseStart(&module),
            .kw_elem => try p.parseElem(&module),
            .kw_data => try p.parseData(&module),
            .kw_definition => try p.skipSExpr(),
            .kw_tag => {
                try p.parseTag(&module);
                // A defined tag closes the import prologue exactly as a
                // defined func/table/memory/global does. Without this a
                // later `(import ... (tag ...))` was accepted and left the
                // tag index space in source order, while the binary wabt
                // writes puts every import first -- so `throw $t` in the
                // text meant one tag and the same `throw` in the output
                // meant another.
                const last = module.tags.items[module.tags.items.len - 1];
                if (!last.is_import) seen_non_import_def = true;
            },
            .invalid => {
                p.markMalformed(@src());
                try p.skipSExpr();
            },
            else => try p.skipSExpr(),
        }
        p.skipAnnotations();
        try p.expect(.r_paren);
        p.skipAnnotations();
    }

    p.skipAnnotations();
    try p.expect(.r_paren);
    // Check for unexpected trailing tokens
    if (p.peek().kind != .eof) p.markMalformed(@src());
    if (p.malformed or pass1_malformed) {
        return error.InvalidModule;
    }
    return module;
}

/// Map a bare heaptype name (`any`, `nofunc`, …) to its abstract heap type.
/// `func` is handled by its own keyword token before this is reached.
fn abstractHeapTypeByName(name: []const u8) ?types.AbstractHeapType {
    const table = .{
        .{ "extern", types.AbstractHeapType.extern_ },
        .{ "any", types.AbstractHeapType.any },
        .{ "eq", types.AbstractHeapType.eq },
        .{ "i31", types.AbstractHeapType.i31 },
        .{ "struct", types.AbstractHeapType.struct_ },
        .{ "array", types.AbstractHeapType.array },
        .{ "exn", types.AbstractHeapType.exn },
        .{ "none", types.AbstractHeapType.none },
        .{ "nofunc", types.AbstractHeapType.nofunc },
        .{ "noextern", types.AbstractHeapType.noextern },
        .{ "noexn", types.AbstractHeapType.noexn },
        .{ "func", types.AbstractHeapType.func },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Skip an annotation and its content in prescan mode (no Parser struct available).
fn skipPrescanAnnotation(lex: *Lexer) void {
    var depth: u32 = 1;
    while (depth > 0) {
        const tok = lex.next();
        switch (tok.kind) {
            .l_paren, .annotation => depth += 1,
            .r_paren => depth -= 1,
            .eof => return,
            .invalid => {
                if (tok.text.len >= 2 and tok.text[0] == '(' and tok.text[1] == '@') {
                    depth += 1;
                }
            },
            else => {},
        }
    }
}

/// Fast pre-scan of source text to collect function, type, and global names
/// for forward reference resolution. Uses a separate lexer pass.
fn prescanNames(
    source: []const u8,
    func_names: *std.StringArrayHashMapUnmanaged(u32),
    type_names: *std.StringArrayHashMapUnmanaged(u32),
    global_names: *std.StringArrayHashMapUnmanaged(u32),
    table_names: *std.StringArrayHashMapUnmanaged(u32),
    memory_names: *std.StringArrayHashMapUnmanaged(u32),
    data_names: *std.StringArrayHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) void {
    var lex = Lexer.init(source);
    var func_idx: u32 = 0;
    var type_idx: u32 = 0;
    var global_idx: u32 = 0;
    var table_idx: u32 = 0;
    var memory_idx: u32 = 0;
    var data_idx: u32 = 0;

    // Skip (module and optional name
    var tok = lex.next();
    if (tok.kind != .l_paren) return;
    tok = lex.next();
    // Skip annotations between ( and module
    while (tok.kind == .annotation) {
        skipPrescanAnnotation(&lex);
        tok = lex.next();
    }
    if (tok.kind != .kw_module) return;
    tok = lex.next();
    // Skip annotations after module keyword
    while (tok.kind == .annotation) {
        skipPrescanAnnotation(&lex);
        tok = lex.next();
    }
    if (tok.kind == .identifier) tok = lex.next();
    // Skip annotations after module name
    while (tok.kind == .annotation) {
        skipPrescanAnnotation(&lex);
        tok = lex.next();
    }

    // Scan top-level fields
    while (tok.kind == .l_paren or tok.kind == .annotation) {
        // Skip module-level annotations
        if (tok.kind == .annotation) {
            skipPrescanAnnotation(&lex);
            tok = lex.next();
            continue;
        }
        tok = lex.next();
        // Skip annotations between ( and keyword
        while (tok.kind == .annotation) {
            skipPrescanAnnotation(&lex);
            tok = lex.next();
        }
        if (tok.kind == .kw_func) {
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .identifier) {
                func_names.put(allocator, normalizeIdentifier(allocator, tok.text), func_idx) catch {};
            }
            func_idx += 1;
        } else if (tok.kind == .kw_type) {
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .identifier) {
                type_names.put(allocator, normalizeIdentifier(allocator, tok.text), type_idx) catch {};
            }
            type_idx += 1;
        } else if (tok.kind == .kw_global) {
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .identifier) {
                global_names.put(allocator, normalizeIdentifier(allocator, tok.text), global_idx) catch {};
            }
            global_idx += 1;
        } else if (tok.kind == .kw_table) {
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .identifier) {
                table_names.put(allocator, normalizeIdentifier(allocator, tok.text), table_idx) catch {};
            }
            table_idx += 1;
        } else if (tok.kind == .kw_memory) {
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .identifier) {
                memory_names.put(allocator, normalizeIdentifier(allocator, tok.text), memory_idx) catch {};
            }
            memory_idx += 1;
        } else if (tok.kind == .kw_data) {
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .identifier) {
                data_names.put(allocator, normalizeIdentifier(allocator, tok.text), data_idx) catch {};
            }
            data_idx += 1;
        } else if (tok.kind == .kw_import) {
            // Imports define indices for their kind. We need to find
            // (import "mod" "name" (func $name ...)) to count import funcs.
            // Skip module and field strings, then read the '(' before kind desc
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            // module string consumed
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            // field string consumed
            tok = lex.next();
            while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
            if (tok.kind == .l_paren) {
                tok = lex.next();
                while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
                if (tok.kind == .kw_func) {
                    tok = lex.next();
                    while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
                    if (tok.kind == .identifier) {
                        func_names.put(allocator, normalizeIdentifier(allocator, tok.text), func_idx) catch {};
                    }
                    func_idx += 1;
                } else if (tok.kind == .kw_global) {
                    tok = lex.next();
                    while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
                    if (tok.kind == .identifier) {
                        global_names.put(allocator, normalizeIdentifier(allocator, tok.text), global_idx) catch {};
                    }
                    global_idx += 1;
                } else if (tok.kind == .kw_table) {
                    tok = lex.next();
                    while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
                    if (tok.kind == .identifier) {
                        table_names.put(allocator, normalizeIdentifier(allocator, tok.text), table_idx) catch {};
                    }
                    table_idx += 1;
                } else if (tok.kind == .kw_memory) {
                    tok = lex.next();
                    while (tok.kind == .annotation) { skipPrescanAnnotation(&lex); tok = lex.next(); }
                    if (tok.kind == .identifier) {
                        memory_names.put(allocator, normalizeIdentifier(allocator, tok.text), memory_idx) catch {};
                    }
                    memory_idx += 1;
                }
                // Skip remaining tokens in kind desc '(func/global/... ...)' 
                var inner_depth: u32 = 1;
                if (tok.kind == .l_paren or tok.kind == .annotation) inner_depth += 1;
                while (inner_depth > 0) {
                    tok = lex.next();
                    if (tok.kind == .l_paren or tok.kind == .annotation) inner_depth += 1;
                    if (tok.kind == .r_paren) inner_depth -= 1;
                    if (tok.kind == .eof) return;
                    if (tok.kind == .invalid and tok.text.len >= 2 and tok.text[0] == '(' and tok.text[1] == '@') inner_depth += 1;
                }
            }
        }
        // Skip to matching ')'
        var depth: u32 = 1;
        if (tok.kind == .l_paren or tok.kind == .annotation) depth += 1;
        while (depth > 0) {
            tok = lex.next();
            if (tok.kind == .l_paren or tok.kind == .annotation) depth += 1;
            if (tok.kind == .r_paren) depth -= 1;
            if (tok.kind == .eof) return;
            if (tok.kind == .invalid and tok.text.len >= 2 and tok.text[0] == '(' and tok.text[1] == '@') depth += 1;
        }
        tok = lex.next(); // next top-level field
    }
}

// ── Internal parser ─────────────────────────────────────────────────────

const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    peeked: ?Lex.Token = null,
    module: ?*Mod.Module = null,
    /// Set when malformed input is detected (e.g. invalid alignment).
    malformed: bool = false,
    /// Where the first malformed input was noticed, and by which check.
    diagnostic: ?Diagnostic = null,
    /// Offset of the most recently consumed token, which is what a check that
    /// rejects the input has just looked at.
    last_offset: usize = 0,
    /// True when parsing inside a (rec ...) group (forward type refs allowed).
    in_rec: bool = false,
    /// Upper bound type index for the current rec group.
    rec_end: u32 = 0,
    /// Map from function $name to index (for name resolution in call instructions).
    func_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from type $name to index (for name resolution).
    type_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from local/param $name to index (per-function, cleared for each func).
    local_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from global $name to index.
    global_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from table $name to index.
    table_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from tag $name to index.
    tag_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from memory $name to index.
    memory_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from data segment $name to index.
    data_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from elem segment $name to index.
    elem_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Stack of label $names for block/loop/if — most recent label at the end.
    label_stack: std.ArrayListUnmanaged(?[]const u8) = .empty,
    /// Type indices referenced during current type parsing (for iso-recursive canonicalization).
    collected_type_refs: std.ArrayListUnmanaged(u32) = .empty,
    /// True when parsing a type section entry (controls type ref collection).
    in_type_parse: bool = false,

    fn peek(self: *Parser) Lex.Token {
        if (self.peeked) |t| return t;
        self.peeked = self.lexer.next();
        return self.peeked.?;
    }

    fn advance(self: *Parser) Lex.Token {
        const tok = if (self.peeked) |t| blk: {
            self.peeked = null;
            break :blk t;
        } else self.lexer.next();
        self.last_offset = tok.offset;
        return tok;
    }

    /// Record that the input is malformed, keeping where in the source it was
    /// noticed and which check noticed it. Only the first is kept: later marks
    /// are usually consequences of the first, and the earliest one is the one
    /// worth reporting.
    fn markMalformed(self: *Parser, src: std.builtin.SourceLocation) void {
        self.malformed = true;
        if (self.diagnostic == null) {
            self.diagnostic = .{
                .offset = self.last_offset,
                .check = src.fn_name,
                .parser_line = src.line,
            };
        }
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        const tok = self.advance();
        if (tok.kind != kind) return error.UnexpectedToken;
    }

    fn skipSExpr(self: *Parser) ParseError!void {
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = self.advance();
            switch (tok.kind) {
                .l_paren, .annotation => depth += 1,
                .r_paren => {
                    depth -= 1;
                    if (depth == 0) {
                        // Put the ')' back so the caller's expect(.r_paren) works
                        self.peeked = tok;
                        return;
                    }
                },
                .eof => return error.InvalidModule,
                else => {},
            }
        }
    }

    fn skipAnnotation(self: *Parser) ParseError!void {
        // The annotation token (@id has been consumed. Now skip until matching ')'.
        // Annotations can contain nested s-expressions.
        // Invalid tokens inside annotations (e.g. (@) empty id) are harmless.
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = self.advance();
            switch (tok.kind) {
                .l_paren, .annotation => depth += 1,
                .r_paren => depth -= 1,
                .eof => return error.InvalidModule,
                .invalid => {
                    // If the invalid token consumed a '(' (e.g. "(@" empty annotation),
                    // increment depth to account for it.
                    if (tok.text.len >= 2 and tok.text[0] == '(' and tok.text[1] == '@') {
                        depth += 1;
                    }
                },
                else => {},
            }
        }
    }

    /// Skip any adjacent annotation tokens at the current position.
    fn skipAnnotations(self: *Parser) void {
        while (self.peek().kind == .annotation) {
            _ = self.advance();
            self.skipAnnotation() catch return;
        }
    }

    fn parseU32(self: *Parser) ParseError!u32 {
        const tok = self.advance();
        if (tok.kind != .integer) return error.InvalidNumber;
        const clean = stripUnderscores(tok.text);
        return std.fmt.parseInt(u32, clean.slice(), 0) catch return error.InvalidNumber;
    }

    fn parseU64(self: *Parser) ParseError!u64 {
        const tok = self.advance();
        if (tok.kind != .integer) return error.InvalidNumber;
        const clean = stripUnderscores(tok.text);
        return std.fmt.parseInt(u64, clean.slice(), 0) catch return error.InvalidNumber;
    }

    /// Parse an index that may be either a numeric u32 or a $name identifier.
    /// Resolves $name against the given name map.
    fn parseIndexWithMap(self: *Parser, names: *const std.StringArrayHashMapUnmanaged(u32)) ParseError!u32 {
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            return self.lookupName(names, tok.text) orelse return error.InvalidNumber;
        }
        return self.parseU32();
    }

    fn parseFuncIdx(self: *Parser) ParseError!u32 {
        return self.parseIndexWithMap(&self.func_names);
    }

    fn parseGlobalIdx(self: *Parser) ParseError!u32 {
        return self.parseIndexWithMap(&self.global_names);
    }

    fn parseTableIdx(self: *Parser) ParseError!u32 {
        return self.parseIndexWithMap(&self.table_names);
    }

    fn parseTypeIdx(self: *Parser) ParseError!u32 {
        return self.parseIndexWithMap(&self.type_names);
    }

    /// Look up an identifier in a name map, trying both raw and normalized forms.
    fn lookupName(self: *Parser, names: *const std.StringArrayHashMapUnmanaged(u32), text: []const u8) ?u32 {
        if (names.get(text)) |idx| return idx;
        const norm = normalizeIdentifier(self.allocator, text);
        if (norm.ptr != text.ptr) {
            defer self.allocator.free(norm);
            if (names.get(norm)) |idx| return idx;
        }
        return null;
    }

    /// Check if an identifier is empty (just "$" with no following chars)
    fn checkEmptyId(self: *Parser, text: []const u8) void {
        if (text.len == 1 and text[0] == '$') self.markMalformed(@src());
    }

    fn parseValType(self: *Parser) ParseError!types.ValType {
        // Handle parenthesized reference types: (ref null <heaptype>) / (ref <heaptype>)
        if (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_ref) {
                _ = self.advance(); // consume 'ref'
                var nullable = false;
                if (self.peek().kind == .kw_null) {
                    _ = self.advance(); // consume 'null'
                    nullable = true;
                }
                // Parse heap type (could be $id, keyword like func/extern/any, or index)
                var heap_text: []const u8 = "";
                var resolved_type_idx: u32 = std.math.maxInt(u32);
                if (self.peek().kind != .r_paren) {
                    const ht = self.advance();
                    heap_text = ht.text;
                    // Validate type index if it's a number
                    if (ht.kind == .integer) {
                        const idx = std.fmt.parseInt(u32, ht.text, 0) catch {
                            self.markMalformed(@src());
                            try self.expect(.r_paren);
                            return if (nullable) .concrete_ref_null else .concrete_ref;
                        };
                        resolved_type_idx = idx;
                        if (self.in_rec) {
                            // Within rec group, allow refs within the group but not beyond
                            if (idx >= self.rec_end) self.markMalformed(@src());
                        } else if (self.in_type_parse) {
                            if (self.module) |mod| {
                                // Allow self-reference: idx == items.len refers to the type currently being parsed
                                const max = if (mod.num_declared_types > 0) mod.num_declared_types else @as(u32, @intCast(mod.module_types.items.len));
                                if (idx >= max) self.markMalformed(@src());
                            }
                        } else {
                            if (self.module) |mod| {
                                const max_types = if (mod.num_declared_types > 0) mod.num_declared_types else @as(u32, @intCast(mod.module_types.items.len));
                                if (idx >= max_types) self.markMalformed(@src());
                            }
                        }
                    } else if (ht.kind == .identifier) {
                        // Validate named type references
                        if (self.lookupName(&self.type_names, ht.text)) |idx| {
                            resolved_type_idx = idx;
                            if (self.in_rec) {
                                if (idx >= self.rec_end) self.markMalformed(@src());
                            } else if (self.in_type_parse) {
                                if (self.module) |mod| {
                                    if (idx > mod.module_types.items.len) self.markMalformed(@src());
                                }
                            } else {
                                if (self.module) |mod| {
                                    if (idx >= mod.module_types.items.len) self.markMalformed(@src());
                                }
                            }
                        } else {
                            self.markMalformed(@src());
                        }
                    }
                }
                try self.expect(.r_paren);
                // Canonicalize: (ref null func) → funcref, (ref null extern) → externref, etc.
                if (nullable and heap_text.len > 0) {
                    if (std.mem.eql(u8, heap_text, "func")) return .funcref;
                    if (std.mem.eql(u8, heap_text, "extern")) return .externref;
                    if (std.mem.eql(u8, heap_text, "any")) return .anyref;
                    if (std.mem.eql(u8, heap_text, "exn")) return .exnref;
                    if (std.mem.eql(u8, heap_text, "i31")) return .i31ref;
                    if (std.mem.eql(u8, heap_text, "eq")) return .eqref;
                    if (std.mem.eql(u8, heap_text, "struct")) return .structref;
                    if (std.mem.eql(u8, heap_text, "array")) return .arrayref;
                    if (std.mem.eql(u8, heap_text, "nofunc")) return .nullfuncref;
                    if (std.mem.eql(u8, heap_text, "noextern")) return .nullexternref;
                    if (std.mem.eql(u8, heap_text, "none")) return .nullref;
                    if (std.mem.eql(u8, heap_text, "noexn")) return .nullexnref;
                }
                // Canonicalize non-nullable abstract heap types
                if (!nullable and heap_text.len > 0) {
                    if (std.mem.eql(u8, heap_text, "func")) return .ref_func;
                    if (std.mem.eql(u8, heap_text, "extern")) return .ref_extern;
                    if (std.mem.eql(u8, heap_text, "any")) return .ref_any;
                    if (std.mem.eql(u8, heap_text, "i31")) return .ref_i31;
                    if (std.mem.eql(u8, heap_text, "eq")) return .ref_eq;
                    if (std.mem.eql(u8, heap_text, "struct")) return .ref_struct;
                    if (std.mem.eql(u8, heap_text, "array")) return .ref_array;
                    if (std.mem.eql(u8, heap_text, "exn")) return .ref_exn;
                    if (std.mem.eql(u8, heap_text, "none")) return .ref_none;
                    if (std.mem.eql(u8, heap_text, "nofunc")) return .ref_nofunc;
                    if (std.mem.eql(u8, heap_text, "noextern")) return .ref_noextern;
                    if (std.mem.eql(u8, heap_text, "noexn")) return .ref_noexn;
                }
                // Record type index for concrete type references (only during type section parsing)
                if (self.in_type_parse and resolved_type_idx != std.math.maxInt(u32)) {
                    self.collected_type_refs.append(self.allocator, resolved_type_idx) catch {};
                }
                return if (nullable) .concrete_ref_null else .concrete_ref;
            }
            // Not a ref type — restore state
            self.lexer.pos = save_pos;
            self.peeked = save_peeked;
            return error.InvalidType;
        }
        const tok = self.advance();
        return switch (tok.kind) {
            .kw_i32 => .i32,
            .kw_i64 => .i64,
            .kw_f32 => .f32,
            .kw_f64 => .f64,
            .kw_v128 => .v128,
            .kw_funcref => .funcref,
            .kw_externref => .externref,
            .kw_anyref => .anyref,
            .kw_exnref => .exnref,
            .kw_nullref => .nullref,
            .kw_nullfuncref => .nullfuncref,
            .kw_nullexternref => .nullexternref,
            .kw_nullexnref => .nullexnref,
            .kw_i31ref => .i31ref,
            .kw_eqref => .eqref,
            .kw_structref => .structref,
            .kw_arrayref => .arrayref,
            .kw_i8 => .i8,
            .kw_i16 => .i16,
            else => error.InvalidType,
        };
    }

    /// Read a reference type that stands on its own rather than inside a
    /// signature -- the element type an element segment names before its
    /// elements. Both spellings are accepted, the bare keyword (`funcref`,
    /// `anyref`, `nullexternref`, ...) and the folded `(ref null? heaptype)`,
    /// because `parseIndexedValType` already knows every one of them and
    /// reports the index a concrete heap type resolved to.
    ///
    /// Returns null, leaving the parser exactly where it was, when what comes
    /// next is not a reference type. The caller can then try the other things
    /// that share the position, such as an offset expression.
    fn parseRefTypeAnnotation(self: *Parser) ?IndexedValType {
        const save_pos = self.lexer.pos;
        const save_peeked = self.peeked;
        const indexed = self.parseIndexedValType() catch {
            self.lexer.pos = save_pos;
            self.peeked = save_peeked;
            return null;
        };
        if (!indexed.val_type.isRefType()) {
            self.lexer.pos = save_pos;
            self.peeked = save_peeked;
            return null;
        }
        return indexed;
    }

    fn parseFuncSig(self: *Parser, module: *Mod.Module) ParseError!struct { params: []const types.ValType, results: []const types.ValType, param_type_idxs: []const u32, result_type_idxs: []const u32 } {
        var params: std.ArrayListUnmanaged(types.ValType) = .empty;
        errdefer params.deinit(self.allocator);
        var param_tidxs: std.ArrayListUnmanaged(u32) = .empty;
        errdefer param_tidxs.deinit(self.allocator);
        var results: std.ArrayListUnmanaged(types.ValType) = .empty;
        errdefer results.deinit(self.allocator);
        var result_tidxs: std.ArrayListUnmanaged(u32) = .empty;
        errdefer result_tidxs.deinit(self.allocator);
        var seen_result = false;

        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance();
            self.skipAnnotations();
            const kw = self.peek();
            if (kw.kind == .kw_param) {
                if (seen_result) return error.UnexpectedToken; // param after result
                _ = self.advance();
                self.skipAnnotations();
                // Optional identifier
                if (self.peek().kind == .identifier) _ = self.advance();
                self.skipAnnotations();
                while (self.peek().kind != .r_paren) {
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    try params.append(self.allocator, try self.parseValType());
                    self.in_type_parse = saved_itp;
                    const tidx: u32 = if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF;
                    param_tidxs.append(self.allocator, tidx) catch {};
                    self.skipAnnotations();
                }
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else if (kw.kind == .kw_result) {
                seen_result = true;
                _ = self.advance();
                self.skipAnnotations();
                while (self.peek().kind != .r_paren) {
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    try results.append(self.allocator, try self.parseValType());
                    self.in_type_parse = saved_itp;
                    const tidx: u32 = if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF;
                    result_tidxs.append(self.allocator, tidx) catch {};
                    self.skipAnnotations();
                }
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else {
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                break;
            }
        }

        _ = module;
        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .results = try results.toOwnedSlice(self.allocator),
            .param_type_idxs = try param_tidxs.toOwnedSlice(self.allocator),
            .result_type_idxs = try result_tidxs.toOwnedSlice(self.allocator),
        };
    }

    // -- module fields --

    fn parseType(self: *Parser, module: *Mod.Module) ParseError!void {
        // Clear type ref collection for this type
        self.collected_type_refs.clearRetainingCapacity();
        self.in_type_parse = true;
        defer self.in_type_parse = false;
        // Allow self-referencing types (standalone types form implicit singleton rec groups)
        const was_in_rec = self.in_rec;
        const old_rec_end = self.rec_end;
        if (!self.in_rec) {
            self.in_rec = true;
            self.rec_end = @as(u32, @intCast(module.module_types.items.len)) + 1;
        }
        defer {
            self.in_rec = was_in_rec;
            self.rec_end = old_rec_end;
        }
        // (type $name? (func (param ...) (result ...)))
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            self.type_names.put(self.allocator, name, @intCast(module.module_types.items.len)) catch {};
        }
        self.skipAnnotations();
        try self.expect(.l_paren);

        // Check for (sub ...) wrapper
        var meta = Mod.TypeMeta{};
        if (std.mem.eql(u8, self.peek().text, "sub")) {
            _ = self.advance(); // consume 'sub'
            meta.is_sub = true;
            meta.is_final = false; // sub types are non-final by default
            // Check for 'final' modifier
            if (std.mem.eql(u8, self.peek().text, "final")) {
                _ = self.advance();
                meta.is_final = true;
            }
            // Check for parent type reference ($name or index)
            if (self.peek().kind == .identifier) {
                const parent_name = self.advance().text;
                if (self.type_names.get(parent_name)) |idx| {
                    meta.parent = idx;
                }
            } else if (self.peek().kind == .integer) {
                meta.parent = self.parseU32() catch std.math.maxInt(u32);
            }
            // Next should be '(' for the actual type definition
            try self.expect(.l_paren);
        }

        // Parse the inner type: func, struct, or array
        self.skipAnnotations();
        const inner_text = self.peek().text;
        if (self.peek().kind == .kw_func) {
            meta.kind = .func;
            _ = self.advance();
            self.skipAnnotations();
            const sig = try self.parseFuncSig(module);
            self.skipAnnotations();
            try self.expect(.r_paren);
            if (meta.is_sub) try self.expect(.r_paren); // close (sub ...)
            try module.module_types.append(self.allocator, .{
                .func_type = .{ .params = sig.params, .results = sig.results, .param_type_idxs = sig.param_type_idxs, .result_type_idxs = sig.result_type_idxs },
            });
        } else {
            if (std.mem.eql(u8, inner_text, "struct")) {
                meta.kind = .struct_;
                _ = self.advance(); // consume 'struct'
                // Parse struct fields: (field [$name] [mut] <valtype>) ...
                var fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .empty;
                while (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance(); // consume '('
                    if (std.mem.eql(u8, self.peek().text, "field")) {
                        _ = self.advance(); // consume 'field'
                        var fname: ?[]const u8 = null;
                        if (self.peek().kind == .identifier) {
                            fname = self.advance().text;
                            // Duplicate field check
                            for (fields.items) |existing| {
                                if (existing.name) |en| {
                                    if (fname) |fn2| {
                                        if (std.mem.eql(u8, en, fn2)) self.markMalformed(@src());
                                    }
                                }
                            }
                        }
                        var fmut = false;
                        if (self.peek().kind == .r_paren) {
                            // Empty field group: (field) — skip
                            _ = self.advance(); // consume )
                        } else {
                            if (self.peek().kind == .l_paren) {
                                const sp2 = self.lexer.pos;
                                const spk2 = self.peeked;
                                _ = self.advance();
                                if (self.peek().kind == .kw_mut) {
                                    _ = self.advance();
                                    fmut = true;
                                    const rb1 = self.collected_type_refs.items.len;
                                    const si1 = self.in_type_parse; self.in_type_parse = true;
                                    const ftype = self.parseValType() catch .concrete_ref_null;
                                    self.in_type_parse = si1;
                                    const ft1: u32 = if (self.collected_type_refs.items.len > rb1) self.collected_type_refs.items[rb1] else 0xFFFFFFFF;
                                    if (self.peek().kind == .r_paren) _ = self.advance();
                                    fields.append(self.allocator, .{ .name = fname, .@"type" = ftype, .mutable = fmut, .type_idx = ft1 }) catch {};
                                } else {
                                    self.lexer.pos = sp2;
                                    self.peeked = spk2;
                                    const rb2 = self.collected_type_refs.items.len;
                                    const si2 = self.in_type_parse; self.in_type_parse = true;
                                    const ftype = self.parseValType() catch .concrete_ref_null;
                                    self.in_type_parse = si2;
                                    const ft2: u32 = if (self.collected_type_refs.items.len > rb2) self.collected_type_refs.items[rb2] else 0xFFFFFFFF;
                                    fields.append(self.allocator, .{ .name = fname, .@"type" = ftype, .mutable = false, .type_idx = ft2 }) catch {};
                                }
                            } else {
                                const rb3 = self.collected_type_refs.items.len;
                                const si3 = self.in_type_parse; self.in_type_parse = true;
                                const ftype = self.parseValType() catch .concrete_ref_null;
                                self.in_type_parse = si3;
                                const ft3: u32 = if (self.collected_type_refs.items.len > rb3) self.collected_type_refs.items[rb3] else 0xFFFFFFFF;
                                fields.append(self.allocator, .{ .name = fname, .@"type" = ftype, .mutable = false, .type_idx = ft3 }) catch {};
                            }
                            // Handle multiple anonymous fields: (field type type type ...)
                            while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                                const rb4 = self.collected_type_refs.items.len;
                                const si4 = self.in_type_parse; self.in_type_parse = true;
                                const extra_type = self.parseValType() catch break;
                                self.in_type_parse = si4;
                                const ft4: u32 = if (self.collected_type_refs.items.len > rb4) self.collected_type_refs.items[rb4] else 0xFFFFFFFF;
                                fields.append(self.allocator, .{ .@"type" = extra_type, .type_idx = ft4 }) catch {};
                            }
                            if (self.peek().kind == .r_paren) _ = self.advance();
                        }
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        break;
                    }
                }
                // Skip any remaining unparsed struct content
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.skipToRParen();
                    } else {
                        _ = self.advance();
                    }
                }
                try self.expect(.r_paren); // close struct
                if (meta.is_sub) try self.expect(.r_paren);
                try module.module_types.append(self.allocator, .{
                    .struct_type = .{ .fields = fields },
                });
            } else if (std.mem.eql(u8, inner_text, "array")) {
                meta.kind = .array;
                _ = self.advance(); // consume 'array'
                // Parse element type: [mut] <valtype>
                var elem_mut = false;
                if (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_mut) {
                        _ = self.advance();
                        elem_mut = true;
                        const rb = self.collected_type_refs.items.len;
                        const prev_itp = self.in_type_parse;
                        self.in_type_parse = true;
                        defer self.in_type_parse = prev_itp;
                        const elem_type = self.parseValType() catch .concrete_ref_null;
                        const tidx: u32 = if (self.collected_type_refs.items.len > rb) self.collected_type_refs.items[rb] else 0xFFFFFFFF;
                        if (self.peek().kind == .r_paren) _ = self.advance();
                        try self.expect(.r_paren); // close array
                        if (meta.is_sub) try self.expect(.r_paren);
                        try module.module_types.append(self.allocator, .{
                            .array_type = .{ .field = .{ .@"type" = elem_type, .mutable = elem_mut, .type_idx = tidx } },
                        });
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        const rb = self.collected_type_refs.items.len;
                        const prev_itp = self.in_type_parse;
                        self.in_type_parse = true;
                        defer self.in_type_parse = prev_itp;
                        const elem_type = self.parseValType() catch .concrete_ref_null;
                        const tidx: u32 = if (self.collected_type_refs.items.len > rb) self.collected_type_refs.items[rb] else 0xFFFFFFFF;
                        try self.expect(.r_paren); // close array
                        if (meta.is_sub) try self.expect(.r_paren);
                        try module.module_types.append(self.allocator, .{
                            .array_type = .{ .field = .{ .@"type" = elem_type, .mutable = false, .type_idx = tidx } },
                        });
                    }
                } else {
                    const rb = self.collected_type_refs.items.len;
                    const prev_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    defer self.in_type_parse = prev_itp;
                    const elem_type = self.parseValType() catch .concrete_ref_null;
                    const tidx: u32 = if (self.collected_type_refs.items.len > rb) self.collected_type_refs.items[rb] else 0xFFFFFFFF;
                    try self.expect(.r_paren); // close array
                    if (meta.is_sub) try self.expect(.r_paren);
                    try module.module_types.append(self.allocator, .{
                        .array_type = .{ .field = .{ .@"type" = elem_type, .mutable = false, .type_idx = tidx } },
                    });
                }
            } else {
                // Other GC types (sub without inner type, etc.)
                self.scanGcTypeRefs();
                try self.expect(.r_paren);
                if (meta.is_sub) try self.expect(.r_paren);
                try module.module_types.append(self.allocator, .{
                    .func_type = .{},
                });
            }
        }
        // Save collected type refs into the meta
        meta.type_refs = self.collected_type_refs.toOwnedSlice(self.allocator) catch &.{};
        try module.type_meta.append(self.allocator, meta);
    }

    /// Scan a GC composite type body for type reference validation and duplicate field names.
    /// Consumes tokens up to (but not including) the closing ')' of the type form.
    fn scanGcTypeRefs(self: *Parser) void {
        const first = self.advance(); // consume struct/array/sub keyword
        const is_struct = std.mem.eql(u8, first.text, "struct");
        var field_names: [64][]const u8 = undefined;
        var field_count: usize = 0;
        // Scan nested s-expressions for (ref N) patterns
        var depth: u32 = 0;
        while (self.peek().kind != .eof) {
            const tok = self.peek();
            if (tok.kind == .l_paren) {
                _ = self.advance();
                depth += 1;
                // Check for (ref ...) or (ref null ...)
                if (self.peek().kind == .kw_ref or self.peek().kind == .kw_ref_null) {
                    _ = self.advance(); // consume ref/ref_null
                    if (self.peek().kind == .kw_null) _ = self.advance(); // consume null
                    if (self.peek().kind != .r_paren) {
                        const ht = self.advance();
                        if (ht.kind == .integer) {
                            const idx = std.fmt.parseInt(u32, ht.text, 0) catch {
                                self.markMalformed(@src());
                                continue;
                            };
                            if (self.in_rec) {
                                if (idx >= self.rec_end) self.markMalformed(@src());
                            } else {
                                if (self.module) |mod| {
                                    if (idx >= mod.module_types.items.len) self.markMalformed(@src());
                                }
                            }
                        } else if (ht.kind == .identifier) {
                            if (self.type_names.get(ht.text)) |idx| {
                                if (self.in_rec) {
                                    if (idx >= self.rec_end) self.markMalformed(@src());
                                } else {
                                    if (self.module) |mod| {
                                        if (idx >= mod.module_types.items.len) self.markMalformed(@src());
                                    }
                                }
                            }
                        }
                    }
                } else if (is_struct and std.mem.eql(u8, self.peek().text, "field")) {
                    _ = self.advance(); // consume 'field'
                    // Check for named field: (field $name ...)
                    if (self.peek().kind == .identifier) {
                        const fname = self.advance().text;
                        if (field_count < field_names.len) {
                            for (field_names[0..field_count]) |existing| {
                                if (std.mem.eql(u8, fname, existing)) {
                                    self.markMalformed(@src());
                                    break;
                                }
                            }
                            field_names[field_count] = fname;
                            field_count += 1;
                        }
                    }
                }
            } else if (tok.kind == .r_paren) {
                if (depth == 0) break;
                _ = self.advance();
                depth -= 1;
            } else {
                _ = self.advance();
            }
        }
    }

    fn parseRec(self: *Parser, module: *Mod.Module) ParseError!void {
        // (rec (type ...) (type ...) ...)
        // Pre-count types and pre-register names so forward refs resolve.
        const save_pos = self.lexer.pos;
        const save_peeked = self.peeked;
        var rec_count: u32 = 0;
        const rec_start: u32 = @intCast(module.module_types.items.len);
        while (self.peek().kind == .l_paren) {
            _ = self.advance();
            if (self.peek().kind == .kw_type) {
                _ = self.advance(); // consume 'type'
                // Pre-register type name for forward references within rec group
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    self.type_names.put(self.allocator, name, rec_start + rec_count) catch {};
                }
                rec_count += 1;
            }
            self.skipSExpr() catch {};
            if (self.peek().kind == .r_paren) _ = self.advance();
        }
        self.lexer.pos = save_pos;
        self.peeked = save_peeked;

        if (rec_count == 0) {
            try module.empty_rec_group_positions.append(self.allocator, rec_start);
        }

        self.in_rec = true;
        self.rec_end = rec_start + rec_count;
        defer {
            self.in_rec = false;
            self.rec_end = 0;
        }
        var rec_pos: u32 = 0;
        while (self.peek().kind == .l_paren) {
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_type) {
                _ = self.advance(); // consume 'type'
                try self.parseType(module);
                // Stamp the last added type_meta with rec group info
                if (module.type_meta.items.len > 0) {
                    var meta = &module.type_meta.items[module.type_meta.items.len - 1];
                    meta.in_rec_group = true;
                    meta.rec_group = rec_start;
                    meta.rec_group_size = rec_count;
                    meta.rec_position = rec_pos;
                }
                rec_pos += 1;
            } else {
                // A recursion group may be empty, but every member it has
                // must be a type declaration.
                self.markMalformed(@src());
                try self.skipSExpr();
            }
            try self.expect(.r_paren);
        }
    }

    /// Assign canonical rec group IDs using iso-recursive structural comparison.
    /// Types in structurally identical rec groups get the same canonical_group.
    fn canonicalizeTypes(self: *Parser, module: *Mod.Module) void {
        const meta_items = module.type_meta.items;
        // Ensure all types have a rec group assignment (singletons get their own index)
        for (meta_items, 0..) |*meta, i| {
            if (meta.rec_group == std.math.maxInt(u32)) {
                meta.rec_group = @intCast(i);
                meta.rec_group_size = 1;
                meta.rec_position = 0;
            }
        }

        var next_canonical: u32 = 0;
        // Map from canonical key bytes → canonical group ID
        var group_map = std.StringHashMapUnmanaged(u32){};
        defer {
            // Free all stored keys
            var it = group_map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            group_map.deinit(self.allocator);
        }

        var i: u32 = 0;
        while (i < meta_items.len) {
            const group_start = meta_items[i].rec_group;
            const group_size = meta_items[i].rec_group_size;

            // Build canonical key for this rec group
            var key: std.ArrayListUnmanaged(u8) = .empty;
            defer key.deinit(self.allocator);
            self.buildRecGroupKey(&key, module, group_start, group_size);

            // Look up or assign canonical ID
            if (group_map.get(key.items)) |existing_id| {
                for (0..group_size) |pos| {
                    meta_items[group_start + @as(u32, @intCast(pos))].canonical_group = existing_id;
                }
            } else {
                const id = next_canonical;
                next_canonical += 1;
                for (0..group_size) |pos| {
                    meta_items[group_start + @as(u32, @intCast(pos))].canonical_group = id;
                }
                // Store owned copy of key
                const owned_key = self.allocator.alloc(u8, key.items.len) catch {
                    i = group_start + group_size;
                    continue;
                };
                @memcpy(owned_key, key.items);
                group_map.put(self.allocator, owned_key, id) catch {};
            }

            i = group_start + group_size;
        }
    }

    /// Build a canonical byte key for a rec group that captures its full structure.
    fn buildRecGroupKey(self: *Parser, key: *std.ArrayListUnmanaged(u8), module: *Mod.Module, group_start: u32, group_size: u32) void {
        const alloc = self.allocator;
        const meta_items = module.type_meta.items;
        const types_items = module.module_types.items;

        for (0..group_size) |pos| {
            const type_idx = group_start + @as(u32, @intCast(pos));
            if (type_idx >= meta_items.len) break;
            const tmeta = meta_items[type_idx];

            // Kind byte
            key.append(alloc, @intFromEnum(tmeta.kind)) catch {};

            // Finality (part of type identity in the GC spec)
            key.append(alloc, if (tmeta.is_final) @as(u8, 0x01) else @as(u8, 0x00)) catch {};

            // Parent reference (canonicalized)
            if (tmeta.parent == std.math.maxInt(u32)) {
                // No parent
                key.appendSlice(alloc, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }) catch {};
            } else if (tmeta.parent >= group_start and tmeta.parent < group_start + group_size) {
                // Internal parent reference — encode by position within rec group
                key.append(alloc, 0x01) catch {};
                const parent_pos: u32 = tmeta.parent - group_start;
                key.appendSlice(alloc, std.mem.asBytes(&parent_pos)) catch {};
            } else if (tmeta.parent < meta_items.len) {
                // External parent reference — encode by canonical group + position
                key.append(alloc, 0x02) catch {};
                const parent_meta = meta_items[tmeta.parent];
                key.appendSlice(alloc, std.mem.asBytes(&parent_meta.canonical_group)) catch {};
                key.appendSlice(alloc, std.mem.asBytes(&parent_meta.rec_position)) catch {};
            }

            // Structural content
            if (type_idx >= types_items.len) continue;
            switch (types_items[type_idx]) {
                .func_type => |ft| {
                    key.append(alloc, 0x10) catch {};
                    const plen: u32 = @intCast(ft.params.len);
                    key.appendSlice(alloc, std.mem.asBytes(&plen)) catch {};
                    const rlen: u32 = @intCast(ft.results.len);
                    key.appendSlice(alloc, std.mem.asBytes(&rlen)) catch {};
                    // Encode each param/result type with canonicalized type refs
                    var ref_idx: usize = 0;
                    for (ft.params) |p| {
                        ref_idx = appendCanonicalValType(alloc, key, p, tmeta.type_refs, ref_idx, meta_items, group_start, group_size);
                    }
                    for (ft.results) |r| {
                        ref_idx = appendCanonicalValType(alloc, key, r, tmeta.type_refs, ref_idx, meta_items, group_start, group_size);
                    }
                },
                .struct_type => |st| {
                    key.append(alloc, 0x20) catch {};
                    const flen: u32 = @intCast(st.fields.items.len);
                    key.appendSlice(alloc, std.mem.asBytes(&flen)) catch {};
                    var ref_idx: usize = 0;
                    for (st.fields.items) |field| {
                        key.append(alloc, if (field.mutable) @as(u8, 0x01) else @as(u8, 0x00)) catch {};
                        ref_idx = appendCanonicalValType(alloc, key, field.@"type", tmeta.type_refs, ref_idx, meta_items, group_start, group_size);
                    }
                },
                .array_type => |at| {
                    key.append(alloc, 0x30) catch {};
                    key.append(alloc, if (at.field.mutable) @as(u8, 0x01) else @as(u8, 0x00)) catch {};
                    _ = appendCanonicalValType(alloc, key, at.field.@"type", tmeta.type_refs, 0, meta_items, group_start, group_size);
                },
            }
        }
    }

    /// Append a canonicalized ValType to the key buffer. For concrete type refs,
    /// uses the type_refs to resolve the index and canonicalize as internal/external reference.
    fn appendCanonicalValType(
        alloc: std.mem.Allocator,
        key: *std.ArrayListUnmanaged(u8),
        vt: types.ValType,
        type_refs: []const u32,
        ref_idx: usize,
        meta_items: []const Mod.TypeMeta,
        group_start: u32,
        group_size: u32,
    ) usize {
        if ((vt == .concrete_ref or vt == .concrete_ref_null) and ref_idx < type_refs.len) {
            const target_idx = type_refs[ref_idx];
            key.append(alloc, if (vt == .concrete_ref) @as(u8, 0xA0) else @as(u8, 0xA1)) catch {};
            if (target_idx >= group_start and target_idx < group_start + group_size) {
                // Internal reference — encode by position within rec group
                key.append(alloc, 0x01) catch {};
                const target_pos: u32 = target_idx - group_start;
                key.appendSlice(alloc, std.mem.asBytes(&target_pos)) catch {};
            } else if (target_idx < meta_items.len) {
                // External reference — encode by canonical group + position
                key.append(alloc, 0x02) catch {};
                const target_meta = meta_items[target_idx];
                key.appendSlice(alloc, std.mem.asBytes(&target_meta.canonical_group)) catch {};
                key.appendSlice(alloc, std.mem.asBytes(&target_meta.rec_position)) catch {};
            }
            return ref_idx + 1;
        }
        // Non-reference type — encode the ValType directly
        const val: i32 = @intFromEnum(vt);
        key.appendSlice(alloc, std.mem.asBytes(&val)) catch {};
        return ref_idx;
    }

    fn parseFunc(self: *Parser, module: *Mod.Module) ParseError!void {
        var func = Mod.Func{};
        const func_idx: u32 = @intCast(module.funcs.items.len);
        // Clear per-function local name map
        self.local_names.clearRetainingCapacity();
        self.label_stack.clearRetainingCapacity();
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            func.name = self.advance().text;
            if (func.name) |n| self.checkEmptyId(n);
            // Register name → index for call resolution
            if (func.name) |n| {
                const norm = normalizeIdentifier(self.allocator, n);
                if (self.func_names.get(norm)) |existing| {
                    if (existing != func_idx and existing < func_idx) self.markMalformed(@src());
                }
                self.func_names.put(self.allocator, norm, func_idx) catch {};
            }
        }

        // Handle inline (export "name") and (import "mod" "name") declarations
        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                self.skipAnnotations();
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                self.skipAnnotations();
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .func,
                    .var_ = .{ .index = func_idx },
                }) catch return error.OutOfMemory;
                self.skipAnnotations();
            } else if (self.peek().kind == .kw_import) {
                _ = self.advance(); // consume 'import'
                self.skipAnnotations();
                const mod_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                const field_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                try self.expect(.r_paren); // close (import ...)

                // Parse optional (type $idx) and inline sig
                var type_index: types.Index = 0;
                var has_explicit_type2 = false;
                var params_list: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer params_list.deinit(self.allocator);
                var results_list: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer results_list.deinit(self.allocator);
                var param_tidxs_list2: std.ArrayListUnmanaged(u32) = .empty;
                defer param_tidxs_list2.deinit(self.allocator);
                var result_tidxs_list2: std.ArrayListUnmanaged(u32) = .empty;
                defer result_tidxs_list2.deinit(self.allocator);

                self.skipAnnotations();
                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    self.skipAnnotations();
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        type_index = self.parseTypeIdx() catch 0;
                        has_explicit_type2 = true;
                        self.skipAnnotations();
                        try self.expect(.r_paren);
                        self.skipAnnotations();
                    } else if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        self.skipAnnotations();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        self.skipAnnotations();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const refs_before = self.collected_type_refs.items.len;
                            const saved_itp = self.in_type_parse;
                            self.in_type_parse = true;
                            const vt = self.parseValType() catch break;
                            self.in_type_parse = saved_itp;
                            params_list.append(self.allocator, vt) catch {};
                            param_tidxs_list2.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            self.skipAnnotations();
                        }
                        try self.expect(.r_paren);
                        self.skipAnnotations();
                    } else if (self.peek().kind == .kw_result) {
                        _ = self.advance();
                        self.skipAnnotations();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const refs_before = self.collected_type_refs.items.len;
                            const saved_itp = self.in_type_parse;
                            self.in_type_parse = true;
                            const vt = self.parseValType() catch break;
                            self.in_type_parse = saved_itp;
                            results_list.append(self.allocator, vt) catch {};
                            result_tidxs_list2.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            self.skipAnnotations();
                        }
                        try self.expect(.r_paren);
                        self.skipAnnotations();
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        break;
                    }
                }

                // Register as import
                func.is_import = true;
                func.decl.type_var = .{ .index = type_index };

                // Build func type if inline sig provided (no explicit type ref)
                if (!has_explicit_type2) {
                    const params = params_list.toOwnedSlice(self.allocator) catch &.{};
                    const results = results_list.toOwnedSlice(self.allocator) catch &.{};
                    const pt = param_tidxs_list2.toOwnedSlice(self.allocator) catch &.{};
                    const rt = result_tidxs_list2.toOwnedSlice(self.allocator) catch &.{};
                    type_index = @intCast(module.module_types.items.len);
                    module.module_types.append(self.allocator, .{
                        .func_type = .{ .params = params, .results = results, .param_type_idxs = pt, .result_type_idxs = rt },
                    }) catch {};
                    func.decl.type_var = .{ .index = type_index };
                }

                try module.funcs.append(self.allocator, func);
                module.num_func_imports += 1;
                var import = Mod.Import{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .func,
                };
                import.func = .{ .type_var = .{ .index = type_index } };
                try module.imports.append(self.allocator, import);
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        // Check for (type $idx)
        self.skipAnnotations();
        if (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_type) {
                _ = self.advance();
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx = self.type_names.get(name) orelse 0;
                    func.decl.type_var = .{ .index = idx };
                } else {
                    const idx = try self.parseU32();
                    func.decl.type_var = .{ .index = idx };
                }
                try self.expect(.r_paren);
            } else {
                // Not (type ...) — restore
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
            }
        }

        // Parse inline (param ...) and (result ...) to build a signature
        var params_list: std.ArrayListUnmanaged(types.ValType) = .empty;
        defer params_list.deinit(self.allocator);
        var param_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
        defer param_tidxs_list.deinit(self.allocator);
        var results_list: std.ArrayListUnmanaged(types.ValType) = .empty;
        defer results_list.deinit(self.allocator);
        var result_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
        defer result_tidxs_list.deinit(self.allocator);

        var seen_results = false;

        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            const inner = self.peek().kind;
            if (inner == .kw_param) {
                if (seen_results) self.markMalformed(@src());
                _ = self.advance(); // consume 'param'
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx: u32 = @intCast(params_list.items.len);
                    if (self.local_names.get(name) != null) {
                        self.markMalformed(@src());
                    }
                    self.local_names.put(self.allocator, name, idx) catch {};
                }
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    const vt = self.parseValType() catch { self.in_type_parse = saved_itp; break; };
                    self.in_type_parse = saved_itp;
                    params_list.append(self.allocator, vt) catch return error.OutOfMemory;
                    param_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                    self.skipAnnotations();
                }
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else if (inner == .kw_result) {
                seen_results = true;
                _ = self.advance(); // consume 'result'
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    const vt = self.parseValType() catch { self.in_type_parse = saved_itp; break; };
                    self.in_type_parse = saved_itp;
                    results_list.append(self.allocator, vt) catch return error.OutOfMemory;
                    result_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                    self.skipAnnotations();
                }
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else if (inner == .kw_type) {
                // (type ...) after (param/result ...) is malformed
                if (params_list.items.len > 0 or results_list.items.len > 0) {
                    self.markMalformed(@src());
                }
                try self.skipSExpr();
                try self.expect(.r_paren);
            } else {
                // Not param/result — restore and stop parsing sig
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                break;
            }
        }

        // If (type $sig) is given with inline params/results, validate they match exactly
        const has_type_ref = func.decl.type_var == .index and func.decl.type_var.index != types.invalid_index;
        if (has_type_ref and (params_list.items.len > 0 or results_list.items.len > 0)) {
            const tidx = func.decl.type_var.index;
            if (tidx < module.module_types.items.len) {
                switch (module.module_types.items[tidx]) {
                    .func_type => |ft| {
                        if (ft.params.len != params_list.items.len or ft.results.len != results_list.items.len) {
                            self.markMalformed(@src());
                        } else {
                            // The concrete type index is part of the type: an
                            // inline `(ref $b)` does not match a referenced
                            // `(ref $a)` even though both are the same
                            // `ValType`.
                            for (ft.params, params_list.items, 0..) |a, b, k| {
                                if (a != b) self.markMalformed(@src());
                                if (Mod.FuncSignature.concreteIdxAt(ft.param_type_idxs, k) !=
                                    Mod.FuncSignature.concreteIdxAt(param_tidxs_list.items, k)) self.markMalformed(@src());
                            }
                            for (ft.results, results_list.items, 0..) |a, b, k| {
                                if (a != b) self.markMalformed(@src());
                                if (Mod.FuncSignature.concreteIdxAt(ft.result_type_idxs, k) !=
                                    Mod.FuncSignature.concreteIdxAt(result_tidxs_list.items, k)) self.markMalformed(@src());
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // If we found inline params/results and no (type $idx), create a type entry
        if (!has_type_ref) {
            if (params_list.items.len > 0 or results_list.items.len > 0) {
                const p = self.allocator.alloc(types.ValType, params_list.items.len) catch return error.OutOfMemory;
                @memcpy(p, params_list.items);
                const pt = self.allocator.alloc(u32, param_tidxs_list.items.len) catch return error.OutOfMemory;
                @memcpy(pt, param_tidxs_list.items);
                const r = self.allocator.alloc(types.ValType, results_list.items.len) catch return error.OutOfMemory;
                @memcpy(r, results_list.items);
                const rt = self.allocator.alloc(u32, result_tidxs_list.items.len) catch return error.OutOfMemory;
                @memcpy(rt, result_tidxs_list.items);
                const new_sig = Mod.FuncSignature{ .params = p, .results = r, .param_type_idxs = pt, .result_type_idxs = rt };
                // Deduplicate: reuse existing type if signature matches
                const type_idx = blk: {
                    for (module.module_types.items, 0..) |entry, idx| {
                        switch (entry) {
                            .func_type => |ft| if (ft.eql(new_sig)) {
                                self.allocator.free(p);
                                self.allocator.free(r);
                                if (pt.len > 0) self.allocator.free(pt);
                                if (rt.len > 0) self.allocator.free(rt);
                                break :blk idx;
                            },
                            else => {},
                        }
                    }
                    module.module_types.append(self.allocator, .{
                        .func_type = new_sig,
                    }) catch return error.OutOfMemory;
                    break :blk module.module_types.items.len - 1;
                };
                func.decl.type_var = .{ .index = @intCast(type_idx) };
            } else {
                // Empty func with no type — deduplicate void->void type
                const empty_sig = Mod.FuncSignature{};
                const type_idx = blk: {
                    for (module.module_types.items, 0..) |entry, idx| {
                        switch (entry) {
                            .func_type => |ft| if (ft.eql(empty_sig)) break :blk idx,
                            else => {},
                        }
                    }
                    module.module_types.append(self.allocator, .{
                        .func_type = .{},
                    }) catch return error.OutOfMemory;
                    break :blk module.module_types.items.len - 1;
                };
                func.decl.type_var = .{ .index = @intCast(type_idx) };
            }
        }

        // Parse (local ...) declarations
        // When computing local indices, use the actual param count from the type
        // (params_list may be empty if the function uses (type $sig) instead of inline params)
        const actual_param_count: u32 = blk: {
            if (params_list.items.len > 0) break :blk @intCast(params_list.items.len);
            // Look up param count from referenced type
            if (func.decl.type_var == .index and func.decl.type_var.index != types.invalid_index) {
                const tidx = func.decl.type_var.index;
                if (tidx < module.module_types.items.len) {
                    switch (module.module_types.items[tidx]) {
                        .func_type => |ft| break :blk @intCast(ft.params.len),
                        else => {},
                    }
                }
            }
            break :blk 0;
        };
        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_local) {
                _ = self.advance(); // consume 'local'
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx: u32 = actual_param_count + @as(u32, @intCast(func.local_types.items.len));
                    if (self.local_names.get(name) != null) {
                        self.markMalformed(@src());
                    }
                    self.local_names.put(self.allocator, name, idx) catch {};
                }
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    const vt = self.parseValType() catch { self.in_type_parse = saved_itp; break; };
                    self.in_type_parse = saved_itp;
                    func.local_types.append(self.allocator, vt) catch return error.OutOfMemory;
                    func.local_type_idxs.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                    self.skipAnnotations();
                }
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else {
                // Not local — restore and stop
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                break;
            }
        }

        // Pre-scan: check for misplaced (param ...) or (result ...) in function body.
        // These must appear before any instructions, not after.
        // Exception: (result ...) after select is a typed select annotation.
        // Also check for (param ...) after (local ...).
        {
            var scan = Lexer.init(self.lexer.source);
            scan.pos = if (self.peeked) |pk| pk.offset else self.lexer.pos;
            var saw_instr = false;
            var saw_local = func.local_types.items.len > 0;
            var last_was_select = false;
            var depth: u32 = 0;
            var block_depth: u32 = 0; // Track flat block/loop/if/end nesting
            scan_loop: while (true) {
                const stok = scan.next();
                switch (stok.kind) {
                    .eof => break,
                    .l_paren => {
                        if (depth == 0 and block_depth == 0) {
                            const inner = scan.next();
                            if (inner.kind == .kw_param) {
                                if (saw_instr or saw_local) {
                                    if (!last_was_select) { self.markMalformed(@src()); break :scan_loop; }
                                }
                            } else if (inner.kind == .kw_result) {
                                if (saw_instr and !last_was_select) { self.markMalformed(@src()); break :scan_loop; }
                            } else if (inner.kind == .kw_local) {
                                saw_local = true;
                                last_was_select = false;
                            } else if (inner.kind == .kw_type) {
                                // (type ...) after call_indirect/select — keep last_was_select
                            } else {
                                saw_instr = true;
                                last_was_select = false;
                            }
                        }
                        depth += 1;
                    },
                    .r_paren => {
                        if (depth == 0) break;
                        depth -= 1;
                    },
                    else => {
                        if (depth == 0) {
                            // Track flat block nesting
                            if (stok.kind == .kw_block or stok.kind == .kw_loop or stok.kind == .kw_if or stok.kind == .kw_try_table) {
                                block_depth += 1;
                            } else if (stok.kind == .kw_end and block_depth > 0) {
                                block_depth -= 1;
                            }
                            if (block_depth == 0) {
                                last_was_select = stok.kind == .kw_select or stok.kind == .kw_call_indirect or stok.kind == .kw_return_call_indirect;
                                saw_instr = true;
                            }
                        }
                    },
                }
            }
        }

        // Parse function body instructions → emit bytecode
        var code: std.ArrayListUnmanaged(u8) = .empty;
        defer code.deinit(self.allocator);
        self.parseFuncBodyInstrs(&code);
        // Emit final end
        code.append(self.allocator, 0x0b) catch {};

        const owned = code.toOwnedSlice(self.allocator) catch &.{};
        func.code_bytes = owned;
        func.owns_code_bytes = true;

        try module.funcs.append(self.allocator, func);
    }

    fn parseFuncBodyInstrs(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
            self.skipAnnotations();
            if (self.peek().kind == .r_paren or self.peek().kind == .eof) break;
            if (self.peek().kind == .l_paren) {
                _ = self.advance(); // consume '('
                self.skipAnnotations();
                self.parseFoldedInstr(code);
            } else {
                self.parsePlainInstr(code);
            }
        }
    }

    fn parseFoldedInstr(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.peek();
        switch (tok.kind) {
            .kw_block => {
                _ = self.advance();
                self.skipAnnotations();
                code.append(self.allocator, 0x02) catch return;
                const label = self.consumeOptionalLabel();
                self.label_stack.append(self.allocator, label) catch {};
                self.skipAnnotations();
                self.emitBlockType(code);
                self.parseFuncBodyInstrs(code);
                code.append(self.allocator, 0x0b) catch return; // end
                if (self.label_stack.items.len > 0) _ = self.label_stack.pop();
                self.skipToRParen();
            },
            .kw_loop => {
                _ = self.advance();
                code.append(self.allocator, 0x03) catch return;
                const label = self.consumeOptionalLabel();
                self.label_stack.append(self.allocator, label) catch {};
                self.emitBlockType(code);
                self.parseFuncBodyInstrs(code);
                code.append(self.allocator, 0x0b) catch return; // end
                if (self.label_stack.items.len > 0) _ = self.label_stack.pop();
                self.skipToRParen();
            },
            .kw_try_table => {
                _ = self.advance();
                code.append(self.allocator, 0x1f) catch return;
                const label = self.consumeOptionalLabel();
                self.emitBlockType(code);
                // Parse catch clauses. `try_table`'s own label is deliberately
                // not on the stack yet: a clause's label index is resolved in
                // the context surrounding the instruction, so
                // `(block $l (try_table (catch_all $l) ...))` is depth 0.
                // Pushing first shifted every catch label by one.
                var clause_count: u32 = 0;
                var catch_bytes = std.ArrayListUnmanaged(u8).empty;
                defer catch_bytes.deinit(self.allocator);
                while (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance();
                    const ck = self.peek().kind;
                    if (ck == .kw_catch or ck == .kw_catch_ref or ck == .kw_catch_all or ck == .kw_catch_all_ref) {
                        const catch_kind = self.advance().kind;
                        const cc: u8 = switch (catch_kind) {
                            .kw_catch => 0x00, .kw_catch_ref => 0x01,
                            .kw_catch_all => 0x02, .kw_catch_all_ref => 0x03,
                            else => 0x00,
                        };
                        catch_bytes.append(self.allocator, cc) catch {};
                        if (cc <= 0x01) {
                            var tag_idx: u32 = 0;
                            if (self.peek().kind == .identifier) {
                                tag_idx = self.tag_names.get(self.advance().text) orelse 0;
                            } else { tag_idx = self.parseU32() catch 0; }
                            var buf: [5]u8 = undefined;
                            const n = leb128.writeU32Leb128(&buf, tag_idx);
                            catch_bytes.appendSlice(self.allocator, buf[0..n]) catch {};
                        }
                        var depth: u32 = 0;
                        if (self.peek().kind == .identifier) {
                            depth = self.resolveLabelDepth(self.advance().text) orelse 0;
                        } else { depth = self.parseU32() catch 0; }
                        var buf: [5]u8 = undefined;
                        const n = leb128.writeU32Leb128(&buf, depth);
                        catch_bytes.appendSlice(self.allocator, buf[0..n]) catch {};
                        clause_count += 1;
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        break;
                    }
                }
                // The body *is* inside the new label scope, so push now.
                self.label_stack.append(self.allocator, label) catch {};
                var cnt_buf: [5]u8 = undefined;
                const cn = leb128.writeU32Leb128(&cnt_buf, clause_count);
                code.appendSlice(self.allocator, cnt_buf[0..cn]) catch {};
                code.appendSlice(self.allocator, catch_bytes.items) catch {};
                self.parseFuncBodyInstrs(code);
                code.append(self.allocator, 0x0b) catch return; // end
                if (self.label_stack.items.len > 0) _ = self.label_stack.pop();
                self.skipToRParen();
            },
            .kw_if => {
                _ = self.advance();
                const label = self.consumeOptionalLabel();
                // Parse block type
                var block_type_buf: [6]u8 = undefined;
                const bt_len = self.readBlockType(&block_type_buf, false);

                // Check for (then ...) and (else ...) sub-expressions
                // First parse condition operands (before then)
                var has_then = false;
                while (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance(); // consume '('
                    if (self.peek().kind == .kw_then) {
                        has_then = true;
                        break;
                    } else {
                        // Condition operand — parse as folded instruction
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        _ = self.advance(); // re-consume '('
                        self.parseFoldedInstr(code);
                    }
                }

                // Now emit the if opcode
                code.append(self.allocator, 0x04) catch return;
                code.appendSlice(self.allocator, block_type_buf[0..bt_len]) catch return;
                self.label_stack.append(self.allocator, label) catch {};

                if (has_then) {
                    _ = self.advance(); // consume 'then'
                    self.parseFuncBodyInstrs(code);
                    self.skipToRParen(); // close (then ...)
                }
                // Check for (else ...)
                if (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_else) {
                        _ = self.advance();
                        code.append(self.allocator, 0x05) catch return; // else
                        self.parseFuncBodyInstrs(code);
                        self.skipToRParen(); // close (else ...)
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                    }
                }
                code.append(self.allocator, 0x0b) catch return; // end
                if (self.label_stack.items.len > 0) _ = self.label_stack.pop();
                self.skipToRParen(); // close (if ...)
            },
            else => {
                // Generic folded instruction: (instr operands...)
                // Emit instruction bytes first, then operands, then rotate so
                // operands precede the instruction in the final bytecode.
                const instr_start = code.items.len;
                self.parsePlainInstr(code);
                const instr_end = code.items.len;
                const instr_len = instr_end - instr_start;

                // Now parse operand sub-expressions (they emit AFTER the instruction in the buffer)
                var has_operands = false;
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    self.skipAnnotations();
                    if (self.peek().kind == .r_paren or self.peek().kind == .eof) break;
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.skipAnnotations();
                        self.parseFoldedInstr(code);
                        has_operands = true;
                    } else {
                        // Could be additional immediates — skip them
                        if (self.peek().kind == .invalid) self.markMalformed(@src());
                        _ = self.advance();
                    }
                }

                // Reorder: [instr][operands] → [operands][instr]
                // In a stack machine, operands must be pushed before the
                // instruction that consumes them.
                if (has_operands and instr_len > 0) {
                    if (instr_len <= 32) {
                        var buf: [32]u8 = undefined;
                        @memcpy(buf[0..instr_len], code.items[instr_start..instr_end]);
                        const total = code.items.len;
                        const operand_len = total - instr_end;
                        std.mem.copyForwards(u8, code.items[instr_start .. instr_start + operand_len], code.items[instr_end..total]);
                        @memcpy(code.items[instr_start + operand_len .. instr_start + operand_len + instr_len], buf[0..instr_len]);
                    } else {
                        // Large instruction (e.g. br_table with many targets) — use heap
                        const heap_buf = self.allocator.alloc(u8, instr_len) catch return;
                        defer self.allocator.free(heap_buf);
                        @memcpy(heap_buf, code.items[instr_start..instr_end]);
                        const total = code.items.len;
                        const operand_len = total - instr_end;
                        std.mem.copyForwards(u8, code.items[instr_start .. instr_start + operand_len], code.items[instr_end..total]);
                        @memcpy(code.items[instr_start + operand_len .. instr_start + operand_len + instr_len], heap_buf);
                    }
                }

                self.skipToRParen();
            },
        }
    }

    fn parsePlainInstr(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        switch (tok.kind) {
            .kw_unreachable => code.append(self.allocator, 0x00) catch return,
            .kw_nop => code.append(self.allocator, 0x01) catch return,
            .kw_block => {
                code.append(self.allocator, 0x02) catch return;
                const label = self.consumeOptionalLabel();
                self.label_stack.append(self.allocator, label) catch {};
                self.emitBlockType(code);
            },
            .kw_loop => {
                code.append(self.allocator, 0x03) catch return;
                const label = self.consumeOptionalLabel();
                self.label_stack.append(self.allocator, label) catch {};
                self.emitBlockType(code);
            },
            .kw_if => {
                code.append(self.allocator, 0x04) catch return;
                const label = self.consumeOptionalLabel();
                self.label_stack.append(self.allocator, label) catch {};
                self.emitBlockType(code);
            },
            .kw_else => {
                code.append(self.allocator, 0x05) catch return;
                // Validate optional else label matches the opening if label
                if (self.peek().kind == .identifier) {
                    const el_label_raw = self.advance().text;
                    const el_label = normalizeIdentifier(self.allocator, el_label_raw);
                    if (self.label_stack.items.len > 0) {
                        const opening = self.label_stack.items[self.label_stack.items.len - 1];
                        if (opening == null or !std.mem.eql(u8, opening.?, el_label)) {
                            self.markMalformed(@src());
                            return;
                        }
                    } else {
                        self.markMalformed(@src());
                        return;
                    }
                }
            },
            .kw_end => {
                code.append(self.allocator, 0x0b) catch return;
                // Validate optional end label matches the opening block/loop/if label
                if (self.peek().kind == .identifier) {
                    const en_label_raw = self.advance().text;
                    const en_label = normalizeIdentifier(self.allocator, en_label_raw);
                    if (self.label_stack.items.len > 0) {
                        const opening = self.label_stack.items[self.label_stack.items.len - 1];
                        if (opening == null or !std.mem.eql(u8, opening.?, en_label)) {
                            self.markMalformed(@src());
                            return;
                        }
                    } else {
                        self.markMalformed(@src());
                        return;
                    }
                }
                if (self.label_stack.items.len > 0) _ = self.label_stack.pop();
            },
            .kw_br => {
                code.append(self.allocator, 0x0c) catch return;
                self.emitU32Imm(code);
            },
            .kw_br_if => {
                code.append(self.allocator, 0x0d) catch return;
                self.emitU32Imm(code);
            },
            .kw_br_table => {
                code.append(self.allocator, 0x0e) catch return;
                // Collect all targets (integer depths or $label identifiers)
                var targets: std.ArrayListUnmanaged(u32) = .empty;
                defer targets.deinit(self.allocator);
                while (self.peek().kind == .integer or self.peek().kind == .identifier) {
                    if (self.peek().kind == .integer) {
                        const idx = self.parseU32() catch break;
                        targets.append(self.allocator, idx) catch return;
                    } else {
                        const label_tok = self.advance();
                        const depth = self.resolveLabelDepth(label_tok.text) orelse blk: {
                            self.markMalformed(@src());
                            break :blk 0;
                        };
                        targets.append(self.allocator, depth) catch return;
                    }
                }
                if (targets.items.len == 0) {
                    // Malformed, emit 0 targets with default 0
                    self.emitLeb128U32(code, 0);
                    self.emitLeb128U32(code, 0);
                } else {
                    // Last target is the default
                    self.emitLeb128U32(code, @intCast(targets.items.len - 1));
                    for (targets.items) |t| self.emitLeb128U32(code, t);
                }
            },
            .kw_return => code.append(self.allocator, 0x0f) catch return,
            .kw_br_on_null => {
                code.append(self.allocator, 0xd5) catch return;
                self.emitU32Imm(code);
            },
            .kw_br_on_non_null => {
                code.append(self.allocator, 0xd6) catch return;
                self.emitU32Imm(code);
            },
            .kw_br_on_cast, .kw_br_on_cast_fail => {
                code.append(self.allocator, 0xfb) catch return;
                const sub: u32 = if (tok.kind == .kw_br_on_cast) 0x18 else 0x19;
                var buf_sub: [5]u8 = undefined;
                const n_sub = leb128.writeU32Leb128(&buf_sub, sub);
                code.appendSlice(self.allocator, buf_sub[0..n_sub]) catch return;
                // br_on_cast/br_on_cast_fail: castflags label rt1 rt2
                // castflags: 1 byte (bit 0 = src nullable, bit 1 = dst nullable)
                var cast_flags: u8 = 0;
                // Parse (ref [null] ht1) (ref [null] ht2) label
                // Actually format is: label (ref [null] ht1) (ref [null] ht2)
                self.emitU32Imm(code); // label depth
                // Parse source ref type
                if (self.peek().kind == .l_paren) {
                    _ = self.advance();
                    if (self.peek().kind == .kw_ref) {
                        _ = self.advance();
                        if (self.peek().kind == .kw_null) {
                            _ = self.advance();
                            cast_flags |= 1;
                        }
                        if (self.peek().kind != .r_paren and self.peek().kind != .eof)
                            _ = self.advance(); // heap type
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else {
                        // bare type keyword
                        const vt = self.peek();
                        if (vt.kind == .kw_funcref or vt.kind == .kw_anyref or
                            vt.kind == .kw_externref or vt.kind == .kw_eqref or
                            vt.kind == .kw_i31ref or vt.kind == .kw_structref or
                            vt.kind == .kw_arrayref or vt.kind == .kw_exnref)
                        {
                            cast_flags |= 1; // bare ref types are nullable
                            _ = self.advance();
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    }
                } else if (self.peek().kind == .kw_funcref or self.peek().kind == .kw_anyref or
                    self.peek().kind == .kw_externref or self.peek().kind == .kw_eqref or
                    self.peek().kind == .kw_i31ref or self.peek().kind == .kw_exnref or
                    self.peek().kind == .kw_structref or self.peek().kind == .kw_arrayref or
                    self.peek().kind == .kw_nullref or self.peek().kind == .kw_nullfuncref or
                    self.peek().kind == .kw_nullexternref or self.peek().kind == .kw_nullexnref)
                {
                    cast_flags |= 1;
                    _ = self.advance();
                }
                // Parse target ref type
                var target_heap: i32 = -0x10; // default: func
                if (self.peek().kind == .l_paren) {
                    _ = self.advance();
                    if (self.peek().kind == .kw_ref) {
                        _ = self.advance();
                        if (self.peek().kind == .kw_null) {
                            _ = self.advance();
                            cast_flags |= 2;
                        }
                        if (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const ht_tok = self.advance();
                            if (std.mem.eql(u8, ht_tok.text, "i31")) { target_heap = 0x6c; }
                            else if (std.mem.eql(u8, ht_tok.text, "eq")) { target_heap = 0x6d; }
                            else if (std.mem.eql(u8, ht_tok.text, "any")) { target_heap = 0x6e; }
                            else if (std.mem.eql(u8, ht_tok.text, "func")) { target_heap = 0x70; }
                            else if (std.mem.eql(u8, ht_tok.text, "extern")) { target_heap = 0x6f; }
                            else if (std.mem.eql(u8, ht_tok.text, "struct")) { target_heap = 0x6b; }
                            else if (std.mem.eql(u8, ht_tok.text, "array")) { target_heap = 0x6a; }
                            else if (std.mem.eql(u8, ht_tok.text, "none")) { target_heap = 0x71; }
                            else if (std.mem.eql(u8, ht_tok.text, "nofunc")) { target_heap = 0x73; }
                            else if (std.mem.eql(u8, ht_tok.text, "noextern")) { target_heap = 0x72; }
                            else if (ht_tok.kind == .identifier) {
                                target_heap = @intCast(self.type_names.get(ht_tok.text) orelse 0);
                            } else if (ht_tok.kind == .integer) {
                                target_heap = @intCast(std.fmt.parseInt(u32, ht_tok.text, 0) catch 0);
                            }
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else {
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    }
                } else if (self.peek().kind == .kw_i31ref) {
                    cast_flags |= 2;
                    target_heap = 0x6c;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_eqref) {
                    cast_flags |= 2;
                    target_heap = 0x6d;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_structref) {
                    cast_flags |= 2;
                    target_heap = 0x6b;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_arrayref) {
                    cast_flags |= 2;
                    target_heap = 0x6a;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_funcref) {
                    cast_flags |= 2;
                    target_heap = 0x70;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_anyref) {
                    cast_flags |= 2;
                    target_heap = 0x6e;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_externref) {
                    cast_flags |= 2;
                    target_heap = 0x6f;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_nullref) {
                    cast_flags |= 2;
                    target_heap = 0x71;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_nullfuncref) {
                    cast_flags |= 2;
                    target_heap = 0x73;
                    _ = self.advance();
                } else if (self.peek().kind == .kw_nullexternref) {
                    cast_flags |= 2;
                    target_heap = 0x72;
                    _ = self.advance();
                }
                // Emit: castflags (1 byte), then encode source/target heap types
                code.append(self.allocator, cast_flags) catch return;
                self.emitLeb128S32(code, target_heap);
            },
            .kw_throw => {
                code.append(self.allocator, 0x08) catch return;
                // throw $tag_idx
                if (self.peek().kind == .identifier) {
                    const tag_tok = self.advance();
                    const idx = self.tag_names.get(tag_tok.text) orelse 0;
                    self.emitLeb128U32(code, idx);
                } else {
                    self.emitU32Imm(code);
                }
            },
            .kw_throw_ref => code.append(self.allocator, 0x0a) catch return,
            .kw_call_ref => {
                code.append(self.allocator, 0x14) catch return;
                // call_ref $type — type index
                if (self.peek().kind == .identifier) {
                    const type_tok = self.advance();
                    const idx = self.type_names.get(type_tok.text) orelse 0;
                    self.emitLeb128U32(code, idx);
                } else {
                    self.emitU32Imm(code);
                }
            },
            .kw_return_call_ref => {
                code.append(self.allocator, 0x15) catch return;
                if (self.peek().kind == .identifier) {
                    const type_tok = self.advance();
                    const idx = self.type_names.get(type_tok.text) orelse 0;
                    self.emitLeb128U32(code, idx);
                } else {
                    self.emitU32Imm(code);
                }
            },
            .kw_try_table => {
                code.append(self.allocator, 0x1f) catch return;
                // Parse optional label
                const label = if (self.peek().kind == .identifier) self.advance().text else null;
                self.emitBlockType(code);
                // Parse catch clauses, building a byte buffer. `try_table`'s
                // own label is pushed only afterwards -- see the folded form
                // above; a clause's label is resolved in the enclosing
                // context, so pushing first shifted every one of them by one.
                var clause_count: u32 = 0;
                var catch_bytes = std.ArrayListUnmanaged(u8).empty;
                defer catch_bytes.deinit(self.allocator);
                while (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance();
                    const ck = self.peek().kind;
                    if (ck == .kw_catch or ck == .kw_catch_ref or ck == .kw_catch_all or ck == .kw_catch_all_ref) {
                        const catch_kind = self.advance().kind;
                        const catch_code: u8 = switch (catch_kind) {
                            .kw_catch => 0x00,
                            .kw_catch_ref => 0x01,
                            .kw_catch_all => 0x02,
                            .kw_catch_all_ref => 0x03,
                            else => 0x00,
                        };
                        catch_bytes.append(self.allocator, catch_code) catch {};
                        // catch/catch_ref have a tag index
                        if (catch_code <= 0x01) {
                            var tag_idx: u32 = 0;
                            if (self.peek().kind == .identifier) {
                                const tag_tok = self.advance();
                                tag_idx = self.tag_names.get(tag_tok.text) orelse 0;
                            } else {
                                tag_idx = self.parseU32() catch 0;
                            }
                            var buf: [5]u8 = undefined;
                            const n = leb128.writeU32Leb128(&buf, tag_idx);
                            catch_bytes.appendSlice(self.allocator, buf[0..n]) catch {};
                        }
                        // Label (branch depth)
                        var depth: u32 = 0;
                        if (self.peek().kind == .identifier) {
                            const lbl = self.advance();
                            depth = self.resolveLabelDepth(lbl.text) orelse 0;
                        } else {
                            depth = self.parseU32() catch 0;
                        }
                        var buf: [5]u8 = undefined;
                        const n = leb128.writeU32Leb128(&buf, depth);
                        catch_bytes.appendSlice(self.allocator, buf[0..n]) catch {};
                        clause_count += 1;
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        break;
                    }
                }
                // The body *is* inside the new label scope, so push now.
                self.label_stack.append(self.allocator, label) catch {};
                // Emit: clause_count + catch clause bytes
                var cnt_buf: [5]u8 = undefined;
                const cn = leb128.writeU32Leb128(&cnt_buf, clause_count);
                code.appendSlice(self.allocator, cnt_buf[0..cn]) catch {};
                code.appendSlice(self.allocator, catch_bytes.items) catch {};
                // Instructions inside try_table are parsed by the normal loop; end (0x0b) closes it
            },
            .kw_call => {
                code.append(self.allocator, 0x10) catch return;
                self.emitU32Imm(code);
            },
            .kw_return_call => {
                code.append(self.allocator, 0x12) catch return;
                self.emitU32Imm(code);
            },
            .kw_call_indirect => {
                code.append(self.allocator, 0x11) catch return;
                // WAT: call_indirect $tableidx? typeuse
                // Binary: 0x11 typeidx tableidx
                var ci_table_idx: u32 = 0;
                // Check for $table identifier before the type use
                if (self.peek().kind == .identifier) {
                    const ci_tok = self.advance();
                    ci_table_idx = self.table_names.get(ci_tok.text) orelse 0;
                } else if (self.peek().kind == .integer) {
                    // Lookahead: if integer followed by (type ...), it's a table index
                    const sp_ci = self.lexer.pos;
                    const spk_ci = self.peeked;
                    const maybe_tbl = self.parseU32() catch 0;
                    if (self.peek().kind == .l_paren) {
                        const sp2 = self.lexer.pos;
                        const spk2 = self.peeked;
                        _ = self.advance(); // skip '('
                        if (self.peek().kind == .kw_type) {
                            // It was a table index followed by (type ...)
                            ci_table_idx = maybe_tbl;
                            // Restore to just before '(' so the type parsing below handles it
                            self.lexer.pos = sp2;
                            self.peeked = spk2;
                        } else {
                            // Not (type ...), restore and treat as type index
                            self.lexer.pos = sp_ci;
                            self.peeked = spk_ci;
                        }
                    } else {
                        // No '(' follows, restore and treat as type index
                        self.lexer.pos = sp_ci;
                        self.peeked = spk_ci;
                    }
                }
                // Pre-scan: check type/param/result ordering
                // Valid order is: (type ...)? (param ...)* (result ...)*
                {
                    var scan = Lexer.init(self.lexer.source);
                    scan.pos = if (self.peeked) |pk| pk.offset else self.lexer.pos;
                    var saw_type = false;
                    var saw_param = false;
                    var saw_result = false;
                    while (true) {
                        const stok = scan.next();
                        if (stok.kind != .l_paren) break;
                        const inner = scan.next();
                        if (inner.kind == .kw_type) {
                            if (saw_param or saw_result) self.markMalformed(@src());
                            saw_type = true;
                        } else if (inner.kind == .kw_param) {
                            if (saw_result) self.markMalformed(@src());
                            saw_param = true;
                        } else if (inner.kind == .kw_result) {
                            saw_result = true;
                        } else break;
                        // Skip to matching ')'
                        var sdepth: u32 = 1;
                        while (sdepth > 0) {
                            const s2 = scan.next();
                            if (s2.kind == .l_paren) sdepth += 1 else if (s2.kind == .r_paren) sdepth -= 1 else if (s2.kind == .eof) break;
                        }
                    }
                }
                // Parse type use: (type $idx) or inline
                if (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance(); // '('
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance(); // 'type'
                        // Resolve type name via type_names, not emitU32Imm
                        // (emitU32Imm checks func_names first, which can
                        // shadow type names when a function has the same $name)
                        if (self.peek().kind == .identifier) {
                            const type_tok = self.advance();
                            const idx = self.type_names.get(type_tok.text) orelse 0;
                            self.emitLeb128U32(code, idx);
                        } else {
                            self.emitU32Imm(code); // numeric type index
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance(); // ')'
                        // Consume optional inline (param ...) and (result ...) after type
                        while (self.peek().kind == .l_paren) {
                            const sp2 = self.lexer.pos;
                            const spk2 = self.peeked;
                            _ = self.advance();
                            if (self.peek().kind == .kw_param or self.peek().kind == .kw_result) {
                                _ = self.advance();
                                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                                    _ = self.advance();
                                }
                                if (self.peek().kind == .r_paren) _ = self.advance();
                            } else {
                                self.lexer.pos = sp2;
                                self.peeked = spk2;
                                break;
                            }
                        }
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        // Check for inline (param ...) (result ...) without (type ...)
                        var ci_buf: [6]u8 = undefined;
                        const ci_n = self.readBlockType(&ci_buf, true);
                        // readBlockType emits signed s33 for type indices, but
                        // readBlockType emits signed s33 for type indices, but
                        // call_indirect uses unsigned u32. Re-encode if needed.
                        if (ci_n > 1 or (ci_n == 1 and ci_buf[0] != 0x40)) {
                            // Type index from readBlockType — decode s33 and re-encode as u32
                            if (leb128.readS32Leb128(ci_buf[0..ci_n])) |sr| {
                                if (sr.value >= 0) {
                                    self.emitLeb128U32(code, @intCast(sr.value));
                                } else {
                                    self.emitLeb128U32(code, 0);
                                }
                            } else |_| {
                                self.emitLeb128U32(code, 0);
                            }
                        } else {
                            self.emitLeb128U32(code, 0);
                        }
                    }
                } else if (self.peek().kind == .integer) {
                    self.emitU32Imm(code); // numeric type index
                } else {
                    // No type use at all — void type, use type 0
                    self.emitLeb128U32(code, 0);
                }
                // Emit table index
                self.emitLeb128U32(code, ci_table_idx);
            },
            .kw_return_call_indirect => {
                code.append(self.allocator, 0x13) catch return;
                var rci_table_idx: u32 = 0;
                if (self.peek().kind == .identifier) {
                    const rci_tok = self.advance();
                    rci_table_idx = self.table_names.get(rci_tok.text) orelse 0;
                } else if (self.peek().kind == .integer) {
                    // Lookahead: if integer followed by (type/param/result ...), it's a table index
                    const sp_ti = self.lexer.pos;
                    const spk_ti = self.peeked;
                    const maybe_tbl = self.parseU32() catch 0;
                    if (self.peek().kind == .l_paren) {
                        const sp2 = self.lexer.pos;
                        const spk2 = self.peeked;
                        _ = self.advance();
                        if (self.peek().kind == .kw_type or self.peek().kind == .kw_param or self.peek().kind == .kw_result) {
                            rci_table_idx = maybe_tbl;
                            self.lexer.pos = sp2;
                            self.peeked = spk2;
                        } else {
                            self.lexer.pos = sp_ti;
                            self.peeked = spk_ti;
                        }
                    } else {
                        self.lexer.pos = sp_ti;
                        self.peeked = spk_ti;
                    }
                }
                if (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) {
                            const type_tok = self.advance();
                            const idx = self.type_names.get(type_tok.text) orelse 0;
                            self.emitLeb128U32(code, idx);
                        } else {
                            self.emitU32Imm(code);
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                        // Skip optional trailing (param ...) (result ...) after type
                        while (self.peek().kind == .l_paren) {
                            const sp2 = self.lexer.pos;
                            const spk2 = self.peeked;
                            _ = self.advance();
                            if (self.peek().kind == .kw_param or self.peek().kind == .kw_result) {
                                _ = self.advance();
                                while (self.peek().kind != .r_paren and self.peek().kind != .eof) _ = self.advance();
                                if (self.peek().kind == .r_paren) _ = self.advance();
                            } else {
                                self.lexer.pos = sp2;
                                self.peeked = spk2;
                                break;
                            }
                        }
                    } else if (self.peek().kind == .kw_param or self.peek().kind == .kw_result) {
                        // Inline (param ...) (result ...) — parse and create type
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        var rci_params: [16]types.ValType = undefined;
                        var rci_param_count: u32 = 0;
                        var rci_results: [16]types.ValType = undefined;
                        var rci_result_count: u32 = 0;
                        while (self.peek().kind == .l_paren) {
                            const sp3 = self.lexer.pos;
                            const spk3 = self.peeked;
                            _ = self.advance();
                            if (self.peek().kind == .kw_param) {
                                _ = self.advance();
                                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                                    if (self.parseValType()) |vt| {
                                        if (rci_param_count < 16) { rci_params[rci_param_count] = vt; rci_param_count += 1; }
                                    } else |_| break;
                                }
                                if (self.peek().kind == .r_paren) _ = self.advance();
                            } else if (self.peek().kind == .kw_result) {
                                _ = self.advance();
                                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                                    if (self.parseValType()) |vt| {
                                        if (rci_result_count < 16) { rci_results[rci_result_count] = vt; rci_result_count += 1; }
                                    } else |_| break;
                                }
                                if (self.peek().kind == .r_paren) _ = self.advance();
                            } else {
                                self.lexer.pos = sp3;
                                self.peeked = spk3;
                                break;
                            }
                        }
                        // Create func type and emit index
                        if (self.module) |mod| {
                            const p = self.allocator.alloc(types.ValType, rci_param_count) catch { self.emitLeb128U32(code, 0); self.emitLeb128U32(code, rci_table_idx); return; };
                            @memcpy(p, rci_params[0..rci_param_count]);
                            const r = self.allocator.alloc(types.ValType, rci_result_count) catch { self.emitLeb128U32(code, 0); self.emitLeb128U32(code, rci_table_idx); return; };
                            @memcpy(r, rci_results[0..rci_result_count]);
                            const type_idx: u32 = @intCast(mod.module_types.items.len);
                            mod.module_types.append(self.allocator, .{ .func_type = .{ .params = p, .results = r } }) catch {};
                            self.emitLeb128U32(code, type_idx);
                        } else {
                            self.emitLeb128U32(code, 0);
                        }
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        self.emitLeb128U32(code, 0);
                    }
                } else if (self.peek().kind == .integer) {
                    self.emitU32Imm(code);
                } else {
                    self.emitLeb128U32(code, 0);
                }
                self.emitLeb128U32(code, rci_table_idx);
            },
            .kw_drop => code.append(self.allocator, 0x1a) catch return,
            .kw_select => {
                // Check for typed select: select (result <type>) ...
                if (self.peek().kind == .l_paren) {
                    const save_pos2 = self.lexer.pos;
                    const save_peeked2 = self.peeked;
                    _ = self.advance(); // consume '('
                    if (self.peek().kind == .kw_result) {
                        _ = self.advance(); // consume 'result'
                        code.append(self.allocator, 0x1c) catch return; // typed select
                        var sel_types: [8]types.ValType = undefined;
                        var count: u32 = 0;
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
                            if (count < 8) sel_types[count] = vt;
                            count += 1;
                        }
                        self.emitLeb128U32(code, count);
                        for (0..count) |ci| {
                            if (ci < 8) {
                                const raw: u32 = @bitCast(@intFromEnum(sel_types[ci]));
                                code.append(self.allocator, @truncate(raw)) catch {};
                            }
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                        // Consume additional (result ...) annotations
                        while (self.peek().kind == .l_paren) {
                            const sp3 = self.lexer.pos;
                            const spk3 = self.peeked;
                            _ = self.advance();
                            if (self.peek().kind == .kw_result) {
                                _ = self.advance();
                                while (self.peek().kind != .r_paren and self.peek().kind != .eof) _ = self.advance();
                                if (self.peek().kind == .r_paren) _ = self.advance();
                            } else {
                                self.lexer.pos = sp3;
                                self.peeked = spk3;
                                break;
                            }
                        }
                    } else {
                        self.lexer.pos = save_pos2;
                        self.peeked = save_peeked2;
                        code.append(self.allocator, 0x1b) catch return;
                    }
                } else {
                    code.append(self.allocator, 0x1b) catch return;
                }
            },
            .kw_local_get => {
                code.append(self.allocator, 0x20) catch return;
                self.emitU32Imm(code);
            },
            .kw_local_set => {
                code.append(self.allocator, 0x21) catch return;
                self.emitU32Imm(code);
            },
            .kw_local_tee => {
                code.append(self.allocator, 0x22) catch return;
                self.emitU32Imm(code);
            },
            .kw_global_get => {
                code.append(self.allocator, 0x23) catch return;
                self.emitGlobalIdx(code);
            },
            .kw_global_set => {
                code.append(self.allocator, 0x24) catch return;
                self.emitGlobalIdx(code);
            },
            .kw_memory_size => {
                code.append(self.allocator, 0x3f) catch return;
                self.emitMemIdxImm(code);
            },
            .kw_memory_grow => {
                code.append(self.allocator, 0x40) catch return;
                self.emitMemIdxImm(code);
            },
            .kw_i32_const => {
                code.append(self.allocator, 0x41) catch return;
                self.emitS32Imm(code);
            },
            .kw_i64_const => {
                code.append(self.allocator, 0x42) catch return;
                self.emitS64Imm(code);
            },
            .kw_f32_const => {
                code.append(self.allocator, 0x43) catch return;
                self.emitF32Imm(code);
            },
            .kw_f64_const => {
                code.append(self.allocator, 0x44) catch return;
                self.emitF64Imm(code);
            },
            .kw_ref_null => {
                code.append(self.allocator, 0xd0) catch return;
                self.emitRefNullHeapType(code);
            },
            .kw_ref_func => {
                code.append(self.allocator, 0xd2) catch return;
                self.emitFuncIdx(code);
            },
            .kw_ref_test, .kw_ref_cast => {
                // ref.test (ref [null] <ht>) / ref.cast (ref [null] <ht>)
                // Encoding: 0xfb + sub_opcode + heaptype
                code.append(self.allocator, 0xfb) catch return;
                var nullable = false;
                // Parse (ref [null] <heaptype>) or bare type keyword
                if (self.peek().kind == .l_paren) {
                    _ = self.advance(); // consume '('
                    if (self.peek().kind == .kw_ref) {
                        _ = self.advance(); // consume 'ref'
                        if (self.peek().kind == .kw_null) {
                            _ = self.advance();
                            nullable = true;
                        }
                    }
                    // Parse heap type
                    var heap_type: ?types.HeapType = null;
                    if (self.peek().kind == .identifier) {
                        const name = self.advance().text;
                        if (self.type_names.get(name)) |idx| {
                            heap_type = .{ .concrete = idx };
                        }
                    } else if (self.peek().kind == .integer) {
                        heap_type = .{ .concrete = self.parseU32() catch 0 };
                    } else if (self.peek().kind == .kw_func) {
                        _ = self.advance();
                        heap_type = .{ .abstract = .func };
                    } else if (self.peek().kind != .r_paren) {
                        const ht_text = self.advance().text;
                        if (abstractHeapTypeByName(ht_text)) |abstract| {
                            heap_type = .{ .abstract = abstract };
                        }
                    }
                    if (self.peek().kind == .r_paren) _ = self.advance();
                    // Emit sub-opcode
                    const sub_op: u32 = if (tok.kind == .kw_ref_test)
                        (if (nullable) @as(u32, 0x15) else @as(u32, 0x14))
                    else
                        (if (nullable) @as(u32, 0x17) else @as(u32, 0x16));
                    self.emitLeb128U32(code, sub_op);
                    if (heap_type) |ht| self.emitHeapType(code, ht);
                } else if (self.peek().kind == .kw_i31ref or self.peek().kind == .kw_eqref or
                    self.peek().kind == .kw_structref or self.peek().kind == .kw_arrayref or
                    self.peek().kind == .kw_funcref or self.peek().kind == .kw_anyref or
                    self.peek().kind == .kw_externref or self.peek().kind == .kw_nullref or
                    self.peek().kind == .kw_nullfuncref or self.peek().kind == .kw_nullexternref or
                    self.peek().kind == .kw_nullexnref or self.peek().kind == .kw_exnref)
                {
                    // Bare type keyword: ref.cast i31ref etc.
                    const vt = self.advance();
                    nullable = true; // bare ref types are nullable
                    const heap_type: ?types.AbstractHeapType = switch (vt.kind) {
                        .kw_i31ref => .i31,
                        .kw_eqref => .eq,
                        .kw_structref => .struct_,
                        .kw_arrayref => .array,
                        .kw_funcref => .func,
                        .kw_anyref => .any,
                        .kw_externref => .extern_,
                        .kw_exnref => .exn,
                        .kw_nullref => .none,
                        .kw_nullfuncref => .nofunc,
                        .kw_nullexternref => .noextern,
                        .kw_nullexnref => .noexn,
                        else => null,
                    };
                    const sub_op: u32 = if (tok.kind == .kw_ref_test)
                        (if (nullable) @as(u32, 0x15) else @as(u32, 0x14))
                    else
                        (if (nullable) @as(u32, 0x17) else @as(u32, 0x16));
                    self.emitLeb128U32(code, sub_op);
                    if (heap_type) |abstract| self.emitHeapType(code, .{ .abstract = abstract });
                }
            },
            .opcode => {
                if (std.mem.eql(u8, tok.text, "v128.const")) {
                    self.emitSimdV128Const(code);
                } else {
                    self.emitGenericOpcode(tok.text, code);
                }
            },
            .invalid => {
                self.markMalformed(@src());
            },
            .kw_catch, .kw_catch_ref, .kw_catch_all, .kw_catch_all_ref => {
                // catch/catch_ref/catch_all/catch_all_ref outside try_table is malformed
                self.markMalformed(@src());
            },
            .kw_local => {
                // local in function body (after instructions) is an ordering error
                self.markMalformed(@src());
            },
            else => {},
        }
    }

    fn emitBlockType(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        var buf: [6]u8 = undefined;
        const len = self.readBlockType(&buf, false);
        code.appendSlice(self.allocator, buf[0..len]) catch {};
    }

    fn readBlockType(self: *Parser, buf: *[6]u8, force_type_index: bool) usize {
        // Check for (param ...) (result ...), (result <valtype>+), or bare (param ...)
        var param_count: u32 = 0;
        var param_types_buf: [16]types.ValType = undefined;
        var param_tidxs_buf: [16]u32 = @splat(0xFFFFFFFF);
        var result_count: u32 = 0;
        var result_types_buf: [16]types.ValType = undefined;
        var result_tidxs_buf: [16]u32 = @splat(0xFFFFFFFF);

        // Consume all (param ...) blocks
        while (self.peek().kind == .l_paren or self.peek().kind == .annotation) {
            if (self.peek().kind == .annotation) { _ = self.advance(); self.skipAnnotation() catch break; continue; }
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_param) {
                _ = self.advance(); // consume 'param'
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    self.skipAnnotations();
                    if (self.peek().kind == .r_paren) break;
                    const before_pos = self.lexer.pos;
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    if (self.parseValType()) |vt| {
                        self.in_type_parse = saved_itp;
                        if (param_count < 16) {
                            param_types_buf[param_count] = vt;
                            param_tidxs_buf[param_count] = if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF;
                        }
                        param_count += 1;
                        self.skipAnnotations();
                    } else |_| {
                        self.in_type_parse = saved_itp;
                        if (self.lexer.pos == before_pos) _ = self.advance();
                        break;
                    }
                }
                self.skipAnnotations();
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
            self.skipAnnotations();
        }

        // Consume all (result ...) blocks
        while (self.peek().kind == .l_paren or self.peek().kind == .annotation) {
            if (self.peek().kind == .annotation) { _ = self.advance(); self.skipAnnotation() catch break; continue; }
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_result) {
                _ = self.advance(); // consume 'result'
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    self.skipAnnotations();
                    if (self.peek().kind == .r_paren) break;
                    const before_pos = self.lexer.pos;
                    const refs_before = self.collected_type_refs.items.len;
                    const saved_itp = self.in_type_parse;
                    self.in_type_parse = true;
                    if (self.parseValType()) |vt| {
                        self.in_type_parse = saved_itp;
                        if (result_count < 16) {
                            result_types_buf[result_count] = vt;
                            result_tidxs_buf[result_count] = if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF;
                        }
                        result_count += 1;
                        self.skipAnnotations();
                    } else |_| {
                        self.in_type_parse = saved_itp;
                        if (self.lexer.pos == before_pos) _ = self.advance();
                        break;
                    }
                }
                self.skipAnnotations();
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
            self.skipAnnotations();
        }

        // No block type annotations found
        if (param_count == 0 and result_count == 0) {
            // Fall through to check for (type N) below
        } else if (param_count == 0 and result_count == 1 and @intFromEnum(result_types_buf[0]) > 0) {
            // Simple single-result block type: emit valtype byte
            // BUT concrete refs need the multi-value path (type index) because
            // they require a heap type that can't be encoded in a single byte
            const rt = result_types_buf[0];
            if (rt != .concrete_ref_null and rt != .concrete_ref and !force_type_index) {
                const raw: u32 = @bitCast(@intFromEnum(rt));
                buf[0] = @truncate(raw);
                return 1;
            }
        }
        // Multi-value or concrete ref: create a func type entry and emit type index
        if (param_count > 0 or result_count > 0) {
            if (self.module) |mod| {
                const p = self.allocator.alloc(types.ValType, param_count) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                @memcpy(p, param_types_buf[0..param_count]);
                const pt = self.allocator.alloc(u32, param_count) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                @memcpy(pt, param_tidxs_buf[0..param_count]);
                const r = self.allocator.alloc(types.ValType, result_count) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                @memcpy(r, result_types_buf[0..result_count]);
                const rt = self.allocator.alloc(u32, result_count) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                @memcpy(rt, result_tidxs_buf[0..result_count]);
                const type_idx: u32 = @intCast(mod.module_types.items.len);
                mod.module_types.append(self.allocator, .{
                    .func_type = .{ .params = p, .results = r, .param_type_idxs = pt, .result_type_idxs = rt },
                }) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                return leb128.writeS32Leb128(buf, @bitCast(type_idx));
            }
            buf[0] = 0x40;
            return 1;
        }
        // Check for bare type use: (type N)
        if (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_type) {
                _ = self.advance();
                if (self.parseTypeIdx()) |idx| {
                    if (self.peek().kind == .r_paren) _ = self.advance();
                    const n = leb128.writeS32Leb128(buf, @bitCast(idx));
                    return n;
                } else |_| {}
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
            }
        }
        buf[0] = 0x40; // void
        return 1;
    }

    /// Emit the function index a `ref.func` names.
    ///
    /// `ref.func x` takes a funcidx and nothing else, so only the function
    /// namespace is searched. The general immediate reader is no good here:
    /// it tries labels and then locals first, for the sake of `br $label`
    /// and `local.get $x`, and the local names of the function parsed most
    /// recently are still in it when a table's or a global's initializer is
    /// read. A module whose last function had a parameter `$y` and which
    /// then wrote `ref.func $y` for the *function* `$y` silently got that
    /// parameter's index instead. A name that no function has is malformed
    /// rather than function 0.
    fn emitFuncIdx(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            if (self.lookupName(&self.func_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
            } else {
                self.markMalformed(@src());
                self.emitLeb128U32(code, 0);
            }
            return;
        }
        if (self.peek().kind == .integer) {
            self.emitLeb128U32(code, self.parseU32() catch 0);
            return;
        }
        self.markMalformed(@src());
        self.emitLeb128U32(code, 0);
    }

    fn emitGlobalIdx(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            if (self.lookupName(&self.global_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            self.emitLeb128U32(code, 0);
            return;
        }
        const tok = self.advance();
        if (tok.kind == .integer) {
            const val = std.fmt.parseInt(u32, tok.text, 0) catch 0;
            self.emitLeb128U32(code, val);
        } else {
            self.emitLeb128U32(code, 0);
        }
    }

    fn emitU32Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            // Check label stack first (for br/br_if $label)
            if (self.resolveLabelDepth(tok.text)) |depth| {
                self.emitLeb128U32(code, depth);
                return;
            }
            if (self.lookupName(&self.local_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.func_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.type_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.global_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.table_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.memory_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.data_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.lookupName(&self.elem_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            self.emitLeb128U32(code, 0);
            return;
        }
        if (self.peek().kind == .integer) {
            const val = self.parseU32() catch 0;
            self.emitLeb128U32(code, val);
        } else {
            self.emitLeb128U32(code, 0);
        }
    }

    /// Consume an optional $label identifier (used after block/loop/if keywords).
    fn consumeOptionalLabel(self: *Parser) ?[]const u8 {
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            return normalizeIdentifier(self.allocator, tok.text);
        }
        return null;
    }

    /// Resolve a label name to its branch depth (0 = innermost).
    fn resolveLabelDepth(self: *Parser, name: []const u8) ?u32 {
        if (self.label_stack.items.len == 0) return null;
        const norm = normalizeIdentifier(self.allocator, name);
        defer if (norm.ptr != name.ptr) self.allocator.free(norm);
        var i: u32 = 0;
        while (i < self.label_stack.items.len) : (i += 1) {
            const idx = self.label_stack.items.len - 1 - i;
            if (self.label_stack.items[idx]) |label| {
                if (std.mem.eql(u8, label, name)) return i;
                if (norm.ptr != name.ptr and std.mem.eql(u8, label, norm)) return i;
            }
        }
        return null;
    }

    fn emitS32Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        const tok = self.advance();
        if (tok.kind != .integer) {
            self.markMalformed(@src());
            self.emitLeb128S32(code, 0);
            return;
        }
        if (!isValidNumLiteral(tok.text)) self.markMalformed(@src());
        const clean = stripUnderscores(tok.text);
        const text = clean.slice();
        const val = std.fmt.parseInt(i32, text, 0) catch blk: {
            // Try parsing as unsigned and reinterpret
            const uval = std.fmt.parseInt(u32, text, 0) catch {
                self.markMalformed(@src());
                break :blk 0;
            };
            break :blk @as(i32, @bitCast(uval));
        };
        self.emitLeb128S32(code, val);
    }

    fn emitS64Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        const tok = self.advance();
        if (tok.kind != .integer) {
            self.markMalformed(@src());
            self.emitLeb128S64(code, 0);
            return;
        }
        if (!isValidNumLiteral(tok.text)) self.markMalformed(@src());
        const clean = stripUnderscores(tok.text);
        const text = clean.slice();
        const val = std.fmt.parseInt(i64, text, 0) catch blk: {
            const uval = std.fmt.parseInt(u64, text, 0) catch {
                self.markMalformed(@src());
                break :blk 0;
            };
            break :blk @as(i64, @bitCast(uval));
        };
        self.emitLeb128S64(code, val);
    }

    fn emitF32Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        const tok = self.advance();
        if (tok.kind == .integer or tok.kind == .float) {
            if (!isValidNumLiteral(tok.text)) self.markMalformed(@src());
            if (!isValidFloatLiteral(f32, tok.text)) self.markMalformed(@src());
            const bits = parseF32Bits(tok.text);
            const le = std.mem.toBytes(bits);
            code.appendSlice(self.allocator, &le) catch {};
        } else {
            self.markMalformed(@src());
            code.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }) catch {};
        }
    }

    fn emitF64Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        const tok = self.advance();
        if (tok.kind == .integer or tok.kind == .float) {
            if (!isValidNumLiteral(tok.text)) self.markMalformed(@src());
            if (!isValidFloatLiteral(f64, tok.text)) self.markMalformed(@src());
            const bits = parseF64Bits(tok.text);
            const le = std.mem.toBytes(bits);
            code.appendSlice(self.allocator, &le) catch {};
        } else {
            self.markMalformed(@src());
            code.appendSlice(self.allocator, &[8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }) catch {};
        }
    }

    fn emitLeb128U32(self: *Parser, code: *std.ArrayListUnmanaged(u8), val: u32) void {
        var buf: [5]u8 = undefined;
        const n = leb128.writeU32Leb128(&buf, val);
        code.appendSlice(self.allocator, buf[0..n]) catch {};
    }

    fn emitLeb128S32(self: *Parser, code: *std.ArrayListUnmanaged(u8), val: i32) void {
        var buf: [5]u8 = undefined;
        const n = leb128.writeS32Leb128(&buf, val);
        code.appendSlice(self.allocator, buf[0..n]) catch {};
    }

    fn emitLeb128S64(self: *Parser, code: *std.ArrayListUnmanaged(u8), val: i64) void {
        var buf: [10]u8 = undefined;
        const n = leb128.writeS64Leb128(&buf, val);
        code.appendSlice(self.allocator, buf[0..n]) catch {};
    }

    /// Emit a heaptype as the s33 LEB128 the binary format requires: abstract heap
    /// types are the *negative* spec codes (func = -0x10 encodes to the single byte
    /// 0x70), concrete heap types are the non-negative type index.
    fn emitHeapType(self: *Parser, code: *std.ArrayListUnmanaged(u8), heap: types.HeapType) void {
        switch (heap) {
            .abstract => |abstract| self.emitLeb128S64(code, @intFromEnum(abstract)),
            .concrete => |idx| self.emitLeb128S64(code, @intCast(idx)),
        }
    }

    fn validateRefNullTypeIndex(self: *Parser, idx: u32) void {
        if (self.module) |mod| {
            const max = if (mod.num_declared_types > 0)
                mod.num_declared_types
            else
                @as(u32, @intCast(mod.module_types.items.len));
            if (idx >= max) self.markMalformed(@src());
        }
    }

    fn emitRefNullHeapType(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const heap: types.HeapType = switch (self.peek().kind) {
            .identifier => blk: {
                const idx = self.parseTypeIdx() catch {
                    self.markMalformed(@src());
                    self.emitHeapType(code, .{ .abstract = .func });
                    return;
                };
                self.validateRefNullTypeIndex(idx);
                break :blk .{ .concrete = idx };
            },
            .integer => blk: {
                const idx = self.parseU32() catch {
                    self.markMalformed(@src());
                    self.emitHeapType(code, .{ .abstract = .func });
                    return;
                };
                self.validateRefNullTypeIndex(idx);
                break :blk .{ .concrete = idx };
            },
            .kw_funcref, .kw_func => blk: {
                _ = self.advance();
                break :blk .{ .abstract = .func };
            },
            .kw_externref => blk: {
                _ = self.advance();
                break :blk .{ .abstract = .extern_ };
            },
            .kw_exnref => blk: {
                _ = self.advance();
                break :blk .{ .abstract = .exn };
            },
            .r_paren, .eof => {
                self.markMalformed(@src());
                self.emitHeapType(code, .{ .abstract = .func });
                return;
            },
            else => blk: {
                const tok = self.advance();
                const abstract = abstractHeapTypeByName(tok.text) orelse {
                    self.markMalformed(@src());
                    self.emitHeapType(code, .{ .abstract = .func });
                    return;
                };
                break :blk .{ .abstract = abstract };
            },
        };
        self.emitHeapType(code, heap);
    }

    fn emitGenericOpcode(self: *Parser, text: []const u8, code: *std.ArrayListUnmanaged(u8)) void {
        // Map WAT opcode text (e.g. "i32.add") to binary opcode
        const opcode = opcodeFromText(text);
        if (opcode) |op| {
            if (op <= 0xff) {
                code.append(self.allocator, @truncate(op)) catch return;
                // Memory load/store instructions: emit memarg (align + offset)
                if (op >= 0x28 and op <= 0x3e) {
                    self.emitMemarg(code, @truncate(op));
                }
                // table.get / table.set need a table index immediate
                if (op == 0x25 or op == 0x26) {
                    self.emitU32Imm(code);
                }
                // br_on_null / br_on_non_null need a label depth immediate
                if (op == 0xd5 or op == 0xd6) {
                    self.emitU32Imm(code);
                }
            } else {
                const unpacked = unpackOpcode(op);
                const sub = unpacked.sub;
                const actual_prefix = unpacked.prefix;
                code.append(self.allocator, actual_prefix) catch return;
                var buf: [5]u8 = undefined;
                const n = leb128.writeU32Leb128(&buf, sub);
                code.appendSlice(self.allocator, buf[0..n]) catch return;
                if (actual_prefix == 0xfe) {
                    // The validator already states what each threads opcode
                    // carries and how it must be aligned, so read it from
                    // there rather than keeping a second, driftable copy. The
                    // condition here used to be `sub >= 0x10`, which is wrong
                    // twice over: it gave `atomic.fence` a memarg instead of
                    // its reserved byte, and gave notify and wait at 0x00 to
                    // 0x02 no immediate at all.
                    if (Validator.atomicSig(sub)) |sig| switch (sig.imm) {
                        .fence => code.append(self.allocator, 0x00) catch return,
                        // An atomic must be exactly naturally aligned, so that
                        // is the alignment to assume when none is written.
                        .memarg => self.emitMemargAligned(code, sig.align_log2),
                    };
                } else if (actual_prefix == 0xfc) {
                    self.emitBulkMemImm(sub, code);
                } else if (actual_prefix == 0xfd) {
                    self.emitSimdImm(sub, code);
                } else if (actual_prefix == 0xfb) {
                    self.emitGcImm(sub, code);
                }
            }
        } else {
            // Unrecognized opcode text — flag as malformed
            self.markMalformed(@src());
        }
    }

    /// Emit immediates for GC (0xfb prefix) instructions.
    fn emitGcImm(self: *Parser, sub: u32, code: *std.ArrayListUnmanaged(u8)) void {
        switch (sub) {
            0x00, 0x01 => self.emitU32Imm(code), // struct.new, struct.new_default: typeidx
            0x02, 0x03, 0x04, 0x05 => { // struct.get/get_s/get_u/set: typeidx, fieldidx
                // First: type index
                var type_idx: u32 = 0;
                if (self.peek().kind == .identifier) {
                    const tok = self.advance();
                    type_idx = self.type_names.get(tok.text) orelse 0;
                    self.emitLeb128U32(code, type_idx);
                } else if (self.peek().kind == .integer) {
                    type_idx = self.parseU32() catch 0;
                    self.emitLeb128U32(code, type_idx);
                } else {
                    self.emitLeb128U32(code, 0);
                }
                // Second: field index (may be $name or numeric)
                if (self.peek().kind == .identifier) {
                    const field_tok = self.advance();
                    // Look up field name in the struct type
                    var field_idx: u32 = 0;
                    if (self.module) |mod| {
                        if (type_idx < mod.module_types.items.len) {
                            switch (mod.module_types.items[type_idx]) {
                                .struct_type => |st| {
                                    for (st.fields.items, 0..) |field, fi| {
                                        if (field.name) |name| {
                                            if (std.mem.eql(u8, name, field_tok.text)) {
                                                field_idx = @intCast(fi);
                                                break;
                                            }
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                    self.emitLeb128U32(code, field_idx);
                } else {
                    self.emitU32Imm(code);
                }
            },
            0x06, 0x07 => self.emitU32Imm(code), // array.new, array.new_default: typeidx
            0x08 => { // array.new_fixed: typeidx, count
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x09, 0x0a => { // array.new_data, array.new_elem: typeidx, dataidx/elemidx
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x0b, 0x0c, 0x0d, 0x0e => self.emitU32Imm(code), // array.get/get_s/get_u/set: typeidx
            0x0f => {}, // array.len: no immediates
            0x10 => self.emitU32Imm(code), // array.fill: typeidx
            0x11 => { // array.copy: typeidx, typeidx
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x12 => { // array.init_data: typeidx, dataidx
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x13 => { // array.init_elem: typeidx, elemidx
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x1a, 0x1b => {}, // any.convert_extern, extern.convert_any: no immediates
            0x1c, 0x1d, 0x1e => {}, // ref.i31, i31.get_s, i31.get_u: no immediates
            else => {},
        }
    }

    /// Emit immediates for SIMD (0xfd prefix) instructions.
    fn emitSimdImm(self: *Parser, sub: u32, code: *std.ArrayListUnmanaged(u8)) void {
        if (sub <= 0x0b or (sub >= 0x5c and sub <= 0x5d)) {
            // v128.load/store variants + load_zero: memarg only (no separate
            // mem_idx). As above, an omitted `align=` means the natural
            // alignment, which the validator already records for each.
            const natural: u8 = if (Validator.simdSig(sub)) |sig| sig.max_align else 0;
            self.emitMemargAligned(code, natural);
        } else if (sub == 0x0d) {
            // i8x16.shuffle: 16 lane index bytes
            for (0..16) |_| {
                const lane_val = self.parseU32() catch 0;
                code.append(self.allocator, @truncate(lane_val)) catch {};
            }
        } else if (sub >= 0x15 and sub <= 0x22) {
            // extract_lane / replace_lane: 1 byte lane index
            const lane_val = self.parseU32() catch 0;
            code.append(self.allocator, @truncate(lane_val)) catch {};
        } else if (sub >= 0x54 and sub <= 0x5b) {
            // v128.load*_lane / v128.store*_lane: memarg + 1 byte lane
            // Binary format: memarg then lane byte
            // WAT format: optional "offset=N align=N" then lane_idx
            // Don't use emitMemarg (it may consume the lane integer as memory index).
            // Parse memarg keywords manually.
            var log2_align: u32 = if (Validator.simdSig(sub)) |sig| sig.max_align else 0;
            var offset: u64 = 0;
            for (0..2) |_| {
                if (self.peek().kind == .nat_eq) {
                    const tok = self.advance();
                    if (std.mem.startsWith(u8, tok.text, "offset=")) {
                        offset = std.fmt.parseInt(u64, tok.text[7..], 0) catch 0;
                    } else if (std.mem.startsWith(u8, tok.text, "align=")) {
                        // `align=` states the alignment itself; what is
                        // encoded is its log2. Emitting the stated number
                        // made every naturally aligned lane op look
                        // wildly over-aligned and be rejected.
                        const stated = std.fmt.parseInt(u32, tok.text[6..], 0) catch 0;
                        if (stated == 0 or (stated & (stated - 1)) != 0) {
                            self.markMalformed(@src());
                        } else {
                            log2_align = @ctz(stated);
                        }
                    }
                }
            }
            // Lane index
            const lane_val = self.parseU32() catch 0;
            // Emit memarg: alignment LEB + offset LEB
            var abuf: [5]u8 = undefined;
            const an = leb128.writeU32Leb128(&abuf, log2_align);
            code.appendSlice(self.allocator, abuf[0..an]) catch {};
            var obuf: [5]u8 = undefined;
            const on = leb128.writeU32Leb128(&obuf, @truncate(offset));
            code.appendSlice(self.allocator, obuf[0..on]) catch {};
            // Lane byte
            code.append(self.allocator, @truncate(lane_val)) catch {};
        }
        // All other SIMD ops (arithmetic, comparison, etc.) have no immediates
    }

    /// Emit a v128.const instruction with 16 bytes of literal data.
    fn emitSimdV128Const(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        // Emit 0xfd prefix + 0x0c sub-opcode
        code.append(self.allocator, 0xfd) catch return;
        var buf: [5]u8 = undefined;
        const n = leb128.writeU32Leb128(&buf, 0x0c);
        code.appendSlice(self.allocator, buf[0..n]) catch return;

        // Parse lane format: i8x16, i16x8, i32x4, i64x2, f32x4, f64x2
        const fmt_tok = self.advance();
        const fmt = fmt_tok.text;
        if (std.mem.eql(u8, fmt, "i8x16")) {
            for (0..16) |_| {
                const v = self.parseI32() catch 0;
                code.append(self.allocator, @truncate(@as(u32, @bitCast(v)))) catch {};
            }
        } else if (std.mem.eql(u8, fmt, "i16x8")) {
            for (0..8) |_| {
                const v = self.parseI32() catch 0;
                const val: u16 = @truncate(@as(u32, @bitCast(v)));
                code.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(u16, val))) catch {};
            }
        } else if (std.mem.eql(u8, fmt, "i32x4")) {
            for (0..4) |_| {
                const v = self.parseI32() catch 0;
                code.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i32, v))) catch {};
            }
        } else if (std.mem.eql(u8, fmt, "i64x2")) {
            for (0..2) |_| {
                const v = self.parseI64() catch 0;
                code.appendSlice(self.allocator, std.mem.asBytes(&std.mem.nativeToLittle(i64, v))) catch {};
            }
        } else if (std.mem.eql(u8, fmt, "f32x4")) {
            for (0..4) |_| {
                const v = self.parseF32Bytes();
                code.appendSlice(self.allocator, &v) catch {};
            }
        } else if (std.mem.eql(u8, fmt, "f64x2")) {
            for (0..2) |_| {
                const v = self.parseF64Bytes();
                code.appendSlice(self.allocator, &v) catch {};
            }
        } else {
            // Unknown lane format — emit 16 zero bytes
            code.appendNTimes(self.allocator, 0, 16) catch {};
        }
    }

    fn parseI32(self: *Parser) ParseError!i32 {
        const tok = self.advance();
        if (tok.kind == .integer) {
            // Handle both positive and negative, and hex
            return std.fmt.parseInt(i32, tok.text, 0) catch {
                // Try unsigned parsing for large values
                const u = std.fmt.parseInt(u32, tok.text, 0) catch return 0;
                return @bitCast(u);
            };
        }
        return 0;
    }

    fn parseI64(self: *Parser) ParseError!i64 {
        const tok = self.advance();
        if (tok.kind == .integer) {
            return std.fmt.parseInt(i64, tok.text, 0) catch {
                const u = std.fmt.parseInt(u64, tok.text, 0) catch return 0;
                return @bitCast(u);
            };
        }
        return 0;
    }

    fn parseF32Bytes(self: *Parser) [4]u8 {
        const tok = self.advance();
        const bits = parseFloatBits(f32, tok.text);
        return std.mem.toBytes(std.mem.nativeToLittle(u32, bits));
    }

    fn parseF64Bytes(self: *Parser) [8]u8 {
        const tok = self.advance();
        const bits = parseFloatBits(f64, tok.text);
        return std.mem.toBytes(std.mem.nativeToLittle(u64, bits));
    }

    /// Emit an optional memory index for load/store instructions.
    /// Checks if the next token is a $name matching a known memory.
    fn emitMemIdx(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        if (self.peek().kind == .identifier) {
            if (self.memory_names.get(self.peek().text)) |idx| {
                _ = self.advance();
                self.emitLeb128U32(code, idx);
                return;
            }
        }
        self.emitLeb128U32(code, 0);
    }

    /// Emit the optional memory index for memory.size/memory.grow.
    fn emitMemIdxImm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            if (self.lookupName(&self.memory_names, tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
            } else {
                self.markMalformed(@src());
                self.emitLeb128U32(code, 0);
            }
            return;
        }
        if (self.peek().kind == .integer) {
            const idx = self.parseU32() catch {
                self.markMalformed(@src());
                self.emitLeb128U32(code, 0);
                return;
            };
            self.emitLeb128U32(code, idx);
            return;
        }
        self.emitLeb128U32(code, 0);
    }

    fn emitMemarg(self: *Parser, code: *std.ArrayListUnmanaged(u8), opcode: u8) void {
        // Text that omits `align=` means the natural alignment, not no
        // alignment. The validator already records the width of every plain
        // memory instruction, so take it from there.
        const natural = Validator.maxAlignmentForOpcode(opcode) orelse 0;
        self.emitMemargAligned(code, @truncate(natural));
    }

    /// As `emitMemarg`, but with the alignment to assume when the text states
    /// none, for instructions whose natural alignment is not keyed by a plain
    /// opcode byte.
    fn emitMemargAligned(self: *Parser, code: *std.ArrayListUnmanaged(u8), default_log2: u8) void {
        // Parse optional memory index: $name or integer before offset=/align=
        var mem_idx: u32 = 0;
        var has_mem_idx = false;
        if (self.peek().kind == .identifier) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            const tok = self.advance();
            // Check if this is a memory name (not a local/etc)
            if (self.memory_names.get(tok.text)) |idx| {
                mem_idx = idx;
                has_mem_idx = true;
            } else {
                // Not a memory name — rewind
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
            }
        } else if (self.peek().kind == .integer and self.peek().text.len > 0 and self.peek().text[0] != '-') {
            // Check if next token is a bare integer (memory index) before offset=/align=
            // Only consume if followed by offset=, align=, or end of args
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            const tok = self.advance();
            const next = self.peek().kind;
            if (next == .nat_eq or next == .l_paren or next == .r_paren or next == .eof) {
                mem_idx = std.fmt.parseInt(u32, tok.text, 0) catch 0;
                if (mem_idx > 0) has_mem_idx = true;
            } else {
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
            }
        }

        // Parse optional offset=N and align=N
        var alignment: u32 = 0;
        var offset: u64 = 0;
        var has_align = false;
        for (0..2) |_| {
            if (self.peek().kind == .nat_eq) {
                const tok = self.advance();
                if (std.mem.startsWith(u8, tok.text, "offset=")) {
                    const clean = stripUnderscores(tok.text[7..]);
                    offset = std.fmt.parseInt(u64, clean.slice(), 0) catch {
                        self.markMalformed(@src());
                        continue;
                    };
                } else if (std.mem.startsWith(u8, tok.text, "align=")) {
                    alignment = std.fmt.parseInt(u32, tok.text[6..], 0) catch {
                        self.markMalformed(@src());
                        continue;
                    };
                    has_align = true;
                }
            }
        }
        // Convert alignment to log2 and validate
        var log2_align: u32 = default_log2;
        if (has_align) {
            if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
                self.markMalformed(@src());
            } else {
                log2_align = @ctz(alignment);
            }
        }
        // Encode alignment with multi-memory bit 6
        if (has_mem_idx) {
            self.emitLeb128U32(code, log2_align | 0x40);
            self.emitLeb128U32(code, mem_idx);
        } else {
            self.emitLeb128U32(code, log2_align);
        }
        var buf: [10]u8 = undefined;
        const n = leb128.writeU64Leb128(&buf, offset);
        code.appendSlice(self.allocator, buf[0..n]) catch {};
    }

    fn emitBulkMemImm(self: *Parser, sub: u32, code: *std.ArrayListUnmanaged(u8)) void {
        switch (sub) {
            0x08 => {
                // memory.init: WAT syntax is `memory.init $mem $data` or `memory.init $data`
                // Binary format expects: data_idx, mem_idx
                const first_kind = self.peek().kind;
                if (first_kind == .identifier or first_kind == .integer) {
                    var first_code = std.ArrayListUnmanaged(u8).empty;
                    self.emitU32Imm(&first_code);
                    const second_kind = self.peek().kind;
                    if (second_kind == .identifier or second_kind == .integer) {
                        // Two immediates: first is mem_idx, second is data_idx
                        // Binary order: data_idx, mem_idx
                        var second_code = std.ArrayListUnmanaged(u8).empty;
                        self.emitU32Imm(&second_code);
                        code.appendSlice(self.allocator, second_code.items) catch {};
                        code.appendSlice(self.allocator, first_code.items) catch {};
                        second_code.deinit(self.allocator);
                    } else {
                        // One immediate: it's data_idx, mem defaults to 0
                        code.appendSlice(self.allocator, first_code.items) catch {};
                        self.emitLeb128U32(code, 0); // mem_idx = 0
                    }
                    first_code.deinit(self.allocator);
                } else {
                    self.emitLeb128U32(code, 0); // data_idx = 0
                    self.emitLeb128U32(code, 0); // mem_idx = 0
                }
            },
            0x09 => self.emitU32Imm(code), // data.drop
            0x0a => {
                // memory.copy: dst_mem, src_mem
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x0b => self.emitU32Imm(code), // memory.fill
            0x0c => {
                // table.init: WAT syntax is `table.init $table $elem` or `table.init $elem`
                // Binary format expects: elem_idx, table_idx
                const first_kind = self.peek().kind;
                if (first_kind == .identifier or first_kind == .integer) {
                    var first_code = std.ArrayListUnmanaged(u8).empty;
                    self.emitU32Imm(&first_code);
                    const second_kind = self.peek().kind;
                    if (second_kind == .identifier or second_kind == .integer) {
                        // Two immediates: first is table_idx, second is elem_idx
                        // Binary order: elem_idx, table_idx
                        var second_code = std.ArrayListUnmanaged(u8).empty;
                        self.emitU32Imm(&second_code);
                        code.appendSlice(self.allocator, second_code.items) catch {};
                        code.appendSlice(self.allocator, first_code.items) catch {};
                        second_code.deinit(self.allocator);
                    } else {
                        // One immediate: it's elem_idx, table defaults to 0
                        code.appendSlice(self.allocator, first_code.items) catch {};
                        self.emitLeb128U32(code, 0); // table_idx = 0
                    }
                    first_code.deinit(self.allocator);
                } else {
                    self.emitLeb128U32(code, 0); // elem_idx = 0
                    self.emitLeb128U32(code, 0); // table_idx = 0
                }
            },
            0x0d => self.emitU32Imm(code), // elem.drop
            0x0e => {
                // table.copy: dst_table, src_table
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x0f => self.emitU32Imm(code), // table.grow
            0x10 => self.emitU32Imm(code), // table.size
            0x11 => self.emitU32Imm(code), // table.fill
            else => {},
        }
    }

    fn skipToRParen(self: *Parser) void {
        // Skip tokens until we see the matching ')' or eof
        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
            if (self.peek().kind == .annotation) {
                _ = self.advance();
                self.skipAnnotation() catch return;
            } else if (self.peek().kind == .l_paren) {
                _ = self.advance();
                self.skipToRParen();
            } else {
                _ = self.advance();
            }
        }
        if (self.peek().kind == .r_paren) _ = self.advance();
    }

    /// Parse a sequence of instructions in an init expression context and emit bytecode.
    /// Handles both plain instructions and folded (parenthesized) instructions.
    fn parseInitExpr(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
            if (self.peek().kind == .l_paren) {
                _ = self.advance(); // consume '('
                self.skipAnnotations();
                self.parseInitExprFolded(code);
            } else {
                self.parseInitExprPlain(code);
            }
            self.skipAnnotations();
        }
    }

    /// Parse a folded (parenthesized) init expression instruction.
    fn parseInitExprFolded(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        const tok = self.peek();
        switch (tok.kind) {
            .kw_i32_const, .kw_i64_const, .kw_f32_const, .kw_f64_const,
            .kw_ref_null, .kw_ref_func, .kw_global_get => {
                // Parse nested args first, then the instruction
                self.parseInitExprPlain(code);
                // Skip to closing paren
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.skipAnnotations();
                        self.parseInitExprFolded(code);
                    } else {
                        self.parseInitExprPlain(code);
                    }
                    self.skipAnnotations();
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            },
            else => {
                // Extended constant expression in folded form (e.g. i32.add).
                // Emit instruction, then operands, then reorder so operands precede instruction.
                const instr_start = code.items.len;
                if (self.takeInitExprTerminator()) return;
                self.parsePlainInstr(code);
                const instr_end = code.items.len;
                const instr_len = instr_end - instr_start;
                // Parse sub-expressions (operands)
                var has_operands = false;
                self.skipAnnotations();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.skipAnnotations();
                        self.parseInitExprFolded(code);
                        has_operands = true;
                    } else {
                        self.parseInitExprPlain(code);
                        has_operands = true;
                    }
                    self.skipAnnotations();
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
                // Reorder: [instr][operands] → [operands][instr]
                if (has_operands and instr_len > 0 and instr_len <= 32) {
                    var buf: [32]u8 = undefined;
                    @memcpy(buf[0..instr_len], code.items[instr_start..instr_end]);
                    const total = code.items.len;
                    const operand_len = total - instr_end;
                    std.mem.copyForwards(u8, code.items[instr_start .. instr_start + operand_len], code.items[instr_end..total]);
                    @memcpy(code.items[instr_start + operand_len .. instr_start + operand_len + instr_len], buf[0..instr_len]);
                }
            },
        }
    }

    /// Parse a plain init expression instruction.
    fn parseInitExprPlain(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        if (self.takeInitExprTerminator()) return;
        self.parsePlainInstr(code);
    }

    /// Reject the `end` that terminates a constant expression in the binary
    /// but has no spelling in the text.
    ///
    /// A constant expression is a sequence of instructions, not a block:
    /// `expr ::= instr* end` puts the `end` in the *encoding*, and every
    /// writer of one appends it. Reading `end` as an instruction let
    /// `(global i32 i32.const 0 end)` through, and what it wrote was
    /// `41 00 0b` plus the writer's own `0b` -- two terminators, and a
    /// section whose declared size no longer matches its contents. The
    /// validator could not catch it either, because it stops reading at the
    /// first `end`.
    fn takeInitExprTerminator(self: *Parser) bool {
        if (self.peek().kind != .kw_end) return false;
        self.markMalformed(@src());
        _ = self.advance();
        return true;
    }

    /// Parse an init expression that is wrapped in parens, e.g. (i32.const 0).
    /// This handles a single folded instruction expression.
    fn parseInitExprWrapped(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.skipAnnotations();
        if (self.peek().kind == .l_paren) {
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            self.parseInitExprFolded(code);
        }
    }

    const IndexedValType = struct {
        val_type: types.ValType,
        type_idx: u32 = types.invalid_index,
    };

    fn parseIndexedValType(self: *Parser) ParseError!IndexedValType {
        const refs_before = self.collected_type_refs.items.len;
        const saved_in_type_parse = self.in_type_parse;
        self.in_type_parse = true;
        const val_type_result = self.parseValType();
        self.in_type_parse = saved_in_type_parse;
        const val_type = val_type_result catch |err| {
            self.collected_type_refs.shrinkRetainingCapacity(refs_before);
            return err;
        };
        const type_idx = if (self.collected_type_refs.items.len > refs_before)
            self.collected_type_refs.items[refs_before]
        else
            types.invalid_index;
        self.collected_type_refs.shrinkRetainingCapacity(refs_before);
        if ((val_type == .concrete_ref or val_type == .concrete_ref_null) and
            type_idx == types.invalid_index)
        {
            self.markMalformed(@src());
        }
        return .{
            .val_type = val_type,
            .type_idx = type_idx,
        };
    }

    const IndexedGlobalType = struct {
        global_type: types.GlobalType,
        type_idx: u32 = types.invalid_index,
    };

    fn parseIndexedGlobalType(self: *Parser) ParseError!IndexedGlobalType {
        self.skipAnnotations();
        if (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance();
            self.skipAnnotations();
            if (self.peek().kind == .kw_mut) {
                _ = self.advance();
                self.skipAnnotations();
                const indexed = try self.parseIndexedValType();
                self.skipAnnotations();
                try self.expect(.r_paren);
                return .{
                    .global_type = .{ .val_type = indexed.val_type, .mutability = .mutable },
                    .type_idx = indexed.type_idx,
                };
            }
            self.lexer.pos = save_pos;
            self.peeked = save_peeked;
        }

        const indexed = try self.parseIndexedValType();
        return .{
            .global_type = .{ .val_type = indexed.val_type, .mutability = .immutable },
            .type_idx = indexed.type_idx,
        };
    }

    fn recordTableImport(
        self: *Parser,
        module: *Mod.Module,
        import: *Mod.Import,
        table_type: types.TableType,
        type_idx: u32,
        is_table64: bool,
    ) ParseError!void {
        import.table = table_type;
        import.table_type_idx = type_idx;
        try module.tables.append(self.allocator, .{
            .@"type" = table_type,
            .type_idx = type_idx,
            .is_import = true,
            .is_table64 = is_table64,
        });
        module.num_table_imports += 1;
    }

    fn recordGlobalImport(
        self: *Parser,
        module: *Mod.Module,
        import: *Mod.Import,
        global_type: types.GlobalType,
        type_idx: u32,
    ) ParseError!void {
        import.global = global_type;
        import.global_type_idx = type_idx;
        try module.globals.append(self.allocator, .{
            .@"type" = global_type,
            .type_idx = type_idx,
            .is_import = true,
        });
        module.num_global_imports += 1;
    }

    fn parseTable(self: *Parser, module: *Mod.Module) ParseError!void {
        const table_idx: u32 = @intCast(module.tables.items.len);
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            if (self.table_names.get(name)) |existing| {
                if (existing != table_idx and existing < table_idx) self.markMalformed(@src());
            }
            self.table_names.put(self.allocator, name, table_idx) catch {};
        }

        self.skipAnnotations();
        // Check for i64 keyword (table64)
        var is_table64 = false;
        if (self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_table64 = true;
        }

        // Handle inline (export "name") and (import "mod" "name") on tables
        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance();
            self.skipAnnotations();
            if (self.peek().kind == .kw_export) {
                _ = self.advance();
                self.skipAnnotations();
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                self.skipAnnotations();
                if (self.peek().kind == .r_paren) _ = self.advance();
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .table,
                    .var_ = .{ .index = table_idx },
                }) catch return error.OutOfMemory;
                self.skipAnnotations();
            } else if (self.peek().kind == .kw_import) {
                _ = self.advance(); // consume 'import'
                self.skipAnnotations();
                const mod_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                const field_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                try self.expect(.r_paren); // close (import ...)
                self.skipAnnotations();
                // Check for i64 keyword after import (table64)
                if (!is_table64 and self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_table64 = true;
                }
                const limits = try self.parseLimitsTail(is_table64);
                self.skipAnnotations();
                const indexed = try self.parseIndexedValType();
                var import = Mod.Import{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .table,
                };
                try self.recordTableImport(
                    module,
                    &import,
                    .{ .elem_type = indexed.val_type, .limits = limits },
                    indexed.type_idx,
                    is_table64,
                );
                try module.imports.append(self.allocator, import);
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        // Check for i64 keyword after export/import clauses
        self.skipAnnotations();
        if (!is_table64 and self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_table64 = true;
        }

        // Check for inline element syntax: (table elemtype (elem ...))
        self.skipAnnotations();
        if (self.peek().kind != .integer) {
            // elemtype first — inline elem syntax
            const saved_refs_len2 = self.collected_type_refs.items.len;
            const saved_in_type2 = self.in_type_parse;
            self.in_type_parse = true;
            const elem_type = self.parseValType() catch .funcref;
            self.in_type_parse = saved_in_type2;
            const inline_type_idx: u32 = if (self.collected_type_refs.items.len > saved_refs_len2)
                self.collected_type_refs.items[saved_refs_len2]
            else
                0xFFFFFFFF;
            // `(table <reftype> (elem <elemlist>))` abbreviates a table whose
            // size is the length of the list, together with an active
            // segment holding the list at offset zero. What follows `elem`
            // is an ordinary elemlist, so it is read by the same code
            // `(elem ...)` uses: the same folded and `(item ...)` spellings,
            // the same heap types, the same name resolution.
            var seg = Mod.ElemSegment{
                .kind = .active,
                .table_var = .{ .index = table_idx },
                .elem_type = elem_type,
                .elem_type_idx = inline_type_idx,
                // The implicit form of a segment means table 0, so only a
                // later table has to say which table its elements fill.
                .has_explicit_table_index = table_idx != 0,
            };
            errdefer self.deinitElemSegment(&seg);
            var elem_expr_code: std.ArrayListUnmanaged(u8) = .empty;
            defer elem_expr_code.deinit(self.allocator);
            var elem_expr_count: u32 = 0;
            var func_index_count: u32 = 0;
            var has_elem_list = false;
            self.skipAnnotations();
            if (self.peek().kind == .l_paren) {
                const sp2 = self.lexer.pos;
                const spk2 = self.peeked;
                _ = self.advance();
                self.skipAnnotations();
                if (self.peek().kind == .kw_elem) {
                    _ = self.advance();
                    has_elem_list = true;
                    self.skipAnnotations();
                    while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                        if (self.peek().kind == .l_paren) {
                            _ = self.advance();
                            self.skipAnnotations();
                            const inner_kind = self.peek().kind;
                            try self.parseElemExprEntry(&seg, &elem_expr_code, inner_kind);
                            elem_expr_count += 1;
                        } else if (self.peek().kind == .integer or
                            self.peek().kind == .identifier)
                        {
                            try self.parseElemFuncIdxEntry(&seg);
                            func_index_count += 1;
                        } else {
                            // Neither an expression nor a function index, so
                            // it is not an element of any elemlist.
                            self.markMalformed(@src());
                            _ = self.advance();
                        }
                        self.skipAnnotations();
                    }
                    try self.expect(.r_paren);
                } else {
                    self.lexer.pos = sp2;
                    self.peeked = spk2;
                }
            }
            // The two elemlist forms are alternatives, not a mixture: a
            // segment holds function indices or expressions, and only one of
            // them can be encoded.
            if (elem_expr_count > 0 and func_index_count > 0) self.markMalformed(@src());
            // The abbreviation stands for `(table id' n n reftype)`: a table
            // exactly as long as the list that fills it, both bounds. A
            // minimum on its own leaves room the elements do not reach, and
            // lets the table grow past what was written -- the sibling
            // `(memory (data ...))` abbreviation has always fixed both.
            const initial: u64 = elem_expr_count + func_index_count;
            try module.tables.append(self.allocator, .{
                .@"type" = .{ .elem_type = elem_type, .limits = .{
                    .initial = initial,
                    .max = if (has_elem_list) initial else 0,
                    .has_max = has_elem_list,
                    .is_64 = is_table64,
                } },
                .type_idx = inline_type_idx,
                .is_table64 = is_table64,
            });
            if (!has_elem_list) return;

            // An empty list is still a list, and it is written in whichever
            // form can state the type: the index form only ever holds
            // functions, so a table of any other reference type needs the
            // expression form even with nothing in it.
            const list_is_indices = func_index_count > 0 or
                (elem_expr_count == 0 and (elem_type == .funcref or elem_type == .ref_func));
            seg.uses_elem_exprs = !list_is_indices;
            if (list_is_indices) {
                // The function-index form infers `(ref func)`, not the
                // table's own type, exactly as a written-out `(elem ...)`
                // does.
                seg.elem_type = .ref_func;
                seg.elem_type_idx = types.invalid_index;
            }
            const ob = try self.allocator.alloc(u8, 2);
            ob[0] = if (is_table64) 0x42 else 0x41; // i64.const / i32.const
            ob[1] = 0x00; // 0
            seg.offset_expr_bytes = ob;
            seg.owns_offset_expr_bytes = true;
            if (elem_expr_count > 0) {
                seg.elem_expr_bytes = try elem_expr_code.toOwnedSlice(self.allocator);
                seg.owns_elem_expr_bytes = true;
                seg.elem_expr_count = elem_expr_count;
            }
            try module.elem_segments.append(self.allocator, seg);
            return;
        }

        const limits = try self.parseLimitsTail(is_table64);
        self.skipAnnotations();
        // Capture concrete type index if elem type is (ref null $t) / (ref $t)
        const saved_refs_len = self.collected_type_refs.items.len;
        const saved_in_type = self.in_type_parse;
        self.in_type_parse = true;
        const elem_type = try self.parseValType();
        self.in_type_parse = saved_in_type;
        const table_type_idx: u32 = if (self.collected_type_refs.items.len > saved_refs_len)
            self.collected_type_refs.items[saved_refs_len]
        else
            0xFFFFFFFF;
        // A table may state the value its slots start out holding. The
        // initializer is an ordinary constant expression, written either
        // folded — `(table 1 funcref (ref.null func))` — or unfolded, which
        // is the spelling the text writer emits and the one `wasm-tools`
        // prints: `(table 1 funcref ref.null func)`. Both go through the
        // shared constant-expression parser, so a form accepted for a global
        // is accepted here, with the same heap types, the same name
        // resolution and the same errors.
        self.skipAnnotations();
        var table_init_bytes: []const u8 = &.{};
        var owns_table_init_bytes = false;
        if (self.peek().kind != .r_paren and self.peek().kind != .eof) {
            var init_code: std.ArrayListUnmanaged(u8) = .empty;
            defer init_code.deinit(self.allocator);
            self.parseInitExpr(&init_code);
            // Something followed the element type but produced no
            // instruction, so it was not an initializer at all.
            if (init_code.items.len == 0) self.markMalformed(@src());
            table_init_bytes = try init_code.toOwnedSlice(self.allocator);
            owns_table_init_bytes = true;
        }
        errdefer if (owns_table_init_bytes and table_init_bytes.len > 0)
            self.allocator.free(table_init_bytes);
        try module.tables.append(self.allocator, .{
            .@"type" = .{ .elem_type = elem_type, .limits = limits },
            .init_expr_bytes = table_init_bytes,
            .owns_init_expr_bytes = owns_table_init_bytes,
            .type_idx = table_type_idx,
            .is_table64 = is_table64,
        });
    }

    /// Parse the bounds that follow a table's or memory's index type: an
    /// initial size, an optional maximum, and the `shared` and `(pagesize N)`
    /// markers. All six places that accept limits share this so that a form
    /// the writer emits cannot be accepted in one position and rejected in
    /// another.
    fn parseLimitsTail(self: *Parser, is_64: bool) ParseError!types.Limits {
        self.skipAnnotations();
        const initial = if (is_64) try self.parseU64() else @as(u64, try self.parseU32());
        var limits = types.Limits{ .initial = initial, .is_64 = is_64 };
        self.skipAnnotations();
        if (self.peek().kind == .integer) {
            limits.max = if (is_64) try self.parseU64() else @as(u64, try self.parseU32());
            limits.has_max = true;
            self.skipAnnotations();
        }
        if (self.peek().kind == .kw_shared) {
            _ = self.advance();
            limits.is_shared = true;
            self.skipAnnotations();
        }
        // `(pagesize N)` states the memory's page size, which is otherwise
        // the default of 64 KiB.
        if (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peek = self.peeked;
            _ = self.advance();
            self.skipAnnotations();
            if (self.peek().kind == .kw_pagesize) {
                _ = self.advance();
                self.skipAnnotations();
                limits.page_size = try self.parseU32();
                self.skipAnnotations();
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else {
                self.lexer.pos = save_pos;
                self.peeked = save_peek;
            }
        }
        return limits;
    }

    fn parseMemory(self: *Parser, module: *Mod.Module) ParseError!void {
        const mem_idx: u32 = @intCast(module.memories.items.len);
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            if (self.memory_names.get(name)) |existing| {
                if (existing != mem_idx and existing < mem_idx) self.markMalformed(@src());
            }
            self.memory_names.put(self.allocator, name, mem_idx) catch {};
        }

        self.skipAnnotations();
        // Check for i64 keyword (memory64)
        var is_memory64 = false;
        if (self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_memory64 = true;
        }

        // Handle inline (export "name") declarations
        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                self.skipAnnotations();
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                self.skipAnnotations();
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .memory,
                    .var_ = .{ .index = mem_idx },
                }) catch return error.OutOfMemory;
                self.skipAnnotations();
            } else if (self.peek().kind == .kw_data) {
                // Inline (data "...") abbreviation
                _ = self.advance(); // consume 'data'
                var data_parts: std.ArrayListUnmanaged(u8) = .empty;
                defer data_parts.deinit(self.allocator);
                while (self.peek().kind == .string) {
                    const tok = self.advance();
                    const stripped = stripQuotes(tok.text);
                    decodeWatStringInto(stripped, &data_parts, self.allocator);
                }
                try self.expect(.r_paren); // close (data ...)
                const data_len: u64 = @intCast(data_parts.items.len);
                const page_size: u64 = 65536;
                const pages: u64 = if (data_len == 0) 0 else (data_len + page_size - 1) / page_size;
                try module.memories.append(self.allocator, .{
                    .type = .{ .limits = .{ .initial = pages, .max = pages, .has_max = true, .is_64 = is_memory64 } },
                });
                // Create active data segment at offset 0
                var seg = Mod.DataSegment{};
                seg.kind = .active;
                seg.memory_var = .{ .index = mem_idx };
                if (is_memory64) {
                    const ob = self.allocator.alloc(u8, 2) catch return error.OutOfMemory;
                    ob[0] = 0x42; // i64.const
                    ob[1] = 0x00; // 0
                    seg.offset_expr_bytes = ob;
                } else {
                    const ob = self.allocator.alloc(u8, 2) catch return error.OutOfMemory;
                    ob[0] = 0x41; // i32.const
                    ob[1] = 0x00; // 0
                    seg.offset_expr_bytes = ob;
                }
                seg.owns_offset_expr_bytes = true;
                if (data_parts.items.len > 0) {
                    seg.data = data_parts.toOwnedSlice(self.allocator) catch &.{};
                    seg.owns_data = true;
                }
                try module.data_segments.append(self.allocator, seg);
                return;
            } else if (self.peek().kind == .kw_import) {
                // Inline (import "mod" "name") abbreviation for memory
                _ = self.advance(); // consume 'import'
                self.skipAnnotations();
                const mod_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                const field_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                try self.expect(.r_paren); // close (import ...)
                self.skipAnnotations();
                // Check for i64 keyword after import (memory64)
                if (!is_memory64 and self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_memory64 = true;
                }
                const limits = try self.parseLimitsTail(is_memory64);
                try module.memories.append(self.allocator, .{
                    .type = .{ .limits = limits },
                    .is_import = true,
                });
                module.num_memory_imports += 1;
                var import = Mod.Import{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .memory,
                };
                import.memory = .{ .limits = limits };
                try module.imports.append(self.allocator, import);
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        // Check for i64 keyword after export/import clauses
        self.skipAnnotations();
        if (!is_memory64 and self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_memory64 = true;
        }

        const limits = try self.parseLimitsTail(is_memory64);
        try module.memories.append(self.allocator, .{
            .@"type" = .{ .limits = limits },
        });
    }

    fn parseGlobal(self: *Parser, module: *Mod.Module) ParseError!void {
        const global_idx: u32 = @intCast(module.globals.items.len);
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            // Detect duplicate $name: prescan sets index on first occurrence,
            // so if the existing index doesn't match ours AND it's a lower
            // index (already processed), it's a genuine duplicate.
            if (self.global_names.get(name)) |existing| {
                if (existing != global_idx and existing < global_idx) self.markMalformed(@src());
            }
            self.global_names.put(self.allocator, name, global_idx) catch {};
        }

        // Handle inline (export "name") and (import "mod" "name") declarations
        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            self.skipAnnotations();
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                self.skipAnnotations();
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                self.skipAnnotations();
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .global,
                    .var_ = .{ .index = global_idx },
                }) catch return error.OutOfMemory;
                self.skipAnnotations();
            } else if (self.peek().kind == .kw_import) {
                _ = self.advance(); // consume 'import'
                self.skipAnnotations();
                const mod_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                const field_name = self.parseName(self.advance().text);
                self.skipAnnotations();
                try self.expect(.r_paren); // close (import ...)

                const indexed = try self.parseIndexedGlobalType();
                var import = Mod.Import{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .global,
                };
                try self.recordGlobalImport(
                    module,
                    &import,
                    indexed.global_type,
                    indexed.type_idx,
                );
                try module.imports.append(self.allocator, import);
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        self.skipAnnotations();
        var mutability: types.Mutability = .immutable;
        var val_type: types.ValType = undefined;
        var global_tidx: u32 = 0xFFFFFFFF;

        // Check for (mut <valtype>) — requires two-token lookahead
        if (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_mut) {
                _ = self.advance();
                mutability = .mutable;
                const rb = self.collected_type_refs.items.len;
                const si = self.in_type_parse;
                self.in_type_parse = true;
                val_type = try self.parseValType();
                self.in_type_parse = si;
                if (self.collected_type_refs.items.len > rb) global_tidx = self.collected_type_refs.items[rb];
                self.skipAnnotations();
                try self.expect(.r_paren);
            } else {
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                const rb = self.collected_type_refs.items.len;
                const si = self.in_type_parse;
                self.in_type_parse = true;
                val_type = try self.parseValType();
                self.in_type_parse = si;
                if (self.collected_type_refs.items.len > rb) global_tidx = self.collected_type_refs.items[rb];
            }
        } else {
            const rb = self.collected_type_refs.items.len;
            const si = self.in_type_parse;
            self.in_type_parse = true;
            val_type = try self.parseValType();
            self.in_type_parse = si;
            if (self.collected_type_refs.items.len > rb) global_tidx = self.collected_type_refs.items[rb];
        }

        // Encode init expression into bytecode
        self.skipAnnotations();
        var code: std.ArrayListUnmanaged(u8) = .empty;
        defer code.deinit(self.allocator);
        self.parseInitExpr(&code);

        const owned = code.toOwnedSlice(self.allocator) catch &.{};

        try module.globals.append(self.allocator, .{
            .type = .{ .val_type = val_type, .mutability = mutability },
            .type_idx = global_tidx,
            .init_expr_bytes = owned,
            .owns_init_expr_bytes = true,
        });
    }

    fn parseTag(self: *Parser, module: *Mod.Module) ParseError!void {
        const tag_idx: u32 = @intCast(module.tags.items.len);
        // Parse optional $name
        if (self.peek().kind == .identifier) {
            const name_tok = self.advance();
            self.tag_names.put(self.allocator, name_tok.text, tag_idx) catch {};
        }
        // Handle inline (export "name") declarations
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance();
            if (self.peek().kind == .kw_export) {
                _ = self.advance();
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                if (self.peek().kind == .r_paren) _ = self.advance();
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .tag,
                    .var_ = .{ .index = tag_idx },
                }) catch return error.OutOfMemory;
            } else if (self.peek().kind == .kw_import) {
                // Inline import: (tag $name (import "mod" "field") ...)
                _ = self.advance();
                const mod_name = self.parseName(self.advance().text);
                const field_name = self.parseName(self.advance().text);
                if (self.peek().kind == .r_paren) _ = self.advance();
                var imp_params: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer imp_params.deinit(self.allocator);
                var imp_param_tidxs: std.ArrayListUnmanaged(u32) = .empty;
                defer imp_param_tidxs.deinit(self.allocator);
                var inline_tag_type_idx: u32 = std.math.maxInt(u32);
                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const refs_before = self.collected_type_refs.items.len;
                            const vt = self.parseValType() catch break;
                            imp_param_tidxs.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            imp_params.append(self.allocator, vt) catch {};
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        const tidx = self.parseTypeIdx() catch 0;
                        inline_tag_type_idx = tidx;
                        if (self.module) |mod| {
                            if (tidx < mod.module_types.items.len) {
                                switch (mod.module_types.items[tidx]) {
                                    .func_type => |ft| {
                                        for (ft.params) |p2| imp_params.append(self.allocator, p2) catch {};
                                        for (ft.param_type_idxs) |ti| imp_param_tidxs.append(self.allocator, ti) catch {};
                                    },
                                    else => {},
                                }
                            }
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        break;
                    }
                }
                const params = imp_params.toOwnedSlice(self.allocator) catch &.{};
                const param_tidxs = imp_param_tidxs.toOwnedSlice(self.allocator) catch &.{};
                defer if (param_tidxs.len > 0) self.allocator.free(param_tidxs);
                // An imported tag needs a type section entry exactly as much
                // as a defined one does -- the import section encodes a
                // signature *index*, not a signature. Without this the
                // written module referred to a type that was never emitted.
                if (inline_tag_type_idx == std.math.maxInt(u32)) {
                    inline_tag_type_idx = self.findOrAddFuncTypeWithTidxs(module, params, &.{}, param_tidxs, &.{});
                }
                module.imports.append(self.allocator, .{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .tag,
                }) catch {};
                try module.tags.append(self.allocator, .{
                    .@"type" = .{ .sig = .{ .params = params, .results = &.{} } },
                    .type_idx = inline_tag_type_idx,
                    .is_import = true,
                });
                module.num_tag_imports += 1;
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }
        // Parse tag type: (param ...) and (result ...)
        var params_list: std.ArrayListUnmanaged(types.ValType) = .empty;
        defer params_list.deinit(self.allocator);
        var results_list: std.ArrayListUnmanaged(types.ValType) = .empty;
        defer results_list.deinit(self.allocator);
        var param_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
        defer param_tidxs_list.deinit(self.allocator);
        var result_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
        defer result_tidxs_list.deinit(self.allocator);
        const prev_itp = self.in_type_parse;
        self.in_type_parse = true;
        defer self.in_type_parse = prev_itp;
        var tag_type_idx: u32 = std.math.maxInt(u32);
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance();
            if (self.peek().kind == .kw_param) {
                _ = self.advance();
                if (self.peek().kind == .identifier) _ = self.advance();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const refs_before = self.collected_type_refs.items.len;
                    const vt = self.parseValType() catch break;
                    param_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                    params_list.append(self.allocator, vt) catch {};
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else if (self.peek().kind == .kw_result) {
                _ = self.advance();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const refs_before = self.collected_type_refs.items.len;
                    const vt = self.parseValType() catch break;
                    result_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                    results_list.append(self.allocator, vt) catch {};
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else if (self.peek().kind == .kw_type) {
                _ = self.advance();
                const tidx = self.parseTypeIdx() catch 0;
                if (self.module) |mod| {
                    if (tidx < mod.module_types.items.len) {
                        switch (mod.module_types.items[tidx]) {
                            .func_type => |ft| {
                                for (ft.params) |p| params_list.append(self.allocator, p) catch {};
                                for (ft.results) |r| results_list.append(self.allocator, r) catch {};
                                for (ft.param_type_idxs) |ti| param_tidxs_list.append(self.allocator, ti) catch {};
                                for (ft.result_type_idxs) |ti| result_tidxs_list.append(self.allocator, ti) catch {};
                            },
                            else => {},
                        }
                    }
                }
                tag_type_idx = tidx;
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }
        const params = params_list.toOwnedSlice(self.allocator) catch &.{};
        const results = results_list.toOwnedSlice(self.allocator) catch &.{};
        const param_tidxs = param_tidxs_list.toOwnedSlice(self.allocator) catch &.{};
        const result_tidxs = result_tidxs_list.toOwnedSlice(self.allocator) catch &.{};
        // `Tag` has no slots for the concrete type indices, and
        // `findOrAddFuncTypeWithTidxs` copies them into `module_types`, so
        // nothing takes ownership of these two and they must be freed here.
        // `params`/`results` are different: the tag keeps them, and
        // `Module.deinit` frees them.
        defer if (param_tidxs.len > 0) self.allocator.free(param_tidxs);
        defer if (result_tidxs.len > 0) self.allocator.free(result_tidxs);
        // If no explicit type index, register a function type for this tag's signature
        if (tag_type_idx == std.math.maxInt(u32)) {
            tag_type_idx = self.findOrAddFuncTypeWithTidxs(module, params, results, param_tidxs, result_tidxs);
        }
        try module.tags.append(self.allocator, .{
            .@"type" = .{ .sig = .{ .params = params, .results = results } },
            .type_idx = tag_type_idx,
        });
    }

    /// Find a matching function type index in module_types, or add a new one.
    fn findOrAddFuncType(self: *Parser, module: *Mod.Module, params: []const types.ValType, results: []const types.ValType) u32 {
        return self.findOrAddFuncTypeWithTidxs(module, params, results, &.{}, &.{});
    }

        /// Concrete type index parallel to element `idx`. A shorter or absent
    /// list means the remaining entries are abstract, which is how types
    /// built without index tracking are represented.
    fn concreteIdxAt(tidxs: []const u32, idx: usize) u32 {
        return Mod.FuncSignature.concreteIdxAt(tidxs, idx);
    }

    fn findOrAddFuncTypeWithTidxs(self: *Parser, module: *Mod.Module, params: []const types.ValType, results: []const types.ValType, param_tidxs: []const u32, result_tidxs: []const u32) u32 {
        // Search existing types
        for (module.module_types.items, 0..) |entry, i| {
            switch (entry) {
                .func_type => |ft| {
                    if (ft.params.len == params.len and ft.results.len == results.len) {
                        var match = true;
                        // The concrete type index has to take part in the
                        // comparison: `(ref $a)` and `(ref $b)` are the same
                        // `ValType`, so matching on value types alone folded
                        // two distinct function types into one and handed
                        // back an index describing the wrong signature.
                        for (ft.params, params, 0..) |a, b, k| {
                            if (a != b or concreteIdxAt(ft.param_type_idxs, k) != concreteIdxAt(param_tidxs, k)) {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            for (ft.results, results, 0..) |a, b, k| {
                                if (a != b or concreteIdxAt(ft.result_type_idxs, k) != concreteIdxAt(result_tidxs, k)) {
                                    match = false;
                                    break;
                                }
                            }
                        }
                        if (match) return @intCast(i);
                    }
                },
                else => {},
            }
        }
        // Not found — add a new type
        const new_idx: u32 = @intCast(module.module_types.items.len);
        const p_copy = self.allocator.dupe(types.ValType, params) catch return new_idx;
        const r_copy = self.allocator.dupe(types.ValType, results) catch return new_idx;
        const pt_copy = if (param_tidxs.len > 0) (self.allocator.dupe(u32, param_tidxs) catch &.{}) else @as([]const u32, &.{});
        const rt_copy = if (result_tidxs.len > 0) (self.allocator.dupe(u32, result_tidxs) catch &.{}) else @as([]const u32, &.{});
        module.module_types.append(self.allocator, .{ .func_type = .{ .params = p_copy, .results = r_copy, .param_type_idxs = pt_copy, .result_type_idxs = rt_copy } }) catch {};
        return new_idx;
    }

    fn parseImport(self: *Parser, module: *Mod.Module) ParseError!void {
        self.skipAnnotations();
        const module_name = self.advance().text; // string literal
        self.skipAnnotations();
        const field_name = self.advance().text;
        // Strip quotes
        const mod_str = self.parseName(module_name);
        const field_str = self.parseName(field_name);

        self.skipAnnotations();
        try self.expect(.l_paren);
        self.skipAnnotations();
        const kind_tok = self.advance();

        var import = Mod.Import{
            .module_name = mod_str,
            .field_name = field_str,
            .kind = undefined,
        };

        switch (kind_tok.kind) {
            .kw_func => {
                import.kind = .func;
                const import_func_idx: u32 = @intCast(module.funcs.items.len);
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const fname = self.advance().text;
                    if (self.func_names.getOrPut(self.allocator, fname)) |gop| {
                        if (gop.found_existing and gop.value_ptr.* != import_func_idx) self.markMalformed(@src());
                        gop.value_ptr.* = import_func_idx;
                    } else |_| {}
                }
                var type_index: types.Index = 0;
                var has_explicit_type = false;
                var params_list: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer params_list.deinit(self.allocator);
                var results_list: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer results_list.deinit(self.allocator);
                var param_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
                defer param_tidxs_list.deinit(self.allocator);
                var result_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
                defer result_tidxs_list.deinit(self.allocator);
                self.skipAnnotations();
                while (self.peek().kind == .l_paren or self.peek().kind == .annotation) {
                    if (self.peek().kind == .annotation) {
                        _ = self.advance();
                        self.skipAnnotation() catch break;
                        continue;
                    }
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    self.skipAnnotations();
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        type_index = try self.parseTypeIdx();
                        has_explicit_type = true;
                        self.skipAnnotations();
                        try self.expect(.r_paren);
                    } else if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        self.skipAnnotations();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        self.skipAnnotations();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof and self.peek().kind != .annotation) {
                            const refs_before = self.collected_type_refs.items.len;
                            const saved_itp = self.in_type_parse;
                            self.in_type_parse = true;
                            const vt = self.parseValType() catch break;
                            self.in_type_parse = saved_itp;
                            params_list.append(self.allocator, vt) catch {};
                            param_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            self.skipAnnotations();
                        }
                        self.skipAnnotations();
                        try self.expect(.r_paren);
                    } else if (self.peek().kind == .kw_result) {
                        _ = self.advance();
                        self.skipAnnotations();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof and self.peek().kind != .annotation) {
                            const refs_before = self.collected_type_refs.items.len;
                            const saved_itp = self.in_type_parse;
                            self.in_type_parse = true;
                            const vt = self.parseValType() catch break;
                            self.in_type_parse = saved_itp;
                            results_list.append(self.allocator, vt) catch {};
                            result_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            self.skipAnnotations();
                        }
                        self.skipAnnotations();
                        try self.expect(.r_paren);
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        break;
                    }
                    self.skipAnnotations();
                }
                if (!has_explicit_type) {
                    const params = params_list.toOwnedSlice(self.allocator) catch &.{};
                    const results = results_list.toOwnedSlice(self.allocator) catch &.{};
                    const pt = param_tidxs_list.toOwnedSlice(self.allocator) catch &.{};
                    const rt = result_tidxs_list.toOwnedSlice(self.allocator) catch &.{};
                    type_index = @intCast(module.module_types.items.len);
                    module.module_types.append(self.allocator, .{
                        .func_type = .{ .params = params, .results = results, .param_type_idxs = pt, .result_type_idxs = rt },
                    }) catch {};
                }
                import.func = .{ .type_var = .{ .index = type_index } };
                try module.funcs.append(self.allocator, .{
                    .is_import = true,
                    .decl = .{ .type_var = .{ .index = type_index } },
                });
                module.num_func_imports += 1;
            },
            .kw_memory => {
                import.kind = .memory;
                const import_mem_idx: u32 = @intCast(module.memories.items.len);
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const mname = self.advance().text;
                    if (self.memory_names.get(mname)) |existing| {
                        if (existing != import_mem_idx and existing < import_mem_idx) self.markMalformed(@src());
                    }
                    self.memory_names.put(self.allocator, mname, import_mem_idx) catch {};
                }
                self.skipAnnotations();
                // Check for i64 keyword (memory64)
                var is_memory64 = false;
                if (self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_memory64 = true;
                }
                const limits = try self.parseLimitsTail(is_memory64);
                self.skipAnnotations();
                import.memory = .{ .limits = limits };
                try module.memories.append(self.allocator, .{
                    .type = .{ .limits = limits },
                    .is_import = true,
                });
                module.num_memory_imports += 1;
            },
            .kw_table => {
                import.kind = .table;
                const import_table_idx: u32 = @intCast(module.tables.items.len);
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const tname = self.advance().text;
                    if (self.table_names.get(tname)) |existing| {
                        if (existing != import_table_idx and existing < import_table_idx) self.markMalformed(@src());
                    }
                    self.table_names.put(self.allocator, tname, import_table_idx) catch {};
                }
                self.skipAnnotations();
                // Check for i64 keyword (table64)
                var is_table64 = false;
                if (self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_table64 = true;
                }
                const t_limits = try self.parseLimitsTail(is_table64);
                self.skipAnnotations();
                const indexed = try self.parseIndexedValType();
                self.skipAnnotations();
                try self.recordTableImport(
                    module,
                    &import,
                    .{ .elem_type = indexed.val_type, .limits = t_limits },
                    indexed.type_idx,
                    is_table64,
                );
            },
            .kw_global => {
                import.kind = .global;
                const import_global_idx: u32 = @intCast(module.globals.items.len);
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const gname = self.advance().text;
                    if (self.global_names.get(gname)) |existing| {
                        if (existing != import_global_idx and existing < import_global_idx) self.markMalformed(@src());
                    }
                    self.global_names.put(self.allocator, gname, import_global_idx) catch {};
                }
                self.skipAnnotations();
                const indexed = try self.parseIndexedGlobalType();
                self.skipAnnotations();
                try self.recordGlobalImport(
                    module,
                    &import,
                    indexed.global_type,
                    indexed.type_idx,
                );
            },
            .kw_tag => {
                import.kind = .tag;
                const import_tag_idx: u32 = @intCast(module.tags.items.len);
                if (self.peek().kind == .identifier) {
                    const tname = self.advance().text;
                    self.tag_names.put(self.allocator, tname, import_tag_idx) catch {};
                }
                var params_list: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer params_list.deinit(self.allocator);
                var results_list: std.ArrayListUnmanaged(types.ValType) = .empty;
                defer results_list.deinit(self.allocator);
                var param_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
                defer param_tidxs_list.deinit(self.allocator);
                var result_tidxs_list: std.ArrayListUnmanaged(u32) = .empty;
                defer result_tidxs_list.deinit(self.allocator);
                var imp_tag_type_idx: u32 = std.math.maxInt(u32);
                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const refs_before = self.collected_type_refs.items.len;
                            const vt = self.parseValType() catch break;
                            param_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            params_list.append(self.allocator, vt) catch {};
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else if (self.peek().kind == .kw_result) {
                        _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const refs_before = self.collected_type_refs.items.len;
                            const vt = self.parseValType() catch break;
                            result_tidxs_list.append(self.allocator, if (self.collected_type_refs.items.len > refs_before) self.collected_type_refs.items[refs_before] else 0xFFFFFFFF) catch {};
                            results_list.append(self.allocator, vt) catch {};
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        const tidx = self.parseTypeIdx() catch 0;
                        imp_tag_type_idx = tidx;
                        if (self.module) |mod| {
                            if (tidx < mod.module_types.items.len) {
                                switch (mod.module_types.items[tidx]) {
                                    .func_type => |ft| {
                                        for (ft.params) |p2| params_list.append(self.allocator, p2) catch {};
                                        for (ft.results) |r2| results_list.append(self.allocator, r2) catch {};
                                        for (ft.param_type_idxs) |ti| param_tidxs_list.append(self.allocator, ti) catch {};
                                        for (ft.result_type_idxs) |ti| result_tidxs_list.append(self.allocator, ti) catch {};
                                    },
                                    else => {},
                                }
                            }
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        break;
                    }
                }
                const params = params_list.toOwnedSlice(self.allocator) catch &.{};
                const results = results_list.toOwnedSlice(self.allocator) catch &.{};
                const param_tidxs = param_tidxs_list.toOwnedSlice(self.allocator) catch &.{};
                const result_tidxs = result_tidxs_list.toOwnedSlice(self.allocator) catch &.{};
                defer if (param_tidxs.len > 0) self.allocator.free(param_tidxs);
                defer if (result_tidxs.len > 0) self.allocator.free(result_tidxs);
                // See the inline-import path: the import section encodes a
                // signature index, so one has to exist in the type section.
                if (imp_tag_type_idx == std.math.maxInt(u32)) {
                    imp_tag_type_idx = self.findOrAddFuncTypeWithTidxs(module, params, results, param_tidxs, result_tidxs);
                }
                try module.tags.append(self.allocator, .{
                    .@"type" = .{ .sig = .{ .params = params, .results = results } },
                    .type_idx = imp_tag_type_idx,
                    .is_import = true,
                });
                module.num_tag_imports += 1;
            },
            else => try self.skipSExpr(),
        }

        // Consume remaining tokens in the desc
        while (self.peek().kind != .r_paren) {
            if (self.peek().kind == .annotation) {
                _ = self.advance();
                self.skipAnnotation() catch break;
            } else if (self.peek().kind == .l_paren) {
                _ = self.advance();
                try self.skipSExpr();
                try self.expect(.r_paren);
            } else if (self.peek().kind == .eof) {
                return error.InvalidModule;
            } else {
                _ = self.advance();
            }
        }
        self.skipAnnotations();
        try self.expect(.r_paren); // close the desc (func/memory/...)
        try module.imports.append(self.allocator, import);
    }

    fn parseExport(self: *Parser, module: *Mod.Module) ParseError!void {
        self.skipAnnotations();
        const name_tok = self.advance();
        const exp_name = self.parseName(name_tok.text);
        self.skipAnnotations();
        try self.expect(.l_paren);
        self.skipAnnotations();
        const kind_tok = self.advance();
        const kind: types.ExternalKind = switch (kind_tok.kind) {
            .kw_func => .func,
            .kw_memory => .memory,
            .kw_table => .table,
            .kw_global => .global,
            .kw_tag => .tag,
            else => return error.UnexpectedToken,
        };
        self.skipAnnotations();
        const index: u32 = switch (kind) {
            .func => try self.parseFuncIdx(),
            .global => try self.parseGlobalIdx(),
            .table => try self.parseTableIdx(),
            .memory => self.parseU32() catch 0,
            .tag => blk: {
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    break :blk self.tag_names.get(name) orelse 0;
                }
                break :blk self.parseU32() catch 0;
            },
        };
        self.skipAnnotations();
        try self.expect(.r_paren);
        self.skipAnnotations();
        try module.exports.append(self.allocator, .{
            .name = exp_name,
            .kind = kind,
            .var_ = .{ .index = index },
        });
    }

    fn parseStart(self: *Parser, module: *Mod.Module) ParseError!void {
        if (module.start_var != null) return error.InvalidModule;
        self.skipAnnotations();
        const index = try self.parseFuncIdx();
        self.skipAnnotations();
        module.start_var = .{ .index = index };
    }

    /// Read one entry of an elemlist written as a constant expression. The
    /// opening paren is already consumed and `inner_kind` is the token
    /// behind it, so both `(item expr)` and a bare folded expression arrive
    /// here. The `end` that terminates the expression in the binary is
    /// appended, as every consumer of `elem_expr_bytes` expects.
    ///
    /// `(elem ...)` and the `(table <reftype> (elem ...))` abbreviation both
    /// come through this, so the two spellings cannot drift apart: the same
    /// folded and unfolded forms, the same heap types, the same name
    /// resolution and the same errors.
    fn parseElemExprEntry(
        self: *Parser,
        seg: *Mod.ElemSegment,
        code: *std.ArrayListUnmanaged(u8),
        inner_kind: TokenKind,
    ) ParseError!void {
        const expr_start = code.items.len;
        if (inner_kind == .kw_item) {
            _ = self.advance(); // consume 'item'
            // item body: use parseInitExpr (flat form inside item)
            self.parseInitExpr(code);
        } else {
            // Direct folded expression (outer ( already consumed)
            // parseInitExprFolded consumes the closing )
            self.parseInitExprFolded(code);
        }
        try code.append(self.allocator, 0x0b);
        // `elem_var_indices` shadows the expressions with the function index
        // each one happens to name, and records a `ref.null` as an index no
        // function can have. It is lossy by construction, so it is kept only
        // for the consumers that predate the expression form.
        const expr_bytes = code.items[expr_start .. code.items.len - 1];
        if (expr_bytes.len >= 1 and expr_bytes[0] == 0xd2) {
            if (leb128.readU32Leb128(expr_bytes[1..])) |r| {
                seg.elem_var_indices.append(self.allocator, .{ .index = r.value }) catch {};
            } else |_| {}
        } else if (expr_bytes.len >= 1 and expr_bytes[0] == 0xd0) {
            seg.elem_var_indices.append(self.allocator, .{ .index = std.math.maxInt(u32) }) catch {};
        }
        if (inner_kind == .kw_item) try self.expect(.r_paren);
    }

    /// Read one entry of an elemlist written as a bare function index,
    /// either numeric or a name.
    fn parseElemFuncIdxEntry(self: *Parser, seg: *Mod.ElemSegment) ParseError!void {
        const idx = if (self.peek().kind == .identifier) blk: {
            const id_tok = self.advance();
            // Every function name in the module is known before the fields
            // are read, so a name still unresolved here is a name no
            // function has. Reading it as function 0 put a function in the
            // table that the module never named, exactly as `emitFuncIdx`
            // used to before it was made to reject the same mistake.
            break :blk self.lookupName(&self.func_names, id_tok.text) orelse {
                self.markMalformed(@src());
                break :blk 0;
            };
        } else try self.parseU32();
        try seg.elem_var_indices.append(self.allocator, .{ .index = idx });
    }

    /// Release what a half-built element segment owns. A segment only
    /// becomes the module's to free once it has been appended, so one
    /// abandoned by a failing parse has to be freed here.
    fn deinitElemSegment(self: *Parser, seg: *Mod.ElemSegment) void {
        seg.elem_var_indices.deinit(self.allocator);
        if (seg.owns_offset_expr_bytes and seg.offset_expr_bytes.len > 0)
            self.allocator.free(seg.offset_expr_bytes);
        if (seg.owns_elem_expr_bytes and seg.elem_expr_bytes.len > 0)
            self.allocator.free(seg.elem_expr_bytes);
    }

    fn parseElem(self: *Parser, module: *Mod.Module) ParseError!void {
        var seg = Mod.ElemSegment{};
        errdefer self.deinitElemSegment(&seg);
        const elem_idx: u32 = @intCast(module.elem_segments.items.len);
        self.skipAnnotations();
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            self.elem_names.put(self.allocator, name, elem_idx) catch {};
        }

        // Parse offset expression and elem indices
        seg.elem_var_indices = .empty;

        // Check for declarative/passive keywords
        self.skipAnnotations();
        if (self.peek().kind == .kw_declare) {
            _ = self.advance();
            seg.kind = .declared;
        }

        // Encode offset expression if present (active segment)
        var offset_code: std.ArrayListUnmanaged(u8) = .empty;
        defer offset_code.deinit(self.allocator);
        var has_offset = false;
        // Track elem type keyword presence for validation
        var has_elem_type = false;
        // Whether any element was written as a bare function index rather
        // than as an expression. The two forms encode differently, and a
        // segment that named a reference type uses expressions.
        var has_bare_index = false;
        // Encode elem expressions
        var elem_expr_code: std.ArrayListUnmanaged(u8) = .empty;
        defer elem_expr_code.deinit(self.allocator);
        var elem_expr_count: u32 = 0;

        self.skipAnnotations();
        while (self.peek().kind != .r_paren) {
            self.skipAnnotations();
            if (self.peek().kind == .r_paren) break;

            // An elemlist opens with the type of its elements, and every
            // reference type may be written there. Reading it before
            // anything else is what keeps `nullfuncref` or `(ref null $t)`
            // from being mistaken for the offset expression of an active
            // segment, and what keeps the type itself from being dropped.
            if (!has_elem_type) {
                if (self.parseRefTypeAnnotation()) |ref_type| {
                    seg.elem_type = ref_type.val_type;
                    seg.elem_type_idx = ref_type.type_idx;
                    has_elem_type = true;
                    continue;
                }
            }

            if (self.peek().kind == .l_paren) {
                const save_pos = self.lexer.pos;
                const save_peeked = self.peeked;
                _ = self.advance(); // consume '('

                const inner_kind = self.peek().kind;
                if (inner_kind == .kw_offset) {
                    _ = self.advance(); // consume 'offset'
                    self.parseInitExpr(&offset_code);
                    try self.expect(.r_paren);
                    has_offset = true;
                } else if (inner_kind == .kw_table) {
                    // (table $t) — record target table index
                    _ = self.advance(); // consume 'table'
                    if (self.peek().kind == .identifier) {
                        const ttok = self.advance();
                        seg.table_var = .{ .index = self.table_names.get(ttok.text) orelse 0 };
                    } else if (self.peek().kind == .integer) {
                        seg.table_var = .{ .index = self.parseU32() catch 0 };
                    }
                    seg.has_explicit_table_index = true;
                    if (self.peek().kind == .r_paren) _ = self.advance();
                } else if (has_elem_type) {
                    // Elements of a segment whose type has been named: each
                    // one is a constant expression, spelled `(item expr)` or
                    // as a bare folded expression.
                    try self.parseElemExprEntry(&seg, &elem_expr_code, inner_kind);
                    elem_expr_count += 1;
                } else if (!has_offset) {
                    // First folded expression is the offset expression
                    self.lexer.pos = save_pos;
                    self.peeked = save_peeked;
                    self.parseInitExprWrapped(&offset_code);
                    has_offset = true;
                } else {
                    // Post-offset without an element type: not an elemlist
                    // any grammar admits, so there is nothing to record.
                    try self.skipSExpr();
                    try self.expect(.r_paren);
                }
            } else if (self.peek().kind == .integer or self.peek().kind == .identifier) {
                try self.parseElemFuncIdxEntry(&seg);
                has_bare_index = true;
            } else if (self.peek().kind == .kw_func) {
                // The `func` short form: funcref elements written as plain
                // function indices, which is already the default type.
                _ = self.advance();
            } else if (self.peek().kind == .eof) {
                return error.InvalidModule;
            } else {
                _ = self.advance();
            }
        }

        if (has_offset) {
            seg.kind = .active;
            const owned = offset_code.toOwnedSlice(self.allocator) catch &.{};
            seg.offset_expr_bytes = owned;
            seg.owns_offset_expr_bytes = true;
        } else if (seg.kind != .declared) {
            // No offset → passive segment (or declared if only 'func' keyword)
            seg.kind = .passive;
        }

        // Naming a reference type is what makes the elements expressions
        // rather than function indices, whether or not there are any: an
        // empty segment still has to carry its type through to the binary.
        seg.uses_elem_exprs = has_elem_type and !has_bare_index;
        // The function-index forms infer `(ref func)`, not `funcref`.
        // Their encoding has no reftype field, so retain that inferred type
        // explicitly for validation and other IR consumers.
        if (!seg.uses_elem_exprs) {
            seg.elem_type = .ref_func;
            seg.elem_type_idx = types.invalid_index;
        }

        if (elem_expr_count > 0) {
            seg.elem_expr_bytes = elem_expr_code.toOwnedSlice(self.allocator) catch &.{};
            seg.owns_elem_expr_bytes = true;
            seg.elem_expr_count = elem_expr_count;
        }

        try module.elem_segments.append(self.allocator, seg);
    }

    fn parseData(self: *Parser, module: *Mod.Module) ParseError!void {
        var seg = Mod.DataSegment{};
        self.skipAnnotations();
        if (self.peek().kind == .identifier) _ = self.advance();

        // Parse offset expression
        var offset_code: std.ArrayListUnmanaged(u8) = .empty;
        defer offset_code.deinit(self.allocator);
        var has_offset = false;

        self.skipAnnotations();
        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('

            self.skipAnnotations();
            const inner_kind = self.peek().kind;
            if (inner_kind == .kw_offset) {
                _ = self.advance(); // consume 'offset'
                self.parseInitExpr(&offset_code);
                self.skipAnnotations();
                try self.expect(.r_paren);
                has_offset = true;
                self.skipAnnotations();
            } else if (inner_kind == .kw_memory) {
                // (memory $m) — resolve memory index
                _ = self.advance(); // consume 'memory'
                self.skipAnnotations();
                if (self.peek().kind == .identifier) {
                    const mtok = self.advance();
                    if (self.memory_names.get(mtok.text)) |idx| {
                        seg.memory_var = .{ .index = idx };
                    }
                } else if (self.peek().kind == .integer) {
                    const mtok = self.advance();
                    const idx = std.fmt.parseInt(u32, mtok.text, 0) catch 0;
                    seg.memory_var = .{ .index = idx };
                }
                self.skipAnnotations();
                try self.expect(.r_paren);
                self.skipAnnotations();
            } else if (!has_offset) {
                // First non-offset/memory parenthesized expr is the offset expression
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                self.parseInitExprWrapped(&offset_code);
                has_offset = true;
                self.skipAnnotations();
            } else {
                try self.skipSExpr();
                self.skipAnnotations();
                try self.expect(.r_paren);
                self.skipAnnotations();
            }
        }

        if (has_offset) {
            seg.kind = .active;
            const owned = offset_code.toOwnedSlice(self.allocator) catch &.{};
            seg.offset_expr_bytes = owned;
            seg.owns_offset_expr_bytes = true;
        } else {
            seg.kind = .passive;
        }

        // Read data string(s), decoding WAT escape sequences
        var data_parts: std.ArrayListUnmanaged(u8) = .empty;
        defer data_parts.deinit(self.allocator);
        self.skipAnnotations();
        while (self.peek().kind == .string) {
            const tok = self.advance();
            const stripped = stripQuotes(tok.text);
            decodeWatStringInto(stripped, &data_parts, self.allocator);
            self.skipAnnotations();
        }
        if (data_parts.items.len > 0) {
            seg.data = data_parts.toOwnedSlice(self.allocator) catch &.{};
            seg.owns_data = true;
        }

        try module.data_segments.append(self.allocator, seg);
    }

    fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            return text[1 .. text.len - 1];
        }
        return text;
    }

    /// Strip quotes and validate UTF-8 for names (exports, imports).
    fn parseName(self: *Parser, text: []const u8) []const u8 {
        const raw = stripQuotes(text);
        // Check if string contains escape sequences
        if (std.mem.indexOfScalar(u8, raw, '\\')) |_| {
            // Decode escape sequences and validate UTF-8
            const decoded = decodeWatString(self.allocator, raw);
            if (decoded.len > 0) {
                if (!std.unicode.utf8ValidateSlice(decoded)) {
                    self.markMalformed(@src());
                }
                if (self.module) |m| {
                    m.owned_strings.append(self.allocator, decoded) catch {};
                }
                return decoded;
            }
        }
        if (!std.unicode.utf8ValidateSlice(raw)) {
            self.markMalformed(@src());
        }
        return raw;
    }
};

/// Decode WAT string escape sequences (\nn hex, \t, \n, \r, \\, \").
fn decodeWatString(allocator: std.mem.Allocator, raw: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => { buf.append(allocator, '\n') catch return &.{}; i += 1; },
                't' => { buf.append(allocator, '\t') catch return &.{}; i += 1; },
                'r' => { buf.append(allocator, '\r') catch return &.{}; i += 1; },
                '\\' => { buf.append(allocator, '\\') catch return &.{}; i += 1; },
                '"' => { buf.append(allocator, '"') catch return &.{}; i += 1; },
                '\'' => { buf.append(allocator, '\'') catch return &.{}; i += 1; },
                else => {
                    // Try \xx hex escape
                    if (i + 1 < raw.len) {
                        const hi = hexVal(raw[i]);
                        const lo = hexVal(raw[i + 1]);
                        if (hi != null and lo != null) {
                            buf.append(allocator, hi.? * 16 + lo.?) catch return &.{};
                            i += 2;
                            continue;
                        }
                    }
                    buf.append(allocator, '\\') catch return &.{};
                    buf.append(allocator, raw[i]) catch return &.{};
                    i += 1;
                },
            }
        } else {
            buf.append(allocator, raw[i]) catch return &.{};
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator) catch return &.{};
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Decode WAT string escape sequences into an existing buffer (no allocation returned).
fn decodeWatStringInto(raw: []const u8, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            switch (raw[i]) {
                'n' => { out.append(allocator, '\n') catch {}; i += 1; },
                't' => { out.append(allocator, '\t') catch {}; i += 1; },
                'r' => { out.append(allocator, '\r') catch {}; i += 1; },
                '\\' => { out.append(allocator, '\\') catch {}; i += 1; },
                '"' => { out.append(allocator, '"') catch {}; i += 1; },
                '\'' => { out.append(allocator, '\'') catch {}; i += 1; },
                else => {
                    if (i + 1 < raw.len) {
                        const hi = hexVal(raw[i]);
                        const lo = hexVal(raw[i + 1]);
                        if (hi != null and lo != null) {
                            out.append(allocator, hi.? * 16 + lo.?) catch {};
                            i += 2;
                            continue;
                        }
                    }
                    out.append(allocator, '\\') catch {};
                    out.append(allocator, raw[i]) catch {};
                    i += 1;
                },
            }
        } else {
            out.append(allocator, raw[i]) catch {};
            i += 1;
        }
    }
}

/// Check if a token kind is a constant instruction (valid in init expressions).
fn isConstInstrToken(kind: TokenKind) bool {
    return switch (kind) {
        .kw_i32_const, .kw_i64_const, .kw_f32_const, .kw_f64_const,
        .kw_ref_null, .kw_ref_func, .kw_global_get => true,
        else => false,
    };
}

/// Strip WAT `_` digit separators from a number string.
/// Uses a stack buffer to avoid allocation.
const CleanNum = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    original: []const u8,

    fn slice(self: *const CleanNum) []const u8 {
        if (self.len == 0) return self.original;
        return self.buf[0..self.len];
    }
};

fn stripUnderscores(text: []const u8) CleanNum {
    // Quick check: if no underscores, return as-is
    if (std.mem.indexOfScalar(u8, text, '_') == null) {
        return .{ .original = text };
    }
    var result = CleanNum{ .original = text };
    for (text) |ch| {
        if (ch != '_' and result.len < result.buf.len) {
            result.buf[result.len] = ch;
            result.len += 1;
        }
    }
    return result;
}

/// Validate WAT number literal underscore placement.
/// Underscores are only valid between two hex/decimal digits.
/// Also rejects bare `0x`, truncated exponents (`0e`, `0e+`), etc.
fn isValidNumLiteral(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;

    // Skip optional sign
    if (text[i] == '+' or text[i] == '-') {
        i += 1;
        if (i >= text.len) return false;
    }

    // Handle nan/inf (always valid if we got here)
    const rest = text[i..];
    if (std.mem.startsWith(u8, rest, "nan") or std.mem.startsWith(u8, rest, "inf"))
        return true;

    // Check for hex prefix
    const is_hex = rest.len > 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X');
    if (is_hex) {
        i += 2; // skip "0x"
        if (i >= text.len or (!isHexChar(text[i]) and text[i] != '.'))
            return false; // bare "0x" or "0x_..."
    }

    // Walk remaining characters, check underscore rules and exponent completeness
    var prev_was_digit = false;
    var seen_digit_part = false;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '_') {
            if (!prev_was_digit) return false;
            if (i + 1 >= text.len) return false;
            const next = text[i + 1];
            const next_is_digit = if (is_hex) isHexChar(next) else (next >= '0' and next <= '9');
            if (!next_is_digit) return false;
            prev_was_digit = false;
        } else if ((is_hex and isHexChar(ch)) or (ch >= '0' and ch <= '9')) {
            prev_was_digit = true;
            seen_digit_part = true;
        } else if (ch == '.') {
            prev_was_digit = false;
        } else if (ch == 'e' or ch == 'E' or ch == 'p' or ch == 'P') {
            // Exponent marker: must be followed by optional sign then ≥1 digit
            i += 1;
            if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
            if (i >= text.len or (text[i] != '_' and text[i] < '0') or text[i] > '9')
                return false; // no digits after exponent
            prev_was_digit = true;
            seen_digit_part = true;
        } else {
            return false;
        }
    }
    return seen_digit_part;
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Validate float-type-specific rules: overflow to infinity, NaN payload constraints.
fn isValidFloatLiteral(comptime F: type, text: []const u8) bool {
    const mantissa_bits: comptime_int = if (F == f32) 23 else 52;
    const UInt = if (F == f32) u32 else u64;

    var i: usize = 0;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const after_sign = text[i..];

    // NaN payload validation
    if (std.mem.startsWith(u8, after_sign, "nan:")) {
        const payload_text = after_sign[4..];
        // Must be 0xN format
        if (!std.mem.startsWith(u8, payload_text, "0x")) return false;
        // Strip underscores and parse
        const clean = stripUnderscores(payload_text[2..]);
        const payload = std.fmt.parseInt(UInt, clean.slice(), 16) catch return false;
        // Payload must be non-zero and fit in mantissa
        if (payload == 0) return false;
        if (payload >= (@as(UInt, 1) << mantissa_bits)) return false;
        return true;
    }
    if (std.mem.eql(u8, after_sign, "nan") or std.mem.eql(u8, after_sign, "inf"))
        return true;

    // Check for overflow: parsed bits form infinity but input isn't inf
    const clean = stripUnderscores(text);
    const bits = parseFloatBits(F, clean.slice());
    const inf_bits: UInt = if (F == f32) 0x7f800000 else 0x7ff0000000000000;
    const mantissa_mask: UInt = (@as(UInt, 1) << mantissa_bits) - 1;
    // If exponent is all-1s and mantissa is 0, that's infinity
    if ((bits & ~(@as(UInt, 1) << @intCast(mantissa_bits + (if (F == f32) @as(comptime_int, 8) else 11)))) == inf_bits) {
        if ((bits & mantissa_mask) == 0) return false; // overflow to infinity
    }
    return true;
}

/// Parse a float literal and return its IEEE 754 bit pattern as u32.
fn parseF32Bits(text: []const u8) u32 {
    return parseFloatBits(f32, text);
}

/// Parse a float literal and return its IEEE 754 bit pattern as u64.
fn parseF64Bits(text: []const u8) u64 {
    return parseFloatBits(f64, text);
}

/// Generic float-literal-to-bits parser for f32 or f64.
pub fn parseFloatBits(comptime F: type, text: []const u8) if (F == f32) u32 else u64 {
    const UInt = if (F == f32) u32 else u64;
    const mantissa_bits: comptime_int = if (F == f32) 23 else 52;

    // Determine sign prefix length
    const sign_len: usize = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) 1 else 0;
    const negative = sign_len == 1 and text[0] == '-';
    const sign_bit: UInt = if (negative) @as(UInt, 1) << @intCast(mantissa_bits + (if (F == f32) @as(comptime_int, 8) else 11)) else 0;
    const after_sign = text[sign_len..];

    // NaN with payload: nan:0xN — exponent all-1s, mantissa = payload
    if (std.mem.startsWith(u8, after_sign, "nan:0x")) {
        const payload = std.fmt.parseInt(UInt, after_sign[6..], 16) catch 0;
        const nan_exp: UInt = if (F == f32) 0x7f800000 else 0x7ff0000000000000;
        const mantissa_mask: UInt = (@as(UInt, 1) << mantissa_bits) - 1;
        return sign_bit | nan_exp | (payload & mantissa_mask);
    }
    // Canonical NaN
    if (std.mem.eql(u8, after_sign, "nan")) {
        const canon: UInt = if (F == f32) 0x7fc00000 else 0x7ff8000000000000;
        return sign_bit | canon;
    }
    // Infinity
    if (std.mem.eql(u8, after_sign, "inf")) {
        const inf_bits: UInt = if (F == f32) 0x7f800000 else 0x7ff0000000000000;
        return sign_bit | inf_bits;
    }
    const clean = stripUnderscores(text);
    // Hex float/integer: use custom parser with correct round-to-nearest-even
    if (parseHexFloatBits(F, clean.slice())) |bits| return bits;
    // Decimal: std.fmt.parseFloat is correct for decimal literals
    const val = std.fmt.parseFloat(F, clean.slice()) catch 0.0;
    return @bitCast(val);
}

/// Parse a hex float literal (0x...) with correct round-to-nearest-even.
/// Returns null if text is not a hex float.
fn parseHexFloatBits(comptime F: type, text: []const u8) ?if (F == f32) u32 else u64 {
    const UInt = if (F == f32) u32 else u64;
    const mantissa_bits: comptime_int = if (F == f32) 23 else 52;
    const exp_bias: comptime_int = if (F == f32) 127 else 1023;
    const max_biased_exp: comptime_int = if (F == f32) 254 else 2046;
    const exp_field_bits: comptime_int = if (F == f32) 8 else 11;

    var pos: usize = 0;
    var negative = false;
    if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) {
        negative = text[pos] == '-';
        pos += 1;
    }
    if (pos + 1 >= text.len or text[pos] != '0') return null;
    if (text[pos + 1] != 'x' and text[pos + 1] != 'X') return null;
    pos += 2;

    var sig: u128 = 0;
    var sig_overflow_sticky: bool = false;
    var frac_hex_digits: i32 = 0;
    var in_frac = false;
    var saw_digit = false;

    while (pos < text.len) : (pos += 1) {
        if (text[pos] == '.') { in_frac = true; continue; }
        const d: u128 = hexDigitVal(text[pos]) orelse break;
        saw_digit = true;
        if ((sig >> 124) != 0) {
            sig_overflow_sticky = sig_overflow_sticky or (d != 0);
        } else {
            if (in_frac) frac_hex_digits += 1;
            sig = sig * 16 + d;
        }
    }
    if (!saw_digit) return null;

    // Parse binary exponent (p/P followed by decimal integer)
    var p_exp: i32 = 0;
    if (pos < text.len and (text[pos] == 'p' or text[pos] == 'P')) {
        pos += 1;
        var exp_neg = false;
        if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) {
            exp_neg = text[pos] == '-';
            pos += 1;
        }
        while (pos < text.len and text[pos] >= '0' and text[pos] <= '9') : (pos += 1) {
            p_exp = p_exp *| 10 +| @as(i32, @intCast(text[pos] - '0'));
        }
        if (exp_neg) p_exp = -p_exp;
    }

    const sign_bit: UInt = if (negative) @as(UInt, 1) << @intCast(mantissa_bits + exp_field_bits) else 0;
    if (sig == 0) return sign_bit;

    // Find MSB position
    var msb: u32 = 0;
    {
        var tmp = sig;
        while (tmp > 1) {
            tmp >>= 1;
            msb += 1;
        }
    }

    // Unbiased exponent: value = sig * 2^(p_exp - 4*frac_hex_digits)
    //                         = 1.xxx * 2^(msb + p_exp - 4*frac_hex_digits)
    const true_exp: i32 = @as(i32, @intCast(msb)) + p_exp - 4 * frac_hex_digits;

    // Overflow → infinity
    if (true_exp > max_biased_exp - exp_bias + 1) {
        return sign_bit | (@as(UInt, max_biased_exp + 1) << mantissa_bits);
    }
    // Extreme underflow → zero
    if (true_exp < 1 - exp_bias - mantissa_bits - 1) {
        return sign_bit;
    }

    var biased_exp: i32 = true_exp + exp_bias;
    var target_msb_pos: i32 = mantissa_bits;
    if (biased_exp <= 0) {
        // Subnormal range: reduce target position
        target_msb_pos += biased_exp - 1;
        biased_exp = 0;
    }

    const shift: i32 = @as(i32, @intCast(msb)) - target_msb_pos;
    var mantissa: UInt = undefined;
    var guard: bool = false;
    var sticky: bool = sig_overflow_sticky;

    if (shift > 0) {
        if (shift > @as(i32, @intCast(msb)) + 1) {
            // Guard bit is above all sig bits — value is too small to round up
            return sign_bit;
        }
        const s: u7 = @intCast(@as(u32, @intCast(shift)));
        mantissa = @truncate(sig >> @as(u7, s));
        guard = ((sig >> @as(u7, s - 1)) & 1) != 0;
        if (s >= 2) {
            const mask: u128 = (@as(u128, 1) << @as(u7, s - 1)) - 1;
            sticky = sticky or ((sig & mask) != 0);
        }
    } else if (shift == 0) {
        mantissa = @truncate(sig);
    } else {
        mantissa = @as(UInt, @truncate(sig)) << @intCast(@as(u32, @intCast(-shift)));
    }

    const mantissa_mask: UInt = (@as(UInt, 1) << mantissa_bits) - 1;
    var m: UInt = mantissa & mantissa_mask;

    // Round to nearest, ties to even
    if (guard) {
        if (sticky) {
            m += 1; // above midpoint
        } else if ((m & 1) != 0) {
            m += 1; // tie, round to even
        }
        if (m > mantissa_mask) {
            m = 0;
            biased_exp += 1;
            if (biased_exp > max_biased_exp) {
                return sign_bit | (@as(UInt, @intCast(max_biased_exp + 1)) << mantissa_bits);
            }
        }
    }

    return sign_bit | (@as(UInt, @intCast(biased_exp)) << mantissa_bits) | m;
}

fn hexDigitVal(c: u8) ?u128 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn opcodeFromText(text: []const u8) ?u32 {
    const map = std.StaticStringMap(u32).initComptime(.{
        // Reference
        .{ "ref.is_null", 0xd1 },
        .{ "ref.as_non_null", 0xd4 },
        .{ "ref.eq", 0xd3 },
        // Table
        .{ "table.get", 0x25 },
        .{ "table.set", 0x26 },
        // Memory load
        .{ "i32.load", 0x28 },
        .{ "i64.load", 0x29 },
        .{ "f32.load", 0x2a },
        .{ "f64.load", 0x2b },
        .{ "i32.load8_s", 0x2c },
        .{ "i32.load8_u", 0x2d },
        .{ "i32.load16_s", 0x2e },
        .{ "i32.load16_u", 0x2f },
        .{ "i64.load8_s", 0x30 },
        .{ "i64.load8_u", 0x31 },
        .{ "i64.load16_s", 0x32 },
        .{ "i64.load16_u", 0x33 },
        .{ "i64.load32_s", 0x34 },
        .{ "i64.load32_u", 0x35 },
        // Memory store
        .{ "i32.store", 0x36 },
        .{ "i64.store", 0x37 },
        .{ "f32.store", 0x38 },
        .{ "f64.store", 0x39 },
        .{ "i32.store8", 0x3a },
        .{ "i32.store16", 0x3b },
        .{ "i64.store8", 0x3c },
        .{ "i64.store16", 0x3d },
        .{ "i64.store32", 0x3e },
        // i32 comparison
        .{ "i32.eqz", 0x45 },
        .{ "i32.eq", 0x46 },
        .{ "i32.ne", 0x47 },
        .{ "i32.lt_s", 0x48 },
        .{ "i32.lt_u", 0x49 },
        .{ "i32.gt_s", 0x4a },
        .{ "i32.gt_u", 0x4b },
        .{ "i32.le_s", 0x4c },
        .{ "i32.le_u", 0x4d },
        .{ "i32.ge_s", 0x4e },
        .{ "i32.ge_u", 0x4f },
        // i64 comparison
        .{ "i64.eqz", 0x50 },
        .{ "i64.eq", 0x51 },
        .{ "i64.ne", 0x52 },
        .{ "i64.lt_s", 0x53 },
        .{ "i64.lt_u", 0x54 },
        .{ "i64.gt_s", 0x55 },
        .{ "i64.gt_u", 0x56 },
        .{ "i64.le_s", 0x57 },
        .{ "i64.le_u", 0x58 },
        .{ "i64.ge_s", 0x59 },
        .{ "i64.ge_u", 0x5a },
        // f32 comparison
        .{ "f32.eq", 0x5b },
        .{ "f32.ne", 0x5c },
        .{ "f32.lt", 0x5d },
        .{ "f32.gt", 0x5e },
        .{ "f32.le", 0x5f },
        .{ "f32.ge", 0x60 },
        // f64 comparison
        .{ "f64.eq", 0x61 },
        .{ "f64.ne", 0x62 },
        .{ "f64.lt", 0x63 },
        .{ "f64.gt", 0x64 },
        .{ "f64.le", 0x65 },
        .{ "f64.ge", 0x66 },
        // i32 arithmetic
        .{ "i32.clz", 0x67 },
        .{ "i32.ctz", 0x68 },
        .{ "i32.popcnt", 0x69 },
        .{ "i32.add", 0x6a },
        .{ "i32.sub", 0x6b },
        .{ "i32.mul", 0x6c },
        .{ "i32.div_s", 0x6d },
        .{ "i32.div_u", 0x6e },
        .{ "i32.rem_s", 0x6f },
        .{ "i32.rem_u", 0x70 },
        .{ "i32.and", 0x71 },
        .{ "i32.or", 0x72 },
        .{ "i32.xor", 0x73 },
        .{ "i32.shl", 0x74 },
        .{ "i32.shr_s", 0x75 },
        .{ "i32.shr_u", 0x76 },
        .{ "i32.rotl", 0x77 },
        .{ "i32.rotr", 0x78 },
        // i64 arithmetic
        .{ "i64.clz", 0x79 },
        .{ "i64.ctz", 0x7a },
        .{ "i64.popcnt", 0x7b },
        .{ "i64.add", 0x7c },
        .{ "i64.sub", 0x7d },
        .{ "i64.mul", 0x7e },
        .{ "i64.div_s", 0x7f },
        .{ "i64.div_u", 0x80 },
        .{ "i64.rem_s", 0x81 },
        .{ "i64.rem_u", 0x82 },
        .{ "i64.and", 0x83 },
        .{ "i64.or", 0x84 },
        .{ "i64.xor", 0x85 },
        .{ "i64.shl", 0x86 },
        .{ "i64.shr_s", 0x87 },
        .{ "i64.shr_u", 0x88 },
        .{ "i64.rotl", 0x89 },
        .{ "i64.rotr", 0x8a },
        // f32 arithmetic
        .{ "f32.abs", 0x8b },
        .{ "f32.neg", 0x8c },
        .{ "f32.ceil", 0x8d },
        .{ "f32.floor", 0x8e },
        .{ "f32.trunc", 0x8f },
        .{ "f32.nearest", 0x90 },
        .{ "f32.sqrt", 0x91 },
        .{ "f32.add", 0x92 },
        .{ "f32.sub", 0x93 },
        .{ "f32.mul", 0x94 },
        .{ "f32.div", 0x95 },
        .{ "f32.min", 0x96 },
        .{ "f32.max", 0x97 },
        .{ "f32.copysign", 0x98 },
        // f64 arithmetic
        .{ "f64.abs", 0x99 },
        .{ "f64.neg", 0x9a },
        .{ "f64.ceil", 0x9b },
        .{ "f64.floor", 0x9c },
        .{ "f64.trunc", 0x9d },
        .{ "f64.nearest", 0x9e },
        .{ "f64.sqrt", 0x9f },
        .{ "f64.add", 0xa0 },
        .{ "f64.sub", 0xa1 },
        .{ "f64.mul", 0xa2 },
        .{ "f64.div", 0xa3 },
        .{ "f64.min", 0xa4 },
        .{ "f64.max", 0xa5 },
        .{ "f64.copysign", 0xa6 },
        // Conversions
        .{ "i32.wrap_i64", 0xa7 },
        .{ "i32.trunc_f32_s", 0xa8 },
        .{ "i32.trunc_f32_u", 0xa9 },
        .{ "i32.trunc_f64_s", 0xaa },
        .{ "i32.trunc_f64_u", 0xab },
        .{ "i64.extend_i32_s", 0xac },
        .{ "i64.extend_i32_u", 0xad },
        .{ "i64.trunc_f32_s", 0xae },
        .{ "i64.trunc_f32_u", 0xaf },
        .{ "i64.trunc_f64_s", 0xb0 },
        .{ "i64.trunc_f64_u", 0xb1 },
        .{ "f32.convert_i32_s", 0xb2 },
        .{ "f32.convert_i32_u", 0xb3 },
        .{ "f32.convert_i64_s", 0xb4 },
        .{ "f32.convert_i64_u", 0xb5 },
        .{ "f32.demote_f64", 0xb6 },
        .{ "f64.convert_i32_s", 0xb7 },
        .{ "f64.convert_i32_u", 0xb8 },
        .{ "f64.convert_i64_s", 0xb9 },
        .{ "f64.convert_i64_u", 0xba },
        .{ "f64.promote_f32", 0xbb },
        .{ "i32.reinterpret_f32", 0xbc },
        .{ "i64.reinterpret_f64", 0xbd },
        .{ "f32.reinterpret_i32", 0xbe },
        .{ "f64.reinterpret_i64", 0xbf },
        // Sign extension
        .{ "i32.extend8_s", 0xc0 },
        .{ "i32.extend16_s", 0xc1 },
        .{ "i64.extend8_s", 0xc2 },
        .{ "i64.extend16_s", 0xc3 },
        .{ "i64.extend32_s", 0xc4 },
        // GC (0xfb prefix)
        .{ "ref.i31", 0xfb1c },
        .{ "i31.get_s", 0xfb1d },
        .{ "i31.get_u", 0xfb1e },
        .{ "struct.new", 0xfb00 },
        .{ "struct.new_default", 0xfb01 },
        .{ "struct.get", 0xfb02 },
        .{ "struct.get_s", 0xfb03 },
        .{ "struct.get_u", 0xfb04 },
        .{ "struct.set", 0xfb05 },
        .{ "array.new", 0xfb06 },
        .{ "array.new_default", 0xfb07 },
        .{ "array.new_fixed", 0xfb08 },
        .{ "array.new_data", 0xfb09 },
        .{ "array.new_elem", 0xfb0a },
        .{ "array.get", 0xfb0b },
        .{ "array.get_s", 0xfb0c },
        .{ "array.get_u", 0xfb0d },
        .{ "array.set", 0xfb0e },
        .{ "array.len", 0xfb0f },
        .{ "array.fill", 0xfb10 },
        .{ "array.copy", 0xfb11 },
        .{ "array.init_data", 0xfb12 },
        .{ "array.init_elem", 0xfb13 },
        .{ "any.convert_extern", 0xfb1a },
        .{ "extern.convert_any", 0xfb1b },
        // Saturating truncation (0xfc prefix)
        .{ "i32.trunc_sat_f32_s", 0xfc00 },
        .{ "i32.trunc_sat_f32_u", 0xfc01 },
        .{ "i32.trunc_sat_f64_s", 0xfc02 },
        .{ "i32.trunc_sat_f64_u", 0xfc03 },
        .{ "i64.trunc_sat_f32_s", 0xfc04 },
        .{ "i64.trunc_sat_f32_u", 0xfc05 },
        .{ "i64.trunc_sat_f64_s", 0xfc06 },
        .{ "i64.trunc_sat_f64_u", 0xfc07 },
        // Bulk memory (0xfc prefix)
        .{ "memory.init", 0xfc08 },
        .{ "data.drop", 0xfc09 },
        .{ "memory.copy", 0xfc0a },
        .{ "memory.fill", 0xfc0b },
        .{ "table.init", 0xfc0c },
        .{ "elem.drop", 0xfc0d },
        .{ "table.copy", 0xfc0e },
        .{ "table.grow", 0xfc0f },
        .{ "table.size", 0xfc10 },
        .{ "table.fill", 0xfc11 },
        // SIMD (0xfd prefix)
        .{ "v128.load", 0xfd00 },
        .{ "v128.load8x8_s", 0xfd01 },
        .{ "v128.load8x8_u", 0xfd02 },
        .{ "v128.load16x4_s", 0xfd03 },
        .{ "v128.load16x4_u", 0xfd04 },
        .{ "v128.load32x2_s", 0xfd05 },
        .{ "v128.load32x2_u", 0xfd06 },
        .{ "v128.load8_splat", 0xfd07 },
        .{ "v128.load16_splat", 0xfd08 },
        .{ "v128.load32_splat", 0xfd09 },
        .{ "v128.load64_splat", 0xfd0a },
        .{ "v128.store", 0xfd0b },
        // 0xfd0c = v128.const (handled separately)
        .{ "i8x16.shuffle", 0xfd0d },
        .{ "i8x16.swizzle", 0xfd0e },
        .{ "i8x16.splat", 0xfd0f },
        .{ "i16x8.splat", 0xfd10 },
        .{ "i32x4.splat", 0xfd11 },
        .{ "i64x2.splat", 0xfd12 },
        .{ "f32x4.splat", 0xfd13 },
        .{ "f64x2.splat", 0xfd14 },
        .{ "i8x16.extract_lane_s", 0xfd15 },
        .{ "i8x16.extract_lane_u", 0xfd16 },
        .{ "i8x16.replace_lane", 0xfd17 },
        .{ "i16x8.extract_lane_s", 0xfd18 },
        .{ "i16x8.extract_lane_u", 0xfd19 },
        .{ "i16x8.replace_lane", 0xfd1a },
        .{ "i32x4.extract_lane", 0xfd1b },
        .{ "i32x4.replace_lane", 0xfd1c },
        .{ "i64x2.extract_lane", 0xfd1d },
        .{ "i64x2.replace_lane", 0xfd1e },
        .{ "f32x4.extract_lane", 0xfd1f },
        .{ "f32x4.replace_lane", 0xfd20 },
        .{ "f64x2.extract_lane", 0xfd21 },
        .{ "f64x2.replace_lane", 0xfd22 },
        // i8x16 comparison
        .{ "i8x16.eq", 0xfd23 },
        .{ "i8x16.ne", 0xfd24 },
        .{ "i8x16.lt_s", 0xfd25 },
        .{ "i8x16.lt_u", 0xfd26 },
        .{ "i8x16.gt_s", 0xfd27 },
        .{ "i8x16.gt_u", 0xfd28 },
        .{ "i8x16.le_s", 0xfd29 },
        .{ "i8x16.le_u", 0xfd2a },
        .{ "i8x16.ge_s", 0xfd2b },
        .{ "i8x16.ge_u", 0xfd2c },
        // i16x8 comparison
        .{ "i16x8.eq", 0xfd2d },
        .{ "i16x8.ne", 0xfd2e },
        .{ "i16x8.lt_s", 0xfd2f },
        .{ "i16x8.lt_u", 0xfd30 },
        .{ "i16x8.gt_s", 0xfd31 },
        .{ "i16x8.gt_u", 0xfd32 },
        .{ "i16x8.le_s", 0xfd33 },
        .{ "i16x8.le_u", 0xfd34 },
        .{ "i16x8.ge_s", 0xfd35 },
        .{ "i16x8.ge_u", 0xfd36 },
        // i32x4 comparison
        .{ "i32x4.eq", 0xfd37 },
        .{ "i32x4.ne", 0xfd38 },
        .{ "i32x4.lt_s", 0xfd39 },
        .{ "i32x4.lt_u", 0xfd3a },
        .{ "i32x4.gt_s", 0xfd3b },
        .{ "i32x4.gt_u", 0xfd3c },
        .{ "i32x4.le_s", 0xfd3d },
        .{ "i32x4.le_u", 0xfd3e },
        .{ "i32x4.ge_s", 0xfd3f },
        .{ "i32x4.ge_u", 0xfd40 },
        // f32x4 comparison
        .{ "f32x4.eq", 0xfd41 },
        .{ "f32x4.ne", 0xfd42 },
        .{ "f32x4.lt", 0xfd43 },
        .{ "f32x4.gt", 0xfd44 },
        .{ "f32x4.le", 0xfd45 },
        .{ "f32x4.ge", 0xfd46 },
        // f64x2 comparison
        .{ "f64x2.eq", 0xfd47 },
        .{ "f64x2.ne", 0xfd48 },
        .{ "f64x2.lt", 0xfd49 },
        .{ "f64x2.gt", 0xfd4a },
        .{ "f64x2.le", 0xfd4b },
        .{ "f64x2.ge", 0xfd4c },
        // v128 bitwise
        .{ "v128.not", 0xfd4d },
        .{ "v128.and", 0xfd4e },
        .{ "v128.andnot", 0xfd4f },
        .{ "v128.or", 0xfd50 },
        .{ "v128.xor", 0xfd51 },
        .{ "v128.bitselect", 0xfd52 },
        .{ "v128.any_true", 0xfd53 },
        // v128.load*_lane / v128.store*_lane
        .{ "v128.load8_lane", 0xfd54 },
        .{ "v128.load16_lane", 0xfd55 },
        .{ "v128.load32_lane", 0xfd56 },
        .{ "v128.load64_lane", 0xfd57 },
        .{ "v128.store8_lane", 0xfd58 },
        .{ "v128.store16_lane", 0xfd59 },
        .{ "v128.store32_lane", 0xfd5a },
        .{ "v128.store64_lane", 0xfd5b },
        .{ "v128.load32_zero", 0xfd5c },
        .{ "v128.load64_zero", 0xfd5d },
        // f32x4 arithmetic
        .{ "f32x4.demote_f64x2_zero", 0xfd5e },
        .{ "f64x2.promote_low_f32x4", 0xfd5f },
        // i8x16 arithmetic
        .{ "i8x16.abs", 0xfd60 },
        .{ "i8x16.neg", 0xfd61 },
        .{ "i8x16.popcnt", 0xfd62 },
        .{ "i8x16.all_true", 0xfd63 },
        .{ "i8x16.bitmask", 0xfd64 },
        .{ "i8x16.narrow_i16x8_s", 0xfd65 },
        .{ "i8x16.narrow_i16x8_u", 0xfd66 },
        .{ "f32x4.ceil", 0xfd67 },
        .{ "f32x4.floor", 0xfd68 },
        .{ "f32x4.trunc", 0xfd69 },
        .{ "f32x4.nearest", 0xfd6a },
        .{ "f64x2.ceil", 0xfd74 },
        .{ "f64x2.floor", 0xfd75 },
        .{ "f64x2.trunc", 0xfd7a },
        .{ "f64x2.nearest", 0xfd94 },
        .{ "i8x16.shl", 0xfd6b },
        .{ "i8x16.shr_s", 0xfd6c },
        .{ "i8x16.shr_u", 0xfd6d },
        .{ "i8x16.add", 0xfd6e },
        .{ "i8x16.add_sat_s", 0xfd6f },
        .{ "i8x16.add_sat_u", 0xfd70 },
        .{ "i8x16.sub", 0xfd71 },
        .{ "i8x16.sub_sat_s", 0xfd72 },
        .{ "i8x16.sub_sat_u", 0xfd73 },
        .{ "i8x16.min_s", 0xfd76 },
        .{ "i8x16.min_u", 0xfd77 },
        .{ "i8x16.max_s", 0xfd78 },
        .{ "i8x16.max_u", 0xfd79 },
        .{ "i8x16.avgr_u", 0xfd7b },
        // i16x8 arithmetic
        .{ "i16x8.extadd_pairwise_i8x16_s", 0xfd7c },
        .{ "i16x8.extadd_pairwise_i8x16_u", 0xfd7d },
        .{ "i32x4.extadd_pairwise_i16x8_s", 0xfd7e },
        .{ "i32x4.extadd_pairwise_i16x8_u", 0xfd7f },
        .{ "i16x8.abs", 0xfd80 },
        .{ "i16x8.neg", 0xfd81 },
        .{ "i16x8.q15mulr_sat_s", 0xfd82 },
        .{ "i16x8.all_true", 0xfd83 },
        .{ "i16x8.bitmask", 0xfd84 },
        .{ "i16x8.narrow_i32x4_s", 0xfd85 },
        .{ "i16x8.narrow_i32x4_u", 0xfd86 },
        .{ "i16x8.extend_low_i8x16_s", 0xfd87 },
        .{ "i16x8.extend_high_i8x16_s", 0xfd88 },
        .{ "i16x8.extend_low_i8x16_u", 0xfd89 },
        .{ "i16x8.extend_high_i8x16_u", 0xfd8a },
        .{ "i16x8.shl", 0xfd8b },
        .{ "i16x8.shr_s", 0xfd8c },
        .{ "i16x8.shr_u", 0xfd8d },
        .{ "i16x8.add", 0xfd8e },
        .{ "i16x8.add_sat_s", 0xfd8f },
        .{ "i16x8.add_sat_u", 0xfd90 },
        .{ "i16x8.sub", 0xfd91 },
        .{ "i16x8.sub_sat_s", 0xfd92 },
        .{ "i16x8.sub_sat_u", 0xfd93 },
        .{ "i16x8.mul", 0xfd95 },
        .{ "i16x8.min_s", 0xfd96 },
        .{ "i16x8.min_u", 0xfd97 },
        .{ "i16x8.max_s", 0xfd98 },
        .{ "i16x8.max_u", 0xfd99 },
        .{ "i16x8.avgr_u", 0xfd9b },
        // i32x4 arithmetic
        .{ "i32x4.abs", 0xfda0 },
        .{ "i32x4.neg", 0xfda1 },
        .{ "i32x4.all_true", 0xfda3 },
        .{ "i32x4.bitmask", 0xfda4 },
        .{ "i32x4.extend_low_i16x8_s", 0xfda7 },
        .{ "i32x4.extend_high_i16x8_s", 0xfda8 },
        .{ "i32x4.extend_low_i16x8_u", 0xfda9 },
        .{ "i32x4.extend_high_i16x8_u", 0xfdaa },
        .{ "i32x4.shl", 0xfdab },
        .{ "i32x4.shr_s", 0xfdac },
        .{ "i32x4.shr_u", 0xfdad },
        .{ "i32x4.add", 0xfdae },
        .{ "i32x4.sub", 0xfdb1 },
        .{ "i32x4.mul", 0xfdb5 },
        .{ "i32x4.min_s", 0xfdb6 },
        .{ "i32x4.min_u", 0xfdb7 },
        .{ "i32x4.max_s", 0xfdb8 },
        .{ "i32x4.max_u", 0xfdb9 },
        .{ "i32x4.dot_i16x8_s", 0xfdba },
        // i64x2 arithmetic
        .{ "i64x2.abs", 0xfdc0 },
        .{ "i64x2.neg", 0xfdc1 },
        .{ "i64x2.all_true", 0xfdc3 },
        .{ "i64x2.bitmask", 0xfdc4 },
        .{ "i64x2.extend_low_i32x4_s", 0xfdc7 },
        .{ "i64x2.extend_high_i32x4_s", 0xfdc8 },
        .{ "i64x2.extend_low_i32x4_u", 0xfdc9 },
        .{ "i64x2.extend_high_i32x4_u", 0xfdca },
        .{ "i64x2.shl", 0xfdcb },
        .{ "i64x2.shr_s", 0xfdcc },
        .{ "i64x2.shr_u", 0xfdcd },
        .{ "i64x2.add", 0xfdce },
        .{ "i64x2.sub", 0xfdd1 },
        .{ "i64x2.mul", 0xfdd5 },
        .{ "i64x2.eq", 0xfdd6 },
        .{ "i64x2.ne", 0xfdd7 },
        .{ "i64x2.lt_s", 0xfdd8 },
        .{ "i64x2.gt_s", 0xfdd9 },
        .{ "i64x2.le_s", 0xfdda },
        .{ "i64x2.ge_s", 0xfddb },
        // f32x4 arithmetic
        .{ "f32x4.abs", 0xfde0 },
        .{ "f32x4.neg", 0xfde1 },
        .{ "f32x4.sqrt", 0xfde3 },
        .{ "f32x4.add", 0xfde4 },
        .{ "f32x4.sub", 0xfde5 },
        .{ "f32x4.mul", 0xfde6 },
        .{ "f32x4.div", 0xfde7 },
        .{ "f32x4.min", 0xfde8 },
        .{ "f32x4.max", 0xfde9 },
        .{ "f32x4.pmin", 0xfdea },
        .{ "f32x4.pmax", 0xfdeb },
        // f64x2 arithmetic
        .{ "f64x2.abs", 0xfdec },
        .{ "f64x2.neg", 0xfded },
        .{ "f64x2.sqrt", 0xfdef },
        .{ "f64x2.add", 0xfdf0 },
        .{ "f64x2.sub", 0xfdf1 },
        .{ "f64x2.mul", 0xfdf2 },
        .{ "f64x2.div", 0xfdf3 },
        .{ "f64x2.min", 0xfdf4 },
        .{ "f64x2.max", 0xfdf5 },
        .{ "f64x2.pmin", 0xfdf6 },
        .{ "f64x2.pmax", 0xfdf7 },
        // Conversions
        .{ "i32x4.trunc_sat_f32x4_s", 0xfdf8 },
        .{ "i32x4.trunc_sat_f32x4_u", 0xfdf9 },
        .{ "f32x4.convert_i32x4_s", 0xfdfa },
        .{ "f32x4.convert_i32x4_u", 0xfdfb },
        .{ "i32x4.trunc_sat_f64x2_s_zero", 0xfdfc },
        .{ "i32x4.trunc_sat_f64x2_u_zero", 0xfdfd },
        .{ "f64x2.convert_low_i32x4_s", 0xfdfe },
        .{ "f64x2.convert_low_i32x4_u", 0xfdff },
        // Extended multiply
        .{ "i16x8.extmul_low_i8x16_s", 0xfd9c },
        .{ "i16x8.extmul_high_i8x16_s", 0xfd9d },
        .{ "i16x8.extmul_low_i8x16_u", 0xfd9e },
        .{ "i16x8.extmul_high_i8x16_u", 0xfd9f },
        .{ "i32x4.extmul_low_i16x8_s", 0xfdbc },
        .{ "i32x4.extmul_high_i16x8_s", 0xfdbd },
        .{ "i32x4.extmul_low_i16x8_u", 0xfdbe },
        .{ "i32x4.extmul_high_i16x8_u", 0xfdbf },
        .{ "i64x2.extmul_low_i32x4_s", 0xfddc },
        .{ "i64x2.extmul_high_i32x4_s", 0xfddd },
        .{ "i64x2.extmul_low_i32x4_u", 0xfdde },
        .{ "i64x2.extmul_high_i32x4_u", 0xfddf },
        // Relaxed SIMD (0xfd prefix, sub-opcodes 0x100-0x113)
        .{ "i8x16.relaxed_swizzle", 0xfd_0100 },
        .{ "i32x4.relaxed_trunc_f32x4_s", 0xfd_0101 },
        .{ "i32x4.relaxed_trunc_f32x4_u", 0xfd_0102 },
        .{ "i32x4.relaxed_trunc_f64x2_s_zero", 0xfd_0103 },
        .{ "i32x4.relaxed_trunc_f64x2_u_zero", 0xfd_0104 },
        .{ "f32x4.relaxed_madd", 0xfd_0105 },
        .{ "f32x4.relaxed_nmadd", 0xfd_0106 },
        .{ "f64x2.relaxed_madd", 0xfd_0107 },
        .{ "f64x2.relaxed_nmadd", 0xfd_0108 },
        .{ "i8x16.relaxed_laneselect", 0xfd_0109 },
        .{ "i16x8.relaxed_laneselect", 0xfd_010a },
        .{ "i32x4.relaxed_laneselect", 0xfd_010b },
        .{ "i64x2.relaxed_laneselect", 0xfd_010c },
        .{ "f32x4.relaxed_min", 0xfd_010d },
        .{ "f32x4.relaxed_max", 0xfd_010e },
        .{ "f64x2.relaxed_min", 0xfd_010f },
        .{ "f64x2.relaxed_max", 0xfd_0110 },
        .{ "i16x8.relaxed_q15mulr_s", 0xfd_0111 },
        .{ "i16x8.relaxed_dot_i8x16_i7x16_s", 0xfd_0112 },
        .{ "i32x4.relaxed_dot_i8x16_i7x16_add_s", 0xfd_0113 },
    });
    return map.get(text) orelse generated_map.get(text);
}

/// The parser packs a prefixed opcode as `(prefix << 16) | sub`, while
/// `Opcode.Code` packs it as the binary format writes it. Convert.
/// Split a packed opcode into its prefix and sub-opcode.
///
/// Two packings are in use: the hand-written table above mostly writes
/// `(prefix << 8) | sub`, while `packForParser` writes `(prefix << 16) | sub`
/// so that sub-opcodes wider than a byte fit. Both are read here, so that
/// whichever table an opcode came from it is taken apart the same way.
fn unpackOpcode(op: u32) struct { prefix: u8, sub: u32 } {
    const high: u8 = @truncate(op >> 16);
    if (high != 0) return .{ .prefix = high, .sub = op & 0xffff };
    return .{ .prefix = @truncate(op >> 8), .sub = op & 0xff };
}

fn packForParser(raw: u32) u32 {
    if (raw <= 0xff) return raw;
    const prefix: u32 = if (raw <= 0xffff) raw >> 8 else raw >> 12;
    const sub: u32 = if (raw <= 0xffff) raw & 0xff else raw & 0xfff;
    return (prefix << 16) | sub;
}

/// Every opcode `Opcode.Code` can name, keyed by that name.
///
/// The table above is kept by hand and had drifted: it was missing all of
/// the threads atomics and the wide arithmetic, so the parser could not read
/// back text the writer had just printed. Deriving the rest from the same
/// enum the writer names instructions with means an opcode added there is
/// readable as well as printable, rather than only printable.
const generated_map = blk: {
    @setEvalBranchQuota(200000);
    const fields = @typeInfo(Opcode.Code).@"enum".fields;
    var entries: [fields.len]struct { []const u8, u32 } = undefined;
    var n: usize = 0;
    for (fields) |f| {
        const name = (@as(Opcode.Code, @enumFromInt(f.value))).name();
        if (std.mem.eql(u8, name, "<unknown>")) continue;
        entries[n] = .{ name, packForParser(f.value) };
        n += 1;
    }
    const final = entries[0..n].*;
    break :blk std.StaticStringMap(u32).initComptime(final);
};

// ── Tests ───────────────────────────────────────────────────────────────

test "parse empty module" {
    var module = try parseModule(std.testing.allocator, "(module)");
    defer module.deinit();
}

test "reject missing module keyword" {
    try std.testing.expectError(error.UnexpectedToken, parseModule(std.testing.allocator, "(func)"));
}

test "parse module with memory" {
    var module = try parseModule(std.testing.allocator, "(module (memory 1 256))");
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.memories.items.len);
    try std.testing.expectEqual(@as(u64, 1), module.memories.items[0].type.limits.initial);
    try std.testing.expectEqual(@as(u64, 256), module.memories.items[0].type.limits.max);
}

test "memory.size and memory.grow preserve numeric and named memory indices" {
    const allocator = std.testing.allocator;
    var module = try parseModule(allocator,
        \\(module
        \\  (memory $narrow 1)
        \\  (memory $wide i64 1)
        \\  (func (result i64) memory.size 1)
        \\  (func (result i64) i64.const 1 memory.grow $wide))
    );
    defer module.deinit();

    try std.testing.expectEqualSlices(u8, &.{ 0x3f, 0x01, 0x0b }, module.funcs.items[0].code_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x01, 0x40, 0x01, 0x0b }, module.funcs.items[1].code_bytes);
    try Validator.validate(&module, .{});

    try std.testing.expectError(error.InvalidModule, parseModule(allocator,
        \\(module (memory $known 1) (func memory.size $missing drop))
    ));
}

test "parse module with export" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (export "mem" (memory 0))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.exports.items.len);
    try std.testing.expect(std.mem.eql(u8, "mem", module.exports.items[0].name));
}

test "parse module with type" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (type (func (param i32) (result i32)))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.module_types.items.len);
}

test "parse module with import" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (import "env" "log" (func (type 0)))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.imports.items.len);
    try std.testing.expectEqual(@as(types.Index, 1), module.num_func_imports);
}

test "table and global import spellings preserve concrete reference indices" {
    const cases = [_]struct {
        source: []const u8,
        kind: types.ExternalKind,
    }{
        .{ .source = "(module (type $t (func)) (import \"m\" \"t\" (table 1 (ref null $t))))", .kind = .table },
        .{ .source = "(module (type $t (func)) (table (import \"m\" \"t\") 1 (ref null $t)))", .kind = .table },
        .{ .source = "(module (type (func)) (import \"m\" \"t\" (table 1 (ref null 0))))", .kind = .table },
        .{ .source = "(module (type (func)) (table (import \"m\" \"t\") 1 (ref null 0)))", .kind = .table },
        .{ .source = "(module (type $t (func)) (import \"m\" \"g\" (global (ref null $t))))", .kind = .global },
        .{ .source = "(module (type $t (func)) (global (import \"m\" \"g\") (ref null $t)))", .kind = .global },
        .{ .source = "(module (type (func)) (import \"m\" \"g\" (global (mut (ref null 0)))))", .kind = .global },
        .{ .source = "(module (type (func)) (global (import \"m\" \"g\") (mut (ref null 0))))", .kind = .global },
    };

    for (cases) |case| {
        var module = try parseModule(std.testing.allocator, case.source);
        defer module.deinit();
        const import = module.imports.items[0];
        try std.testing.expectEqual(case.kind, import.kind);
        switch (case.kind) {
            .table => {
                try std.testing.expectEqual(@as(u32, 0), import.table_type_idx);
                try std.testing.expectEqual(@as(u32, 0), module.tables.items[0].type_idx);
            },
            .global => {
                try std.testing.expectEqual(@as(u32, 0), import.global_type_idx);
                try std.testing.expectEqual(@as(u32, 0), module.globals.items[0].type_idx);
            },
            else => unreachable,
        }
    }
}

test "quoted type names resolve in imports and function signatures" {
    const import_cases = [_]struct {
        source: []const u8,
        kind: types.ExternalKind,
    }{
        .{
            .source = "(module (type $t (func)) (import \"m\" \"t\" (table 1 (ref null $\"t\"))))",
            .kind = .table,
        },
        .{
            .source = "(module (type $t (func)) (table (import \"m\" \"t\") 1 (ref null $\"t\")))",
            .kind = .table,
        },
        .{
            .source = "(module (type $t (func)) (import \"m\" \"g\" (global (mut (ref null $\"t\")))))",
            .kind = .global,
        },
        .{
            .source = "(module (type $t (func)) (global (import \"m\" \"g\") (ref null $\"t\")))",
            .kind = .global,
        },
    };

    for (import_cases) |case| {
        var module = try parseModule(std.testing.allocator, case.source);
        defer module.deinit();
        switch (case.kind) {
            .table => {
                try std.testing.expectEqual(@as(u32, 0), module.imports.items[0].table_type_idx);
                try std.testing.expectEqual(@as(u32, 0), module.tables.items[0].type_idx);
            },
            .global => {
                try std.testing.expectEqual(@as(u32, 0), module.imports.items[0].global_type_idx);
                try std.testing.expectEqual(@as(u32, 0), module.globals.items[0].type_idx);
            },
            else => unreachable,
        }
        try Validator.validate(&module, .{});
    }

    var function = try parseModule(std.testing.allocator,
        \\(module
        \\  (type $t (func))
        \\  (func (param (ref null $"t")) local.get 0 drop)
        \\)
    );
    defer function.deinit();
    const func_type_idx = function.funcs.items[0].decl.type_var.index;
    const func_type = function.module_types.items[func_type_idx].func_type;
    try std.testing.expectEqual(@as(u32, 0), func_type.param_type_idxs[0]);
    try Validator.validate(&function, .{});
}

test "undefined quoted concrete type names remain invalid" {
    const cases = [_][]const u8{
        "(module (import \"m\" \"t\" (table 1 (ref null $\"missing\"))))",
        "(module (import \"m\" \"g\" (global (ref null $\"missing\"))))",
        "(module (func (param (ref null $\"missing\"))))",
    };
    for (cases) |source| {
        try std.testing.expectError(error.InvalidModule, parseModule(std.testing.allocator, source));
    }
}

test "table and global import spellings reject invalid concrete reference indices" {
    const cases = [_][]const u8{
        "(module (type (func)) (import \"m\" \"t\" (table 1 (ref null 1))))",
        "(module (type (func)) (table (import \"m\" \"t\") 1 (ref null 1)))",
        "(module (type (func)) (import \"m\" \"g\" (global (ref null 1))))",
        "(module (type (func)) (global (import \"m\" \"g\") (ref null 1)))",
        "(module (import \"m\" \"t\" (table 1 (ref null $missing))))",
        "(module (table (import \"m\" \"t\") 1 (ref null $missing)))",
        "(module (import \"m\" \"g\" (global (ref null $missing))))",
        "(module (global (import \"m\" \"g\") (ref null $missing)))",
    };
    for (cases) |source| {
        try std.testing.expectError(error.InvalidModule, parseModule(std.testing.allocator, source));
    }
}

test "noexn global imports preserve nullability and mutability" {
    const cases = [_]struct {
        source: []const u8,
        val_type: types.ValType,
        mutability: types.Mutability,
    }{
        .{
            .source = "(module (import \"m\" \"g\" (global (ref noexn))))",
            .val_type = .ref_noexn,
            .mutability = .immutable,
        },
        .{
            .source = "(module (global (import \"m\" \"g\") (ref noexn)))",
            .val_type = .ref_noexn,
            .mutability = .immutable,
        },
        .{
            .source = "(module (import \"m\" \"g\" (global (mut (ref noexn)))))",
            .val_type = .ref_noexn,
            .mutability = .mutable,
        },
        .{
            .source = "(module (global (import \"m\" \"g\") (mut (ref noexn))))",
            .val_type = .ref_noexn,
            .mutability = .mutable,
        },
        .{
            .source = "(module (import \"m\" \"g\" (global (ref null noexn))))",
            .val_type = .nullexnref,
            .mutability = .immutable,
        },
        .{
            .source = "(module (global (import \"m\" \"g\") (mut (ref null noexn))))",
            .val_type = .nullexnref,
            .mutability = .mutable,
        },
    };

    for (cases) |case| {
        var module = try parseModule(std.testing.allocator, case.source);
        defer module.deinit();
        const global = module.globals.items[0];
        const import = module.imports.items[0];
        try std.testing.expectEqual(case.val_type, global.@"type".val_type);
        try std.testing.expectEqual(case.mutability, global.@"type".mutability);
        try std.testing.expectEqual(types.invalid_index, global.type_idx);
        try std.testing.expectEqual(types.invalid_index, import.global_type_idx);
        try Validator.validate(&module, .{});
    }
}

test "parse module with global" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (global (mut i32) (i32.const 42))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.globals.items.len);
    try std.testing.expectEqual(types.Mutability.mutable, module.globals.items[0].type.mutability);
}

test "parse module with start" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (func)
        \\  (start 0)
        \\)
    );
    defer module.deinit();
    try std.testing.expect(module.start_var != null);
}

test "parse (ref null func) as value type" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (global (ref null func) (ref.null func))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.globals.items.len);
    // (ref null func) is canonicalized to funcref (0x70)
    try std.testing.expectEqual(types.ValType.funcref, module.globals.items[0].type.val_type);
}

test "ref.null preserves named and abstract heap types" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (type $t (func))
        \\  (global (ref null $t) (ref.null $t))
        \\  (global funcref (ref.null func))
        \\  (global externref (ref.null extern))
        \\  (global anyref (ref.null any))
        \\)
    );
    defer module.deinit();

    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x00 }, module.globals.items[0].init_expr_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x70 }, module.globals.items[1].init_expr_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x6f }, module.globals.items[2].init_expr_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x6e }, module.globals.items[3].init_expr_bytes);
    try Validator.validate(&module, .{});
}

test "ref.null numeric heap type emits s33 and round trips" {
    const allocator = std.testing.allocator;
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(allocator);

    try source.appendSlice(allocator, "(module\n");
    for (0..65) |_| try source.appendSlice(allocator, "  (type (func))\n");
    try source.appendSlice(allocator,
        \\  (global (ref null 64) (ref.null 64))
        \\)
    );

    var module = try parseModule(allocator, source.items);
    defer module.deinit();
    // 64 is the first concrete heap type index whose signed LEB needs two
    // bytes. It must not be flattened to the one-byte `func` heap type.
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0xc0, 0x00 }, module.globals.items[0].init_expr_bytes);
    try Validator.validate(&module, .{});

    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);
    var reread = try binary_reader.readModule(allocator, wasm);
    defer reread.deinit();
    try Validator.validate(&reread, .{});

    const wat = try TextWriter.writeModule(allocator, &reread);
    defer allocator.free(wat);
    try std.testing.expect(std.mem.indexOf(u8, wat, "ref.null 64") != null);
}

test "ref.null numeric heap type works in a function body" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (type (func))
        \\  (func (result (ref null 0)) ref.null 0)
        \\)
    );
    defer module.deinit();

    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x00, 0x0b }, module.funcs.items[0].code_bytes);
    try Validator.validate(&module, .{});
}

test "ref.null rejects an out-of-range numeric heap type" {
    try std.testing.expectError(error.InvalidModule, parseModule(std.testing.allocator,
        \\(module
        \\  (type (func))
        \\  (func ref.null 1 drop)
        \\)
    ));
}

test "ref.null rejects numeric indices in the abstract heap type alias window" {
    try std.testing.expectError(error.InvalidModule, parseModule(std.testing.allocator,
        \\(module
        \\  (type (func))
        \\  (func ref.null 4294967280 drop)
        \\)
    ));
}

// ── Table initializers ──────────────────────────────────────────────────

test "a table initializer is read folded or unfolded" {
    // The text writer prints a constant expression unfolded, which is also
    // what `wasm-tools` prints, and the folded spelling is what a
    // hand-written module tends to use. Both name the same expression, so
    // both must produce the same bytes.
    const cases = [_]struct {
        unfolded: []const u8,
        folded: []const u8,
        init: []const u8,
    }{
        .{
            .unfolded = "(module (table 1 funcref ref.null func))",
            .folded = "(module (table 1 funcref (ref.null func)))",
            .init = &.{ 0xd0, 0x70 },
        },
        .{
            .unfolded = "(module (table 1 externref ref.null extern))",
            .folded = "(module (table 1 externref (ref.null extern)))",
            .init = &.{ 0xd0, 0x6f },
        },
        .{
            .unfolded = "(module (func) (table 3 funcref ref.func 0))",
            .folded = "(module (func) (table 3 funcref (ref.func 0)))",
            .init = &.{ 0xd2, 0x00 },
        },
        .{
            .unfolded = "(module (func $f) (func $g) (table 3 funcref ref.func $g))",
            .folded = "(module (func $f) (func $g) (table 3 funcref (ref.func $g)))",
            .init = &.{ 0xd2, 0x01 },
        },
        .{
            .unfolded = "(module (import \"m\" \"g\" (global externref)) (table 4 externref global.get 0))",
            .folded = "(module (import \"m\" \"g\" (global externref)) (table 4 externref (global.get 0)))",
            .init = &.{ 0x23, 0x00 },
        },
        .{
            .unfolded = "(module (import \"m\" \"g\" (global $g externref)) (table 4 externref global.get $g))",
            .folded = "(module (import \"m\" \"g\" (global $g externref)) (table 4 externref (global.get $g)))",
            .init = &.{ 0x23, 0x00 },
        },
        .{
            .unfolded = "(module (table $t 1 funcref ref.null func))",
            .folded = "(module (table $t 1 funcref (ref.null func)))",
            .init = &.{ 0xd0, 0x70 },
        },
        .{
            .unfolded = "(module (table i64 1 8 externref ref.null extern))",
            .folded = "(module (table i64 1 8 externref (ref.null extern)))",
            .init = &.{ 0xd0, 0x6f },
        },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;

        var unfolded = try parseModule(alloc, case.unfolded);
        defer unfolded.deinit();
        var folded = try parseModule(alloc, case.folded);
        defer folded.deinit();

        try std.testing.expectEqualSlices(u8, case.init, unfolded.tables.items[0].init_expr_bytes);
        try std.testing.expectEqualSlices(u8, case.init, folded.tables.items[0].init_expr_bytes);
        try Validator.validate(&unfolded, .{});
        try Validator.validate(&folded, .{});

        // Same module, so the same binary either way.
        const a = try binary_writer.writeModule(alloc, &unfolded);
        defer alloc.free(a);
        const b = try binary_writer.writeModule(alloc, &folded);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }
}

test "a table's ref.null initializer keeps the heap type the source names" {
    // The heap-type token was read and thrown away, and `funcref` written in
    // its place, so `(table 1 externref (ref.null extern))` silently became a
    // module that no longer validates.
    const cases = [_]struct { source: []const u8, init: []const u8 }{
        .{ .source = "(module (table 1 funcref ref.null func))", .init = &.{ 0xd0, 0x70 } },
        .{ .source = "(module (table 1 externref ref.null extern))", .init = &.{ 0xd0, 0x6f } },
        .{ .source = "(module (table 1 anyref ref.null any))", .init = &.{ 0xd0, 0x6e } },
        .{ .source = "(module (table 1 eqref ref.null eq))", .init = &.{ 0xd0, 0x6d } },
        .{ .source = "(module (table 1 i31ref ref.null i31))", .init = &.{ 0xd0, 0x6c } },
        .{ .source = "(module (table 1 structref ref.null struct))", .init = &.{ 0xd0, 0x6b } },
        .{ .source = "(module (table 1 arrayref ref.null array))", .init = &.{ 0xd0, 0x6a } },
        .{ .source = "(module (table 1 exnref ref.null exn))", .init = &.{ 0xd0, 0x69 } },
        .{ .source = "(module (table 1 nullref ref.null none))", .init = &.{ 0xd0, 0x71 } },
        .{ .source = "(module (table 1 nullfuncref ref.null nofunc))", .init = &.{ 0xd0, 0x73 } },
        .{ .source = "(module (table 1 nullexternref ref.null noextern))", .init = &.{ 0xd0, 0x72 } },
        .{ .source = "(module (table 1 nullexnref ref.null noexn))", .init = &.{ 0xd0, 0x74 } },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;

        var module = try parseModule(alloc, case.source);
        defer module.deinit();
        try std.testing.expectEqualSlices(u8, case.init, module.tables.items[0].init_expr_bytes);
        try Validator.validate(&module, .{});
    }
}

test "a table initializer names a concrete heap type by name or index" {
    const alloc = std.testing.allocator;

    var named = try parseModule(alloc,
        \\(module
        \\  (type $t (func))
        \\  (table 1 (ref null $t) ref.null $t)
        \\)
    );
    defer named.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x00 }, named.tables.items[0].init_expr_bytes);
    // The element type's own concrete index is not disturbed by the
    // initializer that follows it.
    try std.testing.expectEqual(@as(u32, 0), named.tables.items[0].type_idx);
    try std.testing.expectEqual(types.ValType.concrete_ref_null, named.tables.items[0].type.elem_type);
    try Validator.validate(&named, .{});

    var numbered = try parseModule(alloc,
        \\(module
        \\  (type (func))
        \\  (table 1 (ref null 0) ref.null 0)
        \\)
    );
    defer numbered.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x00 }, numbered.tables.items[0].init_expr_bytes);
    try std.testing.expectEqual(@as(u32, 0), numbered.tables.items[0].type_idx);
    try Validator.validate(&numbered, .{});
}

test "a table initializer's concrete heap type is an s33, not a byte" {
    const alloc = std.testing.allocator;

    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "(module\n");
    for (0..65) |_| try source.appendSlice(alloc, "  (type (func))\n");
    try source.appendSlice(alloc,
        \\  (table 1 (ref null 64) ref.null 64)
        \\)
    );

    var module = try parseModule(alloc, source.items);
    defer module.deinit();
    // 64 is the first concrete heap type index whose signed LEB needs two
    // bytes; a one-byte write would spell `func` instead.
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0xc0, 0x00 }, module.tables.items[0].init_expr_bytes);
    try std.testing.expectEqual(@as(u32, 64), module.tables.items[0].type_idx);
    try Validator.validate(&module, .{});

    const wasm = try binary_writer.writeModule(alloc, &module);
    defer alloc.free(wasm);
    var reread = try binary_reader.readModule(alloc, wasm);
    defer reread.deinit();
    try Validator.validate(&reread, .{});
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0xc0, 0x00 }, reread.tables.items[0].init_expr_bytes);
    try std.testing.expectEqual(@as(u32, 64), reread.tables.items[0].type_idx);
}

test "a table whose element type has no null states what it holds" {
    const alloc = std.testing.allocator;

    // A non-defaultable element type is exactly the case where the
    // initializer is not decoration: it is what makes the module legal.
    var abstract = try parseModule(alloc, "(module (func $f) (table 2 (ref func) ref.func $f))");
    defer abstract.deinit();
    try std.testing.expectEqual(types.ValType.ref_func, abstract.tables.items[0].type.elem_type);
    try std.testing.expectEqualSlices(u8, &.{ 0xd2, 0x00 }, abstract.tables.items[0].init_expr_bytes);
    try Validator.validate(&abstract, .{});

    var concrete = try parseModule(alloc,
        \\(module
        \\  (type $t (func))
        \\  (func $f (type $t))
        \\  (table 2 (ref $t) ref.func $f)
        \\)
    );
    defer concrete.deinit();
    try std.testing.expectEqual(types.ValType.concrete_ref, concrete.tables.items[0].type.elem_type);
    try std.testing.expectEqual(@as(u32, 0), concrete.tables.items[0].type_idx);
    try Validator.validate(&concrete, .{});

    // Without one there is nothing to fill the table with.
    var bare = try parseModule(alloc, "(module (func $f) (table 2 (ref func)))");
    defer bare.deinit();
    try std.testing.expectError(error.TypeMismatch, Validator.validate(&bare, .{}));

    // An imported table needs no initializer: whoever supplies it has
    // already filled it.
    var imported = try parseModule(alloc, "(module (import \"m\" \"t\" (table 1 (ref func))))");
    defer imported.deinit();
    try Validator.validate(&imported, .{});
}

test "a table initializer that does not suit the table is rejected" {
    // Each of these used to be accepted and quietly turned into something
    // else, or rejected for the wrong reason. None of them may pass.
    const cases = [_]struct { source: []const u8, err: anyerror }{
        // The heap type does not match the element type.
        .{ .source = "(module (table 1 funcref ref.null extern))", .err = error.TypeMismatch },
        .{ .source = "(module (table 1 externref (ref.null func)))", .err = error.TypeMismatch },
        // A number is not a reference.
        .{ .source = "(module (table 1 funcref i32.const 0))", .err = error.TypeMismatch },
        // Two values where one belongs.
        .{ .source = "(module (func) (table 1 funcref ref.func 0 ref.null func))", .err = error.TypeMismatch },
        // No function 0 to point at.
        .{ .source = "(module (table 1 funcref ref.func 0))", .err = error.InvalidFuncIndex },
        // Only an imported global is in scope: the table section comes
        // before the global section.
        .{
            .source = "(module (global $g externref (ref.null extern)) (table 1 externref global.get $g))",
            .err = error.InvalidGlobalIndex,
        },
        // A mutable global is not a constant.
        .{
            .source = "(module (import \"m\" \"g\" (global (mut externref))) (table 1 externref global.get 0))",
            .err = error.ConstantExprRequired,
        },
        // A constant expression holds constant instructions only.
        .{ .source = "(module (func) (table 1 funcref ref.func 0 drop))", .err = error.ConstantExprRequired },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;

        var module = try parseModule(alloc, case.source);
        defer module.deinit();
        try std.testing.expectError(case.err, Validator.validate(&module, .{}));
    }
}

test "a table initializer that is not an expression at all is malformed" {
    // Text that follows the element type but names no instruction is not an
    // initializer, and must not be dropped as though the table had none.
    try std.testing.expectError(
        error.InvalidModule,
        parseModule(std.testing.allocator, "(module (table 1 funcref bogus))"),
    );
}

test "a table initializer is encoded like a global's" {
    const alloc = std.testing.allocator;

    // Both go through the same constant-expression parser, so a form spelled
    // the same way in both places encodes the same way in both places --
    // including the folded GC forms that the table branch used to special
    // case for itself.
    var module = try parseModule(alloc,
        \\(module
        \\  (global $a anyref (ref.i31 (i32.const 5)))
        \\  (global $b anyref i32.const 5 ref.i31)
        \\  (table 1 anyref (ref.i31 (i32.const 5)))
        \\  (table 1 anyref i32.const 5 ref.i31)
        \\)
    );
    defer module.deinit();
    const expected = [_]u8{ 0x41, 0x05, 0xfb, 0x1c };
    try std.testing.expectEqualSlices(u8, &expected, module.globals.items[0].init_expr_bytes);
    try std.testing.expectEqualSlices(u8, &expected, module.globals.items[1].init_expr_bytes);
    try std.testing.expectEqualSlices(u8, &expected, module.tables.items[0].init_expr_bytes);
    try std.testing.expectEqualSlices(u8, &expected, module.tables.items[1].init_expr_bytes);
}

test "table initializers survive text, binary, text and binary again" {
    // The whole loop: the text the writer prints for a module carries the
    // initializer, parses back to the same bytes, and rebuilds the same
    // binary the module started as.
    const cases = [_]struct { source: []const u8, printed: []const u8 }{
        .{
            .source = "(module (table 1 funcref ref.null func))",
            .printed = "(table (;0;) 1 funcref ref.null func)",
        },
        .{
            .source = "(module (table 1 externref ref.null extern))",
            .printed = "(table (;0;) 1 externref ref.null extern)",
        },
        .{
            .source = "(module (table 1 arrayref ref.null array))",
            .printed = "(table (;0;) 1 arrayref ref.null array)",
        },
        .{
            .source = "(module (func) (table 3 funcref ref.func 0))",
            .printed = "(table (;0;) 3 funcref ref.func 0)",
        },
        .{
            .source = "(module (func $f) (table 2 (ref func) ref.func $f))",
            .printed = "(table (;0;) 2 (ref func) ref.func 0)",
        },
        .{
            .source = "(module (import \"m\" \"g\" (global externref)) (table 4 externref global.get 0))",
            .printed = "(table (;0;) 4 externref global.get 0)",
        },
        .{
            .source = "(module (table i64 1 8 externref ref.null extern))",
            .printed = "(table (;0;) i64 1 8 externref ref.null extern)",
        },
        .{
            .source = "(module (type $t (func)) (table 1 (ref null $t) ref.null $t))",
            .printed = "(table (;0;) 1 (ref null 0) ref.null 0)",
        },
        .{
            .source = "(module (type $t (func)) (func $f (type $t)) (table 1 (ref $t) ref.func $f))",
            .printed = "(table (;0;) 1 (ref 0) ref.func 0)",
        },
        .{
            .source = "(module (table 1 funcref) (table 1 externref ref.null extern))",
            .printed = "(table (;0;) 1 funcref)",
        },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;

        var parsed = try parseModule(alloc, case.source);
        defer parsed.deinit();
        try Validator.validate(&parsed, .{});

        const wasm = try binary_writer.writeModule(alloc, &parsed);
        defer alloc.free(wasm);
        var reread = try binary_reader.readModule(alloc, wasm);
        defer reread.deinit();
        try Validator.validate(&reread, .{});

        const table = parsed.tables.items[0];
        const round = reread.tables.items[0];
        try std.testing.expectEqualSlices(u8, table.init_expr_bytes, round.init_expr_bytes);
        try std.testing.expectEqual(table.type.elem_type, round.type.elem_type);
        try std.testing.expectEqual(table.type_idx, round.type_idx);
        try std.testing.expectEqual(table.type.limits.initial, round.type.limits.initial);
        try std.testing.expectEqual(table.type.limits.is_64, round.type.limits.is_64);

        // The binary the module came from is the binary it goes back to.
        const again = try binary_writer.writeModule(alloc, &reread);
        defer alloc.free(again);
        try std.testing.expectEqualSlices(u8, wasm, again);

        // The printed text says what the table holds...
        const wat = try TextWriter.writeModule(alloc, &reread);
        defer alloc.free(wat);
        try std.testing.expect(std.mem.indexOf(u8, wat, case.printed) != null);

        // ...and reads back as the module it was printed from.
        var reparsed = try parseModule(alloc, wat);
        defer reparsed.deinit();
        try Validator.validate(&reparsed, .{});
        const back = reparsed.tables.items[0];
        try std.testing.expectEqualSlices(u8, table.init_expr_bytes, back.init_expr_bytes);
        try std.testing.expectEqual(table.type.elem_type, back.type.elem_type);
        try std.testing.expectEqual(table.type_idx, back.type_idx);
        try std.testing.expectEqual(table.type.limits.initial, back.type.limits.initial);
        try std.testing.expectEqual(table.type.limits.is_64, back.type.limits.is_64);

        const from_text = try binary_writer.writeModule(alloc, &reparsed);
        defer alloc.free(from_text);
        try std.testing.expectEqualSlices(u8, wasm, from_text);
    }
}

test "a constant expression's ref.func names a function, not a local" {
    const alloc = std.testing.allocator;

    // `ref.func x` takes a funcidx. It went through the general immediate
    // reader, which tries labels and then locals first so that `br $l` and
    // `local.get $x` work -- and the local names of the function parsed
    // most recently are still in that map when a table's or a global's
    // initializer is read. Here `$y` is function 2 and is also the name of
    // the *parameter* of the function declared just before, so the
    // initializer used to be `ref.func 0`: a different function, silently.
    const cases = [_][]const u8{
        // Table, unfolded and folded, shadowed by a parameter and by a local.
        "(module (func $x) (func $z) (func $y) (func $a (param $y i32)) (table 1 funcref ref.func $y))",
        "(module (func $x) (func $z) (func $y) (func $a (param $y i32)) (table 1 funcref (ref.func $y)))",
        "(module (func $x) (func $z) (func $y) (func $a (local $y i32)) (table 1 funcref ref.func $y))",
        // Global, the same two spellings.
        "(module (func $x) (func $z) (func $y) (func $a (param $y i32)) (global funcref ref.func $y))",
        "(module (func $x) (func $z) (func $y) (func $a (local $y i32)) (global funcref (ref.func $y)))",
        // A label of the last function is not a function either.
        "(module (func $x) (func $z) (func $y) (func $a (block $y)) (table 1 funcref ref.func $y))",
    };

    for (cases) |source| {
        var module = try parseModule(alloc, source);
        defer module.deinit();
        const init = if (module.tables.items.len > 0)
            module.tables.items[0].init_expr_bytes
        else
            module.globals.items[0].init_expr_bytes;
        try std.testing.expectEqualSlices(u8, &.{ 0xd2, 0x02 }, init);
        try Validator.validate(&module, .{});
    }

    // A name no function has is malformed, not function 0.
    const undefined_names = [_][]const u8{
        "(module (func) (table 1 funcref ref.func $nope))",
        "(module (func) (table 1 funcref (ref.func $nope)))",
        "(module (func) (global funcref ref.func $nope))",
        "(module (func) (global funcref (ref.func $nope)))",
        "(module (func $a (param $y i32)) (table 1 funcref ref.func $y))",
        "(module (func $a (local $y i32)) (global funcref (ref.func $y)))",
    };
    for (undefined_names) |source| {
        try std.testing.expectError(error.InvalidModule, parseModule(alloc, source));
    }

    // Numeric indices are unaffected, and so is the rest of a function
    // body: a label is still a label and a local is still a local.
    var body = try parseModule(alloc,
        \\(module
        \\  (func $x)
        \\  (func $y)
        \\  (elem declare func $y)
        \\  (func $a (param $p i32) (result i32)
        \\    (block $l (br $l))
        \\    ref.func $y
        \\    drop
        \\    local.get $p)
        \\  (table 1 funcref ref.func 1)
        \\)
    );
    defer body.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xd2, 0x01 }, body.tables.items[0].init_expr_bytes);
    try Validator.validate(&body, .{});
}

test "a constant expression has no `end` to write" {
    // `expr ::= instr* end` puts the terminator in the encoding, not in the
    // text. Reading one as an instruction wrote a second `0x0b` after the
    // one every writer appends, and the module that came out had a section
    // whose size no longer matched its contents -- which the validator
    // could not see, because it stops reading at the first `end`.
    const rejected = [_][]const u8{
        "(module (global i32 i32.const 0 end))",
        "(module (global i32 (i32.const 0) end))",
        "(module (global i32 (i32.add (i32.const 1) end)))",
        "(module (table 1 funcref ref.null func end))",
        "(module (table 1 funcref (ref.null func) end))",
        "(module (func) (table 1 funcref ref.func 0 end))",
        "(module (memory 1) (data (offset i32.const 0 end) \"a\"))",
        "(module (func) (table 1 funcref) (elem (offset i32.const 0 end) func 0))",
    };
    for (rejected) |source| {
        try std.testing.expectError(error.InvalidModule, parseModule(std.testing.allocator, source));
    }

    // The same expressions without one are fine, and `end` keeps its
    // meaning inside a function body, where it closes a block.
    const accepted = [_][]const u8{
        "(module (global i32 i32.const 0))",
        "(module (table 1 funcref ref.null func))",
        "(module (memory 1) (data (offset i32.const 0) \"a\"))",
        "(module (func (result i32) block (result i32) i32.const 1 end))",
    };
    for (accepted) |source| {
        var module = try parseModule(std.testing.allocator, source);
        defer module.deinit();
        try Validator.validate(&module, .{});
    }
}

test "an inline element list is still an inline element list" {
    const alloc = std.testing.allocator;

    // `(table funcref (elem ...))` is an abbreviation for a table plus an
    // active segment, not a table with an initializer.
    var module = try parseModule(alloc,
        \\(module
        \\  (func $f)
        \\  (func $g)
        \\  (table funcref (elem $f $g))
        \\  (table 1 funcref)
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 2), module.tables.items.len);
    try std.testing.expectEqual(@as(u64, 2), module.tables.items[0].type.limits.initial);
    try std.testing.expectEqual(@as(usize, 0), module.tables.items[0].init_expr_bytes.len);
    try std.testing.expectEqual(@as(usize, 0), module.tables.items[1].init_expr_bytes.len);
    try std.testing.expectEqual(@as(usize, 1), module.elem_segments.items.len);
    try Validator.validate(&module, .{});
}

test "parse module with rec type group" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (rec (type (func)) (type (func (param i32))))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 2), module.module_types.items.len);
}

test "parse empty recursion groups keeps their ordering" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (rec)
        \\  (rec)
        \\  (type (func))
        \\  (rec)
        \\  (rec (type (func)))
        \\  (rec)
        \\  (rec)
        \\  (type (func))
        \\  (rec)
        \\)
    );
    defer module.deinit();

    const expected_positions = [_]u32{ 0, 0, 1, 2, 2, 3 };
    try std.testing.expectEqualSlices(u32, &expected_positions, module.empty_rec_group_positions.items);
    try std.testing.expectEqual(@as(usize, 3), module.module_types.items.len);
    try std.testing.expect(module.type_meta.items[1].in_rec_group);
}

test "recursion groups reject non-type members" {
    try std.testing.expectError(error.InvalidModule, parseModule(std.testing.allocator,
        \\(module (rec (func)))
    ));
}

test "parse module with anyref global" {
    var module = try parseModule(std.testing.allocator,
        \\(module
        \\  (global anyref (ref.null any))
        \\)
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.globals.items.len);
    try std.testing.expectEqual(types.ValType.anyref, module.globals.items[0].type.val_type);
}

test "parse module with annotation" {
    var module = try parseModule(std.testing.allocator,
        \\(module (@name "test") (memory 1))
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.memories.items.len);
}

test "memory load emits correct memarg without extra mem_idx byte" {
    // i32.load should emit: opcode(0x28) + align(LEB u32) + offset(LEB u32)
    // NOT: opcode(0x28) + mem_idx(0x00) + align + offset
    const allocator = std.testing.allocator;
    var module = try parseModule(allocator,
        \\(module (memory 1) (func (export "f") (result i32) (i32.load (i32.const 0))))
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.funcs.items.len);
    const code = module.funcs.items[0].code_bytes;
    // Expected: i32.const 0 (41 00), i32.load align=2 offset=0 (28 02 00), end (0b)
    // Total: 6 bytes
    try std.testing.expectEqual(@as(usize, 6), code.len);
    try std.testing.expectEqual(@as(u8, 0x41), code[0]); // i32.const
    try std.testing.expectEqual(@as(u8, 0x00), code[1]); // 0
    try std.testing.expectEqual(@as(u8, 0x28), code[2]); // i32.load
    // Omitting `align=` means the natural alignment, and i32.load is 4 wide.
    try std.testing.expectEqual(@as(u8, 0x02), code[3]); // align=4
    try std.testing.expectEqual(@as(u8, 0x00), code[4]); // offset=0
    try std.testing.expectEqual(@as(u8, 0x0b), code[5]); // end
}

test "memory store emits correct memarg" {
    const allocator = std.testing.allocator;
    var module = try parseModule(allocator,
        \\(module (memory 1) (func (export "f") (i32.store (i32.const 0) (i32.const 42))))
    );
    defer module.deinit();
    const code = module.funcs.items[0].code_bytes;
    // i32.const 0 (41 00), i32.const 42 (41 2a), i32.store align=2 offset=0 (36 02 00), end (0b)
    try std.testing.expectEqual(@as(usize, 8), code.len);
    try std.testing.expectEqual(@as(u8, 0x36), code[4]); // i32.store
    // Omitting `align=` means the natural alignment, and i32.store is 4 wide.
    try std.testing.expectEqual(@as(u8, 0x02), code[5]); // align=4
    try std.testing.expectEqual(@as(u8, 0x00), code[6]); // offset=0
    try std.testing.expectEqual(@as(u8, 0x0b), code[7]); // end
}

test "memory load with explicit offset and align" {
    const allocator = std.testing.allocator;
    var module = try parseModule(allocator,
        \\(module (memory 1) (func (export "f") (result i32) (i32.load offset=8 align=4 (i32.const 0))))
    );
    defer module.deinit();
    const code = module.funcs.items[0].code_bytes;
    // i32.const 0 (41 00), i32.load align=log2(4)=2 offset=8 (28 02 08), end (0b)
    try std.testing.expectEqual(@as(usize, 6), code.len);
    try std.testing.expectEqual(@as(u8, 0x28), code[2]); // i32.load
    try std.testing.expectEqual(@as(u8, 0x02), code[3]); // align=2 (log2(4))
    try std.testing.expectEqual(@as(u8, 0x08), code[4]); // offset=8
    try std.testing.expectEqual(@as(u8, 0x0b), code[5]); // end
}

test "v128.store has correct memarg encoding (no extra mem_idx)" {
    var module = try parseModule(std.testing.allocator,
        \\(module (memory 1) (func (v128.store (i32.const 0) (v128.const i32x4 0 0 0 0))))
    );
    defer module.deinit();
    const code = module.funcs.items[0].code_bytes;
    // Find v128.store opcode (fd 0b)
    var found = false;
    for (0..code.len) |i| {
        if (i + 1 < code.len and code[i] == 0xfd and code[i + 1] == 0x0b) {
            // Next two bytes should be memarg: align, offset=0. Omitting
            // `align=` means the natural alignment, and v128.store is 16
            // wide, so its align_log2 is 4.
            try std.testing.expectEqual(@as(u8, 0x04), code[i + 2]); // align=16
            try std.testing.expectEqual(@as(u8, 0x00), code[i + 3]); // offset
            // Byte after offset should be end (0x0b) — NOT another 0x00
            try std.testing.expectEqual(@as(u8, 0x0b), code[i + 4]); // end
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

/// Normalize a WAT identifier token text for name-map lookups.
/// For plain identifiers like `$foo`, returns the text unchanged.
/// For quoted identifiers like `$"\41B"`, decodes escapes and returns `$` + decoded.
/// The result is allocated from `allocator` when decoding is needed; the caller
/// must free it.  When no decoding is needed the returned slice points directly
/// into `text`.
fn normalizeIdentifier(allocator: std.mem.Allocator, text: []const u8) []const u8 {
    // Must start with '$' and have at least `$"x"`
    if (text.len < 4 or text[0] != '$' or text[1] != '"') return text;
    // Must end with '"'
    if (text[text.len - 1] != '"') return text;
    // Decode the content between the quotes
    const inner = text[2 .. text.len - 1]; // content between $" and "
    // Quick check: if no backslash, just wrap as $<inner>
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
        // "$foo" equivalent to $foo — construct $<inner>
        var buf = allocator.alloc(u8, inner.len + 1) catch return text;
        buf[0] = '$';
        @memcpy(buf[1..], inner);
        return buf;
    }
    // Has escapes — decode them
    var result = std.ArrayListUnmanaged(u8).empty;
    result.append(allocator, '$') catch return text;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            const next = inner[i + 1];
            if (next == 'n') { result.append(allocator, '\n') catch {}; i += 2; }
            else if (next == 't') { result.append(allocator, '\t') catch {}; i += 2; }
            else if (next == 'r') { result.append(allocator, '\r') catch {}; i += 2; }
            else if (next == '\\') { result.append(allocator, '\\') catch {}; i += 2; }
            else if (next == '"') { result.append(allocator, '"') catch {}; i += 2; }
            else if (next == '\'') { result.append(allocator, '\'') catch {}; i += 2; }
            else if (next == 'u' and i + 2 < inner.len and inner[i + 2] == '{') {
                // \u{XXXX} Unicode escape
                i += 3; // skip \u{
                var codepoint: u21 = 0;
                while (i < inner.len and inner[i] != '}') : (i += 1) {
                    const hd = hexDigitVal(inner[i]);
                    if (hd) |d| { codepoint = codepoint * 16 + @as(u21, @intCast(d)); } else break;
                }
                if (i < inner.len and inner[i] == '}') i += 1; // skip }
                // Encode as UTF-8
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                result.appendSlice(allocator, utf8_buf[0..utf8_len]) catch {};
            } else {
                // \xx hex escape
                if (i + 2 < inner.len) {
                    const h1 = hexDigitVal(inner[i + 1]);
                    const h2 = hexDigitVal(inner[i + 2]);
                    if (h1 != null and h2 != null) {
                        const byte_val: u8 = @intCast(h1.? * 16 + h2.?);
                        result.append(allocator, byte_val) catch {};
                        i += 3;
                        continue;
                    }
                }
                result.append(allocator, '\\') catch {};
                result.append(allocator, next) catch {};
                i += 2;
            }
        } else {
            result.append(allocator, inner[i]) catch {};
            i += 1;
        }
    }
    return result.toOwnedSlice(allocator) catch text;
}

/// Expected `ref.test`/`ref.cast` heaptype operand bytes, captured from
/// `wasm-tools parse` output. A heaptype is the s33 LEB128 of the *negative*
/// spec heap code, so every abstract heap type is a single byte.
const spec_heaptype_operand_bytes = [_]struct { types.AbstractHeapType, u8 }{
    .{ .func, 0x70 },
    .{ .extern_, 0x6f },
    .{ .any, 0x6e },
    .{ .eq, 0x6d },
    .{ .i31, 0x6c },
    .{ .struct_, 0x6b },
    .{ .array, 0x6a },
    .{ .exn, 0x69 },
    .{ .none, 0x71 },
    .{ .nofunc, 0x73 },
    .{ .noextern, 0x72 },
    .{ .noexn, 0x74 },
};

test "ref.test emits a single-byte heaptype for every abstract heap type" {
    const allocator = std.testing.allocator;
    inline for (spec_heaptype_operand_bytes) |entry| {
        const name = switch (entry[0]) {
            .extern_ => "extern",
            .struct_ => "struct",
            else => @tagName(entry[0]),
        };
        inline for (.{ .{ "", @as(u8, 0x14) }, .{ "null ", @as(u8, 0x15) } }) |form| {
            const src = "(module (func (param anyref) local.get 0 ref.test (ref " ++
                form[0] ++ name ++ ") drop))";
            var module = try parseModule(allocator, src);
            defer module.deinit();
            const code = module.funcs.items[0].code_bytes;
            // local.get 0 (20 00), then fb <sub_op> <heaptype>
            try std.testing.expectEqualSlices(u8, &.{ 0xfb, form[1], entry[1] }, code[2..5]);
        }
    }
}

test "ref.cast emits a single-byte heaptype for bare reference keywords" {
    const allocator = std.testing.allocator;
    // Bare keywords are the nullable shorthand, so ref.cast uses sub-opcode 0x17.
    inline for (.{
        .{ "funcref", @as(u8, 0x70) },
        .{ "externref", @as(u8, 0x6f) },
        .{ "anyref", @as(u8, 0x6e) },
        .{ "eqref", @as(u8, 0x6d) },
        .{ "i31ref", @as(u8, 0x6c) },
        .{ "structref", @as(u8, 0x6b) },
        .{ "arrayref", @as(u8, 0x6a) },
        .{ "exnref", @as(u8, 0x69) },
        .{ "nullref", @as(u8, 0x71) },
        .{ "nullfuncref", @as(u8, 0x73) },
        .{ "nullexternref", @as(u8, 0x72) },
        .{ "nullexnref", @as(u8, 0x74) },
    }) |entry| {
        const src = "(module (func (param anyref) local.get 0 ref.cast " ++ entry[0] ++ " drop))";
        var module = try parseModule(allocator, src);
        defer module.deinit();
        const code = module.funcs.items[0].code_bytes;
        try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0x17, entry[1] }, code[2..5]);
    }
}

test "ref.cast emits concrete type indices distinctly from abstract heap types" {
    const allocator = std.testing.allocator;
    // Concrete index 0 is a single 0x00 byte, not confusable with any abstract code.
    var by_index = try parseModule(allocator,
        \\(module (type $t (func)) (func (param funcref) local.get 0 ref.cast (ref 0) drop))
    );
    defer by_index.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0x16, 0x00 }, by_index.funcs.items[0].code_bytes[2..5]);

    var by_name = try parseModule(allocator,
        \\(module (type $t (func)) (func (param funcref) local.get 0 ref.cast (ref $t) drop))
    );
    defer by_name.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0x16, 0x00 }, by_name.funcs.items[0].code_bytes[2..5]);

    // Index 112 shares the byte pattern that the abstract `func` code would have
    // been double-encoded into; the two must not collide.
    var big = try parseModule(allocator,
        \\(module (type $t (func)) (func (param funcref) local.get 0 ref.cast (ref 112) drop))
    );
    defer big.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0x16, 0xf0, 0x00 }, big.funcs.items[0].code_bytes[2..6]);
}

test "parsing a tag frees the concrete type indices it collects" {
    // `Tag` has no slots for the per-parameter concrete type indices, and
    // `findOrAddFuncTypeWithTidxs` copies them into `module_types`, so the
    // originals are owned by nobody once the tag is appended. They were
    // leaked, which `std.testing.allocator` fails on -- but only if a test
    // actually parses a tag with parameters, which none did.
    const allocator = std.testing.allocator;
    var defined = try parseModule(allocator,
        \\(module (tag $a (param i32 i64)))
    );
    defer defined.deinit();
    try std.testing.expectEqual(@as(usize, 1), defined.tags.items.len);
    try std.testing.expectEqualSlices(
        types.ValType,
        &.{ .i32, .i64 },
        defined.tags.items[0].@"type".sig.params,
    );

    // The `(type $t)` form takes a different path to the same slices.
    var by_type = try parseModule(allocator,
        \\(module (type $t (func (param f64))) (tag $a (type $t)))
    );
    defer by_type.deinit();
    try std.testing.expectEqual(@as(u32, 0), by_type.tags.items[0].type_idx);
    try std.testing.expectEqualSlices(
        types.ValType,
        &.{.f64},
        by_type.tags.items[0].@"type".sig.params,
    );
}

test "an imported tag with an inline signature registers a type" {
    // The import section encodes a signature *index*, so a tag import needs
    // an entry in the type section just as much as a defined tag does.
    // Neither imported-tag path registered one, so `type_idx` stayed
    // `maxInt` and the module referred to a type that was never emitted.
    const allocator = std.testing.allocator;

    var inline_form = try parseModule(allocator,
        \\(module (tag $a (import "m" "t") (param i32 i64)))
    );
    defer inline_form.deinit();
    try std.testing.expect(inline_form.tags.items[0].is_import);
    try std.testing.expect(inline_form.tags.items[0].type_idx != std.math.maxInt(u32));
    try std.testing.expectEqualSlices(
        types.ValType,
        &.{ .i32, .i64 },
        inline_form.module_types.items[inline_form.tags.items[0].type_idx].func_type.params,
    );

    var desc_form = try parseModule(allocator,
        \\(module (import "m" "t" (tag $a (param f32))))
    );
    defer desc_form.deinit();
    try std.testing.expect(desc_form.tags.items[0].type_idx != std.math.maxInt(u32));
    try std.testing.expectEqualSlices(
        types.ValType,
        &.{.f32},
        desc_form.module_types.items[desc_form.tags.items[0].type_idx].func_type.params,
    );
}

test "an imported tag reuses an existing matching type rather than adding one" {
    const allocator = std.testing.allocator;
    var mod = try parseModule(allocator,
        \\(module (type $t (func (param i32))) (import "m" "t" (tag $a (param i32))))
    );
    defer mod.deinit();
    try std.testing.expectEqual(@as(usize, 1), mod.module_types.items.len);
    try std.testing.expectEqual(@as(u32, 0), mod.tags.items[0].type_idx);
}

test "a tag import after a defined tag is rejected" {
    // A defined tag closes the import prologue, exactly as a defined
    // func/table/memory/global does. Accepting the interleaving left
    // `module.tags` in source order while the binary writer emits every
    // import first, so a `throw $t` in the text and the same `throw` in the
    // output named different tags.
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidModule, parseModule(allocator,
        \\(module (tag $a (param i32)) (import "m" "t" (tag $b (param f32))))
    ));

    // The prologue itself is unaffected: imports before definitions are
    // still fine, and the index space is imports-first.
    var ok = try parseModule(allocator,
        \\(module (import "m" "t" (tag $b (param f32))) (tag $a (param i32)))
    );
    defer ok.deinit();
    try std.testing.expectEqual(@as(u32, 1), ok.num_tag_imports);
    try std.testing.expect(ok.tags.items[0].is_import);
    try std.testing.expect(!ok.tags.items[1].is_import);
}

test "function types differing only in a concrete type index are not folded together" {
    // `(ref $a)` and `(ref $b)` are the same `ValType`, so a structural
    // search that compared value types alone reported the first as a match
    // for the second and handed back an index describing a different
    // signature. Two tags is the shortest way to reach the search twice.
    const allocator = std.testing.allocator;
    var mod = try parseModule(allocator,
        \\(module (type $a (func)) (type $b (func (param i32)))
        \\  (tag $e (param (ref $a))) (tag $f (param (ref $b))))
    );
    defer mod.deinit();
    try std.testing.expect(mod.tags.items[0].type_idx != mod.tags.items[1].type_idx);
    try std.testing.expectEqual(
        @as(u32, 0),
        mod.module_types.items[mod.tags.items[0].type_idx].func_type.param_type_idxs[0],
    );
    try std.testing.expectEqual(
        @as(u32, 1),
        mod.module_types.items[mod.tags.items[1].type_idx].func_type.param_type_idxs[0],
    );

    // Identical signatures must still share one entry.
    var shared = try parseModule(allocator,
        \\(module (tag $e (param i32)) (tag $f (param i32)))
    );
    defer shared.deinit();
    try std.testing.expectEqual(shared.tags.items[0].type_idx, shared.tags.items[1].type_idx);
}

test "a try_table catch label is resolved outside the try_table" {
    // `try_table`'s own label belongs to its body, not to its catch clauses:
    // a clause's label index counts from the enclosing context. Pushing the
    // label before parsing the clauses shifted every one of them by one.
    const allocator = std.testing.allocator;
    var flat = try parseModule(allocator,
        \\(module (tag $e) (func block $outer try_table (catch_all $outer) nop end end))
    );
    defer flat.deinit();
    // 0x02 0x40 block, 0x1f 0x40 try_table, 0x01 one clause, 0x02 catch_all,
    // then the label depth.
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00 },
        flat.funcs.items[0].code_bytes[0..7],
    );

    var folded = try parseModule(allocator,
        \\(module (tag $e) (func (block $outer (try_table (catch_all $outer) (nop)))))
    );
    defer folded.deinit();
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00 },
        folded.funcs.items[0].code_bytes[0..7],
    );

    // The body is still inside the new scope, so a `br` in it sees
    // try_table at depth 0 and the block at depth 1.
    var inner = try parseModule(allocator,
        \\(module (tag $e) (func (block $outer (try_table (catch_all $outer) (br $outer)))))
    );
    defer inner.deinit();
    const code = inner.funcs.items[0].code_bytes;
    try std.testing.expectEqualSlices(u8, &.{ 0x0c, 0x01 }, code[7..9]);
}

test "two functions whose params differ only in the referenced type get different types" {
    // `(ref $a)` and `(ref $b)` are the same `ValType`, so deduplicating a
    // function declaration on value types alone gave the second function the
    // first one's signature -- a module that still validates, with a
    // different meaning than the source.
    const allocator = std.testing.allocator;
    var m = try parseModule(allocator,
        \\(module
        \\  (type $a (func (param i32)))
        \\  (type $b (func (param f64)))
        \\  (func (param (ref $a)) (unreachable))
        \\  (func (param (ref $b)) (unreachable))
        \\)
    );
    defer m.deinit();
    const f0 = m.funcs.items[0].decl.type_var.index;
    const f1 = m.funcs.items[1].decl.type_var.index;
    try std.testing.expect(f0 != f1);
    try std.testing.expectEqual(@as(u32, 0), m.module_types.items[f0].func_type.param_type_idxs[0]);
    try std.testing.expectEqual(@as(u32, 1), m.module_types.items[f1].func_type.param_type_idxs[0]);

    // Results are matched the same way.
    var r = try parseModule(allocator,
        \\(module
        \\  (type $a (func (param i32)))
        \\  (type $b (func (param f64)))
        \\  (func (result (ref $a)) (unreachable))
        \\  (func (result (ref $b)) (unreachable))
        \\)
    );
    defer r.deinit();
    try std.testing.expect(r.funcs.items[0].decl.type_var.index != r.funcs.items[1].decl.type_var.index);

    // Two functions that really do share a signature must still share a type.
    var same = try parseModule(allocator,
        \\(module
        \\  (type $a (func (param i32)))
        \\  (func (param (ref $a)) (unreachable))
        \\  (func (param (ref $a)) (unreachable))
        \\)
    );
    defer same.deinit();
    try std.testing.expectEqual(same.funcs.items[0].decl.type_var.index, same.funcs.items[1].decl.type_var.index);
}

test "an inline signature must agree with its type reference about referenced types" {
    // `(func (type $t) (param ...))` restates the signature; the restatement
    // has to match, and the concrete type a reference points at is part of it.
    const allocator = std.testing.allocator;
    const mismatch =
        \\(module
        \\  (type $a (func (param i32)))
        \\  (type $b (func (param f64)))
        \\  (type $t (func (param (ref $a))))
        \\  (func (type $t) (param (ref $b)) (unreachable))
        \\)
    ;
    try std.testing.expectError(error.InvalidModule, parseModule(allocator, mismatch));

    const result_mismatch =
        \\(module
        \\  (type $a (func (param i32)))
        \\  (type $b (func (param f64)))
        \\  (type $t (func (result (ref $a))))
        \\  (func (type $t) (result (ref $b)) (unreachable))
        \\)
    ;
    try std.testing.expectError(error.InvalidModule, parseModule(allocator, result_mismatch));

    // The matching restatement is still accepted.
    var ok = try parseModule(allocator,
        \\(module
        \\  (type $a (func (param i32)))
        \\  (type $t (func (param (ref $a))))
        \\  (func (type $t) (param (ref $a)) (unreachable))
        \\)
    );
    defer ok.deinit();
    try std.testing.expectEqual(@as(u32, 1), ok.funcs.items[0].decl.type_var.index);
}

test "a memory or table states shared and its page size in every position" {
    const allocator = std.testing.allocator;
    // Limits are accepted in six places -- a plain table or memory, either
    // written with an inline `(import ...)` or listed under an `(import ...)`
    // -- and a form the writer emits in one of them has to be accepted in all
    // of them, or printing a module produces text this parser rejects.
    var m = try parseModule(allocator,
        \\(module
        \\  (import "a" "b" (memory i64 1 2 shared))
        \\  (import "c" "d" (table 3 4 funcref))
        \\  (memory (import "e" "f") 5 6 shared)
        \\  (table (import "g" "h") i64 7 8 funcref)
        \\  (memory 9 10 shared)
        \\  (table i64 11 12 funcref)
        \\)
    );
    defer m.deinit();

    try std.testing.expect(m.memories.items[0].type.limits.is_64);
    try std.testing.expect(m.memories.items[0].type.limits.is_shared);
    try std.testing.expectEqual(@as(u64, 2), m.memories.items[0].type.limits.max);
    try std.testing.expect(m.memories.items[1].type.limits.is_shared);
    try std.testing.expectEqual(@as(u64, 6), m.memories.items[1].type.limits.max);
    try std.testing.expect(m.memories.items[2].type.limits.is_shared);
    try std.testing.expectEqual(@as(u64, 10), m.memories.items[2].type.limits.max);

    try std.testing.expectEqual(@as(u64, 4), m.tables.items[0].type.limits.max);
    try std.testing.expect(m.tables.items[1].type.limits.is_64);
    try std.testing.expectEqual(@as(u64, 8), m.tables.items[1].type.limits.max);
    try std.testing.expect(m.tables.items[2].type.limits.is_64);
    try std.testing.expectEqual(@as(u64, 12), m.tables.items[2].type.limits.max);

    // A page size is stated as the size itself, not as its log2.
    var ps = try parseModule(allocator,
        \\(module
        \\  (memory 1 (pagesize 1))
        \\  (memory 2 (pagesize 0x10000))
        \\)
    );
    defer ps.deinit();
    try std.testing.expectEqual(@as(u32, 1), ps.memories.items[0].type.limits.page_size);
    try std.testing.expectEqual(@as(u32, 0x10000), ps.memories.items[1].type.limits.page_size);
    // The bounds are still the bounds, not the page size.
    try std.testing.expectEqual(@as(u64, 1), ps.memories.items[0].type.limits.initial);
    try std.testing.expectEqual(@as(u64, 2), ps.memories.items[1].type.limits.initial);
}

test "a parsed table initializer is released with its module" {
    const allocator = std.testing.allocator;
    var module = try parseModule(
        allocator,
        \\(module (table 1 funcref (ref.null func)))
    );
    defer module.deinit();

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xd0, 0x70 },
        module.tables.items[0].init_expr_bytes,
    );
    try std.testing.expect(module.tables.items[0].owns_init_expr_bytes);
}

test "a page size survives being written back out" {
    const allocator = std.testing.allocator;
    // The binary writer never emitted the page size, so a memory read with
    // one lost it on the way back out and became a 64 KiB memory.
    var m = try parseModule(allocator, "(module (memory 1 (pagesize 1)))");
    defer m.deinit();

    const bytes = try @import("../binary/writer.zig").writeModule(allocator, &m);
    defer allocator.free(bytes);

    var back = try @import("../binary/reader.zig").readModule(allocator, bytes);
    defer back.deinit();
    try std.testing.expectEqual(@as(u32, 1), back.memories.items[0].type.limits.page_size);

    // A memory that never stated one keeps the default and gains no flag.
    var d = try parseModule(allocator, "(module (memory 1))");
    defer d.deinit();
    const dbytes = try @import("../binary/writer.zig").writeModule(allocator, &d);
    defer allocator.free(dbytes);
    var dback = try @import("../binary/reader.zig").readModule(allocator, dbytes);
    defer dback.deinit();
    try std.testing.expectEqual(types.default_page_size, dback.memories.items[0].type.limits.page_size);
    try std.testing.expectEqual(bytes.len - 1, dbytes.len);
}

test "a rejected module says where it was rejected and by what" {
    const allocator = std.testing.allocator;
    // `error.InvalidModule` is raised by any of some seventy checks, so on its
    // own it says only that something was wrong. Without a position, finding
    // out which means deleting lines from the input one at a time.
    const source =
        \\(module
        \\  (func $a)
        \\  (func $a)
        \\)
    ;
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.InvalidModule, parseModuleDiag(allocator, source, &diagnostic));

    const d = diagnostic orelse return error.TestUnexpectedResult;
    const pos = d.position(source);
    try std.testing.expectEqual(@as(u32, 3), pos.line);
    try std.testing.expectEqual(@as(u32, 9), pos.column);
    try std.testing.expectEqualStrings("  (func $a)", d.sourceLine(source));
    try std.testing.expectEqualStrings("parseFunc", d.check);
    try std.testing.expect(d.parser_line > 0);

    // The plain entry point still works and still rejects the same module.
    try std.testing.expectError(error.InvalidModule, parseModule(allocator, source));

    // A module that is fine leaves the diagnostic alone.
    var ok_diag: ?Diagnostic = null;
    var m = try parseModuleDiag(allocator, "(module (func $a))", &ok_diag);
    defer m.deinit();
    try std.testing.expect(ok_diag == null);
}

test "the first thing noticed is the one reported" {
    const allocator = std.testing.allocator;
    // Later marks are usually consequences of the first, so a report that kept
    // the last one would point past the actual problem.
    const source =
        \\(module
        \\  (func $x)
        \\  (func $x)
        \\  (func $y)
        \\  (func $y)
        \\)
    ;
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.InvalidModule, parseModuleDiag(allocator, source, &diagnostic));
    const d = diagnostic orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), d.position(source).line);
}

test "a position on the first line, and one past the end, still resolve" {
    const source = "(module\n  (func)\n)";
    const first = Diagnostic{ .offset = 0, .check = "x", .parser_line = 1 };
    try std.testing.expectEqual(@as(u32, 1), first.position(source).line);
    try std.testing.expectEqual(@as(u32, 1), first.position(source).column);
    try std.testing.expectEqualStrings("(module", first.sourceLine(source));

    // An offset at or past the end must not read out of bounds.
    const past = Diagnostic{ .offset = source.len + 10, .check = "x", .parser_line = 1 };
    try std.testing.expectEqual(@as(u32, 3), past.position(source).line);
    try std.testing.expectEqualStrings(")", past.sourceLine(source));
}

test "every mnemonic the writer can print, the parser can read back" {
    // The parser's table of mnemonics was kept by hand while the writer named
    // instructions from `Opcode.Code`, so the two drifted: 104 modules across
    // the test corpora printed fine and were then rejected on reparse, every
    // one of them for a name the writer knew and the parser did not. Deriving
    // the parser's names from the same enum is what stops that recurring, and
    // this is the test that holds the two together.
    var missing: usize = 0;
    var wrong: usize = 0;
    inline for (@typeInfo(Opcode.Code).@"enum".fields) |f| {
        const code: Opcode.Code = @enumFromInt(f.value);
        const name = code.name();
        if (!std.mem.eql(u8, name, "<unknown>")) {
            if (opcodeFromText(name)) |got| {
                // Resolving is not enough; it has to resolve to this opcode.
                // `select` is the one name two members share, and the
                // hand-written entry for it is the one that must win.
                // Compare what the parser makes of the two, not the packed
                // words: an opcode reached through the hand-written table is
                // packed differently from one reached through the generated
                // one, and both unpack to the same instruction.
                const want = unpackOpcode(packForParser(f.value));
                const have = unpackOpcode(got);
                if ((have.prefix != want.prefix or have.sub != want.sub) and
                    !std.mem.eql(u8, name, "select"))
                {
                    std.debug.print("{s}: got {x}/{x}, expected {x}/{x}\n", .{
                        name, have.prefix, have.sub, want.prefix, want.sub,
                    });
                    wrong += 1;
                }
            } else {
                std.debug.print("no mnemonic for {s}\n", .{name});
                missing += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
    try std.testing.expectEqual(@as(usize, 0), wrong);

    // `select` resolves to the untyped form, not to `select_t`, which shares
    // its name but takes a type immediate.
    try std.testing.expectEqual(@as(u32, 0x1b), opcodeFromText("select").?);
}

test "a threads opcode carries the immediate the validator says it does" {
    const allocator = std.testing.allocator;
    // Which immediate a 0xfe opcode takes was decided here by `sub >= 0x10`,
    // which is wrong twice over: it gave `atomic.fence` a memarg instead of
    // its reserved byte, and it gave notify and wait no immediate at all.
    var m = try parseModule(allocator,
        \\(module
        \\  (memory 1 1 shared)
        \\  (func
        \\    atomic.fence
        \\    i32.const 0
        \\    i32.atomic.load
        \\    drop
        \\    i32.const 0
        \\    i64.atomic.load8_u
        \\    drop))
    );
    defer m.deinit();

    try std.testing.expectEqualSlices(u8, &.{
        // atomic.fence takes a single reserved zero byte, not a memarg.
        0xfe, 0x03, 0x00,
        0x41, 0x00, // i32.const 0
        // An atomic must be exactly naturally aligned, so text that omits the
        // alignment means the natural one, not the unaligned 0 a plain load
        // defaults to. i32.atomic.load is 4 wide, so its align_log2 is 2.
        0xfe, 0x10, 0x02, 0x00,
        0x1a, // drop
        0x41, 0x00, // i32.const 0
        // i64.atomic.load8_u reads one byte, so its natural alignment is 0.
        0xfe, 0x14, 0x00, 0x00,
        0x1a, // drop
        0x0b, // end
    }, m.funcs.items[0].code_bytes);
}

test "a stated alignment still beats the natural one" {
    const allocator = std.testing.allocator;
    // The natural alignment is only the assumption made when the text is
    // silent. Text that states an alignment must still be taken at its word,
    // or a module that says something unusual is silently rewritten.
    var m = try parseModule(allocator,
        \\(module
        \\  (memory 1)
        \\  (func (result i32) i32.const 0 i32.load align=1))
    );
    defer m.deinit();
    const body = m.funcs.items[0].code_bytes;
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0x00, 0x00 }, body[2..5]);
}

test "a lane memarg states its alignment the same way every other one does" {
    const allocator = std.testing.allocator;
    // The lane forms parse their memarg on a separate path, and that path
    // emitted the stated alignment rather than its log2 -- so `align=4` was
    // encoded as 4, which reads back as an alignment of 16 bytes and was
    // rejected. It also defaulted to 0 rather than the natural alignment.
    var m = try parseModule(allocator,
        \\(module
        \\  (memory 1)
        \\  (func (param v128) (result v128)
        \\    i32.const 0
        \\    local.get 0
        \\    v128.load32_lane align=4 0
        \\    i32.const 0
        \\    local.get 0
        \\    v128.load32_lane 1))
    );
    defer m.deinit();
    const body = m.funcs.items[0].code_bytes;

    // align=4 is an alignment of 4 bytes, so log2 is 2 -- not the 4 that was
    // emitted before.
    const stated = std.mem.indexOf(u8, body, &.{ 0xfd, 0x56 }).?;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xfd, 0x56, 0x02, 0x00, 0x00 },
        body[stated .. stated + 5],
    );

    // The second one omits `align=`, so it means v128.load32_lane's natural
    // alignment, which is 4 bytes, and its lane index is 1.
    const implied = std.mem.indexOf(u8, body[stated + 5 ..], &.{ 0xfd, 0x56 }).? + stated + 5;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xfd, 0x56, 0x02, 0x00, 0x01 },
        body[implied .. implied + 5],
    );
}

test "an element segment keeps every spelling of the reference type it names" {
    const allocator = std.testing.allocator;
    // Each of these is a reftype in the elemlist position, and each has to
    // reach `elem_type`: an element segment defaults to funcref, so a type
    // that is read and dropped is indistinguishable from one never written.
    inline for (.{
        .{ "funcref", types.ValType.funcref },
        .{ "externref", types.ValType.externref },
        .{ "anyref", types.ValType.anyref },
        .{ "eqref", types.ValType.eqref },
        .{ "i31ref", types.ValType.i31ref },
        .{ "structref", types.ValType.structref },
        .{ "arrayref", types.ValType.arrayref },
        .{ "exnref", types.ValType.exnref },
        .{ "nullref", types.ValType.nullref },
        .{ "nullfuncref", types.ValType.nullfuncref },
        .{ "nullexternref", types.ValType.nullexternref },
        .{ "nullexnref", types.ValType.nullexnref },
    }) |entry| {
        // Passive, declarative and active segments read their elemlist by
        // the same rule, so all three have to agree about the type.
        var passive = try parseModule(allocator, "(module (elem " ++ entry[0] ++ "))");
        defer passive.deinit();
        try std.testing.expectEqual(entry[1], passive.elem_segments.items[0].elem_type);
        try std.testing.expectEqual(types.SegmentKind.passive, passive.elem_segments.items[0].kind);

        var declared = try parseModule(allocator, "(module (elem declare " ++ entry[0] ++ "))");
        defer declared.deinit();
        try std.testing.expectEqual(entry[1], declared.elem_segments.items[0].elem_type);
        try std.testing.expectEqual(types.SegmentKind.declared, declared.elem_segments.items[0].kind);

        var active = try parseModule(allocator,
            "(module (table 1 " ++ entry[0] ++ ") (elem (table 0) (i32.const 0) " ++ entry[0] ++ "))");
        defer active.deinit();
        try std.testing.expectEqual(entry[1], active.elem_segments.items[0].elem_type);
        try std.testing.expectEqual(types.SegmentKind.active, active.elem_segments.items[0].kind);
    }
}

test "an element type is not mistaken for the offset of an active segment" {
    const allocator = std.testing.allocator;
    // A reftype the elemlist rule did not recognise used to fall through to
    // the offset rule, which turned a passive segment into an active one
    // whose offset was `ref.null nofunc` -- and a module with no table into
    // one that referred to table 0.
    var passive = try parseModule(allocator,
        \\(module (elem nullfuncref (ref.null nofunc) (ref.null nofunc)))
    );
    defer passive.deinit();
    const seg = passive.elem_segments.items[0];
    try std.testing.expectEqual(types.SegmentKind.passive, seg.kind);
    try std.testing.expectEqual(types.ValType.nullfuncref, seg.elem_type);
    try std.testing.expectEqual(@as(usize, 0), seg.offset_expr_bytes.len);
    try std.testing.expectEqual(@as(u32, 2), seg.elem_expr_count);
    // ref.null nofunc, end -- twice.
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x73, 0x0b, 0xd0, 0x73, 0x0b }, seg.elem_expr_bytes);

    // With an offset already read, the same unrecognised keyword left the
    // elements to be skipped one by one and dropped.
    var active = try parseModule(allocator,
        \\(module (table i64 1 exnref) (elem (table 0) (i64.const 0) exnref (ref.null exn)))
    );
    defer active.deinit();
    const active_seg = active.elem_segments.items[0];
    try std.testing.expectEqual(types.SegmentKind.active, active_seg.kind);
    try std.testing.expectEqual(types.ValType.exnref, active_seg.elem_type);
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x00 }, active_seg.offset_expr_bytes);
    try std.testing.expectEqual(@as(u32, 1), active_seg.elem_expr_count);
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x69, 0x0b }, active_seg.elem_expr_bytes);
}

test "a folded element type keeps its heap type" {
    const allocator = std.testing.allocator;
    // `(ref null ht)` and `(ref ht)` name the same types the bare keywords
    // do; only `func` and `extern` used to be read, and a concrete index
    // after an offset was recorded as (ref func) whatever it said.
    inline for (.{
        .{ "(ref null func)", types.ValType.funcref },
        .{ "(ref func)", types.ValType.ref_func },
        .{ "(ref null extern)", types.ValType.externref },
        .{ "(ref extern)", types.ValType.ref_extern },
        .{ "(ref null any)", types.ValType.anyref },
        .{ "(ref any)", types.ValType.ref_any },
        .{ "(ref null none)", types.ValType.nullref },
        .{ "(ref null nofunc)", types.ValType.nullfuncref },
        .{ "(ref null exn)", types.ValType.exnref },
        .{ "(ref i31)", types.ValType.ref_i31 },
        .{ "(ref null struct)", types.ValType.structref },
        .{ "(ref array)", types.ValType.ref_array },
    }) |entry| {
        var module = try parseModule(allocator, "(module (elem declare " ++ entry[0] ++ "))");
        defer module.deinit();
        try std.testing.expectEqual(entry[1], module.elem_segments.items[0].elem_type);
        try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), module.elem_segments.items[0].elem_type_idx);
    }

    // A concrete heap type carries an index, by name or by number, and the
    // segment has to keep it: `concrete_ref_null` alone says nothing.
    inline for (.{ "(ref null $t)", "(ref null 1)" }) |spelling| {
        var module = try parseModule(allocator,
            "(module (type (func)) (type $t (func (param i32))) (table 1 " ++ spelling ++ ")" ++
                " (elem (table 0) (i32.const 0) " ++ spelling ++ "))");
        defer module.deinit();
        const seg = module.elem_segments.items[0];
        try std.testing.expectEqual(types.ValType.concrete_ref_null, seg.elem_type);
        try std.testing.expectEqual(@as(u32, 1), seg.elem_type_idx);
        try std.testing.expectEqual(types.SegmentKind.active, seg.kind);
    }

    // Without an offset the same segment is passive, not declarative.
    var passive = try parseModule(allocator,
        \\(module (type $t (func)) (elem (ref $t)))
    );
    defer passive.deinit();
    try std.testing.expectEqual(types.ValType.concrete_ref, passive.elem_segments.items[0].elem_type);
    try std.testing.expectEqual(@as(u32, 0), passive.elem_segments.items[0].elem_type_idx);
    try std.testing.expectEqual(types.SegmentKind.passive, passive.elem_segments.items[0].kind);
}

test "the function-index forms of an element segment still read as before" {
    const allocator = std.testing.allocator;
    // The elemlist is a list of function indices in three spellings, none of
    // which names a reference type; reading a reftype first must not disturb
    // any of them.
    inline for (.{
        "(module (func) (func) (table 2 funcref) (elem (i32.const 0) func 0 1))",
        "(module (func) (func) (table 2 funcref) (elem (i32.const 0) 0 1))",
        "(module (func $a) (func $b) (table 2 funcref) (elem (i32.const 0) func $a $b))",
    }) |src| {
        var module = try parseModule(allocator, src);
        defer module.deinit();
        const seg = module.elem_segments.items[0];
        try std.testing.expectEqual(types.SegmentKind.active, seg.kind);
        try std.testing.expectEqual(types.ValType.ref_func, seg.elem_type);
        try std.testing.expectEqual(@as(u32, 0), seg.elem_expr_count);
        try std.testing.expect(!seg.uses_elem_exprs);
        try std.testing.expectEqual(@as(usize, 2), seg.elem_var_indices.items.len);
        try std.testing.expectEqual(@as(u32, 0), seg.elem_var_indices.items[0].index);
        try std.testing.expectEqual(@as(u32, 1), seg.elem_var_indices.items[1].index);
    }

    // Passive and declarative function-index segments infer `(ref func)`.
    var passive = try parseModule(allocator,
        \\(module (func $f) (elem func $f))
    );
    defer passive.deinit();
    try std.testing.expectEqual(types.SegmentKind.passive, passive.elem_segments.items[0].kind);
    try std.testing.expectEqual(types.ValType.ref_func, passive.elem_segments.items[0].elem_type);
    try std.testing.expect(!passive.elem_segments.items[0].uses_elem_exprs);

    var declared = try parseModule(allocator,
        \\(module (func $f) (elem declare func $f))
    );
    defer declared.deinit();
    try std.testing.expectEqual(types.SegmentKind.declared, declared.elem_segments.items[0].kind);
    try std.testing.expectEqual(types.ValType.ref_func, declared.elem_segments.items[0].elem_type);
    try std.testing.expect(!declared.elem_segments.items[0].uses_elem_exprs);

    // `(item expr)` is the long spelling of an element expression.
    var item = try parseModule(allocator,
        \\(module (func $f) (elem declare funcref (item (ref.func $f))))
    );
    defer item.deinit();
    try std.testing.expectEqual(@as(u32, 1), item.elem_segments.items[0].elem_expr_count);
    try std.testing.expectEqualSlices(u8, &.{ 0xd2, 0x00, 0x0b }, item.elem_segments.items[0].elem_expr_bytes);
}

test "an inline table element list keeps its expressions" {
    const allocator = std.testing.allocator;
    // `(table <reftype> (elem <elemlist>))` abbreviates a table together
    // with an active segment holding the list. The abbreviation used to
    // build that segment by hand out of function indices, so it understood
    // only `ref.func` and a `ref.null` it always spelled `func`, never said
    // the segment held expressions -- which dropped every one of them on the
    // way out -- and never owned the bytes it had written.
    var module = try parseModule(allocator,
        \\(module
        \\  (func $f)
        \\  (global $g funcref (ref.null func))
        \\  (table funcref (elem
        \\    (ref.func $f)
        \\    (ref.null func)
        \\    (global.get $g)
        \\    (item ref.func $f)
        \\    (item (ref.func 0)))))
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 1), module.elem_segments.items.len);
    const seg = module.elem_segments.items[0];
    try std.testing.expectEqual(types.SegmentKind.active, seg.kind);
    try std.testing.expect(seg.uses_elem_exprs);
    try std.testing.expect(seg.owns_elem_expr_bytes);
    try std.testing.expectEqual(@as(u32, 5), seg.elem_expr_count);
    try std.testing.expectEqual(types.ValType.funcref, seg.elem_type);
    try std.testing.expectEqual(types.invalid_index, seg.elem_type_idx);
    try std.testing.expectEqualSlices(u8, &.{
        0xd2, 0x00, 0x0b, // ref.func 0
        0xd0, 0x70, 0x0b, // ref.null func
        0x23, 0x00, 0x0b, // global.get 0
        0xd2, 0x00, 0x0b, // (item ref.func 0)
        0xd2, 0x00, 0x0b, // (item (ref.func 0))
    }, seg.elem_expr_bytes);
    // The segment fills the table the abbreviation defined, from zero.
    try std.testing.expectEqual(@as(u32, 0), seg.table_var.index);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x00 }, seg.offset_expr_bytes);
    try std.testing.expect(seg.owns_offset_expr_bytes);
    // A table written this way is as long as its list.
    try std.testing.expectEqual(@as(u64, 5), module.tables.items[0].type.limits.initial);
    try Validator.validate(&module, .{});
}

test "an inline table element list keeps every reference type" {
    const allocator = std.testing.allocator;
    // The elements are expressions of the table's own type, abstract or
    // concrete, and the segment has to say which type that is: the encoding
    // of an expression list has a reftype field, and a segment that leaves
    // it at the default says `funcref` however it was written.
    inline for (.{
        .{ "externref", "(ref.null extern)", types.ValType.externref, @as([]const u8, &.{ 0xd0, 0x6f, 0x0b }) },
        .{ "anyref", "(ref.null any)", types.ValType.anyref, @as([]const u8, &.{ 0xd0, 0x6e, 0x0b }) },
        .{ "nullfuncref", "(ref.null nofunc)", types.ValType.nullfuncref, @as([]const u8, &.{ 0xd0, 0x73, 0x0b }) },
        .{ "(ref null extern)", "(ref.null extern)", types.ValType.externref, @as([]const u8, &.{ 0xd0, 0x6f, 0x0b }) },
    }) |entry| {
        var module = try parseModule(allocator,
            "(module (table " ++ entry[0] ++ " (elem " ++ entry[1] ++ ")))");
        defer module.deinit();
        const seg = module.elem_segments.items[0];
        try std.testing.expect(seg.uses_elem_exprs);
        try std.testing.expectEqual(entry[2], seg.elem_type);
        try std.testing.expectEqual(types.invalid_index, seg.elem_type_idx);
        try std.testing.expectEqual(@as(u32, 1), seg.elem_expr_count);
        try std.testing.expectEqualSlices(u8, entry[3], seg.elem_expr_bytes);
        try Validator.validate(&module, .{});
    }

    // A concrete element type is an index, and both the table and its
    // segment have to keep it.
    var concrete = try parseModule(allocator,
        \\(module
        \\  (type $t (func))
        \\  (func $f (type $t))
        \\  (table (ref null $t) (elem (ref.func $f) (ref.null $t))))
    );
    defer concrete.deinit();
    const seg = concrete.elem_segments.items[0];
    try std.testing.expect(seg.uses_elem_exprs);
    try std.testing.expectEqual(types.ValType.concrete_ref_null, seg.elem_type);
    try std.testing.expectEqual(@as(u32, 0), seg.elem_type_idx);
    try std.testing.expectEqual(types.ValType.concrete_ref_null, concrete.tables.items[0].type.elem_type);
    try std.testing.expectEqual(@as(u32, 0), concrete.tables.items[0].type_idx);
    try std.testing.expectEqualSlices(u8, &.{ 0xd2, 0x00, 0x0b, 0xd0, 0x00, 0x0b }, seg.elem_expr_bytes);
    try Validator.validate(&concrete, .{});
}

test "an inline table element list of function indices is still the index form" {
    const allocator = std.testing.allocator;
    // The other half of the elemlist rule: bare function indices, by number
    // or by name, encode as indices rather than expressions and infer
    // `(ref func)` as their type just as a written-out `(elem ...)` does.
    inline for (.{
        "(module (func) (func) (table funcref (elem 0 1)))",
        "(module (func $a) (func $b) (table funcref (elem $a $b)))",
    }) |src| {
        var module = try parseModule(allocator, src);
        defer module.deinit();
        const seg = module.elem_segments.items[0];
        try std.testing.expectEqual(types.SegmentKind.active, seg.kind);
        try std.testing.expect(!seg.uses_elem_exprs);
        try std.testing.expectEqual(@as(u32, 0), seg.elem_expr_count);
        try std.testing.expectEqual(@as(usize, 0), seg.elem_expr_bytes.len);
        try std.testing.expectEqual(types.ValType.ref_func, seg.elem_type);
        try std.testing.expectEqual(@as(usize, 2), seg.elem_var_indices.items.len);
        try std.testing.expectEqual(@as(u32, 0), seg.elem_var_indices.items[0].index);
        try std.testing.expectEqual(@as(u32, 1), seg.elem_var_indices.items[1].index);
        try std.testing.expectEqual(@as(u64, 2), module.tables.items[0].type.limits.initial);
        try Validator.validate(&module, .{});
    }
}

test "an empty inline table element list is still an element list" {
    const allocator = std.testing.allocator;
    // `(elem)` is an elemlist of no elements, and the abbreviation still
    // stands for a segment. Which form of segment depends on the table: the
    // index form only ever holds functions, so any other reference type
    // needs the expression form to have somewhere to say so.
    var funcs = try parseModule(allocator, "(module (table funcref (elem)))");
    defer funcs.deinit();
    try std.testing.expectEqual(@as(usize, 1), funcs.elem_segments.items.len);
    try std.testing.expect(!funcs.elem_segments.items[0].uses_elem_exprs);
    try std.testing.expectEqual(types.ValType.ref_func, funcs.elem_segments.items[0].elem_type);
    try std.testing.expectEqual(@as(u32, 0), funcs.elem_segments.items[0].elem_expr_count);
    try std.testing.expectEqual(@as(u64, 0), funcs.tables.items[0].type.limits.initial);
    try Validator.validate(&funcs, .{});

    var externs = try parseModule(allocator, "(module (table externref (elem)))");
    defer externs.deinit();
    try std.testing.expect(externs.elem_segments.items[0].uses_elem_exprs);
    try std.testing.expectEqual(types.ValType.externref, externs.elem_segments.items[0].elem_type);
    try std.testing.expectEqual(@as(u32, 0), externs.elem_segments.items[0].elem_expr_count);
    try std.testing.expectEqual(@as(usize, 0), externs.elem_segments.items[0].elem_expr_bytes.len);
    try Validator.validate(&externs, .{});

    // A table with no element list at all is not a segment.
    var none = try parseModule(allocator, "(module (table 1 funcref))");
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.elem_segments.items.len);
}

test "an inline table element list says which table it fills" {
    const allocator = std.testing.allocator;
    // The abbreviation names the table it defines, which is only table 0
    // when it is the first one. A segment that leaves the index implicit
    // means table 0 whatever table it was written under, so a later table's
    // elements ended up in the first table's text.
    var module = try parseModule(allocator,
        \\(module
        \\  (func $f)
        \\  (table 1 funcref)
        \\  (table funcref (elem (ref.func $f)))
        \\  (table funcref (elem $f)))
    );
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 2), module.elem_segments.items.len);
    try std.testing.expectEqual(@as(u32, 1), module.elem_segments.items[0].table_var.index);
    try std.testing.expect(module.elem_segments.items[0].has_explicit_table_index);
    try std.testing.expectEqual(@as(u32, 2), module.elem_segments.items[1].table_var.index);
    try std.testing.expect(module.elem_segments.items[1].has_explicit_table_index);
    try Validator.validate(&module, .{});

    // Table 0 is what the implicit form means, so nothing has to be said.
    var first = try parseModule(allocator, "(module (func $f) (table funcref (elem (ref.func $f))))");
    defer first.deinit();
    try std.testing.expectEqual(@as(u32, 0), first.elem_segments.items[0].table_var.index);
    try std.testing.expect(!first.elem_segments.items[0].has_explicit_table_index);
    try Validator.validate(&first, .{});
}

test "a 64-bit table's inline element list is offset by an i64" {
    const allocator = std.testing.allocator;
    // The offset the abbreviation invents indexes the table, so it has the
    // table's index type.
    var module = try parseModule(allocator,
        \\(module (func $f) (table i64 funcref (elem (ref.func $f))))
    );
    defer module.deinit();
    const seg = module.elem_segments.items[0];
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x00 }, seg.offset_expr_bytes);
    try std.testing.expect(seg.uses_elem_exprs);
    try std.testing.expect(module.tables.items[0].type.limits.is_64);
    try Validator.validate(&module, .{});
}

test "an inline table element list rejects what is not an element" {
    const allocator = std.testing.allocator;
    // A word that is neither an index nor an expression used to be skipped
    // silently, leaving a shorter table than was written.
    try std.testing.expectError(error.InvalidModule, parseModule(allocator,
        \\(module (table funcref (elem garbage)))
    ));
    // The two forms of elemlist are alternatives, not a mixture: only one of
    // them can be encoded, so the other's elements would be lost.
    try std.testing.expectError(error.InvalidModule, parseModule(allocator,
        \\(module (func $f) (table funcref (elem 0 (ref.func $f))))
    ));
    // An expression of the wrong type, or one naming a function that does
    // not exist, is caught where every other element expression is.
    var wrong_type = try parseModule(allocator,
        \\(module (table funcref (elem (i32.const 0))))
    );
    defer wrong_type.deinit();
    try std.testing.expectError(error.TypeMismatch, Validator.validate(&wrong_type, .{}));

    var no_such_func = try parseModule(allocator,
        \\(module (table funcref (elem (ref.func 3))))
    );
    defer no_such_func.deinit();
    try std.testing.expectError(error.InvalidFuncIndex, Validator.validate(&no_such_func, .{}));
}

test "an element list that fails part way frees what it had read" {
    const allocator = std.testing.allocator;
    // A segment belongs to the module only once it has been appended, so a
    // parse that abandons one part way through has to free it itself. The
    // testing allocator is what checks this: each of these fails on an index
    // no `u32` can hold, after the segment has taken bytes and indices of
    // its own.
    inline for (.{
        "(module (func) (table funcref (elem (ref.func 0) 99999999999999999999)))",
        "(module (func $f) (table funcref (elem $f 99999999999999999999)))",
        "(module (func) (table externref (elem (ref.null extern) 99999999999999999999)))",
        "(module (func) (table 1 funcref) (elem (i32.const 0) func 0 99999999999999999999))",
        "(module (func) (table 1 funcref) (elem (i32.const 0) funcref (ref.func 0) 99999999999999999999))",
        "(module (func) (elem declare funcref (ref.func 0) 99999999999999999999))",
    }) |src| {
        if (parseModule(allocator, src)) |parsed| {
            var module = parsed;
            module.deinit();
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "an inline table element list fixes the table's size" {
    const allocator = std.testing.allocator;
    // `(table <reftype> (elem <elemlist>))` abbreviates `(table id' n n
    // <reftype>)`: the table is exactly as long as the list, both bounds.
    // A minimum on its own leaves room no element reaches and lets the
    // table grow past what was written.
    inline for (.{
        .{ "(module (func $f) (table funcref (elem $f)))", 1 },
        .{ "(module (func) (func) (table funcref (elem 0 1)))", 2 },
        .{ "(module (func $f) (table funcref (elem (ref.func $f) (ref.null func))))", 2 },
        .{ "(module (table funcref (elem)))", 0 },
        .{ "(module (table externref (elem)))", 0 },
        .{ "(module (table externref (elem (ref.null extern))))", 1 },
        .{ "(module (table anyref (elem (ref.null any) (ref.null none))))", 2 },
        .{ "(module (func $f) (table i64 funcref (elem $f)))", 1 },
        .{ "(module (func $f) (table i64 funcref (elem (ref.func $f))))", 1 },
        .{ "(module (type $t (func)) (func $f (type $t)) (table (ref null $t) (elem (ref.func $f))))", 1 },
    }) |entry| {
        var module = try parseModule(allocator, entry[0]);
        defer module.deinit();
        const limits = module.tables.items[module.tables.items.len - 1].type.limits;
        try std.testing.expectEqual(@as(u64, entry[1]), limits.initial);
        try std.testing.expect(limits.has_max);
        try std.testing.expectEqual(@as(u64, entry[1]), limits.max);
        try Validator.validate(&module, .{});
    }

    // A table with no element list is not the abbreviation, and states
    // whichever bounds it was written with.
    var explicit = try parseModule(allocator, "(module (table 1 funcref) (table 2 5 funcref))");
    defer explicit.deinit();
    try std.testing.expect(!explicit.tables.items[0].type.limits.has_max);
    try std.testing.expect(explicit.tables.items[1].type.limits.has_max);
    try std.testing.expectEqual(@as(u64, 5), explicit.tables.items[1].type.limits.max);
}

test "an inline table element list writes both bounds into the binary" {
    const allocator = std.testing.allocator;
    // The bound has to reach the encoding, where it is a flag byte before
    // the numbers: without `has_max` the table entry is `70 00 01` and the
    // maximum is not written at all.
    var module = try parseModule(allocator, "(module (func $f) (table funcref (elem $f)))");
    defer module.deinit();
    const wasm = try binary_writer.writeModule(allocator, &module);
    defer allocator.free(wasm);
    // funcref, limits flags 0x01 (has max), minimum 1, maximum 1.
    try std.testing.expect(std.mem.indexOf(u8, wasm, &[_]u8{ 0x70, 0x01, 0x01, 0x01 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, wasm, &[_]u8{ 0x70, 0x00, 0x01 }) == null);

    // A 64-bit table says so in the same byte: 0x04 for the index type and
    // 0x01 for the maximum.
    var wide = try parseModule(allocator, "(module (func $f) (table i64 funcref (elem $f $f)))");
    defer wide.deinit();
    const wide_wasm = try binary_writer.writeModule(allocator, &wide);
    defer allocator.free(wide_wasm);
    try std.testing.expect(std.mem.indexOf(u8, wide_wasm, &[_]u8{ 0x70, 0x05, 0x02, 0x02 }) != null);

    // Reading the module back finds the bound the writer put there.
    var reread = try binary_reader.readModule(allocator, wasm);
    defer reread.deinit();
    try std.testing.expect(reread.tables.items[0].type.limits.has_max);
    try std.testing.expectEqual(@as(u64, 1), reread.tables.items[0].type.limits.max);
}

test "an element segment rejects a function name no function has" {
    const allocator = std.testing.allocator;
    // Every function name is known before the fields are read, so a name
    // still unresolved in an elemlist is a name no function has. Reading it
    // as function 0 put a function in the table the module never named.
    inline for (.{
        "(module (func $f) (table funcref (elem $nope)))",
        "(module (func $f) (table funcref (elem $f $nope)))",
        "(module (func $f) (table 1 funcref) (elem (i32.const 0) func $nope))",
        "(module (func $f) (table 1 funcref) (elem (i32.const 0) $nope))",
        "(module (func $f) (elem func $nope))",
        "(module (func $f) (elem declare func $nope))",
    }) |src| {
        try std.testing.expectError(error.InvalidModule, parseModule(allocator, src));
    }

    // The same lists with a name some function does have are accepted, and
    // resolve to that function.
    inline for (.{
        .{ "(module (func) (func $f) (table funcref (elem $f)))", 1 },
        .{ "(module (func) (func $f) (table 1 2 funcref) (elem (i32.const 0) func $f))", 1 },
        .{ "(module (func) (func $f) (elem func $f))", 1 },
    }) |entry| {
        var module = try parseModule(allocator, entry[0]);
        defer module.deinit();
        const seg = module.elem_segments.items[0];
        try std.testing.expectEqual(@as(usize, 1), seg.elem_var_indices.items.len);
        try std.testing.expectEqual(@as(u32, entry[1]), seg.elem_var_indices.items[0].index);
        try Validator.validate(&module, .{});
    }
}
