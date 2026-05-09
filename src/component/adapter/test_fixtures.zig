//! Test-only synthesizers that produce a splice-shaped (adapter,
//! embed) pair from scratch.
//!
//! The wabt adapter splicer (`adapter.zig::splice`) is exercised in
//! three layers today:
//!
//!   1. Per-module unit tests (`decode.zig`, `core_imports.zig`,
//!      `shim.zig`, `fixup.zig`, `types_import.zig`, `abi.zig`,
//!      `gc.zig`, `world_gc.zig`).
//!   2. Standalone helper tests in `adapter.zig`
//!      (`stripComponentTypeSections`, `buildMainModuleFallback`,
//!      `coreToCompValType`).
//!   3. End-to-end via the wamr fixtures (`zig-hello`,
//!      `zig-calculator-cmd`, `mixed-zig-rust-calc`) — out-of-tree.
//!
//! What's missing — and what this module enables — is an in-tree
//! end-to-end assertion that `splice()` produces a structurally
//! correct component on a hermetic synthesised input pair. A
//! regression in the splicer's choreography that today only fails
//! the wamr CI lane will then also fail `zig build test`.
//!
//! The synthesised pair is the smallest shape that exercises every
//! phase of `splice()`:
//!
//!   * encoded-world AST GC (one live WASI namespace, `stdout`)
//!   * adapter core-wasm GC (exactly one preview1 export survives)
//!   * types-import hoist (top-level `wasi:cli/stdout@…` import)
//!   * canon-lift of `wasi:cli/run@<ver>#run` to top-level
//!   * shim + fixup choreography for at least one slot
//!
//! Constraints met by the current shape:
//!
//!   * The world's package MUST be `wasi:cli` because
//!     `findRunInstanceExport` (adapter.zig:1084) hardcodes
//!     `startsWith("wasi:cli/run")` to locate the lifted entry.
//!   * Every WIT func uses primitive params/results so
//!     `metadata_encode.encodeWorldFromSource` accepts the source
//!     and `abi.classifyFunc` returns `.direct` (no canon-lower
//!     memory/realloc options). Indirect-shim coverage exists
//!     elsewhere; this fixture is intentionally simple.
//!
//! Synthesis style is hand-rolled byte streams (mirroring
//! `core_imports.zig::buildMockAdapterCore`) — `Module.zig` /
//! `binary/writer.zig` could express the same shape, but going
//! through the public encoder for tests would couple this fixture
//! to the encoder's quirks. Hand-rolling keeps the fixture
//! self-contained.

const std = @import("std");
const Allocator = std.mem.Allocator;

const leb = @import("../../leb128.zig");
const metadata_encode = @import("../wit/metadata_encode.zig");

const ADAPTER_WIT =
    \\package wasi:cli@0.1.0;
    \\
    \\interface stdout {
    \\    flush: func() -> u32;
    \\}
    \\
    \\interface run {
    \\    run: func() -> u32;
    \\}
    \\
    \\world command {
    \\    import stdout;
    \\    export run;
    \\}
;

const REACTOR_ADAPTER_WIT =
    \\package wasi:cli@0.1.0;
    \\
    \\interface stdout {
    \\    flush: func() -> u32;
    \\}
    \\
    \\world reactor {
    \\    import stdout;
    \\}
;

const REACTOR_EMBED_WIT =
    \\package docs:counter@0.1.0;
    \\
    \\interface api {
    \\    bump: func() -> u32;
    \\}
    \\
    \\world counter {
    \\    export api;
    \\}
;

pub const ADAPTER_CT_SECTION_NAME = "component-type:wit-bindgen:0.0.0-mock:wasi:cli@0.1.0:command:encoded world";
pub const REACTOR_ADAPTER_CT_SECTION_NAME = "component-type:wit-bindgen:0.0.0-mock:wasi:cli@0.1.0:reactor:encoded world";
pub const EMBED_CT_SECTION_NAME = "component-type:embed-mock";
pub const REACTOR_EMBED_CT_SECTION_NAME = "component-type:docs:counter@0.1.0:counter:encoded world";

pub const PREVIEW1_EXPORT = "fd_write";
pub const RUN_EXPORT = "wasi:cli/run@0.1.0#run";
pub const STDOUT_NAMESPACE = "wasi:cli/stdout@0.1.0";
pub const STDOUT_FUNC = "flush";
pub const REACTOR_API_NAMESPACE = "docs:counter/api@0.1.0";
pub const REACTOR_API_FUNC = "bump";
pub const REACTOR_API_CORE_EXPORT = "docs:counter/api@0.1.0#bump";

/// Build a synthetic preview1-shape adapter core wasm.
///
/// Imports:
///   * `env.memory`                          (memory 0)
///   * `__main_module__._start`              (func, () -> ())
///   * `wasi:cli/stdout@0.1.0.flush`         (func, () -> i32 — canon-lower)
///
/// Exports:
///   * `fd_write`                            (preview1 entry; () -> i32)
///   * `wasi:cli/run@0.1.0#run`              (run entry; () -> i32)
///   * `cabi_import_realloc`                 (canon-lower realloc helper)
///
/// Custom sections:
///   * `component-type:…wasi:cli@0.1.0:command:encoded world` — payload
///     is the `wasi:cli@0.1.0`/`world command` encoded by
///     `metadata_encode.encodeWorldFromSource`.
///
/// The first and third defined func bodies are trivial `i32.const 0; end`;
/// `run` (the middle body) calls the imported `stdout.flush` and
/// returns its result, so the adapter's GC keeps the stdout import
/// live and `live_namespaces` survives splice. Caller frees with
/// the same allocator.
pub fn buildSyntheticAdapter(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, ADAPTER_WIT, "command");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 2 func types — both `() -> i32`, plus `() -> ()`
    // for `_start`. Indices: 0 = () -> i32, 1 = () -> ().
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        // type 0: () -> i32
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        // type 1: () -> ()
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: env.memory, __main_module__._start, wasi:cli/stdout.flush
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03); // count
        // env.memory: memory 0 (limits: min 0, no max)
        try writeName(allocator, &b, "env");
        try writeName(allocator, &b, "memory");
        try b.append(allocator, 0x02); // import desc: memory
        try b.append(allocator, 0x00); // limits flag: no max
        try b.append(allocator, 0x00); // min 0
        // __main_module__._start: func type 1
        try writeName(allocator, &b, "__main_module__");
        try writeName(allocator, &b, "_start");
        try b.append(allocator, 0x00); // import desc: func
        try b.append(allocator, 0x01); // typeidx 1 (() -> ())
        // wasi:cli/stdout@0.1.0.flush: func type 0
        try writeName(allocator, &b, STDOUT_NAMESPACE);
        try writeName(allocator, &b, STDOUT_FUNC);
        try b.append(allocator, 0x00); // import desc: func
        try b.append(allocator, 0x00); // typeidx 0 (() -> i32)
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 3 defined funcs (fd_write, run, cabi_import_realloc), all type 0
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03); // count
        try b.appendSlice(allocator, &.{ 0x00, 0x00, 0x00 }); // typeidx 0 ×3
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Export section: fd_write (func 2), run-shape (func 3), cabi_import_realloc (func 4).
    // Defined func indices start after imports: imported funcs are
    // _start (idx 0) and stdout.flush (idx 1).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03); // count
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x02 }); // func, idx 2
        try writeName(allocator, &b, RUN_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x03 }); // func, idx 3
        try writeName(allocator, &b, "cabi_import_realloc");
        try b.appendSlice(allocator, &.{ 0x00, 0x04 }); // func, idx 4
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: 3 bodies. fd_write and cabi_import_realloc are
    // trivial `i32.const 0; end`; `run` calls `stdout.flush` (imported
    // func idx 1) and returns its result, so the adapter's GC keeps
    // the stdout import live and `live_namespaces` survives splice.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03); // count
        // body 0 (fd_write): i32.const 0; end
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b });
        // body 1 (run): call $1 (stdout.flush); end
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x10, 0x01, 0x0b });
        // body 2 (cabi_import_realloc): i32.const 0; end
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    // Custom section with the encoded-world payload — last so it
    // doesn't perturb the standard section ordering.
    try appendCustomSection(allocator, &out, ADAPTER_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic preview1 embed core wasm.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///
/// Exports:
///   * `_start`                              (func, () -> ())
///   * `memory`                              (memory 0)
///
/// The defined `_start` body is `i32.const 0; drop; end` — keeps the
/// validator happy without producing a meaningful side effect.
/// Caller frees with the same allocator.
pub fn buildSyntheticEmbed(allocator: Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 2 types — () -> i32 (the import sig) and () -> () (_start).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: wasi_snapshot_preview1.fd_write (func type 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00); // func
        try b.append(allocator, 0x00); // typeidx 0
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 1 defined func (_start, type 1)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x01); // typeidx 1
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Memory section: 1 memory (limits: min 0, no max)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00); // limits flag
        try b.append(allocator, 0x00); // min
        try writeSection(allocator, &out, 0x05, b.items);
    }

    // Export section: _start (func 1), memory (memory 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, "_start");
        try b.appendSlice(allocator, &.{ 0x00, 0x01 }); // func, defined idx 1 (import is 0)
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 }); // memory, idx 0
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: _start body is `i32.const 0; drop; end`
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x05);                            // body size
        try b.append(allocator, 0x00);                            // 0 locals
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x1a, 0x0b }); // i32.const 0; drop; end
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    return out.toOwnedSlice(allocator);
}

pub const SECONDARY_NAME = "mock_host";
pub const SECONDARY_EXPORT = "do_thing";

/// Build a synthetic bare-shim secondary adapter core wasm.
///
/// Imports:
///   * `env.memory`                          (memory 0)
///
/// Exports:
///   * `do_thing`                            (func, () -> i32)
///
/// No `wasi:cli/run` export, no encoded-world custom section, and
/// no `__main_module__` or WASI namespace imports — exactly the
/// "bare host-shim" shape `spliceN` accepts as a secondary adapter
/// in #114. Caller frees with the same allocator.
pub fn buildBareSecondaryAdapter(allocator: Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 1 type — () -> i32
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: env.memory (memory 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try writeName(allocator, &b, "env");
        try writeName(allocator, &b, "memory");
        try b.append(allocator, 0x02); // memory
        try b.append(allocator, 0x00); // limits flag
        try b.append(allocator, 0x00); // min
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 1 defined func, type 0
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00); // typeidx 0
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Export section: do_thing (func 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try writeName(allocator, &b, SECONDARY_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x00 }); // func, idx 0
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: do_thing body is `i32.const 0; end`
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x04); // body size
        try b.append(allocator, 0x00); // 0 locals
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b }); // i32.const 0; end
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic embed core wasm that imports BOTH preview1
/// and a bare-shim secondary's host function — exercises
/// `spliceMany` on N=2.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///   * `mock_host.do_thing`                  (func, () -> i32)
///
/// Exports:
///   * `_start`                              (func, () -> ())
///   * `memory`                              (memory 0)
///
/// `_start` calls both imports (drops their results) so the
/// adapter GC keeps both imports live across `spliceMany`.
pub fn buildSyntheticEmbedWithSecondary(allocator: Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: () -> i32 and () -> ()
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: preview1.fd_write, mock_host.do_thing
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        // wasi_snapshot_preview1.fd_write — type 0
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        // mock_host.do_thing — type 0
        try writeName(allocator, &b, SECONDARY_NAME);
        try writeName(allocator, &b, SECONDARY_EXPORT);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 1 defined func (_start, type 1)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x01);
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Memory section: 1 memory
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeSection(allocator, &out, 0x05, b.items);
    }

    // Export section: _start (func 2 — imports take 0,1), memory (0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, "_start");
        try b.appendSlice(allocator, &.{ 0x00, 0x02 });
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: _start = call $0; drop; call $1; drop; end
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x08); // body size: 1 (locals) + 7 (code) = 8
        try b.append(allocator, 0x00); // 0 locals
        try b.appendSlice(allocator, &.{
            0x10, 0x00, 0x1a, // call $0; drop
            0x10, 0x01, 0x1a, // call $1; drop
            0x0b, // end
        });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic preview1-shape **reactor** adapter core wasm.
///
/// Differs from `buildSyntheticAdapter` in two structural ways that
/// classify it as a reactor under `adapter.detectShape`:
///
///   * No `<iface>#<name>` core export (no `wasi:cli/run` lifted entry).
///   * No `__main_module__.<x>` core import (long-lived, not driven
///     by `_start`).
///
/// Imports:
///   * `env.memory`                          (memory 0)
///   * `wasi:cli/stdout@0.1.0.flush`         (func, () -> i32 — canon-lower)
///
/// Exports:
///   * `fd_write`                            (preview1 entry; () -> i32)
///   * `cabi_import_realloc`                 (canon-lower realloc helper)
///
/// Custom section: `component-type:…wasi:cli@0.1.0:reactor:encoded world`
/// — payload is the `wasi:cli@0.1.0`/`world reactor` (import-only)
/// produced by `metadata_encode.encodeWorldFromSource`. Caller frees
/// with the same allocator.
pub fn buildSyntheticReactorAdapter(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, REACTOR_ADAPTER_WIT, "reactor");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 1 type — () -> i32 (every defined func + the
    // imported stdout.flush share this signature).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01); // count
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: env.memory, wasi:cli/stdout.flush
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        // env.memory: memory 0 (limits: min 0, no max)
        try writeName(allocator, &b, "env");
        try writeName(allocator, &b, "memory");
        try b.append(allocator, 0x02); // memory
        try b.append(allocator, 0x00); // limits flag
        try b.append(allocator, 0x00); // min
        // wasi:cli/stdout@0.1.0.flush: func type 0
        try writeName(allocator, &b, STDOUT_NAMESPACE);
        try writeName(allocator, &b, STDOUT_FUNC);
        try b.append(allocator, 0x00); // func
        try b.append(allocator, 0x00); // typeidx 0
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 2 defined funcs (fd_write, cabi_import_realloc), all type 0
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        try b.appendSlice(allocator, &.{ 0x00, 0x00 }); // typeidx 0 ×2
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Export section: fd_write (func 1), cabi_import_realloc (func 2).
    // Imported func is at idx 0 (stdout.flush).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x01 }); // func, idx 1
        try writeName(allocator, &b, "cabi_import_realloc");
        try b.appendSlice(allocator, &.{ 0x00, 0x02 }); // func, idx 2
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: 2 bodies. fd_write calls stdout.flush (imported
    // func idx 0) and returns its result, so the adapter's GC keeps
    // the stdout import live. cabi_import_realloc is trivial.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        // body 0 (fd_write): call $0 (stdout.flush); end
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x10, 0x00, 0x0b });
        // body 1 (cabi_import_realloc): i32.const 0; end
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, REACTOR_ADAPTER_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic **reactor** embed core wasm.
///
/// Differs from `buildSyntheticEmbed` in two ways:
///
///   * No `_start` export (long-lived; entry comes from the
///     wrapping component's lifted exports).
///   * Has a `<iface>#<func>`-shape core export
///     (`docs:counter/api@0.1.0#bump`) — the lift target.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///
/// Exports:
///   * `docs:counter/api@0.1.0#bump`         (func, () -> i32)
///   * `memory`                              (memory 0)
///
/// Custom section: `component-type:counter` — payload is the
/// `docs:counter@0.1.0`/`world counter { export api; }` produced by
/// `metadata_encode.encodeWorldFromSource`. The reactor branch in
/// `assemble()` reads this to recover the WIT signature for canon-lift.
///
/// `bump` calls `fd_write` (drops result) and returns `i32.const 42`.
/// Caller frees with the same allocator.
pub fn buildSyntheticReactorEmbed(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, REACTOR_EMBED_WIT, "counter");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 1 type — () -> i32 (shared by the import and bump).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: wasi_snapshot_preview1.fd_write (func type 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00); // func
        try b.append(allocator, 0x00); // typeidx 0
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 1 defined func (bump, type 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00); // typeidx 0
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Memory section: 1 memory (limits: min 0, no max)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeSection(allocator, &out, 0x05, b.items);
    }

    // Export section: <iface>#bump (func 1 — import takes 0), memory (0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, REACTOR_API_CORE_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x01 }); // func, idx 1
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: bump = call $0; drop; i32.const 42; end
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x07); // body size: 1 (locals) + 6 (code)
        try b.append(allocator, 0x00); // 0 locals
        try b.appendSlice(allocator, &.{
            0x10, 0x00, 0x1a, // call $0; drop
            0x41, 42, // i32.const 42
            0x0b, // end
        });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, REACTOR_EMBED_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic **reactor** embed that imports BOTH preview1
/// and a bare-shim secondary's host function — exercises
/// `spliceMany` on a reactor primary + bare secondary.
///
/// Differs from `buildSyntheticEmbedWithSecondary`:
///   * No `_start` export (reactor shape).
///   * Has `<iface>#bump` core export — the lift target.
///   * Carries a `component-type:counter` custom section.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///   * `mock_host.do_thing`                  (func, () -> i32)
///
/// Exports:
///   * `docs:counter/api@0.1.0#bump`         (func, () -> i32)
///   * `memory`                              (memory 0)
///
/// `bump` calls both imports (drops their results) so the adapter
/// GC keeps both imports live across `spliceMany`. Returns
/// `i32.const 42`. Caller frees with the same allocator.
pub fn buildSyntheticReactorEmbedWithSecondary(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, REACTOR_EMBED_WIT, "counter");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 1 type — () -> i32.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: preview1.fd_write, mock_host.do_thing
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        // wasi_snapshot_preview1.fd_write — type 0
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        // mock_host.do_thing — type 0
        try writeName(allocator, &b, SECONDARY_NAME);
        try writeName(allocator, &b, SECONDARY_EXPORT);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 1 defined func (bump, type 0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00);
        try writeSection(allocator, &out, 0x03, b.items);
    }

    // Memory section: 1 memory
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeSection(allocator, &out, 0x05, b.items);
    }

    // Export section: <iface>#bump (func 2 — imports take 0,1), memory (0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, REACTOR_API_CORE_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x02 });
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: bump = call $0; drop; call $1; drop; i32.const 42; end
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x0a); // body size: 1 (locals) + 9 (code)
        try b.append(allocator, 0x00); // 0 locals
        try b.appendSlice(allocator, &.{
            0x10, 0x00, 0x1a, // call $0; drop
            0x10, 0x01, 0x1a, // call $1; drop
            0x41, 42, // i32.const 42
            0x0b, // end
        });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, REACTOR_EMBED_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

// ── byte-stream helpers ──────────────────────────────────────────────────

fn writeMagic(allocator: Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
}

fn writeSection(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    id: u8,
    body: []const u8,
) !void {
    try out.append(allocator, id);
    var len_buf: [leb.max_u32_bytes]u8 = undefined;
    const n = leb.writeU32Leb128(&len_buf, @intCast(body.len));
    try out.appendSlice(allocator, len_buf[0..n]);
    try out.appendSlice(allocator, body);
}

fn writeName(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    var len_buf: [leb.max_u32_bytes]u8 = undefined;
    const n = leb.writeU32Leb128(&len_buf, @intCast(name.len));
    try out.appendSlice(allocator, len_buf[0..n]);
    try out.appendSlice(allocator, name);
}

fn appendCustomSection(
    allocator: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    payload: []const u8,
) !void {
    var name_leb_buf: [leb.max_u32_bytes]u8 = undefined;
    const name_leb_n = leb.writeU32Leb128(&name_leb_buf, @intCast(name.len));
    const body_len = name_leb_n + name.len + payload.len;

    try out.append(allocator, 0x00); // custom section id
    var size_leb_buf: [leb.max_u32_bytes]u8 = undefined;
    const size_leb_n = leb.writeU32Leb128(&size_leb_buf, @intCast(body_len));
    try out.appendSlice(allocator, size_leb_buf[0..size_leb_n]);
    try out.appendSlice(allocator, name_leb_buf[0..name_leb_n]);
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, payload);
}

// ── self-tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const reader = @import("../../binary/reader.zig");
const decode = @import("decode.zig");
const core_imports = @import("core_imports.zig");

test "buildSyntheticAdapter: parses through reader and exposes expected imports/exports" {
    const adapter_bytes = try buildSyntheticAdapter(testing.allocator);
    defer testing.allocator.free(adapter_bytes);

    var owned = try core_imports.extract(testing.allocator, adapter_bytes);
    defer owned.deinit();

    // Exports the preview1 entry, the run-shape entry, and realloc.
    try testing.expect(owned.interface.findExport(PREVIEW1_EXPORT) != null);
    try testing.expect(owned.interface.findExport(RUN_EXPORT) != null);
    try testing.expect(owned.interface.findExport("cabi_import_realloc") != null);

    // Imports include the canon-lower'd stdout.flush.
    var saw_stdout = false;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, STDOUT_NAMESPACE) and
            std.mem.eql(u8, im.field_name, STDOUT_FUNC))
        {
            saw_stdout = true;
        }
    }
    try testing.expect(saw_stdout);
}

test "buildSyntheticAdapter: encoded-world section round-trips through decode" {
    const adapter_bytes = try buildSyntheticAdapter(testing.allocator);
    defer testing.allocator.free(adapter_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try decode.parseFromAdapterCore(arena.allocator(), adapter_bytes);

    // World imports `stdout`, exports `run`.
    try testing.expectEqual(@as(usize, 1), w.imports.len);
    try testing.expectEqualStrings(STDOUT_NAMESPACE, w.imports[0].name);
    try testing.expectEqual(@as(usize, 1), w.exports.len);
    try testing.expect(std.mem.startsWith(u8, w.exports[0].name, "wasi:cli/run@"));
}

test "buildSyntheticEmbed: parses through reader and matches preview1 contract" {
    const embed_bytes = try buildSyntheticEmbed(testing.allocator);
    defer testing.allocator.free(embed_bytes);

    var owned = try core_imports.extract(testing.allocator, embed_bytes);
    defer owned.deinit();

    // Embed imports preview1.fd_write so `splice` will GC the adapter
    // down to that one preview1 export.
    var saw_p1 = false;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, "wasi_snapshot_preview1") and
            std.mem.eql(u8, im.field_name, PREVIEW1_EXPORT))
        {
            saw_p1 = true;
        }
    }
    try testing.expect(saw_p1);
    try testing.expect(owned.interface.findExport("_start") != null);
}

test "buildBareSecondaryAdapter: parses and exposes do_thing export with env.memory only" {
    const sec_bytes = try buildBareSecondaryAdapter(testing.allocator);
    defer testing.allocator.free(sec_bytes);

    var owned = try core_imports.extract(testing.allocator, sec_bytes);
    defer owned.deinit();

    // do_thing must be exported.
    try testing.expect(owned.interface.findExport(SECONDARY_EXPORT) != null);
    // No `wasi:cli/run` export — secondary is bare.
    for (owned.interface.exports) |ex| {
        try testing.expect(std.mem.indexOfScalar(u8, ex.name, '#') == null);
    }
    // Every import is `env.<x>` — bare-shim contract.
    for (owned.interface.imports) |im| {
        try testing.expectEqualStrings("env", im.module_name);
    }
}

test "buildSyntheticEmbedWithSecondary: imports both preview1 and mock_host" {
    const embed_bytes = try buildSyntheticEmbedWithSecondary(testing.allocator);
    defer testing.allocator.free(embed_bytes);

    var owned = try core_imports.extract(testing.allocator, embed_bytes);
    defer owned.deinit();

    var saw_p1 = false;
    var saw_sec = false;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, "wasi_snapshot_preview1") and
            std.mem.eql(u8, im.field_name, PREVIEW1_EXPORT)) saw_p1 = true;
        if (std.mem.eql(u8, im.module_name, SECONDARY_NAME) and
            std.mem.eql(u8, im.field_name, SECONDARY_EXPORT)) saw_sec = true;
    }
    try testing.expect(saw_p1);
    try testing.expect(saw_sec);
    try testing.expect(owned.interface.findExport("_start") != null);
}

test "buildSyntheticReactorAdapter: parses through reader, no run export, no __main_module__ import" {
    const ad_bytes = try buildSyntheticReactorAdapter(testing.allocator);
    defer testing.allocator.free(ad_bytes);

    var owned = try core_imports.extract(testing.allocator, ad_bytes);
    defer owned.deinit();

    // Preview1 entry + canon-lower realloc are the only exports.
    try testing.expect(owned.interface.findExport(PREVIEW1_EXPORT) != null);
    try testing.expect(owned.interface.findExport("cabi_import_realloc") != null);
    // No `<iface>#name` export — that's the reactor signal.
    for (owned.interface.exports) |ex| {
        try testing.expect(std.mem.indexOfScalar(u8, ex.name, '#') == null);
    }
    // No `__main_module__.<x>` import — reactor adapters have none.
    for (owned.interface.imports) |im| {
        try testing.expect(!std.mem.eql(u8, im.module_name, "__main_module__"));
    }
    // Stdout import must survive — adapter GC keeps it live via fd_write's body.
    var saw_stdout = false;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, STDOUT_NAMESPACE) and
            std.mem.eql(u8, im.field_name, STDOUT_FUNC)) saw_stdout = true;
    }
    try testing.expect(saw_stdout);
}

test "buildSyntheticReactorAdapter: encoded-world section round-trips through decode" {
    const ad_bytes = try buildSyntheticReactorAdapter(testing.allocator);
    defer testing.allocator.free(ad_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const w = try decode.parseFromAdapterCore(arena.allocator(), ad_bytes);

    // World imports stdout, exports nothing — pure import shape.
    try testing.expectEqual(@as(usize, 1), w.imports.len);
    try testing.expectEqualStrings(STDOUT_NAMESPACE, w.imports[0].name);
    try testing.expectEqual(@as(usize, 0), w.exports.len);
}

test "buildSyntheticReactorEmbed: parses through reader, no _start, exports <iface>#bump" {
    const embed_bytes = try buildSyntheticReactorEmbed(testing.allocator);
    defer testing.allocator.free(embed_bytes);

    var owned = try core_imports.extract(testing.allocator, embed_bytes);
    defer owned.deinit();

    // `<iface>#bump` is exported; `_start` is NOT.
    try testing.expect(owned.interface.findExport(REACTOR_API_CORE_EXPORT) != null);
    try testing.expect(owned.interface.findExport("_start") == null);

    // preview1.fd_write is imported.
    var saw_p1 = false;
    for (owned.interface.imports) |im| {
        if (std.mem.eql(u8, im.module_name, "wasi_snapshot_preview1") and
            std.mem.eql(u8, im.field_name, PREVIEW1_EXPORT)) saw_p1 = true;
    }
    try testing.expect(saw_p1);
}

test "buildSyntheticReactorEmbed: encoded-world section decodes the api export" {
    const embed_bytes = try buildSyntheticReactorEmbed(testing.allocator);
    defer testing.allocator.free(embed_bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ct_payload = (try decode.extractEncodedWorld(embed_bytes)) orelse
        return error.TestUnexpectedResult;

    const metadata_decode = @import("../wit/metadata_decode.zig");
    const decoded = try metadata_decode.decode(arena.allocator(), ct_payload);

    // The world is `counter` and exports the `api` interface.
    try testing.expectEqualStrings("counter", decoded.name);
    try testing.expectEqual(@as(usize, 1), decoded.externs.len);
    try testing.expect(decoded.externs[0].is_export);
    try testing.expectEqualStrings(REACTOR_API_NAMESPACE, decoded.externs[0].qualified_name);
    try testing.expectEqual(@as(usize, 1), decoded.externs[0].funcs.len);
    try testing.expectEqualStrings(REACTOR_API_FUNC, decoded.externs[0].funcs[0].name);
}
