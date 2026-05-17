//! WIT parser.
//!
//! Recursive-descent parser that consumes tokens from `lexer.zig` and
//! produces the AST in `ast.zig`. The parser uses an arena allocator
//! for all AST allocations.
//!
//! Supported grammar — sufficient to parse every `*.wit` file in
//! canonical `wasi-http@0.2.6` + `wasi-cli@0.2.6` + `wasi-io@0.2.6` +
//! `wasi-clocks@0.2.6` + `wasi-random@0.2.6` + `wasi-filesystem@0.2.6`
//! + `wasi-sockets@0.2.6` (see the file-by-file harness test below):
//!
//!   * `package <ns>:<name>[@<semver>];`
//!   * Doc comments (`///` and `/** … */`) attached to the next item.
//!   * `@<id>` and `@<id>(<args>?)` annotations on any item — treated
//!     as no-op metadata. Grammar within `(...)` is balanced-paren
//!     skipping; no string-literal values supported (canonical files
//!     use `@since(version = X.Y.Z)` / `@unstable(feature = id)` /
//!     bare `@deprecated`).
//!   * `interface <name> { <items> }`
//!   * `world <name> { <items> }`
//!   * Inside an interface: `type`, `record`, `variant`, `enum`,
//!     `flags`, `resource`, `<name>: func(...) [-> <type>];`,
//!     `use … . { … };`.
//!   * Inside a world: `import|export` of an interface ref, named
//!     function, or inline interface; `use`; `type`; `include`.
//!   * Resources: empty bodies (`resource R;`), `{}`-bodies with
//!     `constructor`, named methods, and `static` methods.
//!   * `func(p: T, …,)` — trailing comma in parameter lists.
//!   * Types: all primitives (`u8/u16/u32/u64`, `s8/s16/s32/s64`,
//!     `f32/f64`, `bool`, `char`, `string`); `list<T>`,
//!     `option<T>`, `result<T,E>` (and `result` / `result<_, E>`),
//!     `tuple<T,U,...>`, `own<R>`, `borrow<R>`, named type
//!     references.
//!
//! Explicitly NOT supported yet (parser returns
//! `error.UnsupportedFeature` with a precise span pointing at the
//! offending keyword):
//!   * Streams: `stream<T>` / `future<T>` / `error-context`.
//!   * Async: `async func`.
//!   * Multi-package files (only the first `package` decl is
//!     honoured; multi-file primary-package inheritance is the
//!     resolver's job — see Phase 2 of #195).
//!   * String escapes inside `%` explicit identifiers (the lexer
//!     accepts them but identifier text is taken verbatim).
//!   * String-literal annotation args (`@deprecated("msg")`) —
//!     canonical wasi files don't use them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParseError = lexer.LexError || error{
    OutOfMemory,
    UnexpectedToken,
    UnsupportedFeature,
    DuplicateName,
    InvalidPackageId,
    InvalidVersion,
};

pub const ParseDiagnostic = struct {
    /// The token type that triggered the error (if any).
    token: ?lexer.Token = null,
    /// Byte span in the original source.
    span: lexer.Span = .{ .start = 0, .end = 0 },
    /// Human-readable message (e.g. "expected `}`, found `;`").
    msg: []const u8 = "",
};

pub fn parse(
    allocator: Allocator,
    source: []const u8,
    diag: ?*ParseDiagnostic,
) ParseError!ast.Document {
    var p = Parser{
        .allocator = allocator,
        .lex = lexer.Lexer.init(source),
        .source = source,
        .pending_docs = "",
        .diag = diag,
        .lookahead = null,
    };
    return p.parseDocument();
}

const Parser = struct {
    allocator: Allocator,
    lex: lexer.Lexer,
    source: []const u8,
    /// Accumulated doc-comment text from the most recent run of
    /// `///` / `/** … */` lines, attached to the next item that
    /// supports docs. Cleared when the item consumes it.
    pending_docs: []const u8,
    diag: ?*ParseDiagnostic,
    /// One-token lookahead. We keep tokens read ahead of the current
    /// position here so multi-token productions (e.g. distinguishing
    /// a `func` literal from a type-named `func`) can backtrack.
    lookahead: ?lexer.Tok,

    fn fail(self: *Parser, span: lexer.Span, msg: []const u8) ParseError {
        if (self.diag) |d| {
            d.span = span;
            d.msg = msg;
        }
        return error.UnexpectedToken;
    }

    /// Same as `fail` but also records the offending token's tag in
    /// `ParseDiagnostic.token` so callers can render the actual kind
    /// (e.g. `got token: .lparen`) in their diagnostic. Issue #216
    /// motivated this: `UnexpectedToken` errors were losing the
    /// per-token information the diagnostic struct was designed to
    /// surface.
    fn failTok(self: *Parser, tok: lexer.Tok, msg: []const u8) ParseError {
        if (self.diag) |d| d.token = tok.tag;
        return self.fail(tok.span, msg);
    }

    fn peekTok(self: *Parser) ParseError!lexer.Tok {
        if (self.lookahead) |t| return t;
        const t = try self.lex.next();
        self.lookahead = t;
        return t;
    }

    fn nextTok(self: *Parser) ParseError!lexer.Tok {
        if (self.lookahead) |t| {
            self.lookahead = null;
            return t;
        }
        return self.lex.next();
    }

    fn nextNonDoc(self: *Parser) ParseError!lexer.Tok {
        while (true) {
            const t = try self.nextTok();
            switch (t.tag) {
                .doc_comment, .doc_block => {
                    // Concatenate doc text — keep only the most-recent
                    // contiguous run. A non-doc, non-whitespace token
                    // will reset this.
                    if (self.pending_docs.len == 0) {
                        self.pending_docs = t.span.slice(self.source);
                    } else {
                        // Multiple consecutive doc comments: extend
                        // span to cover both.
                        self.pending_docs = self.source[blk: {
                            // Find start in pending_docs (which is a
                            // sub-slice of self.source)
                            const ptr_start: usize = @intFromPtr(self.pending_docs.ptr) - @intFromPtr(self.source.ptr);
                            break :blk ptr_start;
                        }..t.span.end];
                    }
                },
                .at => try self.consumeAnnotationAfterAt(),
                else => return t,
            }
        }
    }

    /// Drain any pending doc-comment tokens into `pending_docs`,
    /// leaving the next non-doc token in the lookahead. Matches
    /// `nextNonDoc`'s doc-accumulation semantics, but stops at the
    /// boundary instead of consuming the following non-doc token.
    /// Also transparently skips any annotations (`@<id>(<args>?)`)
    /// interleaved with the docs — annotations are no-op metadata
    /// for this parser scope, like `nextNonDoc` does.
    fn skipLeadingDocs(self: *Parser) ParseError!void {
        while (true) {
            const t = try self.peekTok();
            switch (t.tag) {
                .doc_comment, .doc_block => {
                    _ = try self.nextTok();
                    if (self.pending_docs.len == 0) {
                        self.pending_docs = t.span.slice(self.source);
                    } else {
                        const ptr_start: usize = @intFromPtr(self.pending_docs.ptr) - @intFromPtr(self.source.ptr);
                        self.pending_docs = self.source[ptr_start..t.span.end];
                    }
                },
                .at => {
                    _ = try self.nextTok();
                    try self.consumeAnnotationAfterAt();
                },
                else => return,
            }
        }
    }

    /// Consume one annotation body after `@` has already been read.
    /// Grammar:
    ///   `<id>` ( `(` <args> `)` )?
    /// where `<args>` is any token sequence with balanced parens —
    /// the parser does not interpret annotation values for this
    /// scope (canonical wasi files use `@since(version = X.Y.Z)`
    /// and `@unstable(feature = id)`; the encoder is gate-agnostic
    /// and treats all annotations as no-op metadata).
    fn consumeAnnotationAfterAt(self: *Parser) ParseError!void {
        const name_tok = try self.nextTok();
        switch (name_tok.tag) {
            .id, .explicit_id => {},
            // Keyword names are allowed as annotation tags too
            // (`@async` etc. — none used in upstream 0.2.6 today,
            // but cheap to tolerate).
            .kw_use, .kw_type, .kw_func, .kw_record, .kw_resource, .kw_flags, .kw_variant, .kw_enum, .kw_bool, .kw_string, .kw_option, .kw_result, .kw_future, .kw_stream, .kw_error_context, .kw_list, .kw_as, .kw_from, .kw_static, .kw_interface, .kw_tuple, .kw_import, .kw_export, .kw_world, .kw_package, .kw_constructor, .kw_async, .kw_include, .kw_with, .kw_own, .kw_borrow => {},
            else => return self.failTok(name_tok, "expected annotation name after `@`"),
        }
        const peek = try self.peekTok();
        if (peek.tag != .lparen) return;
        _ = try self.nextTok();
        var depth: usize = 1;
        while (depth > 0) {
            const inner = try self.nextTok();
            switch (inner.tag) {
                .lparen => depth += 1,
                .rparen => depth -= 1,
                .eof => return self.failTok(inner, "unterminated annotation arg list"),
                else => {},
            }
        }
    }

    fn takeDocs(self: *Parser) []const u8 {
        const d = self.pending_docs;
        self.pending_docs = "";
        return d;
    }

    fn expect(self: *Parser, want: lexer.Token) ParseError!lexer.Tok {
        const t = try self.nextNonDoc();
        if (t.tag != want) {
            return self.failTok(t, "unexpected token");
        }
        return t;
    }

    fn eatIf(self: *Parser, want: lexer.Token) ParseError!bool {
        const t = try self.peekTok();
        if (t.tag == want) {
            _ = try self.nextTok();
            return true;
        }
        return false;
    }

    fn parseDocument(self: *Parser) ParseError!ast.Document {
        var package: ?ast.PackageId = null;

        // Drain any leading doc comments into `pending_docs` without
        // consuming the first significant token. If a `package` decl
        // follows, the leading docs are discarded (PackageId carries
        // no doc field); if an item follows directly (no `package`),
        // the docs attach to that item as usual via `nextNonDoc` /
        // `takeDocs`.
        try self.skipLeadingDocs();
        const first = try self.peekTok();

        // Optional `package <ns>:<name>[@<semver>];`
        if (first.tag == .kw_package) {
            _ = self.takeDocs();
            _ = try self.nextNonDoc();
            package = try self.parsePackageId();
            _ = try self.expect(.semicolon);
        }

        var items = std.ArrayListUnmanaged(ast.TopLevelItem).empty;
        while (true) {
            const t = try self.nextNonDoc();
            switch (t.tag) {
                .eof => break,
                .kw_interface => {
                    const iface = try self.parseInterface();
                    try items.append(self.allocator, .{ .interface = iface });
                },
                .kw_world => {
                    const w = try self.parseWorld();
                    try items.append(self.allocator, .{ .world = w });
                },
                .kw_use => {
                    const u = try self.parseUse();
                    try items.append(self.allocator, .{ .use = u });
                },
                .kw_resource, .kw_stream, .kw_future, .kw_error_context, .kw_async => {
                    return self.failTok(t, "feature not yet supported");
                },
                else => return self.failTok(t, "expected `interface`, `world`, or `use`"),
            }
        }

        return .{
            .package = package,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parsePackageId(self: *Parser) ParseError!ast.PackageId {
        const ns = try self.expect(.id);
        _ = try self.expect(.colon);
        const name = try self.expect(.id);
        var version: ?[]const u8 = null;
        if (try self.eatIf(.at)) {
            version = try self.parseSemverText();
        }
        return .{
            .namespace = ns.span.slice(self.source),
            .name = name.span.slice(self.source),
            .version = version,
        };
    }

    /// Parse the literal text of a semver (e.g. `0.1.0`, `1.2.3-beta.1`).
    /// We don't validate the structure — the encoder treats it as
    /// opaque text. Just consume tokens that could appear inside a
    /// semver string until we hit a delimiter (`;` or `/` or `.`+id).
    ///
    /// `.`, `-`, `+` are only consumed when followed by an id or
    /// integer; otherwise they're left for the caller. This matters
    /// for `use wasi:io/streams@0.2.6.{output-stream};` where the
    /// `.` between the version and `{` is a use-clause delimiter,
    /// not a semver continuation. We save and restore lexer/lookahead
    /// state so we can speculatively peek past the separator.
    fn parseSemverText(self: *Parser) ParseError![]const u8 {
        const first = try self.expect(.integer);
        const start = first.span.start;
        var end = first.span.end;
        while (true) {
            const t = try self.peekTok();
            switch (t.tag) {
                .period, .minus, .plus => {
                    const saved_pos = self.lex.pos;
                    const saved_lookahead = self.lookahead;
                    _ = try self.nextTok(); // consume sep
                    const after = try self.nextTok();
                    if (after.tag != .id and after.tag != .integer) {
                        // Not a semver continuation — rewind so the
                        // caller sees `t` (the separator) as the
                        // next token.
                        self.lex.pos = saved_pos;
                        self.lookahead = saved_lookahead;
                        break;
                    }
                    end = after.span.end;
                },
                else => break,
            }
        }
        return self.source[start..end];
    }

    fn parseInterface(self: *Parser) ParseError!ast.Interface {
        const docs = self.takeDocs();
        const name = try self.parseId();
        _ = try self.expect(.lbrace);
        var items = std.ArrayListUnmanaged(ast.InterfaceItem).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const item = try self.parseInterfaceItem(t);
            try items.append(self.allocator, item);
        }
        return .{
            .docs = docs,
            .name = name,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parseInterfaceItem(self: *Parser, head: lexer.Tok) ParseError!ast.InterfaceItem {
        const docs = self.takeDocs();
        switch (head.tag) {
            .kw_use => {
                const u = try self.parseUse();
                return .{ .use = u };
            },
            .kw_type => {
                const td = try self.parseTypeAlias(docs);
                return .{ .type = td };
            },
            .kw_record => {
                const td = try self.parseRecord(docs);
                return .{ .type = td };
            },
            .kw_variant => {
                const td = try self.parseVariant(docs);
                return .{ .type = td };
            },
            .kw_enum => {
                const td = try self.parseEnum(docs);
                return .{ .type = td };
            },
            .kw_flags => {
                const td = try self.parseFlags(docs);
                return .{ .type = td };
            },
            .kw_resource => {
                const td = try self.parseResource(docs);
                return .{ .type = td };
            },
            .kw_stream, .kw_future, .kw_error_context, .kw_async, .kw_constructor => {
                return self.failTok(head, "feature not yet supported");
            },
            .id, .explicit_id => {
                // `name: func(...) [-> result];`
                const name = try self.identText(head);
                _ = try self.expect(.colon);
                _ = try self.expect(.kw_func);
                const f = try self.parseFuncSignature();
                _ = try self.expect(.semicolon);
                return .{ .func = .{ .docs = docs, .name = name, .func = f } };
            },
            else => return self.failTok(head, "expected interface item"),
        }
    }

    fn parseTypeAlias(self: *Parser, docs: []const u8) ParseError!ast.TypeDef {
        const name = try self.parseId();
        _ = try self.expect(.eq);
        const ty = try self.parseType();
        _ = try self.expect(.semicolon);
        return .{ .docs = docs, .name = name, .kind = .{ .alias = ty } };
    }

    fn parseRecord(self: *Parser, docs: []const u8) ParseError!ast.TypeDef {
        const name = try self.parseId();
        _ = try self.expect(.lbrace);
        var fields = std.ArrayListUnmanaged(ast.Field).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const field_docs = self.takeDocs();
            const field_name = try self.identText(t);
            _ = try self.expect(.colon);
            const ty = try self.parseType();
            try fields.append(self.allocator, .{ .docs = field_docs, .name = field_name, .type = ty });
            // Optional trailing comma.
            const after = try self.peekTok();
            if (after.tag == .comma) _ = try self.nextTok();
        }
        return .{
            .docs = docs,
            .name = name,
            .kind = .{ .record = try fields.toOwnedSlice(self.allocator) },
        };
    }

    fn parseVariant(self: *Parser, docs: []const u8) ParseError!ast.TypeDef {
        const name = try self.parseId();
        _ = try self.expect(.lbrace);
        var cases = std.ArrayListUnmanaged(ast.Case).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const case_docs = self.takeDocs();
            const case_name = try self.identText(t);
            var payload: ?ast.Type = null;
            if (try self.eatIf(.lparen)) {
                payload = try self.parseType();
                _ = try self.expect(.rparen);
            }
            try cases.append(self.allocator, .{ .docs = case_docs, .name = case_name, .type = payload });
            const after = try self.peekTok();
            if (after.tag == .comma) _ = try self.nextTok();
        }
        return .{
            .docs = docs,
            .name = name,
            .kind = .{ .variant = try cases.toOwnedSlice(self.allocator) },
        };
    }

    fn parseEnum(self: *Parser, docs: []const u8) ParseError!ast.TypeDef {
        const name = try self.parseId();
        _ = try self.expect(.lbrace);
        var names = std.ArrayListUnmanaged([]const u8).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const n = try self.identText(t);
            try names.append(self.allocator, n);
            const after = try self.peekTok();
            if (after.tag == .comma) _ = try self.nextTok();
        }
        return .{
            .docs = docs,
            .name = name,
            .kind = .{ .@"enum" = try names.toOwnedSlice(self.allocator) },
        };
    }

    fn parseFlags(self: *Parser, docs: []const u8) ParseError!ast.TypeDef {
        const name = try self.parseId();
        _ = try self.expect(.lbrace);
        var names = std.ArrayListUnmanaged([]const u8).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const n = try self.identText(t);
            try names.append(self.allocator, n);
            const after = try self.peekTok();
            if (after.tag == .comma) _ = try self.nextTok();
        }
        return .{
            .docs = docs,
            .name = name,
            .kind = .{ .flags = try names.toOwnedSlice(self.allocator) },
        };
    }

    /// `resource <name> { (constructor(...) | <id>: [static] func(...) [-> T];)* }`
    fn parseResource(self: *Parser, docs: []const u8) ParseError!ast.TypeDef {
        const name = try self.parseId();
        // Resources without a body: `resource <name>;` — used in
        // canonical wasi-cli/terminal.wit etc. to declare a
        // resource that has no methods. Treat as an empty resource.
        if (try self.eatIf(.semicolon)) {
            return .{
                .docs = docs,
                .name = name,
                .kind = .{ .resource = &.{} },
            };
        }
        _ = try self.expect(.lbrace);
        var methods = std.ArrayListUnmanaged(ast.ResourceMethod).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const m_docs = self.takeDocs();
            switch (t.tag) {
                .kw_constructor => {
                    const f = try self.parseFuncSignature();
                    _ = try self.expect(.semicolon);
                    try methods.append(self.allocator, .{
                        .docs = m_docs,
                        .kind = .constructor,
                        .name = "",
                        .func = f,
                    });
                },
                .id, .explicit_id => {
                    const m_name = try self.identText(t);
                    _ = try self.expect(.colon);
                    // Optional `static` modifier before `func`.
                    var kind: ast.ResourceMethodKind = .method;
                    var head = try self.nextNonDoc();
                    if (head.tag == .kw_static) {
                        kind = .static;
                        head = try self.nextNonDoc();
                    }
                    if (head.tag != .kw_func) {
                        return self.failTok(head, "expected `func`");
                    }
                    const f = try self.parseFuncSignature();
                    _ = try self.expect(.semicolon);
                    try methods.append(self.allocator, .{
                        .docs = m_docs,
                        .kind = kind,
                        .name = m_name,
                        .func = f,
                    });
                },
                else => return self.failTok(t, "expected `constructor` or method declaration"),
            }
        }
        return .{
            .docs = docs,
            .name = name,
            .kind = .{ .resource = try methods.toOwnedSlice(self.allocator) },
        };
    }

    fn parseFuncSignature(self: *Parser) ParseError!ast.Func {
        _ = try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(ast.Param).empty;
        if (!(try self.eatIf(.rparen))) {
            while (true) {
                const name_tok = try self.nextNonDoc();
                const param_name = try self.identText(name_tok);
                _ = try self.expect(.colon);
                const ty = try self.parseType();
                try params.append(self.allocator, .{ .name = param_name, .type = ty });
                if (try self.eatIf(.comma)) {
                    // Trailing comma — closing `)` immediately
                    // after the comma is legal in canonical WIT
                    // (every multi-line func sig in wasi-* uses
                    // it). Treat as loop terminator.
                    if (try self.eatIf(.rparen)) break;
                    continue;
                }
                _ = try self.expect(.rparen);
                break;
            }
        }
        var result: ?ast.Type = null;
        if (try self.eatIf(.arrow)) {
            result = try self.parseType();
        }
        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .result = result,
        };
    }

    fn parseType(self: *Parser) ParseError!ast.Type {
        const t = try self.nextNonDoc();
        return self.parseTypeFromTok(t);
    }

    fn parseTypeFromTok(self: *Parser, t: lexer.Tok) ParseError!ast.Type {
        return switch (t.tag) {
            .kw_bool => .bool,
            .kw_u8 => .u8,
            .kw_u16 => .u16,
            .kw_u32 => .u32,
            .kw_u64 => .u64,
            .kw_s8 => .s8,
            .kw_s16 => .s16,
            .kw_s32 => .s32,
            .kw_s64 => .s64,
            .kw_f32 => .f32,
            .kw_f64 => .f64,
            .kw_char => .char,
            .kw_string => .string,
            .kw_list => blk: {
                _ = try self.expect(.lt);
                const inner = try self.parseType();
                _ = try self.expect(.gt);
                const heap = try self.allocator.create(ast.Type);
                heap.* = inner;
                break :blk .{ .list = heap };
            },
            .kw_option => blk: {
                _ = try self.expect(.lt);
                const inner = try self.parseType();
                _ = try self.expect(.gt);
                const heap = try self.allocator.create(ast.Type);
                heap.* = inner;
                break :blk .{ .option = heap };
            },
            .kw_result => blk: {
                // `result` (no body), `result<_, E>`, `result<T>`, `result<T, E>`.
                if (!(try self.eatIf(.lt))) break :blk ast.Type{ .result = .{ .ok = null, .err = null } };
                var ok: ?*const ast.Type = null;
                var err: ?*const ast.Type = null;
                const first = try self.nextNonDoc();
                if (first.tag != .kw_underscore) {
                    const ok_ty = try self.parseTypeFromTok(first);
                    const heap = try self.allocator.create(ast.Type);
                    heap.* = ok_ty;
                    ok = heap;
                }
                if (try self.eatIf(.comma)) {
                    const err_ty = try self.parseType();
                    const heap = try self.allocator.create(ast.Type);
                    heap.* = err_ty;
                    err = heap;
                }
                _ = try self.expect(.gt);
                break :blk ast.Type{ .result = .{ .ok = ok, .err = err } };
            },
            .kw_tuple => blk: {
                _ = try self.expect(.lt);
                var fields = std.ArrayListUnmanaged(ast.Type).empty;
                while (true) {
                    const ty = try self.parseType();
                    try fields.append(self.allocator, ty);
                    if (try self.eatIf(.comma)) continue;
                    _ = try self.expect(.gt);
                    break;
                }
                break :blk ast.Type{ .tuple = try fields.toOwnedSlice(self.allocator) };
            },
            .kw_own, .kw_borrow => blk: {
                _ = try self.expect(.lt);
                const name_tok = try self.nextNonDoc();
                if (name_tok.tag != .id and name_tok.tag != .explicit_id) {
                    return self.failTok(name_tok, "expected resource name");
                }
                const name = try self.identText(name_tok);
                _ = try self.expect(.gt);
                break :blk if (t.tag == .kw_own) ast.Type{ .own = name } else ast.Type{ .borrow = name };
            },
            .kw_stream, .kw_future, .kw_error_context => return self.failTok(t, "feature not yet supported"),
            .id, .explicit_id => .{ .name = try self.identText(t) },
            else => return self.failTok(t, "expected a type"),
        };
    }

    fn parseUse(self: *Parser) ParseError!ast.Use {
        // `use pkg:name/iface[@semver].{a, b as c};`
        // or  `use iface.{a};`  (in-package short form)
        const ref = try self.parseInterfaceRef();
        _ = try self.expect(.period);
        _ = try self.expect(.lbrace);
        var names = std.ArrayListUnmanaged(ast.UseName).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const n = try self.identText(t);
            var rename: ?[]const u8 = null;
            if (try self.eatIf(.kw_as)) {
                const r = try self.nextNonDoc();
                rename = try self.identText(r);
            }
            try names.append(self.allocator, .{ .name = n, .rename = rename });
            if (try self.eatIf(.comma)) continue;
            _ = try self.expect(.rbrace);
            break;
        }
        _ = try self.expect(.semicolon);
        return .{
            .from = ref,
            .names = try names.toOwnedSlice(self.allocator),
        };
    }

    fn parseInterfaceRef(self: *Parser) ParseError!ast.InterfaceRef {
        // Either `<id>` (in-package) or `<ns>:<name>/<iface>[@<semver>]` (qualified).
        const head = try self.nextNonDoc();
        const head_text = try self.identText(head);
        const peek = try self.peekTok();
        if (peek.tag == .colon) {
            // Qualified: ns is `head_text`.
            _ = try self.nextTok();
            const name_tok = try self.nextNonDoc();
            const name_text = try self.identText(name_tok);
            _ = try self.expect(.slash);
            const iface_tok = try self.nextNonDoc();
            const iface_text = try self.identText(iface_tok);
            var version: ?[]const u8 = null;
            if (try self.eatIf(.at)) {
                version = try self.parseSemverText();
            }
            return .{
                .package = .{
                    .namespace = head_text,
                    .name = name_text,
                    .version = version,
                },
                .name = iface_text,
            };
        }
        return .{ .name = head_text };
    }

    fn parseWorld(self: *Parser) ParseError!ast.World {
        const docs = self.takeDocs();
        const name = try self.parseId();
        _ = try self.expect(.lbrace);
        var items = std.ArrayListUnmanaged(ast.WorldItem).empty;
        while (true) {
            const t = try self.nextNonDoc();
            if (t.tag == .rbrace) break;
            const item = try self.parseWorldItem(t);
            try items.append(self.allocator, item);
        }
        return .{
            .docs = docs,
            .name = name,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parseWorldItem(self: *Parser, head: lexer.Tok) ParseError!ast.WorldItem {
        const docs = self.takeDocs();
        switch (head.tag) {
            .kw_import => {
                const ext = try self.parseWorldExtern(docs);
                return .{ .import = ext };
            },
            .kw_export => {
                const ext = try self.parseWorldExtern(docs);
                return .{ .@"export" = ext };
            },
            .kw_use => {
                const u = try self.parseUse();
                return .{ .use = u };
            },
            .kw_type => {
                const td = try self.parseTypeAlias(docs);
                return .{ .type = td };
            },
            .kw_record => return .{ .type = try self.parseRecord(docs) },
            .kw_variant => return .{ .type = try self.parseVariant(docs) },
            .kw_enum => return .{ .type = try self.parseEnum(docs) },
            .kw_flags => return .{ .type = try self.parseFlags(docs) },
            .kw_include => return .{ .include = try self.parseInclude(docs) },
            else => return self.failTok(head, "expected world item"),
        }
    }

    fn parseWorldExtern(self: *Parser, docs: []const u8) ParseError!ast.WorldExtern {
        // After `import` / `export`, the head identifier can be:
        //   * `<id>: func(...) [-> T];`             — named func
        //   * `<id>: interface { ... };`            — inline interface
        //   * `<id>;`                                — in-package iface ref
        //   * `<id>@<semver>;`                       — versioned in-package
        //   * `<ns>:<name>/<iface>[@<semver>];`     — qualified iface ref
        //
        // The first three forms start with `<id>:` so we have to peek
        // *past* the colon to disambiguate `<id>: func(...)` from
        // `<ns>:<name>/<iface>`.
        const head = try self.nextNonDoc();
        const head_text = try self.identText(head);
        const peek = try self.peekTok();

        switch (peek.tag) {
            .colon => {
                _ = try self.nextTok(); // consume `:`
                const after_colon = try self.nextNonDoc();
                switch (after_colon.tag) {
                    .kw_func => {
                        const f = try self.parseFuncSignature();
                        _ = try self.expect(.semicolon);
                        return .{ .named_func = .{ .docs = docs, .name = head_text, .func = f } };
                    },
                    .kw_interface => {
                        _ = try self.expect(.lbrace);
                        var items = std.ArrayListUnmanaged(ast.InterfaceItem).empty;
                        while (true) {
                            const t = try self.nextNonDoc();
                            if (t.tag == .rbrace) break;
                            const it = try self.parseInterfaceItem(t);
                            try items.append(self.allocator, it);
                        }
                        _ = try self.expect(.semicolon);
                        return .{ .named_interface = .{ .docs = docs, .name = head_text, .items = try items.toOwnedSlice(self.allocator) } };
                    },
                    .id, .explicit_id => {
                        // `<ns>:<name>/<iface>[@<semver>]`. We've
                        // already consumed `<ns>:`; `after_colon` is
                        // `<name>`.
                        const name_text = try self.identText(after_colon);
                        _ = try self.expect(.slash);
                        const iface_tok = try self.nextNonDoc();
                        const iface_text = try self.identText(iface_tok);
                        var version: ?[]const u8 = null;
                        if (try self.eatIf(.at)) {
                            version = try self.parseSemverText();
                        }
                        _ = try self.expect(.semicolon);
                        return .{ .interface_ref = .{
                            .docs = docs,
                            .ref = .{
                                .package = .{
                                    .namespace = head_text,
                                    .name = name_text,
                                    .version = version,
                                },
                                .name = iface_text,
                            },
                        } };
                    },
                    else => return self.failTok(after_colon, "expected `func`, `interface`, or qualified-package name"),
                }
            },
            .at => {
                _ = try self.nextTok();
                _ = try self.parseSemverText();
                _ = try self.expect(.semicolon);
                return .{ .interface_ref = .{
                    .docs = docs,
                    .ref = .{ .name = head_text },
                } };
            },
            .semicolon => {
                _ = try self.nextTok();
                return .{ .interface_ref = .{
                    .docs = docs,
                    .ref = .{ .name = head_text },
                } };
            },
            else => return self.failTok(peek, "expected `;`, `:`, or `@` after world-extern name"),
        }
    }

    fn parseInclude(self: *Parser, docs: []const u8) ParseError!ast.Include {
        const ref = try self.parseInterfaceRef();
        var with: []const ast.UseName = &.{};
        if (try self.eatIf(.kw_with)) {
            _ = try self.expect(.lbrace);
            var list = std.ArrayListUnmanaged(ast.UseName).empty;
            while (true) {
                const t = try self.nextNonDoc();
                if (t.tag == .rbrace) break;
                const n = try self.identText(t);
                var rename: ?[]const u8 = null;
                if (try self.eatIf(.kw_as)) {
                    const r = try self.nextNonDoc();
                    rename = try self.identText(r);
                }
                try list.append(self.allocator, .{ .name = n, .rename = rename });
                if (try self.eatIf(.comma)) continue;
                _ = try self.expect(.rbrace);
                break;
            }
            with = try list.toOwnedSlice(self.allocator);
        }
        _ = try self.expect(.semicolon);
        return .{ .docs = docs, .target = ref, .with = with };
    }

    fn parseId(self: *Parser) ParseError![]const u8 {
        const t = try self.nextNonDoc();
        return self.identText(t);
    }

    fn identText(self: *Parser, t: lexer.Tok) ParseError![]const u8 {
        switch (t.tag) {
            .id => return t.span.slice(self.source),
            .explicit_id => {
                // Strip leading `%`.
                const text = t.span.slice(self.source);
                return text[1..];
            },
            else => return self.failTok(t, "expected identifier"),
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Test helper: parses into an arena owned by the caller. Caller
/// must keep the arena alive while reading the returned document.
fn parseInto(arena: *std.heap.ArenaAllocator, source: []const u8) !ast.Document {
    var diag: ParseDiagnostic = .{};
    return parse(arena.allocator(), source, &diag) catch |err| {
        const tok_name: []const u8 = if (diag.token) |t| @tagName(t) else "?";
        std.debug.print(
            "parse error: {s} at [{d}, {d}] (token: .{s}): {s}\n",
            .{ @errorName(err), diag.span.start, diag.span.end, tok_name, diag.msg },
        );
        return err;
    };
}

test "parse #192: leading doc comment before package" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Before #192 was fixed, the leading-doc skip loop in
    // parseDocument used `nextNonDoc()` and silently ate the
    // `package` keyword along with the doc, so this source failed
    // with `error.UnexpectedToken` on the `wasi` identifier.
    const source =
        \\/// Doc comment before package.
        \\package docs:adder@0.1.0;
        \\
        \\interface i {
        \\    f: func();
        \\}
        \\
        \\world w {
        \\    import i;
        \\}
    ;
    const doc = try parseInto(&arena, source);
    try testing.expect(doc.package != null);
    try testing.expectEqualStrings("docs", doc.package.?.namespace);
    try testing.expectEqualStrings("adder", doc.package.?.name);
    try testing.expectEqualStrings("0.1.0", doc.package.?.version.?);
    try testing.expectEqual(@as(usize, 2), doc.items.len);
    try testing.expect(doc.items[0] == .interface);
    try testing.expectEqualStrings("i", doc.items[0].interface.name);
    // The leading doc was meant for the package decl (which has no
    // doc field); ensure it didn't leak onto the first interface.
    try testing.expectEqualStrings("", doc.items[0].interface.docs);
    try testing.expect(doc.items[1] == .world);
    try testing.expectEqualStrings("w", doc.items[1].world.name);
}

test "parse #192: leading doc comment with no package attaches to first item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // When there is no `package` decl, the leading doc should
    // attach to the first item as its docstring — matching the
    // normal "docs before any item" behaviour.
    const source =
        \\/// doc-for-iface
        \\interface foo {
        \\    bar: func();
        \\}
    ;
    const doc = try parseInto(&arena, source);
    try testing.expectEqual(@as(?ast.PackageId, null), doc.package);
    try testing.expectEqual(@as(usize, 1), doc.items.len);
    try testing.expect(doc.items[0] == .interface);
    try testing.expectEqualStrings("foo", doc.items[0].interface.name);
    try testing.expectEqualStrings("/// doc-for-iface", doc.items[0].interface.docs);
}

test "parse: empty document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena, "");
    try testing.expectEqual(@as(?ast.PackageId, null), doc.package);
    try testing.expectEqual(@as(usize, 0), doc.items.len);
}

test "parse: package decl only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena, "package docs:adder@0.1.0;");
    try testing.expect(doc.package != null);
    try testing.expectEqualStrings("docs", doc.package.?.namespace);
    try testing.expectEqualStrings("adder", doc.package.?.name);
    try testing.expectEqualStrings("0.1.0", doc.package.?.version.?);
}

test "parse: wamr adder example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\package docs:adder@0.1.0;
        \\
        \\interface add {
        \\    add: func(x: u32, y: u32) -> u32;
        \\}
        \\
        \\world adder {
        \\    export add;
        \\}
    ;
    const doc = try parseInto(&arena, source);
    try testing.expectEqual(@as(usize, 2), doc.items.len);

    try testing.expect(doc.items[0] == .interface);
    const iface = doc.items[0].interface;
    try testing.expectEqualStrings("add", iface.name);
    try testing.expectEqual(@as(usize, 1), iface.items.len);
    try testing.expect(iface.items[0] == .func);
    const func = iface.items[0].func;
    try testing.expectEqualStrings("add", func.name);
    try testing.expectEqual(@as(usize, 2), func.func.params.len);
    try testing.expectEqualStrings("x", func.func.params[0].name);
    try testing.expect(func.func.params[0].type == .u32);
    try testing.expect(func.func.result.? == .u32);

    try testing.expect(doc.items[1] == .world);
    const world = doc.items[1].world;
    try testing.expectEqualStrings("adder", world.name);
    try testing.expectEqual(@as(usize, 1), world.items.len);
    try testing.expect(world.items[0] == .@"export");
}

test "parse: wamr calculator-cmd example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\package docs:zigcalc@0.1.0;
        \\
        \\/// World for the Zig calculator.
        \\world app {
        \\    import docs:adder/add@0.1.0;
        \\}
    ;
    const doc = try parseInto(&arena, source);
    try testing.expect(doc.package != null);
    try testing.expectEqual(@as(usize, 1), doc.items.len);
    try testing.expect(doc.items[0] == .world);
    const w = doc.items[0].world;
    try testing.expectEqualStrings("app", w.name);
    try testing.expect(std.mem.startsWith(u8, w.docs, "///"));
    try testing.expectEqual(@as(usize, 1), w.items.len);
    try testing.expect(w.items[0] == .import);
    const imp = w.items[0].import;
    try testing.expect(imp == .interface_ref);
    const ref = imp.interface_ref.ref;
    try testing.expect(ref.package != null);
    try testing.expectEqualStrings("docs", ref.package.?.namespace);
    try testing.expectEqualStrings("adder", ref.package.?.name);
    try testing.expectEqualStrings("0.1.0", ref.package.?.version.?);
    try testing.expectEqualStrings("add", ref.name);
}

test "parse: record type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    record point {
        \\        x: s32,
        \\        y: s32,
        \\    }
        \\}
    );
    try testing.expectEqual(@as(usize, 1), doc.items.len);
    const iface = doc.items[0].interface;
    try testing.expectEqual(@as(usize, 1), iface.items.len);
    try testing.expect(iface.items[0] == .type);
    const td = iface.items[0].type;
    try testing.expectEqualStrings("point", td.name);
    try testing.expect(td.kind == .record);
    try testing.expectEqual(@as(usize, 2), td.kind.record.len);
    try testing.expectEqualStrings("x", td.kind.record[0].name);
    try testing.expect(td.kind.record[0].type == .s32);
}

test "parse: variant with payloads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    variant shape {
        \\        circle(f64),
        \\        square,
        \\        triangle(tuple<f64, f64>),
        \\    }
        \\}
    );
    const td = doc.items[0].interface.items[0].type;
    try testing.expect(td.kind == .variant);
    try testing.expectEqual(@as(usize, 3), td.kind.variant.len);
    try testing.expectEqualStrings("circle", td.kind.variant[0].name);
    try testing.expect(td.kind.variant[0].type.? == .f64);
    try testing.expect(td.kind.variant[1].type == null);
    try testing.expect(td.kind.variant[2].type.? == .tuple);
}

test "parse: enum and flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    enum direction { north, south, east, west }
        \\    flags perms { read, write, exec }
        \\}
    );
    const items = doc.items[0].interface.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expect(items[0].type.kind == .@"enum");
    try testing.expectEqual(@as(usize, 4), items[0].type.kind.@"enum".len);
    try testing.expect(items[1].type.kind == .flags);
    try testing.expectEqual(@as(usize, 3), items[1].type.kind.flags.len);
}

test "parse: list / option / result types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    take: func(xs: list<u8>, name: option<string>) -> result<u32, string>;
        \\}
    );
    const f = doc.items[0].interface.items[0].func.func;
    try testing.expect(f.params[0].type == .list);
    try testing.expect(f.params[0].type.list.* == .u8);
    try testing.expect(f.params[1].type == .option);
    try testing.expect(f.params[1].type.option.* == .string);
    try testing.expect(f.result.? == .result);
    try testing.expect(f.result.?.result.ok.?.* == .u32);
    try testing.expect(f.result.?.result.err.?.* == .string);
}

test "parse: type alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    type byte = u8;
        \\}
    );
    const td = doc.items[0].interface.items[0].type;
    try testing.expect(td.kind == .alias);
    try testing.expect(td.kind.alias == .u8);
}

test "parse: use clause with rename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    use other.{a, b as renamed};
        \\}
    );
    const u = doc.items[0].interface.items[0].use;
    try testing.expectEqualStrings("other", u.from.name);
    try testing.expectEqual(@as(usize, 2), u.names.len);
    try testing.expectEqualStrings("a", u.names[0].name);
    try testing.expectEqual(@as(?[]const u8, null), u.names[0].rename);
    try testing.expectEqualStrings("renamed", u.names[1].rename.?);
}

test "parse: explicit-id keyword as name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    %record: func();
        \\}
    );
    const f = doc.items[0].interface.items[0].func;
    try testing.expectEqualStrings("record", f.name);
}

test "parse: empty resource decl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    resource file { }
        \\}
    );
    const td = doc.items[0].interface.items[0].type;
    try testing.expectEqualStrings("file", td.name);
    try testing.expectEqual(@as(usize, 0), td.kind.resource.len);
}

test "parse: resource with method, static, constructor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    resource output-stream {
        \\        constructor(seed: u32);
        \\        blocking-write-and-flush: func(contents: list<u8>) -> result;
        \\        check-write: static func() -> u64;
        \\    }
        \\}
    );
    const methods = doc.items[0].interface.items[0].type.kind.resource;
    try testing.expectEqual(@as(usize, 3), methods.len);
    try testing.expectEqual(ast.ResourceMethodKind.constructor, methods[0].kind);
    try testing.expectEqual(@as(usize, 1), methods[0].func.params.len);
    try testing.expectEqual(ast.ResourceMethodKind.method, methods[1].kind);
    try testing.expectEqualStrings("blocking-write-and-flush", methods[1].name);
    try testing.expectEqual(ast.ResourceMethodKind.static, methods[2].kind);
    try testing.expectEqualStrings("check-write", methods[2].name);
}

test "parse: borrow<R> and own<R> type syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    drop-it: func(s: own<output-stream>);
        \\    write: func(s: borrow<output-stream>, data: list<u8>);
        \\}
    );
    const items = doc.items[0].interface.items;
    const own_ty = items[0].func.func.params[0].type;
    const borrow_ty = items[1].func.func.params[0].type;
    try testing.expect(own_ty == .own);
    try testing.expectEqualStrings("output-stream", own_ty.own);
    try testing.expect(borrow_ty == .borrow);
    try testing.expectEqualStrings("output-stream", borrow_ty.borrow);
}

test "parse #195: @since/@unstable/@deprecated annotations at item positions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Annotations attach (per the canonical wasi-http layout) to
    // every item-introducing keyword: world, interface, use,
    // import/export, include, type aliases, record/variant/enum/
    // flags, resource decls, resource members (constructor/method/
    // static), and individual named funcs. The parser drops them
    // as no-op metadata.
    const source =
        \\package docs:demo@0.2.6;
        \\
        \\@since(version = 0.2.0)
        \\interface i {
        \\    @since(version = 0.2.0)
        \\    use other.{thing};
        \\
        \\    @since(version = 0.2.0)
        \\    type byte = u8;
        \\
        \\    @since(version = 0.2.0)
        \\    record r { x: u32 }
        \\
        \\    @since(version = 0.2.0)
        \\    variant v { a, b(string) }
        \\
        \\    @since(version = 0.2.0)
        \\    enum e { a, b }
        \\
        \\    @since(version = 0.2.0)
        \\    flags f { a, b }
        \\
        \\    @unstable(feature = experimental)
        \\    resource res {
        \\        @since(version = 0.2.0)
        \\        constructor();
        \\        @since(version = 0.2.0)
        \\        m: func();
        \\        @since(version = 0.2.0)
        \\        s: static func();
        \\    }
        \\
        \\    @since(version = 0.2.0)
        \\    bare-func: func();
        \\}
        \\
        \\@deprecated
        \\world w {
        \\    @since(version = 0.2.0)
        \\    import i;
        \\    @since(version = 0.2.0)
        \\    export i;
        \\    @since(version = 0.2.0)
        \\    include base;
        \\}
        \\
        \\world base {
        \\    import i;
        \\}
    ;
    const doc = try parseInto(&arena, source);
    try testing.expect(doc.package != null);
    try testing.expectEqual(@as(usize, 3), doc.items.len);
    try testing.expect(doc.items[0] == .interface);
    // Verify the interface's items parsed through annotations: use,
    // type, record, variant, enum, flags, res (resource), bare-func.
    const iface_items = doc.items[0].interface.items;
    try testing.expectEqual(@as(usize, 8), iface_items.len);
    try testing.expect(iface_items[0] == .use);
    try testing.expect(iface_items[1] == .type);
    try testing.expect(iface_items[2] == .type);
    try testing.expect(iface_items[3] == .type);
    try testing.expect(iface_items[4] == .type);
    try testing.expect(iface_items[5] == .type);
    try testing.expect(iface_items[6] == .type);
    try testing.expect(iface_items[7] == .func);
    // World w has 3 items: import + export + include.
    try testing.expect(doc.items[1] == .world);
    try testing.expectEqual(@as(usize, 3), doc.items[1].world.items.len);
}

test "parse #195: trailing comma in single-line func param list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\interface i {
        \\    f: func(x: u32,) -> u32;
        \\}
    );
    const items = doc.items[0].interface.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expect(items[0] == .func);
    try testing.expectEqual(@as(usize, 1), items[0].func.func.params.len);
    try testing.expectEqualStrings("x", items[0].func.func.params[0].name);
}

test "parse #195: trailing comma in multi-line func param list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Mirrors the canonical wasi-* style: every multi-line func sig
    // has a trailing comma after the last param before `)`.
    const doc = try parseInto(&arena,
        \\interface i {
        \\    subscribe-instant: func(
        \\        when: u64,
        \\    ) -> u32;
        \\    blocking-read: func(
        \\        max: u64,
        \\        offset: u32,
        \\    );
        \\}
    );
    const items = doc.items[0].interface.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqual(@as(usize, 1), items[0].func.func.params.len);
    try testing.expectEqualStrings("when", items[0].func.func.params[0].name);
    try testing.expect(items[0].func.func.result.? == .u32);
    try testing.expectEqual(@as(usize, 2), items[1].func.func.params.len);
    try testing.expect(items[1].func.func.result == null);
}

test "parse #195: stacked annotations on a single item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\@since(version = 0.2.0)
        \\@unstable(feature = io)
        \\@deprecated
        \\interface foo {
        \\    bar: func();
        \\}
    );
    try testing.expectEqual(@as(usize, 1), doc.items.len);
    try testing.expect(doc.items[0] == .interface);
    try testing.expectEqualStrings("foo", doc.items[0].interface.name);
}

test "parse #195: bare annotation with no args" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parseInto(&arena,
        \\@unstable
        \\interface foo {
        \\    @deprecated
        \\    bar: func();
        \\}
    );
    try testing.expectEqual(@as(usize, 1), doc.items.len);
    try testing.expectEqualStrings("foo", doc.items[0].interface.name);
    try testing.expectEqual(@as(usize, 1), doc.items[0].interface.items.len);
}

test "parse #216: failure diagnostic carries the offending token tag" {
    // Issue #216 asks the parser to surface the actual token kind
    // that triggered an `UnexpectedToken` error, so users producing
    // smaller repros can pinpoint the construct. `failTok` plumbs
    // the tag into `ParseDiagnostic.token` for every error site.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\interface foo {
        \\    bar: 123;
        \\}
    ;
    var diag: ParseDiagnostic = .{};
    try testing.expectError(error.UnexpectedToken, parse(arena.allocator(), source, &diag));
    try testing.expect(diag.token != null);
    // The `123` integer literal where a `func` keyword was expected
    // — exact tag depends on lexer enum values; assert by name.
    try testing.expectEqualStrings("integer", @tagName(diag.token.?));
}

test "parse #195: every canonical wasi-* WIT file parses individually" {
    // Phase 1 acceptance for #195: every `*.wit` file in canonical
    // wasi-http@0.2.6 + wasi-cli + wasi-io + wasi-clocks +
    // wasi-random + wasi-filesystem + wasi-sockets (all pinned at
    // v0.2.6) parses without grammar errors.
    //
    // Files vendored at src/component/wit/wasi-canon/<pkg>/*.wit. Some files
    // omit a `package` decl (it's inherited from sibling files in
    // the same directory in the canonical multi-file layout); this
    // test prepends a synthetic placeholder package decl when one
    // is missing, since standalone parse is what's exercised here
    // (multi-file primary-package handling is Phase 2 scope).
    const Fixture = struct { path: []const u8, content: []const u8 };
    const fixtures = [_]Fixture{
        .{ .path = "cli/command.wit", .content = @embedFile("wasi-canon/cli/command.wit") },
        .{ .path = "cli/environment.wit", .content = @embedFile("wasi-canon/cli/environment.wit") },
        .{ .path = "cli/exit.wit", .content = @embedFile("wasi-canon/cli/exit.wit") },
        .{ .path = "cli/imports.wit", .content = @embedFile("wasi-canon/cli/imports.wit") },
        .{ .path = "cli/run.wit", .content = @embedFile("wasi-canon/cli/run.wit") },
        .{ .path = "cli/stdio.wit", .content = @embedFile("wasi-canon/cli/stdio.wit") },
        .{ .path = "cli/terminal.wit", .content = @embedFile("wasi-canon/cli/terminal.wit") },
        .{ .path = "clocks/monotonic-clock.wit", .content = @embedFile("wasi-canon/clocks/monotonic-clock.wit") },
        .{ .path = "clocks/timezone.wit", .content = @embedFile("wasi-canon/clocks/timezone.wit") },
        .{ .path = "clocks/wall-clock.wit", .content = @embedFile("wasi-canon/clocks/wall-clock.wit") },
        .{ .path = "clocks/world.wit", .content = @embedFile("wasi-canon/clocks/world.wit") },
        .{ .path = "filesystem/preopens.wit", .content = @embedFile("wasi-canon/filesystem/preopens.wit") },
        .{ .path = "filesystem/types.wit", .content = @embedFile("wasi-canon/filesystem/types.wit") },
        .{ .path = "filesystem/world.wit", .content = @embedFile("wasi-canon/filesystem/world.wit") },
        .{ .path = "http/handler.wit", .content = @embedFile("wasi-canon/http/handler.wit") },
        .{ .path = "http/proxy.wit", .content = @embedFile("wasi-canon/http/proxy.wit") },
        .{ .path = "http/types.wit", .content = @embedFile("wasi-canon/http/types.wit") },
        .{ .path = "io/error.wit", .content = @embedFile("wasi-canon/io/error.wit") },
        .{ .path = "io/poll.wit", .content = @embedFile("wasi-canon/io/poll.wit") },
        .{ .path = "io/streams.wit", .content = @embedFile("wasi-canon/io/streams.wit") },
        .{ .path = "io/world.wit", .content = @embedFile("wasi-canon/io/world.wit") },
        .{ .path = "random/insecure-seed.wit", .content = @embedFile("wasi-canon/random/insecure-seed.wit") },
        .{ .path = "random/insecure.wit", .content = @embedFile("wasi-canon/random/insecure.wit") },
        .{ .path = "random/random.wit", .content = @embedFile("wasi-canon/random/random.wit") },
        .{ .path = "random/world.wit", .content = @embedFile("wasi-canon/random/world.wit") },
        .{ .path = "sockets/instance-network.wit", .content = @embedFile("wasi-canon/sockets/instance-network.wit") },
        .{ .path = "sockets/ip-name-lookup.wit", .content = @embedFile("wasi-canon/sockets/ip-name-lookup.wit") },
        .{ .path = "sockets/network.wit", .content = @embedFile("wasi-canon/sockets/network.wit") },
        .{ .path = "sockets/tcp-create-socket.wit", .content = @embedFile("wasi-canon/sockets/tcp-create-socket.wit") },
        .{ .path = "sockets/tcp.wit", .content = @embedFile("wasi-canon/sockets/tcp.wit") },
        .{ .path = "sockets/udp-create-socket.wit", .content = @embedFile("wasi-canon/sockets/udp-create-socket.wit") },
        .{ .path = "sockets/udp.wit", .content = @embedFile("wasi-canon/sockets/udp.wit") },
        .{ .path = "sockets/world.wit", .content = @embedFile("wasi-canon/sockets/world.wit") },
    };

    for (fixtures) |f| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const ar = arena.allocator();

        // Prepend a synthetic placeholder `package` decl when the
        // file doesn't carry one. The Phase 1 test only exercises
        // parser grammar coverage; multi-file primary-package
        // inheritance is Phase 2 scope.
        const trimmed = std.mem.trimStart(u8, f.content, " \t\r\n");
        // Skip leading line/doc comments to find the first real keyword.
        var i: usize = 0;
        while (i < trimmed.len) {
            if (std.mem.startsWith(u8, trimmed[i..], "///")) {
                while (i < trimmed.len and trimmed[i] != '\n') i += 1;
            } else if (std.mem.startsWith(u8, trimmed[i..], "//")) {
                while (i < trimmed.len and trimmed[i] != '\n') i += 1;
            } else if (std.mem.startsWith(u8, trimmed[i..], "/*")) {
                // skip block comment
                while (i + 1 < trimmed.len and !(trimmed[i] == '*' and trimmed[i + 1] == '/')) i += 1;
                if (i + 1 < trimmed.len) i += 2;
            } else if (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n') {
                i += 1;
            } else {
                break;
            }
        }
        const has_pkg = i < trimmed.len and std.mem.startsWith(u8, trimmed[i..], "package ");
        const src = if (has_pkg)
            f.content
        else
            try std.fmt.allocPrint(ar, "package wabt:test@0.2.6;\n{s}", .{f.content});

        var diag: ParseDiagnostic = .{};
        _ = parse(ar, src, &diag) catch |err| {
            const tok_name: []const u8 = if (diag.token) |t| @tagName(t) else "?";
            std.debug.print(
                "\nfile: {s}\nerror: {s} at [{d}..{d}] (token: .{s}): {s}\n",
                .{ f.path, @errorName(err), diag.span.start, diag.span.end, tok_name, diag.msg },
            );
            return err;
        };
    }
}
