//! Decompiler — generates readable pseudo-code from Module IR.
//!
//! Produces a human-readable text representation of a WebAssembly module
//! showing its structure: imports, exports, memories, globals, and functions.

const std = @import("std");
const types = @import("types.zig");
const Mod = @import("Module.zig");

pub const WriteError = error{OutOfMemory};

/// Generate readable pseudo-code from a Module IR.
pub fn decompile(allocator: std.mem.Allocator, module: *const Mod.Module) WriteError![]u8 {
    var d = Decomp{ .allocator = allocator, .buf = .empty };
    errdefer d.buf.deinit(allocator);
    try d.emit(module);
    return d.buf.toOwnedSlice(allocator);
}

fn resolveSig(module: *const Mod.Module, decl: Mod.FuncDeclaration) types.FuncType {
    switch (decl.type_var) {
        .index => |ti| {
            if (ti != types.invalid_index and ti < module.module_types.items.len) {
                switch (module.module_types.items[ti]) {
                    .func_type => |ft| return .{ .params = ft.params, .results = ft.results },
                    else => {},
                }
            }
        },
        .name => {},
    }
    return decl.sig;
}

fn getFuncSig(module: *const Mod.Module, index: u32) types.FuncType {
    if (index >= module.funcs.items.len) return .{};
    return resolveSig(module, module.funcs.items[index].decl);
}

const Decomp = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),

    // ── Main emitter ────────────────────────────────────────────────────

    fn emit(self: *Decomp, module: *const Mod.Module) WriteError!void {
        // Header
        try self.append("// Module: ");
        if (module.name) |n| {
            try self.append(n);
        } else {
            try self.append("<unnamed>");
        }
        try self.appendByte('\n');

        try self.append("// Types: ");
        try self.writeUsize(module.module_types.items.len);
        try self.append(", Functions: ");
        try self.writeUsize(module.funcs.items.len);
        try self.append(", Memories: ");
        try self.writeUsize(module.memories.items.len);
        try self.append(", Tables: ");
        try self.writeUsize(module.tables.items.len);
        try self.append(", Globals: ");
        try self.writeUsize(module.globals.items.len);
        try self.appendByte('\n');

        // Imports
        if (module.imports.items.len > 0) {
            try self.append("\n// Imports\n");
            for (module.imports.items) |imp| {
                try self.writeImport(module, imp);
            }
        }

        // Exports
        if (module.exports.items.len > 0) {
            try self.append("\n// Exports\n");
            for (module.exports.items) |exp| {
                try self.writeExport(exp);
            }
        }

        // Memory (defined, non-imported)
        if (module.num_memory_imports < module.memories.items.len) {
            try self.append("\n// Memory\n");
            for (module.memories.items[module.num_memory_imports..], 0..) |mem, i| {
                try self.append("memory mem");
                try self.writeU32(@intCast(i));
                try self.append(" : initial=");
                try self.writeU64(mem.type.limits.initial);
                if (mem.type.limits.has_max) {
                    try self.append(", max=");
                    try self.writeU64(mem.type.limits.max);
                }
                try self.append(";\n");
            }
        }

        // Globals (defined, non-imported)
        if (module.num_global_imports < module.globals.items.len) {
            try self.append("\n// Globals\n");
            for (module.globals.items[module.num_global_imports..], 0..) |global, i| {
                try self.append("global g");
                try self.writeU32(@intCast(i));
                try self.append(" : ");
                if (global.type.mutability == .mutable) {
                    try self.append("mutable ");
                }
                try self.append(global.type.val_type.name());
                try self.append(" = 0;\n");
            }
        }

        // Functions (defined, non-imported)
        if (module.num_func_imports < module.funcs.items.len) {
            try self.append("\n// Functions\n");
            for (module.funcs.items[module.num_func_imports..], 0..) |_, i| {
                const idx = module.num_func_imports + @as(u32, @intCast(i));
                const sig = getFuncSig(module, idx);
                try self.append("function func_");
                try self.writeU32(idx);
                try self.appendByte('(');
                try self.writeSigParams(sig.params);
                try self.appendByte(')');
                if (sig.results.len > 0) {
                    try self.append(" -> ");
                    try self.writeSigResults(sig.results);
                }
                try self.append(" {\n  // (empty body)\n}\n\n");
            }
        }
    }

    // ── Section writers ─────────────────────────────────────────────────

    fn writeImport(self: *Decomp, module: *const Mod.Module, imp: Mod.Import) WriteError!void {
        try self.append("import ");
        switch (imp.kind) {
            .func => {
                try self.append("function ");
                try self.append(imp.module_name);
                try self.appendByte('.');
                try self.append(imp.field_name);
                try self.append(" : ");
                if (imp.func) |f| {
                    const sig = resolveSig(module, f);
                    try self.writeSigDisplay(sig.params, sig.results);
                } else {
                    try self.append("() -> ()");
                }
            },
            .memory => {
                try self.append("memory ");
                try self.append(imp.module_name);
                try self.appendByte('.');
                try self.append(imp.field_name);
                try self.append(" : ");
                if (imp.memory) |mem| {
                    try self.append("initial=");
                    try self.writeU64(mem.limits.initial);
                    if (mem.limits.has_max) {
                        try self.append(", max=");
                        try self.writeU64(mem.limits.max);
                    }
                } else {
                    try self.append("initial=0");
                }
            },
            .table => {
                try self.append("table ");
                try self.append(imp.module_name);
                try self.appendByte('.');
                try self.append(imp.field_name);
                try self.append(" : ");
                if (imp.table) |t| {
                    try self.append(t.elem_type.name());
                    try self.append(", initial=");
                    try self.writeU64(t.limits.initial);
                } else {
                    try self.append("funcref, initial=0");
                }
            },
            .global => {
                try self.append("global ");
                try self.append(imp.module_name);
                try self.appendByte('.');
                try self.append(imp.field_name);
                try self.append(" : ");
                if (imp.global) |g| {
                    if (g.mutability == .mutable) try self.append("mutable ");
                    try self.append(g.val_type.name());
                } else {
                    try self.append("i32");
                }
            },
            .tag => {
                try self.append("tag ");
                try self.append(imp.module_name);
                try self.appendByte('.');
                try self.append(imp.field_name);
            },
        }
        try self.append(";\n");
    }

    fn writeExport(self: *Decomp, exp: Mod.Export) WriteError!void {
        try self.append("export ");
        try self.append(externalKindName(exp.kind));
        try self.append(" \"");
        try self.append(exp.name);
        try self.append("\" = ");
        try self.append(externalKindName(exp.kind));
        try self.appendByte('[');
        try self.writeU32(exp.var_.index);
        try self.append("];\n");
    }

    // ── Signature display ───────────────────────────────────────────────

    fn writeSigParams(self: *Decomp, params: []const types.ValType) WriteError!void {
        const param_names = "abcdefghijklmnopqrstuvwxyz";
        for (params, 0..) |p, i| {
            if (i > 0) try self.append(", ");
            try self.append(p.name());
            try self.appendByte(' ');
            if (i < param_names.len) {
                try self.appendByte(param_names[i]);
            } else {
                try self.appendByte('_');
            }
        }
    }

    fn writeSigResults(self: *Decomp, results: []const types.ValType) WriteError!void {
        for (results, 0..) |r, i| {
            if (i > 0) try self.append(", ");
            try self.append(r.name());
        }
    }

    fn writeSigDisplay(self: *Decomp, params: []const types.ValType, results: []const types.ValType) WriteError!void {
        try self.appendByte('(');
        for (params, 0..) |p, i| {
            if (i > 0) try self.append(", ");
            try self.append(p.name());
        }
        try self.append(") -> (");
        for (results, 0..) |r, i| {
            if (i > 0) try self.append(", ");
            try self.append(r.name());
        }
        try self.appendByte(')');
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fn a(self: *Decomp) std.mem.Allocator {
        return self.allocator;
    }

    fn append(self: *Decomp, s: []const u8) WriteError!void {
        try self.buf.appendSlice(self.a(), s);
    }

    fn appendByte(self: *Decomp, b: u8) WriteError!void {
        try self.buf.append(self.a(), b);
    }

    fn writeU32(self: *Decomp, v: u32) WriteError!void {
        var tmp: [16]u8 = undefined;
        const result = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.append(result);
    }

    fn writeU64(self: *Decomp, v: u64) WriteError!void {
        var tmp: [24]u8 = undefined;
        const result = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.append(result);
    }

    fn writeUsize(self: *Decomp, v: usize) WriteError!void {
        var tmp: [24]u8 = undefined;
        const result = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
        try self.append(result);
    }

    fn externalKindName(kind: types.ExternalKind) []const u8 {
        return switch (kind) {
            .func => "function",
            .table => "table",
            .memory => "memory",
            .global => "global",
            .tag => "tag",
        };
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "empty module produces header" {
    var module = Mod.Module.init(std.testing.allocator);
    defer module.deinit();
    const output = try decompile(std.testing.allocator, &module);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "// Module: <unnamed>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Types: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Functions: 0") != null);
}

test "decompile with memory" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.memories.append(alloc, .{ .type = .{ .limits = .{ .initial = 1, .has_max = true, .max = 256 } } });
    const output = try decompile(alloc, &module);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "memory mem0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "initial=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "max=256") != null);
}

test "decompile with import" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.imports.append(alloc, .{
        .module_name = "env",
        .field_name = "log",
        .kind = .func,
        .func = .{},
    });
    module.num_func_imports = 1;
    try module.funcs.append(alloc, .{ .is_import = true });
    const output = try decompile(alloc, &module);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "import function env.log") != null);
}

test "decompile with export" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.exports.append(alloc, .{ .name = "main", .kind = .func, .var_ = .{ .index = 0 } });
    const output = try decompile(alloc, &module);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "export function \"main\" = function[0]") != null);
}

test "decompile with global" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.globals.append(alloc, .{ .type = .{ .val_type = .i32, .mutability = .mutable } });
    const output = try decompile(alloc, &module);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "global g0 : mutable i32") != null);
}

test "decompile with function" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    try module.funcs.append(alloc, .{});
    const output = try decompile(alloc, &module);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "function func_0()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "// (empty body)") != null);
}

test "decompile with named module" {
    const alloc = std.testing.allocator;
    var module = Mod.Module.init(alloc);
    defer module.deinit();
    module.name = "test_module";
    const output = try decompile(alloc, &module);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "// Module: test_module") != null);
}
