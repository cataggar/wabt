const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from binaries") orelse false;

    const stack_protector = b.option(bool, "stack-protector", "Enable stack protector (requires libc linkage)") orelse false;
    const link_libc = b.option(bool, "link-libc", "Link against libc") orelse stack_protector;
    const version = b.option([]const u8, "version", "Version string") orelse "dev";
    // When set, `zig build p3-conformance` fails (instead of skipping) if no
    // usable Wasmtime is found — set by the CI p3-conformance job, which
    // installs a pinned Wasmtime that supports the P3 canon built-ins.
    const p3_require_wasmtime = b.option(bool, "p3-require-wasmtime", "Fail (not skip) p3-conformance when no Wasmtime is found (CI)") orelse false;
    // When set, `zig build wasi-p3-testsuite` fails (instead of skipping) if the
    // vendored wasm32-wasip3 testsuite is missing — set by CI once the suite is
    // vendored, so a dropped checkout is a hard failure rather than a silent skip.
    const wasip3_require_suite = b.option(bool, "wasip3-require-suite", "Fail (not skip) wasi-p3-testsuite when the testsuite is not vendored (CI)") orelse false;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Core library module
    const wabt_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
    });
    wabt_mod.addOptions("build_options", options);

    // Static library
    const lib = b.addLibrary(.{
        .name = "wabt",
        .root_module = wabt_mod,
    });
    b.installArtifact(lib);

    // Per-subcommand source files (each exposes pub const usage and pub fn run).
    // Order is unimportant; this list drives both the inline-test loop and
    // documents the subcommand inventory.
    const subcommand_sources = [_][]const u8{
        "src/tools/parse.zig",
        "src/tools/print.zig",
        "src/tools/validate.zig",
        "src/tools/objdump.zig",
        "src/tools/strip.zig",
        "src/tools/json_from_wast.zig",
        "src/tools/decompile.zig",
        "src/tools/stats.zig",
        "src/tools/desugar.zig",
        "src/tools/shrink.zig",
        "src/tools/component.zig",
        "src/tools/component_embed.zig",
        "src/tools/component_new.zig",
        "src/tools/component_compose.zig",
        "src/tools/component_objdump.zig",
        // Subject dispatchers (the original #137 roots plus OCI).
        "src/tools/text.zig",
        "src/tools/module.zig",
        "src/tools/interface.zig",
        "src/tools/compose.zig",
        "src/tools/spec.zig",
        // OCI commands and shared option/runtime/output boundaries.
        "src/tools/oci_options.zig",
        "src/tools/oci_runtime.zig",
        "src/tools/oci_output.zig",
        "src/tools/oci_read_test.zig",
        "src/tools/oci_write_test.zig",
        "src/tools/oci_push.zig",
        "src/tools/oci_pull.zig",
        "src/tools/oci_copy.zig",
        "src/tools/oci_inspect.zig",
        "src/tools/oci_resolve.zig",
        "src/tools/oci_list_tags.zig",
        "src/tools/oci.zig",
    };

    // Single wabt CLI exe — dispatches to subcommand modules at runtime.
    const wabt_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/wabt.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_mod },
        },
    });

    const wabt_exe = b.addExecutable(.{
        .name = "wabt",
        .root_module = wabt_cli_mod,
    });
    // Increase default stack size for deeply nested Wasm blocks
    wabt_exe.stack_size = 128 * 1024 * 1024; // 128 MB
    b.installArtifact(wabt_exe);

    // ── wasi-preview1 → preview2 adapter ─────────────────────────────────
    //
    // Builds `zig-out/adapter/wasi_snapshot_preview1.command.wasm` from
    // `adapters/wasi-preview1/src/adapter.wat` using the wabt library. See
    // `adapters/wasi-preview1/README.md` for the surface coverage, the
    // current scaffold status, and the roadmap up to the embedded-default
    // adapter for `wabt component new` (tracked under cataggar/wamr#453).
    // Build the tool for the actual host machine (NOT the user's
    // `-Dtarget`): the tool runs at build time on the build platform
    // to produce the adapter wasm. `b.graph.host` in Zig 0.16 returns
    // the user-selected `-Dtarget` when one is set (verified failing
    // on the `wasi`/`riscv64` release matrix entries), so we resolve
    // the native query explicitly here.
    const native_host = b.resolveTargetQuery(.{});

    // The wabt module itself is compiled for the user's target; the
    // tool needs a separate copy compiled for the host so the
    // build-time `build-wasi-preview1-adapter` exe is executable on
    // the CI runner.
    const wabt_host_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = native_host,
        .optimize = optimize,
    });
    wabt_host_mod.addOptions("build_options", options);

    const adapter_tool_mod = b.createModule(.{
        .root_source_file = b.path("adapters/wasi-preview1/tools/build_adapter.zig"),
        .target = native_host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_host_mod },
        },
    });
    const adapter_tool_exe = b.addExecutable(.{
        .name = "build-wasi-preview1-adapter",
        .root_module = adapter_tool_mod,
    });
    adapter_tool_exe.stack_size = 128 * 1024 * 1024;

    // ── Adapter artifacts: command + reactor shapes ──────────────────────
    //
    // Both shapes share `src/fragments/{prelude,body,realloc,exports}.wat`
    // and add per-shape `*-imports.wat`, `*-impl.wat`, and `*-footer.wat`
    // fragments. The build tool concatenates argv-order fragments before
    // parsing, so a single tool invocation per shape produces the artifact.
    // See `adapters/wasi-preview1/src/fragments/README.md` for the cut
    // points and the shape-specific differences.
    //
    // Adapter artifacts are wired into the `adapter` umbrella step (both
    // shapes) plus per-shape `adapter-command` / `adapter-reactor` steps.
    // Both blobs are `@embedFile`d into the CLI so `wabt component new`
    // auto-picks the right shape based on the embed's `_start` export
    // (see `src/tools/component_new.zig:pickBuiltinAdapter`).
    const adapter_step = b.step(
        "adapter",
        "Build the wasi-preview1 → preview2 adapter (command + reactor shapes; see adapters/wasi-preview1/README.md)",
    );

    const adapter_wasm_command = buildAdapterArtifact(b, adapter_tool_exe, .command);
    const adapter_install_command = b.addInstallFileWithDir(
        adapter_wasm_command,
        .prefix,
        "adapter/wasi_snapshot_preview1.command.wasm",
    );
    const adapter_step_command = b.step(
        "adapter-command",
        "Build only the command-shape preview1 adapter (wasi_snapshot_preview1.command.wasm)",
    );
    adapter_step_command.dependOn(&adapter_install_command.step);
    adapter_step.dependOn(&adapter_install_command.step);

    const adapter_wasm_reactor = buildAdapterArtifact(b, adapter_tool_exe, .reactor);
    const adapter_install_reactor = b.addInstallFileWithDir(
        adapter_wasm_reactor,
        .prefix,
        "adapter/wasi_snapshot_preview1.reactor.wasm",
    );
    const adapter_step_reactor = b.step(
        "adapter-reactor",
        "Build only the reactor-shape preview1 adapter (wasi_snapshot_preview1.reactor.wasm)",
    );
    adapter_step_reactor.dependOn(&adapter_install_reactor.step);
    adapter_step.dependOn(&adapter_install_reactor.step);

    // ── Builtin adapter module ───────────────────────────────────────────
    //
    // Compile-time bake BOTH adapter blobs into the wabt CLI so
    // `wabt component new` can auto-splice preview1 cores without
    // requiring `--adapt wasi_snapshot_preview1=<path>`. The CLI's
    // `pickBuiltinAdapter` picks command vs reactor by inspecting
    // the embed's exports for `_start`. We stage a generated
    // `builtin.zig` next to both adapter wasms in a single
    // WriteFile dir; `@embedFile` then resolves to the run-tool
    // outputs, which makes Zig pull both adapter wasms in as build
    // dependencies of the CLI exe automatically.
    const builtin_stage = b.addWriteFiles();
    const builtin_zig = builtin_stage.add(
        "builtin.zig",
        "//! Generated by build.zig; do not edit.\n" ++
            "//! Compile-time-embedded wasi-preview1 → preview2 adapters.\n" ++
            "//!\n" ++
            "//! `wasi_preview1_command_wasm` — exports `wasi:cli/run@0.2.6#run`,\n" ++
            "//! drives the embed via `__main_module__._start`. Picked when the\n" ++
            "//! embed core exports `_start`.\n" ++
            "//!\n" ++
            "//! `wasi_preview1_reactor_wasm` — no `wasi:cli/run` export, no\n" ++
            "//! `_start` invocation. Picked when the embed core lacks `_start`\n" ++
            "//! (the wrapping component lifts the embed's own exports\n" ++
            "//! directly). See cataggar/wabt#167.\n" ++
            "pub const wasi_preview1_command_wasm: []const u8 =\n" ++
            "    @embedFile(\"wasi_snapshot_preview1.command.wasm\");\n" ++
            "pub const wasi_preview1_reactor_wasm: []const u8 =\n" ++
            "    @embedFile(\"wasi_snapshot_preview1.reactor.wasm\");\n",
    );
    _ = builtin_stage.addCopyFile(
        adapter_wasm_command,
        "wasi_snapshot_preview1.command.wasm",
    );
    _ = builtin_stage.addCopyFile(
        adapter_wasm_reactor,
        "wasi_snapshot_preview1.reactor.wasm",
    );
    const builtin_adapter_mod = b.createModule(.{
        .root_source_file = builtin_zig,
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
    });
    wabt_cli_mod.addImport("builtin_adapter", builtin_adapter_mod);

    // wasm2wat-fuzz: buildable but NOT installed. Existing fuzz scripts
    // expect this exe to live somewhere reachable; keep it as an explicit
    // build step.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/wasm2wat-fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .stack_protector = if (stack_protector) true else null,
        .link_libc = if (link_libc) true else null,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_mod },
        },
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "wasm2wat-fuzz",
        .root_module = fuzz_mod,
    });
    fuzz_exe.stack_size = 128 * 1024 * 1024;
    const fuzz_step = b.step("fuzz-bin", "Build the wasm2wat-fuzz harness (not installed)");
    fuzz_step.dependOn(&fuzz_exe.step);

    // Tests
    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test_mod.addOptions("build_options", options);
    const lib_tests = b.addTest(.{
        .root_module = lib_test_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    const oci_cli_test_step = b.step(
        "test-oci-cli",
        "Run focused OCI command-shell unit and CLI tests",
    );
    const oci_qualification_check = b.addSystemCommand(&.{
        "python3",
        "scripts/check_oci_qualification.py",
        "--allow-missing-fixtures",
    });
    const oci_qualification_test_step = b.step(
        "test-oci-qualification",
        "Lint OCI qualification documentation, workflow pins, and packaging",
    );
    oci_qualification_test_step.dependOn(&oci_qualification_check.step);

    const oci_interop_runner = b.addSystemCommand(&.{
        "python3",
        "scripts/oci_interop.py",
        "--wabt",
    });
    oci_interop_runner.addArtifactArg(wabt_exe);
    const oci_interop_step = b.step(
        "oci-interop",
        "Run the external ORAS/wkg interoperability matrix (requires pinned tools and a loopback registry)",
    );
    oci_interop_step.dependOn(&oci_interop_runner.step);

    const oci_registry_test_mod = b.createModule(.{
        .root_source_file = b.path("src/oci/registry_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_mod },
        },
    });
    const oci_registry_tests = b.addTest(.{
        .root_module = oci_registry_test_mod,
    });
    const run_oci_registry_tests = b.addRunArtifact(oci_registry_tests);
    const oci_registry_test_step = b.step(
        "test-oci-registry",
        "Run deterministic OCI registry fixture tests",
    );
    oci_registry_test_step.dependOn(&run_oci_registry_tests.step);
    test_step.dependOn(oci_registry_test_step);

    const oci_fixture_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/oci_fixture_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wabt", .module = wabt_mod },
        },
    });
    const oci_fixture_tests = b.addTest(.{
        .root_module = oci_fixture_test_mod,
    });
    const run_oci_fixture_tests = b.addRunArtifact(oci_fixture_tests);
    test_step.dependOn(&run_oci_fixture_tests.step);
    oci_cli_test_step.dependOn(&run_oci_fixture_tests.step);

    // Per-subcommand inline tests
    for (subcommand_sources) |src| {
        const sub_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wabt", .module = wabt_mod },
            },
        });
        // `component_new.zig` references the compile-time-embedded
        // adapter via `@import("builtin_adapter")`; make it resolvable
        // in the test build too.
        if (std.mem.endsWith(u8, src, "component_new.zig")) {
            sub_mod.addImport("builtin_adapter", builtin_adapter_mod);
        }
        const sub_test = b.addTest(.{
            .root_module = sub_mod,
        });
        const run_sub_test = b.addRunArtifact(sub_test);
        test_step.dependOn(&run_sub_test.step);
        if (std.mem.startsWith(u8, src, "src/tools/oci")) {
            oci_cli_test_step.dependOn(&run_sub_test.step);
        }
    }

    // Inline tests for the dispatcher itself (parseSubcommand etc.).
    const dispatcher_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/wabt.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wabt", .module = wabt_mod },
            },
        }),
    });
    const run_dispatcher_test = b.addRunArtifact(dispatcher_test);
    test_step.dependOn(&run_dispatcher_test.step);
    oci_cli_test_step.dependOn(&run_dispatcher_test.step);

    // CLI smoke assertions: subcommand layout, exit codes, version-on-stdout.
    {
        const wabt_version_line = b.fmt("wabt {s}\n", .{version});

        const wabt_version_run = b.addRunArtifact(wabt_exe);
        wabt_version_run.addArg("version");
        wabt_version_run.expectExitCode(0);
        wabt_version_run.expectStdOutEqual(wabt_version_line);
        test_step.dependOn(&wabt_version_run.step);

        const wabt_help_run = b.addRunArtifact(wabt_exe);
        wabt_help_run.addArg("help");
        wabt_help_run.expectExitCode(0);
        wabt_help_run.expectStdOutMatch(
            "oci        OCI WebAssembly artifacts — push, pull, copy, inspect, resolve, list-tags",
        );
        wabt_help_run.expectStdErrEqual("");
        test_step.dependOn(&wabt_help_run.step);

        const wabt_text_help_run = b.addRunArtifact(wabt_exe);
        wabt_text_help_run.addArgs(&.{ "help", "text" });
        wabt_text_help_run.expectExitCode(0);
        wabt_text_help_run.expectStdOutMatch("Usage: wabt text <verb> [args...]");
        test_step.dependOn(&wabt_text_help_run.step);

        const oci_subject_help =
            "Usage: wabt oci <verb> [args...]\n" ++
            "\n" ++
            "OCI WebAssembly artifact commands:\n" ++
            "  push       Publish a validated Wasm artifact to a registry tag\n" ++
            "  pull       Atomically extract one supported direct Wasm artifact\n" ++
            "  copy       Copy a complete OCI graph between registries/layouts\n" ++
            "  inspect    Inspect a verified registry or OCI layout graph\n" ++
            "  resolve    Resolve a mutable or local reference immutably\n" ++
            "  list-tags  List all tags in one registry repository\n" ++
            "\n" ++
            "Transport only: these commands never execute downloaded WebAssembly.\n" ++
            "Guide: https://github.com/cataggar/wabt/blob/main/docs/oci.md\n" ++
            "\n" ++
            "Run `wabt help oci <verb>` for verb-specific syntax and options.\n";

        const global_oci_help = b.addRunArtifact(wabt_exe);
        global_oci_help.addArgs(&.{ "help", "oci" });
        global_oci_help.expectExitCode(0);
        global_oci_help.expectStdOutEqual(oci_subject_help);
        global_oci_help.expectStdErrEqual("");
        test_step.dependOn(&global_oci_help.step);
        oci_cli_test_step.dependOn(&global_oci_help.step);

        const local_oci_help = b.addRunArtifact(wabt_exe);
        local_oci_help.addArgs(&.{ "oci", "help" });
        local_oci_help.expectExitCode(0);
        local_oci_help.expectStdOutEqual(oci_subject_help);
        local_oci_help.expectStdErrEqual("");
        test_step.dependOn(&local_oci_help.step);
        oci_cli_test_step.dependOn(&local_oci_help.step);

        const oci_help_cases = [_][2][]const u8{
            .{ "push", "Usage: wabt oci push REF FILE [options]" },
            .{ "pull", "Usage: wabt oci pull REF -o FILE [options]" },
            .{ "copy", "Usage: wabt oci copy SOURCE DESTINATION [options]" },
            .{ "inspect", "Usage: wabt oci inspect REF [options]" },
            .{ "resolve", "Usage: wabt oci resolve REF [options]" },
            .{ "list-tags", "Usage: wabt oci list-tags REGISTRY/REPOSITORY [options]" },
        };
        inline for (oci_help_cases) |case| {
            const global_leaf_help = b.addRunArtifact(wabt_exe);
            global_leaf_help.addArgs(&.{ "help", "oci", case[0] });
            global_leaf_help.expectExitCode(0);
            global_leaf_help.expectStdOutMatch(case[1]);
            global_leaf_help.expectStdErrEqual("");
            test_step.dependOn(&global_leaf_help.step);
            oci_cli_test_step.dependOn(&global_leaf_help.step);

            const local_leaf_help = b.addRunArtifact(wabt_exe);
            local_leaf_help.addArgs(&.{ "oci", "help", case[0] });
            local_leaf_help.expectExitCode(0);
            local_leaf_help.expectStdOutMatch(case[1]);
            local_leaf_help.expectStdErrEqual("");
            test_step.dependOn(&local_leaf_help.step);
            oci_cli_test_step.dependOn(&local_leaf_help.step);

            const positional_leaf_help = b.addRunArtifact(wabt_exe);
            positional_leaf_help.addArgs(&.{ "oci", case[0], "help" });
            positional_leaf_help.expectExitCode(0);
            positional_leaf_help.expectStdOutMatch(case[1]);
            positional_leaf_help.expectStdErrEqual("");
            test_step.dependOn(&positional_leaf_help.step);
            oci_cli_test_step.dependOn(&positional_leaf_help.step);

            const dash_h = b.addRunArtifact(wabt_exe);
            dash_h.addArgs(&.{ "oci", case[0], "-h" });
            dash_h.expectExitCode(1);
            dash_h.expectStdOutEqual("");
            test_step.dependOn(&dash_h.step);
            oci_cli_test_step.dependOn(&dash_h.step);

            const dash_help = b.addRunArtifact(wabt_exe);
            dash_help.addArgs(&.{ "oci", case[0], "--help" });
            dash_help.expectExitCode(1);
            dash_help.expectStdOutEqual("");
            test_step.dependOn(&dash_help.step);
            oci_cli_test_step.dependOn(&dash_help.step);
        }

        const oci_layout_fixture = b.addWriteFiles();
        _ = oci_layout_fixture.add(
            "oci-layout",
            "{\"imageLayoutVersion\":\"1.0.0\"}",
        );
        _ = oci_layout_fixture.add(
            "index.json",
            "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:5786275fcb65fe4d8856d79f032d2835db65e4795d83628a5313f54eefeed241\",\"size\":467,\"annotations\":{\"org.opencontainers.image.ref.name\":\"smoke\"}}]}",
        );
        _ = oci_layout_fixture.add(
            "blobs/sha256/5786275fcb65fe4d8856d79f032d2835db65e4795d83628a5313f54eefeed241",
            "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"artifactType\":\"application/wasm\",\"config\":{\"mediaType\":\"application/vnd.oci.empty.v1+json\",\"digest\":\"sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\",\"size\":2},\"layers\":[{\"mediaType\":\"application/wasm\",\"digest\":\"sha256:93a44bbb96c751218e4c00d479e4c14358122a389acca16205b1e4d0dc5f9476\",\"size\":8,\"annotations\":{\"org.opencontainers.image.title\":\"../../hostile.wasm\"}}]}",
        );
        _ = oci_layout_fixture.add(
            "blobs/sha256/44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
            "{}",
        );
        _ = oci_layout_fixture.add(
            "blobs/sha256/93a44bbb96c751218e4c00d479e4c14358122a389acca16205b1e4d0dc5f9476",
            "\x00asm\x01\x00\x00\x00",
        );
        const layout_directory = oci_layout_fixture.getDirectory();

        const layout_resolve = b.addRunArtifact(wabt_exe);
        layout_resolve.addArgs(&.{ "oci", "resolve" });
        layout_resolve.addDecoratedDirectoryArg(
            "oci:",
            layout_directory,
            ":smoke",
        );
        layout_resolve.expectExitCode(0);
        layout_resolve.expectStdOutMatch(
            "@sha256:5786275fcb65fe4d8856d79f032d2835db65e4795d83628a5313f54eefeed241",
        );
        layout_resolve.expectStdErrEqual("");
        test_step.dependOn(&layout_resolve.step);
        oci_cli_test_step.dependOn(&layout_resolve.step);

        const layout_inspect = b.addRunArtifact(wabt_exe);
        layout_inspect.addArgs(&.{ "oci", "inspect" });
        layout_inspect.addDecoratedDirectoryArg(
            "oci:",
            layout_directory,
            ":smoke",
        );
        layout_inspect.expectExitCode(0);
        layout_inspect.expectStdOutMatch("\"schema\":\"wabt.oci.inspect\"");
        layout_inspect.expectStdOutMatch("\"profile\":\"oci-1.1\"");
        layout_inspect.expectStdErrEqual("");
        test_step.dependOn(&layout_inspect.step);
        oci_cli_test_step.dependOn(&layout_inspect.step);

        const layout_pull = b.addRunArtifact(wabt_exe);
        layout_pull.addArgs(&.{ "oci", "pull" });
        layout_pull.addDecoratedDirectoryArg(
            "oci:",
            layout_directory,
            ":smoke",
        );
        layout_pull.addArg("-o");
        _ = layout_pull.addOutputFileArg("layout-smoke.wasm");
        layout_pull.expectExitCode(0);
        layout_pull.expectStdOutEqual("");
        layout_pull.expectStdErrEqual("");
        test_step.dependOn(&layout_pull.step);
        oci_cli_test_step.dependOn(&layout_pull.step);

        const layout_copy = b.addRunArtifact(wabt_exe);
        layout_copy.addArgs(&.{ "oci", "copy" });
        layout_copy.addDecoratedDirectoryArg(
            "oci:",
            layout_directory,
            ":smoke",
        );
        const copied_layout = layout_copy.addPrefixedOutputFileArg(
            "oci:",
            "copied-layout",
        );
        layout_copy.expectExitCode(0);
        layout_copy.expectStdOutEqual(
            "sha256:5786275fcb65fe4d8856d79f032d2835db65e4795d83628a5313f54eefeed241\n",
        );
        layout_copy.expectStdErrEqual("");
        test_step.dependOn(&layout_copy.step);
        oci_cli_test_step.dependOn(&layout_copy.step);

        const copied_layout_resolve = b.addRunArtifact(wabt_exe);
        copied_layout_resolve.addArgs(&.{ "oci", "resolve" });
        copied_layout_resolve.addPrefixedDirectoryArg(
            "oci:",
            copied_layout,
        );
        copied_layout_resolve.expectExitCode(0);
        copied_layout_resolve.expectStdOutMatch(
            "@sha256:5786275fcb65fe4d8856d79f032d2835db65e4795d83628a5313f54eefeed241",
        );
        copied_layout_resolve.expectStdErrEqual("");
        test_step.dependOn(&copied_layout_resolve.step);
        oci_cli_test_step.dependOn(&copied_layout_resolve.step);

        const oci_invalid_cases = [_]struct {
            args: []const []const u8,
            diagnostic: []const u8,
        }{
            .{
                .args = &.{ "oci", "push", "registry.example/team/app", "app.wasm" },
                .diagnostic = "error: wabt oci push: MissingSelection\n",
            },
            .{
                .args = &.{ "oci", "pull", "registry.example/team/app:tag", "-o", "out/" },
                .diagnostic = "error: wabt oci pull: InvalidOutputFile\n",
            },
            .{
                .args = &.{
                    "oci",                "copy",      "oci:source", "oci:destination",
                    "--source-auth-file", "auth.json",
                },
                .diagnostic = "error: wabt oci copy: RegistryOptionForLayout\n",
            },
            .{
                .args = &.{
                    "oci",        "resolve",                  "registry.example/team/app:tag",
                    "--password", "DO_NOT_PRINT_THIS_SECRET",
                },
                .diagnostic = "error: wabt oci resolve: PlaintextSecretOption\n",
            },
            .{
                .args = &.{
                    "oci",        "inspect", "registry.example/team/app:tag",
                    "--deadline", "0s",
                },
                .diagnostic = "error: wabt oci inspect: InvalidDuration\n",
            },
        };
        inline for (oci_invalid_cases) |case| {
            const invalid = b.addRunArtifact(wabt_exe);
            invalid.addArgs(case.args);
            invalid.expectExitCode(1);
            invalid.expectStdOutEqual("");
            invalid.expectStdErrEqual(case.diagnostic);
            test_step.dependOn(&invalid.step);
            oci_cli_test_step.dependOn(&invalid.step);
        }

        const oci_aliases = [_][]const []const u8{
            &.{ "oci", "registry" },
            &.{ "oci", "pin" },
            &.{ "oci", "list_tags" },
            &.{ "component", "push" },
        };
        inline for (oci_aliases) |case| {
            const rejected = b.addRunArtifact(wabt_exe);
            rejected.addArgs(case);
            rejected.expectExitCode(1);
            rejected.expectStdOutEqual("");
            test_step.dependOn(&rejected.step);
            oci_cli_test_step.dependOn(&rejected.step);
        }

        const global_nested_help_cases = [_][3][]const u8{
            .{ "text", "parse", "Usage: wabt text parse [options] <file.wat>" },
            .{ "module", "validate", "Usage: wabt module validate [options] <file.wasm>" },
        };
        inline for (global_nested_help_cases) |c| {
            const nested_help = b.addRunArtifact(wabt_exe);
            nested_help.addArgs(&.{ "help", c[0], c[1] });
            nested_help.expectExitCode(0);
            nested_help.expectStdOutMatch(c[2]);
            nested_help.expectStdOutMatch("--features <selectors>");
            nested_help.expectStdOutMatch("--enable-wide-arithmetic");
            test_step.dependOn(&nested_help.step);

            const invalid_nested_help = b.addRunArtifact(wabt_exe);
            invalid_nested_help.addArgs(&.{ "help", c[0], "not-a-real-verb" });
            invalid_nested_help.expectExitCode(1);
            invalid_nested_help.expectStdErrMatch(b.fmt("error: unknown {s} verb 'not-a-real-verb'", .{c[0]}));
            test_step.dependOn(&invalid_nested_help.step);
        }

        const subject_local_nested_help = b.addRunArtifact(wabt_exe);
        subject_local_nested_help.addArgs(&.{ "text", "help", "parse" });
        subject_local_nested_help.expectExitCode(0);
        subject_local_nested_help.expectStdOutMatch("Usage: wabt text parse [options] <file.wat>");
        subject_local_nested_help.expectStdOutMatch("--features <selectors>");
        subject_local_nested_help.expectStdOutMatch("--enable-wide-arithmetic");
        test_step.dependOn(&subject_local_nested_help.step);

        const cli_feature_fixtures = b.addWriteFiles();
        const wide_wat = cli_feature_fixtures.add(
            "wide-feature.wat",
            "(module (func (param i64 i64) (result i64 i64) local.get 0 local.get 1 i64.mul_wide_u))\n",
        );
        const custom_page_wat = cli_feature_fixtures.add(
            "custom-page-feature.wat",
            "(module (memory 0 (pagesize 1)))\n",
        );

        const parse_wide_alias = b.addRunArtifact(wabt_exe);
        parse_wide_alias.addArgs(&.{ "text", "parse", "--enable-wide-arithmetic" });
        parse_wide_alias.addFileArg(wide_wat);
        parse_wide_alias.addArg("-o");
        const wide_wasm = parse_wide_alias.addOutputFileArg("wide-feature.wasm");
        parse_wide_alias.expectExitCode(0);
        test_step.dependOn(&parse_wide_alias.step);

        const parse_wide_alias_after_selector = b.addRunArtifact(wabt_exe);
        parse_wide_alias_after_selector.addArgs(&.{
            "text", "parse", "--features=-all,multi-value", "--enable-wide-arithmetic",
        });
        parse_wide_alias_after_selector.addFileArg(wide_wat);
        parse_wide_alias_after_selector.addArg("-o");
        _ = parse_wide_alias_after_selector.addOutputFileArg("wide-alias-after-selector.wasm");
        parse_wide_alias_after_selector.expectExitCode(0);
        test_step.dependOn(&parse_wide_alias_after_selector.step);

        const parse_wide_selector_after_alias = b.addRunArtifact(wabt_exe);
        parse_wide_selector_after_alias.addArgs(&.{
            "text", "parse", "--enable-wide-arithmetic", "--features=-wide-arithmetic",
        });
        parse_wide_selector_after_alias.addFileArg(wide_wat);
        parse_wide_selector_after_alias.addArgs(&.{ "-o", "wide-selector-after-alias.wasm" });
        parse_wide_selector_after_alias.expectExitCode(1);
        parse_wide_selector_after_alias.expectStdErrMatch("error.UnsupportedOpcode");
        test_step.dependOn(&parse_wide_selector_after_alias.step);

        const parse_custom_page_alias = b.addRunArtifact(wabt_exe);
        parse_custom_page_alias.addArgs(&.{ "text", "parse", "--enable-custom-page-sizes" });
        parse_custom_page_alias.addFileArg(custom_page_wat);
        parse_custom_page_alias.addArg("-o");
        const custom_page_wasm = parse_custom_page_alias.addOutputFileArg("custom-page-feature.wasm");
        parse_custom_page_alias.expectExitCode(0);
        test_step.dependOn(&parse_custom_page_alias.step);

        const parse_custom_page_selector_after_alias = b.addRunArtifact(wabt_exe);
        parse_custom_page_selector_after_alias.addArgs(&.{
            "text", "parse", "--enable-custom-page-sizes", "--features=-custom-page-sizes",
        });
        parse_custom_page_selector_after_alias.addFileArg(custom_page_wat);
        parse_custom_page_selector_after_alias.addArgs(&.{ "-o", "custom-page-selector-after-alias.wasm" });
        parse_custom_page_selector_after_alias.expectExitCode(1);
        parse_custom_page_selector_after_alias.expectStdErrMatch("error.InvalidLimits");
        test_step.dependOn(&parse_custom_page_selector_after_alias.step);

        const validate_wide_alias = b.addRunArtifact(wabt_exe);
        validate_wide_alias.addArgs(&.{ "module", "validate", "--enable-wide-arithmetic" });
        validate_wide_alias.addFileArg(wide_wasm);
        validate_wide_alias.expectExitCode(0);
        test_step.dependOn(&validate_wide_alias.step);

        const validate_wide_selector_after_alias = b.addRunArtifact(wabt_exe);
        validate_wide_selector_after_alias.addArgs(&.{
            "module", "validate", "--enable-wide-arithmetic", "--features=-wide-arithmetic",
        });
        validate_wide_selector_after_alias.addFileArg(wide_wasm);
        validate_wide_selector_after_alias.expectExitCode(1);
        validate_wide_selector_after_alias.expectStdErrMatch("error.UnsupportedOpcode");
        test_step.dependOn(&validate_wide_selector_after_alias.step);

        const validate_custom_page_alias = b.addRunArtifact(wabt_exe);
        validate_custom_page_alias.addArgs(&.{ "module", "validate", "--enable-custom-page-sizes" });
        validate_custom_page_alias.addFileArg(custom_page_wasm);
        validate_custom_page_alias.expectExitCode(0);
        test_step.dependOn(&validate_custom_page_alias.step);

        const validate_custom_page_selector_after_alias = b.addRunArtifact(wabt_exe);
        validate_custom_page_selector_after_alias.addArgs(&.{
            "module", "validate", "--enable-custom-page-sizes", "--features=-custom-page-sizes",
        });
        validate_custom_page_selector_after_alias.addFileArg(custom_page_wasm);
        validate_custom_page_selector_after_alias.expectExitCode(1);
        validate_custom_page_selector_after_alias.expectStdErrMatch("error.InvalidLimits");
        test_step.dependOn(&validate_custom_page_selector_after_alias.step);

        const wabt_no_subcmd = b.addRunArtifact(wabt_exe);
        wabt_no_subcmd.expectExitCode(1);
        test_step.dependOn(&wabt_no_subcmd.step);

        const wabt_unknown = b.addRunArtifact(wabt_exe);
        wabt_unknown.addArg("not-a-real-subcommand");
        wabt_unknown.expectExitCode(1);
        test_step.dependOn(&wabt_unknown.step);

        // #232 — `wabt component objdump <component>` exits 0 and
        // produces the expected summary header; `wabt module objdump`
        // rejects the component preamble with the redirect message
        // (and non-zero exit) instead of `error.InvalidVersion`.
        const objdump_ok = b.addRunArtifact(wabt_exe);
        objdump_ok.addArgs(&.{ "component", "objdump", "src/component/fixtures/stdio-echo.wasm" });
        objdump_ok.expectExitCode(0);
        objdump_ok.expectStdOutMatch("wabt component objdump:");
        objdump_ok.expectStdOutMatch("Section order:");
        objdump_ok.expectStdOutMatch("Core modules:");
        objdump_ok.expectStdOutMatch("Component imports:");
        test_step.dependOn(&objdump_ok.step);

        const module_objdump_redirect = b.addRunArtifact(wabt_exe);
        module_objdump_redirect.addArgs(&.{ "module", "objdump", "src/component/fixtures/stdio-echo.wasm" });
        module_objdump_redirect.expectExitCode(1);
        module_objdump_redirect.expectStdErrMatch("wabt component objdump");
        test_step.dependOn(&module_objdump_redirect.step);

        // ── #185: leaf `help` subword + rejected -h / --help flags ──
        //
        // One representative leaf per subject. The positional `help`
        // form must exit 0; the legacy `-h` / `--help` flags must be
        // rejected as unknown options (exit non-zero). Mirrors the
        // top-level `parseSubcommand` test assertions in
        // `src/tools/wabt.zig` at the verb tier.
        const help_cases = [_][3][]const u8{
            .{ "text", "parse", "<input.wat>" },
            .{ "module", "validate", "<input.wasm>" },
            .{ "component", "new", "<input.wasm>" },
            .{ "spec", "to-json", "<input.wast>" },
        };
        inline for (help_cases) |c| {
            const subject = c[0];
            const verb = c[1];

            // `wabt <subject> <verb> help` → exit 0.
            const ok = b.addRunArtifact(wabt_exe);
            ok.addArgs(&.{ subject, verb, "help" });
            ok.expectExitCode(0);
            test_step.dependOn(&ok.step);

            // `wabt <subject> <verb> -h` → exit non-zero (the flag is
            // no longer recognised; the leaf falls through to its
            // existing unknown-option / missing-input error path).
            const dash_h = b.addRunArtifact(wabt_exe);
            dash_h.addArgs(&.{ subject, verb, "-h" });
            dash_h.expectExitCode(1);
            test_step.dependOn(&dash_h.step);

            // `wabt <subject> <verb> --help` → exit non-zero, same
            // reasoning as above.
            const dash_help = b.addRunArtifact(wabt_exe);
            dash_help.addArgs(&.{ subject, verb, "--help" });
            dash_help.expectExitCode(1);
            test_step.dependOn(&dash_help.step);
        }
    }

    // ── WASI Preview 3 conformance gate (#267 Phase 3) ────────────────
    // wabt is a toolkit, not a runtime: this gate drives the hand-authored
    // `tests/p3/*.wat` guests through `wabt component new`, then validates
    // each produced component on upstream Wasmtime (resolved from the
    // `WASMTIME` env var; needs P3 feature flags, e.g. wasmtime >= 46). Not
    // wired into the default `test` aggregate — it requires Python 3 + an
    // external Wasmtime, and skips cleanly when none is found. CI gates
    // regressions in a follow-up. Run locally with `zig build p3-conformance`
    // (optionally `WASMTIME=/path/to/wasmtime`).
    const p3_runner = b.addSystemCommand(&.{
        "python3",
        "scripts/p3_conformance.py",
        "--fixtures",
        "tests/p3",
        "--skip",
        "tests/p3-conformance-skip.json",
        "--wabt",
    });
    p3_runner.addArtifactArg(wabt_exe);
    // CI installs a pinned Wasmtime and sets this so a missing/broken
    // Wasmtime is a hard failure rather than a silent skip.
    if (p3_require_wasmtime) p3_runner.addArg("--require-wasmtime");
    const p3_step = b.step(
        "p3-conformance",
        "Validate wabt-produced P3 components against Wasmtime (set WASMTIME)",
    );
    p3_step.dependOn(&p3_runner.step);

    // ── WASI Preview 3 component decode gate (#267 Phase 4) ────────────
    // Where `p3-conformance` validates that the components wabt *produces*
    // from hand-authored single-built-in fixtures are accepted by Wasmtime
    // (`wasmtime compile`), this gate runs the other direction: it feeds
    // wabt the **real-world** `wasm32-wasip3` components from the upstream
    // WASI testsuite (vendored at `tests/wasi-testsuite`) and requires wabt's
    // component loader to decode every one (`wabt component objdump`). wabt is
    // a toolkit, not a runtime, so this is the loader-parity analog of the
    // wamr project's wasip3 runtime gate. Not in the default `test` aggregate
    // (needs Python 3 + the testsuite submodule); skips cleanly when the suite
    // isn't checked out. Run locally with `zig build wasi-p3-testsuite`.
    const wasip3_runner = b.addSystemCommand(&.{
        "python3",
        "scripts/wasi_p3_testsuite.py",
        "--skip",
        "tests/wasi-p3-testsuite-skip.json",
        "--wabt",
    });
    wasip3_runner.addArtifactArg(wabt_exe);
    if (wasip3_require_suite) wasip3_runner.addArg("--require-suite");
    const wasip3_step = b.step(
        "wasi-p3-testsuite",
        "Decode + byte-identical round-trip upstream wasm32-wasip3 components with wabt",
    );
    wasip3_step.dependOn(&wasip3_runner.step);
}

/// Adapter shape selector used by `buildAdapterArtifact` to pick
/// the per-shape fragment list. The named output file embeds the
/// shape in its filename so both artifacts can co-exist under
/// `zig-out/adapter/`.
const AdapterShape = enum {
    command,
    reactor,

    fn worldName(self: AdapterShape) []const u8 {
        return switch (self) {
            .command => "command",
            .reactor => "reactor",
        };
    }

    fn outputBasename(self: AdapterShape) []const u8 {
        return switch (self) {
            .command => "wasi_snapshot_preview1.command.wasm",
            .reactor => "wasi_snapshot_preview1.reactor.wasm",
        };
    }
};

/// Run `build-wasi-preview1-adapter` for one shape and return the
/// generated `LazyPath`. Argv layout:
///
///     <wit-dir> <world-name> <output.wasm> \
///         prelude.wat <shape>-imports.wat body.wat <shape>-impl.wat \
///         realloc.wat exports.wat <shape>-footer.wat
///
/// Fragment order matters — see
/// `adapters/wasi-preview1/src/fragments/README.md` for the cut
/// rationale (imports must precede non-import defs; the per-shape
/// `*-impl.wat` supplies trap-stub funcs or the `$run` entry).
fn buildAdapterArtifact(
    b: *std.Build,
    tool_exe: *std.Build.Step.Compile,
    shape: AdapterShape,
) std.Build.LazyPath {
    const run = b.addRunArtifact(tool_exe);
    // <wit-dir>
    run.addDirectoryArg(b.path("adapters/wasi-preview1/wit"));
    // <world-name>
    run.addArg(shape.worldName());
    // <output.wasm>
    const out = run.addOutputFileArg(shape.outputBasename());

    const frag_dir = "adapters/wasi-preview1/src/fragments";
    const per_shape_imports = switch (shape) {
        .command => "command-imports.wat",
        .reactor => "reactor-imports.wat",
    };
    const per_shape_impl = switch (shape) {
        .command => "command-impl.wat",
        .reactor => "reactor-impl.wat",
    };
    const per_shape_footer = switch (shape) {
        .command => "command-footer.wat",
        .reactor => "reactor-footer.wat",
    };
    const fragments = [_][]const u8{
        "prelude.wat",
        per_shape_imports,
        "body.wat",
        per_shape_impl,
        "realloc.wat",
        "exports.wat",
        per_shape_footer,
    };
    for (fragments) |frag| {
        const full = b.pathJoin(&.{ frag_dir, frag });
        run.addFileArg(b.path(full));
    }
    return out;
}
