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
//! function-reference intrinsic `[future]<iface>#<fn>#<idx>`, and synchronous
//! JavaScript-backed exported resources in `--dispatch` mode.

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
    \\                        pub fn dropExportResource(
    \\                          comptime provider: []const u8,
    \\                          comptime resource_name: []const u8, rep: i32) void
    \\                      Mutually exclusive with --impl.
    \\                      Exported resources require this mode. Their class
    \\                      operations use `<iface>#[constructor|method|static]…`
    \\                      dispatch keys; `<iface>#[dtor]R` is an internal
    \\                      release callback, not a JavaScript method.
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
    \\                        resource:  R\t<provider>\t<name>\t<class>
    \\                        operation: C|M|S\t<provider>\t<name>\t<js-name>
    \\                                   \t<canonical-dispatch-key>\t<arity>
    \\                      The root form matches ComponentizeJS default imports.
    \\                      Requires --dispatch. Every imported function's
    \\                      parameter/result types must be within the native
    \\                      bridge's supported set (bool, integers, f32/f64,
    \\                      char, string, resources (with exact own/borrow
    \\                      ownership), option<T>, list<T>, tuple, record,
    \\                      variant, enum, <=32-label flags, and result<T,E>,
    \\                      recursively). Imported resource classes include
    \\                      constructors, methods, statics, and finalizer-driven
    \\                      canonical drops. Future/stream, error-context,
    \\                      canonical async functions, and >32-label flags fail
    \\                      deterministically rather than being skipped.
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

fn findInterfaceType(iface: ast.Interface, name: []const u8) ?ast.TypeDef {
    for (iface.items) |item| switch (item) {
        .type => |td| if (std.mem.eql(u8, td.name, name)) return td,
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
const ScopedType = struct {
    kind: ast.TypeDefKind,
    def_iface: []const u8,
    /// Original name in `def_iface`. Unlike the consumer-visible lookup key,
    /// this survives `use ... as ...` chains and identifies resources without
    /// falling back to a collision-prone bare resource name.
    def_name: []const u8,
};

/// A named type pulled in through a `use`. `scope_id` is the interface that
/// owns the type body's references, while `name` is the name emitted in Zig.
const UsedType = struct {
    name: []const u8,
    kind: ast.TypeDefKind,
    /// Scope used to resolve references in the type body.
    scope_id: []const u8,
    /// Scope used to resolve the emitted declaration's Zig identifier.
    name_scope_id: []const u8,
};

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
    // Names emitted from ≥2 defining interfaces — their Zig identifier is
    // disambiguated by the defining interface.
    colliding: std.StringHashMapUnmanaged(void) = .empty,
    // Interface basename → number of world interfaces with that basename.
    // Duplicate names such as wasi:filesystem/types and wasi:http/types need
    // package-qualified Zig namespaces and type prefixes.
    iface_name_counts: std.StringHashMapUnmanaged(usize) = .empty,
    // Package/interface disambiguator → number of canonical interfaces using
    // it. A namespace/version-qualified fallback is required when these also
    // collide.
    iface_short_name_counts: std.StringHashMapUnmanaged(usize) = .empty,
    counted_ifaces: std.StringHashMapUnmanaged(void) = .empty,
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
    // Guest-defined resources from exported interfaces, in deterministic WIT
    // declaration order. Identity is always provider + original resource name;
    // aliases and same-named resources in other providers never collapse.
    export_resources: std.ArrayListUnmanaged(ExportResource) = .empty,

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

    fn appendExportResource(self: *Gen, resource: ExportResource) GenError!void {
        for (self.export_resources.items) |existing| {
            if (std.mem.eql(u8, existing.provider, resource.provider) and
                std.mem.eql(u8, existing.name, resource.name))
            {
                return;
            }
        }
        try self.export_resources.append(self.ar, resource);
    }

    fn isExportResource(self: *Gen, provider: []const u8, name: []const u8) bool {
        for (self.export_resources.items) |resource| {
            if (std.mem.eql(u8, resource.provider, provider) and
                std.mem.eql(u8, resource.name, name))
            {
                return true;
            }
        }
        return false;
    }

    fn exportResourceTypeName(self: *Gen, resource: ExportResource) GenError![]const u8 {
        const saved = self.current_iface;
        self.current_iface = resource.provider;
        defer self.current_iface = saved;
        return self.typeName(resource.name);
    }

    const Use = struct { id: []const u8, iface: ast.Interface, is_export: bool, pkg: ?ast.PackageId };
    const TopFunc = struct { name: []const u8, func: ast.Func, is_export: bool };
    const ExportResource = struct {
        provider: []const u8,
        name: []const u8,
        methods: []const ast.ResourceMethod,
    };

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
        for (uses.items) |u| try self.noteInterface(u.id);
        for (uses.items) |u| {
            if (!u.is_export) continue;
            for (u.iface.items) |item| switch (item) {
                .type => |td| switch (td.kind) {
                    .resource => |methods| try self.appendExportResource(.{
                        .provider = u.id,
                        .name = td.name,
                        .methods = methods,
                    }),
                    else => {},
                },
                else => {},
            };
        }
        if (self.export_resources.items.len != 0 and self.dispatch == null) {
            return self.fail(
                "exported WIT resources require --dispatch so their representations can be backed by JavaScript objects",
                .{},
            );
        }

        // Index every named type so `.name` refs resolve, plus any types pulled
        // in from another interface via `use pkg:iface.{ … }` (resolved in the
        // package context of the interface that contains the `use`). World
        // items share the `$root` scope used while emitting root-function
        // wrappers, so world-local types and aliases resolve there too.
        var used_types = std.ArrayListUnmanaged(UsedType).empty;
        var world_types = std.ArrayListUnmanaged(ast.TypeDef).empty;
        // Source-interface definitions reached through a `use` are walked once
        // per interface/name pair. Their transitive named dependencies must be
        // indexed and emitted too: an alias body is resolved in the source
        // interface's scope, not in `$root`.
        var indexed_source_types = std.StringHashMapUnmanaged(void).empty;
        var emitted_used_types = std.StringHashMapUnmanaged(void).empty;
        // #303: detect names emitted from more than one interface so we can
        // disambiguate their Zig identifiers. Keyed by name → first defining
        // interface; a second distinct definer marks a collision.
        var local_def_iface = std.StringHashMapUnmanaged([]const u8).empty;
        for (world.items) |item| switch (item) {
            .type => |td| {
                try self.types.put(self.ar, td.name, td.kind);
                try self.scoped.put(self.ar, self.scopeKey("$root", td.name), .{
                    .kind = td.kind,
                    .def_iface = "$root",
                    .def_name = td.name,
                });
                try world_types.append(self.ar, td);
                const gop = try local_def_iface.getOrPut(self.ar, td.name);
                if (gop.found_existing) {
                    if (!std.mem.eql(u8, gop.value_ptr.*, "$root"))
                        try self.colliding.put(self.ar, td.name, {});
                } else gop.value_ptr.* = "$root";
            },
            .use => |use_item| {
                const hit = self.resolver.findInterfaceWithPkgCtx(use_item.from, doc_pkg) orelse continue;
                const src_ref = ast.InterfaceRef{ .name = use_item.from.name, .package = hit.pkg };
                const src_id = try ifaceId(self.ar, src_ref, doc_pkg);
                for (use_item.names) |un| {
                    try self.indexUsedType(
                        &indexed_source_types,
                        &emitted_used_types,
                        &used_types,
                        &local_def_iface,
                        "$root",
                        hit.iface,
                        hit.pkg,
                        src_id,
                        un.name,
                        un.rename,
                    );
                }
            },
            else => {},
        };
        for (uses.items) |u| {
            for (u.iface.items) |it| switch (it) {
                .type => |td| {
                    try self.types.put(self.ar, td.name, td.kind);
                    try self.scoped.put(self.ar, self.scopeKey(u.id, td.name), .{
                        .kind = td.kind,
                        .def_iface = u.id,
                        .def_name = td.name,
                    });
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
                        try self.indexUsedType(
                            &indexed_source_types,
                            &emitted_used_types,
                            &used_types,
                            &local_def_iface,
                            u.id,
                            hit.iface,
                            hit.pkg,
                            src_id,
                            un.name,
                            un.rename,
                        );
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
        for (used_types.items) |ut| switch (ut.kind) {
            .resource => |methods| for (methods) |m| {
                if (m.func.is_async) self.needs_cm_async = true;
            },
            else => {},
        };
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
        try self.registerChannels(uses.items, top_funcs.items, used_types.items);

        // ── named types (use-imported first, then locally-defined) ──
        for (used_types.items) |ut| {
            self.current_iface = ut.name_scope_id;
            const emitted_name = try self.typeName(ut.name);
            self.current_iface = ut.scope_id;
            try self.emitTypeDef(ut.scope_id, .{ .name = ut.name, .kind = ut.kind }, emitted_name);
        }
        self.current_iface = "$root";
        for (world_types.items) |td| try self.emitTypeDef("$root", td, null);
        for (uses.items) |u| {
            self.current_iface = u.id;
            for (u.iface.items) |it| switch (it) {
                .type => |td| {
                    // A resource reached through `use` is emitted under its
                    // canonical provider/name above. If that provider is also
                    // imported directly, do not emit the same Zig type twice.
                    if (td.kind == .resource and emitted_used_types.contains(self.scopeKey(u.id, td.name)))
                        continue;
                    try self.emitTypeDef(u.id, td, null);
                },
                else => {},
            };
        }
        self.current_iface = "";

        if (self.export_resources.items.len != 0) {
            try self.emitExportResourceMappers();
        }

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
        if (self.dispatch != null) {
            try self.emitJsExportManifest(uses.items, top_funcs.items);
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

    /// Queue one type imported from another interface for emission and account
    /// for its Zig name alongside ordinary interface and world definitions.
    fn queueUsedType(
        self: *Gen,
        emitted: *std.StringHashMapUnmanaged(void),
        used_types: *std.ArrayListUnmanaged(UsedType),
        local_def_iface: *std.StringHashMapUnmanaged([]const u8),
        name: []const u8,
        kind: ast.TypeDefKind,
        scope_id: []const u8,
        name_scope_id: []const u8,
    ) GenError!void {
        const key = self.scopeKey(scope_id, name);
        if (emitted.contains(key)) return;
        try emitted.put(self.ar, key, {});
        try used_types.append(self.ar, .{
            .name = name,
            .kind = kind,
            .scope_id = scope_id,
            .name_scope_id = name_scope_id,
        });

        const gop = try local_def_iface.getOrPut(self.ar, name);
        if (gop.found_existing) {
            if (!std.mem.eql(u8, gop.value_ptr.*, scope_id))
                try self.colliding.put(self.ar, name, {});
        } else gop.value_ptr.* = scope_id;
    }

    /// Index one `use` name and expose it in the consuming scope while keeping
    /// the source interface's canonical type identity through rename chains.
    fn indexUsedType(
        self: *Gen,
        indexed: *std.StringHashMapUnmanaged(void),
        emitted: *std.StringHashMapUnmanaged(void),
        used_types: *std.ArrayListUnmanaged(UsedType),
        local_def_iface: *std.StringHashMapUnmanaged([]const u8),
        consumer_scope: []const u8,
        source_iface: ast.Interface,
        source_pkg: ?ast.PackageId,
        source_id: []const u8,
        source_name: []const u8,
        rename: ?[]const u8,
    ) GenError!void {
        try self.indexSourceType(
            indexed,
            emitted,
            used_types,
            local_def_iface,
            source_iface,
            source_pkg,
            source_id,
            source_name,
            false,
        );
        const source = self.scoped.get(self.scopeKey(source_id, source_name)) orelse
            return error.UnknownType;
        const local = rename orelse source_name;
        try self.scoped.put(self.ar, self.scopeKey(consumer_scope, local), source);
        try self.types.put(self.ar, local, source.kind);

        if (source.kind == .resource) {
            try self.indexSourceType(
                indexed,
                emitted,
                used_types,
                local_def_iface,
                source_iface,
                source_pkg,
                source_id,
                source_name,
                true,
            );
            if (!std.mem.eql(u8, local, source_name)) {
                try self.queueUsedType(
                    emitted,
                    used_types,
                    local_def_iface,
                    local,
                    .{ .alias = .{ .name = source_name } },
                    source_id,
                    consumer_scope,
                );
            }
        } else {
            try self.queueUsedType(
                emitted,
                used_types,
                local_def_iface,
                local,
                source.kind,
                source.def_iface,
                consumer_scope,
            );
        }
    }

    /// Index a type from the interface that owns its definition. If a selected
    /// `use`d type is an alias/record/variant referring to other named types,
    /// those source-scope dependencies are recursively indexed and queued for
    /// emission before the selected alias is emitted in its consumer's scope.
    fn indexSourceType(
        self: *Gen,
        indexed: *std.StringHashMapUnmanaged(void),
        emitted: *std.StringHashMapUnmanaged(void),
        used_types: *std.ArrayListUnmanaged(UsedType),
        local_def_iface: *std.StringHashMapUnmanaged([]const u8),
        iface: ast.Interface,
        iface_pkg: ?ast.PackageId,
        iface_id: []const u8,
        name: []const u8,
        emit: bool,
    ) GenError!void {
        try self.noteInterface(iface_id);
        const td = findInterfaceType(iface, name) orelse {
            for (iface.items) |item| switch (item) {
                .use => |use_item| {
                    for (use_item.names) |un| {
                        const local = un.rename orelse un.name;
                        if (!std.mem.eql(u8, local, name)) continue;

                        const hit = self.resolver.findInterfaceWithPkgCtx(use_item.from, iface_pkg) orelse
                            return error.UnknownInterface;
                        const src_ref = ast.InterfaceRef{ .name = use_item.from.name, .package = hit.pkg };
                        const src_id = try ifaceId(self.ar, src_ref, self.resolver.main.package);
                        try self.indexSourceType(
                            indexed,
                            emitted,
                            used_types,
                            local_def_iface,
                            hit.iface,
                            hit.pkg,
                            src_id,
                            un.name,
                            false,
                        );
                        const source = self.scoped.get(self.scopeKey(src_id, un.name)) orelse
                            return error.UnknownType;
                        try self.scoped.put(self.ar, self.scopeKey(iface_id, local), source);
                        try self.types.put(self.ar, local, source.kind);

                        if (!emit) return;
                        if (source.kind == .resource) {
                            try self.indexSourceType(
                                indexed,
                                emitted,
                                used_types,
                                local_def_iface,
                                hit.iface,
                                hit.pkg,
                                src_id,
                                un.name,
                                true,
                            );
                            if (!std.mem.eql(u8, local, un.name)) {
                                try self.queueUsedType(
                                    emitted,
                                    used_types,
                                    local_def_iface,
                                    local,
                                    .{ .alias = .{ .name = un.name } },
                                    src_id,
                                    iface_id,
                                );
                            }
                        } else {
                            try self.queueUsedType(
                                emitted,
                                used_types,
                                local_def_iface,
                                local,
                                source.kind,
                                source.def_iface,
                                iface_id,
                            );
                        }
                        return;
                    }
                },
                else => {},
            };
            return;
        };
        const key = self.scopeKey(iface_id, name);
        if (!indexed.contains(key)) {
            try indexed.put(self.ar, key, {});
            try self.scoped.put(self.ar, key, .{
                .kind = td.kind,
                .def_iface = iface_id,
                .def_name = td.name,
            });
            try self.types.put(self.ar, name, td.kind);
            try self.indexTypeDefDependencies(
                indexed,
                emitted,
                used_types,
                local_def_iface,
                iface,
                iface_pkg,
                iface_id,
                td.kind,
            );
        }
        if (emit) try self.queueUsedType(emitted, used_types, local_def_iface, td.name, td.kind, iface_id, iface_id);
    }

    fn indexTypeDefDependencies(
        self: *Gen,
        indexed: *std.StringHashMapUnmanaged(void),
        emitted: *std.StringHashMapUnmanaged(void),
        used_types: *std.ArrayListUnmanaged(UsedType),
        local_def_iface: *std.StringHashMapUnmanaged([]const u8),
        iface: ast.Interface,
        iface_pkg: ?ast.PackageId,
        iface_id: []const u8,
        kind: ast.TypeDefKind,
    ) GenError!void {
        switch (kind) {
            .record => |fields| for (fields) |field| {
                try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, field.type);
            },
            .variant => |cases| for (cases) |case| {
                if (case.type) |ty| {
                    try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, ty);
                }
            },
            .alias => |ty| try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, ty),
            .resource => |methods| for (methods) |method| {
                for (method.func.params) |param| {
                    try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, param.type);
                }
                if (method.func.result) |result| {
                    try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, result);
                }
            },
            .@"enum", .flags => {},
        }
    }

    fn indexTypeDependencies(
        self: *Gen,
        indexed: *std.StringHashMapUnmanaged(void),
        emitted: *std.StringHashMapUnmanaged(void),
        used_types: *std.ArrayListUnmanaged(UsedType),
        local_def_iface: *std.StringHashMapUnmanaged([]const u8),
        iface: ast.Interface,
        iface_pkg: ?ast.PackageId,
        iface_id: []const u8,
        ty: ast.Type,
    ) GenError!void {
        switch (ty) {
            .option, .list => |element| {
                try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, element.*);
            },
            .result => |result| {
                if (result.ok) |ok| {
                    try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, ok.*);
                }
                if (result.err) |err| {
                    try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, err.*);
                }
            },
            .tuple => |elements| for (elements) |element| {
                try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, element);
            },
            .future, .stream => |element| {
                if (element) |value| {
                    try self.indexTypeDependencies(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, value.*);
                }
            },
            .name, .own, .borrow => |name| {
                try self.indexSourceType(indexed, emitted, used_types, local_def_iface, iface, iface_pkg, iface_id, name, true);
            },
            else => {},
        }
    }

    // ── type emission ────────────────────────────────────────────────

    fn emitTypeDef(self: *Gen, iface_id: []const u8, td: ast.TypeDef, name_override: ?[]const u8) GenError!void {
        const type_name = name_override orelse try self.typeName(td.name);
        switch (td.kind) {
            .record => |fields| {
                self.print("pub const {s} = struct {{\n", .{type_name});
                for (fields) |f| {
                    self.print("    {s}: {s},\n", .{ try snake(self.ar, f.name), try self.zigType(f.type) });
                }
                self.raw("};\n\n");
            },
            .@"enum" => |cases| {
                self.print("pub const {s} = enum {{\n", .{type_name});
                for (cases) |c| self.print("    {s},\n", .{try snake(self.ar, c)});
                self.raw("};\n\n");
            },
            .variant => |cases| {
                self.print("pub const {s} = union(enum) {{\n", .{type_name});
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
                self.print("pub const {s} = packed struct(u{d}) {{\n", .{ type_name, bits });
                for (labels) |l| self.print("    {s}: bool = false,\n", .{try snake(self.ar, l)});
                if (bits > labels.len) self.print("    _padding: u{d} = 0,\n", .{bits - labels.len});
                self.raw("};\n\n");
            },
            .alias => |t| {
                self.print("pub const {s} = {s};\n\n", .{ type_name, try self.zigType(t) });
            },
            .resource => try self.emitResource(iface_id, td, type_name),
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
            .own => |r| try std.fmt.allocPrint(self.ar, "wit_types.Own({s})", .{try self.typeName(r)}),
            .borrow => |r| try std.fmt.allocPrint(self.ar, "wit_types.Borrow({s})", .{try self.typeName(r)}),
            .name => |n| blk: {
                const name = try self.typeName(n);
                if (self.typeKind(n)) |kind| {
                    if (kind == .resource)
                        break :blk try std.fmt.allocPrint(self.ar, "wit_types.Own({s})", .{name});
                }
                break :blk name;
            },
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

    /// Emit the exact core export names dispatched to JavaScript. The host
    /// runtime consumes this manifest after module evaluation to reject a
    /// missing namespace/member or non-callable export before snapshot/AOT
    /// publication. Keep this in dispatch mode only: `--impl` worlds do not
    /// resolve their implementations from a JavaScript module namespace.
    fn emitJsExportManifest(self: *Gen, uses: []const Use, top_funcs: []const TopFunc) GenError!void {
        var count: usize = 0;
        for (uses) |u| {
            if (!u.is_export) continue;
            for (u.iface.items) |it| switch (it) {
                .func => |fd| if (!fd.func.is_async) {
                    count += 1;
                },
                else => {},
            };
        }
        for (top_funcs) |tf| {
            if (tf.is_export and !tf.func.is_async) count += 1;
        }
        count += self.export_resources.items.len;
        if (count == 0) return;

        self.raw(
            \\// Exact dispatch keys for componentization-time JavaScript export validation.
            \\// "I\t<interface-id>#<function>\n" preserves named-interface topology;
            \\// "R\t<function>\n" identifies a world-level root export.
            \\// JavaScript-backed exported resources use direction-explicit records:
            \\// "ER\t<provider>\t<resource>\t<class>\n"
            \\// "EC|EM|ES\t<provider>\t<resource>\t<js-name>\t<dispatch-key>\t<arity>\n"
            \\// "ED\t<provider>\t<resource>\t<dispatch-key>\n"
            \\pub const js_export_manifest: []const u8 =
            \\
        );
        for (uses) |u| {
            if (!u.is_export) continue;
            for (u.iface.items) |it| switch (it) {
                .func => |fd| {
                    if (fd.func.is_async) continue;
                    self.print("    \"I\\t{s}#{s}\\n\" ++\n", .{ u.id, fd.name });
                },
                else => {},
            };
        }
        for (self.export_resources.items) |resource| {
            const class_name = try pascal(self.ar, resource.name);
            self.print(
                "    \"ER\\t{s}\\t{s}\\t{s}\\n\" ++\n",
                .{ resource.provider, resource.name, class_name },
            );
            for (resource.methods) |method| {
                const tag: []const u8 = switch (method.kind) {
                    .constructor => "EC",
                    .method => "EM",
                    .static => "ES",
                };
                const js_name = if (method.kind == .constructor)
                    class_name
                else
                    try camel(self.ar, method.name);
                const operation = try self.resourceExternName(resource.name, method);
                self.print(
                    "    \"{s}\\t{s}\\t{s}\\t{s}\\t{s}#{s}\\t{d}\\n\" ++\n",
                    .{
                        tag,
                        resource.provider,
                        resource.name,
                        js_name,
                        resource.provider,
                        operation,
                        method.func.params.len,
                    },
                );
            }
            self.print(
                "    \"ED\\t{s}\\t{s}\\t{s}#[dtor]{s}\\n\" ++\n",
                .{ resource.provider, resource.name, resource.provider, resource.name },
            );
        }
        for (top_funcs) |tf| {
            if (tf.is_export and !tf.func.is_async) {
                self.print("    \"R\\t{s}\\n\" ++\n", .{tf.name});
            }
        }
        self.raw(
            \\    "";
            \\
            \\pub export fn starling_js_exports_manifest(out_len: *usize) callconv(.c) [*]const u8 {
            \\    out_len.* = js_export_manifest.len;
            \\    return js_export_manifest.ptr;
            \\}
            \\
            \\
        );
    }

    fn emitExportIface(self: *Gen, u: Use) GenError!void {
        self.current_iface = u.id;
        self.print("// exports: {s}\n", .{u.id});
        for (u.iface.items) |it| switch (it) {
            .func => |fd| try self.emitExportFunc(u.id, fd.name, fd.func),
            .type => |td| switch (td.kind) {
                .resource => try self.emitExportResourceOperations(u.id, td),
                else => {},
            },
            else => {},
        };
        self.raw("\n");
    }

    fn emitExportResourceOperations(
        self: *Gen,
        iface_id: []const u8,
        td: ast.TypeDef,
    ) GenError!void {
        const R = try self.typeName(td.name);
        for (td.kind.resource) |method| {
            try self.emitExportResourceOperation(iface_id, td.name, R, method);
        }
        try self.emitExportResourceDtor(iface_id, td.name);
    }

    fn validateExportResourceOperation(
        self: *Gen,
        iface_id: []const u8,
        resource_name: []const u8,
        method: ast.ResourceMethod,
    ) GenError!void {
        const operation = try self.resourceExternName(resource_name, method);
        const context = try std.fmt.allocPrint(
            self.ar,
            "exported resource operation '{s}#{s}'",
            .{ iface_id, operation },
        );
        if (method.func.is_async) {
            return self.fail(
                "{s} cannot be dispatched to JavaScript: canonical async resource operations are not supported",
                .{context},
            );
        }
        for (method.func.params) |param| {
            if (!try self.nativeBridgeSupported(param.type)) {
                return self.fail(
                    "{s}: parameter '{s}' has a WIT type not supported by JavaScript resource dispatch",
                    .{ context, param.name },
                );
            }
        }
        if (method.func.result) |result| {
            if (!try self.nativeBridgeSupported(result)) {
                return self.fail(
                    "{s}: its result has a WIT type not supported by JavaScript resource dispatch",
                    .{context},
                );
            }
            if (try self.typeContainsExportBorrow(self.current_iface, result)) {
                return self.fail(
                    "{s}: borrowed exported resources cannot be returned",
                    .{context},
                );
            }
        }
    }

    fn emitExportResourceOperation(
        self: *Gen,
        iface_id: []const u8,
        resource_name: []const u8,
        R: []const u8,
        method: ast.ResourceMethod,
    ) GenError!void {
        try self.validateExportResourceOperation(iface_id, resource_name, method);
        const operation = try self.resourceExternName(resource_name, method);
        const export_sym = try std.fmt.allocPrint(self.ar, "{s}#{s}", .{ iface_id, operation });
        const result_zig = if (method.kind == .constructor)
            try std.fmt.allocPrint(self.ar, "wit_types.Own({s})", .{R})
        else
            try self.resultZig(method.func);

        self.print("export fn @\"{s}\"(", .{export_sym});
        if (method.kind == .method) {
            self.raw("self: i32");
            if (method.func.params.len != 0) self.raw(", ");
        }
        try self.emitFlatParamDecls(method.func.params);
        self.print(") wit_types.CoreReturn({s}) {{\n", .{result_zig});
        self.raw("    wit_types.resetScratch();\n");

        if (method.kind == .method) {
            self.print(
                "    const __self = {s}.Borrowed{{ .handle = self }};\n",
                .{R},
            );
        }
        try self.emitLiftParams(method.func.params);
        if (method.func.params.len != 0) {
            self.raw(
                "    const __dispatch_params = wit_types.mapResources(@TypeOf(__params), __params, __wit_lift_export_resource, &wit_types.alloc);\n",
            );
            self.raw(
                "    _ = wit_types.mapResources(@TypeOf(__dispatch_params), __dispatch_params, __wit_prepare_export_resource, &wit_types.alloc);\n",
            );
            self.raw(
                "    _ = wit_types.mapResources(@TypeOf(__params), __params, __wit_consume_export_resource, &wit_types.alloc);\n",
            );
        }

        const args = try self.implArgListFrom(method.func.params, "__dispatch_params");
        var dispatch_args = std.ArrayListUnmanaged(u8).empty;
        try dispatch_args.appendSlice(self.ar, ".{ ");
        if (method.kind == .method) try dispatch_args.appendSlice(self.ar, "__self");
        if (args.len != 0) {
            if (method.kind == .method) try dispatch_args.appendSlice(self.ar, ", ");
            try dispatch_args.appendSlice(self.ar, args);
        }
        try dispatch_args.appendSlice(self.ar, " }");

        const has_result = method.kind == .constructor or method.func.result != null;
        if (!has_result) {
            self.print(
                "    __wit_dispatch.call(\"{s}\", void, {s});\n",
                .{ export_sym, dispatch_args.items },
            );
            self.raw("    return;\n");
        } else {
            self.print(
                "    const __result = __wit_dispatch.call(\"{s}\", {s}, {s});\n",
                .{ export_sym, result_zig, dispatch_args.items },
            );
            self.print(
                "    const __canonical_result = wit_types.mapResources({s}, __result, __wit_lower_export_resource, &wit_types.alloc);\n",
                .{result_zig},
            );
            self.print(
                "    __wit_dispatch.completeNativeResult({s}, __result);\n",
                .{result_zig},
            );
            self.print(
                "    return wit_types.returnResult({s}, __canonical_result, &wit_types.alloc);\n",
                .{result_zig},
            );
        }
        self.raw("}\n\n");
    }

    fn emitExportResourceDtor(
        self: *Gen,
        iface_id: []const u8,
        resource_name: []const u8,
    ) GenError!void {
        const export_sym = try std.fmt.allocPrint(
            self.ar,
            "{s}#[dtor]{s}",
            .{ iface_id, resource_name },
        );
        self.print("export fn @\"{s}\"(rep: i32) void {{\n", .{export_sym});
        // resource-drop can invoke this synchronously while its caller still
        // holds a scratch-backed nested result, so a dtor must not reset it.
        self.print(
            "    __wit_dispatch.dropExportResource(\"{s}\", \"{s}\", rep);\n",
            .{ iface_id, resource_name },
        );
        self.raw("}\n\n");
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
        if (func.result) |result| {
            if (try self.typeContainsExportBorrow(self.current_iface, result)) {
                return self.fail(
                    "exported function '{s}' cannot return a borrowed exported resource",
                    .{export_sym},
                );
            }
        }
        const result_zig = try self.resultZig(func);

        self.print("export fn @\"{s}\"(", .{export_sym});
        try self.emitFlatParamDecls(func.params);
        self.print(") wit_types.CoreReturn({s}) {{\n", .{result_zig});
        self.raw("    wit_types.resetScratch();\n");

        try self.emitLiftParams(func.params);

        // Call the user implementation or generic dispatcher, then encode the result.
        const map_resources = self.dispatch != null and self.export_resources.items.len != 0;
        if (map_resources and func.params.len != 0) {
            self.raw(
                "    const __dispatch_params = wit_types.mapResources(@TypeOf(__params), __params, __wit_lift_export_resource, &wit_types.alloc);\n",
            );
            self.raw(
                "    _ = wit_types.mapResources(@TypeOf(__dispatch_params), __dispatch_params, __wit_prepare_export_resource, &wit_types.alloc);\n",
            );
            self.raw(
                "    _ = wit_types.mapResources(@TypeOf(__params), __params, __wit_consume_export_resource, &wit_types.alloc);\n",
            );
        }
        const args = try self.implArgListFrom(
            func.params,
            if (map_resources) "__dispatch_params" else "__params",
        );
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
                    "    const __result = __wit_dispatch.call(\"{s}\", {s}, {s});\n",
                    .{ export_sym, result_zig, dispatch_args },
                );
                if (map_resources) {
                    self.print(
                        "    const __canonical_result = wit_types.mapResources({s}, __result, __wit_lower_export_resource, &wit_types.alloc);\n",
                        .{result_zig},
                    );
                    self.print(
                        "    __wit_dispatch.completeNativeResult({s}, __result);\n",
                        .{result_zig},
                    );
                }
                self.print(
                    "    return wit_types.returnResult({s}, {s}, &wit_types.alloc);\n",
                    .{ result_zig, if (map_resources) "__canonical_result" else "__result" },
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

    fn implArgListFrom(
        self: *Gen,
        params: []const ast.Param,
        base: []const u8,
    ) GenError![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        for (params, 0..) |p, idx| {
            if (idx != 0) try buf.appendSlice(self.ar, ", ");
            try buf.appendSlice(self.ar, base);
            try buf.append(self.ar, '.');
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
        return self.emitAsyncSpillWithPrefix(params, self_field, "");
    }

    fn emitAsyncSpillWithPrefix(
        self: *Gen,
        params: []const ast.Param,
        self_field: ?[]const u8,
        prefix: []const u8,
    ) GenError![]const u8 {
        self.raw("        const __pargs = .{ ");
        var first = true;
        if (self_field) |sf| {
            self.raw(sf);
            first = false;
        }
        for (params) |p| {
            if (!first) self.raw(", ");
            first = false;
            self.print("{s}{s}", .{ prefix, try snake(self.ar, p.name) });
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
    // `starling_js_imports_manifest` byte string so the host runtime can
    // discover which builtin ES modules/functions and resource classes to
    // synthesize without per-world C++ glue. Ordinary functions retain the
    // original four-column TSV record. Uppercase-tagged R/C/M/S records
    // declare a resource class and its constructor/method/static operations;
    // uppercase is outside WIT's module-id grammar, keeping the extension
    // unambiguous. Resource operation dispatch keys are their canonical core
    // field names qualified by the exact provider interface. Interface
    // functions retain their `<iface-id>` module and verbatim function export.
    // A root function `foo` uses module `foo`, export `default`, and dispatch
    // key `$root#foo`, matching ComponentizeJS 0.21.
    //
    // Resource arguments are all decoded before `commitNativeResources`
    // atomically transfers any nested own handles. Method receivers decode as
    // Borrow(Resource), constructors/results retain Own(Resource), and a
    // strong `starling_js_resource_drop` routes generation-safe finalizer
    // requests to exactly one canonical `[resource-drop]` extern by matching
    // the generated ResourceDescriptor's provider/name pair.
    //
    // A function whose signature includes a type the native bridge doesn't
    // cover (future/stream or error-context) is a deterministic
    // `error.UnsupportedWitType` generation failure (via `fail`, naming the
    // offending function/type) rather than a silently-missing JS export --
    // see `nativeBridgeSupported`. Canonical async imports and future/stream
    // resource operations are explicitly rejected because ComponentizeJS
    // 0.21 rejects those canonical async types; they are not silently skipped.

    /// Whether `ty`'s type graph is entirely within the set `js_dispatch`'s
    /// `NativeValue` encode/decode pair supports: `bool`/integers/`f32`/`f64`,
    /// `char`, `string`, `option<T>`, `list<T>` (including `list<u8>`,
    /// bridged as `wit_types.ByteList`), `tuple`, `record`, `variant`,
    /// `enum`, `flags` with ≤32 labels, resource handles with their exact
    /// provider-qualified identity and own/borrow mode, and `result<T,E>`
    /// (recursively, for any of those). Everything else -- `future`/`stream`,
    /// `error-context`, and a `flags` type with >32 labels (multiword `flags`,
    /// which `emitTypeDef` itself doesn't generate -- see its doc comment) --
    /// is unsupported. This matches the Zig-type cases `encodeNative`/
    /// `decodeNative` implement in `js_dispatch.zig`; keep this in sync with
    /// that switch if it ever grows.
    fn nativeBridgeSupportedIn(self: *Gen, scope: []const u8, ty: ast.Type) GenError!bool {
        const saved = self.current_iface;
        self.current_iface = scope;
        defer self.current_iface = saved;
        return self.nativeBridgeSupported(ty);
    }

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
                const info = self.scoped.get(self.scopeKey(self.current_iface, n)) orelse
                    return error.UnknownType;
                break :blk switch (info.kind) {
                    .record => |fields| r: {
                        for (fields) |f| {
                            if (!try self.nativeBridgeSupportedIn(info.def_iface, f.type)) break :r false;
                        }
                        break :r true;
                    },
                    .alias => |t| try self.nativeBridgeSupportedIn(info.def_iface, t),
                    .variant => |cases| r: {
                        for (cases) |c| {
                            if (c.type) |t| {
                                if (!try self.nativeBridgeSupportedIn(info.def_iface, t)) break :r false;
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
                    .resource => true,
                };
            },
            .own, .borrow => |n| (try self.resolveBridgeResource(self.current_iface, n)) != null,
            // ComponentizeJS 0.21 rejects canonical async value types, and
            // error-context has no JavaScript bridge representation.
            else => false,
        };
    }

    const JsBridgeResource = struct {
        provider: []const u8,
        name: []const u8,
        zig_type: []const u8,
        methods: []const ast.ResourceMethod,
    };

    /// Resolve a resource through the current scope's aliases and `use`
    /// renames. The returned provider/name always comes from the defining
    /// resource declaration, never from a consumer-visible alias.
    fn resolveBridgeResource(self: *Gen, scope: []const u8, name: []const u8) GenError!?JsBridgeResource {
        const info = self.scoped.get(self.scopeKey(scope, name)) orelse return error.UnknownType;
        return switch (info.kind) {
            .resource => |methods| blk: {
                const saved = self.current_iface;
                self.current_iface = info.def_iface;
                defer self.current_iface = saved;
                break :blk .{
                    .provider = info.def_iface,
                    .name = info.def_name,
                    .zig_type = try self.typeName(info.def_name),
                    .methods = methods,
                };
            },
            .alias => |ty| switch (ty) {
                .name, .own, .borrow => |target| try self.resolveBridgeResource(info.def_iface, target),
                else => null,
            },
            else => null,
        };
    }

    fn appendBridgeResource(
        self: *Gen,
        resources: *std.ArrayListUnmanaged(JsBridgeResource),
        seen_resources: *std.StringHashMapUnmanaged(void),
        resource: JsBridgeResource,
    ) GenError!void {
        const key = self.scopeKey(resource.provider, resource.name);
        if (seen_resources.contains(key)) return;
        try seen_resources.put(self.ar, key, {});
        try resources.append(self.ar, resource);
    }

    /// Collect every resource in `ty`'s supported aggregate graph while
    /// retaining the scope in which named references must be resolved.
    fn collectBridgeResourcesFromType(
        self: *Gen,
        scope: []const u8,
        ty: ast.Type,
        resources: *std.ArrayListUnmanaged(JsBridgeResource),
        seen_resources: *std.StringHashMapUnmanaged(void),
        seen_types: *std.StringHashMapUnmanaged(void),
    ) GenError!void {
        switch (ty) {
            .list, .option => |element| try self.collectBridgeResourcesFromType(
                scope,
                element.*,
                resources,
                seen_resources,
                seen_types,
            ),
            .result => |result| {
                if (result.ok) |ok| try self.collectBridgeResourcesFromType(
                    scope,
                    ok.*,
                    resources,
                    seen_resources,
                    seen_types,
                );
                if (result.err) |err| try self.collectBridgeResourcesFromType(
                    scope,
                    err.*,
                    resources,
                    seen_resources,
                    seen_types,
                );
            },
            .tuple => |elements| for (elements) |element| {
                try self.collectBridgeResourcesFromType(
                    scope,
                    element,
                    resources,
                    seen_resources,
                    seen_types,
                );
            },
            .future, .stream => |element| if (element) |value| {
                try self.collectBridgeResourcesFromType(
                    scope,
                    value.*,
                    resources,
                    seen_resources,
                    seen_types,
                );
            },
            .name, .own, .borrow => |name| {
                if (try self.resolveBridgeResource(scope, name)) |resource| {
                    try self.appendBridgeResource(resources, seen_resources, resource);
                    return;
                }
                const key = self.scopeKey(scope, name);
                if (seen_types.contains(key)) return;
                try seen_types.put(self.ar, key, {});
                const info = self.scoped.get(key) orelse return error.UnknownType;
                switch (info.kind) {
                    .record => |fields| for (fields) |field| {
                        try self.collectBridgeResourcesFromType(
                            info.def_iface,
                            field.type,
                            resources,
                            seen_resources,
                            seen_types,
                        );
                    },
                    .variant => |cases| for (cases) |case| {
                        if (case.type) |case_type| try self.collectBridgeResourcesFromType(
                            info.def_iface,
                            case_type,
                            resources,
                            seen_resources,
                            seen_types,
                        );
                    },
                    .alias => |target| try self.collectBridgeResourcesFromType(
                        info.def_iface,
                        target,
                        resources,
                        seen_resources,
                        seen_types,
                    ),
                    .resource, .@"enum", .flags => {},
                }
            },
            else => {},
        }
    }

    fn typeContainsResource(self: *Gen, scope: []const u8, ty: ast.Type) GenError!bool {
        return switch (ty) {
            .list, .option => |element| try self.typeContainsResource(scope, element.*),
            .result => |result| blk: {
                if (result.ok) |ok| {
                    if (try self.typeContainsResource(scope, ok.*)) break :blk true;
                }
                if (result.err) |err| {
                    if (try self.typeContainsResource(scope, err.*)) break :blk true;
                }
                break :blk false;
            },
            .tuple => |elements| blk: {
                for (elements) |element| {
                    if (try self.typeContainsResource(scope, element)) break :blk true;
                }
                break :blk false;
            },
            .name, .own, .borrow => |name| blk: {
                if ((try self.resolveBridgeResource(scope, name)) != null) break :blk true;
                const info = self.scoped.get(self.scopeKey(scope, name)) orelse return error.UnknownType;
                break :blk switch (info.kind) {
                    .record => |fields| r: {
                        for (fields) |field| {
                            if (try self.typeContainsResource(info.def_iface, field.type)) break :r true;
                        }
                        break :r false;
                    },
                    .variant => |cases| r: {
                        for (cases) |case| {
                            if (case.type) |case_type| {
                                if (try self.typeContainsResource(info.def_iface, case_type)) break :r true;
                            }
                        }
                        break :r false;
                    },
                    .alias => |target| try self.typeContainsResource(info.def_iface, target),
                    .resource => true,
                    .@"enum", .flags => false,
                };
            },
            else => false,
        };
    }

    fn typeContainsExportBorrow(
        self: *Gen,
        scope: []const u8,
        ty: ast.Type,
    ) GenError!bool {
        return switch (ty) {
            .list, .option => |element| try self.typeContainsExportBorrow(scope, element.*),
            .result => |result| blk: {
                if (result.ok) |ok| {
                    if (try self.typeContainsExportBorrow(scope, ok.*)) break :blk true;
                }
                if (result.err) |err| {
                    if (try self.typeContainsExportBorrow(scope, err.*)) break :blk true;
                }
                break :blk false;
            },
            .tuple => |elements| blk: {
                for (elements) |element| {
                    if (try self.typeContainsExportBorrow(scope, element)) break :blk true;
                }
                break :blk false;
            },
            .borrow => |name| blk: {
                const resource = try self.resolveBridgeResource(scope, name) orelse
                    break :blk false;
                break :blk self.isExportResource(resource.provider, resource.name);
            },
            .name => |name| blk: {
                const info = self.scoped.get(self.scopeKey(scope, name)) orelse
                    return error.UnknownType;
                break :blk switch (info.kind) {
                    .record => |fields| r: {
                        for (fields) |field| {
                            if (try self.typeContainsExportBorrow(info.def_iface, field.type))
                                break :r true;
                        }
                        break :r false;
                    },
                    .variant => |cases| r: {
                        for (cases) |case| {
                            if (case.type) |case_type| {
                                if (try self.typeContainsExportBorrow(info.def_iface, case_type))
                                    break :r true;
                            }
                        }
                        break :r false;
                    },
                    .alias => |target| try self.typeContainsExportBorrow(info.def_iface, target),
                    .resource, .@"enum", .flags => false,
                };
            },
            else => false,
        };
    }

    const JsImportEntry = struct {
        manifest_kind: []const u8,
        module: []const u8,
        resource_name: []const u8,
        js_name: []const u8,
        dispatch_key: []const u8,
        manifest_arity: usize,
        call_target: []const u8,
        param_ziq: []const []const u8,
        result_zig: []const u8,
        has_result: bool,
        has_resource_params: bool,
    };

    fn validateJsBridgeFunc(self: *Gen, context: []const u8, func: ast.Func) GenError!void {
        if (func.is_async) {
            return self.fail(
                "{s} cannot be bridged to JavaScript: canonical async functions are explicitly " ++
                    "unsupported because ComponentizeJS 0.21 rejects canonical async types",
                .{context},
            );
        }
        for (func.params) |param| {
            if (!try self.nativeBridgeSupported(param.type)) {
                return self.fail(
                    "{s}: parameter '{s}' has a WIT type not supported by the JS import bridge " ++
                        "(supported recursively: bool/integers/f32/f64/char/string/resources with " ++
                        "exact own/borrow ownership/option<T>/list<T>/tuple/record/variant/enum/" ++
                        "flags (≤32 labels)/result<T,E>; future/stream, error-context, and >32-label " ++
                        "multiword flags remain explicitly unsupported)",
                    .{ context, param.name },
                );
            }
        }
        if (func.result) |result| {
            if (!try self.nativeBridgeSupported(result)) {
                return self.fail(
                    "{s}: its result has a WIT type not supported by the JS import bridge " ++
                        "(supported recursively: bool/integers/f32/f64/char/string/resources with " ++
                        "exact own/borrow ownership/option<T>/list<T>/tuple/record/variant/enum/" ++
                        "flags (≤32 labels)/result<T,E>; future/stream, error-context, and >32-label " ++
                        "multiword flags remain explicitly unsupported)",
                    .{context},
                );
            }
        }
    }

    fn emitJsImportBridge(self: *Gen, uses: []const Use, top_funcs: []const TopFunc) GenError!void {
        var entries = std.ArrayListUnmanaged(JsImportEntry).empty;
        var resources = std.ArrayListUnmanaged(JsBridgeResource).empty;
        var seen_resources = std.StringHashMapUnmanaged(void).empty;
        var seen_types = std.StringHashMapUnmanaged(void).empty;

        // Discover resources from each imported interface's complete type
        // surface and function signatures. Resolution uses `ScopedType`'s
        // defining provider/name, so aliases and transitive `use` chains
        // cannot accidentally bind to another provider's same-named resource.
        for (uses) |u| {
            if (u.is_export) continue;
            self.current_iface = u.id;
            for (u.iface.items) |it| switch (it) {
                .type => |td| try self.collectBridgeResourcesFromType(
                    u.id,
                    .{ .name = td.name },
                    &resources,
                    &seen_resources,
                    &seen_types,
                ),
                .func => |fd| {
                    for (fd.func.params) |param| try self.collectBridgeResourcesFromType(
                        u.id,
                        param.type,
                        &resources,
                        &seen_resources,
                        &seen_types,
                    );
                    if (fd.func.result) |result| try self.collectBridgeResourcesFromType(
                        u.id,
                        result,
                        &resources,
                        &seen_resources,
                        &seen_types,
                    );
                },
                else => {},
            };
        }
        for (top_funcs) |tf| {
            if (tf.is_export) continue;
            for (tf.func.params) |param| try self.collectBridgeResourcesFromType(
                "$root",
                param.type,
                &resources,
                &seen_resources,
                &seen_types,
            );
            if (tf.func.result) |result| try self.collectBridgeResourcesFromType(
                "$root",
                result,
                &resources,
                &seen_resources,
                &seen_types,
            );
        }

        // Resource methods may themselves mention resources from other
        // providers. Walk to a fixed point so all such transitive identities
        // receive class metadata and exact drop routing.
        var resource_index: usize = 0;
        while (resource_index < resources.items.len) : (resource_index += 1) {
            const resource = resources.items[resource_index];
            for (resource.methods) |method| {
                for (method.func.params) |param| try self.collectBridgeResourcesFromType(
                    resource.provider,
                    param.type,
                    &resources,
                    &seen_resources,
                    &seen_types,
                );
                if (method.func.result) |result| try self.collectBridgeResourcesFromType(
                    resource.provider,
                    result,
                    &resources,
                    &seen_resources,
                    &seen_types,
                );
            }
        }

        // Resource operations use canonical core field names as dispatch keys.
        // A method's implicit receiver is decoded as Borrow(Resource), while a
        // constructor produces Own(Resource); neither ownership mode is
        // structurally collapsed.
        for (resources.items) |resource| {
            self.current_iface = resource.provider;
            for (resource.methods) |method| {
                const extern_name = try self.resourceExternName(resource.name, method);
                const dispatch_key = try std.fmt.allocPrint(
                    self.ar,
                    "{s}#{s}",
                    .{ resource.provider, extern_name },
                );
                const context = try std.fmt.allocPrint(
                    self.ar,
                    "imported resource operation '{s}'",
                    .{dispatch_key},
                );
                try self.validateJsBridgeFunc(context, method.func);

                var param_ziq = std.ArrayListUnmanaged([]const u8).empty;
                var has_resource_params = method.kind == .method;
                if (method.kind == .method) try param_ziq.append(
                    self.ar,
                    try std.fmt.allocPrint(
                        self.ar,
                        "wit_types.Borrow({s})",
                        .{resource.zig_type},
                    ),
                );
                for (method.func.params) |param| {
                    try param_ziq.append(self.ar, try self.zigType(param.type));
                    has_resource_params = has_resource_params or
                        try self.typeContainsResource(resource.provider, param.type);
                }

                const manifest_kind: []const u8 = switch (method.kind) {
                    .constructor => "C",
                    .method => "M",
                    .static => "S",
                };
                const js_name = switch (method.kind) {
                    .constructor => try pascal(self.ar, resource.name),
                    .method, .static => try camel(self.ar, method.name),
                };
                const call_target = switch (method.kind) {
                    .constructor => try std.fmt.allocPrint(
                        self.ar,
                        "{s}.init",
                        .{resource.zig_type},
                    ),
                    .method => try std.fmt.allocPrint(
                        self.ar,
                        "{s}.Borrowed.{s}",
                        .{ resource.zig_type, try camel(self.ar, method.name) },
                    ),
                    .static => try std.fmt.allocPrint(
                        self.ar,
                        "{s}.{s}",
                        .{ resource.zig_type, try camel(self.ar, method.name) },
                    ),
                };
                const result_zig = if (method.kind == .constructor)
                    try std.fmt.allocPrint(self.ar, "wit_types.Own({s})", .{resource.zig_type})
                else
                    try self.resultZig(method.func);
                try entries.append(self.ar, .{
                    .manifest_kind = manifest_kind,
                    .module = resource.provider,
                    .resource_name = resource.name,
                    .js_name = js_name,
                    .dispatch_key = dispatch_key,
                    .manifest_arity = method.func.params.len,
                    .call_target = call_target,
                    .param_ziq = param_ziq.items,
                    .result_zig = result_zig,
                    .has_result = method.kind == .constructor or method.func.result != null,
                    .has_resource_params = has_resource_params,
                });
            }
        }

        for (uses) |u| {
            if (u.is_export) continue;
            self.current_iface = u.id;
            for (u.iface.items) |it| switch (it) {
                .func => |fd| {
                    const context = try std.fmt.allocPrint(
                        self.ar,
                        "imported function '{s}#{s}'",
                        .{ u.id, fd.name },
                    );
                    try self.validateJsBridgeFunc(context, fd.func);
                    var param_ziq = std.ArrayListUnmanaged([]const u8).empty;
                    var has_resource_params = false;
                    for (fd.func.params) |param| {
                        try param_ziq.append(self.ar, try self.zigType(param.type));
                        has_resource_params = has_resource_params or
                            try self.typeContainsResource(u.id, param.type);
                    }
                    try entries.append(self.ar, .{
                        .manifest_kind = "F",
                        .module = u.id,
                        .resource_name = "",
                        .js_name = fd.name,
                        .dispatch_key = try std.fmt.allocPrint(self.ar, "{s}#{s}", .{ u.id, fd.name }),
                        .manifest_arity = fd.func.params.len,
                        .call_target = try std.fmt.allocPrint(
                            self.ar,
                            "{s}.{s}",
                            .{ try self.interfaceModuleName(u.id), try camel(self.ar, fd.name) },
                        ),
                        .param_ziq = param_ziq.items,
                        .result_zig = try self.resultZig(fd.func),
                        .has_result = fd.func.result != null,
                        .has_resource_params = has_resource_params,
                    });
                },
                else => {},
            };
        }
        self.current_iface = "$root";
        for (top_funcs) |tf| {
            if (tf.is_export) continue;
            const context = try std.fmt.allocPrint(
                self.ar,
                "imported root function '{s}'",
                .{tf.name},
            );
            try self.validateJsBridgeFunc(context, tf.func);
            var param_ziq = std.ArrayListUnmanaged([]const u8).empty;
            var has_resource_params = false;
            for (tf.func.params) |param| {
                try param_ziq.append(self.ar, try self.zigType(param.type));
                has_resource_params = has_resource_params or
                    try self.typeContainsResource("$root", param.type);
            }
            try entries.append(self.ar, .{
                .manifest_kind = "F",
                .module = tf.name,
                .resource_name = "",
                .js_name = "default",
                .dispatch_key = try std.fmt.allocPrint(self.ar, "$root#{s}", .{tf.name}),
                .manifest_arity = tf.func.params.len,
                .call_target = try camel(self.ar, tf.name),
                .param_ziq = param_ziq.items,
                .result_zig = try self.resultZig(tf.func),
                .has_result = tf.func.result != null,
                .has_resource_params = has_resource_params,
            });
        }
        self.current_iface = "";
        if (entries.items.len == 0 and resources.items.len == 0) return;

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
            \\// Generated for `--js-imports`. Ordinary function records retain the
            \\// backwards-compatible four-column form:
            \\//   "<module>\t<js-name>\t<dispatch-key>\t<arity>\n"
            \\// Resource records begin with an uppercase tag (not a legal WIT module
            \\// id), so they cannot collide with the legacy form:
            \\//   "R\t<provider>\t<resource>\t<class-name>\n"
            \\//   "C|M|S\t<provider>\t<resource>\t<js-name>\t<dispatch-key>\t<arity>\n"
            \\// C/M/S identify constructor, prototype method, and static method.
            \\// Resource dispatch keys use the exact canonical core field spelling
            \\// (<provider>#[constructor|method|static]...), preserving provider identity.
            \\pub const js_import_manifest: []const u8 =
            \\
        );

        for (resources.items) |resource| {
            self.print(
                "    \"R\\t{s}\\t{s}\\t{s}\\n\" ++\n",
                .{ resource.provider, resource.name, try pascal(self.ar, resource.name) },
            );
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.manifest_kind, "F") or
                    !std.mem.eql(u8, entry.module, resource.provider) or
                    !std.mem.eql(u8, entry.resource_name, resource.name))
                {
                    continue;
                }
                self.print(
                    "    \"{s}\\t{s}\\t{s}\\t{s}\\t{s}\\t{d}\\n\" ++\n",
                    .{
                        entry.manifest_kind,
                        entry.module,
                        entry.resource_name,
                        entry.js_name,
                        entry.dispatch_key,
                        entry.manifest_arity,
                    },
                );
            }
        }
        for (entries.items) |entry| {
            if (!std.mem.eql(u8, entry.manifest_kind, "F")) continue;
            self.print(
                "    \"{s}\\t{s}\\t{s}\\t{d}\\n\" ++\n",
                .{ entry.module, entry.js_name, entry.dispatch_key, entry.manifest_arity },
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

        if (resources.items.len != 0) {
            self.raw(
                \\pub export fn starling_js_resource_drop(
                \\    provider_ptr: [*]const u8,
                \\    provider_len: usize,
                \\    name_ptr: [*]const u8,
                \\    name_len: usize,
                \\    handle: i32,
                \\) callconv(.c) u32 {
                \\    const provider = provider_ptr[0..provider_len];
                \\    const resource_name = name_ptr[0..name_len];
                \\
            );
            for (resources.items) |resource| {
                self.print(
                    "    if (std.mem.eql(u8, provider, {s}.__wit_resource.provider) and\n",
                    .{resource.zig_type},
                );
                self.print(
                    "        std.mem.eql(u8, resource_name, {s}.__wit_resource.name)) {{\n",
                    .{resource.zig_type},
                );
                self.print("        {s}.__wit_drop(handle);\n", .{resource.zig_type});
                self.raw("        return 0;\n");
                self.raw("    }\n");
            }
            self.raw(
                \\    return 1;
                \\}
                \\
                \\
            );
        }

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
            if (e.has_resource_params) {
                self.print("        const __decoded_args = .{{ {s} }};\n", .{call_args.items});
                self.raw(
                    \\        const __native_args = js_dispatch.NativeValue{
                    \\            .tag = .list_,
                    \\            .list_ptr = argv_ptr,
                    \\            .list_len = argv_len,
                    \\        };
                    \\        if (!js_dispatch.commitNativeResources(
                    \\            @TypeOf(__decoded_args),
                    \\            __decoded_args,
                    \\            &__native_args,
                    \\            __alloc,
                    \\        )) @panic("js import dispatch: resource transfer transaction failed");
                    \\
                );
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
    fn emitResource(self: *Gen, iface_id: []const u8, td: ast.TypeDef, R: []const u8) GenError!void {
        if (self.isExportResource(iface_id, td.name)) {
            return self.emitExportResourceType(iface_id, td.name, R);
        }
        const methods = td.kind.resource;

        self.print("pub const {s} = struct {{\n", .{R});
        self.raw("    handle: i32,\n\n");
        self.print(
            "    pub const __wit_resource = wit_types.ResourceDescriptor{{ .provider = \"{s}\", .name = \"{s}\" }};\n",
            .{ iface_id, td.name },
        );
        self.raw("    pub const __wit_resource_ownership: wit_types.ResourceOwnership = .own;\n\n");

        self.raw("    const imp = struct {\n");
        for (methods) |m| try self.emitResourceExtern(iface_id, td.name, m);
        self.print("        extern \"{s}\" fn @\"[resource-drop]{s}\"(self: i32) void;\n", .{ iface_id, td.name });
        self.raw("    };\n\n");

        self.raw("    pub const Borrowed = struct {\n");
        self.raw("        handle: i32,\n\n");
        self.print(
            "        pub const __wit_resource = wit_types.ResourceDescriptor{{ .provider = \"{s}\", .name = \"{s}\" }};\n",
            .{ iface_id, td.name },
        );
        self.raw("        pub const __wit_resource_ownership: wit_types.ResourceOwnership = .borrow;\n\n");
        for (methods) |m| {
            if (m.kind == .method) try self.emitBorrowedResourceMethod(R, m);
        }
        self.raw("    };\n\n");

        self.print("    pub fn __wit_borrow(self: {s}) Borrowed {{\n", .{R});
        self.raw("        return .{ .handle = self.handle };\n");
        self.raw("    }\n\n");

        for (methods) |m| try self.emitResourceWrapper(R, td.name, m);

        self.raw("    pub fn __wit_drop(handle: i32) void {\n");
        self.print("        imp.@\"[resource-drop]{s}\"(handle);\n", .{td.name});
        self.raw("    }\n\n");

        self.print("    pub fn deinit(self: {s}) void {{\n", .{R});
        self.raw("        __wit_drop(self.handle);\n");
        self.raw("    }\n");
        self.raw("};\n\n");
    }

    /// Emit the nominal representation type for a JavaScript-backed resource
    /// defined by a guest export. Its `.handle` stores the runtime's stable rep
    /// id, never an imported-resource host handle. Canonical handles cross the
    /// component boundary only through the three `[export]<iface>` intrinsics.
    fn emitExportResourceType(
        self: *Gen,
        iface_id: []const u8,
        resource_name: []const u8,
        R: []const u8,
    ) GenError!void {
        self.print("pub const {s} = struct {{\n", .{R});
        self.raw("    handle: i32,\n\n");
        self.print(
            "    pub const __wit_resource = wit_types.ResourceDescriptor{{ .provider = \"{s}\", .name = \"{s}\" }};\n",
            .{ iface_id, resource_name },
        );
        self.raw("    pub const __wit_resource_ownership: wit_types.ResourceOwnership = .own;\n");
        self.raw("    pub const ResourceType = @This();\n\n");

        self.raw("    const imp = struct {\n");
        self.print(
            "        extern \"[export]{s}\" fn @\"[resource-new]{s}\"(rep: i32) i32;\n",
            .{ iface_id, resource_name },
        );
        self.print(
            "        extern \"[export]{s}\" fn @\"[resource-rep]{s}\"(handle: i32) i32;\n",
            .{ iface_id, resource_name },
        );
        self.print(
            "        extern \"[export]{s}\" fn @\"[resource-drop]{s}\"(handle: i32) void;\n",
            .{ iface_id, resource_name },
        );
        self.raw("    };\n\n");

        self.raw("    pub const Borrowed = struct {\n");
        self.raw("        handle: i32,\n\n");
        self.print(
            "        pub const __wit_resource = wit_types.ResourceDescriptor{{ .provider = \"{s}\", .name = \"{s}\" }};\n",
            .{ iface_id, resource_name },
        );
        self.raw("        pub const __wit_resource_ownership: wit_types.ResourceOwnership = .borrow;\n");
        self.print("        pub const ResourceType = {s};\n", .{R});
        self.raw("    };\n\n");

        self.print("    pub fn __wit_borrow(self: {s}) Borrowed {{\n", .{R});
        self.raw("        return .{ .handle = self.handle };\n");
        self.raw("    }\n\n");
        self.raw("    pub fn __wit_new(rep: i32) i32 {\n");
        self.print("        return imp.@\"[resource-new]{s}\"(rep);\n", .{resource_name});
        self.raw("    }\n\n");
        self.raw("    pub fn __wit_rep(handle: i32) i32 {\n");
        self.print("        return imp.@\"[resource-rep]{s}\"(handle);\n", .{resource_name});
        self.raw("    }\n\n");
        self.raw("    pub fn __wit_drop(handle: i32) void {\n");
        self.print("        imp.@\"[resource-drop]{s}\"(handle);\n", .{resource_name});
        self.raw("    }\n");
        self.raw("};\n\n");
    }

    /// Emit the provider-qualified callbacks used by
    /// `wit_types.mapResources`. Incoming canonical handles become reps before
    /// JavaScript dispatch; returned owned reps become fresh canonical handles;
    /// incoming owned handles are pinned across their pre-dispatch canonical
    /// drop, while borrows remain live.
    fn emitExportResourceMappers(self: *Gen) GenError!void {
        self.raw(
            \\fn __wit_lift_export_resource(comptime T: type, value: T) T {
            \\    const info = comptime wit_types.resourceInfo(T).?;
            \\
        );
        for (self.export_resources.items) |resource| {
            const R = try self.exportResourceTypeName(resource);
            self.print(
                "    if (comptime {s}.__wit_resource.eql(info.descriptor)) {{\n",
                .{R},
            );
            self.print(
                "        return .{{ .handle = if (comptime info.ownership == .own) {s}.__wit_rep(value.handle) else value.handle }};\n",
                .{R},
            );
            self.raw("    }\n");
        }
        self.raw(
            \\    return value;
            \\}
            \\
            \\fn __wit_prepare_export_resource(comptime T: type, value: T) T {
            \\    const info = comptime wit_types.resourceInfo(T).?;
            \\
        );
        for (self.export_resources.items) |resource| {
            const R = try self.exportResourceTypeName(resource);
            self.print(
                "    if (comptime {s}.__wit_resource.eql(info.descriptor)) {{\n",
                .{R},
            );
            self.raw("        if (comptime info.ownership == .own) {\n");
            self.print(
                "            __wit_dispatch.prepareExportResourceOwn(\"{s}\", \"{s}\", value.handle);\n",
                .{ resource.provider, resource.name },
            );
            self.raw("        }\n");
            self.raw("        return value;\n");
            self.raw("    }\n");
        }
        self.raw(
            \\    return value;
            \\}
            \\
            \\fn __wit_lower_export_resource(comptime T: type, value: T) T {
            \\    const info = comptime wit_types.resourceInfo(T).?;
            \\
        );
        for (self.export_resources.items) |resource| {
            const R = try self.exportResourceTypeName(resource);
            self.print(
                "    if (comptime {s}.__wit_resource.eql(info.descriptor)) {{\n",
                .{R},
            );
            self.raw(
                \\        if (comptime info.ownership != .own) {
                \\            @compileError("borrowed exported resources cannot be returned");
                \\        }
                \\
            );
            self.print("        return .{{ .handle = {s}.__wit_new(value.handle) }};\n", .{R});
            self.raw("    }\n");
        }
        self.raw(
            \\    return value;
            \\}
            \\
            \\fn __wit_consume_export_resource(comptime T: type, value: T) T {
            \\    const info = comptime wit_types.resourceInfo(T).?;
            \\
        );
        for (self.export_resources.items) |resource| {
            const R = try self.exportResourceTypeName(resource);
            self.print(
                "    if (comptime {s}.__wit_resource.eql(info.descriptor)) {{\n",
                .{R},
            );
            self.raw("        if (comptime info.ownership == .own) {\n");
            self.print("            {s}.__wit_drop(value.handle);\n", .{R});
            self.raw("        }\n");
            self.raw("        return value;\n");
            self.raw("    }\n");
        }
        self.raw(
            \\    return value;
            \\}
            \\
            \\
        );
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
                self.print("arg_{s}: {s}", .{ s.name, @tagName(s.core) });
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

    /// Emit a borrowed receiver method that delegates to the owned wrapper's
    /// method implementation without exposing an owned value to the caller.
    fn emitBorrowedResourceMethod(self: *Gen, R: []const u8, m: ast.ResourceMethod) GenError!void {
        std.debug.assert(m.kind == .method);
        const name = try camel(self.ar, m.name);

        self.print("        pub fn {s}(self: Borrowed", .{name});
        if (m.func.params.len > 0) self.raw(", ");
        try self.emitTypedParamDeclsWithPrefix(m.func.params, "arg_");
        self.print(") {s} {{\n", .{try self.resultZig(m.func)});
        self.print("            return ({s}{{ .handle = self.handle }}).{s}(", .{ R, name });
        for (m.func.params, 0..) |p, idx| {
            if (idx != 0) self.raw(", ");
            self.print("arg_{s}", .{try snake(self.ar, p.name)});
        }
        self.raw(");\n");
        self.raw("        }\n");
    }

    /// Emit the `extern` for an **async** resource method/static: the canonical
    /// async lowering yields `(self?, flat params, result_ptr if any) -> i32`
    /// (the packed callstatus); the result is written to `result_ptr`. `self`
    /// (for a method) counts toward the `MAX_FLAT_ASYNC_PARAMS` (4) budget;
    /// beyond it the params (including `self`) spill to a single pointer. An
    /// async constructor (not used by WASI 0.3) is rejected.
    fn emitAsyncResourceExtern(self: *Gen, iface_id: []const u8, ext: []const u8, m: ast.ResourceMethod) GenError!void {
        const func = m.func;
        if (m.kind == .constructor) {
            if (self.js_imports) {
                return self.fail(
                    "imported resource operation '{s}#{s}' cannot be bridged to JavaScript: " ++
                        "canonical async constructors are explicitly unsupported because " ++
                        "ComponentizeJS 0.21 rejects canonical async types",
                    .{ iface_id, ext },
                );
            }
            return error.UnsupportedWitType;
        }
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
                self.print("arg_{s}: {s}", .{ s.name, @tagName(s.core) });
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
        try self.emitTypedParamDeclsWithPrefix(func.params, "arg_");
        if (m.kind == .constructor) {
            self.print(") wit_types.Own({s}) {{\n", .{R});
        } else {
            self.print(") {s} {{\n", .{try self.resultZig(func)});
        }

        // lower params → arg expressions (emitting temps as needed)
        const call_args = try self.lowerParamsWithPrefix(func.params, "arg_");
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
        try self.emitTypedParamDeclsWithPrefix(func.params, "arg_");
        self.print(") {s} {{\n", .{try self.resultZig(func)});

        // lower params → arg expressions (emitting temps / a spilled block).
        const args = if (spill)
            try self.emitAsyncSpillWithPrefix(
                func.params,
                if (is_method) "self" else null,
                "arg_",
            )
        else blk: {
            const call_args = try self.lowerParamsWithPrefix(func.params, "arg_");
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

    fn noteInterface(self: *Gen, iface_id: []const u8) GenError!void {
        if (self.counted_ifaces.contains(iface_id)) return;
        try self.counted_ifaces.put(self.ar, iface_id, {});
        const gop = try self.iface_name_counts.getOrPut(self.ar, ifaceBaseName(iface_id));
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }

        const short_name = self.packageInterfaceDisambiguator(iface_id);
        const short_gop = try self.iface_short_name_counts.getOrPut(self.ar, short_name);
        if (short_gop.found_existing) {
            short_gop.value_ptr.* += 1;
        } else {
            short_gop.value_ptr.* = 1;
        }
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
        // Root-function types use the internal `$root` scope. Its name is not
        // a valid Zig identifier when a world type collides with an interface
        // type, so normalize it before it becomes a type-name prefix.
        if (std.mem.eql(u8, iface_id, "$root")) return "root";
        const base = ifaceBaseName(iface_id);
        if ((self.iface_name_counts.get(base) orelse 0) < 2) return base;

        const short_name = self.packageInterfaceDisambiguator(iface_id);
        if ((self.iface_short_name_counts.get(short_name) orelse 0) < 2)
            return short_name;

        var full_name = std.ArrayListUnmanaged(u8).empty;
        var separator = false;
        for (iface_id) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                if (separator and full_name.items.len != 0)
                    full_name.append(self.ar, '-') catch @panic("OOM");
                full_name.append(self.ar, std.ascii.toLower(c)) catch @panic("OOM");
                separator = false;
            } else {
                separator = true;
            }
        }
        return full_name.toOwnedSlice(self.ar) catch @panic("OOM");
    }

    fn packageInterfaceDisambiguator(self: *Gen, iface_id: []const u8) []const u8 {
        const base = ifaceBaseName(iface_id);
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
    fn registerChannels(
        self: *Gen,
        uses: []const Use,
        top_funcs: []const TopFunc,
        used_types: []const UsedType,
    ) GenError!void {
        for (used_types) |ut| switch (ut.kind) {
            .resource => |methods| {
                self.current_iface = ut.scope_id;
                for (methods) |m| {
                    try self.registerFuncChannels(
                        ut.scope_id,
                        try self.resourceExternName(ut.name, m),
                        m.func,
                    );
                }
            },
            else => {},
        };
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
        self.current_iface = "$root";
        for (top_funcs) |tf| {
            if (!tf.is_export) try self.registerFuncChannels("$root", tf.name, tf.func);
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
        return self.lowerParamsWithPrefix(params, "");
    }

    fn lowerParamsWithPrefix(
        self: *Gen,
        params: []const ast.Param,
        prefix: []const u8,
    ) GenError![]const u8 {
        var args = std.ArrayListUnmanaged(u8).empty;
        for (params) |p| {
            const pn = try std.fmt.allocPrint(
                self.ar,
                "{s}{s}",
                .{ prefix, try snake(self.ar, p.name) },
            );
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
        return self.emitTypedParamDeclsWithPrefix(params, "");
    }

    fn emitTypedParamDeclsWithPrefix(
        self: *Gen,
        params: []const ast.Param,
        prefix: []const u8,
    ) GenError!void {
        for (params, 0..) |p, idx| {
            if (idx != 0) self.raw(", ");
            self.print("{s}{s}: {s}", .{
                prefix,
                try snake(self.ar, p.name),
                try self.zigType(p.type),
            });
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

    var counted = Gen{
        .ar = a,
        .resolver = undefined,
        .impl = "impl",
    };
    try counted.noteInterface("wasi:filesystem/types@0.2.10");
    try counted.noteInterface("wasi:http/types@0.2.10");
    try counted.noteInterface("wasi:http/types@0.2.10");
    try testing.expectEqual(@as(usize, 2), counted.iface_name_counts.get("types").?);

    var namespace_collision = Gen{
        .ar = a,
        .resolver = undefined,
        .impl = "impl",
    };
    try namespace_collision.noteInterface("acme:common/types@1.0.0");
    try namespace_collision.noteInterface("contoso:common/types@2.0.0");
    try testing.expectEqualStrings(
        "acme_common_types_1_0_0",
        try namespace_collision.interfaceModuleName("acme:common/types@1.0.0"),
    );
    try testing.expectEqualStrings(
        "contoso_common_types_2_0_0",
        try namespace_collision.interfaceModuleName("contoso:common/types@2.0.0"),
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
            .params = &.{.{ .name = "p", .type = point_ref }},
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
        .{ .func = .{ .name = "transfer", .func = .{
            .params = &.{.{ .name = "value", .type = .{ .own = "counter" } }},
            .result = .{ .own = "counter" },
        } } },
        .{ .func = .{ .name = "inspect", .func = .{
            .params = &.{.{ .name = "value", .type = .{ .borrow = "counter" } }},
            .result = .u32,
        } } },
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
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "pub const __wit_resource = wit_types.ResourceDescriptor{ .provider = \"test:res/counters\", .name = \"counter\" };",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "pub const __wit_resource_ownership: wit_types.ResourceOwnership = .own;",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub const Borrowed = struct {") != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "pub const __wit_resource_ownership: wit_types.ResourceOwnership = .borrow;",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn __wit_borrow(self: Counter) Borrowed {") != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "pub fn increment(self: Borrowed, arg_by: u32) u32 {",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "return (Counter{ .handle = self.handle }).increment(arg_by);",
        ) != null);
        // canonical resource externs (module = iface id).
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[constructor]counter\"(arg_start: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[method]counter.increment\"(self: i32, arg_by: i32) i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[static]counter.make-zero\"() i32;") != null);
        try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/counters\" fn @\"[resource-drop]counter\"(self: i32) void;") != null);
        // typed wrappers.
        try testing.expect(std.mem.indexOf(u8, out, "pub fn init(arg_start: u32) wit_types.Own(Counter) {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return .{ .handle = imp.@\"[constructor]counter\"(@bitCast(arg_start)) };") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn increment(self: Counter, arg_by: u32) u32 {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[method]counter.increment\"(self.handle, @bitCast(arg_by))") != null);
        // a static returning own<counter> lifts the handle into the wrapper struct.
        try testing.expect(std.mem.indexOf(u8, out, "pub fn makeZero() wit_types.Own(Counter) {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "return wit_types.liftResultFlat(wit_types.Own(Counter), imp.@\"[static]counter.make-zero\"());") != null);
        // Explicit own/borrow modes stay nominally distinct while both lower
        // to the same one-i32 canonical handle.
        try testing.expect(std.mem.indexOf(u8, out, "pub fn transfer(value: wit_types.Own(Counter)) wit_types.Own(Counter) {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"transfer\"(value.handle)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn inspect(value: wit_types.Borrow(Counter)) u32 {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"inspect\"(value.handle)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn __wit_drop(handle: i32) void {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[resource-drop]counter\"(handle);") != null);
        try testing.expect(std.mem.indexOf(u8, out, "pub fn deinit(self: Counter) void {") != null);
        try testing.expect(std.mem.indexOf(u8, out, "__wit_drop(self.handle);") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try testing.expectError(error.UnsupportedWitType, g.generate(exp_world, "host"));
        try testing.expect(std.mem.indexOf(u8, g.diag, "require --dispatch") != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
        try g.generate(exp_world, "host");
        const out = g.out.items;

        try testing.expect(std.mem.indexOf(u8, out, "pub const Counter = struct {") != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "extern \"[export]test:res/counters\" fn @\"[resource-new]counter\"(rep: i32) i32;",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "extern \"[export]test:res/counters\" fn @\"[resource-rep]counter\"(handle: i32) i32;",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "extern \"[export]test:res/counters\" fn @\"[resource-drop]counter\"(handle: i32) void;",
        ) != null);

        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "export fn @\"test:res/counters#[constructor]counter\"(start: i32) wit_types.CoreReturn(wit_types.Own(Counter))",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:res/counters#[constructor]counter\", wit_types.Own(Counter), .{ __dispatch_params.start })",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "const __canonical_result = wit_types.mapResources(wit_types.Own(Counter), __result, __wit_lower_export_resource, &wit_types.alloc);",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "export fn @\"test:res/counters#[method]counter.increment\"(self: i32, by: i32) wit_types.CoreReturn(u32)",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "const __self = Counter.Borrowed{ .handle = self };",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "if (comptime info.ownership == .own) Counter.__wit_rep(value.handle) else value.handle",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.call(\"test:res/counters#[method]counter.increment\", u32, .{ __self, __dispatch_params.by })",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "export fn @\"test:res/counters#[static]counter.make-zero\"() wit_types.CoreReturn(wit_types.Own(Counter))",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "export fn @\"test:res/counters#[dtor]counter\"(rep: i32) void",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "__wit_dispatch.dropExportResource(\"test:res/counters\", \"counter\", rep);",
        ) != null);

        // Ordinary exported functions map resource handles recursively through
        // reps, consume incoming own canonical handles before dispatch so
        // throws cannot leak them, then lower and commit returned resources.
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "export fn @\"test:res/counters#transfer\"(value: i32) wit_types.CoreReturn(wit_types.Own(Counter))",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "const __dispatch_params = wit_types.mapResources(@TypeOf(__params), __params, __wit_lift_export_resource, &wit_types.alloc);",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, out,
            \\    const __dispatch_params = wit_types.mapResources(@TypeOf(__params), __params, __wit_lift_export_resource, &wit_types.alloc);
            \\    _ = wit_types.mapResources(@TypeOf(__dispatch_params), __dispatch_params, __wit_prepare_export_resource, &wit_types.alloc);
            \\    _ = wit_types.mapResources(@TypeOf(__params), __params, __wit_consume_export_resource, &wit_types.alloc);
            \\    const __result = __wit_dispatch.call("test:res/counters#transfer", wit_types.Own(Counter), .{ __dispatch_params.value });
            \\    const __canonical_result = wit_types.mapResources(wit_types.Own(Counter), __result, __wit_lower_export_resource, &wit_types.alloc);
            \\    __wit_dispatch.completeNativeResult(wit_types.Own(Counter), __result);
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "if (comptime info.ownership == .own)",
        ) != null);

        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "\"ER\\ttest:res/counters\\tcounter\\tCounter\\n\"",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "\"EC\\ttest:res/counters\\tcounter\\tCounter\\ttest:res/counters#[constructor]counter\\t1\\n\"",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "\"EM\\ttest:res/counters\\tcounter\\tincrement\\ttest:res/counters#[method]counter.increment\\t1\\n\"",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "\"ES\\ttest:res/counters\\tcounter\\tmakeZero\\ttest:res/counters#[static]counter.make-zero\\t0\\n\"",
        ) != null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "\"ED\\ttest:res/counters\\tcounter\\ttest:res/counters#[dtor]counter\\n\"",
        ) != null);
    }
}

test "generate: same-named resources keep provider identity and alias ownership" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const item_ref = ast.Type{ .name = "item" };
    const a_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "item", .kind = .{ .resource = &.{} } } },
        .{ .type = .{ .name = "item-alias", .kind = .{ .alias = item_ref } } },
        .{ .func = .{ .name = "transfer", .func = .{
            .params = &.{
                .{ .name = "owned", .type = .{ .own = "item-alias" } },
                .{ .name = "borrowed", .type = .{ .borrow = "item-alias" } },
            },
            .result = .{ .own = "item-alias" },
        } } },
    };
    const b_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "item", .kind = .{ .resource = &.{} } } },
        .{ .type = .{ .name = "item-alias", .kind = .{ .alias = item_ref } } },
        .{ .func = .{ .name = "inspect", .func = .{
            .params = &.{.{ .name = "value", .type = .{ .borrow = "item-alias" } }},
            .result = .u32,
        } } },
    };
    const iface_a = ast.Interface{ .name = "provider-a", .items = &a_items };
    const iface_b = ast.Interface{ .name = "provider-b", .items = &b_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "provider-a" } } } },
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "provider-b" } } } },
    } };
    const export_world = ast.World{ .name = "host", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "provider-a" } } } },
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "provider-b" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "demo", .name = "duplicate", .version = "1.2.3" },
        .items = &.{
            .{ .interface = iface_a },
            .{ .interface = iface_b },
            .{ .world = world },
            .{ .world = export_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try g.generate(world, "guest");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(u8, out, "pub const ProviderAItem = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const ProviderBItem = struct {") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "ResourceDescriptor{ .provider = \"demo:duplicate/provider-a@1.2.3\", .name = \"item\" }",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "ResourceDescriptor{ .provider = \"demo:duplicate/provider-b@1.2.3\", .name = \"item\" }",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "pub const ProviderAItemAlias = wit_types.Own(ProviderAItem);",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "pub const ProviderBItemAlias = wit_types.Own(ProviderBItem);",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "pub fn transfer(owned: wit_types.Own(ProviderAItemAlias), borrowed: wit_types.Borrow(ProviderAItemAlias)) wit_types.Own(ProviderAItemAlias)",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "pub fn inspect(value: wit_types.Borrow(ProviderBItemAlias)) u32",
    ) != null);

    var export_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try export_g.generate(export_world, "host");
    const export_out = export_g.out.items;
    try testing.expect(std.mem.indexOf(
        u8,
        export_out,
        "extern \"[export]demo:duplicate/provider-a@1.2.3\" fn @\"[resource-new]item\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        export_out,
        "extern \"[export]demo:duplicate/provider-b@1.2.3\" fn @\"[resource-new]item\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        export_out,
        "\"ER\\tdemo:duplicate/provider-a@1.2.3\\titem\\tItem\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        export_out,
        "\"ER\\tdemo:duplicate/provider-b@1.2.3\\titem\\tItem\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        export_out,
        "export fn @\"demo:duplicate/provider-a@1.2.3#[dtor]item\"(rep: i32) void",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        export_out,
        "export fn @\"demo:duplicate/provider-b@1.2.3#[dtor]item\"(rep: i32) void",
    ) != null);
}

test "generate: exported resource unsupported operations fail deterministically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const u32_type: ast.Type = .u32;
    const async_methods = [_]ast.ResourceMethod{.{
        .kind = .method,
        .name = "later",
        .func = .{ .params = &.{}, .result = .u32, .is_async = true },
    }};
    const channel_methods = [_]ast.ResourceMethod{.{
        .kind = .static,
        .name = "from-stream",
        .func = .{
            .params = &.{.{ .name = "values", .type = .{ .stream = &u32_type } }},
            .result = .{ .name = "thing" },
        },
    }};
    const borrowed_result_methods = [_]ast.ResourceMethod{.{
        .kind = .static,
        .name = "borrowed",
        .func = .{ .params = &.{}, .result = .{ .borrow = "thing" } },
    }};
    const async_iface = ast.Interface{ .name = "async-api", .items = &.{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &async_methods } } },
    } };
    const channel_iface = ast.Interface{ .name = "channel-api", .items = &.{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &channel_methods } } },
    } };
    const borrowed_iface = ast.Interface{ .name = "borrowed-api", .items = &.{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &borrowed_result_methods } } },
    } };
    const async_world = ast.World{ .name = "async-world", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "async-api" } } } },
    } };
    const channel_world = ast.World{ .name = "channel-world", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "channel-api" } } } },
    } };
    const borrowed_world = ast.World{ .name = "borrowed-world", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "borrowed-api" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "unsupported-export-resource" },
        .items = &.{
            .{ .interface = async_iface },
            .{ .interface = channel_iface },
            .{ .interface = borrowed_iface },
            .{ .world = async_world },
            .{ .world = channel_world },
            .{ .world = borrowed_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var async_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try testing.expectError(error.UnsupportedWitType, async_g.generate(async_world, "async-world"));
    try testing.expect(std.mem.indexOf(u8, async_g.diag, "canonical async resource operations") != null);

    var channel_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try testing.expectError(error.UnsupportedWitType, channel_g.generate(channel_world, "channel-world"));
    try testing.expect(std.mem.indexOf(u8, channel_g.diag, "parameter 'values'") != null);

    var borrowed_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
    try testing.expectError(error.UnsupportedWitType, borrowed_g.generate(borrowed_world, "borrowed-world"));
    try testing.expect(std.mem.indexOf(u8, borrowed_g.diag, "borrowed exported resources cannot be returned") != null);
}

test "generate: async resource reached through use imports wit_async" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const methods = [_]ast.ResourceMethod{
        .{
            .kind = .method,
            .name = "ping",
            .func = .{ .params = &.{}, .result = .u32, .is_async = true },
        },
    };
    const provider_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "item", .kind = .{ .resource = &methods } } },
    };
    const facade_items = [_]ast.InterfaceItem{
        .{ .use = .{
            .from = .{ .name = "provider" },
            .names = &.{.{ .name = "item", .rename = "renamed-item" }},
        } },
    };
    const provider = ast.Interface{ .name = "provider", .items = &provider_items };
    const facade = ast.Interface{ .name = "facade", .items = &facade_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "facade" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "async-resource" },
        .items = &.{ .{ .interface = provider }, .{ .interface = facade }, .{ .world = world } },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
    try g.generate(world, "guest");
    const out = g.out.items;
    try testing.expect(std.mem.indexOf(u8, out, "const wit_async = @import(\"wit_async\");") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn ping(self: Borrowed) u32 {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "wit_async.awaitCall(__status);") != null);
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

test "generate --js-imports: a resource reached through use keeps identity and ownership" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // interface counters { resource counter { … } } / imports { use counters.{counter};
    // take: func(c: own<counter>); } -- "counters" is reached only via the
    // `use` (not imported by the world directly). The class/drop metadata
    // must still name counters/counter, while the free function remains in
    // the imports module.
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
    try g.generate(world, "guest");
    const out = g.out.items;
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"R\\ttest:res/counters\\tcounter\\tCounter\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"test:res/imports\\ttake\\ttest:res/imports#take\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const a0 = js_dispatch.decodeNative(wit_types.Own(Counter), &argv_ptr[0], __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "js_dispatch.commitNativeResources(") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "std.mem.eql(u8, provider, Counter.__wit_resource.provider)",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "std.mem.eql(u8, resource_name, Counter.__wit_resource.name)",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "Counter.__wit_drop(handle);") != null);
}

test "generate --js-imports: a mixed resource and free-function interface bridges both" {
    // interface host {
    //   resource counter { … }             // never referenced by `add`
    //   add: func(a: s32, b: s32) -> s32;   // fully bridgeable on its own
    // }
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
    try g.generate(world, "guest");
    const out = g.out.items;
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"R\\ttest:mixed/host\\tcounter\\tCounter\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"M\\ttest:mixed/host\\tcounter\\tget\\ttest:mixed/host#[method]counter.get\\t0\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"test:mixed/host\\tadd\\ttest:mixed/host#add\\t2\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const a0 = js_dispatch.decodeNative(wit_types.Borrow(Counter), &argv_ptr[0], __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __result = Counter.Borrowed.get(a0);") != null);
}

test "generate --js-imports: resource operations preserve aliases, ownership, and provider collisions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const a_methods = [_]ast.ResourceMethod{
        .{
            .kind = .constructor,
            .name = "",
            .func = .{ .params = &.{.{ .name = "seed", .type = .u32 }}, .result = null },
        },
        .{
            .kind = .method,
            .name = "replace-with",
            .func = .{
                .params = &.{.{ .name = "next", .type = .{ .own = "item-alias" } }},
                .result = .{ .own = "item-alias" },
            },
        },
        .{
            .kind = .static,
            .name = "from-borrow",
            .func = .{
                .params = &.{.{ .name = "source", .type = .{ .borrow = "item-alias" } }},
                .result = .{ .own = "item-alias" },
            },
        },
    };
    const a_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "item", .kind = .{ .resource = &a_methods } } },
        .{ .type = .{ .name = "item-alias", .kind = .{ .alias = .{ .name = "item" } } } },
        .{ .type = .{ .name = "box", .kind = .{ .record = &.{
            .{ .name = "value", .type = .{ .own = "item-alias" } },
        } } } },
        .{ .func = .{ .name = "transfer", .func = .{
            .params = &.{
                .{ .name = "owned", .type = .{ .own = "item-alias" } },
                .{ .name = "borrowed", .type = .{ .borrow = "item-alias" } },
                .{ .name = "nested", .type = .{ .option = &.{ .name = "box" } } },
            },
            .result = .{ .own = "item-alias" },
        } } },
    };
    const b_items = [_]ast.InterfaceItem{
        .{ .type = .{ .name = "item", .kind = .{ .resource = &.{} } } },
        .{ .type = .{ .name = "item-alias", .kind = .{ .alias = .{ .name = "item" } } } },
        .{ .func = .{ .name = "borrow-back", .func = .{
            .params = &.{.{ .name = "value", .type = .{ .borrow = "item-alias" } }},
            .result = .{ .borrow = "item-alias" },
        } } },
    };
    const provider_a = ast.Interface{ .name = "provider-a", .items = &a_items };
    const provider_b = ast.Interface{ .name = "provider-b", .items = &b_items };
    const world = ast.World{ .name = "guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "provider-a" } } } },
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "provider-b" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "resource-js", .version = "1.0.0" },
        .items = &.{
            .{ .interface = provider_a },
            .{ .interface = provider_b },
            .{ .world = world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try g.generate(world, "guest");
    const out = g.out.items;

    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"R\\ttest:resource-js/provider-a@1.0.0\\titem\\tItem\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"R\\ttest:resource-js/provider-b@1.0.0\\titem\\tItem\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"C\\ttest:resource-js/provider-a@1.0.0\\titem\\tItem\\ttest:resource-js/provider-a@1.0.0#[constructor]item\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"M\\ttest:resource-js/provider-a@1.0.0\\titem\\treplaceWith\\ttest:resource-js/provider-a@1.0.0#[method]item.replace-with\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"S\\ttest:resource-js/provider-a@1.0.0\\titem\\tfromBorrow\\ttest:resource-js/provider-a@1.0.0#[static]item.from-borrow\\t1\\n\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const a0 = js_dispatch.decodeNative(wit_types.Borrow(ProviderAItem), &argv_ptr[0], __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const a1 = js_dispatch.decodeNative(wit_types.Own(ProviderAItemAlias), &argv_ptr[1], __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const __result = ProviderAItem.Borrowed.replaceWith(a0, a1);",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "out_result.* = js_dispatch.encodeNative(wit_types.Own(ProviderAItemAlias), __result, __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "const a2 = js_dispatch.decodeNative(?Box, &argv_ptr[2], __alloc);",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "const __decoded_args = .{ a0, a1, a2 };") != null);
    try testing.expect(std.mem.indexOf(u8, out, "js_dispatch.commitNativeResources(") != null);

    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "std.mem.eql(u8, provider, ProviderAItem.__wit_resource.provider)",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "std.mem.eql(u8, provider, ProviderBItem.__wit_resource.provider)",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "std.mem.eql(u8, resource_name, ProviderAItem.__wit_resource.name)",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "std.mem.eql(u8, resource_name, ProviderBItem.__wit_resource.name)",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "ProviderAItem.__wit_drop(handle);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ProviderBItem.__wit_drop(handle);") != null);
}

test "generate --js-imports: resource canonical async and channel operations are explicit diagnostics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const async_methods = [_]ast.ResourceMethod{.{
        .kind = .constructor,
        .name = "",
        .func = .{ .params = &.{}, .result = null, .is_async = true },
    }};
    const async_iface = ast.Interface{ .name = "async-host", .items = &.{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &async_methods } } },
    } };
    const async_world = ast.World{ .name = "async-guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "async-host" } } } },
    } };
    const u32_type: ast.Type = .u32;
    const channel_methods = [_]ast.ResourceMethod{.{
        .kind = .static,
        .name = "from-stream",
        .func = .{
            .params = &.{.{ .name = "values", .type = .{ .stream = &u32_type } }},
            .result = .{ .name = "thing" },
        },
    }};
    const channel_iface = ast.Interface{ .name = "channel-host", .items = &.{
        .{ .type = .{ .name = "thing", .kind = .{ .resource = &channel_methods } } },
    } };
    const channel_world = ast.World{ .name = "channel-guest", .items = &.{
        .{ .import = .{ .interface_ref = .{ .ref = .{ .name = "channel-host" } } } },
    } };
    const doc = ast.Document{
        .package = .{ .namespace = "test", .name = "unsupported-resource-js" },
        .items = &.{
            .{ .interface = async_iface },
            .{ .interface = channel_iface },
            .{ .world = async_world },
            .{ .world = channel_world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    var async_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, async_g.generate(async_world, "async-guest"));
    try testing.expect(std.mem.indexOf(u8, async_g.diag, "[constructor]thing") != null);
    try testing.expect(std.mem.indexOf(u8, async_g.diag, "canonical async") != null);

    var channel_g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch", .js_imports = true };
    try testing.expectError(error.UnsupportedWitType, channel_g.generate(channel_world, "channel-guest"));
    try testing.expect(std.mem.indexOf(u8, channel_g.diag, "[static]thing.from-stream") != null);
    try testing.expect(std.mem.indexOf(u8, channel_g.diag, "'values'") != null);
    try testing.expect(std.mem.indexOf(u8, channel_g.diag, "future/stream") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.bump\"(self: i32, arg_by: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.label\"(self: i32, result_ptr: i32) i32;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "extern \"test:res/things\" fn @\"[method]thing.reset\"(self: i32) i32;") != null);

    // Async wrappers drive the subtask via awaitCall then lift from memory.
    try testing.expect(std.mem.indexOf(u8, out, "const __status = imp.@\"[method]thing.bump\"(self.handle, @bitCast(arg_by), wit_types.retPtr());") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "const __pargs = .{ self, arg_a, arg_name, arg_b, arg_c };") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "pub fn signal(self: Pipe, arg_f: wit_types.Future(u32)) bool {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "imp.@\"[method]pipe.signal\"(self.handle, arg_f.handle)") != null);
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
    try testing.expect(std.mem.indexOf(u8, out, "pub fn open(arg_seed: wit_types.Future(u32)) __chan0 {") != null);
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

test "generate: dispatch mode emits exact synchronous JavaScript export manifest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const iface_items = [_]ast.InterfaceItem{
        .{ .func = .{ .name = "do-thing", .func = .{
            .params = &.{.{ .name = "value", .type = .u32 }},
            .result = .u32,
        } } },
        .{ .func = .{ .name = "later", .func = .{
            .params = &.{},
            .result = .u32,
            .is_async = true,
        } } },
    };
    const iface = ast.Interface{ .name = "api", .items = &iface_items };
    const world = ast.World{ .name = "js-exports", .items = &.{
        .{ .@"export" = .{ .interface_ref = .{ .ref = .{ .name = "api" } } } },
        .{ .@"export" = .{ .named_func = .{ .name = "root-add", .func = .{
            .params = &.{
                .{ .name = "a", .type = .u32 },
                .{ .name = "b", .type = .u32 },
            },
            .result = .u32,
        } } } },
    } };
    const doc = ast.Document{
        .package = .{
            .namespace = "test",
            .name = "preflight",
            .version = "1.2.3",
        },
        .items = &.{
            .{ .interface = iface },
            .{ .world = world },
        },
    };
    const res = wit.resolver.Resolver.init(doc, &.{});

    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl", .dispatch = "js_dispatch" };
        try g.generate(world, "js-exports");
        const out = g.out.items;
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "\"I\\ttest:preflight/api@1.2.3#do-thing\\n\" ++",
        ) != null);
        try testing.expect(std.mem.indexOf(u8, out, "\"R\\troot-add\\n\" ++") != null);
        try testing.expect(std.mem.indexOf(u8, out, "api@1.2.3#later\\n") == null);
        try testing.expect(std.mem.indexOf(
            u8,
            out,
            "pub export fn starling_js_exports_manifest(out_len: *usize) callconv(.c) [*]const u8 {",
        ) != null);
    }
    {
        var g = Gen{ .ar = ar, .resolver = res, .impl = "impl" };
        try g.generate(world, "js-exports");
        try testing.expect(std.mem.indexOf(u8, g.out.items, "js_export_manifest") == null);
        try testing.expect(std.mem.indexOf(u8, g.out.items, "starling_js_exports_manifest") == null);
    }
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
