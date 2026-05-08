//! Extract core-wasm import / export tables from the adapter binary.
//!
//! The splicer needs to know:
//!
//!   * Every `(import "<module>" "<name>" func ...)` the adapter
//!     declares — these drive shim/fixup synthesis (preview1 imports
//!     get trapping stubs in the shim, then patched up by the fixup
//!     start function) and the `canon lower` choreography for the
//!     adapter's WASI imports.
//!
//!   * Every `(export "<name>" ...)` — specifically the
//!     `wasi_snapshot_preview1.<name>` exports the adapter publishes
//!     and the `wasi:cli/run@<ver>#run` style exports that the
//!     wrapping component lifts.
//!
//! This module is a thin façade over `binary/reader.zig` — it parses
//! the adapter core wasm into a `Module` and reorganises the
//! relevant slices into a flat `CoreInterface` value with stable
//! views (string/sig data still owns from the underlying `Module`).
//! Callers must keep the `Module` alive for the lifetime of any
//! returned slice (we expose a small `Owned` wrapper that bundles
//! the two so callers don't accidentally free the backing buffer).

const std = @import("std");
const Allocator = std.mem.Allocator;

const reader = @import("../../binary/reader.zig");
const Module = @import("../../Module.zig").Module;
const wtypes = @import("../../types.zig");

pub const Error = reader.ReadError || error{NotCoreWasm};

pub const FuncSig = struct {
    params: []const wtypes.ValType,
    results: []const wtypes.ValType,
};

pub const ImportEntry = struct {
    module_name: []const u8,
    field_name: []const u8,
    /// Only `.func` is interesting for the splicer; other kinds
    /// (table/memory/global) are surfaced for completeness so a
    /// caller can warn-and-skip.
    kind: wtypes.ExternalKind,
    /// Function signature when `kind == .func`, else null.
    sig: ?FuncSig,
};

pub const ExportEntry = struct {
    name: []const u8,
    kind: wtypes.ExternalKind,
    /// Function signature when `kind == .func`, else null.
    sig: ?FuncSig,
};

pub const CoreInterface = struct {
    imports: []const ImportEntry,
    exports: []const ExportEntry,

    /// Iterate imports whose module field equals `module_name`.
    pub fn importsFromModule(
        self: CoreInterface,
        module_name: []const u8,
    ) ImportFromIterator {
        return .{ .all = self.imports, .filter = module_name, .i = 0 };
    }

    pub const ImportFromIterator = struct {
        all: []const ImportEntry,
        filter: []const u8,
        i: usize,

        pub fn next(self: *ImportFromIterator) ?ImportEntry {
            while (self.i < self.all.len) : (self.i += 1) {
                const e = self.all[self.i];
                if (std.mem.eql(u8, e.module_name, self.filter)) {
                    self.i += 1;
                    return e;
                }
            }
            return null;
        }
    };

    /// Lookup exactly one export by name. Returns null if absent.
    pub fn findExport(self: CoreInterface, name: []const u8) ?ExportEntry {
        for (self.exports) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

/// Owned bundle: the parsed `Module` plus a `CoreInterface` whose
/// slices borrow from it. Free with `deinit`.
pub const Owned = struct {
    module: Module,
    interface: CoreInterface,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Owned) void {
        self.module.deinit();
        self.arena.deinit();
    }
};

/// Parse an adapter core wasm and extract its import/export tables.
///
/// `gpa` is used both for the underlying `Module` parse and for an
/// arena that holds the `CoreInterface` slices. Callers `deinit` the
/// returned `Owned` value when done.
pub fn extract(gpa: Allocator, core_bytes: []const u8) Error!Owned {
    if (core_bytes.len < 8 or !std.mem.eql(u8, core_bytes[0..4], "\x00asm")) {
        return error.NotCoreWasm;
    }

    var module = try reader.readModule(gpa, core_bytes);
    errdefer module.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const imports = try a.alloc(ImportEntry, module.imports.items.len);
    for (module.imports.items, 0..) |im, i| {
        imports[i] = .{
            .module_name = im.module_name,
            .field_name = im.field_name,
            .kind = im.kind,
            .sig = if (im.kind == .func and im.func != null)
                lookupFuncSig(&module, im.func.?.type_var.index)
            else
                null,
        };
    }

    var exports_list = std.ArrayListUnmanaged(ExportEntry).empty;
    try exports_list.ensureTotalCapacity(a, module.exports.items.len);
    for (module.exports.items) |ex| {
        var sig: ?FuncSig = null;
        if (ex.kind == .func) {
            const fidx = ex.var_.index;
            if (fidx < module.funcs.items.len) {
                const f = module.funcs.items[fidx];
                sig = lookupFuncSig(&module, f.decl.type_var.index);
            }
        }
        exports_list.appendAssumeCapacity(.{
            .name = ex.name,
            .kind = ex.kind,
            .sig = sig,
        });
    }

    return .{
        .module = module,
        .arena = arena,
        .interface = .{
            .imports = imports,
            .exports = try exports_list.toOwnedSlice(a),
        },
    };
}

/// Resolve a func type index to its signature via the module's type
/// table. Returns null on out-of-bounds or non-func type entry —
/// shouldn't happen for a validated module but the splicer prefers a
/// soft failure to surfacing internal indices to its callers.
fn lookupFuncSig(module: *const Module, type_idx: u32) ?FuncSig {
    if (type_idx >= module.module_types.items.len) return null;
    const entry = module.module_types.items[type_idx];
    return switch (entry) {
        .func_type => |ft| .{ .params = ft.params, .results = ft.results },
        else => null,
    };
}

// ── tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const leb = @import("../../leb128.zig");

/// Hand-build a tiny core wasm with one type, one import
/// (`adapter_in.ping: () -> i32`), and one func/export
/// (`wasi_snapshot_preview1.fd_write: (i32, i32, i32, i32) -> i32`).
fn buildMockAdapterCore(allocator: Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);

    // Magic + version
    try out.appendSlice(allocator, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });

    const Section = struct {
        fn write(buf: *std.ArrayListUnmanaged(u8), alloc: Allocator, id: u8, body: []const u8) !void {
            try buf.append(alloc, id);
            var len_buf: [leb.max_u32_bytes]u8 = undefined;
            const n = leb.writeU32Leb128(&len_buf, @intCast(body.len));
            try buf.appendSlice(alloc, len_buf[0..n]);
            try buf.appendSlice(alloc, body);
        }
    };

    // Type section: 2 types — () -> i32 and (i32 i32 i32 i32) -> i32
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        // type 0: () -> i32
        try b.append(allocator, 0x60); // func
        try b.append(allocator, 0x00); // 0 params
        try b.append(allocator, 0x01); // 1 result
        try b.append(allocator, 0x7f); // i32
        // type 1: (i32 i32 i32 i32) -> i32
        try b.append(allocator, 0x60);
        try b.append(allocator, 0x04);
        try b.appendSlice(allocator, &.{ 0x7f, 0x7f, 0x7f, 0x7f });
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x7f);
        try Section.write(&out, allocator, 0x01, b.items);
    }

    // Import section: adapter_in.ping (typeidx 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01); // count
        const mod_name = "adapter_in";
        const fld_name = "ping";
        try b.append(allocator, @intCast(mod_name.len));
        try b.appendSlice(allocator, mod_name);
        try b.append(allocator, @intCast(fld_name.len));
        try b.appendSlice(allocator, fld_name);
        try b.append(allocator, 0x00); // import desc: func
        try b.append(allocator, 0x00); // typeidx 0
        try Section.write(&out, allocator, 0x02, b.items);
    }

    // Function section: 1 func with type idx 1
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x01); // typeidx 1
        try Section.write(&out, allocator, 0x03, b.items);
    }

    // Export section: "wasi_snapshot_preview1.fd_write" -> func idx 1
    // (idx 0 is the imported `adapter_in.ping`; defined func is idx 1)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        const ex_name = "wasi_snapshot_preview1.fd_write";
        try b.append(allocator, @intCast(ex_name.len));
        try b.appendSlice(allocator, ex_name);
        try b.append(allocator, 0x00); // export desc: func
        try b.append(allocator, 0x01); // funcidx 1
        try Section.write(&out, allocator, 0x07, b.items);
    }

    // Code section: the defined func is `i32.const 0; end`
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);                     // 1 body
        try b.append(allocator, 0x04);                     // body size
        try b.append(allocator, 0x00);                     // 0 locals
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b }); // i32.const 0; end
        try Section.write(&out, allocator, 0x0a, b.items);
    }

    return out.toOwnedSlice(allocator);
}

test "extract: surfaces imports and exports with sigs" {
    const core = try buildMockAdapterCore(testing.allocator);
    defer testing.allocator.free(core);

    var owned = try extract(testing.allocator, core);
    defer owned.deinit();

    try testing.expectEqual(@as(usize, 1), owned.interface.imports.len);
    try testing.expectEqualStrings("adapter_in", owned.interface.imports[0].module_name);
    try testing.expectEqualStrings("ping", owned.interface.imports[0].field_name);
    try testing.expectEqual(wtypes.ExternalKind.func, owned.interface.imports[0].kind);
    try testing.expect(owned.interface.imports[0].sig != null);
    try testing.expectEqual(@as(usize, 0), owned.interface.imports[0].sig.?.params.len);
    try testing.expectEqual(@as(usize, 1), owned.interface.imports[0].sig.?.results.len);

    try testing.expectEqual(@as(usize, 1), owned.interface.exports.len);
    try testing.expectEqualStrings("wasi_snapshot_preview1.fd_write", owned.interface.exports[0].name);
    try testing.expect(owned.interface.exports[0].sig != null);
    try testing.expectEqual(@as(usize, 4), owned.interface.exports[0].sig.?.params.len);
}

test "extract: importsFromModule iterator filters correctly" {
    const core = try buildMockAdapterCore(testing.allocator);
    defer testing.allocator.free(core);

    var owned = try extract(testing.allocator, core);
    defer owned.deinit();

    var it = owned.interface.importsFromModule("adapter_in");
    var n: usize = 0;
    while (it.next() != null) : (n += 1) {}
    try testing.expectEqual(@as(usize, 1), n);

    it = owned.interface.importsFromModule("not_a_module");
    try testing.expect(it.next() == null);
}

test "extract: findExport works" {
    const core = try buildMockAdapterCore(testing.allocator);
    defer testing.allocator.free(core);

    var owned = try extract(testing.allocator, core);
    defer owned.deinit();

    const e = owned.interface.findExport("wasi_snapshot_preview1.fd_write");
    try testing.expect(e != null);
    try testing.expect(owned.interface.findExport("missing") == null);
}

test "extract: rejects non-core wasm bytes" {
    try testing.expectError(error.NotCoreWasm, extract(testing.allocator, "\x00\x00\x00\x00\x01\x00\x00\x00"));
}
