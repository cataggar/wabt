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

pub const ParseError = error{
    UnexpectedToken,
    InvalidModule,
    InvalidType,
    InvalidNumber,
    OutOfMemory,
};

/// Parse a WebAssembly text format source into a Module.
pub fn parseModule(allocator: std.mem.Allocator, source: []const u8) ParseError!Mod.Module {
    var p = Parser{ .lexer = Lexer.init(source), .allocator = allocator };
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
    try p.expect(.kw_module);

    // Optional module name
    if (p.peek().kind == .identifier) {
        module.name = p.advance().text;
    }

    // Parse module fields — two passes:
    // Pass 1: process only (type ...) declarations to build the type section first.
    // This ensures explicit type indices are assigned before implicit function types.
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
            p.malformed = true;
            continue;
        }
        _ = p.advance(); // consume '('
        const kw = p.advance();
        switch (kw.kind) {
            .kw_type => try p.parseType(&module),
            .kw_rec => try p.parseRec(&module),
            else => try p.skipSExpr(),
        }
        try p.expect(.r_paren);
    }

    // Canonicalize rec groups for iso-recursive type equivalence
    p.canonicalizeTypes(&module);

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
            p.malformed = true;
            continue;
        }
        _ = p.advance(); // consume '('
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
                if (seen_non_import_def) p.malformed = true;
                try p.parseImport(&module);
            },
            .kw_export => try p.parseExport(&module),
            .kw_start => try p.parseStart(&module),
            .kw_elem => try p.parseElem(&module),
            .kw_data => try p.parseData(&module),
            .kw_definition => try p.skipSExpr(),
            .kw_tag => try p.parseTag(&module),
            .invalid => {
                p.malformed = true;
                try p.skipSExpr();
            },
            else => try p.skipSExpr(),
        }
        try p.expect(.r_paren);
    }

    try p.expect(.r_paren);
    // Check for unexpected trailing tokens
    if (p.peek().kind != .eof) p.malformed = true;
    if (p.malformed or pass1_malformed) {
        return error.InvalidModule;
    }
    return module;
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
    if (tok.kind != .kw_module) return;
    tok = lex.next();
    if (tok.kind == .identifier) tok = lex.next();

    // Scan top-level fields
    while (tok.kind == .l_paren) {
        tok = lex.next();
        if (tok.kind == .kw_func) {
            tok = lex.next();
            if (tok.kind == .identifier) {
                func_names.put(allocator, tok.text, func_idx) catch {};
            }
            func_idx += 1;
        } else if (tok.kind == .kw_type) {
            tok = lex.next();
            if (tok.kind == .identifier) {
                type_names.put(allocator, tok.text, type_idx) catch {};
            }
            type_idx += 1;
        } else if (tok.kind == .kw_global) {
            tok = lex.next();
            if (tok.kind == .identifier) {
                global_names.put(allocator, tok.text, global_idx) catch {};
            }
            global_idx += 1;
        } else if (tok.kind == .kw_table) {
            tok = lex.next();
            if (tok.kind == .identifier) {
                table_names.put(allocator, tok.text, table_idx) catch {};
            }
            table_idx += 1;
        } else if (tok.kind == .kw_memory) {
            tok = lex.next();
            if (tok.kind == .identifier) {
                memory_names.put(allocator, tok.text, memory_idx) catch {};
            }
            memory_idx += 1;
        } else if (tok.kind == .kw_data) {
            tok = lex.next();
            if (tok.kind == .identifier) {
                data_names.put(allocator, tok.text, data_idx) catch {};
            }
            data_idx += 1;
        } else if (tok.kind == .kw_import) {
            // Imports define indices for their kind. We need to find
            // (import "mod" "name" (func $name ...)) to count import funcs.
            // Skip module and field strings, then read the '(' before kind desc
            _ = lex.next(); // module string
            _ = lex.next(); // field string
            tok = lex.next(); // should be '(' before kind desc (e.g. "(func ...")
            if (tok.kind == .l_paren) {
                tok = lex.next();
                if (tok.kind == .kw_func) {
                    tok = lex.next();
                    if (tok.kind == .identifier) {
                        func_names.put(allocator, tok.text, func_idx) catch {};
                    }
                    func_idx += 1;
                } else if (tok.kind == .kw_global) {
                    tok = lex.next();
                    if (tok.kind == .identifier) {
                        global_names.put(allocator, tok.text, global_idx) catch {};
                    }
                    global_idx += 1;
                } else if (tok.kind == .kw_table) {
                    tok = lex.next();
                    if (tok.kind == .identifier) {
                        table_names.put(allocator, tok.text, table_idx) catch {};
                    }
                    table_idx += 1;
                } else if (tok.kind == .kw_memory) {
                    tok = lex.next();
                    if (tok.kind == .identifier) {
                        memory_names.put(allocator, tok.text, memory_idx) catch {};
                    }
                    memory_idx += 1;
                }
                // Skip remaining tokens in kind desc '(func/global/... ...)' 
                var inner_depth: u32 = 1;
                if (tok.kind == .l_paren) inner_depth += 1;
                while (inner_depth > 0) {
                    tok = lex.next();
                    if (tok.kind == .l_paren) inner_depth += 1;
                    if (tok.kind == .r_paren) inner_depth -= 1;
                    if (tok.kind == .eof) return;
                }
            }
        }
        // Skip to matching ')'
        // If a branch consumed a '(' (e.g. kw_func read past $name into '(export'),
        // account for the extra nesting level.
        var depth: u32 = 1;
        if (tok.kind == .l_paren) depth += 1;
        while (depth > 0) {
            tok = lex.next();
            if (tok.kind == .l_paren) depth += 1;
            if (tok.kind == .r_paren) depth -= 1;
            if (tok.kind == .eof) return;
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
    label_stack: std.ArrayListUnmanaged(?[]const u8) = .{},
    /// Type indices referenced during current type parsing (for iso-recursive canonicalization).
    collected_type_refs: std.ArrayListUnmanaged(u32) = .{},
    /// True when parsing a type section entry (controls type ref collection).
    in_type_parse: bool = false,

    fn peek(self: *Parser) Lex.Token {
        if (self.peeked) |t| return t;
        self.peeked = self.lexer.next();
        return self.peeked.?;
    }

    fn advance(self: *Parser) Lex.Token {
        if (self.peeked) |t| {
            self.peeked = null;
            return t;
        }
        return self.lexer.next();
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
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = self.advance();
            switch (tok.kind) {
                .l_paren, .annotation => depth += 1,
                .r_paren => depth -= 1,
                .eof => return error.InvalidModule,
                .invalid => self.malformed = true,
                else => {},
            }
        }
    }

    fn parseU32(self: *Parser) ParseError!u32 {
        const tok = self.advance();
        if (tok.kind != .integer) return error.InvalidNumber;
        const clean = stripUnderscores(tok.text);
        return std.fmt.parseInt(u32, clean.slice(), 0) catch return error.InvalidNumber;
    }

    /// Parse an index that may be either a numeric u32 or a $name identifier.
    /// Resolves $name against the given name map.
    fn parseIndexWithMap(self: *Parser, names: *const std.StringArrayHashMapUnmanaged(u32)) ParseError!u32 {
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            return names.get(tok.text) orelse return error.InvalidNumber;
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

    /// Check if an identifier is empty (just "$" with no following chars)
    fn checkEmptyId(self: *Parser, text: []const u8) void {
        if (text.len == 1 and text[0] == '$') self.malformed = true;
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
                            self.malformed = true;
                            try self.expect(.r_paren);
                            return if (nullable) .ref_null else .ref;
                        };
                        resolved_type_idx = idx;
                        if (self.in_rec) {
                            // Within rec group, allow refs within the group but not beyond
                            if (idx >= self.rec_end) self.malformed = true;
                        } else {
                            if (self.module) |mod| {
                                if (idx >= mod.module_types.items.len) self.malformed = true;
                            }
                        }
                    } else if (ht.kind == .identifier) {
                        // Validate named type references
                        if (self.type_names.get(ht.text)) |idx| {
                            resolved_type_idx = idx;
                            if (self.in_rec) {
                                if (idx >= self.rec_end) self.malformed = true;
                            } else {
                                if (self.module) |mod| {
                                    if (idx >= mod.module_types.items.len) self.malformed = true;
                                }
                            }
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
                    if (std.mem.eql(u8, heap_text, "i31")) return .anyref;
                    if (std.mem.eql(u8, heap_text, "eq")) return .anyref;
                    if (std.mem.eql(u8, heap_text, "struct")) return .anyref;
                    if (std.mem.eql(u8, heap_text, "array")) return .anyref;
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
                    if (std.mem.eql(u8, heap_text, "i31")) return .ref_any;
                    if (std.mem.eql(u8, heap_text, "eq")) return .ref_any;
                    if (std.mem.eql(u8, heap_text, "struct")) return .ref_any;
                    if (std.mem.eql(u8, heap_text, "array")) return .ref_any;
                    if (std.mem.eql(u8, heap_text, "none")) return .ref_none;
                    if (std.mem.eql(u8, heap_text, "nofunc")) return .ref_nofunc;
                    if (std.mem.eql(u8, heap_text, "noextern")) return .ref_noextern;
                }
                // Record type index for concrete type references (only during type section parsing)
                if (self.in_type_parse and resolved_type_idx != std.math.maxInt(u32)) {
                    self.collected_type_refs.append(self.allocator, resolved_type_idx) catch {};
                }
                return if (nullable) .ref_null else .ref;
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
            .kw_i31ref => .anyref,
            .kw_eqref => .anyref,
            .kw_structref => .anyref,
            .kw_arrayref => .anyref,
            else => error.InvalidType,
        };
    }

    fn parseFuncSig(self: *Parser, module: *Mod.Module) ParseError!struct { params: []const types.ValType, results: []const types.ValType } {
        var params: std.ArrayListUnmanaged(types.ValType) = .{};
        errdefer params.deinit(self.allocator);
        var results: std.ArrayListUnmanaged(types.ValType) = .{};
        errdefer results.deinit(self.allocator);
        var seen_result = false;

        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance();
            const kw = self.peek();
            if (kw.kind == .kw_param) {
                if (seen_result) return error.UnexpectedToken; // param after result
                _ = self.advance();
                // Optional identifier
                if (self.peek().kind == .identifier) _ = self.advance();
                while (self.peek().kind != .r_paren) {
                    try params.append(self.allocator, try self.parseValType());
                }
                try self.expect(.r_paren);
            } else if (kw.kind == .kw_result) {
                seen_result = true;
                _ = self.advance();
                while (self.peek().kind != .r_paren) {
                    try results.append(self.allocator, try self.parseValType());
                }
                try self.expect(.r_paren);
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
        };
    }

    // -- module fields --

    fn parseType(self: *Parser, module: *Mod.Module) ParseError!void {
        // Clear type ref collection for this type
        self.collected_type_refs.clearRetainingCapacity();
        self.in_type_parse = true;
        defer self.in_type_parse = false;
        // (type $name? (func (param ...) (result ...)))
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            self.type_names.put(self.allocator, name, @intCast(module.module_types.items.len)) catch {};
        }
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
        const inner_text = self.peek().text;
        if (self.peek().kind == .kw_func) {
            meta.kind = .func;
            _ = self.advance();
            const sig = try self.parseFuncSig(module);
            try self.expect(.r_paren);
            if (meta.is_sub) try self.expect(.r_paren); // close (sub ...)
            try module.module_types.append(self.allocator, .{
                .func_type = .{ .params = sig.params, .results = sig.results },
            });
        } else {
            if (std.mem.eql(u8, inner_text, "struct")) {
                meta.kind = .struct_;
                _ = self.advance(); // consume 'struct'
                // Parse struct fields: (field [$name] [mut] <valtype>) ...
                var fields: std.ArrayListUnmanaged(Mod.TypeEntry.StructType.Field) = .{};
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
                                        if (std.mem.eql(u8, en, fn2)) self.malformed = true;
                                    }
                                }
                            }
                        }
                        var fmut = false;
                        if (self.peek().kind == .l_paren) {
                            const sp2 = self.lexer.pos;
                            const spk2 = self.peeked;
                            _ = self.advance();
                            if (self.peek().kind == .kw_mut) {
                                _ = self.advance();
                                fmut = true;
                                const ftype = self.parseValType() catch .ref_null;
                                if (self.peek().kind == .r_paren) _ = self.advance();
                                fields.append(self.allocator, .{ .name = fname, .@"type" = ftype, .mutable = fmut }) catch {};
                            } else {
                                self.lexer.pos = sp2;
                                self.peeked = spk2;
                                const ftype = self.parseValType() catch .ref_null;
                                fields.append(self.allocator, .{ .name = fname, .@"type" = ftype, .mutable = false }) catch {};
                            }
                        } else {
                            const ftype = self.parseValType() catch .ref_null;
                            fields.append(self.allocator, .{ .name = fname, .@"type" = ftype, .mutable = false }) catch {};
                        }
                        // Handle multiple anonymous fields: (field type type type ...)
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const extra_type = self.parseValType() catch break;
                            fields.append(self.allocator, .{ .@"type" = extra_type }) catch {};
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
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
                        const elem_type = self.parseValType() catch .ref_null;
                        if (self.peek().kind == .r_paren) _ = self.advance();
                        try self.expect(.r_paren); // close array
                        if (meta.is_sub) try self.expect(.r_paren);
                        try module.module_types.append(self.allocator, .{
                            .array_type = .{ .field = .{ .@"type" = elem_type, .mutable = elem_mut } },
                        });
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        const elem_type = self.parseValType() catch .ref_null;
                        try self.expect(.r_paren); // close array
                        if (meta.is_sub) try self.expect(.r_paren);
                        try module.module_types.append(self.allocator, .{
                            .array_type = .{ .field = .{ .@"type" = elem_type, .mutable = false } },
                        });
                    }
                } else {
                    const elem_type = self.parseValType() catch .ref_null;
                    try self.expect(.r_paren); // close array
                    if (meta.is_sub) try self.expect(.r_paren);
                    try module.module_types.append(self.allocator, .{
                        .array_type = .{ .field = .{ .@"type" = elem_type, .mutable = false } },
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
                                self.malformed = true;
                                continue;
                            };
                            if (self.in_rec) {
                                if (idx >= self.rec_end) self.malformed = true;
                            } else {
                                if (self.module) |mod| {
                                    if (idx >= mod.module_types.items.len) self.malformed = true;
                                }
                            }
                        } else if (ht.kind == .identifier) {
                            if (self.type_names.get(ht.text)) |idx| {
                                if (self.in_rec) {
                                    if (idx >= self.rec_end) self.malformed = true;
                                } else {
                                    if (self.module) |mod| {
                                        if (idx >= mod.module_types.items.len) self.malformed = true;
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
                                    self.malformed = true;
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
        // Pre-count types to determine the rec group boundary.
        const save_pos = self.lexer.pos;
        const save_peeked = self.peeked;
        var rec_count: u32 = 0;
        while (self.peek().kind == .l_paren) {
            _ = self.advance();
            if (self.peek().kind == .kw_type) rec_count += 1;
            self.skipSExpr() catch {};
            if (self.peek().kind == .r_paren) _ = self.advance();
        }
        self.lexer.pos = save_pos;
        self.peeked = save_peeked;

        const rec_start: u32 = @intCast(module.module_types.items.len);
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
                    meta.rec_group = rec_start;
                    meta.rec_group_size = rec_count;
                    meta.rec_position = rec_pos;
                }
                rec_pos += 1;
            } else {
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
            var key: std.ArrayListUnmanaged(u8) = .{};
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

    /// Append a canonicalized ValType to the key buffer. For concrete type refs (.ref/.ref_null),
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
        if ((vt == .ref or vt == .ref_null) and ref_idx < type_refs.len) {
            const target_idx = type_refs[ref_idx];
            key.append(alloc, if (vt == .ref) @as(u8, 0xA0) else @as(u8, 0xA1)) catch {};
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
        if (self.peek().kind == .identifier) {
            func.name = self.advance().text;
            if (func.name) |n| self.checkEmptyId(n);
            // Register name → index for call resolution
            if (func.name) |n| {
                if (self.func_names.get(n)) |existing| {
                    if (existing != func_idx and existing < func_idx) self.malformed = true;
                }
                self.func_names.put(self.allocator, n, func_idx) catch {};
            }
        }

        // Handle inline (export "name") and (import "mod" "name") declarations
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .func,
                    .var_ = .{ .index = func_idx },
                }) catch return error.OutOfMemory;
            } else if (self.peek().kind == .kw_import) {
                _ = self.advance(); // consume 'import'
                const mod_name = self.parseName(self.advance().text);
                const field_name = self.parseName(self.advance().text);
                try self.expect(.r_paren); // close (import ...)

                // Parse optional (type $idx) and inline sig
                var type_index: types.Index = 0;
                var params_list: std.ArrayListUnmanaged(types.ValType) = .{};
                defer params_list.deinit(self.allocator);
                var results_list: std.ArrayListUnmanaged(types.ValType) = .{};
                defer results_list.deinit(self.allocator);

                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        type_index = self.parseTypeIdx() catch 0;
                        try self.expect(.r_paren);
                    } else if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
                            params_list.append(self.allocator, vt) catch {};
                        }
                        try self.expect(.r_paren);
                    } else if (self.peek().kind == .kw_result) {
                        _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
                            results_list.append(self.allocator, vt) catch {};
                        }
                        try self.expect(.r_paren);
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        break;
                    }
                }

                // Register as import
                func.is_import = true;
                func.decl.type_var = .{ .index = type_index };

                // Build func type if inline sig provided
                if (params_list.items.len > 0 or results_list.items.len > 0) {
                    const params = params_list.toOwnedSlice(self.allocator) catch &.{};
                    const results = results_list.toOwnedSlice(self.allocator) catch &.{};
                    type_index = @intCast(module.module_types.items.len);
                    module.module_types.append(self.allocator, .{
                        .func_type = .{ .params = params, .results = results },
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
        if (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
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
        var params_list: std.ArrayListUnmanaged(types.ValType) = .{};
        defer params_list.deinit(self.allocator);
        var results_list: std.ArrayListUnmanaged(types.ValType) = .{};
        defer results_list.deinit(self.allocator);

        var seen_results = false;

        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            const inner = self.peek().kind;
            if (inner == .kw_param) {
                if (seen_results) self.malformed = true;
                _ = self.advance(); // consume 'param'
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx: u32 = @intCast(params_list.items.len);
                    if (self.local_names.get(name) != null) {
                        self.malformed = true;
                    }
                    self.local_names.put(self.allocator, name, idx) catch {};
                }
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
                    params_list.append(self.allocator, vt) catch return error.OutOfMemory;
                }
                try self.expect(.r_paren);
            } else if (inner == .kw_result) {
                seen_results = true;
                _ = self.advance(); // consume 'result'
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
                    results_list.append(self.allocator, vt) catch return error.OutOfMemory;
                }
                try self.expect(.r_paren);
            } else if (inner == .kw_type) {
                // (type ...) after (param/result ...) is malformed
                if (params_list.items.len > 0 or results_list.items.len > 0) {
                    self.malformed = true;
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
                            self.malformed = true;
                        } else {
                            for (ft.params, params_list.items) |a, b| {
                                if (a != b) self.malformed = true;
                            }
                            for (ft.results, results_list.items) |a, b| {
                                if (a != b) self.malformed = true;
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
                const r = self.allocator.alloc(types.ValType, results_list.items.len) catch return error.OutOfMemory;
                @memcpy(r, results_list.items);
                const new_sig = Mod.FuncSignature{ .params = p, .results = r };
                // Deduplicate: reuse existing type if signature matches
                const type_idx = blk: {
                    for (module.module_types.items, 0..) |entry, idx| {
                        switch (entry) {
                            .func_type => |ft| if (ft.eql(new_sig)) {
                                self.allocator.free(p);
                                self.allocator.free(r);
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
        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_local) {
                _ = self.advance(); // consume 'local'
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx: u32 = actual_param_count + @as(u32, @intCast(func.local_types.items.len));
                    if (self.local_names.get(name) != null) {
                        self.malformed = true;
                    }
                    self.local_names.put(self.allocator, name, idx) catch {};
                }
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
                    func.local_types.append(self.allocator, vt) catch return error.OutOfMemory;
                }
                try self.expect(.r_paren);
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
                                    if (!last_was_select) { self.malformed = true; break :scan_loop; }
                                }
                            } else if (inner.kind == .kw_result) {
                                if (saw_instr and !last_was_select) { self.malformed = true; break :scan_loop; }
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
        var code: std.ArrayListUnmanaged(u8) = .{};
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
            if (self.peek().kind == .l_paren) {
                _ = self.advance(); // consume '('
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
                code.append(self.allocator, 0x02) catch return;
                const label = self.consumeOptionalLabel();
                self.label_stack.append(self.allocator, label) catch {};
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
                self.label_stack.append(self.allocator, label) catch {};
                self.emitBlockType(code);
                // Parse catch clauses
                var clause_count: u32 = 0;
                var catch_bytes = std.ArrayListUnmanaged(u8){};
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
                const bt_len = self.readBlockType(&block_type_buf);

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
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.parseFoldedInstr(code);
                        has_operands = true;
                    } else {
                        // Could be additional immediates — skip them
                        if (self.peek().kind == .invalid) self.malformed = true;
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
                    const el_label = self.advance().text;
                    if (self.label_stack.items.len > 0) {
                        const opening = self.label_stack.items[self.label_stack.items.len - 1];
                        if (opening == null or !std.mem.eql(u8, opening.?, el_label)) {
                            self.malformed = true;
                            return;
                        }
                    } else {
                        self.malformed = true;
                        return;
                    }
                }
            },
            .kw_end => {
                code.append(self.allocator, 0x0b) catch return;
                // Validate optional end label matches the opening block/loop/if label
                if (self.peek().kind == .identifier) {
                    const en_label = self.advance().text;
                    if (self.label_stack.items.len > 0) {
                        const opening = self.label_stack.items[self.label_stack.items.len - 1];
                        if (opening == null or !std.mem.eql(u8, opening.?, en_label)) {
                            self.malformed = true;
                            return;
                        }
                    } else {
                        self.malformed = true;
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
                var targets: std.ArrayListUnmanaged(u32) = .{};
                defer targets.deinit(self.allocator);
                while (self.peek().kind == .integer or self.peek().kind == .identifier) {
                    if (self.peek().kind == .integer) {
                        const idx = self.parseU32() catch break;
                        targets.append(self.allocator, idx) catch return;
                    } else {
                        const label_tok = self.advance();
                        const depth = self.resolveLabelDepth(label_tok.text) orelse blk: {
                            self.malformed = true;
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
                    self.peek().kind == .kw_i31ref or self.peek().kind == .kw_exnref)
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
                // Push label for depth resolution (try_table is a block-like construct)
                self.label_stack.append(self.allocator, label) catch {};
                self.emitBlockType(code);
                // Parse catch clauses, building a byte buffer
                var clause_count: u32 = 0;
                var catch_bytes = std.ArrayListUnmanaged(u8){};
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
                            if (saw_param or saw_result) self.malformed = true;
                            saw_type = true;
                        } else if (inner.kind == .kw_param) {
                            if (saw_result) self.malformed = true;
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
                        self.emitLeb128U32(code, 0); // default type 0
                    }
                } else if (self.peek().kind == .integer) {
                    self.emitU32Imm(code); // numeric type index
                } else {
                    self.emitLeb128U32(code, 0); // default type 0
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
                const next = self.peek().kind;
                if (next == .kw_funcref) {
                    _ = self.advance();
                    code.append(self.allocator, 0x70) catch return;
                } else if (next == .kw_externref) {
                    _ = self.advance();
                    code.append(self.allocator, 0x6f) catch return;
                } else if (next == .kw_exnref) {
                    _ = self.advance();
                    code.append(self.allocator, 0x69) catch return;
                } else if (next == .kw_func) {
                    _ = self.advance();
                    code.append(self.allocator, 0x70) catch return;
                } else if (next == .identifier) {
                    // Type name reference: $type_name → type index
                    const name = self.advance().text;
                    const type_idx = self.type_names.get(name) orelse 0;
                    self.emitLeb128S32(code, @bitCast(type_idx));
                } else {
                    const save_pos = self.lexer.pos;
                    const save_peeked = self.peeked;
                    if (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                        const ht = self.advance();
                        if (std.mem.eql(u8, ht.text, "extern")) {
                            code.append(self.allocator, 0x6f) catch return;
                        } else if (std.mem.eql(u8, ht.text, "func")) {
                            code.append(self.allocator, 0x70) catch return;
                        } else if (std.mem.eql(u8, ht.text, "any")) {
                            code.append(self.allocator, 0x6e) catch return;
                        } else if (std.mem.eql(u8, ht.text, "exn")) {
                            code.append(self.allocator, 0x69) catch return;
                        } else if (std.mem.eql(u8, ht.text, "i31")) {
                            code.append(self.allocator, 0x6c) catch return;
                        } else if (std.mem.eql(u8, ht.text, "eq")) {
                            code.append(self.allocator, 0x6d) catch return;
                        } else if (std.mem.eql(u8, ht.text, "struct")) {
                            code.append(self.allocator, 0x6b) catch return;
                        } else if (std.mem.eql(u8, ht.text, "array")) {
                            code.append(self.allocator, 0x6a) catch return;
                        } else if (std.mem.eql(u8, ht.text, "none")) {
                            code.append(self.allocator, 0x71) catch return;
                        } else if (std.mem.eql(u8, ht.text, "nofunc")) {
                            code.append(self.allocator, 0x73) catch return;
                        } else if (std.mem.eql(u8, ht.text, "noextern")) {
                            code.append(self.allocator, 0x72) catch return;
                        } else if (std.mem.eql(u8, ht.text, "noexn")) {
                            code.append(self.allocator, 0x68) catch return;
                        } else {
                            self.lexer.pos = save_pos;
                            self.peeked = save_peeked;
                            if (self.parseValType()) |vt| {
                                const raw: u32 = @bitCast(@intFromEnum(vt));
                                code.append(self.allocator, @truncate(raw)) catch return;
                            } else |_| {
                                code.append(self.allocator, 0x70) catch return;
                            }
                        }
                    } else {
                        code.append(self.allocator, 0x70) catch return;
                    }
                }
            },
            .kw_ref_func => {
                code.append(self.allocator, 0xd2) catch return;
                self.emitU32Imm(code);
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
                    var heap_type_idx: i32 = -1;
                    if (self.peek().kind == .identifier) {
                        const name = self.advance().text;
                        if (self.type_names.get(name)) |idx| {
                            heap_type_idx = @intCast(idx);
                        }
                    } else if (self.peek().kind == .integer) {
                        heap_type_idx = @intCast(self.parseU32() catch 0);
                    } else if (self.peek().kind == .kw_func) {
                        _ = self.advance();
                        heap_type_idx = 0x70; // func abstract heap type
                    } else if (self.peek().kind != .r_paren) {
                        const ht_text = self.advance().text;
                        if (std.mem.eql(u8, ht_text, "extern")) heap_type_idx = 0x6f
                        else if (std.mem.eql(u8, ht_text, "any")) heap_type_idx = 0x6e
                        else if (std.mem.eql(u8, ht_text, "i31")) heap_type_idx = 0x6c
                        else if (std.mem.eql(u8, ht_text, "eq")) heap_type_idx = 0x6d
                        else if (std.mem.eql(u8, ht_text, "struct")) heap_type_idx = 0x6b
                        else if (std.mem.eql(u8, ht_text, "array")) heap_type_idx = 0x6a;
                    }
                    if (self.peek().kind == .r_paren) _ = self.advance();
                    // Emit sub-opcode
                    const sub_op: u32 = if (tok.kind == .kw_ref_test)
                        (if (nullable) @as(u32, 0x15) else @as(u32, 0x14))
                    else
                        (if (nullable) @as(u32, 0x17) else @as(u32, 0x16));
                    self.emitLeb128U32(code, sub_op);
                    // Emit heap type as signed LEB128
                    if (heap_type_idx >= 0) {
                        var buf: [5]u8 = undefined;
                        const n = leb128.writeS32Leb128(&buf, heap_type_idx);
                        code.appendSlice(self.allocator, buf[0..n]) catch {};
                    }
                } else if (self.peek().kind == .kw_i31ref or self.peek().kind == .kw_eqref or
                    self.peek().kind == .kw_structref or self.peek().kind == .kw_arrayref or
                    self.peek().kind == .kw_funcref or self.peek().kind == .kw_anyref or
                    self.peek().kind == .kw_externref)
                {
                    // Bare type keyword: ref.cast i31ref etc.
                    const vt = self.advance();
                    nullable = true; // bare ref types are nullable
                    const heap_type_idx: i32 = switch (vt.kind) {
                        .kw_i31ref => 0x6c,
                        .kw_eqref => 0x6d,
                        .kw_structref => 0x6b,
                        .kw_arrayref => 0x6a,
                        .kw_funcref => 0x70,
                        .kw_anyref => 0x6e,
                        .kw_externref => 0x6f,
                        else => -1,
                    };
                    const sub_op: u32 = if (tok.kind == .kw_ref_test)
                        (if (nullable) @as(u32, 0x15) else @as(u32, 0x14))
                    else
                        (if (nullable) @as(u32, 0x17) else @as(u32, 0x16));
                    self.emitLeb128U32(code, sub_op);
                    if (heap_type_idx >= 0) {
                        var buf: [5]u8 = undefined;
                        const n = leb128.writeS32Leb128(&buf, heap_type_idx);
                        code.appendSlice(self.allocator, buf[0..n]) catch {};
                    }
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
                self.malformed = true;
            },
            .kw_catch, .kw_catch_ref, .kw_catch_all, .kw_catch_all_ref => {
                // catch/catch_ref/catch_all/catch_all_ref outside try_table is malformed
                self.malformed = true;
            },
            .kw_local => {
                // local in function body (after instructions) is an ordering error
                self.malformed = true;
            },
            else => {},
        }
    }

    fn emitBlockType(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        var buf: [6]u8 = undefined;
        const len = self.readBlockType(&buf);
        code.appendSlice(self.allocator, buf[0..len]) catch {};
    }

    fn readBlockType(self: *Parser, buf: *[6]u8) usize {
        // Check for (param ...) (result ...), (result <valtype>+), or bare (param ...)
        var param_count: u32 = 0;
        var param_types_buf: [16]types.ValType = undefined;
        var result_count: u32 = 0;
        var result_types_buf: [16]types.ValType = undefined;

        // Consume all (param ...) blocks
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_param) {
                _ = self.advance(); // consume 'param'
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const before_pos = self.lexer.pos;
                    if (self.parseValType()) |vt| {
                        if (param_count < 16) param_types_buf[param_count] = vt;
                        param_count += 1;
                    } else |_| {
                        if (self.lexer.pos == before_pos) _ = self.advance();
                        break;
                    }
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        // Consume all (result ...) blocks
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_result) {
                _ = self.advance(); // consume 'result'
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const before_pos = self.lexer.pos;
                    if (self.parseValType()) |vt| {
                        if (result_count < 16) result_types_buf[result_count] = vt;
                        result_count += 1;
                    } else |_| {
                        if (self.lexer.pos == before_pos) _ = self.advance();
                        break;
                    }
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        // No block type annotations found
        if (param_count == 0 and result_count == 0) {
            // Fall through to check for (type N) below
        } else if (param_count == 0 and result_count == 1 and @intFromEnum(result_types_buf[0]) > 0) {
            // Simple single-result block type: emit valtype byte (only for standard types)
            const raw: u32 = @bitCast(@intFromEnum(result_types_buf[0]));
            buf[0] = @truncate(raw);
            return 1;
        } else {
            // Multi-value: create a func type entry and emit type index
            if (self.module) |mod| {
                const p = self.allocator.alloc(types.ValType, param_count) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                @memcpy(p, param_types_buf[0..param_count]);
                const r = self.allocator.alloc(types.ValType, result_count) catch {
                    buf[0] = 0x40;
                    return 1;
                };
                @memcpy(r, result_types_buf[0..result_count]);
                const type_idx: u32 = @intCast(mod.module_types.items.len);
                mod.module_types.append(self.allocator, .{
                    .func_type = .{ .params = p, .results = r },
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

    fn emitGlobalIdx(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            if (self.global_names.get(tok.text)) |idx| {
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
        if (self.peek().kind == .identifier) {
            const tok = self.advance();
            // Check label stack first (for br/br_if $label)
            if (self.resolveLabelDepth(tok.text)) |depth| {
                self.emitLeb128U32(code, depth);
                return;
            }
            if (self.local_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.func_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.type_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.global_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.table_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.memory_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.data_names.get(tok.text)) |idx| {
                self.emitLeb128U32(code, idx);
                return;
            }
            if (self.elem_names.get(tok.text)) |idx| {
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
            return tok.text;
        }
        return null;
    }

    /// Resolve a label name to its branch depth (0 = innermost).
    fn resolveLabelDepth(self: *Parser, name: []const u8) ?u32 {
        if (self.label_stack.items.len == 0) return null;
        var i: u32 = 0;
        while (i < self.label_stack.items.len) : (i += 1) {
            const idx = self.label_stack.items.len - 1 - i;
            if (self.label_stack.items[idx]) |label| {
                if (std.mem.eql(u8, label, name)) return i;
            }
        }
        return null;
    }

    fn emitS32Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind != .integer) {
            self.malformed = true;
            self.emitLeb128S32(code, 0);
            return;
        }
        if (!isValidNumLiteral(tok.text)) self.malformed = true;
        const clean = stripUnderscores(tok.text);
        const text = clean.slice();
        const val = std.fmt.parseInt(i32, text, 0) catch blk: {
            // Try parsing as unsigned and reinterpret
            const uval = std.fmt.parseInt(u32, text, 0) catch {
                self.malformed = true;
                break :blk 0;
            };
            break :blk @as(i32, @bitCast(uval));
        };
        self.emitLeb128S32(code, val);
    }

    fn emitS64Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind != .integer) {
            self.malformed = true;
            self.emitLeb128S64(code, 0);
            return;
        }
        if (!isValidNumLiteral(tok.text)) self.malformed = true;
        const clean = stripUnderscores(tok.text);
        const text = clean.slice();
        const val = std.fmt.parseInt(i64, text, 0) catch blk: {
            const uval = std.fmt.parseInt(u64, text, 0) catch {
                self.malformed = true;
                break :blk 0;
            };
            break :blk @as(i64, @bitCast(uval));
        };
        self.emitLeb128S64(code, val);
    }

    fn emitF32Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind == .integer or tok.kind == .float) {
            if (!isValidNumLiteral(tok.text)) self.malformed = true;
            if (!isValidFloatLiteral(f32, tok.text)) self.malformed = true;
            const bits = parseF32Bits(tok.text);
            const le = std.mem.toBytes(bits);
            code.appendSlice(self.allocator, &le) catch {};
        } else {
            self.malformed = true;
            code.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }) catch {};
        }
    }

    fn emitF64Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind == .integer or tok.kind == .float) {
            if (!isValidNumLiteral(tok.text)) self.malformed = true;
            if (!isValidFloatLiteral(f64, tok.text)) self.malformed = true;
            const bits = parseF64Bits(tok.text);
            const le = std.mem.toBytes(bits);
            code.appendSlice(self.allocator, &le) catch {};
        } else {
            self.malformed = true;
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

    fn emitGenericOpcode(self: *Parser, text: []const u8, code: *std.ArrayListUnmanaged(u8)) void {
        // Map WAT opcode text (e.g. "i32.add") to binary opcode
        const opcode = opcodeFromText(text);
        if (opcode) |op| {
            if (op <= 0xff) {
                code.append(self.allocator, @truncate(op)) catch return;
                // Memory load/store instructions: emit mem_idx + memarg
                if (op >= 0x28 and op <= 0x3e) {
                    self.emitMemIdx(code);
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
                // Prefixed opcode: high byte(s) = prefix, low bits = sub-opcode
                const prefix: u8 = @truncate(op >> 16);
                const sub: u32 = if (prefix != 0) op & 0xffff else blk: {
                    // Legacy encoding: prefix in bits 8-15, sub in bits 0-7
                    break :blk op & 0xff;
                };
                const actual_prefix: u8 = if (prefix != 0) prefix else @truncate(op >> 8);
                code.append(self.allocator, actual_prefix) catch return;
                var buf: [5]u8 = undefined;
                const n = leb128.writeU32Leb128(&buf, sub);
                code.appendSlice(self.allocator, buf[0..n]) catch return;
                // Atomic/bulk memory instructions may have memarg or other immediates
                if (actual_prefix == 0xfe and sub >= 0x10) {
                    self.emitMemarg(code, 0);
                } else if (actual_prefix == 0xfc) {
                    self.emitBulkMemImm(sub, code);
                } else if (actual_prefix == 0xfd) {
                    self.emitSimdImm(sub, code);
                }
            }
        } else {
            // Unrecognized opcode text — flag as malformed
            self.malformed = true;
        }
    }

    /// Emit immediates for SIMD (0xfd prefix) instructions.
    fn emitSimdImm(self: *Parser, sub: u32, code: *std.ArrayListUnmanaged(u8)) void {
        if (sub <= 0x0b or (sub >= 0x5c and sub <= 0x5d)) {
            // v128.load/store variants + load_zero: memarg
            self.emitMemIdx(code);
            self.emitMemarg(code, 0);
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
            self.emitMemIdx(code);
            self.emitMemarg(code, 0);
            const lane_val = self.parseU32() catch 0;
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

    /// Emit memory index immediate for memory.size/memory.grow.
    /// Same as emitMemIdx — resolves $name or emits 0.
    fn emitMemIdxImm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        self.emitMemIdx(code);
    }

    fn emitMemarg(self: *Parser, code: *std.ArrayListUnmanaged(u8), opcode: u8) void {
        _ = opcode;
        // Parse optional offset=N and align=N
        var alignment: u32 = 0;
        var offset: u32 = 0;
        var has_align = false;
        for (0..2) |_| {
            if (self.peek().kind == .nat_eq) {
                const tok = self.advance();
                // Format: "offset=N" or "align=N"
                if (std.mem.startsWith(u8, tok.text, "offset=")) {
                    offset = std.fmt.parseInt(u32, tok.text[7..], 0) catch {
                        self.malformed = true;
                        continue;
                    };
                } else if (std.mem.startsWith(u8, tok.text, "align=")) {
                    alignment = std.fmt.parseInt(u32, tok.text[6..], 0) catch {
                        self.malformed = true;
                        continue;
                    };
                    has_align = true;
                }
            }
        }
        // Convert alignment to log2 and validate
        var log2_align: u32 = 0;
        if (has_align) {
            if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
                self.malformed = true;
            } else {
                log2_align = @ctz(alignment);
            }
        }
        self.emitLeb128U32(code, log2_align);
        self.emitLeb128U32(code, offset);
    }

    fn emitBulkMemImm(self: *Parser, sub: u32, code: *std.ArrayListUnmanaged(u8)) void {
        switch (sub) {
            0x08 => {
                // memory.init: WAT syntax is `memory.init $mem $data` or `memory.init $data`
                // Binary format expects: data_idx, mem_idx
                const first_kind = self.peek().kind;
                if (first_kind == .identifier or first_kind == .integer) {
                    var first_code = std.ArrayListUnmanaged(u8){};
                    self.emitU32Imm(&first_code);
                    const second_kind = self.peek().kind;
                    if (second_kind == .identifier or second_kind == .integer) {
                        // Two immediates: first is mem_idx, second is data_idx
                        // Binary order: data_idx, mem_idx
                        var second_code = std.ArrayListUnmanaged(u8){};
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
                    var first_code = std.ArrayListUnmanaged(u8){};
                    self.emitU32Imm(&first_code);
                    const second_kind = self.peek().kind;
                    if (second_kind == .identifier or second_kind == .integer) {
                        // Two immediates: first is table_idx, second is elem_idx
                        // Binary order: elem_idx, table_idx
                        var second_code = std.ArrayListUnmanaged(u8){};
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
            if (self.peek().kind == .l_paren) {
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
        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
            if (self.peek().kind == .l_paren) {
                _ = self.advance(); // consume '('
                self.parseInitExprFolded(code);
            } else {
                self.parseInitExprPlain(code);
            }
        }
    }

    /// Parse a folded (parenthesized) init expression instruction.
    fn parseInitExprFolded(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.peek();
        switch (tok.kind) {
            .kw_i32_const, .kw_i64_const, .kw_f32_const, .kw_f64_const,
            .kw_ref_null, .kw_ref_func, .kw_global_get => {
                // Parse nested args first, then the instruction
                self.parseInitExprPlain(code);
                // Skip to closing paren
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.parseInitExprFolded(code);
                    } else {
                        self.parseInitExprPlain(code);
                    }
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            },
            else => {
                // Extended constant expression in folded form (e.g. i32.add).
                // Emit instruction, then operands, then reorder so operands precede instruction.
                const instr_start = code.items.len;
                self.parsePlainInstr(code);
                const instr_end = code.items.len;
                const instr_len = instr_end - instr_start;
                // Parse sub-expressions (operands)
                var has_operands = false;
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    if (self.peek().kind == .l_paren) {
                        _ = self.advance();
                        self.parseInitExprFolded(code);
                        has_operands = true;
                    } else {
                        self.parseInitExprPlain(code);
                        has_operands = true;
                    }
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
        self.parsePlainInstr(code);
    }

    /// Parse an init expression that is wrapped in parens, e.g. (i32.const 0).
    /// This handles a single folded instruction expression.
    fn parseInitExprWrapped(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        if (self.peek().kind == .l_paren) {
            _ = self.advance(); // consume '('
            self.parseInitExprFolded(code);
        }
    }

    fn parseTable(self: *Parser, module: *Mod.Module) ParseError!void {
        const table_idx: u32 = @intCast(module.tables.items.len);
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            if (self.table_names.get(name)) |existing| {
                if (existing != table_idx and existing < table_idx) self.malformed = true;
            }
            self.table_names.put(self.allocator, name, table_idx) catch {};
        }

        // Check for i64 keyword (table64)
        var is_table64 = false;
        if (self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_table64 = true;
        }

        // Handle inline (export "name") and (import "mod" "name") on tables
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
                    .kind = .table,
                    .var_ = .{ .index = table_idx },
                }) catch return error.OutOfMemory;
            } else if (self.peek().kind == .kw_import) {
                _ = self.advance(); // consume 'import'
                const mod_name = self.parseName(self.advance().text);
                const field_name = self.parseName(self.advance().text);
                try self.expect(.r_paren); // close (import ...)
                // Check for i64 keyword after import (table64)
                if (!is_table64 and self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_table64 = true;
                }
                const initial = try self.parseU32();
                var limits = types.Limits{ .initial = initial };
                if (self.peek().kind == .integer) {
                    limits.max = try self.parseU32();
                    limits.has_max = true;
                }
                const elem_type = try self.parseValType();
                try module.tables.append(self.allocator, .{
                    .@"type" = .{ .elem_type = elem_type, .limits = limits },
                    .is_import = true,
                    .is_table64 = is_table64,
                });
                module.num_table_imports += 1;
                var import = Mod.Import{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .table,
                };
                import.table = .{ .elem_type = elem_type, .limits = limits };
                try module.imports.append(self.allocator, import);
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        // Check for i64 keyword after export/import clauses
        if (!is_table64 and self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_table64 = true;
        }

        // Check for inline element syntax: (table elemtype (elem ...))
        if (self.peek().kind != .integer) {
            // elemtype first — inline elem syntax
            const elem_type = self.parseValType() catch .funcref;
            // Parse (elem func_refs...)
            var elem_indices: std.ArrayListUnmanaged(Mod.Var) = .{};
            if (self.peek().kind == .l_paren) {
                const sp2 = self.lexer.pos;
                const spk2 = self.peeked;
                _ = self.advance();
                if (self.peek().kind == .kw_elem) {
                    _ = self.advance();
                    while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                        if (self.peek().kind == .l_paren) {
                            _ = self.advance();
                            if (self.peek().kind == .kw_ref_func) {
                                _ = self.advance();
                                if (self.peek().kind == .identifier) {
                                    const tok = self.advance();
                                    const idx = self.func_names.get(tok.text) orelse 0;
                                    elem_indices.append(self.allocator, .{ .index = idx }) catch {};
                                } else if (self.peek().kind == .integer) {
                                    const idx = self.parseU32() catch 0;
                                    elem_indices.append(self.allocator, .{ .index = idx }) catch {};
                                }
                            } else if (self.peek().kind == .kw_ref_null) {
                                _ = self.advance();
                                if (self.peek().kind != .r_paren and self.peek().kind != .eof)
                                    _ = self.advance();
                                elem_indices.append(self.allocator, .{ .index = std.math.maxInt(u32) }) catch {};
                            } else {
                                try self.skipSExpr();
                            }
                            if (self.peek().kind == .r_paren) _ = self.advance();
                        } else if (self.peek().kind == .identifier) {
                            const tok = self.advance();
                            if (self.func_names.get(tok.text)) |idx| {
                                elem_indices.append(self.allocator, .{ .index = idx }) catch {};
                            } else {
                                elem_indices.append(self.allocator, .{ .index = 0 }) catch {};
                            }
                        } else if (self.peek().kind == .integer) {
                            const idx = self.parseU32() catch 0;
                            elem_indices.append(self.allocator, .{ .index = idx }) catch {};
                        } else {
                            _ = self.advance();
                        }
                    }
                    if (self.peek().kind == .r_paren) _ = self.advance();
                } else {
                    self.lexer.pos = sp2;
                    self.peeked = spk2;
                }
            }
            const initial: u64 = @intCast(elem_indices.items.len);
            try module.tables.append(self.allocator, .{
                .@"type" = .{ .elem_type = elem_type, .limits = .{ .initial = initial } },
                .is_table64 = is_table64,
            });
            // Create active element segment for the inline elements
            if (elem_indices.items.len > 0) {
                const ob = self.allocator.alloc(u8, 2) catch {
                    elem_indices.deinit(self.allocator);
                    return error.OutOfMemory;
                };
                if (is_table64) {
                    ob[0] = 0x42; // i64.const
                } else {
                    ob[0] = 0x41; // i32.const
                }
                ob[1] = 0x00; // 0
                try module.elem_segments.append(self.allocator, .{
                    .kind = .active,
                    .table_var = .{ .index = @intCast(module.tables.items.len - 1) },
                    .elem_type = elem_type,
                    .elem_var_indices = elem_indices,
                    .offset_expr_bytes = ob,
                    .owns_offset_expr_bytes = true,
                });
            } else {
                elem_indices.deinit(self.allocator);
            }
            return;
        }

        const initial = try self.parseU32();
        var limits = types.Limits{ .initial = initial };
        if (self.peek().kind == .integer) {
            limits.max = try self.parseU32();
            limits.has_max = true;
        }
        const elem_type = try self.parseValType();
        // Parse optional table initializer expression: (ref.null func) etc.
        var table_init_bytes: []const u8 = &.{};
        if (self.peek().kind == .l_paren) {
            _ = self.advance(); // consume '('
            var init_code: std.ArrayListUnmanaged(u8) = .{};
            const inner = self.advance();
            if (inner.kind == .kw_ref_null) {
                init_code.append(self.allocator, 0xd0) catch {};
                if (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    _ = self.advance(); // consume heaptype
                }
                init_code.append(self.allocator, 0x70) catch {};
            } else if (inner.kind == .kw_ref_func) {
                init_code.append(self.allocator, 0xd2) catch {};
                if (self.peek().kind == .identifier) {
                    const fidx = self.func_names.get(self.advance().text) orelse 0;
                    self.emitLeb128U32(&init_code, fidx);
                } else {
                    self.emitLeb128U32(&init_code, self.parseU32() catch 0);
                }
            } else if (inner.kind == .kw_global_get) {
                init_code.append(self.allocator, 0x23) catch {};
                self.emitGlobalIdx(&init_code);
            } else {
                // Unknown/invalid init expr — mark as malformed
                self.malformed = true;
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) _ = self.advance();
            }
            init_code.append(self.allocator, 0x0b) catch {};
            if (self.peek().kind == .r_paren) _ = self.advance();
            table_init_bytes = init_code.toOwnedSlice(self.allocator) catch &.{};
        }
        try module.tables.append(self.allocator, .{
            .@"type" = .{ .elem_type = elem_type, .limits = limits },
            .init_expr_bytes = table_init_bytes,
            .is_table64 = is_table64,
        });
    }

    fn parseMemory(self: *Parser, module: *Mod.Module) ParseError!void {
        const mem_idx: u32 = @intCast(module.memories.items.len);
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            if (self.memory_names.get(name)) |existing| {
                if (existing != mem_idx and existing < mem_idx) self.malformed = true;
            }
            self.memory_names.put(self.allocator, name, mem_idx) catch {};
        }

        // Check for i64 keyword (memory64)
        var is_memory64 = false;
        if (self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_memory64 = true;
        }

        // Handle inline (export "name") declarations
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .memory,
                    .var_ = .{ .index = mem_idx },
                }) catch return error.OutOfMemory;
            } else if (self.peek().kind == .kw_data) {
                // Inline (data "...") abbreviation
                _ = self.advance(); // consume 'data'
                var data_parts: std.ArrayListUnmanaged(u8) = .{};
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
                    .type = .{ .limits = .{ .initial = pages, .max = pages, .has_max = true } },
                    .is_memory64 = is_memory64,
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
                const mod_name = self.parseName(self.advance().text);
                const field_name = self.parseName(self.advance().text);
                try self.expect(.r_paren); // close (import ...)
                // Check for i64 keyword after import (memory64)
                if (!is_memory64 and self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_memory64 = true;
                }
                const initial = try self.parseU32();
                var limits = types.Limits{ .initial = initial };
                if (self.peek().kind == .integer) {
                    limits.max = try self.parseU32();
                    limits.has_max = true;
                }
                try module.memories.append(self.allocator, .{
                    .type = .{ .limits = limits },
                    .is_import = true,
                    .is_memory64 = is_memory64,
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
        if (!is_memory64 and self.peek().kind == .kw_i64) {
            _ = self.advance();
            is_memory64 = true;
        }

        const initial = try self.parseU32();
        var limits = types.Limits{ .initial = initial };
        if (self.peek().kind == .integer) {
            limits.max = try self.parseU32();
            limits.has_max = true;
        }
        try module.memories.append(self.allocator, .{
            .@"type" = .{ .limits = limits },
            .is_memory64 = is_memory64,
        });
    }

    fn parseGlobal(self: *Parser, module: *Mod.Module) ParseError!void {
        const global_idx: u32 = @intCast(module.globals.items.len);
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            // Detect duplicate $name: prescan sets index on first occurrence,
            // so if the existing index doesn't match ours AND it's a lower
            // index (already processed), it's a genuine duplicate.
            if (self.global_names.get(name)) |existing| {
                if (existing != global_idx and existing < global_idx) self.malformed = true;
            }
            self.global_names.put(self.allocator, name, global_idx) catch {};
        }

        // Handle inline (export "name") and (import "mod" "name") declarations
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                const name_tok = self.advance();
                const exp_name = self.parseName(name_tok.text);
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .global,
                    .var_ = .{ .index = global_idx },
                }) catch return error.OutOfMemory;
            } else if (self.peek().kind == .kw_import) {
                _ = self.advance(); // consume 'import'
                const mod_name = self.parseName(self.advance().text);
                const field_name = self.parseName(self.advance().text);
                try self.expect(.r_paren); // close (import ...)

                // Parse type after import
                var mutability: types.Mutability = .immutable;
                var val_type: types.ValType = undefined;
                if (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_mut) {
                        _ = self.advance();
                        mutability = .mutable;
                        val_type = try self.parseValType();
                        try self.expect(.r_paren);
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        val_type = try self.parseValType();
                    }
                } else {
                    val_type = try self.parseValType();
                }
                try module.globals.append(self.allocator, .{
                    .type = .{ .val_type = val_type, .mutability = mutability },
                    .is_import = true,
                });
                module.num_global_imports += 1;
                var import = Mod.Import{
                    .module_name = mod_name,
                    .field_name = field_name,
                    .kind = .global,
                };
                import.global = .{ .val_type = val_type, .mutability = mutability };
                try module.imports.append(self.allocator, import);
                return;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
        }

        var mutability: types.Mutability = .immutable;
        var val_type: types.ValType = undefined;

        // Check for (mut <valtype>) — requires two-token lookahead
        if (self.peek().kind == .l_paren) {
            // Save lexer state to allow backtracking
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_mut) {
                _ = self.advance();
                mutability = .mutable;
                val_type = try self.parseValType();
                try self.expect(.r_paren);
            } else {
                // Not (mut ...) — restore and let parseValType handle it
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                val_type = try self.parseValType();
            }
        } else {
            val_type = try self.parseValType();
        }

        // Encode init expression into bytecode
        var code: std.ArrayListUnmanaged(u8) = .{};
        defer code.deinit(self.allocator);
        self.parseInitExpr(&code);

        const owned = code.toOwnedSlice(self.allocator) catch &.{};

        try module.globals.append(self.allocator, .{
            .type = .{ .val_type = val_type, .mutability = mutability },
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
                var imp_params: std.ArrayListUnmanaged(types.ValType) = .{};
                defer imp_params.deinit(self.allocator);
                var inline_tag_type_idx: u32 = std.math.maxInt(u32);
                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
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
        var params_list: std.ArrayListUnmanaged(types.ValType) = .{};
        defer params_list.deinit(self.allocator);
        var results_list: std.ArrayListUnmanaged(types.ValType) = .{};
        defer results_list.deinit(self.allocator);
        var tag_type_idx: u32 = std.math.maxInt(u32);
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance();
            if (self.peek().kind == .kw_param) {
                _ = self.advance();
                if (self.peek().kind == .identifier) _ = self.advance();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
                    params_list.append(self.allocator, vt) catch {};
                }
                if (self.peek().kind == .r_paren) _ = self.advance();
            } else if (self.peek().kind == .kw_result) {
                _ = self.advance();
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
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
        try module.tags.append(self.allocator, .{
            .@"type" = .{ .sig = .{ .params = params, .results = results } },
            .type_idx = tag_type_idx,
        });
    }

    fn parseImport(self: *Parser, module: *Mod.Module) ParseError!void {
        const module_name = self.advance().text; // string literal
        const field_name = self.advance().text;
        // Strip quotes
        const mod_str = self.parseName(module_name);
        const field_str = self.parseName(field_name);

        try self.expect(.l_paren);
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
                if (self.peek().kind == .identifier) {
                    const fname = self.advance().text;
                    if (self.func_names.getOrPut(self.allocator, fname)) |gop| {
                        if (gop.found_existing and gop.value_ptr.* != import_func_idx) self.malformed = true;
                        gop.value_ptr.* = import_func_idx;
                    } else |_| {}
                }
                var type_index: types.Index = 0;
                var params_list: std.ArrayListUnmanaged(types.ValType) = .{};
                defer params_list.deinit(self.allocator);
                var results_list: std.ArrayListUnmanaged(types.ValType) = .{};
                defer results_list.deinit(self.allocator);
                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        type_index = try self.parseTypeIdx();
                        try self.expect(.r_paren);
                    } else if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
                            params_list.append(self.allocator, vt) catch {};
                        }
                        try self.expect(.r_paren);
                    } else if (self.peek().kind == .kw_result) {
                        _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
                            results_list.append(self.allocator, vt) catch {};
                        }
                        try self.expect(.r_paren);
                    } else {
                        self.lexer.pos = sp2;
                        self.peeked = spk2;
                        break;
                    }
                }
                if (params_list.items.len > 0 or results_list.items.len > 0) {
                    const params = params_list.toOwnedSlice(self.allocator) catch &.{};
                    const results = results_list.toOwnedSlice(self.allocator) catch &.{};
                    type_index = @intCast(module.module_types.items.len);
                    module.module_types.append(self.allocator, .{
                        .func_type = .{ .params = params, .results = results },
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
                if (self.peek().kind == .identifier) {
                    const mname = self.advance().text;
                    if (self.memory_names.get(mname)) |existing| {
                        if (existing != import_mem_idx and existing < import_mem_idx) self.malformed = true;
                    }
                    self.memory_names.put(self.allocator, mname, import_mem_idx) catch {};
                }
                // Check for i64 keyword (memory64)
                var is_memory64 = false;
                if (self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_memory64 = true;
                }
                const initial = try self.parseU32();
                var limits = types.Limits{ .initial = initial };
                if (self.peek().kind == .integer) {
                    limits.max = try self.parseU32();
                    limits.has_max = true;
                }
                import.memory = .{ .limits = limits };
                try module.memories.append(self.allocator, .{
                    .type = .{ .limits = limits },
                    .is_import = true,
                    .is_memory64 = is_memory64,
                });
                module.num_memory_imports += 1;
            },
            .kw_table => {
                import.kind = .table;
                const import_table_idx: u32 = @intCast(module.tables.items.len);
                if (self.peek().kind == .identifier) {
                    const tname = self.advance().text;
                    if (self.table_names.get(tname)) |existing| {
                        if (existing != import_table_idx and existing < import_table_idx) self.malformed = true;
                    }
                    self.table_names.put(self.allocator, tname, import_table_idx) catch {};
                }
                // Check for i64 keyword (table64)
                var is_table64 = false;
                if (self.peek().kind == .kw_i64) {
                    _ = self.advance();
                    is_table64 = true;
                }
                const initial = try self.parseU32();
                var limits = types.Limits{ .initial = initial };
                if (self.peek().kind == .integer) {
                    limits.max = try self.parseU32();
                    limits.has_max = true;
                }
                const elem_type = try self.parseValType();
                import.table = .{ .elem_type = elem_type, .limits = limits };
                try module.tables.append(self.allocator, .{
                    .type = .{ .elem_type = elem_type, .limits = limits },
                    .is_import = true,
                    .is_table64 = is_table64,
                });
                module.num_table_imports += 1;
            },
            .kw_global => {
                import.kind = .global;
                const import_global_idx: u32 = @intCast(module.globals.items.len);
                if (self.peek().kind == .identifier) {
                    const gname = self.advance().text;
                    if (self.global_names.get(gname)) |existing| {
                        if (existing != import_global_idx and existing < import_global_idx) self.malformed = true;
                    }
                    self.global_names.put(self.allocator, gname, import_global_idx) catch {};
                }
                var mutability: types.Mutability = .immutable;
                var val_type: types.ValType = undefined;
                if (self.peek().kind == .l_paren) {
                    const save_pos = self.lexer.pos;
                    const save_peeked = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_mut) {
                        _ = self.advance();
                        mutability = .mutable;
                        val_type = try self.parseValType();
                        try self.expect(.r_paren);
                    } else {
                        self.lexer.pos = save_pos;
                        self.peeked = save_peeked;
                        val_type = try self.parseValType();
                    }
                } else {
                    val_type = try self.parseValType();
                }
                import.global = .{ .val_type = val_type, .mutability = mutability };
                try module.globals.append(self.allocator, .{
                    .type = .{ .val_type = val_type, .mutability = mutability },
                    .is_import = true,
                });
                module.num_global_imports += 1;
            },
            .kw_tag => {
                import.kind = .tag;
                const import_tag_idx: u32 = @intCast(module.tags.items.len);
                if (self.peek().kind == .identifier) {
                    const tname = self.advance().text;
                    self.tag_names.put(self.allocator, tname, import_tag_idx) catch {};
                }
                var params_list: std.ArrayListUnmanaged(types.ValType) = .{};
                defer params_list.deinit(self.allocator);
                var results_list: std.ArrayListUnmanaged(types.ValType) = .{};
                defer results_list.deinit(self.allocator);
                var imp_tag_type_idx: u32 = std.math.maxInt(u32);
                while (self.peek().kind == .l_paren) {
                    const sp2 = self.lexer.pos;
                    const spk2 = self.peeked;
                    _ = self.advance();
                    if (self.peek().kind == .kw_param) {
                        _ = self.advance();
                        if (self.peek().kind == .identifier) _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
                            params_list.append(self.allocator, vt) catch {};
                        }
                        if (self.peek().kind == .r_paren) _ = self.advance();
                    } else if (self.peek().kind == .kw_result) {
                        _ = self.advance();
                        while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                            const vt = self.parseValType() catch break;
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
            if (self.peek().kind == .l_paren) {
                _ = self.advance();
                try self.skipSExpr();
                try self.expect(.r_paren);
            } else if (self.peek().kind == .eof) {
                return error.InvalidModule;
            } else {
                _ = self.advance();
            }
        }
        try self.expect(.r_paren); // close the desc (func/memory/...)
        try module.imports.append(self.allocator, import);
    }

    fn parseExport(self: *Parser, module: *Mod.Module) ParseError!void {
        const name_tok = self.advance();
        const exp_name = self.parseName(name_tok.text);
        try self.expect(.l_paren);
        const kind_tok = self.advance();
        const kind: types.ExternalKind = switch (kind_tok.kind) {
            .kw_func => .func,
            .kw_memory => .memory,
            .kw_table => .table,
            .kw_global => .global,
            .kw_tag => .tag,
            else => return error.UnexpectedToken,
        };
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
        try self.expect(.r_paren);
        try module.exports.append(self.allocator, .{
            .name = exp_name,
            .kind = kind,
            .var_ = .{ .index = index },
        });
    }

    fn parseStart(self: *Parser, module: *Mod.Module) ParseError!void {
        if (module.start_var != null) return error.InvalidModule;
        const index = try self.parseFuncIdx();
        module.start_var = .{ .index = index };
    }

    fn parseElem(self: *Parser, module: *Mod.Module) ParseError!void {
        var seg = Mod.ElemSegment{};
        const elem_idx: u32 = @intCast(module.elem_segments.items.len);
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            self.elem_names.put(self.allocator, name, elem_idx) catch {};
        }

        // Parse offset expression and elem indices
        seg.elem_var_indices = .{};

        // Check for declarative/passive keywords
        if (self.peek().kind == .kw_declare) {
            _ = self.advance();
            seg.kind = .declared;
        }

        // Encode offset expression if present (active segment)
        var offset_code: std.ArrayListUnmanaged(u8) = .{};
        defer offset_code.deinit(self.allocator);
        var has_offset = false;
        // Track elem type keyword presence for validation
        var has_elem_type = false;
        var elem_type_is_externref = false;
        // Encode elem expressions
        var elem_expr_code: std.ArrayListUnmanaged(u8) = .{};
        defer elem_expr_code.deinit(self.allocator);
        var elem_expr_count: u32 = 0;

        while (self.peek().kind != .r_paren) {
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
                    if (self.peek().kind == .r_paren) _ = self.advance();
                } else if (has_elem_type) {
                    // Post-type elem expressions (passive/declarative segment)
                    if (inner_kind == .kw_item) {
                        _ = self.advance(); // consume 'item'
                    }
                    const expr_start = elem_expr_code.items.len;
                    self.parseInitExpr(&elem_expr_code);
                    elem_expr_code.append(self.allocator, 0x0b) catch {};
                    elem_expr_count += 1;
                    // Extract func index from emitted bytecode for elem_var_indices
                    const expr_bytes = elem_expr_code.items[expr_start .. elem_expr_code.items.len - 1];
                    if (expr_bytes.len >= 1 and expr_bytes[0] == 0xd2) {
                        if (leb128.readU32Leb128(expr_bytes[1..])) |r| {
                            seg.elem_var_indices.append(self.allocator, .{ .index = r.value }) catch {};
                        } else |_| {
                            seg.elem_var_indices.append(self.allocator, .{ .index = 0 }) catch {};
                        }
                    } else if (expr_bytes.len >= 1 and expr_bytes[0] == 0xd0) {
                        seg.elem_var_indices.append(self.allocator, .{ .index = std.math.maxInt(u32) }) catch {};
                    }
                    // For other expressions (ref.i31 etc.), don't add to var_indices;
                    // they will be evaluated from elem_expr_bytes at instantiation time.
                    try self.expect(.r_paren);
                } else if (!has_offset) {
                    // First folded expression is the offset expression
                    self.lexer.pos = save_pos;
                    self.peeked = save_peeked;
                    self.parseInitExprWrapped(&offset_code);
                    has_offset = true;
                } else if (has_elem_type) {
                    // Post-offset with explicit elem type: encode elem expressions
                    if (inner_kind == .kw_item) {
                        _ = self.advance(); // consume 'item'
                    }
                    const expr_start2 = elem_expr_code.items.len;
                    self.parseInitExpr(&elem_expr_code);
                    elem_expr_code.append(self.allocator, 0x0b) catch {};
                    elem_expr_count += 1;
                    const expr_bytes2 = elem_expr_code.items[expr_start2 .. elem_expr_code.items.len - 1];
                    if (expr_bytes2.len >= 1 and expr_bytes2[0] == 0xd2) {
                        if (leb128.readU32Leb128(expr_bytes2[1..])) |r| {
                            seg.elem_var_indices.append(self.allocator, .{ .index = r.value }) catch {};
                        } else |_| {
                            seg.elem_var_indices.append(self.allocator, .{ .index = 0 }) catch {};
                        }
                    } else if (expr_bytes2.len >= 1 and expr_bytes2[0] == 0xd0) {
                        seg.elem_var_indices.append(self.allocator, .{ .index = std.math.maxInt(u32) }) catch {};
                    }
                    try self.expect(.r_paren);
                } else if (!has_elem_type and (inner_kind == .kw_ref or inner_kind == .kw_ref_null)) {
                    // (ref ...) or (ref null ...) — elem type declaration
                    self.skipToRParen();
                    has_elem_type = true;
                } else {
                    // Post-offset without explicit type: skip
                    try self.skipSExpr();
                    try self.expect(.r_paren);
                }
            } else if (self.peek().kind == .integer) {
                const idx = try self.parseU32();
                try seg.elem_var_indices.append(self.allocator, .{ .index = idx });
            } else if (self.peek().kind == .identifier) {
                const id_tok = self.advance();
                const func_idx = self.func_names.get(id_tok.text) orelse 0;
                try seg.elem_var_indices.append(self.allocator, .{ .index = func_idx });
            } else if (self.peek().kind == .kw_funcref) {
                _ = self.advance();
                has_elem_type = true;
            } else if (self.peek().kind == .kw_externref) {
                _ = self.advance();
                has_elem_type = true;
                elem_type_is_externref = true;
            } else if (self.peek().kind == .kw_anyref or
                self.peek().kind == .kw_i31ref or
                self.peek().kind == .kw_eqref or
                self.peek().kind == .kw_structref or
                self.peek().kind == .kw_arrayref)
            {
                _ = self.advance();
                has_elem_type = true;
            } else if (self.peek().kind == .kw_func) {
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

        if (has_elem_type) {
            if (elem_type_is_externref) {
                seg.elem_type = .externref;
            }
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
        if (self.peek().kind == .identifier) _ = self.advance();

        // Parse offset expression
        var offset_code: std.ArrayListUnmanaged(u8) = .{};
        defer offset_code.deinit(self.allocator);
        var has_offset = false;

        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('

            const inner_kind = self.peek().kind;
            if (inner_kind == .kw_offset) {
                _ = self.advance(); // consume 'offset'
                self.parseInitExpr(&offset_code);
                try self.expect(.r_paren);
                has_offset = true;
            } else if (inner_kind == .kw_memory) {
                // (memory $m) — resolve memory index
                _ = self.advance(); // consume 'memory'
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
                try self.expect(.r_paren);
            } else if (!has_offset) {
                // First non-offset/memory parenthesized expr is the offset expression
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                self.parseInitExprWrapped(&offset_code);
                has_offset = true;
            } else {
                try self.skipSExpr();
                try self.expect(.r_paren);
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
        var data_parts: std.ArrayListUnmanaged(u8) = .{};
        defer data_parts.deinit(self.allocator);
        while (self.peek().kind == .string) {
            const tok = self.advance();
            const stripped = stripQuotes(tok.text);
            decodeWatStringInto(stripped, &data_parts, self.allocator);
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
                    self.malformed = true;
                }
                if (self.module) |m| {
                    m.owned_strings.append(self.allocator, decoded) catch {};
                }
                return decoded;
            }
        }
        if (!std.unicode.utf8ValidateSlice(raw)) {
            self.malformed = true;
        }
        return raw;
    }
};

/// Decode WAT string escape sequences (\nn hex, \t, \n, \r, \\, \").
fn decodeWatString(allocator: std.mem.Allocator, raw: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
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
        .{ "i31.get_u", 0xfb1d },
        .{ "i31.get_s", 0xfb1e },
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
    return map.get(text);
}

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
    try std.testing.expectEqual(types.ValType.ref_null, module.globals.items[0].type.val_type);
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
