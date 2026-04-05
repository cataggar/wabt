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
    defer p.label_stack.deinit(allocator);
    var module = Mod.Module.init(allocator);
    errdefer module.deinit();
    p.module = &module;

    // Pre-scan: collect function, type, and global names for forward references.
    prescanNames(source, &p.func_names, &p.type_names, &p.global_names, allocator);

    try p.expect(.l_paren);
    try p.expect(.kw_module);

    // Optional module name
    if (p.peek().kind == .identifier) {
        module.name = p.advance().text;
    }

    // Parse module fields
    while (p.peek().kind == .l_paren or p.peek().kind == .annotation) {
        // Skip annotations: (@id ...) — consume tokens until matching ')'
        if (p.peek().kind == .annotation) {
            _ = p.advance(); // consume annotation token
            try p.skipAnnotation();
            continue;
        }
        _ = p.advance(); // consume '('
        const kw = p.advance();
        switch (kw.kind) {
            .kw_type => try p.parseType(&module),
            .kw_func => try p.parseFunc(&module),
            .kw_table => try p.parseTable(&module),
            .kw_memory => try p.parseMemory(&module),
            .kw_global => try p.parseGlobal(&module),
            .kw_import => try p.parseImport(&module),
            .kw_export => try p.parseExport(&module),
            .kw_start => try p.parseStart(&module),
            .kw_elem => try p.parseElem(&module),
            .kw_data => try p.parseData(&module),
            .kw_rec => try p.parseRec(&module),
            .kw_definition => try p.skipSExpr(),
            else => try p.skipSExpr(),
        }
        try p.expect(.r_paren);
    }

    try p.expect(.r_paren);
    if (p.malformed) return error.InvalidModule;
    return module;
}

/// Fast pre-scan of source text to collect function, type, and global names
/// for forward reference resolution. Uses a separate lexer pass.
fn prescanNames(
    source: []const u8,
    func_names: *std.StringArrayHashMapUnmanaged(u32),
    type_names: *std.StringArrayHashMapUnmanaged(u32),
    global_names: *std.StringArrayHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) void {
    var lex = Lexer.init(source);
    var func_idx: u32 = 0;
    var type_idx: u32 = 0;
    var global_idx: u32 = 0;

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
        } else if (tok.kind == .kw_import) {
            // Imports define indices for their kind. We need to find
            // (import "mod" "name" (func $name ...)) to count import funcs.
            // Skip strings
            tok = lex.next(); // module string
            tok = lex.next(); // field string
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
                }
            }
        }
        // Skip to matching ')'
        var depth: u32 = 1;
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
    /// Map from function $name to index (for name resolution in call instructions).
    func_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from type $name to index (for name resolution).
    type_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from local/param $name to index (per-function, cleared for each func).
    local_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Map from global $name to index.
    global_names: std.StringArrayHashMapUnmanaged(u32) = .{},
    /// Stack of label $names for block/loop/if — most recent label at the end.
    label_stack: std.ArrayListUnmanaged(?[]const u8) = .{},

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
                else => {},
            }
        }
    }

    fn parseU32(self: *Parser) ParseError!u32 {
        const tok = self.advance();
        if (tok.kind != .integer) return error.InvalidNumber;
        return std.fmt.parseInt(u32, tok.text, 0) catch return error.InvalidNumber;
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
                // Skip heap type (could be $id, keyword like func/extern/any, or index)
                if (self.peek().kind != .r_paren) {
                    _ = self.advance();
                }
                try self.expect(.r_paren);
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
            else => error.InvalidType,
        };
    }

    fn parseFuncSig(self: *Parser, module: *Mod.Module) ParseError!struct { params: []const types.ValType, results: []const types.ValType } {
        var params: std.ArrayListUnmanaged(types.ValType) = .{};
        errdefer params.deinit(self.allocator);
        var results: std.ArrayListUnmanaged(types.ValType) = .{};
        errdefer results.deinit(self.allocator);

        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance();
            const kw = self.peek();
            if (kw.kind == .kw_param) {
                _ = self.advance();
                // Optional identifier
                if (self.peek().kind == .identifier) _ = self.advance();
                while (self.peek().kind != .r_paren) {
                    try params.append(self.allocator, try self.parseValType());
                }
                try self.expect(.r_paren);
            } else if (kw.kind == .kw_result) {
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
        // (type $name? (func (param ...) (result ...)))
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            self.type_names.put(self.allocator, name, @intCast(module.module_types.items.len)) catch {};
        }
        try self.expect(.l_paren);
        // The inner form may be func, struct, or array (GC proposal) — skip non-func
        if (self.peek().kind == .kw_func) {
            _ = self.advance();
            const sig = try self.parseFuncSig(module);
            try self.expect(.r_paren);
            try module.module_types.append(self.allocator, .{
                .func_type = .{ .params = sig.params, .results = sig.results },
            });
        } else {
            // GC composite type (struct, array, sub, etc.) — skip for now
            try self.skipSExpr();
            try self.expect(.r_paren);
            try module.module_types.append(self.allocator, .{
                .func_type = .{},
            });
        }
    }

    fn parseRec(self: *Parser, module: *Mod.Module) ParseError!void {
        // (rec (type ...) (type ...) ...)
        while (self.peek().kind == .l_paren) {
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_type) {
                _ = self.advance(); // consume 'type'
                try self.parseType(module);
            } else {
                try self.skipSExpr();
            }
            try self.expect(.r_paren);
        }
    }

    fn parseFunc(self: *Parser, module: *Mod.Module) ParseError!void {
        var func = Mod.Func{};
        const func_idx: u32 = @intCast(module.funcs.items.len);
        // Clear per-function local name map
        self.local_names.clearRetainingCapacity();
        self.label_stack.clearRetainingCapacity();
        if (self.peek().kind == .identifier) {
            func.name = self.advance().text;
            // Register name → index for call resolution
            if (func.name) |n| {
                self.func_names.put(self.allocator, n, func_idx) catch {};
            }
        }

        // Handle inline (export "name") declarations
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_export) {
                _ = self.advance(); // consume 'export'
                const name_tok = self.advance();
                const exp_name = stripQuotes(name_tok.text);
                if (self.peek().kind == .r_paren) _ = self.advance(); // consume ')'
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .func,
                    .var_ = .{ .index = func_idx },
                }) catch return error.OutOfMemory;
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

        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            const inner = self.peek().kind;
            if (inner == .kw_param) {
                _ = self.advance(); // consume 'param'
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx: u32 = @intCast(params_list.items.len);
                    self.local_names.put(self.allocator, name, idx) catch {};
                }
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
                    params_list.append(self.allocator, vt) catch return error.OutOfMemory;
                }
                try self.expect(.r_paren);
            } else if (inner == .kw_result) {
                _ = self.advance(); // consume 'result'
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    const vt = self.parseValType() catch break;
                    results_list.append(self.allocator, vt) catch return error.OutOfMemory;
                }
                try self.expect(.r_paren);
            } else {
                // Not param/result — restore and stop parsing sig
                self.lexer.pos = save_pos;
                self.peeked = save_peeked;
                break;
            }
        }

        // If we found inline params/results and no (type $idx), create a type entry
        if (func.decl.type_var == .index and func.decl.type_var.index == types.invalid_index) {
            if (params_list.items.len > 0 or results_list.items.len > 0) {
                const p = self.allocator.alloc(types.ValType, params_list.items.len) catch return error.OutOfMemory;
                @memcpy(p, params_list.items);
                const r = self.allocator.alloc(types.ValType, results_list.items.len) catch return error.OutOfMemory;
                @memcpy(r, results_list.items);
                const type_idx = module.module_types.items.len;
                module.module_types.append(self.allocator, .{
                    .func_type = .{ .params = p, .results = r },
                }) catch return error.OutOfMemory;
                func.decl.type_var = .{ .index = @intCast(type_idx) };
            } else {
                // Empty func with no type — create void->void type
                const type_idx = module.module_types.items.len;
                module.module_types.append(self.allocator, .{
                    .func_type = .{},
                }) catch return error.OutOfMemory;
                func.decl.type_var = .{ .index = @intCast(type_idx) };
            }
        }

        // Parse (local ...) declarations
        while (self.peek().kind == .l_paren) {
            const save_pos = self.lexer.pos;
            const save_peeked = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_local) {
                _ = self.advance(); // consume 'local'
                if (self.peek().kind == .identifier) {
                    const name = self.advance().text;
                    const idx: u32 = @intCast(params_list.items.len + func.local_types.items.len);
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
                        _ = self.advance();
                    }
                }

                // Reorder: [instr][operands] → [operands][instr]
                // In a stack machine, operands must be pushed before the
                // instruction that consumes them.
                if (has_operands and instr_len > 0) {
                    var buf: [32]u8 = undefined;
                    if (instr_len <= 32) {
                        @memcpy(buf[0..instr_len], code.items[instr_start..instr_end]);
                        const total = code.items.len;
                        const operand_len = total - instr_end;
                        std.mem.copyForwards(u8, code.items[instr_start .. instr_start + operand_len], code.items[instr_end..total]);
                        @memcpy(code.items[instr_start + operand_len .. instr_start + operand_len + instr_len], buf[0..instr_len]);
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
            .kw_else => code.append(self.allocator, 0x05) catch return,
            .kw_end => {
                code.append(self.allocator, 0x0b) catch return;
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
                // Collect all integer targets
                var targets: std.ArrayListUnmanaged(u32) = .{};
                defer targets.deinit(self.allocator);
                while (self.peek().kind == .integer) {
                    const idx = self.parseU32() catch break;
                    targets.append(self.allocator, idx) catch return;
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
            .kw_call => {
                code.append(self.allocator, 0x10) catch return;
                self.emitU32Imm(code);
            },
            .kw_call_indirect => {
                code.append(self.allocator, 0x11) catch return;
                // call_indirect can have (type $idx) or inline type use, then optional table index
                if (self.peek().kind == .l_paren) {
                    const sp = self.lexer.pos;
                    const spk = self.peeked;
                    _ = self.advance(); // '('
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance(); // 'type'
                        self.emitU32Imm(code); // type index
                        if (self.peek().kind == .r_paren) _ = self.advance(); // ')'
                    } else {
                        self.lexer.pos = sp;
                        self.peeked = spk;
                        self.emitLeb128U32(code, 0); // type index 0
                    }
                } else if (self.peek().kind == .integer) {
                    self.emitU32Imm(code);
                } else {
                    self.emitLeb128U32(code, 0);
                }
                // Table index (default 0)
                if (self.peek().kind == .integer) {
                    self.emitU32Imm(code);
                } else {
                    self.emitLeb128U32(code, 0);
                }
            },
            .kw_drop => code.append(self.allocator, 0x1a) catch return,
            .kw_select => code.append(self.allocator, 0x1b) catch return,
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
                self.emitU32Imm(code);
            },
            .kw_global_set => {
                code.append(self.allocator, 0x24) catch return;
                self.emitU32Imm(code);
            },
            .kw_memory_size => {
                code.append(self.allocator, 0x3f) catch return;
                code.append(self.allocator, 0x00) catch return;
            },
            .kw_memory_grow => {
                code.append(self.allocator, 0x40) catch return;
                code.append(self.allocator, 0x00) catch return;
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
                // Parse the heap type for ref.null
                const next = self.peek().kind;
                if (next == .kw_funcref) {
                    _ = self.advance();
                    code.append(self.allocator, 0x70) catch return;
                } else if (next == .kw_externref) {
                    _ = self.advance();
                    code.append(self.allocator, 0x6f) catch return;
                } else if (next == .kw_func) {
                    _ = self.advance();
                    code.append(self.allocator, 0x70) catch return;
                } else {
                    // Check for bare "extern" or other heap type identifiers
                    const save_pos = self.lexer.pos;
                    const save_peeked = self.peeked;
                    if (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                        const ht = self.advance();
                        if (std.mem.eql(u8, ht.text, "extern")) {
                            code.append(self.allocator, 0x6f) catch return;
                        } else if (std.mem.eql(u8, ht.text, "func")) {
                            code.append(self.allocator, 0x70) catch return;
                        } else {
                            // Restore and try parseValType
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
            .opcode => self.emitGenericOpcode(tok.text, code),
            else => {
                // Unknown token in function body — ignore for bytecode purposes
            },
        }
    }

    fn emitBlockType(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        var buf: [6]u8 = undefined;
        const len = self.readBlockType(&buf);
        code.appendSlice(self.allocator, buf[0..len]) catch {};
    }

    fn readBlockType(self: *Parser, buf: *[6]u8) usize {
        // Check for (result <valtype>+) or (param ...) (result ...)
        if (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_result) {
                _ = self.advance(); // consume 'result'
                // Collect result types
                var count: u32 = 0;
                var result_types_buf: [16]types.ValType = undefined;
                while (self.peek().kind != .r_paren and self.peek().kind != .eof) {
                    if (self.parseValType()) |vt| {
                        if (count < 16) result_types_buf[count] = vt;
                        count += 1;
                    } else |_| {
                        _ = self.advance(); // skip unrecognized token
                        count += 1;
                    }
                }
                if (self.peek().kind == .r_paren) _ = self.advance();

                if (count == 1) {
                    const raw: u32 = @bitCast(@intFromEnum(result_types_buf[0]));
                    buf[0] = @truncate(raw);
                    return 1;
                }
                if (count > 1 and count <= 16) {
                    if (self.module) |mod| {
                        const r = self.allocator.alloc(types.ValType, count) catch {
                            buf[0] = 0x40;
                            return 1;
                        };
                        @memcpy(r, result_types_buf[0..count]);
                        const type_idx: u32 = @intCast(mod.module_types.items.len);
                        mod.module_types.append(self.allocator, .{
                            .func_type = .{ .params = &.{}, .results = r },
                        }) catch {
                            buf[0] = 0x40;
                            return 1;
                        };
                        return leb128.writeS32Leb128(buf, @bitCast(type_idx));
                    }
                }
                buf[0] = 0x40;
                return 1;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
            }
        }
        // Check for bare type use: (type N)
        if (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance(); // consume '('
            if (self.peek().kind == .kw_type) {
                _ = self.advance();
                if (self.parseU32()) |idx| {
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
            self.emitLeb128S32(code, 0);
            return;
        }
        const val = std.fmt.parseInt(i32, tok.text, 0) catch blk: {
            // Try parsing as unsigned and reinterpret
            const uval = std.fmt.parseInt(u32, tok.text, 0) catch {
                break :blk 0;
            };
            break :blk @as(i32, @bitCast(uval));
        };
        self.emitLeb128S32(code, val);
    }

    fn emitS64Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind != .integer) {
            self.emitLeb128S64(code, 0);
            return;
        }
        const val = std.fmt.parseInt(i64, tok.text, 0) catch blk: {
            const uval = std.fmt.parseInt(u64, tok.text, 0) catch {
                break :blk 0;
            };
            break :blk @as(i64, @bitCast(uval));
        };
        self.emitLeb128S64(code, val);
    }

    fn emitF32Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind == .integer or tok.kind == .float) {
            // Handle special nan/inf patterns and hex floats
            const bits = parseF32Bits(tok.text);
            const le = std.mem.toBytes(bits);
            code.appendSlice(self.allocator, &le) catch {};
        } else {
            code.appendSlice(self.allocator, &[4]u8{ 0, 0, 0, 0 }) catch {};
        }
    }

    fn emitF64Imm(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        const tok = self.advance();
        if (tok.kind == .integer or tok.kind == .float) {
            const bits = parseF64Bits(tok.text);
            const le = std.mem.toBytes(bits);
            code.appendSlice(self.allocator, &le) catch {};
        } else {
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
                // Memory load/store instructions have memarg (align, offset)
                if (op >= 0x28 and op <= 0x3e) {
                    self.emitMemarg(code, @truncate(op));
                }
            } else {
                // Prefixed opcode
                const prefix: u8 = @truncate(op >> 8);
                const sub: u32 = op & 0xff;
                code.append(self.allocator, prefix) catch return;
                var buf: [5]u8 = undefined;
                const n = leb128.writeU32Leb128(&buf, sub);
                code.appendSlice(self.allocator, buf[0..n]) catch return;
                // Atomic/bulk memory instructions may have memarg or other immediates
                if (prefix == 0xfe and sub >= 0x10) {
                    // Atomic load/store/rmw/cmpxchg have memarg (no alignment check for now)
                    self.emitMemarg(code, 0);
                } else if (prefix == 0xfc) {
                    self.emitBulkMemImm(sub, code);
                }
            }
        }
        // If opcode not recognized, just skip (don't emit anything)
    }

    fn emitMemarg(self: *Parser, code: *std.ArrayListUnmanaged(u8)) void {
        // Parse optional offset=N and align=N
        var alignment: u32 = 0;
        var offset: u32 = 0;
        for (0..2) |_| {
            if (self.peek().kind == .nat_eq) {
                const tok = self.advance();
                // Format: "offset=N" or "align=N"
                if (std.mem.startsWith(u8, tok.text, "offset=")) {
                    offset = std.fmt.parseInt(u32, tok.text[7..], 0) catch 0;
                } else if (std.mem.startsWith(u8, tok.text, "align=")) {
                    alignment = std.fmt.parseInt(u32, tok.text[6..], 0) catch 0;
                }
            }
        }
        self.emitLeb128U32(code, alignment);
        self.emitLeb128U32(code, offset);
    }

    fn emitBulkMemImm(self: *Parser, sub: u32, code: *std.ArrayListUnmanaged(u8)) void {
        switch (sub) {
            0x08 => {
                // memory.init: data_idx, memory_idx
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x09 => self.emitU32Imm(code), // data.drop
            0x0a => {
                // memory.copy: dst_mem, src_mem
                self.emitU32Imm(code);
                self.emitU32Imm(code);
            },
            0x0b => self.emitU32Imm(code), // memory.fill
            0x0c => {
                // table.init: elem_idx, table_idx
                self.emitU32Imm(code);
                self.emitU32Imm(code);
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
                // Non-constant instruction in folded form — still emit it for validation
                self.parsePlainInstr(code);
                // Parse sub-expressions
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
        if (self.peek().kind == .identifier) _ = self.advance();

        // Handle inline (export "name") on tables
        while (self.peek().kind == .l_paren) {
            const sp = self.lexer.pos;
            const spk = self.peeked;
            _ = self.advance();
            if (self.peek().kind == .kw_export) {
                _ = self.advance();
                const name_tok = self.advance();
                const exp_name = stripQuotes(name_tok.text);
                if (self.peek().kind == .r_paren) _ = self.advance();
                module.exports.append(self.allocator, .{
                    .name = exp_name,
                    .kind = .table,
                    .var_ = .{ .index = @intCast(module.tables.items.len) },
                }) catch return error.OutOfMemory;
            } else {
                self.lexer.pos = sp;
                self.peeked = spk;
                break;
            }
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
                        if (self.peek().kind == .identifier) {
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
            });
            // Create active element segment for the inline elements
            if (elem_indices.items.len > 0) {
                // Build offset expr: i32.const 0
                const ob = self.allocator.alloc(u8, 2) catch {
                    elem_indices.deinit(self.allocator);
                    return error.OutOfMemory;
                };
                ob[0] = 0x41; // i32.const
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
        try module.tables.append(self.allocator, .{
            .@"type" = .{ .elem_type = elem_type, .limits = limits },
        });
    }

    fn parseMemory(self: *Parser, module: *Mod.Module) ParseError!void {
        if (self.peek().kind == .identifier) _ = self.advance();
        const initial = try self.parseU32();
        var limits = types.Limits{ .initial = initial };
        if (self.peek().kind == .integer) {
            limits.max = try self.parseU32();
            limits.has_max = true;
        }
        try module.memories.append(self.allocator, .{
            .type = .{ .limits = limits },
        });
    }

    fn parseGlobal(self: *Parser, module: *Mod.Module) ParseError!void {
        const global_idx: u32 = @intCast(module.globals.items.len);
        if (self.peek().kind == .identifier) {
            const name = self.advance().text;
            self.global_names.put(self.allocator, name, global_idx) catch {};
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

    fn parseImport(self: *Parser, module: *Mod.Module) ParseError!void {
        const module_name = self.advance().text; // string literal
        const field_name = self.advance().text;
        // Strip quotes
        const mod_str = stripQuotes(module_name);
        const field_str = stripQuotes(field_name);

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
                if (self.peek().kind == .identifier) _ = self.advance();
                var type_index: types.Index = 0;
                if (self.peek().kind == .l_paren) {
                    _ = self.advance();
                    if (self.peek().kind == .kw_type) {
                        _ = self.advance();
                        type_index = try self.parseU32();
                        try self.expect(.r_paren);
                    } else {
                        try self.skipSExpr();
                        try self.expect(.r_paren);
                    }
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
                if (self.peek().kind == .identifier) _ = self.advance();
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
                });
                module.num_memory_imports += 1;
            },
            .kw_table => {
                import.kind = .table;
                if (self.peek().kind == .identifier) _ = self.advance();
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
                });
                module.num_table_imports += 1;
            },
            .kw_global => {
                import.kind = .global;
                if (self.peek().kind == .identifier) _ = self.advance();
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
        const exp_name = stripQuotes(name_tok.text);
        try self.expect(.l_paren);
        const kind_tok = self.advance();
        const kind: types.ExternalKind = switch (kind_tok.kind) {
            .kw_func => .func,
            .kw_memory => .memory,
            .kw_table => .table,
            .kw_global => .global,
            else => return error.UnexpectedToken,
        };
        const index = try self.parseU32();
        try self.expect(.r_paren);
        try module.exports.append(self.allocator, .{
            .name = exp_name,
            .kind = kind,
            .var_ = .{ .index = index },
        });
    }

    fn parseStart(self: *Parser, module: *Mod.Module) ParseError!void {
        const index = try self.parseU32();
        module.start_var = .{ .index = index };
    }

    fn parseElem(self: *Parser, module: *Mod.Module) ParseError!void {
        var seg = Mod.ElemSegment{};
        if (self.peek().kind == .identifier) _ = self.advance();

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
                    // (table $t) — skip
                    try self.skipSExpr();
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
                    self.parseInitExpr(&elem_expr_code);
                    elem_expr_code.append(self.allocator, 0x0b) catch {}; // terminate expression
                    elem_expr_count += 1;
                    try self.expect(.r_paren);
                } else {
                    // Post-offset without explicit type: skip
                    try self.skipSExpr();
                    try self.expect(.r_paren);
                }
            } else if (self.peek().kind == .integer) {
                const idx = try self.parseU32();
                try seg.elem_var_indices.append(self.allocator, .{ .index = idx });
            } else if (self.peek().kind == .identifier) {
                // Named reference like $f — skip for now
                _ = self.advance();
            } else if (self.peek().kind == .kw_funcref) {
                _ = self.advance();
                has_elem_type = true;
            } else if (self.peek().kind == .kw_externref) {
                _ = self.advance();
                has_elem_type = true;
                elem_type_is_externref = true;
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
                // (memory $m) — skip
                try self.skipSExpr();
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
        }

        // Read data string(s)
        var data_parts: std.ArrayListUnmanaged(u8) = .{};
        defer data_parts.deinit(self.allocator);
        while (self.peek().kind == .string) {
            const tok = self.advance();
            const stripped = stripQuotes(tok.text);
            data_parts.appendSlice(self.allocator, stripped) catch {};
        }
        if (data_parts.items.len > 0) {
            seg.data = data_parts.toOwnedSlice(self.allocator) catch &.{};
        }

        try module.data_segments.append(self.allocator, seg);
    }

    fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            return text[1 .. text.len - 1];
        }
        return text;
    }
};

/// Check if a token kind is a constant instruction (valid in init expressions).
fn isConstInstrToken(kind: TokenKind) bool {
    return switch (kind) {
        .kw_i32_const, .kw_i64_const, .kw_f32_const, .kw_f64_const,
        .kw_ref_null, .kw_ref_func, .kw_global_get => true,
        else => false,
    };
}

/// Map WAT instruction text (e.g. "i32.add") to binary opcode value.
/// Returns null for unrecognized instructions.
fn parseF32Bits(text: []const u8) u32 {
    // Handle nan:0xNNNNNN patterns
    if (std.mem.startsWith(u8, text, "nan:0x") or std.mem.startsWith(u8, text, "+nan:0x")) {
        const hex_start = if (text[0] == '+') @as(usize, 6) else @as(usize, 6);
        const payload = std.fmt.parseInt(u32, text[hex_start..], 16) catch 0;
        return 0x7fc00000 | (payload & 0x7fffff);
    }
    if (std.mem.startsWith(u8, text, "-nan:0x")) {
        const payload = std.fmt.parseInt(u32, text[7..], 16) catch 0;
        return 0xffc00000 | (payload & 0x7fffff);
    }
    if (std.mem.eql(u8, text, "nan") or std.mem.eql(u8, text, "+nan")) return 0x7fc00000;
    if (std.mem.eql(u8, text, "-nan")) return 0xffc00000;
    if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "+inf")) return 0x7f800000;
    if (std.mem.eql(u8, text, "-inf")) return 0xff800000;
    // Try parsing as a float
    const val = std.fmt.parseFloat(f32, text) catch 0.0;
    return @bitCast(val);
}

fn parseF64Bits(text: []const u8) u64 {
    if (std.mem.startsWith(u8, text, "nan:0x") or std.mem.startsWith(u8, text, "+nan:0x")) {
        const hex_start = if (text[0] == '+') @as(usize, 6) else @as(usize, 6);
        const payload = std.fmt.parseInt(u64, text[hex_start..], 16) catch 0;
        return 0x7ff8000000000000 | (payload & 0xfffffffffffff);
    }
    if (std.mem.startsWith(u8, text, "-nan:0x")) {
        const payload = std.fmt.parseInt(u64, text[7..], 16) catch 0;
        return 0xfff8000000000000 | (payload & 0xfffffffffffff);
    }
    if (std.mem.eql(u8, text, "nan") or std.mem.eql(u8, text, "+nan")) return 0x7ff8000000000000;
    if (std.mem.eql(u8, text, "-nan")) return 0xfff8000000000000;
    if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "+inf")) return 0x7ff0000000000000;
    if (std.mem.eql(u8, text, "-inf")) return 0xfff0000000000000;
    const val = std.fmt.parseFloat(f64, text) catch 0.0;
    return @bitCast(val);
}

fn opcodeFromText(text: []const u8) ?u32 {
    const map = std.StaticStringMap(u32).initComptime(.{
        // Reference
        .{ "ref.is_null", 0xd1 },
        .{ "ref.as_non_null", 0xd4 },
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
