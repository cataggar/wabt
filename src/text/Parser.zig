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
    var module = Mod.Module.init(allocator);
    errdefer module.deinit();

    try p.expect(.l_paren);
    try p.expect(.kw_module);

    // Optional module name
    if (p.peek().kind == .identifier) {
        module.name = p.advance().text;
    }

    // Parse module fields
    while (p.peek().kind == .l_paren) {
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
            else => try p.skipSExpr(),
        }
        try p.expect(.r_paren);
    }

    try p.expect(.r_paren);
    return module;
}

// ── Internal parser ─────────────────────────────────────────────────────

const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    peeked: ?Lex.Token = null,

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
                .l_paren => depth += 1,
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

    fn parseU32(self: *Parser) ParseError!u32 {
        const tok = self.advance();
        if (tok.kind != .integer) return error.InvalidNumber;
        return std.fmt.parseInt(u32, tok.text, 0) catch return error.InvalidNumber;
    }

    fn parseValType(self: *Parser) ParseError!types.ValType {
        const tok = self.advance();
        return switch (tok.kind) {
            .kw_i32 => .i32,
            .kw_i64 => .i64,
            .kw_f32 => .f32,
            .kw_f64 => .f64,
            .kw_v128 => .v128,
            .kw_funcref => .funcref,
            .kw_externref => .externref,
            else => error.InvalidType,
        };
    }

    fn parseFuncSig(self: *Parser, module: *Mod.Module) ParseError!struct { params: []const types.ValType, results: []const types.ValType } {
        var params = std.ArrayList(types.ValType).init(self.allocator);
        errdefer params.deinit();
        var results = std.ArrayList(types.ValType).init(self.allocator);
        errdefer results.deinit();

        while (self.peek().kind == .l_paren) {
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
                self.peeked = Lex.Token{ .kind = .l_paren, .text = "(", .offset = 0 };
                break;
            }
        }

        _ = module;
        return .{
            .params = try params.toOwnedSlice(),
            .results = try results.toOwnedSlice(),
        };
    }

    // -- module fields --

    fn parseType(self: *Parser, module: *Mod.Module) ParseError!void {
        // (type $name? (func (param ...) (result ...)))
        if (self.peek().kind == .identifier) _ = self.advance();
        try self.expect(.l_paren);
        try self.expect(.kw_func);
        const sig = try self.parseFuncSig(module);
        try self.expect(.r_paren);
        try module.types.append(self.allocator, .{
            .func_type = .{ .params = sig.params, .results = sig.results },
        });
    }

    fn parseFunc(self: *Parser, module: *Mod.Module) ParseError!void {
        var func = Mod.Func{};
        if (self.peek().kind == .identifier) func.name = self.advance().text;

        // Check for (type $idx)
        if (self.peek().kind == .l_paren) {
            const save = self.peeked;
            const lp = self.advance();
            if (self.peek().kind == .kw_type) {
                _ = self.advance();
                const idx = try self.parseU32();
                func.decl.type_var = .{ .index = idx };
                try self.expect(.r_paren);
            } else {
                self.peeked = lp;
                _ = save;
            }
        }

        // Skip remaining body (params, results, locals, instrs)
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

        try module.funcs.append(self.allocator, func);
    }

    fn parseTable(self: *Parser, module: *Mod.Module) ParseError!void {
        if (self.peek().kind == .identifier) _ = self.advance();
        const initial = try self.parseU32();
        var limits = types.Limits{ .initial = initial };
        if (self.peek().kind == .integer) {
            limits.max = try self.parseU32();
            limits.has_max = true;
        }
        const elem_type = try self.parseValType();
        try module.tables.append(self.allocator, .{
            .type = .{ .elem_type = elem_type, .limits = limits },
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
        if (self.peek().kind == .identifier) _ = self.advance();
        var mutability: types.Mutability = .immutable;
        var val_type: types.ValType = undefined;

        if (self.peek().kind == .l_paren) {
            _ = self.advance();
            if (self.peek().kind == .kw_mut) {
                _ = self.advance();
                mutability = .mutable;
                val_type = try self.parseValType();
                try self.expect(.r_paren);
            } else {
                // Might be init expr — skip
                self.peeked = Lex.Token{ .kind = .l_paren, .text = "(", .offset = 0 };
                val_type = try self.parseValType();
            }
        } else {
            val_type = try self.parseValType();
        }

        // Skip init expression
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

        try module.globals.append(self.allocator, .{
            .type = .{ .val_type = val_type, .mutability = mutability },
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
                    _ = self.advance();
                    try self.expect(.kw_mut);
                    mutability = .mutable;
                    val_type = try self.parseValType();
                    try self.expect(.r_paren);
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

        // Skip offset expression and elem indices for now
        seg.elem_var_indices = .empty;
        while (self.peek().kind != .r_paren) {
            if (self.peek().kind == .l_paren) {
                _ = self.advance();
                try self.skipSExpr();
                try self.expect(.r_paren);
            } else if (self.peek().kind == .integer) {
                const idx = try self.parseU32();
                try seg.elem_var_indices.append(self.allocator, .{ .index = idx });
            } else if (self.peek().kind == .eof) {
                return error.InvalidModule;
            } else {
                _ = self.advance();
            }
        }

        try module.elem_segments.append(self.allocator, seg);
    }

    fn parseData(self: *Parser, module: *Mod.Module) ParseError!void {
        var seg = Mod.DataSegment{};
        if (self.peek().kind == .identifier) _ = self.advance();

        // Skip offset expression
        while (self.peek().kind == .l_paren) {
            _ = self.advance();
            try self.skipSExpr();
            try self.expect(.r_paren);
        }

        // Read data string
        if (self.peek().kind == .string) {
            const tok = self.advance();
            seg.data = stripQuotes(tok.text);
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
    try std.testing.expectEqual(@as(usize, 1), module.types.items.len);
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
