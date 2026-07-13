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

/// WIT for an embed that imports a non-WASI iface whose func sig
/// references a Defined type (`result<u32, u32>`). Used by the #228
/// regression test to verify `buildEmbedExtraImports` preserves the
/// Defined typedef in the wrapping component's iface body — pre-fix
/// the Defined was dropped, leaving the func's `type_idx` operand
/// dangling and the wrapping component unparseable.
const EXTRA_DEFINED_EMBED_WIT =
    \\package docs:demo@0.1.0;
    \\
    \\interface api {
    \\    compute: func() -> result<u32, u32>;
    \\}
    \\
    \\world demo {
    \\    import api;
    \\}
;

pub const EXTRA_DEFINED_NAMESPACE = "docs:demo/api@0.1.0";
pub const EXTRA_DEFINED_FUNC = "compute";
pub const EXTRA_DEFINED_EMBED_CT_SECTION_NAME =
    "component-type:docs:demo@0.1.0:demo:encoded world";

/// WIT for an embed that imports a non-WASI iface whose func sig
/// needs the full set of canon-lower options (memory + realloc +
/// string_encoding). Used by the #230 regression test to verify
/// `buildEmbedExtraImports` routes funcs through the shim/fixup
/// table so the lower can reference `main_inst`'s memory and
/// `cabi_realloc` exports (which aren't aliasable before
/// `main_inst` is instantiated — the cycle the shim/fixup pattern
/// was designed to break).
///
/// `record singleton { a: u32 }` is a Defined typedef (so this
/// fixture also exercises the #228 type-closure path). Its flat
/// repr is a single `i32`, matching the embed's `(i32, i32) -> i32`
/// core import sig — so the lowered shim trampoline shape lines up
/// with what the embed declares and the result validates clean.
const EXTRA_STRING_EMBED_WIT =
    \\package docs:opts@0.1.0;
    \\
    \\interface api {
    \\    record singleton { a: u32 }
    \\    compute: func(s: string) -> singleton;
    \\}
    \\
    \\world opts {
    \\    import api;
    \\}
;

pub const EXTRA_STRING_NAMESPACE = "docs:opts/api@0.1.0";
pub const EXTRA_STRING_FUNC = "compute";
pub const EXTRA_STRING_EMBED_CT_SECTION_NAME =
    "component-type:docs:opts@0.1.0:opts:encoded world";

/// WIT for an embed that imports a resource-bearing iface whose
/// method signature references a resource *from another interface*
/// via `use` (a `borrow<handle>` arg where `handle` lives in `dep`).
/// Regression fixture for cataggar/wabt#241.
///
/// This is the minimal shape of `wasi:http/types` — whose body
/// `use`s `pollable` (wasi:io/poll), `input-stream`/`output-stream`
/// (wasi:io/streams), `duration` (wasi:clocks), etc. The bug: for
/// such cross-iface-`use` namespaces the wrapping component's import
/// instance-type body lost its resource type definitions and had
/// method params flattened to bare `u32` (the `borrow<R>` self
/// handle, the cross-iface `borrow<handle>`, the `option<string>`
/// arg) and `[constructor]thing` no longer returned `own<thing>`.
///
/// Pre-fix, `buildEmbedExtraImports` could only clone the canonical
/// instance body when it was alias-free; a body carrying cross-iface
/// `(alias outer …)` references fell through to the lossy per-func
/// primitive synthesis (`coreToCompValType`), producing a malformed
/// component (`[constructor]…` not returning `(own $T)`). The fix
/// rebases those cross-iface aliases onto the wrapping component's
/// matching imported instances and keeps the typed body.
///
/// A self-contained (alias-free) resource interface is NOT enough to
/// reproduce — the `use dep.{handle}` cross-iface reference is the
/// essential trigger.
const EXTRA_RESOURCE_EMBED_WIT =
    \\package docs:res@0.1.0;
    \\
    \\interface dep {
    \\    resource handle {
    \\        wait: func();
    \\    }
    \\}
    \\
    \\interface api {
    \\    use dep.{handle};
    \\    resource thing {
    \\        constructor();
    \\        configure: func(path: option<string>, h: borrow<handle>);
    \\    }
    \\}
    \\
    \\world res {
    \\    import api;
    \\}
;

pub const EXTRA_RESOURCE_NAMESPACE = "docs:res/api@0.1.0";
pub const EXTRA_RESOURCE_DEP_NAMESPACE = "docs:res/dep@0.1.0";
pub const EXTRA_RESOURCE_DEP_METHOD = "[method]handle.wait";
pub const EXTRA_RESOURCE_CTOR = "[constructor]thing";
pub const EXTRA_RESOURCE_METHOD = "[method]thing.configure";
pub const EXTRA_RESOURCE_EMBED_CT_SECTION_NAME =
    "component-type:docs:res@0.1.0:res:encoded world";

/// Metadata and flattened core-import names for the direct-resource
/// regression fixture used by cataggar/wabt#328. The core import
/// order intentionally differs from the WIT declaration order.
const DIRECT_RESOURCE_EMBED_WIT =
    \\package fixtures:resources@0.2.10;
    \\
    \\interface store {
    \\    resource blob {
    \\        constructor(name: string);
    \\        read: func(peer: borrow<blob>, bytes: list<u8>) -> result<list<u8>, string>;
    \\    }
    \\    ping: func() -> u32;
    \\}
    \\
    \\world direct-imports {
    \\    import store;
    \\}
;

const DIRECT_RESOURCE_MISMATCH_WIT =
    \\package fixtures:resources@0.2.11;
    \\
    \\interface store {
    \\    resource blob {
    \\        constructor(name: string);
    \\        read: func(peer: borrow<blob>, bytes: list<u8>) -> result<list<u8>, string>;
    \\    }
    \\    ping: func() -> u32;
    \\}
    \\
    \\world direct-imports {
    \\    import store;
    \\}
;

pub const DIRECT_RESOURCE_NAMESPACE = "fixtures:resources/store@0.2.10";
pub const DIRECT_RESOURCE_MISMATCH_NAMESPACE = "fixtures:resources/store@0.2.11";
pub const DIRECT_RESOURCE_NAME = "blob";
pub const DIRECT_RESOURCE_DROP = "[resource-drop]blob";
pub const DIRECT_RESOURCE_NEW = "[resource-new]blob";
pub const DIRECT_RESOURCE_REP = "[resource-rep]blob";
pub const DIRECT_RESOURCE_CTOR = "[constructor]blob";
pub const DIRECT_RESOURCE_METHOD = "[method]blob.read";
pub const DIRECT_RESOURCE_FUNC = "ping";
pub const DIRECT_RESOURCE_EMBED_CT_SECTION_NAME =
    "component-type:fixtures:resources@0.2.10:direct-imports:encoded world";
pub const DIRECT_RESOURCE_MISMATCH_CT_SECTION_NAME =
    "component-type:fixtures:resources@0.2.11:direct-imports:encoded world";

/// Two exact-version direct imports where `consumer`'s instance body
/// contains an `alias outer` for `provider.sub-resource`. Metadata
/// lists the dependency first, while the flattened core imports list
/// the consumer first, forcing #328's import planner to topologically
/// rebase the consumer rather than relying on encounter order.
const CROSS_INTERFACE_EMBED_WIT =
    \\package fixtures:cross-interface@0.2.10;
    \\
    \\interface provider {
    \\    resource sub-resource {
    \\        constructor(label: string);
    \\        inspect: func(bytes: list<u8>) -> result<string, u32>;
    \\    }
    \\}
    \\
    \\interface consumer {
    \\    use provider.{sub-resource};
    \\    consume: func(item: borrow<sub-resource>, input: string) -> result<list<u8>, string>;
    \\}
    \\
    \\interface guest {
    \\    touch: func() -> u32;
    \\}
    \\
    \\world cross-interface {
    \\    import provider;
    \\    import consumer;
    \\    export guest;
    \\}
;

pub const CROSS_INTERFACE_PROVIDER_NAMESPACE =
    "fixtures:cross-interface/provider@0.2.10";
pub const CROSS_INTERFACE_CONSUMER_NAMESPACE =
    "fixtures:cross-interface/consumer@0.2.10";
pub const CROSS_INTERFACE_GUEST_NAMESPACE =
    "fixtures:cross-interface/guest@0.2.10";
pub const CROSS_INTERFACE_RESOURCE = "sub-resource";
pub const CROSS_INTERFACE_DROP = "[resource-drop]sub-resource";
pub const CROSS_INTERFACE_CTOR = "[constructor]sub-resource";
pub const CROSS_INTERFACE_METHOD = "[method]sub-resource.inspect";
pub const CROSS_INTERFACE_FUNC = "consume";
pub const CROSS_INTERFACE_GUEST_EXPORT =
    "fixtures:cross-interface/guest@0.2.10#touch";
pub const CROSS_INTERFACE_EMBED_CT_SECTION_NAME =
    "component-type:fixtures:cross-interface@0.2.10:cross-interface:encoded world";

/// Focused negative/compatibility forms of the #328 fixture. These
/// deliberately vary one dimension at a time so adapter tests can
/// assert a precise diagnostic without byte-level fixture mutation.
pub const DirectResourceEmbedVariant = enum {
    full,
    resource_only,
    version_mismatch,
    unknown_resource,
    unknown_function,
    malformed_intrinsic_signature,
    metadata_free_primitive,
};

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
        try b.append(allocator, 0x05); // body size
        try b.append(allocator, 0x00); // 0 locals
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

/// Build a synthetic command-shape embed core wasm that imports a
/// non-WASI namespace whose iface body declares a func with a
/// **Defined** result type (`result<u32, u32>`). Regression fixture
/// for cataggar/wabt#228 — see `EXTRA_DEFINED_EMBED_WIT`.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///   * `docs:demo/api@0.1.0.compute`         (func, (i32) -> ())
///                                               — indirect result pointer
///
/// Exports:
///   * `_start`                              (func, () -> ())
///   * `memory`                              (memory 0)
///
/// Carries a `component-type:docs:demo@0.1.0:demo:encoded world`
/// custom section so the splicer's `embed_metadata` lookup
/// recovers the canonical `docs:demo/api` body — without it the
/// `buildEmbedExtraImports` fallback path would synthesize a
/// primitive-only sig (() -> u32) from the core wasm signature
/// alone, skipping the Defined-type test entirely.
///
/// `_start` body: trivial `i32.const 0; drop; end`. The
/// imported `compute` is never actually called — its presence in
/// the core wasm imports is enough to drive `buildEmbedExtraImports`
/// down the `docs:demo/api` path. Caller frees with the same
/// allocator.
pub fn buildSyntheticEmbedWithExtraDefinedImport(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, EXTRA_DEFINED_EMBED_WIT, "demo");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: preview1, compute's canonical indirect-result
    // lowering, and _start.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f }); // type 0: () -> i32
        try b.appendSlice(allocator, &.{ 0x60, 0x01, 0x7f, 0x00 }); // type 1: (i32) -> ()
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 }); // type 2: () -> ()
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: wasi_snapshot_preview1.fd_write + docs:demo/api@0.1.0.compute.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02); // count
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00); // func
        try b.append(allocator, 0x00); // typeidx 0
        try writeName(allocator, &b, EXTRA_DEFINED_NAMESPACE);
        try writeName(allocator, &b, EXTRA_DEFINED_FUNC);
        try b.append(allocator, 0x00); // func
        try b.append(allocator, 0x01); // typeidx 1
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 1 defined func (_start, type 2)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x02);
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

    // Export section: _start (func 2 = imports 0..1 + defined 0), memory (0)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, "_start");
        try b.appendSlice(allocator, &.{ 0x00, 0x02 }); // func, idx 2
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 }); // memory, idx 0
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: _start = i32.const 0; drop; end
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x05);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x1a, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, EXTRA_DEFINED_EMBED_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic command-shape embed core wasm that imports a
/// non-WASI namespace whose iface body declares a func needing
/// canon-lower opts (memory + string_encoding). Regression fixture
/// for cataggar/wabt#230 — see `EXTRA_STRING_EMBED_WIT`.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///   * `docs:opts/api@0.1.0.compute`         (func, (i32, i32) -> i32)
///         — the canonical-ABI lowered form for
///         `compute: func(s: string) -> singleton` with
///         `record singleton { a: u32 }`.
///
/// Exports:
///   * `_start`                              (func, () -> ())
///   * `memory`                              (memory 0)
///   * `cabi_realloc`                        (func, (i32,i32,i32,i32) -> i32)
///         — needed so the wrapper can alias it for the
///         `realloc` canon-opt on any embed-extra canon.lower.
///         (compute itself doesn't actually need realloc — the
///         result is flat — but having it lets the same fixture
///         exercise a wider range of opt combinations.)
///
/// Carries a `component-type:docs:opts@0.1.0:opts:encoded world`
/// custom section so the splicer's `embed_metadata` lookup
/// recovers the canonical `compute` FuncType.
pub fn buildSyntheticEmbedWithExtraStringImport(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, EXTRA_STRING_EMBED_WIT, "opts");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 4 types.
    //   type 0: () -> i32 (preview1.fd_write)
    //   type 1: () -> () (_start)
    //   type 2: (i32, i32) -> i32 (compute, lowered form)
    //   type 3: (i32, i32, i32, i32) -> i32 (cabi_realloc)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x04);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: preview1.fd_write (type 0) + opts.api.compute (type 2).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeName(allocator, &b, EXTRA_STRING_NAMESPACE);
        try writeName(allocator, &b, EXTRA_STRING_FUNC);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x02);
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 2 defined funcs.
    //   defined func 0: _start (type 1)
    //   defined func 1: cabi_realloc (type 3)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x03);
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

    // Export section: _start (defined func 0 = imports 0..1 + defined 0 = 2),
    // memory (0), cabi_realloc (defined func 1 = imports + defined 1 = 3).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03);
        try writeName(allocator, &b, "_start");
        try b.appendSlice(allocator, &.{ 0x00, 0x02 });
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeName(allocator, &b, "cabi_realloc");
        try b.appendSlice(allocator, &.{ 0x00, 0x03 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: trivial bodies.
    //   _start: i32.const 0; drop; end
    //   cabi_realloc: i32.const 0; end (returns 0 ptr — fine since
    //     the synthetic compute is never actually called in tests).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        // body 0: _start
        try b.append(allocator, 0x05);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x1a, 0x0b });
        // body 1: cabi_realloc
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, EXTRA_STRING_EMBED_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

/// Build a synthetic command-shape embed core wasm that imports a
/// resource-bearing namespace whose method sig references a resource
/// from *another* interface via `use` (cross-iface alias) plus an
/// `option<string>` arg. Regression fixture for cataggar/wabt#241 —
/// see `EXTRA_RESOURCE_EMBED_WIT`.
///
/// Imports:
///   * `wasi_snapshot_preview1.fd_write`     (func, () -> i32)
///   * `docs:res/dep@0.1.0.[method]handle.wait`
///         (func, (i32) -> ())       — self borrow<handle>
///   * `docs:res/api@0.1.0.[constructor]thing`
///         (func, () -> i32)         — lowered `() -> own<thing>`
///   * `docs:res/api@0.1.0.[method]thing.configure`
///         (func, (i32,i32,i32,i32,i32) -> ())
///         — `(self: borrow<thing>, path: option<string>,
///            h: borrow<handle>)` = self + disc + ptr + len + handle
///
/// Exports:
///   * `_start`        (func, () -> ())
///   * `memory`        (memory 0)
///   * `cabi_realloc`  (func, (i32,i32,i32,i32) -> i32)
///
/// Carries a `component-type:docs:res@0.1.0:res:encoded world`
/// custom section so the splicer's `embed_metadata` lookup recovers
/// the canonical `docs:res/api` body, whose `configure` sig carries
/// a cross-iface `(alias outer …)` reference to `docs:res/dep`'s
/// `handle`. Without the fix the alias-bearing body falls to the
/// `coreToCompValType` fallback, dropping the resource type defs and
/// the `own<thing>` / `borrow` / `option` types.
pub fn buildSyntheticEmbedWithResourceImport(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(allocator, EXTRA_RESOURCE_EMBED_WIT, "res");
    defer allocator.free(ct);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Type section: 5 types.
    //   type 0: () -> i32 (preview1.fd_write + [constructor]thing)
    //   type 1: () -> () (_start)
    //   type 2: (i32) -> () ([method]handle.wait)
    //   type 3: (i32,i32,i32,i32,i32) -> () ([method]thing.configure)
    //   type 4: (i32,i32,i32,i32) -> i32 (cabi_realloc)
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x05);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x01, 0x7f, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // Import section: preview1.fd_write (type 0) + dep.handle.wait (type 2)
    // + ctor (type 0) + method (type 3).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x04);
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeName(allocator, &b, EXTRA_RESOURCE_DEP_NAMESPACE);
        try writeName(allocator, &b, EXTRA_RESOURCE_DEP_METHOD);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x02);
        try writeName(allocator, &b, EXTRA_RESOURCE_NAMESPACE);
        try writeName(allocator, &b, EXTRA_RESOURCE_CTOR);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x00);
        try writeName(allocator, &b, EXTRA_RESOURCE_NAMESPACE);
        try writeName(allocator, &b, EXTRA_RESOURCE_METHOD);
        try b.append(allocator, 0x00);
        try b.append(allocator, 0x03);
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // Function section: 2 defined funcs — _start (type 1), cabi_realloc (type 4).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.append(allocator, 0x01);
        try b.append(allocator, 0x04);
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

    // Export section: _start (func 4 = imports 0..3 + defined 0),
    // memory (0), cabi_realloc (func 5 = imports 0..3 + defined 1).
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03);
        try writeName(allocator, &b, "_start");
        try b.appendSlice(allocator, &.{ 0x00, 0x04 });
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeName(allocator, &b, "cabi_realloc");
        try b.appendSlice(allocator, &.{ 0x00, 0x05 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Code section: trivial bodies.
    //   _start: i32.const 0; drop; end
    //   cabi_realloc: i32.const 0; end
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.append(allocator, 0x05);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x1a, 0x0b });
        try b.append(allocator, 0x04);
        try b.append(allocator, 0x00);
        try b.appendSlice(allocator, &.{ 0x41, 0x00, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, EXTRA_RESOURCE_EMBED_CT_SECTION_NAME, ct);

    return out.toOwnedSlice(allocator);
}

const DirectResourceCoreImport = struct {
    field_name: []const u8,
    type_idx: u8,
};

/// Build the default metadata-backed direct-resource embed for #328.
pub fn buildSyntheticEmbedWithDirectResourceImports(allocator: Allocator) ![]u8 {
    return buildSyntheticEmbedWithDirectResourceImportsVariant(allocator, .full);
}

/// Build a command-shaped embed whose direct core imports are the
/// canonical-ABI flattened form of `DIRECT_RESOURCE_EMBED_WIT`.
///
/// The full core order is `ping`, method, rep, drop, constructor,
/// new, unlike the metadata's resource/constructor/method/`ping`
/// order. The exported `_start` calls every import so none can be
/// discarded by a core-wasm GC pass.
pub fn buildSyntheticEmbedWithDirectResourceImportsVariant(
    allocator: Allocator,
    variant: DirectResourceEmbedVariant,
) ![]u8 {
    const full_imports = [_]DirectResourceCoreImport{
        .{ .field_name = DIRECT_RESOURCE_FUNC, .type_idx = 0 },
        .{ .field_name = DIRECT_RESOURCE_METHOD, .type_idx = 2 },
        .{ .field_name = DIRECT_RESOURCE_REP, .type_idx = 3 },
        .{ .field_name = DIRECT_RESOURCE_DROP, .type_idx = 1 },
        .{ .field_name = DIRECT_RESOURCE_CTOR, .type_idx = 4 },
        .{ .field_name = DIRECT_RESOURCE_NEW, .type_idx = 3 },
    };
    const resource_only_imports = [_]DirectResourceCoreImport{
        .{ .field_name = DIRECT_RESOURCE_DROP, .type_idx = 1 },
    };
    const unknown_resource_imports = [_]DirectResourceCoreImport{
        .{ .field_name = "[resource-drop]missing", .type_idx = 1 },
    };
    const unknown_function_imports = [_]DirectResourceCoreImport{
        .{ .field_name = "[method]blob.missing", .type_idx = 1 },
    };
    const malformed_intrinsic_imports = [_]DirectResourceCoreImport{
        .{ .field_name = DIRECT_RESOURCE_DROP, .type_idx = 0 },
    };
    const primitive_imports = [_]DirectResourceCoreImport{
        .{ .field_name = DIRECT_RESOURCE_FUNC, .type_idx = 0 },
    };

    const direct_imports: []const DirectResourceCoreImport = switch (variant) {
        .full, .version_mismatch => &full_imports,
        .resource_only => &resource_only_imports,
        .unknown_resource => &unknown_resource_imports,
        .unknown_function => &unknown_function_imports,
        .malformed_intrinsic_signature => &malformed_intrinsic_imports,
        .metadata_free_primitive => &primitive_imports,
    };

    const Metadata = struct {
        source: []const u8,
        world: []const u8,
        section_name: []const u8,
    };
    const metadata: ?Metadata = switch (variant) {
        .version_mismatch => .{
            .source = DIRECT_RESOURCE_MISMATCH_WIT,
            .world = "direct-imports",
            .section_name = DIRECT_RESOURCE_MISMATCH_CT_SECTION_NAME,
        },
        .metadata_free_primitive => null,
        else => .{
            .source = DIRECT_RESOURCE_EMBED_WIT,
            .world = "direct-imports",
            .section_name = DIRECT_RESOURCE_EMBED_CT_SECTION_NAME,
        },
    };

    const ct: ?[]u8 = if (metadata) |m|
        try metadata_encode.encodeWorldFromSource(allocator, m.source, m.world)
    else
        null;
    defer if (ct) |bytes| allocator.free(bytes);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try writeMagic(allocator, &out);

    // Core signatures:
    //   0: () -> i32                         preview1, ping
    //   1: (i32) -> ()                      resource.drop
    //   2: (i32,i32,i32,i32,i32) -> ()     lowered read + retptr
    //   3: (i32) -> i32                     resource.new/rep
    //   4: (i32,i32) -> i32                 constructor(string)
    //   5: () -> ()                         _start
    //   6: (i32,i32,i32,i32) -> i32         cabi_realloc
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x07);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x01, 0x7f, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x01, 0x7f, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    // preview1 first, then the deliberately metadata-order-independent
    // direct imports.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, @intCast(1 + direct_imports.len));
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x00 });
        for (direct_imports) |im| {
            try writeName(allocator, &b, DIRECT_RESOURCE_NAMESPACE);
            try writeName(allocator, &b, im.field_name);
            try b.append(allocator, 0x00);
            try b.append(allocator, im.type_idx);
        }
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // _start + realloc.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.appendSlice(allocator, &.{ 0x02, 0x05, 0x06 });
        try writeSection(allocator, &out, 0x03, b.items);
    }

    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.appendSlice(allocator, &.{ 0x01, 0x00, 0x00 });
        try writeSection(allocator, &out, 0x05, b.items);
    }

    const imported_func_count: u8 = @intCast(1 + direct_imports.len);
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03);
        try writeName(allocator, &b, "_start");
        try b.appendSlice(allocator, &.{ 0x00, imported_func_count });
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeName(allocator, &b, "cabi_realloc");
        try b.appendSlice(allocator, &.{ 0x00, imported_func_count + 1 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // _start invokes preview1 and every direct import with zero-valued
    // flattened operands. This is structural only; tests never execute it.
    {
        var start = std.ArrayListUnmanaged(u8).empty;
        defer start.deinit(allocator);
        try start.append(allocator, 0x00); // no locals
        try start.appendSlice(allocator, &.{ 0x10, 0x00, 0x1a }); // fd_write
        for (direct_imports, 0..) |im, i| {
            const arg_count: u8 = switch (im.type_idx) {
                0 => 0,
                1, 3 => 1,
                2 => 5,
                4 => 2,
                else => unreachable,
            };
            for (0..arg_count) |_| try start.appendSlice(allocator, &.{ 0x41, 0x00 });
            try start.appendSlice(allocator, &.{ 0x10, @intCast(i + 1) });
            if (im.type_idx == 0 or im.type_idx == 3 or im.type_idx == 4)
                try start.append(allocator, 0x1a);
        }
        try start.append(allocator, 0x0b);

        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.append(allocator, @intCast(start.items.len));
        try b.appendSlice(allocator, start.items);
        try b.appendSlice(allocator, &.{ 0x04, 0x00, 0x41, 0x00, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    if (metadata) |m|
        try appendCustomSection(allocator, &out, m.section_name, ct.?);

    return out.toOwnedSlice(allocator);
}

/// Build a reactor-shaped, metadata-backed #328 fixture with a
/// cross-interface resource alias. Every imported function is called
/// by the exported `guest.touch`, so core GC cannot erase the shape.
///
/// Imported resource glue intentionally contains only
/// `[resource-drop]sub-resource`; imported resources must not carry
/// `[resource-new]` or `[resource-rep]`.
pub fn buildSyntheticReactorEmbedWithCrossInterfaceImports(allocator: Allocator) ![]u8 {
    const ct = try metadata_encode.encodeWorldFromSource(
        allocator,
        CROSS_INTERFACE_EMBED_WIT,
        "cross-interface",
    );
    defer allocator.free(ct);

    const imports = [_]struct {
        module_name: []const u8,
        field_name: []const u8,
        type_idx: u8,
    }{
        // Consumer-before-provider is the opposite of metadata's
        // dependency order and is the core of the regression shape.
        .{
            .module_name = CROSS_INTERFACE_CONSUMER_NAMESPACE,
            .field_name = CROSS_INTERFACE_FUNC,
            .type_idx = 3,
        },
        .{
            .module_name = CROSS_INTERFACE_PROVIDER_NAMESPACE,
            .field_name = CROSS_INTERFACE_METHOD,
            .type_idx = 3,
        },
        .{
            .module_name = CROSS_INTERFACE_PROVIDER_NAMESPACE,
            .field_name = CROSS_INTERFACE_DROP,
            .type_idx = 1,
        },
        .{
            .module_name = CROSS_INTERFACE_PROVIDER_NAMESPACE,
            .field_name = CROSS_INTERFACE_CTOR,
            .type_idx = 2,
        },
    };

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    try writeMagic(allocator, &out);

    // 0: () -> i32                         preview1 + guest.touch
    // 1: (i32) -> ()                      resource.drop
    // 2: (i32,i32) -> i32                 constructor(string)
    // 3: (i32,i32,i32,i32) -> ()         method/consumer + retptr
    // 4: (i32,i32,i32,i32) -> i32         cabi_realloc
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x05);
        try b.appendSlice(allocator, &.{ 0x60, 0x00, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x01, 0x7f, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f });
        try b.appendSlice(allocator, &.{ 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00 });
        try b.appendSlice(allocator, &.{ 0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f });
        try writeSection(allocator, &out, 0x01, b.items);
    }

    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 1 + imports.len);
        try writeName(allocator, &b, "wasi_snapshot_preview1");
        try writeName(allocator, &b, PREVIEW1_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, 0x00 });
        for (imports) |im| {
            try writeName(allocator, &b, im.module_name);
            try writeName(allocator, &b, im.field_name);
            try b.appendSlice(allocator, &.{ 0x00, im.type_idx });
        }
        try writeSection(allocator, &out, 0x02, b.items);
    }

    // guest.touch and cabi_realloc.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.appendSlice(allocator, &.{ 0x02, 0x00, 0x04 });
        try writeSection(allocator, &out, 0x03, b.items);
    }
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.appendSlice(allocator, &.{ 0x01, 0x00, 0x00 });
        try writeSection(allocator, &out, 0x05, b.items);
    }

    const imported_func_count: u8 = 1 + imports.len;
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x03);
        try writeName(allocator, &b, CROSS_INTERFACE_GUEST_EXPORT);
        try b.appendSlice(allocator, &.{ 0x00, imported_func_count });
        try writeName(allocator, &b, "memory");
        try b.appendSlice(allocator, &.{ 0x02, 0x00 });
        try writeName(allocator, &b, "cabi_realloc");
        try b.appendSlice(allocator, &.{ 0x00, imported_func_count + 1 });
        try writeSection(allocator, &out, 0x07, b.items);
    }

    // Call preview1 and all four direct imports with structural zero
    // operands, then return zero from guest.touch.
    {
        var b = std.ArrayListUnmanaged(u8).empty;
        defer b.deinit(allocator);
        try b.append(allocator, 0x02);
        try b.append(allocator, 0x26);
        try b.appendSlice(allocator, &.{
            0x00, // no locals
            0x10, 0x00, 0x1a, // preview1.fd_write
            0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0x10, 0x01, // consumer
            0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0x41, 0x00, 0x10, 0x02, // method
            0x41, 0x00, 0x10, 0x03, // drop
            0x41, 0x00, 0x41, 0x00, 0x10, 0x04, 0x1a, // constructor
            0x41, 0x00, 0x0b, // return 0
        });
        try b.appendSlice(allocator, &.{ 0x04, 0x00, 0x41, 0x00, 0x0b });
        try writeSection(allocator, &out, 0x0a, b.items);
    }

    try appendCustomSection(allocator, &out, CROSS_INTERFACE_EMBED_CT_SECTION_NAME, ct);
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

test "direct resource fixture: core order and metadata preserve canonical resource types" {
    const bytes = try buildSyntheticEmbedWithDirectResourceImports(testing.allocator);
    defer testing.allocator.free(bytes);

    var owned = try core_imports.extract(testing.allocator, bytes);
    defer owned.deinit();

    const expected_fields = [_][]const u8{
        DIRECT_RESOURCE_FUNC,
        DIRECT_RESOURCE_METHOD,
        DIRECT_RESOURCE_REP,
        DIRECT_RESOURCE_DROP,
        DIRECT_RESOURCE_CTOR,
        DIRECT_RESOURCE_NEW,
    };
    var direct_idx: usize = 0;
    for (owned.interface.imports) |im| {
        if (!std.mem.eql(u8, im.module_name, DIRECT_RESOURCE_NAMESPACE)) continue;
        try testing.expectEqualStrings(expected_fields[direct_idx], im.field_name);
        direct_idx += 1;
    }
    try testing.expectEqual(expected_fields.len, direct_idx);
    try testing.expect(owned.interface.findExport("_start") != null);
    try testing.expect(owned.interface.findExport("cabi_realloc") != null);

    const ct_payload = (try decode.extractEncodedWorld(bytes)) orelse
        return error.TestUnexpectedResult;
    const metadata_decode = @import("../wit/metadata_decode.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try metadata_decode.decode(arena.allocator(), ct_payload);
    try testing.expectEqual(@as(usize, 1), decoded.externs.len);
    const ext = decoded.externs[0];
    try testing.expect(!ext.is_export);
    try testing.expectEqualStrings(DIRECT_RESOURCE_NAMESPACE, ext.qualified_name);

    var has_resource = false;
    var has_own = false;
    var has_borrow = false;
    var has_list = false;
    var has_result = false;
    var has_intrinsic_export = false;
    for (ext.inst_decls) |decl| switch (decl) {
        .@"export" => |e| {
            if (e.desc == .type and e.desc.type == .sub_resource and
                std.mem.eql(u8, e.name, DIRECT_RESOURCE_NAME))
            {
                has_resource = true;
            }
            if (std.mem.startsWith(u8, e.name, "[resource-"))
                has_intrinsic_export = true;
        },
        .type => |td| switch (td) {
            .val => |v| switch (v) {
                .own => has_own = true,
                .borrow => has_borrow = true,
                else => {},
            },
            .list => has_list = true,
            .result => has_result = true,
            else => {},
        },
        else => {},
    };
    try testing.expect(has_resource);
    try testing.expect(has_own);
    try testing.expect(has_borrow);
    try testing.expect(has_list);
    try testing.expect(has_result);
    try testing.expect(!has_intrinsic_export);

    // Keep the hand-written flattened method signature in lockstep
    // with the canonical ABI derived from metadata.
    const abi = @import("abi.zig");
    const adapter_world = try decode.parseFromAdapterCore(arena.allocator(), bytes);
    var store_type_idx: ?u32 = null;
    for (adapter_world.imports) |im| {
        if (std.mem.eql(u8, im.name, DIRECT_RESOURCE_NAMESPACE)) {
            store_type_idx = im.body_type_idx;
        }
    }
    const method_ref = try abi.findFuncImport(
        adapter_world,
        store_type_idx orelse return error.TestUnexpectedResult,
        DIRECT_RESOURCE_METHOD,
    );
    const lowered_method = try abi.lowerCoreSig(arena.allocator(), method_ref);
    try testing.expectEqual(@as(usize, 5), lowered_method.params.len);
    try testing.expectEqual(@as(usize, 0), lowered_method.results.len);
    for (lowered_method.params) |param| try testing.expect(param == .i32);

    var saw_ctor_string = false;
    for (ext.funcs) |func| {
        if (!std.mem.eql(u8, func.name, DIRECT_RESOURCE_CTOR)) continue;
        try testing.expectEqual(@as(usize, 1), func.sig.params.len);
        try testing.expect(func.sig.params[0].type == .string);
        saw_ctor_string = true;
    }
    try testing.expect(saw_ctor_string);
}

test "cross-interface fixture: metadata dependency order and core encounter order differ" {
    const bytes = try buildSyntheticReactorEmbedWithCrossInterfaceImports(testing.allocator);
    defer testing.allocator.free(bytes);

    var owned = try core_imports.extract(testing.allocator, bytes);
    defer owned.deinit();

    const expected_modules = [_][]const u8{
        CROSS_INTERFACE_CONSUMER_NAMESPACE,
        CROSS_INTERFACE_PROVIDER_NAMESPACE,
        CROSS_INTERFACE_PROVIDER_NAMESPACE,
        CROSS_INTERFACE_PROVIDER_NAMESPACE,
    };
    const expected_fields = [_][]const u8{
        CROSS_INTERFACE_FUNC,
        CROSS_INTERFACE_METHOD,
        CROSS_INTERFACE_DROP,
        CROSS_INTERFACE_CTOR,
    };
    for (expected_fields, 0..) |field, i| {
        const im = owned.interface.imports[i + 1];
        try testing.expectEqualStrings(expected_modules[i], im.module_name);
        try testing.expectEqualStrings(field, im.field_name);
        try testing.expect(!std.mem.startsWith(u8, field, "[resource-new]"));
        try testing.expect(!std.mem.startsWith(u8, field, "[resource-rep]"));
        if (std.mem.eql(u8, field, CROSS_INTERFACE_DROP)) {
            try testing.expectEqual(@as(usize, 1), im.sig.?.params.len);
            try testing.expectEqual(@as(usize, 0), im.sig.?.results.len);
        }
    }
    try testing.expect(owned.interface.findExport("_start") == null);
    try testing.expect(owned.interface.findExport(CROSS_INTERFACE_GUEST_EXPORT) != null);

    // Parse the generated metadata and pin provider-before-consumer,
    // despite the core module encountering consumer first.
    const payload = (try decode.extractEncodedWorld(bytes)) orelse
        return error.TestUnexpectedResult;
    const metadata_decode = @import("../wit/metadata_decode.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try metadata_decode.decode(arena.allocator(), payload);
    try testing.expectEqual(@as(usize, 3), decoded.externs.len);
    try testing.expectEqualStrings(
        CROSS_INTERFACE_PROVIDER_NAMESPACE,
        decoded.externs[0].qualified_name,
    );
    try testing.expectEqualStrings(
        CROSS_INTERFACE_CONSUMER_NAMESPACE,
        decoded.externs[1].qualified_name,
    );
    try testing.expectEqualStrings(
        CROSS_INTERFACE_GUEST_NAMESPACE,
        decoded.externs[2].qualified_name,
    );

    var saw_sub_resource = false;
    for (decoded.externs[0].type_slots) |slot| {
        if (slot == .sub_resource and
            std.mem.eql(u8, slot.sub_resource, CROSS_INTERFACE_RESOURCE))
        {
            saw_sub_resource = true;
        }
    }
    var saw_outer_alias = false;
    var saw_borrow = false;
    for (decoded.externs[1].type_slots) |slot| switch (slot) {
        .alias_outer => saw_outer_alias = true,
        .val => |val| if (val == .borrow) {
            saw_borrow = true;
        },
        else => {},
    };
    try testing.expect(saw_sub_resource);
    try testing.expect(saw_outer_alias);
    try testing.expect(saw_borrow);

    // Keep the hand-lowered core signatures synchronized with WIT.
    const abi = @import("abi.zig");
    const world = try decode.parseFromAdapterCore(arena.allocator(), bytes);
    var provider_idx: ?u32 = null;
    var consumer_idx: ?u32 = null;
    for (world.imports) |im| {
        if (std.mem.eql(u8, im.name, CROSS_INTERFACE_PROVIDER_NAMESPACE))
            provider_idx = im.body_type_idx;
        if (std.mem.eql(u8, im.name, CROSS_INTERFACE_CONSUMER_NAMESPACE))
            consumer_idx = im.body_type_idx;
    }
    const method = try abi.findFuncImport(
        world,
        provider_idx orelse return error.TestUnexpectedResult,
        CROSS_INTERFACE_METHOD,
    );
    const lowered_method = try abi.lowerCoreSig(arena.allocator(), method);
    try testing.expectEqual(@as(usize, 4), lowered_method.params.len);
    try testing.expectEqual(@as(usize, 0), lowered_method.results.len);

    const ctor = try abi.findFuncImport(
        world,
        provider_idx orelse return error.TestUnexpectedResult,
        CROSS_INTERFACE_CTOR,
    );
    const lowered_ctor = try abi.lowerCoreSig(arena.allocator(), ctor);
    try testing.expectEqual(@as(usize, 2), lowered_ctor.params.len);
    try testing.expectEqual(@as(usize, 1), lowered_ctor.results.len);

    const consume = try abi.findFuncImport(
        world,
        consumer_idx orelse return error.TestUnexpectedResult,
        CROSS_INTERFACE_FUNC,
    );
    const lowered_consume = try abi.lowerCoreSig(arena.allocator(), consume);
    try testing.expectEqual(@as(usize, 4), lowered_consume.params.len);
    try testing.expectEqual(@as(usize, 0), lowered_consume.results.len);
}

test "direct resource fixture: focused negative and compatibility variants" {
    const Cases = struct {
        variant: DirectResourceEmbedVariant,
        field: []const u8,
    };
    const cases = [_]Cases{
        .{ .variant = .resource_only, .field = DIRECT_RESOURCE_DROP },
        .{ .variant = .unknown_resource, .field = "[resource-drop]missing" },
        .{ .variant = .unknown_function, .field = "[method]blob.missing" },
        .{ .variant = .malformed_intrinsic_signature, .field = DIRECT_RESOURCE_DROP },
        .{ .variant = .metadata_free_primitive, .field = DIRECT_RESOURCE_FUNC },
    };
    for (cases) |case| {
        const bytes = try buildSyntheticEmbedWithDirectResourceImportsVariant(
            testing.allocator,
            case.variant,
        );
        defer testing.allocator.free(bytes);

        var owned = try core_imports.extract(testing.allocator, bytes);
        defer owned.deinit();
        try testing.expectEqual(@as(usize, 2), owned.interface.imports.len);
        try testing.expectEqualStrings(DIRECT_RESOURCE_NAMESPACE, owned.interface.imports[1].module_name);
        try testing.expectEqualStrings(case.field, owned.interface.imports[1].field_name);

        if (case.variant == .malformed_intrinsic_signature) {
            const sig = owned.interface.imports[1].sig.?;
            try testing.expectEqual(@as(usize, 0), sig.params.len);
            try testing.expectEqual(@as(usize, 1), sig.results.len);
        }
        if (case.variant == .metadata_free_primitive)
            try testing.expect((try decode.extractEncodedWorld(bytes)) == null);
    }

    const mismatch = try buildSyntheticEmbedWithDirectResourceImportsVariant(
        testing.allocator,
        .version_mismatch,
    );
    defer testing.allocator.free(mismatch);
    const payload = (try decode.extractEncodedWorld(mismatch)) orelse
        return error.TestUnexpectedResult;
    const metadata_decode = @import("../wit/metadata_decode.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try metadata_decode.decode(arena.allocator(), payload);
    try testing.expectEqualStrings(DIRECT_RESOURCE_MISMATCH_NAMESPACE, decoded.externs[0].qualified_name);
}
