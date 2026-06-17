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

pub const ZigBuildWasm = struct {
    source: std.Build.LazyPath,
    /// Names passed via `--export=<name>`. The universal `cabi_realloc`
    /// export is added automatically (see `cabi_realloc`), so list only
    /// the component-specific exports here.
    exports: []const []const u8,
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
    return out;
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
    const cmd = b.addSystemCommand(&.{ "wabt", "component", "new" });
    if (opts.world) |world| {
        cmd.addArg("--world");
        cmd.addArg(world);
    }
    cmd.addArg("--wit");
    cmd.addDirectoryArg(opts.wit_dir orelse b.path("wit"));
    cmd.addFileArg(opts.wasm_core);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(opts.output orelse componentBasename(b, lazyBasename(opts.wasm_core)));
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
    const cmd = b.addSystemCommand(&.{ "wasmtime", "run" });
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
