//! `wabt component bindgen` — generate Zig guest bindings from a WIT world.
//!
//! Emits the canonical-ABI *shells* — the flattened `extern` import decls and
//! `export fn` shells, plus the Zig type definitions — and delegates every
//! lower/lift to the `canon` runtime library. This closes the gap Zig comptime
//! can't: synthesizing each function's flattened core signature.
//!
//!   wabt component bindgen --wit <dir> --world <name> [--impl <module>] -o <out.zig>
//!
//! For each interface the world **imports**, a `pub const <iface> = struct { … }`
//! with `extern` decls + typed wrappers (params lowered, results lifted via
//! `canon`). For each interface the world **exports**, top-level `export fn`
//! shells that lift params (`canon.liftParams`), call `Impl.<fn>` (the
//! user-supplied implementation imported via `--impl`), and encode the result
//! (`canon.returnResult`).
//!
//! v1 supports primitives, `string`, `option<T>`, `list<T>`, and named
//! `record`/`enum` types. `variant`/`flags`/`result`, resources, and async
//! (`future`/`stream`) are rejected with a clear error for now.

const std = @import("std");
const wabt = @import("wabt");
const wit = wabt.component.wit;
const ast = wit.ast;
const Allocator = std.mem.Allocator;

pub const usage =
    \\Usage: wabt component bindgen [options]
    \\
    \\Generate Zig guest bindings (canonical-ABI shells targeting the `canon`
    \\library) from a WIT world.
    \\
    \\Options:
    \\  --wit <path>        WIT file or directory (required)
    \\  --world <name>      World to generate bindings for (required if the WIT
    \\                      defines more than one world)
    \\  --impl <module>     Import name for the user implementation of exported
    \\                      interfaces (default: "impl")
    \\  -o, --output <file> Output .zig file (default: stdout)
    \\
;

pub fn run(init: std.process.Init, sub_args: []const []const u8) !void {
    if (sub_args.len > 0 and std.mem.eql(u8, sub_args[0], "help")) {
        writeStdout(init.io, usage);
        return;
    }
    const alloc = init.gpa;

    var wit_path: ?[]const u8 = null;
    var world_arg: ?[]const u8 = null;
    var impl_arg: []const u8 = "impl";
    var output_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "--wit")) {
            i += 1;
            wit_path = nextArg(sub_args, i, arg);
        } else if (std.mem.eql(u8, arg, "--world")) {
            i += 1;
            world_arg = nextArg(sub_args, i, arg);
        } else if (std.mem.eql(u8, arg, "--impl")) {
            i += 1;
            impl_arg = nextArg(sub_args, i, arg);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            output_file = nextArg(sub_args, i, arg);
        } else {
            std.debug.print("error: unknown argument '{s}'. Use `wabt component bindgen help`.\n", .{arg});
            std.process.exit(1);
        }
    }

    const wp = wit_path orelse {
        std.debug.print("error: --wit <path> is required. Use `wabt component bindgen help`.\n", .{});
        std.process.exit(1);
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ar = arena.allocator();

    const resolver = wit.resolver.parseLayout(ar, init.io, wp) catch |err| {
        std.debug.print("error: parsing WIT layout '{s}': {s}\n", .{ wp, @errorName(err) });
        std.process.exit(1);
    };

    const world_name = world_arg orelse (wit.embed.autoselectWorld(resolver.main) orelse {
        std.debug.print("error: WIT '{s}' has no single world; pass --world <name>.\n", .{wp});
        std.process.exit(1);
    });

    const world = findWorld(resolver.main, world_name) orelse {
        std.debug.print("error: world '{s}' not found in '{s}'.\n", .{ world_name, wp });
        std.process.exit(1);
    };

    var g = Gen{ .ar = ar, .resolver = resolver, .impl = impl_arg };
    g.generate(world, world_name) catch |err| {
        std.debug.print("error: generating bindings for world '{s}': {s}\n", .{ world_name, @errorName(err) });
        std.process.exit(1);
    };
    const src = g.out.items;

    if (output_file) |path| {
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = src }) catch |err| {
            std.debug.print("error: cannot write '{s}': {any}\n", .{ path, err });
            std.process.exit(1);
        };
    } else {
        writeStdout(init.io, src);
    }
}

fn nextArg(args: []const []const u8, idx: usize, flag: []const u8) []const u8 {
    if (idx >= args.len) {
        std.debug.print("error: {s} requires an argument\n", .{flag});
        std.process.exit(1);
    }
    return args[idx];
}

fn writeStdout(io: std.Io, text: []const u8) void {
    var f = std.Io.File.stdout();
    f.writeStreamingAll(io, text) catch {};
}

fn findWorld(doc: ast.Document, name: []const u8) ?ast.World {
    for (doc.items) |item| switch (item) {
        .world => |w| if (std.mem.eql(u8, w.name, name)) return w,
        else => {},
    };
    return null;
}

const Core = enum { i32, i64, f32, f64 };

const GenError = error{ OutOfMemory, UnsupportedWitType, UnknownInterface, UnknownType };

const Gen = struct {
    ar: Allocator,
    resolver: wit.resolver.Resolver,
    impl: []const u8,
    out: std.ArrayListUnmanaged(u8) = .empty,
    // WIT type name → its kind, across all interfaces in the world.
    types: std.StringHashMapUnmanaged(ast.TypeDefKind) = .empty,

    fn raw(self: *Gen, s: []const u8) void {
        self.out.appendSlice(self.ar, s) catch @panic("OOM");
    }
    fn print(self: *Gen, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.ar, fmt, args) catch @panic("OOM");
        self.out.appendSlice(self.ar, s) catch @panic("OOM");
    }

    const Use = struct { id: []const u8, iface: ast.Interface, is_export: bool };

    fn generate(self: *Gen, world: ast.World, world_name: []const u8) GenError!void {
        const doc_pkg = self.resolver.main.package;

        var uses = std.ArrayListUnmanaged(Use).empty;
        for (world.items) |item| {
            const extern_item: ?struct { ext: ast.WorldExtern, is_export: bool } = switch (item) {
                .import => |e| .{ .ext = e, .is_export = false },
                .@"export" => |e| .{ .ext = e, .is_export = true },
                else => null,
            };
            const ei = extern_item orelse continue;
            const ref = switch (ei.ext) {
                .interface_ref => |ir| ir.ref,
                else => return error.UnsupportedWitType, // named_func/named_interface: v2
            };
            const iface = self.resolver.findInterface(ref) orelse return error.UnknownInterface;
            try uses.append(self.ar, .{
                .id = try ifaceId(self.ar, ref, doc_pkg),
                .iface = iface,
                .is_export = ei.is_export,
            });
        }

        // Index every named type so `.name` refs resolve.
        for (uses.items) |u| {
            for (u.iface.items) |it| switch (it) {
                .type => |td| try self.types.put(self.ar, td.name, td.kind),
                else => {},
            };
        }

        // ── header ──
        self.print(
            \\//! Generated by `wabt component bindgen` from world `{s}`. Do not edit.
            \\
            \\const canon = @import("canon");
            \\const abi = @import("abi");
            \\
            \\
        , .{world_name});

        // ── named types ──
        for (uses.items) |u| {
            for (u.iface.items) |it| switch (it) {
                .type => |td| try self.emitTypeDef(td),
                else => {},
            };
        }

        var have_exports = false;
        for (uses.items) |u| {
            if (u.is_export) have_exports = true;
        }
        if (have_exports) {
            self.print("const Impl = @import(\"{s}\");\n\n", .{self.impl});
        }

        // ── imports ──
        for (uses.items) |u| {
            if (u.is_export) continue;
            try self.emitImportIface(u);
        }
        // ── exports ──
        for (uses.items) |u| {
            if (!u.is_export) continue;
            try self.emitExportIface(u);
        }
    }

    // ── type emission ────────────────────────────────────────────────

    fn emitTypeDef(self: *Gen, td: ast.TypeDef) GenError!void {
        switch (td.kind) {
            .record => |fields| {
                self.print("pub const {s} = struct {{\n", .{try pascal(self.ar, td.name)});
                for (fields) |f| {
                    self.print("    {s}: {s},\n", .{ try snake(self.ar, f.name), try self.zigType(f.type) });
                }
                self.raw("};\n\n");
            },
            .@"enum" => |cases| {
                self.print("pub const {s} = enum {{\n", .{try pascal(self.ar, td.name)});
                for (cases) |c| self.print("    {s},\n", .{try snake(self.ar, c)});
                self.raw("};\n\n");
            },
            .variant => |cases| {
                self.print("pub const {s} = union(enum) {{\n", .{try pascal(self.ar, td.name)});
                for (cases) |c| {
                    if (c.type) |t| {
                        self.print("    {s}: {s},\n", .{ try snake(self.ar, c.name), try self.zigType(t) });
                    } else {
                        self.print("    {s},\n", .{try snake(self.ar, c.name)});
                    }
                }
                self.raw("};\n\n");
            },
            .flags => |labels| {
                // A bitset: one bool bit per label (LSB-first) in a backing
                // integer sized to the canonical ABI (1/2/4 bytes for ≤8/≤16/≤32
                // labels). >32 labels (multi-i32) is a later phase.
                if (labels.len > 32) return error.UnsupportedWitType;
                const bits: usize = if (labels.len <= 8) 8 else if (labels.len <= 16) 16 else 32;
                self.print("pub const {s} = packed struct(u{d}) {{\n", .{ try pascal(self.ar, td.name), bits });
                for (labels) |l| self.print("    {s}: bool = false,\n", .{try snake(self.ar, l)});
                if (bits > labels.len) self.print("    _padding: u{d} = 0,\n", .{bits - labels.len});
                self.raw("};\n\n");
            },
            .alias => |t| {
                self.print("pub const {s} = {s};\n\n", .{ try pascal(self.ar, td.name), try self.zigType(t) });
            },
            else => return error.UnsupportedWitType, // resource: later phase
        }
    }

    fn zigType(self: *Gen, ty: ast.Type) GenError![]const u8 {
        return switch (ty) {
            .bool => "bool",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .s8 => "i8",
            .s16 => "i16",
            .s32 => "i32",
            .s64 => "i64",
            .f32 => "f32",
            .f64 => "f64",
            .char => "u32",
            .string => "[]const u8",
            .list => |e| try std.fmt.allocPrint(self.ar, "[]const {s}", .{try self.zigType(e.*)}),
            .option => |e| try std.fmt.allocPrint(self.ar, "?{s}", .{try self.zigType(e.*)}),
            .result => |r| blk: {
                const ok = if (r.ok) |t| try self.zigType(t.*) else "void";
                const err = if (r.err) |t| try self.zigType(t.*) else "void";
                break :blk try std.fmt.allocPrint(self.ar, "canon.Result({s}, {s})", .{ ok, err });
            },
            .name => |n| try pascal(self.ar, n),
            else => error.UnsupportedWitType,
        };
    }

    // ── flattening ───────────────────────────────────────────────────

    fn flatCount(self: *Gen, ty: ast.Type) GenError!usize {
        return switch (ty) {
            .string, .list => 2,
            .option => |e| 1 + try self.flatCount(e.*),
            .result => |r| blk: {
                // discriminant + the wider of the ok/err payloads (the canonical
                // ABI joins case payloads; the count is the max). `_` arms = 0.
                const ok = if (r.ok) |t| try self.flatCount(t.*) else 0;
                const err = if (r.err) |t| try self.flatCount(t.*) else 0;
                break :blk 1 + @max(ok, err);
            },
            .name => |n| blk: {
                const kind = self.types.get(n) orelse return error.UnknownType;
                break :blk switch (kind) {
                    .record => |fields| r: {
                        var c: usize = 0;
                        for (fields) |f| c += try self.flatCount(f.type);
                        break :r c;
                    },
                    .variant => |cases| v: {
                        // discriminant + the widest case payload (`null` = 0).
                        var m: usize = 0;
                        for (cases) |c| if (c.type) |t| {
                            m = @max(m, try self.flatCount(t));
                        };
                        break :v 1 + m;
                    },
                    .flags => |labels| (labels.len + 31) / 32, // i32 slots
                    .@"enum" => 1,
                    .alias => |t| try self.flatCount(t),
                    else => error.UnsupportedWitType,
                };
            },
            else => 1, // scalars (bool/int/float/char/enum)
        };
    }

    fn resultZig(self: *Gen, func: ast.Func) GenError![]const u8 {
        return if (func.result) |t| try self.zigType(t) else "void";
    }

    // ── exports ──────────────────────────────────────────────────────

    fn emitExportIface(self: *Gen, u: Use) GenError!void {
        self.print("// exports: {s}\n", .{u.id});
        for (u.iface.items) |it| switch (it) {
            .func => |fd| try self.emitExportFunc(u.id, fd.name, fd.func),
            else => {},
        };
        self.raw("\n");
    }

    fn emitExportFunc(self: *Gen, iface_id: []const u8, name: []const u8, func: ast.Func) GenError!void {
        if (func.is_async) return error.UnsupportedWitType;
        const result_zig = try self.resultZig(func);

        self.print("export fn @\"{s}#{s}\"(", .{ iface_id, name });
        try self.emitFlatParamDecls(func.params);
        self.print(") canon.CoreReturn({s}) {{\n", .{result_zig});
        self.raw("    abi.resetScratch();\n");

        // Lift params into a typed struct via canon. The local is named
        // `__params` (not a WIT-spellable identifier) so it can't shadow a
        // function parameter that happens to be named `a`/`p`/etc.
        if (func.params.len > 0) {
            self.raw("    const __params = canon.liftParams(struct {\n");
            for (func.params) |p| {
                self.print("        {s}: {s},\n", .{ try snake(self.ar, p.name), try self.zigType(p.type) });
            }
            self.raw("    }, .{ ");
            try self.emitFlatSlotNames(func.params);
            self.raw(" });\n");
        }

        // Call the user impl + encode the result.
        const args = try self.implArgList(func.params);
        if (func.result == null) {
            self.print("    Impl.{s}({s});\n", .{ try camel(self.ar, name), args });
            self.raw("    return;\n");
        } else {
            self.print(
                "    return canon.returnResult({s}, Impl.{s}({s}), &abi.alloc);\n",
                .{ result_zig, try camel(self.ar, name), args },
            );
        }
        self.raw("}\n\n");
    }

    fn implArgList(self: *Gen, params: []const ast.Param) GenError![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        for (params, 0..) |p, idx| {
            if (idx != 0) try buf.appendSlice(self.ar, ", ");
            try buf.appendSlice(self.ar, "__params.");
            try buf.appendSlice(self.ar, try snake(self.ar, p.name));
        }
        return buf.items;
    }

    // ── imports ──────────────────────────────────────────────────────

    fn emitImportIface(self: *Gen, u: Use) GenError!void {
        const mod = try snake(self.ar, lastSegment(u.id));
        self.print("pub const {s} = struct {{\n", .{mod});
        // The flattened `extern` import decls live in a private `imp`
        // namespace: their names are the exact WIT function names, which would
        // otherwise collide with the typed wrappers below for single-word
        // functions (e.g. `ack` → both `@"ack"` and `pub fn ack`). Nesting
        // keeps the canonical wasm import (module + field) intact.
        self.raw("    const imp = struct {\n");
        for (u.iface.items) |it| switch (it) {
            .func => |fd| try self.emitImportExtern(u.id, fd.name, fd.func),
            else => {},
        };
        self.raw("    };\n\n");
        for (u.iface.items) |it| switch (it) {
            .func => |fd| try self.emitImportWrapper(fd.name, fd.func),
            else => {},
        };
        self.raw("};\n\n");
    }

    /// Emit the flattened `extern` import declaration (inside the `imp`
    /// namespace) for one imported function.
    fn emitImportExtern(self: *Gen, iface_id: []const u8, name: []const u8, func: ast.Func) GenError!void {
        if (func.is_async) return error.UnsupportedWitType;
        const rcount: usize = if (func.result) |t| try self.flatCount(t) else 0;
        const indirect = rcount > 1;

        self.print("        extern \"{s}\" fn @\"{s}\"(", .{ iface_id, name });
        try self.emitFlatParamDecls(func.params);
        if (indirect) {
            if (func.params.len > 0) self.raw(", ");
            self.raw("retptr: i32");
        }
        if (rcount <= 1 and func.result != null) {
            self.print(") {s};\n", .{@tagName(try self.coreOfResult(func.result.?))});
        } else {
            self.raw(") void;\n");
        }
    }

    /// Emit the typed wrapper that lowers params, calls the `imp.@"…"` extern,
    /// and lifts the result.
    fn emitImportWrapper(self: *Gen, name: []const u8, func: ast.Func) GenError!void {
        if (func.is_async) return error.UnsupportedWitType;
        const result_zig = try self.resultZig(func);
        const rcount: usize = if (func.result) |t| try self.flatCount(t) else 0;
        const indirect = rcount > 1;

        self.print("    pub fn {s}(", .{try camel(self.ar, name)});
        try self.emitTypedParamDecls(func.params);
        self.print(") {s} {{\n", .{result_zig});

        // lower params → arg expressions (emitting temps as needed)
        const call_args = try self.lowerParams(func.params);

        if (indirect) {
            if (call_args.len > 0) {
                self.print("        imp.@\"{s}\"({s}, abi.retPtr());\n", .{ name, call_args });
            } else {
                self.print("        imp.@\"{s}\"(abi.retPtr());\n", .{name});
            }
            self.print("        return canon.lift({s}, abi.retArea());\n", .{result_zig});
        } else if (func.result == null) {
            self.print("        imp.@\"{s}\"({s});\n", .{ name, call_args });
        } else {
            self.print(
                "        return canon.liftResultFlat({s}, imp.@\"{s}\"({s}));\n",
                .{ result_zig, name, call_args },
            );
        }
        self.raw("    }\n");
    }

    /// Lower each high-level param into the flat call arguments, emitting temp
    /// statements for `option<…>`. Returns the comma-joined argument list.
    fn lowerParams(self: *Gen, params: []const ast.Param) GenError![]const u8 {
        var args = std.ArrayListUnmanaged(u8).empty;
        for (params) |p| {
            const pn = try snake(self.ar, p.name);
            if (args.items.len != 0) try args.appendSlice(self.ar, ", ");
            switch (p.type) {
                .string => {
                    try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "@intCast(@intFromPtr({s}.ptr)), @intCast({s}.len)", .{ pn, pn }));
                },
                .option => |e| {
                    // emit disc/payload temps
                    self.print("        const {s}_disc: i32 = if ({s} != null) 1 else 0;\n", .{ pn, pn });
                    switch (e.*) {
                        .string => {
                            self.print("        const {s}_ptr: i32 = if ({s}) |v| @intCast(@intFromPtr(v.ptr)) else 0;\n", .{ pn, pn });
                            self.print("        const {s}_len: i32 = if ({s}) |v| @intCast(v.len) else 0;\n", .{ pn, pn });
                            try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "{s}_disc, {s}_ptr, {s}_len", .{ pn, pn, pn }));
                        },
                        else => return error.UnsupportedWitType,
                    }
                },
                else => {
                    try args.appendSlice(self.ar, try self.scalarLowerExpr(pn, p.type));
                },
            }
        }
        return args.items;
    }

    fn scalarLowerExpr(self: *Gen, name: []const u8, ty: ast.Type) GenError![]const u8 {
        return switch (ty) {
            .bool => std.fmt.allocPrint(self.ar, "@as(i32, @intFromBool({s}))", .{name}),
            .u32, .s32 => std.fmt.allocPrint(self.ar, "@bitCast({s})", .{name}),
            .u64, .s64 => std.fmt.allocPrint(self.ar, "@bitCast({s})", .{name}),
            .u8, .u16, .s8, .s16, .char => std.fmt.allocPrint(self.ar, "@intCast({s})", .{name}),
            .f32, .f64 => self.ar.dupe(u8, name),
            else => error.UnsupportedWitType,
        };
    }

    // ── flat signature helpers ───────────────────────────────────────

    fn emitFlatParamDecls(self: *Gen, params: []const ast.Param) GenError!void {
        var first = true;
        for (params) |p| {
            const slots = try self.paramSlots(p);
            for (slots) |s| {
                if (!first) self.raw(", ");
                first = false;
                self.print("{s}: {s}", .{ s.name, @tagName(s.core) });
            }
        }
    }

    fn emitFlatSlotNames(self: *Gen, params: []const ast.Param) GenError!void {
        var first = true;
        for (params) |p| {
            const slots = try self.paramSlots(p);
            for (slots) |s| {
                if (!first) self.raw(", ");
                first = false;
                self.raw(s.name);
            }
        }
    }

    fn emitTypedParamDecls(self: *Gen, params: []const ast.Param) GenError!void {
        for (params, 0..) |p, idx| {
            if (idx != 0) self.raw(", ");
            self.print("{s}: {s}", .{ try snake(self.ar, p.name), try self.zigType(p.type) });
        }
    }

    const Slot = struct { name: []const u8, core: Core };

    fn paramSlots(self: *Gen, p: ast.Param) GenError![]const Slot {
        var out = std.ArrayListUnmanaged(Slot).empty;
        try self.flattenSlots(&out, try snake(self.ar, p.name), p.type);
        return out.items;
    }

    fn flattenSlots(self: *Gen, out: *std.ArrayListUnmanaged(Slot), base: []const u8, ty: ast.Type) GenError!void {
        switch (ty) {
            .string, .list => {
                try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_ptr", .{base}), .core = .i32 });
                try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_len", .{base}), .core = .i32 });
            },
            .option => |e| {
                try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_disc", .{base}), .core = .i32 });
                try self.flattenSlots(out, base, e.*);
            },
            else => try out.append(self.ar, .{ .name = base, .core = self.coreOf(ty) catch return error.UnsupportedWitType }),
        }
    }

    fn coreOf(self: *Gen, ty: ast.Type) GenError!Core {
        _ = self;
        return switch (ty) {
            .bool, .u8, .u16, .u32, .s8, .s16, .s32, .char => .i32,
            .u64, .s64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            else => error.UnsupportedWitType,
        };
    }

    fn coreOfResult(self: *Gen, ty: ast.Type) GenError!Core {
        // `ty` is a result already known to flatten to a single core slot.
        // Aggregates carrying a discriminant (result / all-void variant / enum)
        // flatten to its i32; a single-field record flattens to that field.
        return switch (ty) {
            .result => .i32,
            .name => |n| switch (self.types.get(n) orelse return error.UnknownType) {
                .@"enum", .variant => .i32,
                .flags => .i32, // ≤32 labels → a single i32 slot
                .record => |fields| if (fields.len == 1)
                    try self.coreOfResult(fields[0].type)
                else
                    error.UnsupportedWitType,
                .alias => |t| try self.coreOfResult(t),
                else => error.UnsupportedWitType,
            },
            else => self.coreOf(ty),
        };
    }
};

// ── name helpers ────────────────────────────────────────────────────

fn ifaceId(ar: Allocator, ref: ast.InterfaceRef, doc_pkg: ?ast.PackageId) ![]const u8 {
    const p = ref.package orelse doc_pkg orelse return ar.dupe(u8, ref.name);
    if (p.version) |v| return std.fmt.allocPrint(ar, "{s}:{s}/{s}@{s}", .{ p.namespace, p.name, ref.name, v });
    return std.fmt.allocPrint(ar, "{s}:{s}/{s}", .{ p.namespace, p.name, ref.name });
}

fn lastSegment(id: []const u8) []const u8 {
    // "example:petstore/store" → "store" (drop any @version too).
    var s = id;
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[0..at];
    return s;
}

fn snake(ar: Allocator, s: []const u8) ![]u8 {
    const out = try ar.dupe(u8, s);
    for (out) |*c| if (c.* == '-') {
        c.* = '_';
    };
    return out;
}

fn pascal(ar: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    var up = true;
    for (s) |c| {
        if (c == '-') {
            up = true;
            continue;
        }
        try out.append(ar, if (up) std.ascii.toUpper(c) else c);
        up = false;
    }
    return out.toOwnedSlice(ar);
}

fn camel(ar: Allocator, s: []const u8) ![]u8 {
    const p = try pascal(ar, s);
    if (p.len > 0) p[0] = std.ascii.toLower(p[0]);
    return p;
}

// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "name helpers" {
    const a = testing.allocator;
    {
        const s = try snake(a, "pet-id");
        defer a.free(s);
        try testing.expectEqualStrings("pet_id", s);
    }
    {
        const s = try pascal(a, "pet");
        defer a.free(s);
        try testing.expectEqualStrings("Pet", s);
    }
    {
        const s = try camel(a, "pet-at");
        defer a.free(s);
        try testing.expectEqualStrings("petAt", s);
    }
}

test "generate: export shells + import wrappers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // record pet { id: u32, name: string } ; ping: func(x: u32) -> u32 ;
    // get: func(id: u32) -> option<pet>
    const pet_fields = [_]ast.Field{
        .{ .name = "id", .type = .u32 },
        .{ .name = "name", .type = .string },
    };
    const pet_ref = ast.Type{ .name = "pet" };
    const opt_pet = ast.Type{ .option = &pet_ref };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "pet", .kind = .{ .record = &pet_fields } } },
        .{ .func = .{ .name = "ping", .func = .{ .params = &.{.{ .name = "x", .type = .u32 }}, .result = .u32 } } },
        .{ .func = .{ .name = "get", .func = .{ .params = &.{.{ .name = "id", .type = .u32 }}, .result = opt_pet } } },
    };
    const iface = ast.Interface{ .name = "store", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "store" } } } },
    } };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "store" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "t" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = exp_world },
            .{ .world = imp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "pub const Pet = struct {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:t/store#ping\"(x: i32) canon.CoreReturn(u32)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "canon.returnResult(u32, Impl.ping(__params.x), &abi.alloc)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:t/store#get\"(id: i32) canon.CoreReturn(?Pet)") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "pub const store = struct {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:t/store\" fn @\"ping\"(x: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.liftResultFlat(u32, imp.@\"ping\"(@bitCast(x)));") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:t/store\" fn @\"get\"(id: i32, retptr: i32) void;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.lift(?Pet, abi.retArea());") != null);
    }
}

test "generate: result<T,E> returns (indirect + flat all-void)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // make: func() -> result<u32, string>   (flatCount 3 → indirect)
    // flag: func() -> result                (flatCount 1 → flat discriminant)
    const u32_ty: ast.Type = .u32;
    const str_ty: ast.Type = .string;
    const res_u32_str = ast.Type{ .result = .{ .ok = &u32_ty, .err = &str_ty } };
    const res_void = ast.Type{ .result = .{ .ok = null, .err = null } };
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "make", .func = .{ .params = &.{}, .result = res_u32_str } } },
        .{ .func = .{ .name = "flag", .func = .{ .params = &.{}, .result = res_void } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "r" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = exp_world },
            .{ .world = imp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:r/api#make\"() canon.CoreReturn(canon.Result(u32, []const u8))") != null);
        try testing.expect(std.mem.indexOf(u8, out, "canon.returnResult(canon.Result(u32, []const u8), Impl.make(), &abi.alloc)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:r/api#flag\"() canon.CoreReturn(canon.Result(void, void))") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        // indirect result: extern takes a retptr, wrapper lifts from the ret area.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:r/api\" fn @\"make\"(retptr: i32) void;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.lift(canon.Result(u32, []const u8), abi.retArea());") != null);
        // flat all-void result: extern returns the i32 discriminant directly.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:r/api\" fn @\"flag\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.liftResultFlat(canon.Result(void, void), imp.@\"flag\"());") != null);
    }
}

test "generate: identifier hygiene (param named `a`, single-word import name)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // pick: func(a: u32) -> u32   — param `a` must not be shadowed by the
    //                               lifted-params local.
    // ack:  func() -> u32         — single-word name: the extern and the
    //                               wrapper must not collide.
    const edge_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "pick", .func = .{ .params = &.{.{ .name = "a", .type = .u32 }}, .result = .u32 } } },
        .{ .func = .{ .name = "ack", .func = .{ .params = &.{}, .result = .u32 } } },
    };
    const iface = ast.Interface{ .name = "edge", .items = &edge_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "edge" } } } },
    } };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "edge" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "e" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = exp_world },
            .{ .world = imp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        // The export param is still `a`; the lifted-params local is `__params`.
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:e/edge#pick\"(a: i32)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "const __params = canon.liftParams(struct {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Impl.pick(__params.a)") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        // Externs are nested in a private namespace, referenced as `imp.@"…"`.
        try testing.expect(std.mem.indexOf(u8, out, "const imp = struct {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:e/edge\" fn @\"ack\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"ack\"()") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn ack()") != null);
    }
}

test "generate: variant typedef + returns (payload-bearing + all-void)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // variant value { num(u32), text(string), nothing }  — payload-bearing.
    // variant flag2 { on, off }                          — all-void (flat).
    const u32_ty: ast.Type = .u32;
    const str_ty: ast.Type = .string;
    const value_cases = [_]ast.Case{
        .{ .name = "num", .type = u32_ty },
        .{ .name = "text", .type = str_ty },
        .{ .name = "nothing", .type = null },
    };
    const flag_cases = [_]ast.Case{
        .{ .name = "on", .type = null },
        .{ .name = "off", .type = null },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "value", .kind = .{ .variant = &value_cases } } },
        .{ .type = .{ .name = "flag2", .kind = .{ .variant = &flag_cases } } },
        .{ .func = .{ .name = "pick", .func = .{ .params = &.{}, .result = ast.Type{ .name = "value" } } } },
        .{ .func = .{ .name = "state", .func = .{ .params = &.{}, .result = ast.Type{ .name = "flag2" } } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "v" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = exp_world },
            .{ .world = imp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        // The named variant becomes a Zig `union(enum)` (void arm for `nothing`).
        try testing.expect(std.mem.indexOf(u8, out, "pub const Value = union(enum) {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    num: u32,") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    text: []const u8,") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    nothing,") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub const Flag2 = union(enum) {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:v/api#pick\"() canon.CoreReturn(Value)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "canon.returnResult(Value, Impl.pick(), &abi.alloc)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:v/api#state\"() canon.CoreReturn(Flag2)") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        // payload-bearing variant → indirect (retptr + lift).
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:v/api\" fn @\"pick\"(retptr: i32) void;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.lift(Value, abi.retArea());") != null);
        // all-void variant → flat i32 discriminant.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:v/api\" fn @\"state\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.liftResultFlat(Flag2, imp.@\"state\"());") != null);
    }
}

test "generate: flags typedef + flat return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // flags perms { read, write, exec } ; get-perms: func() -> perms
    const labels = [_][]const u8{ "read", "write", "exec" };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "perms", .kind = .{ .flags = &labels } } },
        .{ .func = .{ .name = "get-perms", .func = .{ .params = &.{}, .result = ast.Type{ .name = "perms" } } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "f" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = exp_world },
            .{ .world = imp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        // 3 labels (≤8) → a u8-backed packed struct with padding to fill it.
        try testing.expect(std.mem.indexOf(u8, out, "pub const Perms = packed struct(u8) {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    read: bool = false,") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    exec: bool = false,") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    _padding: u5 = 0,") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:f/api#get-perms\"() canon.CoreReturn(Perms)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "canon.returnResult(Perms, Impl.getPerms(), &abi.alloc)") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "pub const Perms = packed struct(u8) {") != null);
        // ≤32 labels → flat i32.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:f/api\" fn @\"get-perms\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return canon.liftResultFlat(Perms, imp.@\"get-perms\"());") != null);
    }
}

