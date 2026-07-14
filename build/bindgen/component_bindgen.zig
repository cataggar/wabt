//! `wabt component bindgen` — generate Zig guest bindings from a WIT world.
//!
//! Emits the canonical-ABI *shells* — the flattened `extern` import decls and
//! `export fn` shells, plus the Zig type definitions — and delegates every
//! lower/lift to the `canon` runtime library. This closes the gap Zig comptime
//! can't: synthesizing each function's flattened core signature.
//!
//!   wabt component bindgen --wit <dir> --world <name>
//!       [--impl <module> | --dispatch <module>] -o <out.zig>
//!
//! For each interface the world **imports**, a `pub const <iface> = struct { … }`
//! with `extern` decls + typed wrappers (params lowered, results lifted via
//! `canon`). World-level function imports get module-scope typed wrappers over
//! canonical `$root` core imports. For each interface or world-level function
//! the world **exports**, top-level `export fn` shells lift params
//! (`canon.liftParams`), call either `Impl.<fn>` (the user-supplied
//! implementation imported via `--impl`) or a generic `__wit_dispatch.call`
//! imported via `--dispatch`, and encode the result (`canon.returnResult`).
//!
//! Supports primitives, `string`, `option<T>`, `list<T>`, named
//! `record`/`enum`/`variant`/`flags`/`result`/`tuple` types, imported
//! resources, async exports (`task.return`), and `future<T>`/`stream<T>` —
//! primitive elements via `canon.Future`/`Stream`, complex (aggregate /
//! resource-bearing) elements via `canon.FutureOf`/`StreamOf` bound to a
//! function-reference intrinsic `[future]<iface>#<fn>#<idx>`.

const std = @import("std");
const wabt = @import("wabt");
const wit = wabt.component.wit;
const ast = wit.ast;
const Allocator = std.mem.Allocator;

pub const usage =
    \\Usage: wasip3-bindgen [options]
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
    \\  --dispatch <module> Import a generic export dispatcher instead of a
    \\                      per-function implementation. The module must expose:
    \\                        pub fn call(comptime export_name: []const u8,
    \\                          comptime Result: type, args: anytype) Result
    \\                      Mutually exclusive with --impl.
    \\  --manual-return <fn>
    \\                      Generate an async export `<fn>` in manual-return form:
    \\                      the shell calls `Impl.<fn>(params)` (returning void)
    \\                      and the bindings expose a `pub fn <fn>Return(result)`
    \\                      the impl calls when ready. Lets the handler keep
    \\                      running after `task.return` (e.g. to write a
    \\                      `wasi:http` response body stream). Repeatable.
    \\  --js-imports        Also emit a JS-callable reverse bridge for every
    \\                      imported interface or world-level function. The
    \\                      manifest convention is:
    \\                        interface: <iface>\t<fn>\t<iface>#<fn>\t<arity>
    \\                        root:      <fn>\tdefault\t$root#<fn>\t<arity>
    \\                      The root form matches ComponentizeJS default imports.
    \\                      Requires --dispatch. Every imported function's
    \\                      parameter/result types must be within the native
    \\                      bridge's supported set (bool, integers, f32/f64,
    \\                      char, string, option<T>, list<T>, tuple, record,
    \\                      variant, enum, <=32-label flags, and result<T,E>,
    \\                      recursively). Resources, future/stream,
    \\                      error-context, async functions, and >32-label flags
    \\                      fail deterministically rather than being skipped.
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
    var impl_explicit = false;
    var dispatch_arg: ?[]const u8 = null;
    var js_imports_arg = false;
    var output_file: ?[]const u8 = null;
    var manual_returns = std.ArrayListUnmanaged([]const u8).empty;
    defer manual_returns.deinit(alloc);

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
            impl_explicit = true;
        } else if (std.mem.eql(u8, arg, "--dispatch")) {
            i += 1;
            dispatch_arg = nextArg(sub_args, i, arg);
        } else if (std.mem.eql(u8, arg, "--js-imports")) {
            js_imports_arg = true;
        } else if (std.mem.eql(u8, arg, "--manual-return")) {
            i += 1;
            manual_returns.append(alloc, nextArg(sub_args, i, arg)) catch @panic("OOM");
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            output_file = nextArg(sub_args, i, arg);
        } else {
            std.debug.print("error: unknown argument '{s}'. Use `wabt component bindgen help`.\n", .{arg});
            std.process.exit(1);
        }
    }

    if (impl_explicit and dispatch_arg != null) {
        std.debug.print("error: --impl and --dispatch are mutually exclusive.\n", .{});
        std.process.exit(1);
    }

    if (js_imports_arg and dispatch_arg == null) {
        std.debug.print("error: --js-imports requires --dispatch (the JS import bridge reuses the same js_dispatch module).\n", .{});
        std.process.exit(1);
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

    var g = Gen{
        .ar = ar,
        .resolver = resolver,
        .impl = impl_arg,
        .dispatch = dispatch_arg,
        .manual_returns = manual_returns.items,
        .js_imports = js_imports_arg,
    };
    g.generate(world, world_name) catch |err| {
        std.debug.print("error: generating bindings for world '{s}': {s}\n", .{ world_name, @errorName(err) });
        if (g.diag.len != 0) {
            std.debug.print("  {s}\n", .{g.diag});
        }
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

/// A generated nominal type for a complex (non-primitive-element) future/stream
/// channel: its Zig name and the `canon.FutureOf(…)` / `canon.StreamOf(…)` RHS.
const ChanDecl = struct { name: []const u8, rhs: []const u8 };

/// Per-interface view of a named type: its kind and the interface whose name
/// drives the emitted Zig identifier (the definer — itself for a local type, or
/// the source for a `use`d type).
const ScopedType = struct { kind: ast.TypeDefKind, def_iface: []const u8 };

const GenError = error{ OutOfMemory, UnsupportedWitType, UnknownInterface, UnknownType };

const Gen = struct {
    ar: Allocator,
    resolver: wit.resolver.Resolver,
    impl: []const u8,
    dispatch: ?[]const u8 = null,
    /// When true (`--js-imports`), also emit the JS-callable reverse bridge
    /// (`starling_js_import_dispatch` + `starling_js_imports_manifest`) for
    /// every imported interface or root function -- see
    /// `emitJsImportBridge` below.
    js_imports: bool = false,
    /// Extra detail for the most recent `error.UnsupportedWitType` (or other
    /// `GenError`) returned by `generate`, set via `fail`. Empty when no error
    /// has occurred, or when the error came from a call site that didn't set
    /// one (e.g. an interface/type lookup miss). `run()` prints this after
    /// the bare error name so a build failure names the offending
    /// function/type instead of just the error tag.
    diag: []const u8 = "",
    /// Async export func names to generate in manual-return form (`--manual-return`).
    manual_returns: []const []const u8 = &.{},
    out: std.ArrayListUnmanaged(u8) = .empty,
    // WIT type name → its kind, across all interfaces in the world. Global
    // fallback; per-interface resolution goes through `scoped` first so
    // same-named types in different interfaces (e.g. two `error-code`s) keep
    // their own structure + Zig name (#303).
    types: std.StringHashMapUnmanaged(ast.TypeDefKind) = .empty,
    // (iface_id \x00 name) → { kind, def_iface } for every named type each
    // interface can reference (its locals + `use`d types). `def_iface` is the
    // interface whose name drives the emitted Zig identifier.
    scoped: std.StringHashMapUnmanaged(ScopedType) = .empty,
    // Names defined *locally* by ≥2 interfaces — their Zig identifier is
    // disambiguated by the defining interface.
    colliding: std.StringHashMapUnmanaged(void) = .empty,
    // Interface basename → number of world interfaces with that basename.
    // Duplicate names such as wasi:filesystem/types and wasi:http/types need
    // package-qualified Zig namespaces and type prefixes.
    iface_name_counts: std.StringHashMapUnmanaged(usize) = .empty,
    // Monotonic counter for naming per-export `[task-return]` helper structs.
    task_counter: usize = 0,
    // Distinct complex (non-primitive-element) future/stream channels → the
    // generated nominal type name. Key: "<iface>|" + "F:"/"S:" + element zig
    // type — per-interface, so a channel binds to a function-reference site in
    // the interface where it appears (subset-world composition; #295).
    chan_map: std.StringHashMapUnmanaged([]const u8) = .empty,
    // The nominal channel type decls to emit (name + RHS), in discovery order.
    chan_decls: std.ArrayListUnmanaged(ChanDecl) = .empty,
    chan_counter: usize = 0,
    // The interface whose funcs/types are currently being walked or emitted;
    // disambiguates complex channels by their declaring interface.
    current_iface: []const u8 = "",
    // True when the world imports an async func (the wrappers need `cm_async`).
    needs_cm_async: bool = false,

    fn raw(self: *Gen, s: []const u8) void {
        self.out.appendSlice(self.ar, s) catch @panic("OOM");
    }
    fn print(self: *Gen, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.ar, fmt, args) catch @panic("OOM");
        self.out.appendSlice(self.ar, s) catch @panic("OOM");
    }

    /// Records a human-readable detail message (surfaced by `run()` after the
    /// bare `GenError` name) and returns `error.UnsupportedWitType`. Used by
    /// checks that reject a specific unsupported construct so the resulting
    /// build failure names the offending function/type instead of leaving
    /// the caller to guess from `error.UnsupportedWitType` alone.
    fn fail(self: *Gen, comptime fmt: []const u8, args: anytype) GenError {
        self.diag = std.fmt.allocPrint(self.ar, fmt, args) catch @panic("OOM");
        return error.UnsupportedWitType;
    }

    const Use = struct { id: []const u8, iface: ast.Interface, is_export: bool, pkg: ?ast.PackageId };
    const TopFunc = struct { name: []const u8, func: ast.Func, is_export: bool };

    fn generate(self: *Gen, world: ast.World, world_name: []const u8) GenError!void {
        const doc_pkg = self.resolver.main.package;

        var uses = std.ArrayListUnmanaged(Use).empty;
        // Top-level world funcs (`named_func`): emitted at module scope
        // (no enclosing interface struct), separate from `uses`.
        var top_funcs = std.ArrayListUnmanaged(TopFunc).empty;
        for (world.items) |item| {
            const extern_item: ?struct { ext: ast.WorldExtern, is_export: bool } = switch (item) {
                .import => |e| .{ .ext = e, .is_export = false },
                .@"export" => |e| .{ .ext = e, .is_export = true },
                else => null,
            };
            const ei = extern_item orelse continue;
            switch (ei.ext) {
                .interface_ref => |ir| {
                    const ref = ir.ref;
                    const hit = self.resolver.findInterfaceWithPkg(ref) orelse return error.UnknownInterface;
                    try uses.append(self.ar, .{
                        .id = try ifaceId(self.ar, ref, doc_pkg),
                        .iface = hit.iface,
                        .is_export = ei.is_export,
                        .pkg = hit.pkg,
                    });
                },
                .named_interface => |ni| {
                    // Inline interface: advertised under the world-local plain
                    // name (matching metadata_encode / component new), so the
                    // extern module string is `ni.name`. Reuse the interface
                    // machinery by synthesizing a `Use` over its inline items.
                    try uses.append(self.ar, .{
                        .id = ni.name,
                        .iface = .{ .name = ni.name, .items = ni.items },
                        .is_export = ei.is_export,
                        .pkg = doc_pkg,
                    });
                },
                .named_func => |nf| {
                    try top_funcs.append(self.ar, .{ .name = nf.name, .func = nf.func, .is_export = ei.is_export });
                },
            }
        }
        for (uses.items) |u| {
            const gop = try self.iface_name_counts.getOrPut(
                self.ar,
                ifaceBaseName(u.id),
            );
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }

        // Index every named type so `.name` refs resolve, plus any types pulled
        // in from another interface via `use pkg:iface.{ … }` (resolved in the
        // package context of the interface that contains the `use`).
        const UsedType = struct { name: []const u8, kind: ast.TypeDefKind, iface_id: []const u8 };
        var used_types = std.ArrayListUnmanaged(UsedType).empty;
        // #303: detect names defined *locally* by more than one interface so we
        // can disambiguate their Zig identifiers. Keyed by name → first
        // defining interface; a second distinct definer marks a collision.
        var local_def_iface = std.StringHashMapUnmanaged([]const u8).empty;
        for (uses.items) |u| {
            for (u.iface.items) |it| switch (it) {
                .type => |td| {
                    try self.types.put(self.ar, td.name, td.kind);
                    try self.scoped.put(self.ar, self.scopeKey(u.id, td.name), .{ .kind = td.kind, .def_iface = u.id });
                    const gop = try local_def_iface.getOrPut(self.ar, td.name);
                    if (gop.found_existing) {
                        if (!std.mem.eql(u8, gop.value_ptr.*, u.id))
                            try self.colliding.put(self.ar, td.name, {});
                    } else gop.value_ptr.* = u.id;
                },
                .use => |use_item| {
                    const hit = self.resolver.findInterfaceWithPkgCtx(use_item.from, u.pkg) orelse continue;
                    const src_ref = ast.InterfaceRef{ .name = use_item.from.name, .package = hit.pkg };
                    const src_id = try ifaceId(self.ar, src_ref, doc_pkg);
                    for (use_item.names) |un| {
                        const local = un.rename orelse un.name;
                        for (hit.iface.items) |sit| switch (sit) {
                            .type => |td| if (std.mem.eql(u8, td.name, un.name)) {
                                // The consuming interface can reference `local`,
                                // bound to the source's structure + name.
                                try self.scoped.put(self.ar, self.scopeKey(u.id, local), .{ .kind = td.kind, .def_iface = src_id });
                                if (self.types.contains(local)) continue;
                                try self.types.put(self.ar, local, td.kind);
                                try used_types.append(self.ar, .{ .name = local, .kind = td.kind, .iface_id = src_id });
                            },
                            else => {},
                        };
                    }
                },
                else => {},
            };
        }

        // ── header ──
        self.print(
            \\//! Generated by `wabt component bindgen` from world `{s}`. Do not edit.
            \\
            \\const wit_types = @import("wit_types");
            \\
        , .{world_name});
        // A world that imports an async func drives the async-lowered call
        // through `wit_async.awaitCall`.
        for (uses.items) |u| {
            if (u.is_export) continue;
            for (u.iface.items) |it| switch (it) {
                .func => |fd| if (fd.func.is_async) {
                    self.needs_cm_async = true;
                },
                // An imported resource with an async method also drives the call
                // through `wit_async.awaitCall`.
                .type => |td| switch (td.kind) {
                    .resource => |methods| for (methods) |m| {
                        if (m.func.is_async) self.needs_cm_async = true;
                    },
                    else => {},
                },
                else => {},
            };
        }
        for (top_funcs.items) |tf| {
            if (!tf.is_export and tf.func.is_async) self.needs_cm_async = true;
        }
        if (self.needs_cm_async) self.raw("const wit_async = @import(\"wit_async\");\n");
        self.raw("\n");

        // Register complex (non-primitive-element) future/stream channels so
        // their nominal types are shared across import wrappers and the user
        // impl. Must run after `self.types` is fully indexed.
        try self.registerChannels(uses.items);

        // ── named types (use-imported first, then locally-defined) ──
        for (used_types.items) |ut| {
            self.current_iface = ut.iface_id;
            try self.emitTypeDef(ut.iface_id, .{ .name = ut.name, .kind = ut.kind });
        }
        for (uses.items) |u| {
            self.current_iface = u.id;
            for (u.iface.items) |it| switch (it) {
                .type => |td| {
                    // Exported resources (guest-implemented, resource-new/rep) are
                    // a later phase; imported resources are handled below.
                    if (td.kind == .resource and u.is_export) return error.UnsupportedWitType;
                    try self.emitTypeDef(u.id, td);
                },
                else => {},
            };
        }
        self.current_iface = "";

        // ── complex future/stream channel types (after their element types) ──
        for (self.chan_decls.items) |d| {
            self.print("const {s} = {s};\n", .{ d.name, d.rhs });
        }
        if (self.chan_decls.items.len != 0) self.raw("\n");

        var have_exports = false;
        for (uses.items) |u| {
            if (u.is_export) have_exports = true;
        }
        for (top_funcs.items) |tf| {
            if (tf.is_export) have_exports = true;
        }
        if (have_exports) {
            if (self.dispatch) |dispatch| {
                self.print("const __wit_dispatch = @import(\"{s}\");\n\n", .{dispatch});
            } else {
                self.print("const Impl = @import(\"{s}\");\n\n", .{self.impl});
            }
        }

        // ── imports ──
        for (uses.items) |u| {
            if (u.is_export) continue;
            try self.emitImportIface(u);
        }
        try self.emitTopLevelImports(top_funcs.items);
        // ── exports ──
        for (uses.items) |u| {
            if (!u.is_export) continue;
            try self.emitExportIface(u);
        }
        // ── top-level world funcs (`named_func`) ──
        for (top_funcs.items) |tf| {
            if (tf.is_export) try self.emitTopLevelExportFunc(tf.name, tf.func);
        }

        // ── JS-callable reverse bridge for imported interfaces and root funcs
        // (`--js-imports`) ──
        if (self.js_imports) {
            try self.emitJsImportBridge(uses.items, top_funcs.items);
        }
    }

    // ── type emission ────────────────────────────────────────────────

    fn emitTypeDef(self: *Gen, iface_id: []const u8, td: ast.TypeDef) GenError!void {
        switch (td.kind) {
            .record => |fields| {
                self.print("pub const {s} = struct {{\n", .{try self.typeName(td.name)});
                for (fields) |f| {
                    self.print("    {s}: {s},\n", .{ try snake(self.ar, f.name), try self.zigType(f.type) });
                }
                self.raw("};\n\n");
            },
            .@"enum" => |cases| {
                self.print("pub const {s} = enum {{\n", .{try self.typeName(td.name)});
                for (cases) |c| self.print("    {s},\n", .{try snake(self.ar, c)});
                self.raw("};\n\n");
            },
            .variant => |cases| {
                self.print("pub const {s} = union(enum) {{\n", .{try self.typeName(td.name)});
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
                // labels). >32 labels (multi-i32 canonical-ABI representation)
                // is full multiword `flags` support -- a broader phase than
                // this generator implements today (see `nativeBridgeSupported`'s
                // doc comment, which this constraint must stay consistent
                // with). Reject deterministically, by name, here -- the single
                // place every `flags` typedef in the world passes through
                // (used-type indexing and each interface's own `.type` items,
                // *before* any import/export/JS-bridge emission in `generate`)
                // -- rather than a bare `error.UnsupportedWitType` that names
                // neither the offending type nor the actual constraint.
                if (labels.len > 32) {
                    return self.fail(
                        "flags type '{s}' (interface '{s}') has {d} labels, but this generator's " ++
                            "`flags` representation only supports up to 32 labels (a single packed " ++
                            "integer per the canonical ABI's ≤32-label case); >32 labels needs a " ++
                            "multi-i32 bitset, which is a separate, broader multiword-`flags` phase, " ++
                            "not implemented here -- split '{s}' into ≤32-label `flags` groups, or drop " ++
                            "the interface that declares it from this world",
                        .{ td.name, iface_id, labels.len, td.name },
                    );
                }
                const bits: usize = if (labels.len <= 8) 8 else if (labels.len <= 16) 16 else 32;
                self.print("pub const {s} = packed struct(u{d}) {{\n", .{ try self.typeName(td.name), bits });
                for (labels) |l| self.print("    {s}: bool = false,\n", .{try snake(self.ar, l)});
                if (bits > labels.len) self.print("    _padding: u{d} = 0,\n", .{bits - labels.len});
                self.raw("};\n\n");
            },
            .alias => |t| {
                self.print("pub const {s} = {s};\n\n", .{ try self.typeName(td.name), try self.zigType(t) });
            },
            .resource => try self.emitResource(iface_id, td),
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
            // `char` and `list<u8>` are only disambiguated from a bare
            // `u32`/`string` in `--dispatch` (generic export dispatch) mode:
            // that is the sole consumer needing to tell them apart at
            // runtime (see `wit_types.Char`/`wit_types.ByteList`'s doc
            // comments). `--impl` mode (every other WIT world this generator
            // serves: `wasi:*` bindings, hand-written guest code) keeps the
            // exact same `u32`/`[]const u8` spelling it always has, so this
            // is a zero-ripple, dispatch-mode-local change.
            .char => if (self.dispatch != null) "wit_types.Char" else "u32",
            .string => "[]const u8",
            .list => |e| blk: {
                if (self.dispatch != null and e.* == .u8) break :blk "wit_types.ByteList";
                break :blk try std.fmt.allocPrint(self.ar, "[]const {s}", .{try self.zigType(e.*)});
            },
            .option => |e| try std.fmt.allocPrint(self.ar, "?{s}", .{try self.zigType(e.*)}),
            .result => |r| blk: {
                const ok = if (r.ok) |t| try self.zigType(t.*) else "void";
                const err = if (r.err) |t| try self.zigType(t.*) else "void";
                break :blk try std.fmt.allocPrint(self.ar, "wit_types.Result({s}, {s})", .{ ok, err });
            },
            .tuple => |elems| blk: {
                var b = std.ArrayListUnmanaged(u8).empty;
                try b.appendSlice(self.ar, "wit_types.Tuple(.{ ");
                for (elems, 0..) |e, i| {
                    if (i != 0) try b.appendSlice(self.ar, ", ");
                    try b.appendSlice(self.ar, try self.zigType(e));
                }
                try b.appendSlice(self.ar, " })");
                break :blk b.items;
            },
            .future => |e| if (try self.chanName(true, if (e) |p| p.* else null)) |nm|
                nm
            else
                try std.fmt.allocPrint(self.ar, "wit_types.Future({s})", .{if (e) |t| try self.zigType(t.*) else "void"}),
            .stream => |e| if (try self.chanName(false, if (e) |p| p.* else null)) |nm|
                nm
            else
                try std.fmt.allocPrint(self.ar, "wit_types.Stream({s})", .{if (e) |t| try self.zigType(t.*) else "void"}),
            .error_context => "wit_types.ErrorContextHandle",
            .own, .borrow => |r| try self.typeName(r), // resource handle wrapper
            .name => |n| try self.typeName(n),
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
            .tuple => |elems| blk: {
                var c: usize = 0;
                for (elems) |e| c += try self.flatCount(e);
                break :blk c;
            },
            .future, .stream, .error_context => 1, // an i32 handle
            .name => |n| blk: {
                const kind = self.typeKind(n) orelse return error.UnknownType;
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
                    .resource => 1, // an i32 handle
                    .alias => |t| try self.flatCount(t),
                };
            },
            .own, .borrow => 1, // resource handle (i32)
            else => 1, // scalars (bool/int/float/char/enum)
        };
    }

    fn resultZig(self: *Gen, func: ast.Func) GenError![]const u8 {
        return if (func.result) |t| try self.zigType(t) else "void";
    }

    // ── exports ──────────────────────────────────────────────────────

    fn emitExportIface(self: *Gen, u: Use) GenError!void {
        self.current_iface = u.id;
        self.print("// exports: {s}\n", .{u.id});
        for (u.iface.items) |it| switch (it) {
            .func => |fd| try self.emitExportFunc(u.id, fd.name, fd.func),
            else => {},
        };
        self.raw("\n");
    }

    fn emitExportFunc(self: *Gen, iface_id: []const u8, name: []const u8, func: ast.Func) GenError!void {
        if (func.is_async) return self.emitAsyncExportFunc(iface_id, name, func);
        const export_sym = try std.fmt.allocPrint(self.ar, "{s}#{s}", .{ iface_id, name });
        try self.emitSyncExportFuncSym(export_sym, name, func);
    }

    /// Emit a module-scope export shell for a top-level world func
    /// (`named_func`). The core export name is the plain func name (no
    /// `<iface>#` prefix), matching what `component new` lifts.
    fn emitTopLevelExportFunc(self: *Gen, name: []const u8, func: ast.Func) GenError!void {
        // Async top-level func exports are handled by `component new` during lifting,
        // not by bindgen. Skip silently so bindgen can generate imports for worlds
        // that also export async functions.
        if (func.is_async) return;
        try self.emitSyncExportFuncSym(name, name, func);
    }

    /// Shared body for a synchronous export shell. `export_sym` is the
    /// exact wasm core export name (`<iface>#<func>` for an interface
    /// func, or the plain func name for a top-level world func); `name`
    /// drives the `Impl.<fn>` call or is passed to `__wit_dispatch.call`.
    fn emitSyncExportFuncSym(self: *Gen, export_sym: []const u8, name: []const u8, func: ast.Func) GenError!void {
        const result_zig = try self.resultZig(func);

        self.print("export fn @\"{s}\"(", .{export_sym});
        try self.emitFlatParamDecls(func.params);
        self.print(") wit_types.CoreReturn({s}) {{\n", .{result_zig});
        self.raw("    wit_types.resetScratch();\n");

        try self.emitLiftParams(func.params);

        // Call the user implementation or generic dispatcher, then encode the result.
        const args = try self.implArgList(func.params);
        if (self.dispatch != null) {
            const dispatch_args = if (args.len == 0)
                ".{}"
            else
                try std.fmt.allocPrint(self.ar, ".{{ {s} }}", .{args});
            if (func.result == null) {
                self.print(
                    "    __wit_dispatch.call(\"{s}\", void, {s});\n",
                    .{ export_sym, dispatch_args },
                );
                self.raw("    return;\n");
            } else {
                self.print(
                    "    return wit_types.returnResult({s}, __wit_dispatch.call(\"{s}\", {s}, {s}), &wit_types.alloc);\n",
                    .{ result_zig, export_sym, result_zig, dispatch_args },
                );
            }
        } else if (func.result == null) {
            self.print("    Impl.{s}({s});\n", .{ try camel(self.ar, name), args });
            self.raw("    return;\n");
        } else {
            self.print(
                "    return wit_types.returnResult({s}, Impl.{s}({s}), &wit_types.alloc);\n",
                .{ result_zig, try camel(self.ar, name), args },
            );
        }
        self.raw("}\n\n");
    }

    /// Emit the `const __params = canon.liftParams(struct { … }, .{ … });` block
    /// that decodes an export's flattened core params (named `__params` so it
    /// can't shadow a parameter named `a`/`p`/etc.). No-op when there are none.
    fn emitLiftParams(self: *Gen, params: []const ast.Param) GenError!void {
        if (params.len == 0) return;
        self.raw("    const __params = wit_types.liftParams(struct {\n");
        for (params) |p| {
            self.print("        {s}: {s},\n", .{ try snake(self.ar, p.name), try self.zigType(p.type) });
        }
        self.raw("    }, .{ ");
        try self.emitFlatSlotNames(params);
        self.raw(" });\n");
    }

    /// Emit an async-lifted export: async exports are handled by `component new`
    /// during lifting/composition, not by bindgen. Skip silently so bindgen can
    /// generate imports for worlds that also export async functions (async exports
    /// will be added by the lifting phase).
    fn emitAsyncExportFunc(self: *Gen, iface_id: []const u8, name: []const u8, func: ast.Func) GenError!void {
        _ = self;
        _ = iface_id;
        _ = name;
        _ = func;
        // Async exports are handled by `component new`, not bindgen.
        return;
    }

    fn isManualReturn(self: *Gen, name: []const u8) bool {
        for (self.manual_returns) |m| if (std.mem.eql(u8, m, name)) return true;
        return false;
    }

    /// Emit the container-scope `const <tname> = struct { extern "[task-return]…" … };`
    /// helper. The intrinsic takes the result's flat slots, or one i32 pointer
    /// when the result spills past 16 slots.
    fn emitTaskReturnExternDecl(self: *Gen, tname: []const u8, iface_id: []const u8, name: []const u8, func: ast.Func, spilled: bool) GenError!void {
        self.print("const {s} = struct {{\n", .{tname});
        self.print("    extern \"[task-return]{s}#{s}\" fn @\"task-return\"(", .{ iface_id, name });
        if (spilled) {
            self.raw("d0: i32"); // pointer to the lowered result in memory
        } else if (func.result) |t| {
            for ((try self.flatCores(t)), 0..) |c, i| {
                if (i != 0) self.raw(", ");
                self.print("d{d}: {s}", .{ i, @tagName(c) });
            }
        }
        self.raw(") void;\n};\n\n");
    }

    /// Emit the `task.return` delivery (4-space indented) for the result value
    /// expression `rexpr` (ignored when the func has no result).
    fn emitTaskReturnDeliver(self: *Gen, tname: []const u8, func: ast.Func, spilled: bool, rexpr: []const u8) GenError!void {
        const t = func.result orelse {
            self.print("    {s}.@\"task-return\"();\n", .{tname});
            return;
        };
        const rz = try self.zigType(t);
        const rcount = try self.flatCount(t);
        if (spilled) {
            // Lower the result into a fresh scratch buffer (canonical layout) and
            // hand task.return the pointer.
            self.print("    const __ret = wit_types.alloc(wit_types.sizeOf({s}), wit_types.alignOf({s}));\n", .{ rz, rz });
            self.print("    wit_types.lower({s}, {s}, __ret, &wit_types.alloc);\n", .{ rz, rexpr });
            self.print("    {s}.@\"task-return\"(@intCast(@intFromPtr(__ret)));\n", .{tname});
        } else if (rcount == 1) {
            self.print("    {s}.@\"task-return\"(wit_types.returnResult({s}, {s}, &wit_types.alloc));\n", .{ tname, rz, rexpr });
        } else {
            self.print("    const __r = wit_types.lowerFlat({s}, {s}, &wit_types.alloc);\n", .{ rz, rexpr });
            self.print("    {s}.@\"task-return\"(", .{tname});
            for (0..rcount) |i| {
                if (i != 0) self.raw(", ");
                self.print("__r[{d}]", .{i});
            }
            self.raw(");\n");
        }
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
        self.current_iface = u.id;
        const mod = try self.interfaceModuleName(u.id);
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

    /// Emit world-level function imports. The canonical ABI reserves the core
    /// module `$root` for these functions; the field is the verbatim WIT
    /// function name. Typed wrappers stay at module scope, matching the WIT
    /// world's own scope, while their externs are isolated to avoid a name
    /// collision for single-word functions.
    fn emitTopLevelImports(self: *Gen, top_funcs: []const TopFunc) GenError!void {
        var count: usize = 0;
        for (top_funcs) |tf| {
            if (!tf.is_export) count += 1;
        }
        if (count == 0) return;

        self.current_iface = "$root";
        self.raw("const __root_imports = struct {\n");
        for (top_funcs) |tf| {
            if (!tf.is_export) try self.emitImportExtern("$root", tf.name, tf.func);
        }
        self.raw("};\n\n");
        for (top_funcs) |tf| {
            if (!tf.is_export) try self.emitImportWrapperWith(tf.name, tf.func, "", "__root_imports");
        }
        self.raw("\n");
        self.current_iface = "";
    }

    /// Emit the flattened `extern` import declaration (inside the `imp`
    /// namespace) for one imported function.
    fn emitImportExtern(self: *Gen, iface_id: []const u8, name: []const u8, func: ast.Func) GenError!void {
        if (func.is_async) return self.emitAsyncImportExtern(iface_id, name, func);
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

    /// Sum of the flattened core slots of a func's params.
    fn paramFlatCount(self: *Gen, params: []const ast.Param) GenError!usize {
        var c: usize = 0;
        for (params) |p| c += try self.flatCount(p.type);
        return c;
    }

    /// Emit the spilled-params lowering for an async call whose flattened params
    /// (including `self` for a method) exceed `MAX_FLAT_ASYNC_PARAMS` (4). The
    /// whole param tuple is lowered into a fresh scratch buffer in canonical
    /// layout and the call takes a single pointer to it. `self_field` is the
    /// `self` expression to prepend for a method (null for a free func/static).
    /// Returns the pointer argument expression for the call.
    fn emitAsyncSpill(self: *Gen, params: []const ast.Param, self_field: ?[]const u8) GenError![]const u8 {
        self.raw("        const __pargs = .{ ");
        var first = true;
        if (self_field) |sf| {
            self.raw(sf);
            first = false;
        }
        for (params) |p| {
            if (!first) self.raw(", ");
            first = false;
            self.raw(try snake(self.ar, p.name));
        }
        self.raw(" };\n");
        self.raw("        const __pp = wit_types.alloc(wit_types.sizeOf(@TypeOf(__pargs)), wit_types.alignOf(@TypeOf(__pargs)));\n");
        self.raw("        wit_types.lower(@TypeOf(__pargs), __pargs, __pp, &wit_types.alloc);\n");
        return "@intCast(@intFromPtr(__pp))";
    }

    /// Emit the `extern` decl for an imported **async** func. The canonical
    /// async lowering produces `(flat params, result_ptr if any) -> i32 status`
    /// (the packed callstatus); results are written to `result_ptr`. Params that
    /// exceed `MAX_FLAT_ASYNC_PARAMS` (4) spill to a single pointer.
    fn emitAsyncImportExtern(self: *Gen, iface_id: []const u8, name: []const u8, func: ast.Func) GenError!void {
        const spill = try self.paramFlatCount(func.params) > 4;
        self.print("        extern \"{s}\" fn @\"{s}\"(", .{ iface_id, name });
        if (spill) {
            self.raw("args_ptr: i32");
            if (func.result != null) self.raw(", result_ptr: i32");
        } else {
            try self.emitFlatParamDecls(func.params);
            if (func.result != null) {
                if (func.params.len > 0) self.raw(", ");
                self.raw("result_ptr: i32");
            }
        }
        self.raw(") i32;\n"); // packed callstatus
    }

    /// Emit the typed wrapper that lowers params, calls the `imp.@"…"` extern,
    /// and lifts the result.
    fn emitImportWrapper(self: *Gen, name: []const u8, func: ast.Func) GenError!void {
        return self.emitImportWrapperWith(name, func, "    ", "imp");
    }

    fn emitImportWrapperWith(
        self: *Gen,
        name: []const u8,
        func: ast.Func,
        decl_indent: []const u8,
        imp: []const u8,
    ) GenError!void {
        if (func.is_async) return self.emitAsyncImportWrapperWith(name, func, decl_indent, imp);
        const result_zig = try self.resultZig(func);
        const rcount: usize = if (func.result) |t| try self.flatCount(t) else 0;
        const indirect = rcount > 1;

        self.print("{s}pub fn {s}(", .{ decl_indent, try camel(self.ar, name) });
        try self.emitTypedParamDecls(func.params);
        self.print(") {s} {{\n", .{result_zig});

        // lower params → arg expressions (emitting temps as needed)
        const call_args = try self.lowerParams(func.params);

        if (indirect) {
            if (call_args.len > 0) {
                self.print("        {s}.@\"{s}\"({s}, wit_types.retPtr());\n", .{ imp, name, call_args });
            } else {
                self.print("        {s}.@\"{s}\"(wit_types.retPtr());\n", .{ imp, name });
            }
            self.print("        return wit_types.lift({s}, wit_types.retArea());\n", .{result_zig});
        } else if (func.result == null) {
            self.print("        {s}.@\"{s}\"({s});\n", .{ imp, name, call_args });
        } else {
            self.print(
                "        return wit_types.liftResultFlat({s}, {s}.@\"{s}\"({s}));\n",
                .{ result_zig, imp, name, call_args },
            );
        }
        self.raw("    }\n");
    }

    /// Emit the typed wrapper for an imported **async** func: lower params, call
    /// the async-lowered extern (returns the packed callstatus), drive it to
    /// completion via `wit_async.awaitCall`, then lift the result the host wrote
    /// to the result pointer. Always lifts from memory (async lowering writes
    /// results indirectly, even for a single-slot result).
    fn emitAsyncImportWrapper(self: *Gen, name: []const u8, func: ast.Func) GenError!void {
        return self.emitAsyncImportWrapperWith(name, func, "    ", "imp");
    }

    fn emitAsyncImportWrapperWith(
        self: *Gen,
        name: []const u8,
        func: ast.Func,
        decl_indent: []const u8,
        imp: []const u8,
    ) GenError!void {
        const spill = try self.paramFlatCount(func.params) > 4;
        const result_zig = try self.resultZig(func);

        self.print("{s}pub fn {s}(", .{ decl_indent, try camel(self.ar, name) });
        try self.emitTypedParamDecls(func.params);
        self.print(") {s} {{\n", .{result_zig});

        const call_args = if (spill)
            try self.emitAsyncSpill(func.params, null)
        else
            try self.lowerParams(func.params);
        if (func.result != null) {
            if (call_args.len > 0) {
                self.print("        const __status = {s}.@\"{s}\"({s}, wit_types.retPtr());\n", .{ imp, name, call_args });
            } else {
                self.print("        const __status = {s}.@\"{s}\"(wit_types.retPtr());\n", .{ imp, name });
            }
            self.raw("        wit_async.awaitCall(__status);\n");
            self.print("        return wit_types.lift({s}, wit_types.retArea());\n", .{result_zig});
        } else {
            self.print("        const __status = {s}.@\"{s}\"({s});\n", .{ imp, name, call_args });
            self.raw("        wit_async.awaitCall(__status);\n");
        }
        self.raw("    }\n");
    }

    // ── JS-callable reverse bridge for imports (`--js-imports`) ──
    //
    // For every *synchronous* imported interface or root function whose
    // signature is entirely within the native dispatch bridge's supported
    // type set (see `nativeBridgeSupported`), emits one `if` arm inside a single
    // `starling_js_import_dispatch` trampoline that: decodes each argument
    // from the generic `js_dispatch.NativeValue` tree the host runtime built
    // out of the calling JS value (reusing `js_dispatch.decodeNative` -- the
    // exact function the export shells' native bridge already uses to decode
    // a JS *result* onto a concrete Zig type; here it decodes JS *arguments*
    // onto the concrete WIT param types instead, per the encode/decode
    // reversal noted in `runtime/js_dispatch.h`), calls the already-emitted
    // typed import wrapper (`<mod>.<fn>(...)`, from `emitImportIface` above),
    // and encodes the result back with `js_dispatch.encodeNative` -- the same
    // function the export shells' native bridge uses to encode a JS
    // *argument*, here encoding the host's *result* instead. Also emits a
    // `starling_js_imports_manifest` byte string (one TSV line per bridged
    // function: `<js-module>\t<js-export-name>\t<dispatch-key>\t<arity>\n`) so
    // the host runtime can discover which builtin ES modules/exports to
    // synthesize without per-world C++ glue. Interface functions retain their
    // `<iface-id>` module and verbatim function export. A root function `foo`
    // uses module `foo`, export `default`, and dispatch key `$root#foo`,
    // matching ComponentizeJS 0.21 while remaining unambiguous.
    //
    // A function whose signature includes a type the native bridge doesn't
    // cover (resource, future/stream, error-context) is a deterministic
    // `error.UnsupportedWitType` generation failure (via `fail`, naming the
    // offending function/type) rather than a silently-missing JS export --
    // see `nativeBridgeSupported`. An *async* imported function is likewise
    // rejected for now (`wit_async.awaitCall` has no equivalent on this
    // synchronous JS-call path); it is a distinct, separately diagnosed
    // follow-up, not silently skipped either.

    /// Whether `ty`'s type graph is entirely within the set `js_dispatch`'s
    /// `NativeValue` encode/decode pair supports: `bool`/integers/`f32`/`f64`,
    /// `char`, `string`, `option<T>`, `list<T>` (including `list<u8>`,
    /// bridged as `wit_types.ByteList`), `tuple`, `record`, `variant`,
    /// `enum`, `flags` with ≤32 labels, and `result<T,E>` (recursively, for
    /// any of those). Everything else -- resource handles (`own`/`borrow`),
    /// `future`/`stream`, `error-context`, and a `flags` type with >32
    /// labels (multiword `flags`, which `emitTypeDef` itself doesn't
    /// generate -- see its doc comment) -- is unsupported (matches the
    /// Zig-type cases `encodeNative`/`decodeNative` actually implement in
    /// `js_dispatch.zig`; keep this in sync with that switch if it ever
    /// grows).
    fn nativeBridgeSupported(self: *Gen, ty: ast.Type) GenError!bool {
        return switch (ty) {
            .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64, .string, .char => true,
            .list => |e| try self.nativeBridgeSupported(e.*),
            .option => |e| try self.nativeBridgeSupported(e.*),
            .tuple => |elems| r: {
                for (elems) |e| {
                    if (!try self.nativeBridgeSupported(e)) break :r false;
                }
                break :r true;
            },
            .result => |r| blk: {
                if (r.ok) |t| {
                    if (!try self.nativeBridgeSupported(t.*)) break :blk false;
                }
                if (r.err) |t| {
                    if (!try self.nativeBridgeSupported(t.*)) break :blk false;
                }
                break :blk true;
            },
            .name => |n| blk: {
                const kind = self.typeKind(n) orelse return error.UnknownType;
                break :blk switch (kind) {
                    .record => |fields| r: {
                        for (fields) |f| {
                            if (!try self.nativeBridgeSupported(f.type)) break :r false;
                        }
                        break :r true;
                    },
                    .alias => |t| try self.nativeBridgeSupported(t),
                    .variant => |cases| r: {
                        for (cases) |c| {
                            if (c.type) |t| {
                                if (!try self.nativeBridgeSupported(t)) break :r false;
                            }
                        }
                        break :r true;
                    },
                    // `enum`/`flags` carry no payload types to recurse into
                    // -- both encode/decode to a plain JS string / a plain
                    // JS object of camelCased booleans respectively (see
                    // js_dispatch.zig's `encodeNative`/`decodeNative`). A
                    // `flags` type with >32 labels, though, is rejected by
                    // `emitTypeDef` (only ≤32-label `flags` -- a single
                    // packed integer -- is implemented; see its doc
                    // comment) -- this gate must say so too, or it falsely
                    // advertises >32-label `flags` as bridgeable when
                    // generation is actually guaranteed to fail on it.
                    .@"enum" => true,
                    .flags => |labels| labels.len <= 32,
                    // resource: not representable by the native bridge's
                    // tag vocabulary (see js_dispatch.h) -- no
                    // handle-lifetime story on this synchronous JS-call path.
                    .resource => false,
                };
            },
            // future/stream/error-context, own/borrow resource handles: none
            // of these have an `encodeNative`/`decodeNative` case in
            // js_dispatch.zig today.
            else => false,
        };
    }

    const JsImportEntry = struct {
        module: []const u8,
        js_name: []const u8,
        dispatch_key: []const u8,
        call_target: []const u8,
        param_ziq: []const []const u8,
        result_zig: []const u8,
        has_result: bool,
    };

    fn emitJsImportBridge(self: *Gen, uses: []const Use, top_funcs: []const TopFunc) GenError!void {
        var entries = std.ArrayListUnmanaged(JsImportEntry).empty;
        for (uses) |u| {
            if (u.is_export) continue;
            self.current_iface = u.id;
            // An imported interface that defines *any* resource (regardless
            // of whether it has methods) cannot be bridged to JavaScript as
            // a whole: `--js-imports` has no handle-lifetime story for
            // resources yet (see `nativeBridgeSupported`'s doc comment).
            // Reject the *entire interface* here, deterministically, before
            // considering any of its functions -- otherwise a mixed
            // interface (a resource type alongside free-standing functions
            // that never reference it) would silently bridge the free
            // functions while the resource's own methods are dropped with
            // no diagnostic at all, since the loop below only ever switches
            // on `.func` items and treats `.type` as `else => {}`. Checking
            // this first, in its own pass over `u.iface.items`, guarantees
            // the rejection fires regardless of item order or whether any
            // bridged function actually touches the resource.
            for (u.iface.items) |it| {
                if (it == .type and it.type.kind == .resource) {
                    return self.fail(
                        "imported interface '{s}' defines resource '{s}' and cannot be bridged to " ++
                            "JavaScript as a whole (--js-imports has no handle-lifetime story for " ++
                            "resources yet); this applies even when the interface also has free-standing " ++
                            "bridgeable functions that never reference the resource -- move the resource to " ++
                            "its own interface (so the free functions' interface has none), or drop " ++
                            "--js-imports for this world",
                        .{ u.id, it.type.name },
                    );
                }
            }
            for (u.iface.items) |it| switch (it) {
                .func => |fd| {
                    if (fd.func.is_async) {
                        return self.fail(
                            "imported async function '{s}#{s}' cannot be bridged to JavaScript yet " ++
                                "(--js-imports only supports synchronous imports so far); remove it from " ++
                                "the world's JS-facing import surface or drop --js-imports for this world",
                            .{ u.id, fd.name },
                        );
                    }
                    for (fd.func.params) |p| {
                        if (!try self.nativeBridgeSupported(p.type)) {
                            return self.fail(
                                "imported function '{s}#{s}': parameter '{s}' has a WIT type not " ++
                                    "supported by the JS import bridge (bool/integers/f32/f64/char/" ++
                                    "string/option<T>/list<T>/tuple/record/variant/enum/flags " ++
                                    "(≤32 labels)/result<T,E> only -- resource, future/stream, " ++
                                    "error-context, and >32-label (multiword) flags need a further WABT " ++
                                    "phase)",
                                .{ u.id, fd.name, p.name },
                            );
                        }
                    }
                    if (fd.func.result) |r| {
                        if (!try self.nativeBridgeSupported(r)) {
                            return self.fail(
                                "imported function '{s}#{s}': its result type is not supported by the " ++
                                    "JS import bridge (bool/integers/f32/f64/char/string/option<T>/" ++
                                    "list<T>/tuple/record/variant/enum/flags (≤32 labels)/" ++
                                    "result<T,E> only -- resource, future/stream, error-context, and " ++
                                    ">32-label (multiword) flags need a further WABT phase)",
                                .{ u.id, fd.name },
                            );
                        }
                    }
                    var param_ziq = std.ArrayListUnmanaged([]const u8).empty;
                    for (fd.func.params) |p| {
                        param_ziq.append(self.ar, try self.zigType(p.type)) catch @panic("OOM");
                    }
                    entries.append(self.ar, .{
                        .module = u.id,
                        .js_name = fd.name,
                        .dispatch_key = try std.fmt.allocPrint(self.ar, "{s}#{s}", .{ u.id, fd.name }),
                        .call_target = try std.fmt.allocPrint(
                            self.ar,
                            "{s}.{s}",
                            .{ try self.interfaceModuleName(u.id), try camel(self.ar, fd.name) },
                        ),
                        .param_ziq = param_ziq.items,
                        .result_zig = try self.resultZig(fd.func),
                        .has_result = fd.func.result != null,
                    }) catch @panic("OOM");
                },
                else => {},
            };
        }
        self.current_iface = "$root";
        for (top_funcs) |tf| {
            if (tf.is_export) continue;
            if (tf.func.is_async) {
                return self.fail(
                    "imported async root function '{s}' cannot be bridged to JavaScript yet " ++
                        "(--js-imports only supports synchronous imports so far); remove it from " ++
                        "the world's JS-facing import surface or drop --js-imports for this world",
                    .{tf.name},
                );
            }
            for (tf.func.params) |p| {
                if (!try self.nativeBridgeSupported(p.type)) {
                    return self.fail(
                        "imported root function '{s}': parameter '{s}' has a WIT type not " ++
                            "supported by the JS import bridge (bool/integers/f32/f64/char/" ++
                            "string/option<T>/list<T>/tuple/record/variant/enum/flags " ++
                            "(≤32 labels)/result<T,E> only -- resource, future/stream, " ++
                            "error-context, and >32-label (multiword) flags need a further WABT phase)",
                        .{ tf.name, p.name },
                    );
                }
            }
            if (tf.func.result) |r| {
                if (!try self.nativeBridgeSupported(r)) {
                    return self.fail(
                        "imported root function '{s}': its result type is not supported by the " ++
                            "JS import bridge (bool/integers/f32/f64/char/string/option<T>/" ++
                            "list<T>/tuple/record/variant/enum/flags (≤32 labels)/" ++
                            "result<T,E> only -- resource, future/stream, error-context, and " ++
                            ">32-label (multiword) flags need a further WABT phase)",
                        .{tf.name},
                    );
                }
            }
            var param_ziq = std.ArrayListUnmanaged([]const u8).empty;
            for (tf.func.params) |p| {
                param_ziq.append(self.ar, try self.zigType(p.type)) catch @panic("OOM");
            }
            entries.append(self.ar, .{
                .module = tf.name,
                .js_name = "default",
                .dispatch_key = try std.fmt.allocPrint(self.ar, "$root#{s}", .{tf.name}),
                .call_target = try camel(self.ar, tf.name),
                .param_ziq = param_ziq.items,
                .result_zig = try self.resultZig(tf.func),
                .has_result = tf.func.result != null,
            }) catch @panic("OOM");
        }
        self.current_iface = "";
        // A world with no imported interfaces or root functions (or a world
        // importing only async funcs / resources, rejected above) has nothing to bridge --
        // emit nothing rather than a manifest-of-nothing plus a dispatch
        // function that can only ever return "not found". This keeps
        // `--js-imports` a no-op (not just "harmless") for components with
        // no custom imports, matching default export-only behavior exactly.
        if (entries.items.len == 0) return;

        // Reuses whatever module name `--dispatch` named (validated non-null
        // by `run()` whenever `--js-imports` is set); binding it again here
        // under the fixed local name `js_dispatch` is harmless even when the
        // header above already imported the same module as `__wit_dispatch`
        // (e.g. because the world also has exports) -- Zig allows importing
        // one module under multiple local names in the same file.
        self.print("const js_dispatch = @import(\"{s}\");\n", .{self.dispatch.?});
        // `std.mem.eql`/`std.heap.*` below need this; nothing before this
        // point in a `--js-imports`-only (no plain `--dispatch` exports)
        // generated file otherwise references `std`.
        self.raw("const std = @import(\"std\");\n\n");

        self.raw(
            \\// Generated for `--js-imports`: one TSV line per JS-bridged import,
            \\// "<js-module>\t<js-export-name>\t<dispatch-key>\t<arity>\n". Consumed by
            \\// the host runtime (see runtime/js_dispatch.h) to synthesize one builtin
            \\// ES module per <js-module>, each exposing <js-export-name> as a native
            \\// function that forwards to starling_js_import_dispatch(<dispatch-key>, …).
            \\// Interface imports use module=<iface-id>, export=<WIT func>; root imports
            \\// use module=<WIT func>, export=default, dispatch-key=$root#<WIT func>.
            \\pub const js_import_manifest: []const u8 =
            \\
        );
        for (entries.items) |e| {
            self.print(
                "    \"{s}\\t{s}\\t{s}\\t{d}\\n\" ++\n",
                .{ e.module, e.js_name, e.dispatch_key, e.param_ziq.len },
            );
        }
        self.raw("    \"\";\n\n");

        self.raw(
            \\pub export fn starling_js_imports_manifest(out_len: *usize) callconv(.c) [*]const u8 {
            \\    out_len.* = js_import_manifest.len;
            \\    return js_import_manifest.ptr;
            \\}
            \\
            \\
        );

        self.raw(
            \\pub export fn starling_js_import_dispatch(
            \\    name_ptr: [*]const u8,
            \\    name_len: usize,
            \\    argv_ptr: [*]const js_dispatch.NativeValue,
            \\    argv_len: usize,
            \\    out_result: *js_dispatch.NativeValue,
            \\    out_arena: *?*anyopaque,
            \\) callconv(.c) u32 {
            \\    const name = name_ptr[0..name_len];
            \\
        );
        for (entries.items) |e| {
            self.print("    if (std.mem.eql(u8, name, \"{s}\")) {{\n", .{e.dispatch_key});
            self.print(
                "        if (argv_len != {d}) @panic(\"js import dispatch: wrong argument count for {s}\");\n",
                .{ e.param_ziq.len, e.dispatch_key },
            );
            self.raw("        const __arena = std.heap.wasm_allocator.create(std.heap.ArenaAllocator) catch @panic(\"OOM\");\n");
            self.raw("        __arena.* = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);\n");
            self.raw("        const __alloc = __arena.allocator();\n");
            var call_args: std.ArrayListUnmanaged(u8) = .empty;
            for (e.param_ziq, 0..) |pty, idx| {
                if (idx != 0) call_args.appendSlice(self.ar, ", ") catch @panic("OOM");
                self.print("        const a{d} = js_dispatch.decodeNative({s}, &argv_ptr[{d}], __alloc);\n", .{ idx, pty, idx });
                const arg_name = std.fmt.allocPrint(self.ar, "a{d}", .{idx}) catch @panic("OOM");
                call_args.appendSlice(self.ar, arg_name) catch @panic("OOM");
            }
            if (e.has_result) {
                self.print("        const __result = {s}({s});\n", .{ e.call_target, call_args.items });
                self.print("        out_result.* = js_dispatch.encodeNative({s}, __result, __alloc);\n", .{e.result_zig});
            } else {
                self.print("        {s}({s});\n", .{ e.call_target, call_args.items });
                // A WIT import with no result must surface to JavaScript as
                // `undefined` -- never a coerced-looking `false`/`null` --
                // matching ComponentizeJS's observable behavior for a void
                // host call. Goes through `encodeNative`'s own `void` arm
                // (tag `.undefined_`) rather than hand-rolling a literal
                // `NativeValue` here, so the *one* place that knows the
                // shared ABI tag vocabulary is js_dispatch.zig, not this
                // generator (see js_dispatch.h's `StarlingJsTag`).
                self.raw("        out_result.* = js_dispatch.encodeNative(void, {}, __alloc);\n");
            }
            self.raw("        out_arena.* = __arena;\n");
            self.raw("        return 0;\n");
            self.raw("    }\n");
        }
        self.raw("    return 1;\n");
        self.raw("}\n\n");

        self.raw(
            \\pub export fn starling_js_import_result_free(arena: ?*anyopaque) callconv(.c) void {
            \\    js_dispatch.freeNativeArena(arena);
            \\}
            \\
            \\
        );
    }

    // ── resources (imported) ─────────────────────────────────────────

    /// The canonical extern name for a resource method/static/constructor.
    fn resourceExternName(self: *Gen, rname: []const u8, m: ast.ResourceMethod) GenError![]const u8 {
        return switch (m.kind) {
            .constructor => try std.fmt.allocPrint(self.ar, "[constructor]{s}", .{rname}),
            .method => try std.fmt.allocPrint(self.ar, "[method]{s}.{s}", .{ rname, m.name }),
            .static => try std.fmt.allocPrint(self.ar, "[static]{s}.{s}", .{ rname, m.name }),
        };
    }

    /// Emit an imported resource as a handle-wrapper struct: an `i32` handle, a
    /// private `imp` namespace of the canonical resource externs, typed
    /// method/static/constructor wrappers, and a `deinit` that drops the handle.
    fn emitResource(self: *Gen, iface_id: []const u8, td: ast.TypeDef) GenError!void {
        const methods = td.kind.resource;
        const R = try self.typeName(td.name);

        self.print("pub const {s} = struct {{\n", .{R});
        self.raw("    handle: i32,\n\n");

        self.raw("    const imp = struct {\n");
        for (methods) |m| try self.emitResourceExtern(iface_id, td.name, m);
        self.print("        extern \"{s}\" fn @\"[resource-drop]{s}\"(self: i32) void;\n", .{ iface_id, td.name });
        self.raw("    };\n\n");

        for (methods) |m| try self.emitResourceWrapper(R, td.name, m);

        self.print("    pub fn deinit(self: {s}) void {{\n", .{R});
        self.print("        imp.@\"[resource-drop]{s}\"(self.handle);\n", .{td.name});
        self.raw("    }\n");
        self.raw("};\n\n");
    }

    fn emitResourceExtern(self: *Gen, iface_id: []const u8, rname: []const u8, m: ast.ResourceMethod) GenError!void {
        const func = m.func;
        const ext = try self.resourceExternName(rname, m);
        if (func.is_async) return self.emitAsyncResourceExtern(iface_id, ext, m);

        self.print("        extern \"{s}\" fn @\"{s}\"(", .{ iface_id, ext });
        var first = true;
        if (m.kind == .method) {
            self.raw("self: i32");
            first = false;
        }
        for (func.params) |p| {
            const slots = try self.paramSlots(p);
            for (slots) |s| {
                if (!first) self.raw(", ");
                first = false;
                self.print("{s}: {s}", .{ s.name, @tagName(s.core) });
            }
        }
        if (m.kind == .constructor) {
            self.raw(") i32;\n"); // -> own<R> handle
            return;
        }
        const rcount: usize = if (func.result) |t| try self.flatCount(t) else 0;
        if (rcount > 1) {
            if (!first) self.raw(", ");
            self.raw("retptr: i32) void;\n");
        } else if (rcount == 1) {
            self.print(") {s};\n", .{@tagName(try self.coreOfResult(func.result.?))});
        } else {
            self.raw(") void;\n");
        }
    }

    /// Emit the `extern` for an **async** resource method/static: the canonical
    /// async lowering yields `(self?, flat params, result_ptr if any) -> i32`
    /// (the packed callstatus); the result is written to `result_ptr`. `self`
    /// (for a method) counts toward the `MAX_FLAT_ASYNC_PARAMS` (4) budget;
    /// beyond it the params (including `self`) spill to a single pointer. An
    /// async constructor (not used by WASI 0.3) is rejected.
    fn emitAsyncResourceExtern(self: *Gen, iface_id: []const u8, ext: []const u8, m: ast.ResourceMethod) GenError!void {
        const func = m.func;
        if (m.kind == .constructor) return error.UnsupportedWitType;
        const self_slot: usize = if (m.kind == .method) 1 else 0;
        const spill = self_slot + try self.paramFlatCount(func.params) > 4;

        self.print("        extern \"{s}\" fn @\"{s}\"(", .{ iface_id, ext });
        if (spill) {
            // `self` (for a method) lowers into the spilled param block.
            self.raw("args_ptr: i32");
            if (func.result != null) self.raw(", result_ptr: i32");
            self.raw(") i32;\n");
            return;
        }
        var first = true;
        if (m.kind == .method) {
            self.raw("self: i32");
            first = false;
        }
        for (func.params) |p| {
            const slots = try self.paramSlots(p);
            for (slots) |s| {
                if (!first) self.raw(", ");
                first = false;
                self.print("{s}: {s}", .{ s.name, @tagName(s.core) });
            }
        }
        if (func.result != null) {
            if (!first) self.raw(", ");
            self.raw("result_ptr: i32");
        }
        self.raw(") i32;\n"); // packed callstatus
    }

    fn emitResourceWrapper(self: *Gen, R: []const u8, rname: []const u8, m: ast.ResourceMethod) GenError!void {
        const func = m.func;
        const ext = try self.resourceExternName(rname, m);
        if (func.is_async) return self.emitAsyncResourceWrapper(R, ext, m);
        const is_method = m.kind == .method;

        if (m.kind == .constructor) {
            self.raw("    pub fn init(");
        } else {
            self.print("    pub fn {s}(", .{try camel(self.ar, m.name)});
        }
        if (is_method) {
            self.print("self: {s}", .{R});
            if (func.params.len > 0) self.raw(", ");
        }
        try self.emitTypedParamDecls(func.params);
        if (m.kind == .constructor) {
            self.print(") {s} {{\n", .{R});
        } else {
            self.print(") {s} {{\n", .{try self.resultZig(func)});
        }

        // lower params → arg expressions (emitting temps as needed)
        const call_args = try self.lowerParams(func.params);
        const args = if (is_method) blk: {
            if (call_args.len > 0) break :blk try std.fmt.allocPrint(self.ar, "self.handle, {s}", .{call_args});
            break :blk "self.handle";
        } else call_args;

        if (m.kind == .constructor) {
            self.print("        return .{{ .handle = imp.@\"{s}\"({s}) }};\n", .{ ext, args });
            self.raw("    }\n");
            return;
        }

        const result_zig = try self.resultZig(func);
        const rcount: usize = if (func.result) |t| try self.flatCount(t) else 0;
        if (rcount > 1) {
            if (args.len > 0) {
                self.print("        imp.@\"{s}\"({s}, wit_types.retPtr());\n", .{ ext, args });
            } else {
                self.print("        imp.@\"{s}\"(wit_types.retPtr());\n", .{ext});
            }
            self.print("        return wit_types.lift({s}, wit_types.retArea());\n", .{result_zig});
        } else if (func.result == null) {
            self.print("        imp.@\"{s}\"({s});\n", .{ ext, args });
        } else {
            self.print("        return wit_types.liftResultFlat({s}, imp.@\"{s}\"({s}));\n", .{ result_zig, ext, args });
        }
        self.raw("    }\n");
    }

    /// Emit the typed wrapper for an **async** resource method/static: lower the
    /// params (prefixed by `self.handle` for a method), call the async-lowered
    /// extern (returns the packed callstatus), drive it to completion via
    /// `wit_async.awaitCall`, then lift the result the host wrote to the result
    /// pointer. Always lifts from memory (async lowering writes results
    /// indirectly, even for a single-slot result).
    fn emitAsyncResourceWrapper(self: *Gen, R: []const u8, ext: []const u8, m: ast.ResourceMethod) GenError!void {
        const func = m.func;
        const is_method = m.kind == .method;
        const self_slot: usize = if (is_method) 1 else 0;
        const spill = self_slot + try self.paramFlatCount(func.params) > 4;

        self.print("    pub fn {s}(", .{try camel(self.ar, m.name)});
        if (is_method) {
            self.print("self: {s}", .{R});
            if (func.params.len > 0) self.raw(", ");
        }
        try self.emitTypedParamDecls(func.params);
        self.print(") {s} {{\n", .{try self.resultZig(func)});

        // lower params → arg expressions (emitting temps / a spilled block).
        const args = if (spill)
            try self.emitAsyncSpill(func.params, if (is_method) "self" else null)
        else blk: {
            const call_args = try self.lowerParams(func.params);
            if (is_method) {
                if (call_args.len > 0) break :blk try std.fmt.allocPrint(self.ar, "self.handle, {s}", .{call_args});
                break :blk "self.handle";
            }
            break :blk call_args;
        };

        if (func.result != null) {
            if (args.len > 0) {
                self.print("        const __status = imp.@\"{s}\"({s}, wit_types.retPtr());\n", .{ ext, args });
            } else {
                self.print("        const __status = imp.@\"{s}\"(wit_types.retPtr());\n", .{ext});
            }
            self.raw("        wit_async.awaitCall(__status);\n");
            self.print("        return wit_types.lift({s}, wit_types.retArea());\n", .{try self.resultZig(func)});
        } else {
            self.print("        const __status = imp.@\"{s}\"({s});\n", .{ ext, args });
            self.raw("        wit_async.awaitCall(__status);\n");
        }
        self.raw("    }\n");
    }

    /// `iface_id \x00 name` — the `scoped` map key.
    fn scopeKey(self: *Gen, iface: []const u8, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.ar, "{s}\x00{s}", .{ iface, name }) catch @panic("OOM");
    }

    /// The kind of a named type, resolved in the current interface's scope (so a
    /// `use`d or same-named type binds to the right structure), falling back to
    /// the global registry when no interface context is set.
    fn typeKind(self: *Gen, name: []const u8) ?ast.TypeDefKind {
        if (self.current_iface.len != 0) {
            if (self.scoped.get(self.scopeKey(self.current_iface, name))) |info| return info.kind;
        }
        return self.types.get(name);
    }

    /// The interface name (`<iface>`) portion of a qualified id
    /// (`<ns>:<pkg>/<iface>[@<ver>]`).
    fn ifaceBaseName(iface_id: []const u8) []const u8 {
        var s = iface_id;
        if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s = s[i + 1 ..];
        if (std.mem.indexOfScalar(u8, s, '@')) |i| s = s[0..i];
        return s;
    }

    /// The Zig identifier for a named type. Unique names keep their plain
    /// PascalCase; a name defined by several interfaces is prefixed with its
    /// defining interface (e.g. `IpNameLookupErrorCode`) so the bindings compile
    /// (#303).
    fn typeName(self: *Gen, name: []const u8) GenError![]const u8 {
        if (!self.colliding.contains(name)) return pascal(self.ar, name);
        const def_iface = if (self.current_iface.len != 0)
            (if (self.scoped.get(self.scopeKey(self.current_iface, name))) |info| info.def_iface else self.current_iface)
        else
            self.current_iface;
        if (def_iface.len == 0) return pascal(self.ar, name);
        return std.fmt.allocPrint(self.ar, "{s}{s}", .{
            try pascal(self.ar, self.interfaceDisambiguator(def_iface)),
            try pascal(self.ar, name),
        });
    }

    fn interfaceModuleName(self: *Gen, iface_id: []const u8) GenError![]const u8 {
        return snake(self.ar, self.interfaceDisambiguator(iface_id));
    }

    fn interfaceDisambiguator(self: *Gen, iface_id: []const u8) []const u8 {
        const base = ifaceBaseName(iface_id);
        if ((self.iface_name_counts.get(base) orelse 0) < 2) return base;

        const slash = std.mem.lastIndexOfScalar(u8, iface_id, '/') orelse return base;
        const package_start = if (std.mem.lastIndexOfScalar(u8, iface_id[0..slash], ':')) |colon|
            colon + 1
        else
            0;
        return std.fmt.allocPrint(
            self.ar,
            "{s}-{s}",
            .{ iface_id[package_start..slash], base },
        ) catch @panic("OOM");
    }

    fn resolveAlias(self: *Gen, ty: ast.Type) ast.Type {
        var t = ty;
        while (t == .name) {
            const k = self.typeKind(t.name) orelse return t;
            switch (k) {
                .alias => |a| t = a,
                else => return t,
            }
        }
        return t;
    }

    // ── complex future/stream channels (function-reference intrinsics) ───
    //
    // A non-primitive future/stream element can't be named with the
    // `[future]future<T>` / `[stream]stream<T>` intrinsic module (that spelling
    // only covers primitive `T`). `component new` instead resolves the
    // function-reference form `[future]<iface>#<fn>#<idx>` (and `[stream]…`),
    // where `<idx>` is the 0-based position of the future/stream in `<fn>`'s
    // signature, walked params-then-result, depth-first pre-order (mirroring
    // `collectAsyncInSig` / `collectAsyncInValType` in component_new.zig). We
    // pre-walk every imported function, bind each distinct structural channel to
    // one such site, and emit a shared `canon.FutureOf` / `canon.StreamOf` type.

    const AsyncOcc = struct { is_future: bool, element: ?ast.Type };

    /// Append every stream/future reachable from a function signature (params
    /// then result), depth-first in appearance order. An occurrence's position
    /// in `out` is its async-idx.
    fn collectAsyncSig(self: *Gen, func: ast.Func, out: *std.ArrayListUnmanaged(AsyncOcc)) GenError!void {
        for (func.params) |p| try self.collectAsyncTy(p.type, out);
        if (func.result) |r| try self.collectAsyncTy(r, out);
    }

    fn collectAsyncTy(self: *Gen, raw_ty: ast.Type, out: *std.ArrayListUnmanaged(AsyncOcc)) GenError!void {
        switch (self.resolveAlias(raw_ty)) {
            .future => |e| {
                try out.append(self.ar, .{ .is_future = true, .element = if (e) |p| p.* else null });
                if (e) |p| try self.collectAsyncTy(p.*, out);
            },
            .stream => |e| {
                try out.append(self.ar, .{ .is_future = false, .element = if (e) |p| p.* else null });
                if (e) |p| try self.collectAsyncTy(p.*, out);
            },
            .option => |e| try self.collectAsyncTy(e.*, out),
            .list => |e| try self.collectAsyncTy(e.*, out),
            .result => |r| {
                if (r.ok) |t| try self.collectAsyncTy(t.*, out);
                if (r.err) |t| try self.collectAsyncTy(t.*, out);
            },
            .tuple => |elems| for (elems) |e| try self.collectAsyncTy(e, out),
            .name => |n| switch (self.typeKind(n) orelse return) {
                .record => |fields| for (fields) |f| try self.collectAsyncTy(f.type, out),
                .variant => |cases| for (cases) |c| if (c.type) |t| try self.collectAsyncTy(t, out),
                else => {},
            },
            else => {},
        }
    }

    /// True if a future/stream element is a primitive the `canon.Future` /
    /// `canon.Stream` `[future]future<T>` spelling supports; a complex element
    /// instead needs the function-reference intrinsic (`canon.FutureOf` /
    /// `canon.StreamOf`).
    fn isPrimitiveElement(self: *Gen, e: ?ast.Type) bool {
        return switch (self.resolveAlias(e orelse return false)) {
            .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64 => true,
            else => false,
        };
    }

    /// Dedup key for a complex channel: declaring interface + family + element
    /// zig type. Per-interface so a channel binds to a site in its own
    /// interface (a subset-importing consumer then always imports the named
    /// interface — #295).
    fn chanKey(self: *Gen, is_future: bool, elem: ast.Type) GenError![]const u8 {
        return std.fmt.allocPrint(self.ar, "{s}|{s}{s}", .{ self.current_iface, if (is_future) "F:" else "S:", try self.zigType(elem) });
    }

    /// The generated nominal type name for a complex channel, or null for a
    /// primitive-element channel (which uses `canon.Future` / `canon.Stream`).
    fn chanName(self: *Gen, is_future: bool, e: ?ast.Type) GenError!?[]const u8 {
        const elem = e orelse return null;
        if (self.isPrimitiveElement(e)) return null;
        return self.chan_map.get(try self.chanKey(is_future, elem));
    }

    /// Pre-pass: register every distinct complex future/stream channel reachable
    /// from the world's imported functions, binding each to a function-reference
    /// intrinsic module. Each distinct structural channel is bound to one
    /// canonical site (any valid site resolves to the same structure).
    fn registerChannels(self: *Gen, uses: []const Use) GenError!void {
        for (uses) |u| {
            // Imports only for now: complex channels in the worlds we target are
            // import-side; the export-side intrinsic form is a later refinement.
            if (u.is_export) continue;
            self.current_iface = u.id;
            for (u.iface.items) |it| switch (it) {
                .func => |fd| try self.registerFuncChannels(u.id, fd.name, fd.func),
                .type => |td| switch (td.kind) {
                    .resource => |methods| for (methods) |m| {
                        try self.registerFuncChannels(u.id, try self.resourceExternName(td.name, m), m.func);
                    },
                    else => {},
                },
                else => {},
            };
        }
        self.current_iface = "";
    }

    fn registerFuncChannels(self: *Gen, iface_id: []const u8, fn_name: []const u8, func: ast.Func) GenError!void {
        var occ = std.ArrayListUnmanaged(AsyncOcc).empty;
        try self.collectAsyncSig(func, &occ);
        for (occ.items, 0..) |o, idx| {
            const elem = o.element orelse continue;
            if (self.isPrimitiveElement(o.element)) continue;
            const key = try self.chanKey(o.is_future, elem);
            if (self.chan_map.contains(key)) continue;
            const name = try std.fmt.allocPrint(self.ar, "__chan{d}", .{self.chan_counter});
            self.chan_counter += 1;
            const ctor: []const u8 = if (o.is_future) "FutureOf" else "StreamOf";
            const family: []const u8 = if (o.is_future) "future" else "stream";
            const rhs = try std.fmt.allocPrint(self.ar, "wit_types.{s}({s}, \"[{s}]{s}#{s}#{d}\")", .{
                ctor, try self.zigType(elem), family, iface_id, fn_name, idx,
            });
            try self.chan_map.put(self.ar, key, name);
            try self.chan_decls.append(self.ar, .{ .name = name, .rhs = rhs });
        }
    }

    /// Lower each high-level param into the flat call arguments, emitting temp
    /// statements for `option<…>`. Returns the comma-joined argument list.
    fn lowerParams(self: *Gen, params: []const ast.Param) GenError![]const u8 {
        var args = std.ArrayListUnmanaged(u8).empty;
        for (params) |p| {
            const pn = try snake(self.ar, p.name);
            if (args.items.len != 0) try args.appendSlice(self.ar, ", ");
            const rty = self.resolveAlias(p.type);
            if (self.isHandleLike(rty)) {
                try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "{s}.handle", .{pn}));
                continue;
            }
            // In `--dispatch` mode (the mode `--js-imports` always runs in),
            // `zigType` maps `char` / a *direct* `list<u8>` one level deeper
            // than everywhere else, to the wrapper structs `wit_types.Char`
            // / `wit_types.ByteList` (so the JS bridge can tell them apart
            // from a bare `u32` / a generic `list<T>` at runtime -- see
            // those structs' own doc comments). The scalar/slice fast paths
            // below assume the bare payload type (true in `--impl` mode, and
            // true here for every *other* dispatch-mode type), so route
            // these two through the generic, reflection-based
            // `lowerAggregateParam` instead -- it already lowers `Char`/
            // `ByteList` correctly (single-field structs fall out of its
            // `wit_types.lowerFlat` call for free; see wit_types.zig's
            // "Char/ByteList wrappers have the same canonical layout as
            // their bare payload" test) rather than trying to `@intCast` or
            // `.ptr`/`.len` a field that doesn't exist on the wrapper.
            if (self.dispatch != null) {
                var wrapped = false;
                switch (rty) {
                    .char => wrapped = true,
                    .list => |e| if (e.* == .u8) {
                        wrapped = true;
                    },
                    else => {},
                }
                if (wrapped) {
                    try self.lowerAggregateParam(&args, pn, p.type);
                    continue;
                }
            }
            switch (rty) {
                .string, .list => {
                    // `string` / `list<T>`: pass the guest slice's (ptr, len).
                    try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "@intCast(@intFromPtr({s}.ptr)), @intCast({s}.len)", .{ pn, pn }));
                },
                .option => |e| {
                    const inner = self.resolveAlias(e.*);
                    // `lowerOptionParam`'s fast path hand-emits the payload
                    // expression assuming `inner`'s *Zig* representation is
                    // either a handle (`.handle` field) or a value already
                    // usable inline as the scalar it appears to be (a bare
                    // Zig int/float/bool -- what `scalarLowerExpr` knows how
                    // to cast). That assumption fails for any `inner` whose
                    // `zigType` is actually a wrapper/aggregate Zig value even
                    // though it flattens to a single core slot: `char` in
                    // `--dispatch` mode (`wit_types.Char`, a struct), a named
                    // `enum` (a Zig `enum`, not an int -- needs
                    // `@intFromEnum`), a named `flags` with ≤32 labels (a
                    // `packed struct`), a single-field `record`, a
                    // single-element `tuple`, or an all-void `variant`/
                    // `result` (a union needing its tag). All of those are
                    // exactly what the generic, reflection-based
                    // `wit_types.lowerFlat` (driven by `lowerAggregateParam`)
                    // already lowers correctly for every other aggregate
                    // param -- it introspects the *actual* generated Zig type
                    // via `@typeInfo` instead of guessing from the WIT shape,
                    // so it can't go stale as `zigType`/`nativeBridgeSupported`
                    // grow new representable shapes. Route everything except
                    // `string` and genuine scalars/handles through it.
                    if (inner == .string) {
                        try self.lowerOptionParam(&args, pn, inner);
                    } else if (self.isHandleLike(inner) or self.isPlainZigScalar(inner)) {
                        try self.lowerOptionParam(&args, pn, inner);
                    } else {
                        try self.lowerAggregateParam(&args, pn, p.type);
                    }
                },
                .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64, .char => {
                    try args.appendSlice(self.ar, try self.scalarLowerExpr(pn, rty));
                },
                // record / variant / result / tuple / enum / flags: flatten the
                // whole value to its core slots via canon and pass them positionally.
                else => try self.lowerAggregateParam(&args, pn, p.type),
            }
        }
        return args.items;
    }

    /// Lower an aggregate param: `const <pn>_s = wit_types.lowerFlat(<T>, <pn>,
    /// &wit_types.alloc);` then pass `<pn>_s[0], …, <pn>_s[K-1]` positionally.
    fn lowerAggregateParam(self: *Gen, args: *std.ArrayListUnmanaged(u8), pn: []const u8, ty: ast.Type) GenError!void {
        const k = (try self.flatCores(ty)).len;
        self.print("        const {s}_s = wit_types.lowerFlat({s}, {s}, &wit_types.alloc);\n", .{ pn, try self.zigType(ty), pn });
        for (0..k) |i| {
            if (i != 0) try args.appendSlice(self.ar, ", ");
            try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "{s}_s[{d}]", .{ pn, i }));
        }
    }

    /// Lower an `option<inner>` param: a discriminant plus the (null-zeroed)
    /// payload slots. `string` is the (ptr, len) special case; otherwise
    /// `inner` must be a genuine Zig scalar (`isPlainZigScalar`) or handle-like
    /// (`isHandleLike`) -- the caller (`lowerParams`) routes every other
    /// shape (including single-flat-slot aggregates/wrappers such as `char`
    /// in `--dispatch` mode, `enum`, `flags`, a single-field `record`, …)
    /// through `lowerAggregateParam` instead, which lowers via the real
    /// generated Zig type rather than assuming it casts like a bare number.
    fn lowerOptionParam(self: *Gen, args: *std.ArrayListUnmanaged(u8), pn: []const u8, inner: ast.Type) GenError!void {
        self.print("        const {s}_disc: i32 = if ({s} != null) 1 else 0;\n", .{ pn, pn });
        if (inner == .string) {
            self.print("        const {s}_ptr: i32 = if ({s}) |v| @intCast(@intFromPtr(v.ptr)) else 0;\n", .{ pn, pn });
            self.print("        const {s}_len: i32 = if ({s}) |v| @intCast(v.len) else 0;\n", .{ pn, pn });
            try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "{s}_disc, {s}_ptr, {s}_len", .{ pn, pn, pn }));
            return;
        }
        if (try self.flatCount(inner) != 1) return error.UnsupportedWitType;
        const core = @tagName(try self.coreOfResult(inner));
        const some: []const u8 = if (self.isHandleLike(inner))
            "v.handle"
        else
            try self.scalarLowerExpr("v", self.resolveAlias(inner));
        self.print("        const {s}_0: {s} = if ({s}) |v| {s} else 0;\n", .{ pn, core, pn, some });
        try args.appendSlice(self.ar, try std.fmt.allocPrint(self.ar, "{s}_disc, {s}_0", .{ pn, pn }));
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

    fn flattenSlots(self: *Gen, out: *std.ArrayListUnmanaged(Slot), base: []const u8, raw_ty: ast.Type) GenError!void {
        const ty = self.resolveAlias(raw_ty);
        if (self.isHandleLike(ty)) {
            try out.append(self.ar, .{ .name = base, .core = .i32 });
            return;
        }
        switch (ty) {
            .string, .list => {
                try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_ptr", .{base}), .core = .i32 });
                try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_len", .{base}), .core = .i32 });
            },
            .option => |e| {
                try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_disc", .{base}), .core = .i32 });
                try self.flattenSlots(out, base, e.*);
            },
            .tuple => |elems| for (elems, 0..) |e, i| {
                try self.flattenSlots(out, try std.fmt.allocPrint(self.ar, "{s}_{d}", .{ base, i }), e);
            },
            else => {
                // scalar (1 slot) or aggregate (record/variant/result/enum/flags):
                // use the canonical flat core types (with the variant join).
                const cores = try self.flatCores(ty);
                if (cores.len == 1) {
                    try out.append(self.ar, .{ .name = base, .core = cores[0] });
                } else for (cores, 0..) |c, i| {
                    try out.append(self.ar, .{ .name = try std.fmt.allocPrint(self.ar, "{s}_{d}", .{ base, i }), .core = c });
                }
            },
        }
    }

    fn joinCoreG(a: Core, b: Core) Core {
        if (a == b) return a;
        if ((a == .i32 and b == .f32) or (a == .f32 and b == .i32)) return .i32;
        return .i64;
    }

    /// The canonical flat core types `ty` lowers to (mirrors `canon.flatTypeList`,
    /// including the `variant`/`result` join). Used for both the flattened extern
    /// signatures and the export param decls.
    fn flatCores(self: *Gen, raw_ty: ast.Type) GenError![]const Core {
        const ty = self.resolveAlias(raw_ty);
        if (self.isHandleLike(ty)) return &[_]Core{.i32};
        return switch (ty) {
            .string, .list => &[_]Core{ .i32, .i32 },
            .option => |e| blk: {
                var l = std.ArrayListUnmanaged(Core).empty;
                try l.append(self.ar, .i32);
                try l.appendSlice(self.ar, try self.flatCores(e.*));
                break :blk l.items;
            },
            .tuple => |elems| blk: {
                var l = std.ArrayListUnmanaged(Core).empty;
                for (elems) |e| try l.appendSlice(self.ar, try self.flatCores(e));
                break :blk l.items;
            },
            .result => |r| blk: {
                var l = std.ArrayListUnmanaged(Core).empty;
                try l.append(self.ar, .i32); // discriminant
                if (r.ok) |t| try self.joinInto(&l, t.*);
                if (r.err) |t| try self.joinInto(&l, t.*);
                break :blk l.items;
            },
            .name => |n| switch (self.typeKind(n) orelse return error.UnknownType) {
                .record => |fields| blk: {
                    var l = std.ArrayListUnmanaged(Core).empty;
                    for (fields) |f| try l.appendSlice(self.ar, try self.flatCores(f.type));
                    break :blk l.items;
                },
                .variant => |cases| blk: {
                    var l = std.ArrayListUnmanaged(Core).empty;
                    try l.append(self.ar, .i32); // discriminant
                    for (cases) |c| if (c.type) |t| try self.joinInto(&l, t);
                    break :blk l.items;
                },
                .@"enum", .resource => &[_]Core{.i32},
                .flags => |labels| blk: {
                    var l = std.ArrayListUnmanaged(Core).empty;
                    for (0..(labels.len + 31) / 32) |_| try l.append(self.ar, .i32);
                    break :blk l.items;
                },
                .alias => unreachable, // resolved above
            },
            else => blk: {
                // scalar: a single core slot. Allocate in the arena (a
                // `&[_]Core{runtime}` literal would dangle after return).
                var l = std.ArrayListUnmanaged(Core).empty;
                try l.append(self.ar, try self.coreOf(ty));
                break :blk l.items;
            },
        };
    }

    /// Join `ty`'s flat cores element-wise into `l[1..]` (extending as needed).
    fn joinInto(self: *Gen, l: *std.ArrayListUnmanaged(Core), ty: ast.Type) GenError!void {
        const cores = try self.flatCores(ty);
        for (cores, 0..) |c, i| {
            const idx = 1 + i;
            if (idx < l.items.len) l.items[idx] = joinCoreG(l.items[idx], c) else try l.append(self.ar, c);
        }
    }

    fn coreOf(self: *Gen, ty: ast.Type) GenError!Core {
        _ = self;
        return switch (ty) {
            .bool, .u8, .u16, .u32, .s8, .s16, .s32, .char => .i32,
            .u64, .s64 => .i64,
            .f32 => .f32,
            .f64 => .f64,
            .own, .borrow, .future, .stream, .error_context => .i32, // handles
            else => error.UnsupportedWitType,
        };
    }

    /// True when `ty` lowers to a single `i32` handle accessed via a `.handle`
    /// field: `own<R>` / `borrow<R>` / a bare resource reference, or a
    /// `future<T>` / `stream<T>` / `error-context`.
    fn isHandleLike(self: *Gen, ty: ast.Type) bool {
        return switch (ty) {
            .own, .borrow, .future, .stream, .error_context => true,
            .name => |n| if (self.typeKind(n)) |k| k == .resource else false,
            else => false,
        };
    }

    /// True when `ty`'s `zigType` is a bare Zig number/bool primitive that
    /// `scalarLowerExpr` can cast inline (`@intCast`/`@bitCast`/etc. on the
    /// value itself) -- i.e. NOT a struct/enum/packed-struct/union wrapper.
    /// This is strictly narrower than "flattens to one core slot": `char` in
    /// `--dispatch` mode, a named `enum`, a named `flags`, a single-field
    /// `record`, a single-element `tuple`, and an all-void `variant`/`result`
    /// all flatten to one (or, for `result`, one-plus-void) core slot too,
    /// but each is a Zig aggregate value that `scalarLowerExpr` cannot cast
    /// as if it were already an int/float/bool -- those must go through the
    /// reflection-based `wit_types.lowerFlat` (`lowerAggregateParam`)
    /// instead, which introspects the real Zig type via `@typeInfo`. `char`
    /// is the sole *mode-dependent* case: it's only "plain" in `--impl` mode
    /// where `zigType(.char)` is a bare `u32`; in `--dispatch` mode it's the
    /// `wit_types.Char` wrapper struct.
    fn isPlainZigScalar(self: *Gen, ty: ast.Type) bool {
        return switch (ty) {
            .bool, .u8, .u16, .u32, .u64, .s8, .s16, .s32, .s64, .f32, .f64 => true,
            .char => self.dispatch == null,
            else => false,
        };
    }

    fn coreOfResult(self: *Gen, ty: ast.Type) GenError!Core {
        // `ty` is a result already known to flatten to a single core slot.
        // Aggregates carrying a discriminant (result / all-void variant / enum)
        // flatten to its i32; a single-field record flattens to that field.
        return switch (ty) {
            .result => .i32,
            .own, .borrow, .future, .stream, .error_context => .i32, // handles
            .tuple => |elems| if (elems.len == 1) try self.coreOfResult(elems[0]) else error.UnsupportedWitType,
            .name => |n| switch (self.typeKind(n) orelse return error.UnknownType) {
                .@"enum", .variant => .i32,
                .flags => .i32, // ≤32 labels → a single i32 slot
                .resource => .i32, // a handle
                .record => |fields| if (fields.len == 1)
                    try self.coreOfResult(fields[0].type)
                else
                    error.UnsupportedWitType,
                .alias => |t| try self.coreOfResult(t),
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
    if (std.zig.Token.getKeyword(out) != null) {
        const quoted = try std.fmt.allocPrint(ar, "@\"{s}\"", .{out});
        ar.free(out);
        return quoted;
    }
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
    if (std.zig.Token.getKeyword(p) != null) {
        const quoted = try std.fmt.allocPrint(ar, "@\"{s}\"", .{p});
        ar.free(p);
        return quoted;
    }
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
    {
        const s = try snake(a, "error");
        defer a.free(s);
        try testing.expectEqualStrings("@\"error\"", s);
    }
    {
        const s = try camel(a, "error");
        defer a.free(s);
        try testing.expectEqualStrings("@\"error\"", s);
    }
}

test "duplicate interface basenames use package-qualified Zig names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = Gen{
        .ar = a,
        .resolver = undefined,
        .impl = "impl",
    };
    try g.iface_name_counts.put(a, "types", 2);
    try testing.expectEqualStrings(
        "filesystem_types",
        try g.interfaceModuleName("wasi:filesystem/types@0.2.10"),
    );
    try testing.expectEqualStrings(
        "http_types",
        try g.interfaceModuleName("wasi:http/types@0.2.10"),
    );
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
    const dispatch_ty: ast.Type = .u32;
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "pet", .kind = .{ .record = &pet_fields } } },
        .{ .type = .{ .name = "dispatch", .kind = .{ .alias = dispatch_ty } } },
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
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:t/store#ping\"(x: i32) wit_types.CoreReturn(u32)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.returnResult(u32, Impl.ping(__params.x), &wit_types.alloc)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:t/store#get\"(id: i32) wit_types.CoreReturn(?Pet)") != null);
        // No stray module-scope statement after an export shell's closing brace
        // (regression: a duplicate resetScratch was emitted at container scope).
        try testing.expect(std.mem.indexOf(u8, out, "}\n\n    wit_types.resetScratch();") == null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "const __wit_dispatch = @import(\"js_dispatch\");") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub const Dispatch = u32;") != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:t/store#ping\", u32, .{ __params.x })",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:t/store#get\", ?Pet, .{ __params.id })",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, out, "Impl.") == null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "pub const store = struct {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:t/store\" fn @\"ping\"(x: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(u32, imp.@\"ping\"(@bitCast(x)));") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:t/store\" fn @\"get\"(id: i32, retptr: i32) void;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift(?Pet, wit_types.retArea());") != null);
    }
}

test "zigType: char/list<u8> disambiguate only in --dispatch mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const u8_ty: ast.Type = .u8;
    const list_u8 = ast.Type{ .list = &u8_ty };
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "echo-char", .func = .{
            .params = &.{.{ .name = "c", .type = .char }},
            .result = .char,
        } } },
        .{ .func = .{ .name = "echo-bytes", .func = .{
            .params = &.{.{ .name = "b", .type = list_u8 }},
            .result = list_u8,
        } } },
        .{ .func = .{ .name = "echo-string", .func = .{
            .params = &.{.{ .name = "s", .type = .string }},
            .result = .string,
        } } },
    };
    const iface = ast.Interface{ .name = "bytes-api", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "bytes-api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "t" },
        .items = &.{ .{ .interface = iface }, .{ .world = exp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    // `--impl` mode: unaffected, still bare `u32`/`[]const u8` for both
    // `char` and `list<u8>` (every other consumer of this generator, e.g.
    // `wasi:*` bindings, must see zero change).
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.Char") == null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.ByteList") == null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "wit_types.returnResult(u32, Impl.echoChar(__params.c), &wit_types.alloc)",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "wit_types.returnResult([]const u8, Impl.echoBytes(__params.b), &wit_types.alloc)",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "wit_types.returnResult([]const u8, Impl.echoString(__params.s), &wit_types.alloc)",
        ) != null);
    }
    // `--dispatch` mode: `char`/`list<u8>` get the disambiguating wrapper;
    // plain `string` is untouched.
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
        try g.generate(exp_world, "host");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:t/bytes-api#echo-char\", wit_types.Char, .{ __params.c })",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:t/bytes-api#echo-bytes\", wit_types.ByteList, .{ __params.b })",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:t/bytes-api#echo-string\", []const u8, .{ __params.s })",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.CoreReturn(wit_types.Char)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.CoreReturn(wit_types.ByteList)") != null);
    }
}

// Companion to the StarlingMonkey typed-native-bridge spike
// (runtime/js_dispatch.{h,cpp,zig} in the StarlingMonkey worktree): that
// bridge is only reachable when a dispatched export's argument/result type
// graph contains a `u64`/`s64` (see `needsNative` there), so it depends on
// this generator continuing to emit exact `u64`/`s64` typed shells --
// **not** widened to `f64` or routed through any JSON-only representation --
// for `--dispatch` mode, including when a `u64` is nested inside a record
// embedded in another record. This test locks that down at the generator
// level: no code changes were needed in this bindgen to support the spike,
// but its correctness is exactly what the spike's native bridge relies on.
test "generate: dispatch mode preserves exact u64/s64 params, results, and nested records" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // record point { x: u32, y: u32 }
    // record big-point { p: point, id: u64 }
    // big-add: func(a: u64, b: u64) -> u64
    // big-sub: func(a: s64, b: s64) -> s64
    // tag-point: func(p: point, id: u64) -> big-point
    const point_fields = [_]ast.Field{
        .{ .name = "x", .type = .u32 },
        .{ .name = "y", .type = .u32 },
    };
    const point_ref = ast.Type{ .name = "point" };
    const big_point_fields = [_]ast.Field{
        .{ .name = "p", .type = point_ref },
        .{ .name = "id", .type = .u64 },
    };
    const big_point_ref = ast.Type{ .name = "big-point" };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "point", .kind = .{ .record = &point_fields } } },
        .{ .type = .{ .name = "big-point", .kind = .{ .record = &big_point_fields } } },
        .{ .func = .{ .name = "big-add", .func = .{
            .params = &.{ .{ .name = "a", .type = .u64 }, .{ .name = "b", .type = .u64 } },
            .result = .u64,
        } } },
        .{ .func = .{ .name = "big-sub", .func = .{
            .params = &.{ .{ .name = "a", .type = .s64 }, .{ .name = "b", .type = .s64 } },
            .result = .s64,
        } } },
        .{ .func = .{ .name = "tag-point", .func = .{
            .params = &.{ .{ .name = "p", .type = point_ref } },
            .result = big_point_ref,
        } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const exp_world = ast.World{ .name = "js-exports", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "starling", .name = "js" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = exp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try g.generate(exp_world, "js-exports");
    const out = g.out.items;

    // Nested record type generation: `BigPoint.id` stays `u64`, not widened
    // to a JSON-safe/f64-ish type.
    try testing.expect(std.mem.indexOf(u8, out, "pub const Point = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const BigPoint = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "p: Point,") != null);
    try testing.expect(std.mem.indexOf(u8, out, "id: u64,") != null);

    // u64 params/result dispatched with an exact `u64` Zig type, not `f64`.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "export fn @\"starling:js/api#big-add\"(a: i64, b: i64) wit_types.CoreReturn(u64)",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "__wit_dispatch.call(\"starling:js/api#big-add\", u64, .{ __params.a, __params.b })",
    ) != null);

    // s64 params/result likewise stay exact `i64`.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "__wit_dispatch.call(\"starling:js/api#big-sub\", i64, .{ __params.a, __params.b })",
    ) != null);

    // Nested-record result: dispatched with the generated `BigPoint` type,
    // not decomposed into flat scalars or a JSON-only representation.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "__wit_dispatch.call(\"starling:js/api#tag-point\", BigPoint, .{ __params.p })",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "Impl.") == null);
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
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:r/api#make\"() wit_types.CoreReturn(wit_types.Result(u32, []const u8))") != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.returnResult(wit_types.Result(u32, []const u8), Impl.make(), &wit_types.alloc)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:r/api#flag\"() wit_types.CoreReturn(wit_types.Result(void, void))") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        // indirect result: extern takes a retptr, wrapper lifts from the ret area.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:r/api\" fn @\"make\"(retptr: i32) void;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift(wit_types.Result(u32, []const u8), wit_types.retArea());") != null);
        // flat all-void result: extern returns the i32 discriminant directly.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:r/api\" fn @\"flag\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(wit_types.Result(void, void), imp.@\"flag\"());") != null);
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
        try testing.expect(std.mem.indexOf(u8, out, "const __params = wit_types.liftParams(struct {") != null);
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
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:v/api#pick\"() wit_types.CoreReturn(Value)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.returnResult(Value, Impl.pick(), &wit_types.alloc)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:v/api#state\"() wit_types.CoreReturn(Flag2)") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        // payload-bearing variant → indirect (retptr + lift).
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:v/api\" fn @\"pick\"(retptr: i32) void;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift(Value, wit_types.retArea());") != null);
        // all-void variant → flat i32 discriminant.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:v/api\" fn @\"state\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(Flag2, imp.@\"state\"());") != null);
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
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:f/api#get-perms\"() wit_types.CoreReturn(Perms)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_types.returnResult(Perms, Impl.getPerms(), &wit_types.alloc)") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "pub const Perms = packed struct(u8) {") != null);
        // ≤32 labels → flat i32.
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:f/api\" fn @\"get-perms\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(Perms, imp.@\"get-perms\"());") != null);
    }
}

test "generate: imported resource handle struct + methods/static/ctor/drop" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // resource counter { constructor(start: u32); increment: func(by: u32) -> u32;
    //   make-zero: static func() -> counter; }
    const counter_methods = [_]ast.ResourceMethod{
        .{ .kind = .constructor, .name = "", .func = .{ .params = &.{.{ .name = "start", .type = .u32 }}, .result = null } },
        .{ .kind = .method, .name = "increment", .func = .{ .params = &.{.{ .name = "by", .type = .u32 }}, .result = .u32 } },
        .{ .kind = .static, .name = "make-zero", .func = .{ .params = &.{}, .result = ast.Type{ .name = "counter" } } },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "counter", .kind = .{ .resource = &counter_methods } } },
    };
    const iface = ast.Interface{ .name = "counters", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "counters" } } } },
    } };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "counters" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "res" },
        .items = &.{
            .{ .interface = iface },
            .{ .world = imp_world },
            .{ .world = exp_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(imp_world, "guest");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "pub const Counter = struct {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "    handle: i32,") != null);
        // canonical resource externs (module = iface id).
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[constructor]counter\"(start: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[method]counter.increment\"(self: i32, by: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[static]counter.make-zero\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[resource-drop]counter\"(self: i32) void;") != null);
        // typed wrappers.
        try testing.expect(std.mem.indexOf(u8, out, "pub fn init(start: u32) Counter {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return .{ .handle = imp.@\"[constructor]counter\"(@bitCast(start)) };") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn increment(self: Counter, by: u32) u32 {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[method]counter.increment\"(self.handle, @bitCast(by))") != null);
        // a static returning own<counter> lifts the handle into the wrapper struct.
        try testing.expect(std.mem.indexOf(u8, out, "pub fn makeZero() Counter {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(Counter, imp.@\"[static]counter.make-zero\"());") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn deinit(self: Counter) void {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[resource-drop]counter\"(self.handle);") != null);
    }
    {
        // Exported (guest-implemented) resources are not supported yet.
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try testing.expectError(error.UnsupportedWitType, g.generate(exp_world, "host"));
    }
}

test "generate #286: named_interface import emits a plain-named import struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // world guest { import foo: interface { bar: func() -> u32; }; }
    const foo_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "bar", .func = .{ .params = &.{}, .result = .u32 } } },
    };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .named_interface = .{ .name = "foo", .items = &foo_items } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "ni" },
        .items = &.{.{ .world = world }},
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(world, "guest");
    const out = g.out.items;

    // Import struct named after the plain local name; the extern's wasm
    // module is the plain name `foo`, field `bar` — matching the pipeline.
    try testing.expect(std.mem.indexOf(u8, out, "pub const foo = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "extern \"foo\" fn @\"bar\"() i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn bar() u32 {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(u32, imp.@\"bar\"());") != null);
}

test "generate #286: named_func export emits a module-scope export shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // world cmd { export run: func(); }
    const world = ast.World{ .name = "cmd", .items = &.{
        .{ .@"export" = .{ .named_func = .{ .name = "run", .func = .{ .params = &.{}, .result = null } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "nf" },
        .items = &.{.{ .world = world }},
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(world, "cmd");
    const out = g.out.items;

    // An export pulls in the user impl.
    try testing.expect(std.mem.indexOf(u8, out, "const Impl = @import(\"impl\");") != null);
    // Module-scope export under the plain func name (no `<iface>#` prefix).
    try testing.expect(std.mem.indexOf(u8, out, "export fn @\"run\"() wit_types.CoreReturn(void) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Impl.run();") != null);
    try testing.expect(std.mem.indexOf(u8, out, "#run") == null);

    var dispatch_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try dispatch_g.generate(world, "cmd");
    const dispatch_out = dispatch_g.out.items;
    try testing.expect(std.mem.indexOf(u8, dispatch_out, "__wit_dispatch.call(\"run\", void, .{});") != null);
    try testing.expect(std.mem.indexOf(u8, dispatch_out, "Impl.") == null);
}

test "generate #286: named_func export with a primitive result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // world cmd { export compute: func(x: u32) -> u32; }
    const world = ast.World{ .name = "cmd", .items = &.{
        .{ .@"export" = .{ .named_func = .{
            .name = "compute",
            .func = .{ .params = &.{.{ .name = "x", .type = .u32 }}, .result = .u32 },
        } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "nf" },
        .items = &.{.{ .world = world }},
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(world, "cmd");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(u8, out, "export fn @\"compute\"(") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wit_types.returnResult(u32, Impl.compute(") != null);
}

test "generate: named_func root import emits canonical $root extern and module-scope wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const world = ast.World{ .name = "cmd", .items = &.{
        .{ .import = .{ .named_func = .{ .name = "compute", .func = .{
            .params = &.{.{ .name = "x", .type = .u32 }},
            .result = .u32,
        } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "nfi" },
        .items = &.{.{ .world = world }},
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(world, "cmd");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(u8, out, "const __root_imports = struct {") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "extern \"$root\" fn @\"compute\"(x: i32) i32;",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn compute(x: u32) u32 {") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "return wit_types.liftResultFlat(u32, __root_imports.@\"compute\"(@bitCast(x)));",
    ) != null);
}

test "generate --js-imports: manifest + dispatch trampoline for a versioned interface import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // wit: package test:flags@1.2.3; interface imports { get-flag: func(name: string) -> u32; }
    // world guest { import imports: interface { … }; }
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "get-flag", .func = .{
            .params = &.{.{ .name = "name", .type = .string }},
            .result = .u32,
        } } },
    };
    const iface = ast.Interface{ .name = "imports", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "imports" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "flags", .version = "1.2.3" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    // Typed import wrapper (existing, unaffected by --js-imports).
    try testing.expect(std.mem.indexOf(u8, out, "pub const imports = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn getFlag(name: []const u8) u32 {") != null);

    // Manifest: one TSV line naming the ComponentizeJS-compatible versioned
    // module specifier, the verbatim (kebab-case) JS export name, the
    // "<iface>#<fn>" dispatch key, and the arity.
    try testing.expect(std.mem.indexOf(u8, out, "pub const js_import_manifest: []const u8 =") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"test:flags/imports@1.2.3\\tget-flag\\ttest:flags/imports@1.2.3#get-flag\\t1\\n\"",
    ) != null);

    // Dispatch trampoline: decodes the string arg, calls the typed wrapper,
    // encodes the u32 result -- reusing js_dispatch's encode/decode, not a
    // duplicate codec.
    try testing.expect(std.mem.indexOf(u8, out, "pub export fn starling_js_import_dispatch(") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "if (std.mem.eql(u8, name, \"test:flags/imports@1.2.3#get-flag\")) {",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const a0 = js_dispatch.decodeNative([]const u8, &argv_ptr[0], __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __result = imports.getFlag(a0);") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "out_result.* = js_dispatch.encodeNative(u32, __result, __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub export fn starling_js_imports_manifest(out_len: *usize) callconv(.c) [*]const u8 {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub export fn starling_js_import_result_free(arena: ?*anyopaque) callconv(.c) void {") != null);

    // The dispatch trampoline body uses `std.mem.eql`/`std.heap.*`; the
    // generated file must actually import `std` for this to compile (a
    // real bug caught only by compiling the generated output, not by
    // string-matching it -- see tests/e2e/wit-imports/run.sh).
    try testing.expect(std.mem.indexOf(u8, out, "const std = @import(\"std\");") != null);
}

test "generate --js-imports: root function uses ComponentizeJS default-import manifest convention" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "twice", .func = .{
            .params = &.{.{ .name = "value", .type = .u32 }},
            .result = .u32,
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .named_func = .{ .name = "add-one", .func = .{
            .params = &.{.{ .name = "value", .type = .u32 }},
            .result = .u32,
        } } } },
        .{ .import = .{ .named_func = .{ .name = "notify", .func = .{
            .params = &.{.{ .name = "value", .type = .u32 }},
            .result = null,
        } } } },
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "root", .version = "0.1.0" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    // Root imports are canonical core imports from `$root`, not modules
    // named after their JavaScript module specifiers.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "extern \"$root\" fn @\"add-one\"(value: i32) i32;",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "extern \"$root\" fn @\"notify\"(value: i32) void;",
    ) != null);

    // ComponentizeJS 0.21 maps a world-level function `add-one` to
    // `import addOne from "add-one"` and reports ["add-one", "default"].
    // `$root#...` keeps the dispatch key distinct from interface functions.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"add-one\\tdefault\\t$root#add-one\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"notify\\tdefault\\t$root#notify\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "if (std.mem.eql(u8, name, \"$root#add-one\")) {",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __result = addOne(a0);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "notify(a0);") != null);

    // Existing named-interface entries and call targets remain unchanged.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"test:root/host@0.1.0\\ttwice\\ttest:root/host@0.1.0#twice\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __result = host.twice(a0);") != null);
}

test "generate: --js-imports is opt-in -- default (--dispatch alone) emits no import bridge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "get-flag", .func = .{
            .params = &.{.{ .name = "name", .type = .string }},
            .result = .u32,
        } } },
    };
    const iface = ast.Interface{ .name = "imports", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "imports" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "flags" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    // No `.js_imports = true` here -- matches components with no custom
    // JS-import bridge requested; default export-only behavior must be
    // unaffected.
    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try g.generate(world, "guest");
    const out = g.out.items;
    try testing.expect(std.mem.indexOf(u8, out, "js_import_manifest") == null);
    try testing.expect(std.mem.indexOf(u8, out, "starling_js_import_dispatch") == null);
}

test "generate --js-imports: world with only supported-elsewhere imports but nothing to bridge stays a no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // A world with only exports (no interface imports at all): --js-imports
    // must not synthesize a manifest-of-nothing or a dispatch function that
    // can only ever report "not found".
    const world = ast.World{ .name = "cmd", .items = &.{
        .{ .@"export" = .{ .named_func = .{ .name = "run", .func = .{ .params = &.{}, .result = null } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "nf" },
        .items = &.{.{ .world = world }},
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "cmd");
    const out = g.out.items;
    try testing.expect(std.mem.indexOf(u8, out, "js_import_manifest") == null);
    try testing.expect(std.mem.indexOf(u8, out, "starling_js_import_dispatch") == null);
}

test "generate --js-imports: an imported resource parameter is a deterministic build diagnostic, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface counters { resource counter { … } } / imports { use counters.{counter};
    // take: func(c: own<counter>); } -- "counters" is reached only via the
    // `use` (not imported by the world directly), so this test exercises the
    // parameter-type diagnostic in isolation from the "imported interface
    // defines a resource" diagnostic (covered by its own dedicated test
    // below, which fires whenever an *imported* interface itself declares a
    // resource, regardless of what its functions' parameters look like).
    const counter_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "counter", .kind = .{ .resource = &.{} } } },
    };
    const counters_iface = ast.Interface{ .name = "counters", .items = &counter_items };
    const imports_items = [_]ast.InterfaceItem{
        .{ .use = .{ .from = .{ .name = "counters" }, .names = &.{.{ .name = "counter" }} } },
        .{ .func = .{ .name = "take", .func = .{
            .params = &.{.{ .name = "c", .type = ast.Type{ .name = "counter" } }},
            .result = null,
        } } },
    };
    const imports_iface = ast.Interface{ .name = "imports", .items = &imports_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "imports" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "res" },
        .items = &.{ .{ .interface = counters_iface }, .{ .interface = imports_iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, g.generate(world, "guest"));
    try testing.expect(std.mem.indexOf(u8, g.diag, "take") != null);
    try testing.expect(std.mem.indexOf(u8, g.diag, "'c'") != null);
}

test "generate --js-imports: a mixed resource + free-function interface is rejected as a whole, not silently bridged" {
    // interface host {
    //   resource counter { … }             // never referenced by `add`
    //   add: func(a: s32, b: s32) -> s32;   // fully bridgeable on its own
    // }
    // Before the fix, this silently emitted a manifest/dispatch entry for
    // `add` and simply dropped `counter` with no diagnostic at all (the
    // per-item loop only switched on `.func`, treating `.type` as
    // `else => {}`). The whole imported interface must instead be rejected
    // deterministically, precisely because it contains a resource -- even
    // though `add` alone would satisfy `nativeBridgeSupported` and neither
    // `add`'s params/result nor its body reference `counter` at all.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const host_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "counter", .kind = .{ .resource = &.{
            .{ .kind = .method, .name = "get", .func = .{ .params = &.{}, .result = .s32 } },
        } } } },
        .{ .func = .{ .name = "add", .func = .{
            .params = &.{
                .{ .name = "a", .type = .s32 },
                .{ .name = "b", .type = .s32 },
            },
            .result = .s32,
        } } },
    };
    const host_iface = ast.Interface{ .name = "host", .items = &host_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "mixed" },
        .items = &.{ .{ .interface = host_iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, g.generate(world, "guest"));
    // Names the offending interface and resource, not the unrelated `add`.
    try testing.expect(std.mem.indexOf(u8, g.diag, "host") != null);
    try testing.expect(std.mem.indexOf(u8, g.diag, "counter") != null);
    // No JS-bridge manifest/dispatch trampoline is emitted on failure (the
    // interface's normal, unrelated typed import wrapper for `add` -- from
    // `emitImportIface`, always emitted before the `--js-imports` pass runs
    // -- is unaffected and may still appear in `g.out`; only the JS-bridge
    // artifacts must be absent).
    try testing.expect(std.mem.indexOf(u8, g.out.items, "js_import_manifest") == null);
    try testing.expect(std.mem.indexOf(u8, g.out.items, "starling_js_import_dispatch") == null);
}

test "generate --js-imports: an imported async function is a deterministic build diagnostic, not a silent skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "wait", .func = .{ .params = &.{}, .result = null, .is_async = true } } },
    };
    const iface = ast.Interface{ .name = "imports", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "imports" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "async" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, g.generate(world, "guest"));
    try testing.expect(std.mem.indexOf(u8, g.diag, "wait") != null);
}

test "generate --js-imports: two interfaces contribute independent dispatch entries and manifest lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const a_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "ping", .func = .{ .params = &.{}, .result = .bool } } },
    };
    const b_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "pong", .func = .{ .params = &.{}, .result = null } } },
    };
    const a_iface = ast.Interface{ .name = "a", .items = &a_items };
    const b_iface = ast.Interface{ .name = "b", .items = &b_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "a" } } } },
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "b" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "multi" },
        .items = &.{ .{ .interface = a_iface }, .{ .interface = b_iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(u8, out, "\"test:multi/a\\tping\\ttest:multi/a#ping\\t0\\n\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"test:multi/b\\tpong\\ttest:multi/b#pong\\t0\\n\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "if (std.mem.eql(u8, name, \"test:multi/a#ping\")) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "if (std.mem.eql(u8, name, \"test:multi/b#pong\")) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __result = a.ping();") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b.pong();") != null);
    // `pong` has no result: its dispatch arm must produce JavaScript
    // `undefined` via `encodeNative`'s own `void` tag, not a hand-rolled
    // `.tag = .bool_` (which used to decode to JS `false`) -- see the
    // dedicated round-trip test below for the C++/Zig encode contract.
    try testing.expect(std.mem.indexOf(u8, out, "js_dispatch.encodeNative(void, {}, __alloc)") != null);
    try testing.expect(std.mem.indexOf(u8, out, ".tag = .bool_") == null);
}

test "generate --js-imports: a void-result import encodes to the dedicated undefined tag, never bool/option" {
    // interface host { ack: func(); } -- no parameters, no result. JavaScript
    // calling `host.ack()` must observe `undefined`, matching
    // ComponentizeJS's canonical-ABI-void behavior; before this fix the
    // generator hard-coded `.tag = .bool_` (JS `false`) here.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "ack", .func = .{ .params = &.{}, .result = null } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "void" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(u8, out, "if (std.mem.eql(u8, name, \"test:void/host#ack\")) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "host.ack();") != null);
    try testing.expect(std.mem.indexOf(u8, out, "out_result.* = js_dispatch.encodeNative(void, {}, __alloc);") != null);
    // Never the pre-fix placeholder (JS `false`) nor an option-none
    // encoding (JS `null`) -- void must be its own tag, not borrowed from
    // either.
    try testing.expect(std.mem.indexOf(u8, out, ".tag = .bool_") == null);
    try testing.expect(std.mem.indexOf(u8, out, ".tag = .option_none") == null);
}

test "generate --js-imports: char and list<u8> (bytes) params lower through their dispatch-mode wrapper structs' real fields" {
    // Regression test for a real bug: `zigType` maps `char`/a direct
    // `list<u8>` to the wrapper structs `wit_types.Char`/`wit_types.ByteList`
    // in `--dispatch` mode (which `--js-imports` always runs in), but
    // `lowerParams`'s scalar/slice fast paths used to assume the bare
    // payload type -- emitting `@intCast(c)` (fails to compile: `c` is a
    // struct, not an int) / `b.ptr`/`b.len` (fails to compile: no such
    // field on `wit_types.ByteList`, which wraps a `bytes: []const u8`
    // field) -- a genuine Zig **compile** error caught only by actually
    // building the generated output (see tests/e2e/wit-imports/run.sh, the
    // integration test that first surfaced this), not by generation-time
    // rejection or by string-matching alone. This asserts the corrected
    // field accesses appear instead.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface host {
    //   identity-char: func(c: char) -> char;
    //   identity-bytes: func(b: list<u8>) -> list<u8>;
    // }
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "identity-char", .func = .{
            .params = &.{.{ .name = "c", .type = .char }},
            .result = .char,
        } } },
        .{ .func = .{ .name = "identity-bytes", .func = .{
            .params = &.{.{ .name = "b", .type = .{ .list = &.{ .u8 = {} } } }},
            .result = .{ .list = &.{ .u8 = {} } },
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "bytes-char" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    // Typed import wrapper: params declared with the wrapper struct types...
    try testing.expect(std.mem.indexOf(u8, out, "pub fn identityChar(c: wit_types.Char) wit_types.Char {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn identityBytes(b: wit_types.ByteList) wit_types.ByteList {") != null);
    // ...and lowered via the generic `lowerFlat` aggregate path (correct:
    // reflects into `.codepoint`/`.bytes` for free), never a direct
    // `@intCast(c)` or `c.ptr`/`c.len` on the wrapper struct itself.
    try testing.expect(std.mem.indexOf(u8, out, "const c_s = wit_types.lowerFlat(wit_types.Char, c, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const b_s = wit_types.lowerFlat(wit_types.ByteList, b, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "@intCast(c)") == null);
    try testing.expect(std.mem.indexOf(u8, out, "b.ptr") == null);
    try testing.expect(std.mem.indexOf(u8, out, "b.len") == null);

    // The JS-callable reverse bridge (decodeNative/encodeNative side) is
    // unaffected by this fix -- js_dispatch already special-cases
    // `wit_types.Char`/`wit_types.ByteList` by type identity (see
    // js_dispatch.zig's `encodeNative`/`decodeNative`) -- confirm both
    // functions are still bridged (the type-gate fix below is what allows
    // this in the first place; this test's focus is the codegen fix, so it
    // only checks the bridge entries exist, not their exact bodies).
    try testing.expect(std.mem.indexOf(u8, out, "test:bytes-char/host#identity-char") != null);
    try testing.expect(std.mem.indexOf(u8, out, "test:bytes-char/host#identity-bytes") != null);
}

test "generate --js-imports: tuple, enum, flags, variant, and result<T,E> are no longer rejected by the native-bridge type gate" {
    // Regression test for `nativeBridgeSupported`'s allow-list: before this
    // fix, every function below failed generation with
    // `error.UnsupportedWitType` (a conservative allow-list written before
    // js_dispatch.zig grew encodeNative/decodeNative support for these
    // shapes). None of these types need any *codegen* change -- the
    // generic lower/lift path (`lowerAggregateParam` / `wit_types.lift`)
    // already handles them structurally; only the gate itself was stale.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // enum color { red, green, blue }
    // flags perms { read, write, exec }
    // variant shape { circle(f64), origin }
    const color_names = [_][]const u8{ "red", "green", "blue" };
    const perms_labels = [_][]const u8{ "read", "write", "exec" };
    const f64_ty: ast.Type = .f64;
    const shape_cases = [_]ast.Case{
        .{ .name = "circle", .type = f64_ty },
        .{ .name = "origin", .type = null },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "color", .kind = .{ .@"enum" = &color_names } } },
        .{ .type = .{ .name = "perms", .kind = .{ .flags = &perms_labels } } },
        .{ .type = .{ .name = "shape", .kind = .{ .variant = &shape_cases } } },
        // color -> color (named enum, round-trip)
        .{ .func = .{ .name = "next-color", .func = .{
            .params = &.{.{ .name = "c", .type = ast.Type{ .name = "color" } }},
            .result = ast.Type{ .name = "color" },
        } } },
        // perms -> perms (named flags, round-trip)
        .{ .func = .{ .name = "toggle-perms", .func = .{
            .params = &.{.{ .name = "p", .type = ast.Type{ .name = "perms" } }},
            .result = ast.Type{ .name = "perms" },
        } } },
        // shape -> string (named variant param)
        .{ .func = .{ .name = "classify", .func = .{
            .params = &.{.{ .name = "s", .type = ast.Type{ .name = "shape" } }},
            .result = .string,
        } } },
        // tuple<u32, string> -> tuple<string, u32> (anonymous tuple, both directions)
        .{ .func = .{ .name = "swap-tuple", .func = .{
            .params = &.{.{ .name = "t", .type = .{ .tuple = &.{ .u32, .string } } }},
            .result = .{ .tuple = &.{ .string, .u32 } },
        } } },
        // result<s32, string> (anonymous result, both an ok and an err payload)
        .{ .func = .{ .name = "checked-div", .func = .{
            .params = &.{
                .{ .name = "a", .type = .s32 },
                .{ .name = "b", .type = .s32 },
            },
            .result = .{ .result = .{ .ok = &ast.Type{ .s32 = {} }, .err = &ast.Type{ .string = {} } } },
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "adv" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    // The headline assertion: generation must SUCCEED (not
    // error.UnsupportedWitType) for all five of these types.
    try g.generate(world, "guest");
    const out = g.out.items;

    // Every function actually made it into the manifest / dispatch bridge,
    // not just "didn't error" (e.g. a swallowed/skipped entry would also
    // make the call above succeed).
    try testing.expect(std.mem.indexOf(u8, out, "test:adv/host#next-color") != null);
    try testing.expect(std.mem.indexOf(u8, out, "test:adv/host#toggle-perms") != null);
    try testing.expect(std.mem.indexOf(u8, out, "test:adv/host#classify") != null);
    try testing.expect(std.mem.indexOf(u8, out, "test:adv/host#swap-tuple") != null);
    try testing.expect(std.mem.indexOf(u8, out, "test:adv/host#checked-div") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const js_import_manifest: []const u8 =") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub export fn starling_js_import_dispatch(") != null);
}

test "generate --js-imports: a directly-used >32-label flags type is a precise Gen.fail, not a bare internal error, and emits no partial manifest/dispatch output" {
    // `nativeBridgeSupported` used to accept every `flags` type
    // unconditionally, while `emitTypeDef` unconditionally rejects any
    // `flags` typedef with >32 labels via a bare `error.UnsupportedWitType`
    // (no `self.fail` detail at all) -- a contradiction: the type gate
    // claimed support that generation could never actually deliver, and the
    // resulting build failure named neither the offending type nor the
    // actual constraint. This is the direct case: a >32-label `flags` type
    // used straight as an imported function's parameter type.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // flags wide { l0, l1, …, l32 } -- 33 labels, one past the ≤32-label
    // single-packed-integer representation this generator implements.
    var labels_buf: [33][]const u8 = undefined;
    for (&labels_buf, 0..) |*l, i| l.* = std.fmt.allocPrint(ar, "l{d}", .{i}) catch @panic("OOM");
    const labels = labels_buf[0..];

    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "wide", .kind = .{ .flags = labels } } },
        .{ .func = .{ .name = "use-wide", .func = .{
            .params = &.{.{ .name = "w", .type = ast.Type{ .name = "wide" } }},
            .result = null,
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "wide-flags" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, g.generate(world, "guest"));
    // Names the offending flags type, its interface, and its actual label
    // count -- not just "UnsupportedWitType".
    try testing.expect(std.mem.indexOf(u8, g.diag, "wide") != null);
    try testing.expect(std.mem.indexOf(u8, g.diag, "host") != null);
    try testing.expect(std.mem.indexOf(u8, g.diag, "33") != null);
    // No partial JS-bridge manifest/dispatch output survives the failure.
    try testing.expect(std.mem.indexOf(u8, g.out.items, "js_import_manifest") == null);
    try testing.expect(std.mem.indexOf(u8, g.out.items, "starling_js_import_dispatch") == null);
}

test "generate --js-imports: a >32-label flags type reached only through a nested record field and an alias chain is still a precise Gen.fail" {
    // The nested/aliased case: the offending `flags` typedef is never the
    // function's own parameter type directly -- it's the field of a
    // `record`, itself reached only via a `type … = …` alias. Whatever path
    // reaches it, the underlying `flags` typedef is always its own
    // `.type` item in some interface `generate` walks (WIT has no way to
    // declare a `flags` type inline/anonymously), so `emitTypeDef` sees it
    // and must still reject it deterministically and by name -- not
    // silently accept it because it's several hops away from the function
    // signature that actually needs it.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // flags big { l0, …, l39 } (40 labels)
    var labels_buf: [40][]const u8 = undefined;
    for (&labels_buf, 0..) |*l, i| l.* = std.fmt.allocPrint(ar, "l{d}", .{i}) catch @panic("OOM");
    const labels = labels_buf[0..];

    // type big-alias = big;
    // record wrapper { p: big-alias }
    // use-wrapper: func(w: wrapper);
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "big", .kind = .{ .flags = labels } } },
        .{ .type = .{ .name = "big-alias", .kind = .{ .alias = ast.Type{ .name = "big" } } } },
        .{ .type = .{ .name = "wrapper", .kind = .{ .record = &.{
            .{ .name = "p", .type = ast.Type{ .name = "big-alias" } },
        } } } },
        .{ .func = .{ .name = "use-wrapper", .func = .{
            .params = &.{.{ .name = "w", .type = ast.Type{ .name = "wrapper" } }},
            .result = null,
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "wide-flags-nested" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, g.generate(world, "guest"));
    // Names the actual offending `flags` typedef ("big"), not the alias or
    // the record that merely reference it.
    try testing.expect(std.mem.indexOf(u8, g.diag, "big") != null);
    try testing.expect(std.mem.indexOf(u8, g.diag, "host") != null);
    try testing.expect(std.mem.indexOf(u8, g.diag, "40") != null);
    try testing.expect(std.mem.indexOf(u8, g.out.items, "js_import_manifest") == null);
    try testing.expect(std.mem.indexOf(u8, g.out.items, "starling_js_import_dispatch") == null);
}

test "generate --js-imports: exactly 32 labels is still the boundary success case, packed into a single u32" {
    // The flip side of the two tests above: ≤32 labels must keep working
    // end-to-end through the JS import bridge (manifest + dispatch entry),
    // not just "not rejected" -- and the generated backing integer is
    // exactly `u32` at the boundary (33 is the first rejected size).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    var labels_buf: [32][]const u8 = undefined;
    for (&labels_buf, 0..) |*l, i| l.* = std.fmt.allocPrint(ar, "l{d}", .{i}) catch @panic("OOM");
    const labels = labels_buf[0..];

    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "exact32", .kind = .{ .flags = labels } } },
        .{ .func = .{ .name = "use-exact32", .func = .{
            .params = &.{.{ .name = "f", .type = ast.Type{ .name = "exact32" } }},
            .result = ast.Type{ .name = "exact32" },
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "flags32" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;
    try testing.expect(std.mem.indexOf(u8, out, "pub const Exact32 = packed struct(u32) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "test:flags32/host#use-exact32") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const js_import_manifest: []const u8 =") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub export fn starling_js_import_dispatch(") != null);
}

test "generate --js-imports: option<char> lowers through wit_types.Char's real field, not @intCast(v) on the struct" {
    // Regression test for a real bug: `option<char>` passes
    // `nativeBridgeSupported`'s gate (char is individually supported), and
    // `lowerParams` routed it to the "single flat slot" fast path
    // (`lowerOptionParam`) because `flatCount(char) == 1` -- but in
    // `--dispatch` mode (which `--js-imports` always runs in), `zigType(char)`
    // is `wit_types.Char` (a `struct { codepoint: u32 }`), not a bare `u32`.
    // `lowerOptionParam` then called `scalarLowerExpr("v", .char)`, which
    // unconditionally emits `@intCast(v)` assuming `v` is already an int --
    // a genuine Zig **compile** error (`@intCast` on a struct) that
    // `nativeBridgeSupported`'s type-level gate and a plain generation-time
    // success can't catch. Confirmed against the pre-fix source (see
    // `build/bindgen/testdata/force_analysis_driver.zig` + the `gen-regress`
    // build step) that this actually fails `zig build-obj`, not just an
    // assertion here.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface host { identity-opt-char: func(c: option<char>) -> option<char>; }
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "identity-opt-char", .func = .{
            .params = &.{.{ .name = "c", .type = .{ .option = &ast.Type{ .char = {} } } }},
            .result = .{ .option = &ast.Type{ .char = {} } },
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "opt-char" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    // The typed wrapper takes/returns the wrapper struct...
    try testing.expect(std.mem.indexOf(u8, out, "pub fn identityOptChar(c: ?wit_types.Char) ?wit_types.Char {") != null);
    // ...and lowers via the generic aggregate path over the *whole*
    // `option<char>`, which reflects into `.codepoint` for free -- never a
    // direct `@intCast` on the unwrapped struct value.
    try testing.expect(std.mem.indexOf(u8, out, "const c_s = wit_types.lowerFlat(?wit_types.Char, c, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"identity-opt-char\"(c_s[0], c_s[1], wit_types.retPtr());") != null);
    // Negative control: none of the old broken fast-path shape survives --
    // `lowerOptionParam`'s hand-rolled `c_disc`/`c_0` temps (the "extern"
    // decl's own `c_disc: i32` parameter name is unrelated: `flattenSlots`
    // always names option slots that way regardless of which lowering path
    // the call site takes, so this checks the *body* shape specifically).
    try testing.expect(std.mem.indexOf(u8, out, "@intCast(v)") == null);
    try testing.expect(std.mem.indexOf(u8, out, "const c_disc: i32 = if (c != null) 1 else 0;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "const c_0:") == null);
}

test "generate --js-imports: option<enum> and option<flags> lower via the generic aggregate path, not an internal UnsupportedWitType" {
    // Regression test for a real bug: `option<enum>`/`option<flags>` pass
    // `nativeBridgeSupported`'s gate (both are unconditionally supported --
    // no payload types to recurse into), and `lowerParams` routed them to
    // the "single flat slot" fast path (`lowerOptionParam`) because
    // `flatCount` is 1 for both -- but `lowerOptionParam` then called
    // `scalarLowerExpr("v", .name(...))`, whose `switch` has no arm for a
    // named type at all, falling to `else => error.UnsupportedWitType`. So
    // despite the gate saying "supported", generation itself failed with a
    // bare, undiagnosed `error.UnsupportedWitType` -- the exact contradiction
    // `nativeBridgeSupported`'s doc comment promises never happens for
    // anything the gate accepts.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // enum color { red, green, blue }
    // flags perms { read, write, exec }
    const color_names = [_][]const u8{ "red", "green", "blue" };
    const perms_labels = [_][]const u8{ "read", "write", "exec" };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "color", .kind = .{ .@"enum" = &color_names } } },
        .{ .type = .{ .name = "perms", .kind = .{ .flags = &perms_labels } } },
        .{ .func = .{ .name = "toggle-opt-color", .func = .{
            .params = &.{.{ .name = "c", .type = .{ .option = &ast.Type{ .name = "color" } } }},
            .result = .{ .option = &ast.Type{ .name = "color" } },
        } } },
        .{ .func = .{ .name = "toggle-opt-perms", .func = .{
            .params = &.{.{ .name = "p", .type = .{ .option = &ast.Type{ .name = "perms" } } }},
            .result = .{ .option = &ast.Type{ .name = "perms" } },
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "opt-enum-flags" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    // The headline assertion: generation must SUCCEED, matching what
    // `nativeBridgeSupported` already promises for these types.
    try g.generate(world, "guest");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(u8, out, "pub fn toggleOptColor(c: ?Color) ?Color {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const c_s = wit_types.lowerFlat(?Color, c, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn toggleOptPerms(p: ?Perms) ?Perms {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const p_s = wit_types.lowerFlat(?Perms, p, &wit_types.alloc);") != null);
    // Negative control: no hand-rolled discriminant + scalar-cast temps (the
    // shape that used to hit `scalarLowerExpr`'s `else => UnsupportedWitType`
    // -- the "extern" decl's own `c_disc`/`p_disc: i32` parameter names are
    // unrelated; `flattenSlots` always names option slots that way).
    try testing.expect(std.mem.indexOf(u8, out, "const c_disc: i32 = if (c != null) 1 else 0;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "const c_0:") == null);
    try testing.expect(std.mem.indexOf(u8, out, "const p_disc: i32 = if (p != null) 1 else 0;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "const p_0:") == null);
}

test "generate --js-imports: nested single-flat-slot option payloads (alias chain, single-field record, single-element tuple) all use the generic aggregate path" {
    // Broader coverage for the same class of bug: any `option<T>` where `T`
    // flattens to one core slot but isn't literally a bare Zig int/float/
    // bool -- an alias chain resolving down to `char`/`enum`, a single-field
    // `record`, or a single-element `tuple` -- must not reach
    // `lowerOptionParam`'s scalar fast path either. A function mixing a
    // genuine scalar option (`option<u32>`) with one of these in the same
    // call also checks the two lowering paths compose correctly
    // (no argument-count/order mismatch when both appear in one call).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // enum color { red, green, blue }
    // type color-alias = color;
    // record point { x: u32 }
    const color_names = [_][]const u8{ "red", "green", "blue" };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "color", .kind = .{ .@"enum" = &color_names } } },
        .{ .type = .{ .name = "color-alias", .kind = .{ .alias = ast.Type{ .name = "color" } } } },
        .{ .type = .{ .name = "point", .kind = .{ .record = &.{
            .{ .name = "x", .type = .u32 },
        } } } },
        // option<alias to enum> -- resolveAlias must see through the alias
        // before the fast-path/aggregate-path decision.
        .{ .func = .{ .name = "opt-alias-color", .func = .{
            .params = &.{.{ .name = "c", .type = .{ .option = &ast.Type{ .name = "color-alias" } } }},
            .result = .{ .option = &ast.Type{ .name = "color-alias" } },
        } } },
        // option<single-field record>
        .{ .func = .{ .name = "opt-single-field-record", .func = .{
            .params = &.{.{ .name = "p", .type = .{ .option = &ast.Type{ .name = "point" } } }},
            .result = .{ .option = &ast.Type{ .name = "point" } },
        } } },
        // option<single-element tuple>
        .{ .func = .{ .name = "opt-single-elem-tuple", .func = .{
            .params = &.{.{ .name = "t", .type = .{ .option = &ast.Type{ .tuple = &.{.u32} } } }},
            .result = .{ .option = &ast.Type{ .tuple = &.{.u32} } },
        } } },
        // option<u32> (genuine scalar fast path) alongside option<color>
        // (generic aggregate path) in the same call.
        .{ .func = .{ .name = "mix-opt-scalar-and-color", .func = .{
            .params = &.{
                .{ .name = "n", .type = .{ .option = &ast.Type{ .u32 = {} } } },
                .{ .name = "c", .type = .{ .option = &ast.Type{ .name = "color" } } },
            },
            .result = .bool,
        } } },
    };
    const iface = ast.Interface{ .name = "host", .items = &iface_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "opt-nested" },
        .items = &.{ .{ .interface = iface }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    // Alias chain: the fast-path/aggregate decision must resolve through
    // `color-alias` down to `color` (a named enum), landing on the generic
    // aggregate path -- exactly as if the param had been declared
    // `option<color>` directly.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn optAliasColor(c: ?ColorAlias) ?ColorAlias {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const c_s = wit_types.lowerFlat(?ColorAlias, c, &wit_types.alloc);") != null);

    // Single-field record: also the generic aggregate path (a record is a
    // Zig `struct`, never a bare scalar `scalarLowerExpr` can cast).
    try testing.expect(std.mem.indexOf(u8, out, "pub fn optSingleFieldRecord(p: ?Point) ?Point {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const p_s = wit_types.lowerFlat(?Point, p, &wit_types.alloc);") != null);

    // Single-element tuple: same reasoning (`wit_types.Tuple(.{u32})` is a
    // struct wrapper, not `u32` itself).
    try testing.expect(std.mem.indexOf(u8, out, "const t_s = wit_types.lowerFlat(?wit_types.Tuple(.{ u32 }), t, &wit_types.alloc);") != null);

    // Mixed call: the genuine scalar (`option<u32>`) keeps the fast path
    // (its own `_disc`/cast temps)...
    try testing.expect(std.mem.indexOf(u8, out, "const n_disc: i32 = if (n != null) 1 else 0;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const n_0: i32 = if (n) |v| @bitCast(v) else 0;") != null);
    // ...while `option<color>` in the same call still takes the aggregate
    // path, and both sets of args are passed to the extern call in the
    // right relative order.
    try testing.expect(std.mem.indexOf(u8, out, "const c_s = wit_types.lowerFlat(?Color, c, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"mix-opt-scalar-and-color\"(n_disc, n_0, c_s[0], c_s[1])") != null);
}

test "generate: imported resource with async methods (#300)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // resource thing { constructor(id: u32); get-id: func() -> u32;
    //   bump: async func(by: u32) -> u32; label: async func() -> string;
    //   reset: async func(); }
    const thing_methods = [_]ast.ResourceMethod{
        .{ .kind = .constructor, .name = "", .func = .{ .params = &.{.{ .name = "id", .type = .u32 }}, .result = null } },
        .{ .kind = .method, .name = "get-id", .func = .{ .params = &.{}, .result = .u32 } },
        .{ .kind = .method, .name = "bump", .func = .{ .params = &.{.{ .name = "by", .type = .u32 }}, .result = .u32, .is_async = true } },
        .{ .kind = .method, .name = "label", .func = .{ .params = &.{}, .result = .string, .is_async = true } },
        .{ .kind = .method, .name = "reset", .func = .{ .params = &.{}, .result = null, .is_async = true } },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &thing_methods } } },
    };
    const iface = ast.Interface{ .name = "things", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "things" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "res" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;

    // An async method needs the wit_async driver.
    try testing.expect(std.mem.indexOf(u8, out, "const wit_async = @import(\"wit_async\");") != null);

    // Async externs: `(self?, flat params, result_ptr?) -> i32` (packed callstatus).
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.bump\"(self: i32, by: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.label\"(self: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.reset\"(self: i32) i32;") != null);

    // Async wrappers drive the subtask via awaitCall then lift from memory.
    try testing.expect(std.mem.indexOf(u8, out, "const __status = imp.@\"[method]thing.bump\"(self.handle, @bitCast(by), wit_types.retPtr());") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wit_async.awaitCall(__status);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift(u32, wit_types.retArea());") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift([]const u8, wit_types.retArea());") != null);
    // No-result async method: awaitCall, no lift.
    try testing.expect(std.mem.indexOf(u8, out, "const __status = imp.@\"[method]thing.reset\"(self.handle);") != null);

    // The sync method is unchanged (single-slot flat return).
    try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(u32, imp.@\"[method]thing.get-id\"(self.handle));") != null);
}

test "generate: async param spill past MAX_FLAT_ASYNC_PARAMS (#300)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // resource thing { openish: async func(a, name, b, c) -> u32; }   self+1+2+1+1 = 6 > 4
    // combine: async func(a, b, name, c) -> string;                   1+1+2+1   = 5 > 4
    const thing_methods = [_]ast.ResourceMethod{
        .{ .kind = .method, .name = "openish", .func = .{ .params = &.{
            .{ .name = "a", .type = .u32 },
            .{ .name = "name", .type = .string },
            .{ .name = "b", .type = .u32 },
            .{ .name = "c", .type = .u32 },
        }, .result = .u32, .is_async = true } },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &thing_methods } } },
        .{ .func = .{ .name = "combine", .func = .{ .params = &.{
            .{ .name = "a", .type = .u32 },
            .{ .name = "b", .type = .u32 },
            .{ .name = "name", .type = .string },
            .{ .name = "c", .type = .u32 },
        }, .result = .string, .is_async = true } } },
    };
    const iface = ast.Interface{ .name = "things", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "things" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "res" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;

    // Spilled method: the extern takes one args pointer (self lowers into the
    // block) + a result pointer; the wrapper lowers the whole param tuple
    // (self first) to a scratch buffer and passes the pointer.
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.openish\"(args_ptr: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __pargs = .{ self, a, name, b, c };") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __pp = wit_types.alloc(wit_types.sizeOf(@TypeOf(__pargs)), wit_types.alignOf(@TypeOf(__pargs)));") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wit_types.lower(@TypeOf(__pargs), __pargs, __pp, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[method]thing.openish\"(@intCast(@intFromPtr(__pp)), wit_types.retPtr());") != null);

    // Spilled free func: no self in the tuple.
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"combine\"(args_ptr: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __pargs = .{ a, b, name, c };") != null);
}

test "generate: async export lift (task.return)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // run:    async func() -> result        (flat result → task-return(i32))
    // double: async func(x: u32) -> u32      (param lift + flat result)
    const res_void = ast.Type{ .result = .{ .ok = null, .err = null } };
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "run", .func = .{ .params = &.{}, .result = res_void, .is_async = true } } },
        .{ .func = .{ .name = "double", .func = .{ .params = &.{.{ .name = "x", .type = .u32 }}, .result = .u32, .is_async = true } } },
    };
    const iface = ast.Interface{ .name = "run", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "run" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "p", .version = "0.1.0" },
        .items = &.{ .{ .interface = iface }, .{ .world = exp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(exp_world, "host");
    const out = g.out.items;
    // Async exports are emitted by `component new` during lifting, not bindgen.
    // The generator skips them silently so a world that also imports can still
    // generate its imports without export-shell collisions.
    try testing.expect(std.mem.indexOf(u8, out, "[task-return]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "export fn @\"local:p/run@0.1.0#run\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "export fn @\"local:p/run@0.1.0#double\"") == null);
}

test "generate: manual-return async export (--manual-return)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // handle: async func(x: u32) -> u32, requested in manual-return form. The
    // shell only dispatches to the impl (which calls handleReturn when ready and
    // may keep running afterward); the result is delivered by a pub return fn.
    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "handle", .func = .{ .params = &.{.{ .name = "x", .type = .u32 }}, .result = .u32, .is_async = true } } },
    };
    const iface = ast.Interface{ .name = "h", .items = &iface_items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "h" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "local", .name = "p", .version = "0.1.0" },
        .items = &.{ .{ .interface = iface }, .{ .world = exp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .manual_returns = &.{"handle"} };
    try g.generate(exp_world, "host");
    const out = g.out.items;
    // Async exports (including manual-return) are emitted by `component new`
    // during lifting, not bindgen — the generator skips them silently.
    try testing.expect(std.mem.indexOf(u8, out, "handleReturn") == null);
    try testing.expect(std.mem.indexOf(u8, out, "export fn @\"local:p/h@0.1.0#handle\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[task-return]") == null);
}

test "generate: async multi-slot result lifts via lowerFlat; async import via awaitCall" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // `async func() -> string` flattens to 2 slots → direct multi-slot task.return.
    const agg_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "greet", .func = .{ .params = &.{}, .result = .string, .is_async = true } } },
    };
    const agg_iface = ast.Interface{ .name = "api", .items = &agg_items };
    const agg_exp = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const agg_imp = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "a" },
        .items = &.{ .{ .interface = agg_iface }, .{ .world = agg_exp }, .{ .world = agg_imp } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(agg_exp, "host");
        const out = g.out.items;
        // Async exports are emitted by `component new` during lifting, not bindgen;
        // the generator skips them silently.
        try testing.expect(std.mem.indexOf(u8, out, "[task-return]") == null);
        try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:a/api#greet\"") == null);
    }
    {
        // Importing an async func: the extern is async-lowered (params +
        // result_ptr -> i32 status); the wrapper drives the subtask to
        // completion via wit_async.awaitCall, then lifts the result from memory.
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(agg_imp, "guest");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(u8, out, "const wit_async = @import(\"wit_async\");") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:a/api\" fn @\"greet\"(result_ptr: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "const __status = imp.@\"greet\"(wit_types.retPtr());") != null);
        try testing.expect(std.mem.indexOf(u8, out, "wit_async.awaitCall(__status);") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift([]const u8, wit_types.retArea());") != null);
    }
}

test "generate: async import with param + result (async-lower extern)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // double: async func(x: u32) -> u32;  imported.
    const items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "double", .func = .{ .params = &.{.{ .name = "x", .type = .u32 }}, .result = .u32, .is_async = true } } },
    };
    const iface = ast.Interface{ .name = "math", .items = &items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "math" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "m" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // async-lower extern: the flat param `x` precedes the result pointer; the
    // core result is the packed callstatus (i32), not the lifted u32.
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:m/math\" fn @\"double\"(x: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn double(x: u32) u32 {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __status = imp.@\"double\"(@bitCast(x), wit_types.retPtr());") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wit_async.awaitCall(__status);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift(u32, wit_types.retArea());") != null);
}

test "generate: async export with >16-slot result spills task.return to a pointer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // wide: async func() -> tuple<u32 x17>;  17 flat slots > MAX_FLAT_PARAMS (16),
    // so task.return takes a single memory pointer to the lowered result.
    const u32_ty: ast.Type = .u32;
    const wide_result = ast.Type{ .tuple = &.{
        u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty,
        u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty, u32_ty,
    } };
    const items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "wide", .func = .{ .params = &.{}, .result = wide_result, .is_async = true } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &items };
    const exp_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "w" },
        .items = &.{ .{ .interface = iface }, .{ .world = exp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(exp_world, "host");
    const out = g.out.items;
    // Async exports (including wide/spilled results) are emitted by `component new`
    // during lifting, not bindgen — the generator skips them silently.
    try testing.expect(std.mem.indexOf(u8, out, "[task-return]") == null);
    try testing.expect(std.mem.indexOf(u8, out, "export fn @\"test:w/api#wide\"") == null);
}

test "generate: future / stream / tuple in signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // resource pipe {
    //   body: func() -> tuple<stream<u8>, future<u32>>;
    //   signal: func(f: future<u32>) -> bool;
    // }
    // make-pair: func() -> tuple<u32, string>;
    const u8_ty: ast.Type = .u8;
    const u32_ty: ast.Type = .u32;
    const str_ty: ast.Type = .string;
    const stream_u8 = ast.Type{ .stream = &u8_ty };
    const future_u32 = ast.Type{ .future = &u32_ty };
    const body_result = ast.Type{ .tuple = &.{ stream_u8, future_u32 } };
    const pair_result = ast.Type{ .tuple = &.{ u32_ty, str_ty } };
    const pipe_methods = [_]ast.ResourceMethod{
        .{ .kind = .method, .name = "body", .func = .{ .params = &.{}, .result = body_result } },
        .{ .kind = .method, .name = "signal", .func = .{ .params = &.{.{ .name = "f", .type = future_u32 }}, .result = .bool } },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "pipe", .kind = .{ .resource = &pipe_methods } } },
        .{ .func = .{ .name = "make-pair", .func = .{ .params = &.{}, .result = pair_result } } },
    };
    const iface = ast.Interface{ .name = "chan", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "chan" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "fs" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // tuple<stream<u8>, future<u32>> result (indirect, lifted from memory).
    try testing.expect(std.mem.indexOf(u8, out, "pub fn body(self: Pipe) wit_types.Tuple(.{ wit_types.Stream(u8), wit_types.Future(u32) }) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "return wit_types.lift(wit_types.Tuple(.{ wit_types.Stream(u8), wit_types.Future(u32) }), wit_types.retArea());") != null);
    // future<u32> param lowers to its i32 handle.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn signal(self: Pipe, f: wit_types.Future(u32)) bool {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[method]pipe.signal\"(self.handle, f.handle)") != null);
    // free function returning tuple<u32, string>.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn makePair() wit_types.Tuple(.{ u32, []const u8 }) {") != null);
}

test "generate: complex future/stream channels (function-reference intrinsics)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface api {
    //   resource conn {
    //     open: static func(seed: future<u32>) -> future<result<u32, string>>;
    //   }
    //   sink: func(s: stream<list<u8>>) -> bool;
    // }
    // A primitive `future<u32>` param (async-idx 0) precedes the complex
    // `future<result<u32, string>>` result (async-idx 1): the complex channel
    // must bind to `#1`, exercising the appearance-order index walk. The
    // primitive channel stays `canon.Future(u32)`.
    const u8_ty: ast.Type = .u8;
    const u32_ty: ast.Type = .u32;
    const str_ty: ast.Type = .string;
    const future_u32 = ast.Type{ .future = &u32_ty };
    const res_u32_str = ast.Type{ .result = .{ .ok = &u32_ty, .err = &str_ty } };
    const cfut = ast.Type{ .future = &res_u32_str };
    const list_u8 = ast.Type{ .list = &u8_ty };
    const cstream = ast.Type{ .stream = &list_u8 };
    const conn_methods = [_]ast.ResourceMethod{
        .{ .kind = .static, .name = "open", .func = .{ .params = &.{.{ .name = "seed", .type = future_u32 }}, .result = cfut } },
    };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "conn", .kind = .{ .resource = &conn_methods } } },
        .{ .func = .{ .name = "sink", .func = .{ .params = &.{.{ .name = "s", .type = cstream }}, .result = .bool } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "x", .version = "0.1.0" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // Complex channels are shared nominal types bound to a function-reference
    // intrinsic `[future]<iface>#<fn>#<idx>` (`<fn>` is the canonical extern
    // name: a static method is `[static]conn.open`). The complex future is
    // async-idx 1 (the primitive `future<u32>` param took idx 0).
    try testing.expect(std.mem.indexOf(u8, out, "const __chan0 = wit_types.FutureOf(wit_types.Result(u32, []const u8), \"[future]demo:x/api@0.1.0#[static]conn.open#1\");") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __chan1 = wit_types.StreamOf([]const u8, \"[stream]demo:x/api@0.1.0#sink#0\");") != null);
    // The static wrapper: primitive param stays `canon.Future(u32)`; the complex
    // result is the shared nominal `__chan0`.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn open(seed: wit_types.Future(u32)) __chan0 {") != null);
    // The complex stream is a param typed as the shared nominal `__chan1`.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn sink(s: __chan1) bool {") != null);
}

test "generate: same complex channel in two interfaces binds per-interface (#295)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface a { f: func() -> future<result<u32, string>>; }
    // interface b { g: func() -> future<result<u32, string>>; }
    // A subset consumer importing only `a` must NOT pull in `b`'s intrinsic, so
    // the structurally identical channel binds to its own interface, not one
    // shared site.
    const u32_ty: ast.Type = .u32;
    const str_ty: ast.Type = .string;
    const res = ast.Type{ .result = .{ .ok = &u32_ty, .err = &str_ty } };
    const cfut = ast.Type{ .future = &res };
    const a_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "f", .func = .{ .params = &.{}, .result = cfut } } },
    };
    const b_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "g", .func = .{ .params = &.{}, .result = cfut } } },
    };
    const iface_a = ast.Interface{ .name = "a", .items = &a_items };
    const iface_b = ast.Interface{ .name = "b", .items = &b_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "a" } } } },
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "b" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "two", .version = "0.1.0" },
        .items = &.{ .{ .interface = iface_a }, .{ .interface = iface_b }, .{ .world = imp_world } },
    };
    const res2 = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res2, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // Two distinct channel types, each bound to a site in ITS OWN interface —
    // not one shared type bound only to `a`.
    try testing.expect(std.mem.indexOf(u8, out, "const __chan0 = wit_types.FutureOf(wit_types.Result(u32, []const u8), \"[future]demo:two/a@0.1.0#f#0\");") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __chan1 = wit_types.FutureOf(wit_types.Result(u32, []const u8), \"[future]demo:two/b@0.1.0#g#0\");") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn f() __chan0 {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn g() __chan1 {") != null);
}

test "generate: same-named types in two interfaces get per-interface names (#303)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface a { variant error-code { x };       f: func() -> result<u32, error-code>; }
    // interface b { variant error-code { y, z };    g: func() -> result<u32, error-code>; }
    // Both define `error-code` locally → their Zig identifiers must differ.
    const u32_ty: ast.Type = .u32;
    const a_cases = [_]ast.Case{.{ .name = "x", .type = null }};
    const b_cases = [_]ast.Case{ .{ .name = "y", .type = null }, .{ .name = "z", .type = null } };
    const ec_ref = ast.Type{ .name = "error-code" };
    const a_res = ast.Type{ .result = .{ .ok = &u32_ty, .err = &ec_ref } };
    const a_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "error-code", .kind = .{ .variant = &a_cases } } },
        .{ .func = .{ .name = "f", .func = .{ .params = &.{}, .result = a_res } } },
    };
    const b_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "error-code", .kind = .{ .variant = &b_cases } } },
        .{ .func = .{ .name = "g", .func = .{ .params = &.{}, .result = a_res } } },
    };
    const iface_a = ast.Interface{ .name = "a", .items = &a_items };
    const iface_b = ast.Interface{ .name = "b", .items = &b_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "a" } } } },
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "b" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "two", .version = "0.1.0" },
        .items = &.{ .{ .interface = iface_a }, .{ .interface = iface_b }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // Two distinct type decls, prefixed by their defining interface.
    try testing.expect(std.mem.indexOf(u8, out, "pub const AErrorCode = union(enum) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const BErrorCode = union(enum) {") != null);
    // No bare `ErrorCode` (the collision is fully disambiguated).
    try testing.expect(std.mem.indexOf(u8, out, "pub const ErrorCode = ") == null);
    // Each func's result binds to its own interface's error-code.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn f() wit_types.Result(u32, AErrorCode) {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn g() wit_types.Result(u32, BErrorCode) {") != null);
}

test "generate: option<handle> / option<scalar> params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // resource thing { }
    // set-a: func(t: option<thing>, n: option<u32>) -> bool;
    const thing_methods = [_]ast.ResourceMethod{};
    const thing_ref = ast.Type{ .name = "thing" };
    const opt_thing = ast.Type{ .option = &thing_ref };
    const u32_ty: ast.Type = .u32;
    const opt_u32 = ast.Type{ .option = &u32_ty };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &thing_methods } } },
        .{ .func = .{ .name = "set-a", .func = .{ .params = &.{ .{ .name = "t", .type = opt_thing }, .{ .name = "n", .type = opt_u32 } }, .result = .bool } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "o" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // each option lowers to a discriminant + a single (null-zeroed) payload slot.
    try testing.expect(std.mem.indexOf(u8, out, "extern \"demo:o/api\" fn @\"set-a\"(t_disc: i32, t: i32, n_disc: i32, n: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const t_0: i32 = if (t) |v| v.handle else 0;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const n_0: i32 = if (n) |v| @bitCast(v) else 0;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"set-a\"(t_disc, t_0, n_disc, n_0)") != null);
}

test "generate: aggregate params (variant / record) lower via canon.lowerFlat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // variant method { get, post, other(string) }   → disc + (ptr, len) = 3 slots
    // record point { x: u32, y: u32 }                 → 2 slots
    const str_ty: ast.Type = .string;
    const method_cases = [_]ast.Case{
        .{ .name = "get", .type = null },
        .{ .name = "post", .type = null },
        .{ .name = "other", .type = str_ty },
    };
    const point_fields = [_]ast.Field{
        .{ .name = "x", .type = .u32 },
        .{ .name = "y", .type = .u32 },
    };
    const method_ref = ast.Type{ .name = "method" };
    const point_ref = ast.Type{ .name = "point" };
    const iface_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "method", .kind = .{ .variant = &method_cases } } },
        .{ .type = .{ .name = "point", .kind = .{ .record = &point_fields } } },
        .{ .func = .{ .name = "set-method", .func = .{ .params = &.{.{ .name = "m", .type = method_ref }}, .result = .bool } } },
        .{ .func = .{ .name = "move-to", .func = .{ .params = &.{.{ .name = "p", .type = point_ref }}, .result = .u32 } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "m" },
        .items = &.{ .{ .interface = iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // variant flattens to disc + joined payload (here (ptr, len)) = 3 i32 slots.
    try testing.expect(std.mem.indexOf(u8, out, "extern \"demo:m/api\" fn @\"set-method\"(m_0: i32, m_1: i32, m_2: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const m_s = wit_types.lowerFlat(Method, m, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"set-method\"(m_s[0], m_s[1], m_s[2])") != null);
    // record flattens to its concatenated fields = 2 i32 slots.
    try testing.expect(std.mem.indexOf(u8, out, "extern \"demo:m/api\" fn @\"move-to\"(p_0: i32, p_1: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "const p_s = wit_types.lowerFlat(Point, p, &wit_types.alloc);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"move-to\"(p_s[0], p_s[1])") != null);
}

test "generate: use-imported types are indexed and emitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface base { type duration = u64; }
    // interface api  { use base.{duration}; tick: func(d: duration) -> u64; }
    const dur_ty: ast.Type = .u64;
    const base_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "duration", .kind = .{ .alias = dur_ty } } },
    };
    const base_iface = ast.Interface{ .name = "base", .items = &base_items };
    const dur_ref = ast.Type{ .name = "duration" };
    const api_items = [_]ast.InterfaceItem{
        .{ .use = .{ .from = .{ .name = "base" }, .names = &.{.{ .name = "duration" }} } },
        .{ .func = .{ .name = "tick", .func = .{ .params = &.{.{ .name = "d", .type = dur_ref }}, .result = .u64 } } },
    };
    const api_iface = ast.Interface{ .name = "api", .items = &api_items };
    const imp_world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "u" },
        .items = &.{ .{ .interface = base_iface }, .{ .interface = api_iface }, .{ .world = imp_world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(imp_world, "guest");
    const out = g.out.items;
    // the `use`d alias is emitted as a top-level typedef …
    try testing.expect(std.mem.indexOf(u8, out, "pub const Duration = u64;") != null);
    // … and resolves through to its underlying core type when used as a param.
    try testing.expect(std.mem.indexOf(u8, out, "pub fn tick(d: Duration) u64 {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "extern \"demo:u/api\" fn @\"tick\"(d: i64) i64;") != null);
}
