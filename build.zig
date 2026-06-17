const std = @import("std");

/// wasip3 guest bindings (WASI 0.3 / Component-Model async).
///
/// Prerequisites: Zig 0.16, and the `wabt` CLI (cataggar/wabt) on PATH.
pub fn build(b: *std.Build) void {
    // ?? Library modules (guest bindings) ???????????????????????????
    // Public modules so dependents can `@import` them when compiling a
    // `wasm32-freestanding` guest. `abi` owns the sole `cabi_realloc`
    // export + ret-area; `cm_async` declares the canonical-ABI async
    // intrinsics (the WASI 0.3 replacement for `wasi:io`).
    const abi = b.addModule("abi", .{ .root_source_file = b.path("src/abi.zig") });

    const cm_async = b.addModule("cm_async", .{ .root_source_file = b.path("src/cm_async.zig") });
    cm_async.addImport("abi", abi);

    const wasi_cli = b.addModule("wasi_cli", .{ .root_source_file = b.path("src/wasi_cli.zig") });
    wasi_cli.addImport("cm_async", cm_async);

    const wasi_http = b.addModule("wasi_http", .{ .root_source_file = b.path("src/wasi_http.zig") });
    wasi_http.addImport("abi", abi);
    wasi_http.addImport("cm_async", cm_async);

    // Comptime canonical-ABI value marshaller (records / strings / options /
    // lists → linear memory). Depends only on `std`; a guest passes it the
    // `abi.alloc` realloc.
    const canon = b.addModule("canon", .{ .root_source_file = b.path("src/canon.zig") });

    // Single-import library surface re-exporting every module.
    const wasip3 = b.addModule("wasip3", .{ .root_source_file = b.path("src/root.zig") });
    wasip3.addImport("abi", abi);
    wasip3.addImport("canon", canon);
    wasip3.addImport("cm_async", cm_async);
    wasip3.addImport("wasi_cli", wasi_cli);
    wasip3.addImport("wasi_http", wasi_http);


    // ?? Tests ??????????????????????????????????????????????????????
    // Native unit tests for the host-import-free canonical-ABI core in
    // `abi.zig` (bump arena + ret-area decoders). The `wasi_*` wrappers
    // can't be tested natively ? their public functions call `extern`
    // host imports that only link for `wasm32-freestanding`.
    const abi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/abi.zig"),
            .target = b.graph.host,
        }),
    });
    const run_abi_tests = b.addRunArtifact(abi_tests);

    // Native unit tests for the comptime canonical-ABI marshaller (`canon.zig`):
    // layout + lower/lift round-trips (host-import-free).
    const canon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/canon.zig"),
            .target = b.graph.host,
        }),
    });
    const run_canon_tests = b.addRunArtifact(canon_tests);

    const test_step = b.step("test", "Run native unit tests");
    test_step.dependOn(&run_abi_tests.step);
    test_step.dependOn(&run_canon_tests.step);
}

// ?? Build helpers (ported from cataggar/wamr) ??????????????????????
//
// These are `pub` so dependents can `@import("wasip3")` this build.zig
// and reuse them. Path fields are `LazyPath` so a dependent points at the
// vendored sources via `dep.path("src/...")`.

/// The `wabt` CLI binary: `$WABT` if set (point it at a P3-capable build),
/// else `wabt` from `PATH`.
pub fn wabtBin(b: *std.Build) []const u8 {
    return b.graph.environ_map.get("WABT") orelse "wabt";
}

/// The `wasmtime` CLI binary: `$WASMTIME` if set (point it at wasmtime >= 46),
/// else `wasmtime` from `PATH`.
pub fn wasmtimeBin(b: *std.Build) []const u8 {
    return b.graph.environ_map.get("WASMTIME") orelse "wasmtime";
}

/// Pass a WIT directory as the `--wit` arg to a `wabt` Run *and* make edits to
/// its files invalidate that Run's cache. `Run.addDirectoryArg` hashes only the
/// directory *path* into the cache manifest (std `Run.zig`'s
/// `decorated_directory` arm hashes the resolved arg bytes, never the
/// contents), so on its own it would let `wabt component new` / `bindgen` serve
/// stale output after a `wit/*.wit` edit. `Run.addFileInput` hashes a file's
/// *contents* into the manifest without adding it to argv, so we enumerate the
/// `.wit` files under the (source) dir and register each as an input — no copy
/// step, no extra build artifacts. A generated/non-source dir can't be walked
/// at configure time, so it falls back to path-only hashing.
pub fn addWitArg(b: *std.Build, cmd: *std.Build.Step.Run, wit: std.Build.LazyPath) void {
    cmd.addDirectoryArg(wit);
    const sp = switch (wit) {
        .src_path => |s| s,
        else => return,
    };
    const io = b.graph.io;
    var dir = sp.owner.build_root.handle.openDir(io, sp.sub_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".wit")) continue;
        cmd.addFileInput(wit.path(b, entry.path));
    }
}

pub const ZigWasmImport = struct {
    /// Import name, e.g. `wasi_cli` for `@import("wasi_cli")`.
    name: []const u8,
    /// The module's root source file. A `LazyPath` so callers in another
    /// package can point at this dependency's vendored sources via
    /// `dep.path("src/...")`.
    path: std.Build.LazyPath,
    /// Names of other modules in the same `imports` list this module
    /// `@import`s (e.g. `&.{"abi"}`). Wired as `--dep` flags before this
    /// module's `-M` entry.
    deps: []const []const u8 = &.{},
    /// When true, the root source `@import`s this module directly (so it
    /// gets a `--dep` on the root). Transitive-only modules (like `abi`,
    /// reached via the `wasi_*` helpers) set this false.
    root_dep: bool = true,
};

/// The guest-binding module dependency graph. Each module's root source is
/// `src/<name>.zig`; `deps` lists the other modules it `@import`s. Mirrors
/// the `addModule` / `addImport` wiring in `build()` above, in one place,
/// so `resolveImports` can expand a set of roots into the full closure.
pub const ModuleSpec = struct {
    name: []const u8,
    deps: []const []const u8 = &.{},
};

pub const modules = [_]ModuleSpec{
    .{ .name = "abi" },
    .{ .name = "canon" },
    .{ .name = "cm_async", .deps = &.{"abi"} },
    .{ .name = "wasi_cli", .deps = &.{"cm_async"} },
    .{ .name = "wasi_http", .deps = &.{ "abi", "cm_async" } },
};

fn findSpec(name: []const u8) ModuleSpec {
    for (modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    std.debug.panic("unknown wasip3 module: {s}", .{name});
}

/// Expand a set of root module names ? the ones a guest's `main.zig`
/// `@import`s directly ? into the full `ZigWasmImport` closure for
/// `zigBuildWasm`. Pulls in transitive deps (e.g. `wasi_cli` ? `wasi_io`
/// ? `abi`), resolves each source against the `wasip3` dependency via
/// `dep.path("src/<name>.zig")`, and marks transitive-only modules
/// `root_dep = false`. Lets a consumer name just its leaf imports instead
/// of restating the whole graph.
pub fn resolveWasmImports(
    b: *std.Build,
    dep: *std.Build.Dependency,
    roots: []const []const u8,
) []const ZigWasmImport {
    var names: std.ArrayList([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    for (roots) |r| queue.append(b.allocator, r) catch @panic("OOM");
    while (queue.pop()) |name| {
        for (names.items) |n| {
            if (std.mem.eql(u8, n, name)) break;
        } else {
            names.append(b.allocator, name) catch @panic("OOM");
            for (findSpec(name).deps) |d| queue.append(b.allocator, d) catch @panic("OOM");
        }
    }

    var out: std.ArrayList(ZigWasmImport) = .empty;
    for (names.items) |name| {
        var is_root = false;
        for (roots) |r| {
            if (std.mem.eql(u8, r, name)) {
                is_root = true;
                break;
            }
        }
        out.append(b.allocator, .{
            .name = name,
            .path = dep.path(b.fmt("src/{s}.zig", .{name})),
            .deps = findSpec(name).deps,
            .root_dep = is_root,
        }) catch @panic("OOM");
    }
    return out.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// Like `resolveWasmImports`, but also appends caller-provided generated
/// imports (e.g. `wabtComponentBindgen` output) after the resolved wasip3
/// closure — so a guest that imports a generated WIT binding alongside the
/// `wasi_*` helpers can describe its whole import set in one call instead of
/// hand-splicing arrays.
pub fn resolveWasmImportsWith(
    b: *std.Build,
    dep: *std.Build.Dependency,
    roots: []const []const u8,
    extra: []const ZigWasmImport,
) []const ZigWasmImport {
    const base = resolveWasmImports(b, dep, roots);
    if (extra.len == 0) return base;
    const out = b.allocator.alloc(ZigWasmImport, base.len + extra.len) catch @panic("OOM");
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

pub const ZigBuildWasm = struct {
    source: std.Build.LazyPath,
    /// Additional names force-exported via `--export=<name>`. Usually empty:
    /// the build passes `-rdynamic`, so every `export fn` (the guest's
    /// interface exports + `cabi_realloc`) is exported automatically and the
    /// export names live solely in the (generated) Zig source.
    exports: []const []const u8 = &.{},
    /// Output basename for the emitted core wasm.
    output: []const u8,
    /// Extra modules importable from the root via `@import("<name>")`.
    imports: []const ZigWasmImport = &.{},
    target_triple: []const u8 = "wasm32-freestanding",
    /// Auto-add `--export=cabi_realloc`, the canonical-ABI allocator every
    /// wasip3 component needs (exported by `abi.zig`). Set false for a core
    /// module that doesn't link `abi`.
    cabi_realloc: bool = true,
    /// `-fno-llvm` (self-hosted wasm codegen). Off: LLVM/LLD is required
    /// because Zig 0.16's self-hosted wasm linker mis-sets
    /// `__stack_pointer` (cataggar/wamr#843).
    no_llvm: bool = false,
    no_lld: bool = false,
    /// Also register a parallel, real `addExecutable` mirroring this guest's
    /// module graph onto a shared `check` step (created on demand). The actual
    /// build shells out to `zig build-exe`, which ZLS can't introspect; the
    /// `check` exe gives the language server the same `@import` graph so
    /// editor completion / go-to-def / diagnostics work, transparently — a
    /// consumer just points ZLS's build-on-save at the `check` step. Nothing
    /// here is wired into `install`. Set false to opt out.
    zls_check: bool = true,
};

/// Invoke `zig build-exe -target wasm32-freestanding -O ReleaseSmall
/// -fno-entry --export=?`, reconstructing the module import graph
/// (`root` ? `wasi_*` ? `abi`) via `--dep` / `-M` flags. Captures the
/// emitted wasm as a build-graph LazyPath.
pub fn zigBuildWasm(b: *std.Build, opts: ZigBuildWasm) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{
        b.graph.zig_exe, "build-exe",
        "-target",       opts.target_triple,
        "-O",            "ReleaseSmall",
        "-fno-entry",
        // Export every `export fn` (interface exports + `cabi_realloc`) without
        // having to enumerate their canonical names; they're declared in the
        // (often generated) guest source. `--export=<name>` below still works
        // for forcing extra symbols.
        "-rdynamic",
    });
    if (opts.no_llvm) cmd.addArg("-fno-llvm");
    if (opts.no_lld) cmd.addArg("-fno-lld");
    for (opts.exports) |sym| cmd.addArg(b.fmt("--export={s}", .{sym}));
    if (opts.cabi_realloc) {
        for (opts.exports) |sym| {
            if (std.mem.eql(u8, sym, "cabi_realloc")) break;
        } else cmd.addArg("--export=cabi_realloc");
    }

    if (opts.imports.len == 0) {
        cmd.addFileArg(opts.source);
    } else {
        // `--dep` flags attach to the next `-M` module. A `dep` name
        // resolves to the single matching `-M<name>=` module, so a
        // shared module (`abi`) is one instance across all importers.
        for (opts.imports) |imp| {
            if (!imp.root_dep) continue;
            cmd.addArg("--dep");
            cmd.addArg(imp.name);
        }
        cmd.addPrefixedFileArg("-Mroot=", opts.source);
        for (opts.imports) |imp| {
            for (imp.deps) |dep| {
                cmd.addArg("--dep");
                cmd.addArg(dep);
            }
            cmd.addPrefixedFileArg(b.fmt("-M{s}=", .{imp.name}), imp.path);
        }
    }
    const out = cmd.addPrefixedOutputFileArg("-femit-bin=", opts.output);
    cmd.setName(b.fmt("zig build-exe {s}", .{opts.output}));
    if (opts.zls_check) registerZlsCheck(b, opts);
    return out;
}

/// The shared `check` step, created on first use. ZLS introspects all module
/// graphs in the build regardless of which step they hang off, so any
/// `zigBuildWasm` guest's `check` exe makes that guest's imports resolvable;
/// pointing ZLS's build-on-save at `check` also surfaces diagnostics.
fn checkStep(b: *std.Build) *std.Build.Step {
    if (b.top_level_steps.get("check")) |tls| return &tls.step;
    return b.step("check", "Analyze guest modules for ZLS (no install)");
}

/// Mirror a `zigBuildWasm` guest's module graph (`opts.source` + `opts.imports`)
/// as a real `addExecutable` + `createModule` / `addImport` so ZLS can resolve
/// the guest's `@import`s. The `zig build-exe` invocation the real build uses is
/// opaque to ZLS; this rebuilds the same graph from the same data. `@import
/// ("root")` (e.g. an export shell reaching its impl) resolves to the exe's root
/// module automatically. Attached only to the `check` step — never to install.
fn registerZlsCheck(b: *std.Build, opts: ZigBuildWasm) void {
    const query = std.Target.Query.parse(.{ .arch_os_abi = opts.target_triple }) catch return;
    const target = b.resolveTargetQuery(query);

    const root = b.createModule(.{ .root_source_file = opts.source, .target = target });

    var mods: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty;
    for (opts.imports) |imp| {
        mods.put(b.allocator, imp.name, b.createModule(.{ .root_source_file = imp.path })) catch @panic("OOM");
    }
    // Wire each import's declared deps (other imports referenced by name).
    for (opts.imports) |imp| {
        const m = mods.get(imp.name).?;
        for (imp.deps) |d| if (mods.get(d)) |dm| m.addImport(d, dm);
    }
    // Wire the root's direct imports.
    for (opts.imports) |imp| {
        if (imp.root_dep) root.addImport(imp.name, mods.get(imp.name).?);
    }

    const stem = opts.output[0 .. std.mem.indexOfScalar(u8, opts.output, '.') orelse opts.output.len];
    const exe = b.addExecutable(.{ .name = b.fmt("{s}-check", .{stem}), .root_module = root });
    exe.entry = .disabled;
    exe.rdynamic = true;
    checkStep(b).dependOn(&exe.step);
}

pub const WabtComponentNew = struct {
    wasm_core: std.Build.LazyPath,
    /// WIT package directory to embed (`--wit`). Defaults to `wit/`
    /// relative to the build root.
    wit_dir: ?std.Build.LazyPath = null,
    /// World to embed (`--world`). When null, `--world` is omitted and
    /// `wabt` infers the single world in the WIT package.
    world: ?[]const u8 = null,
    /// Output basename for the produced component LazyPath. When null,
    /// derived from `wasm_core`'s basename: a `.core.wasm` suffix becomes
    /// `.wasm` (so `hello.core.wasm` ? `hello.wasm`).
    output: ?[]const u8 = null,
};

/// One-step `wabt component new --world <world> --wit <dir>`: embeds the
/// WIT, wraps the core into a component, and validates ? in one call.
/// The bundled WASI WIT + wasi-preview1 adapter are auto-attached, so no
/// on-disk `wit/deps/` copy is needed.
pub fn wabtComponentNew(b: *std.Build, opts: WabtComponentNew) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ wabtBin(b), "component", "new" });
    if (opts.world) |world| {
        cmd.addArg("--world");
        cmd.addArg(world);
    }
    cmd.addArg("--wit");
    addWitArg(b, cmd, opts.wit_dir orelse b.path("wit"));
    cmd.addFileArg(opts.wasm_core);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(opts.output orelse componentBasename(b, lazyBasename(opts.wasm_core)));
}

pub const WabtComponentBindgen = struct {
    /// World to generate guest bindings for (`--world`).
    world: []const u8,
    /// Module the generated export shells delegate to as their `Impl`
    /// (`--impl`); `"root"` makes them call `@import("root")`. Ignored for an
    /// import-only world (no export shells are emitted).
    impl: []const u8 = "root",
    /// WIT package directory to read (`--wit`). Defaults to `wit/`.
    wit_dir: ?std.Build.LazyPath = null,
    /// Output basename for the generated `.zig` source.
    output: []const u8,
};

/// `wabt component bindgen --wit <dir> --world <world> --impl <impl> -o <out>`:
/// generate the canonical-ABI guest bindings (typed import wrappers and/or
/// `export fn` shells) for a world as a Zig source `LazyPath`.
pub fn wabtComponentBindgen(b: *std.Build, opts: WabtComponentBindgen) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ wabtBin(b), "component", "bindgen", "--wit" });
    addWitArg(b, cmd, opts.wit_dir orelse b.path("wit"));
    cmd.addArgs(&.{ "--world", opts.world, "--impl", opts.impl, "-o" });
    cmd.setName(b.fmt("wabt component bindgen {s}", .{opts.world}));
    return cmd.addOutputFileArg(opts.output);
}

pub const WabtComponentCompose = struct {
    /// The consumer/"main" component whose imports get satisfied.
    consumer: std.Build.LazyPath,
    /// Provider components (`-d`) that satisfy the consumer's imports.
    dependencies: []const std.Build.LazyPath,
    /// Output basename for the composed component.
    output: []const u8,
};

/// `wabt component compose -d <dep>... -o <out> <consumer>`: link a consumer
/// component against one or more provider components into a single composed
/// component `LazyPath`.
pub fn wabtComponentCompose(b: *std.Build, opts: WabtComponentCompose) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{ wabtBin(b), "component", "compose" });
    for (opts.dependencies) |d| {
        cmd.addArg("-d");
        cmd.addFileArg(d);
    }
    cmd.addArg("-o");
    const out = cmd.addOutputFileArg(opts.output);
    cmd.addFileArg(opts.consumer);
    return out;
}

pub const WabtModuleValidate = struct {
    /// Step to attach the validate + install to.
    parent: *std.Build.Step,
    /// Component to validate.
    wasm: std.Build.LazyPath,
    /// Install basename under `zig-out/`. When null, defaults to `wasm`'s
    /// own basename (e.g. `hello.wasm`).
    install_basename: ?[]const u8 = null,
};

/// `wabt module validate` the component, then install it under
/// `zig-out/<basename>`.
pub fn wabtModuleValidate(b: *std.Build, opts: WabtModuleValidate) void {
    const install_basename = opts.install_basename orelse lazyBasename(opts.wasm);

    const validate = b.addSystemCommand(&.{ "wabt", "module", "validate" });
    validate.addFileArg(opts.wasm);
    validate.setName(b.fmt("wabt module validate {s}", .{install_basename}));

    const install = b.addInstallFileWithDir(opts.wasm, .prefix, install_basename);
    install.step.dependOn(&validate.step);
    opts.parent.dependOn(&install.step);
}

pub const WasmtimeRun = struct {
    /// Component to run.
    wasm: std.Build.LazyPath,
    /// Named step to create (e.g. `zig build run`).
    step_name: []const u8 = "run",
    /// Step description shown in `zig build --help`.
    description: []const u8 = "Run the component with wasmtime",
    /// `-S <feature>` flags enabling WASI features on `wasmtime run`.
    /// Defaults to `cli-exit-with-code` so the guest's exit code propagates.
    wasi: []const []const u8 = &.{"cli-exit-with-code"},
    /// Extra args passed to the guest after the component path. Args from
    /// `zig build <step> -- ...` are appended after these.
    args: []const []const u8 = &.{},
};

/// Create a named step that runs the component with `wasmtime run`.
/// Returns the step so callers can wire further dependencies if needed.
pub fn wasmtimeRun(b: *std.Build, opts: WasmtimeRun) *std.Build.Step {
    const cmd = b.addSystemCommand(&.{ wasmtimeBin(b), "run" });
    for (opts.wasi) |feature| {
        cmd.addArg("-S");
        cmd.addArg(feature);
    }
    cmd.addFileArg(opts.wasm);
    for (opts.args) |arg| cmd.addArg(arg);
    if (b.args) |forwarded| cmd.addArgs(forwarded);

    const step = b.step(opts.step_name, opts.description);
    step.dependOn(&cmd.step);
    return step;
}

pub const WasmtimeServe = struct {
    /// Component to serve.
    wasm: std.Build.LazyPath,
    /// Named step to create (e.g. `zig build serve`).
    step_name: []const u8 = "serve",
    /// Step description shown in `zig build --help`.
    description: []const u8 = "Serve the component with wasmtime",
    /// `-W <feature>` Wasm / component-model features. Defaults to the full
    /// WASI 0.3 (P3) async feature set wasmtime needs for a wasip3 component.
    wasm_features: []const []const u8 = &.{
        "component-model-async",
        "component-model-async-stackful",
        "component-model-more-async-builtins",
        "component-model-error-context",
    },
    /// `-S <feature>` WASI features. Defaults to `p3,cli`.
    wasi: []const []const u8 = &.{"p3,cli"},
};

/// Create a named step that serves the component with `wasmtime serve`.
/// Args from `zig build <step> -- ...` (e.g. `--addr 127.0.0.1:8080`) are
/// forwarded to wasmtime after the component path. Returns the step.
pub fn wasmtimeServe(b: *std.Build, opts: WasmtimeServe) *std.Build.Step {
    const cmd = b.addSystemCommand(&.{ wasmtimeBin(b), "serve" });
    for (opts.wasm_features) |f| {
        cmd.addArg("-W");
        cmd.addArg(f);
    }
    for (opts.wasi) |f| {
        cmd.addArg("-S");
        cmd.addArg(f);
    }
    cmd.addFileArg(opts.wasm);
    if (b.args) |extra| cmd.addArgs(extra);

    const step = b.step(opts.step_name, opts.description);
    step.dependOn(&cmd.step);
    return step;
}

/// The basename of a `LazyPath`. For a generated file produced by a `Run`
/// output arg (which is how `zigBuildWasm` / `wabtComponentNew` make their
/// outputs), the basename is recovered from the owning `Run.Output`.
fn lazyBasename(lp: std.Build.LazyPath) []const u8 {
    return switch (lp) {
        .src_path => |sp| std.fs.path.basename(sp.sub_path),
        .cwd_relative => |p| std.fs.path.basename(p),
        .dependency => |d| std.fs.path.basename(d.sub_path),
        .generated => |gen| if (gen.sub_path.len > 0)
            std.fs.path.basename(gen.sub_path)
        else basename: {
            const output: *const std.Build.Step.Run.Output = @fieldParentPtr("generated_file", gen.file);
            break :basename output.basename;
        },
    };
}

/// Component basename derived from a core-wasm basename: a `.core.wasm`
/// suffix becomes `.wasm` (`hello.core.wasm` ? `hello.wasm`); otherwise the
/// extension is replaced with `.wasm`.
fn componentBasename(b: *std.Build, core: []const u8) []const u8 {
    if (std.mem.endsWith(u8, core, ".core.wasm"))
        return b.fmt("{s}.wasm", .{core[0 .. core.len - ".core.wasm".len]});
    const stem = core[0 .. core.len - std.fs.path.extension(core).len];
    return b.fmt("{s}.wasm", .{stem});
}
