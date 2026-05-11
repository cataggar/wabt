//! `build_adapter` — assemble the wasi-preview1 → preview2 adapter
//! artifact from the WAT source plus the embedded
//! `component-type:…:encoded world` custom section.
//!
//! Driven by `zig build adapter`. CLI:
//!
//!     build-wasi-preview1-adapter <adapter.wat> <wit-dir> <output.wasm>
//!
//! Pipeline:
//!
//!   1. Read the WAT source file.
//!   2. Parse + validate via `wabt.text.Parser.parseModule` +
//!      `wabt.Validator.validate` (same path as `wabt text parse`).
//!   3. Parse the WIT layout under `<wit-dir>` via
//!      `wabt.component.wit.resolver.parseLayout` and encode the
//!      `command` world via
//!      `wabt.component.wit.metadata_encode.encodeWorldFromResolver`.
//!   4. Append the encoded world payload as a
//!      `component-type:<pkg>:<world>[@<ver>]:encoded world`
//!      custom section to the module before serialisation.
//!   5. Serialise via `wabt.binary.writer.writeModule`.
//!   6. Write the bytes to the output path.
//!
//! Deferred (tracked under cataggar/wamr#453):
//!
//!   * Replace the ENOSYS stub bodies in `../src/adapter.wat` with
//!     real preview1 → preview2 logic (`fd_write` iterates iovecs and
//!     calls `output-stream.blocking-write-and-flush`, `args_get`
//!     lowers `wasi:cli/environment.get-arguments`, etc.). That work
//!     re-adds the `wasi:io/streams` / `wasi:cli/{stdout,stderr,stdin}`
//!     imports and forces `metadata_encode.zig` to grow resource-handle
//!     encoding, so we keep it as a separate sub-phase.

const std = @import("std");
const wabt = @import("wabt");

/// Name of the world to encode. Matches `world command { … }` in
/// `../wit/preview1.wit`.
const world_name = "command";

/// Custom-section name. The splicer's `decode.extractEncodedWorld`
/// accepts any section whose name starts with `component-type:`
/// (see `src/component/adapter/decode.zig:138`), so the suffix
/// here is for human readability only.
const ct_section_name = "component-type:wabt:wasi-preview1@0.0.0:command:encoded world";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 4) {
        std.debug.print(
            "usage: {s} <adapter.wat> <wit-dir> <output.wasm>\n",
            .{if (args.len > 0) args[0] else "build-wasi-preview1-adapter"},
        );
        std.process.exit(2);
    }
    const in_path = args[1];
    const wit_dir = args[2];
    const out_path = args[3];

    const cwd = std.Io.Dir.cwd();

    const source = cwd.readFileAlloc(
        init.io,
        in_path,
        gpa,
        std.Io.Limit.limited(wabt.max_input_file_size),
    ) catch |err| {
        std.debug.print(
            "build_adapter: cannot read '{s}': {any}\n",
            .{ in_path, err },
        );
        std.process.exit(1);
    };
    defer gpa.free(source);

    var module = wabt.text.Parser.parseModule(gpa, source) catch |err| {
        std.debug.print(
            "build_adapter: parse '{s}': {any}\n",
            .{ in_path, err },
        );
        std.process.exit(1);
    };
    defer module.deinit();

    wabt.Validator.validate(&module, .{}) catch |err| {
        std.debug.print(
            "build_adapter: validate '{s}': {any}\n",
            .{ in_path, err },
        );
        std.process.exit(1);
    };

    // ── Encode the WIT world into a `component-type:…` custom-section
    // payload, then attach it to the module. We keep the resolver
    // arena alive until after writeModule because the Custom entry
    // borrows from `ct_payload` (which itself is owned by `gpa`).
    var resolver_arena = std.heap.ArenaAllocator.init(gpa);
    defer resolver_arena.deinit();
    const ar = resolver_arena.allocator();

    const resolver = wabt.component.wit.resolver.parseLayout(ar, init.io, wit_dir) catch |err| {
        std.debug.print(
            "build_adapter: parsing WIT layout '{s}': {s}\n",
            .{ wit_dir, @errorName(err) },
        );
        std.process.exit(1);
    };

    const ct_payload = wabt.component.wit.metadata_encode.encodeWorldFromResolver(
        gpa,
        resolver,
        world_name,
    ) catch |err| {
        std.debug.print(
            "build_adapter: encoding world '{s}' from '{s}': {s}\n",
            .{ world_name, wit_dir, @errorName(err) },
        );
        std.process.exit(1);
    };
    defer gpa.free(ct_payload);

    // Append the encoded world as a custom section. `module.customs`
    // is serialised at the end of the binary by `binary/writer.zig`,
    // which is the conventional location for wit-bindgen-style
    // `:encoded world` sections.
    module.customs.append(module.allocator, .{
        .name = ct_section_name,
        .data = ct_payload,
    }) catch |err| {
        std.debug.print("build_adapter: appending custom section: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const wasm = wabt.binary.writer.writeModule(gpa, &module) catch |err| {
        std.debug.print(
            "build_adapter: encode '{s}': {any}\n",
            .{ in_path, err },
        );
        std.process.exit(1);
    };
    defer gpa.free(wasm);

    // Sanity check: the produced bytes must be consumable by the
    // adapter splicer's `decode.parseFromAdapterCore`. Without this
    // we'd ship an adapter that fails at `wabt component new` time
    // with a confusing `MissingEncodedWorld` / `UnsupportedAdapterShape`.
    var verify_arena = std.heap.ArenaAllocator.init(gpa);
    defer verify_arena.deinit();
    _ = wabt.component.adapter.decode.parseFromAdapterCore(verify_arena.allocator(), wasm) catch |err| {
        std.debug.print(
            "build_adapter: produced adapter failed self-check (decode.parseFromAdapterCore): {s}\n",
            .{@errorName(err)},
        );
        std.process.exit(1);
    };

    cwd.writeFile(init.io, .{
        .sub_path = out_path,
        .data = wasm,
    }) catch |err| {
        std.debug.print(
            "build_adapter: write '{s}': {any}\n",
            .{ out_path, err },
        );
        std.process.exit(1);
    };
}
