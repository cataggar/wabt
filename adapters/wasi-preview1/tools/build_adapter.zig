//! `build_adapter` — assemble the wasi-preview1 → preview2 adapter
//! artifact from a list of WAT source fragments plus the embedded
//! `component-type:…:encoded world` custom section.
//!
//! Driven by `zig build adapter` / `zig build adapter-reactor`. CLI:
//!
//!     build-wasi-preview1-adapter <wit-dir> <world-name> <output.wasm> \
//!         <fragment1.wat> [<fragment2.wat> ...]
//!
//! Multiple `.wat` inputs are concatenated in argv order before
//! parsing. The single-source case (one fragment) still works; the
//! command and reactor adapters both pass the full fragment list
//! from `src/fragments/` so the bulk of the preview1→preview2
//! lowering body stays single-source.
//!
//! Pipeline:
//!
//!   1. Read every `.wat` fragment in order and concatenate.
//!   2. Parse + validate via `wabt.text.Parser.parseModule` +
//!      `wabt.Validator.validate` (same path as `wabt text parse`).
//!   3. Parse the WIT layout under `<wit-dir>` via
//!      `wabt.component.wit.resolver.parseLayout` and encode the
//!      `<world-name>` world via
//!      `wabt.component.wit.metadata_encode.encodeWorldFromResolver`.
//!   4. Append the encoded world payload as a
//!      `component-type:wabt:wasi-preview1@0.0.0:<world>:encoded world`
//!      custom section to the module before serialisation.
//!   5. Serialise via `wabt.binary.writer.writeModule`.
//!   6. Write the bytes to the output path.
//!   7. Self-check by re-parsing the output through
//!      `wabt.component.adapter.decode.parseFromAdapterCore` so a
//!      broken section-name / encoded-world payload surfaces here
//!      rather than at `wabt component new` time.

const std = @import("std");
const wabt = @import("wabt");

/// Custom-section name prefix. The splicer's
/// `decode.extractEncodedWorld` accepts any section whose name
/// starts with `component-type:` (see
/// `src/component/adapter/decode.zig:138`), so the suffix is for
/// human readability only.
const ct_section_name_prefix = "component-type:wabt:wasi-preview1@0.0.0:";
const ct_section_name_suffix = ":encoded world";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 5) {
        std.debug.print(
            "usage: {s} <wit-dir> <world-name> <output.wasm> <fragment1.wat> [<fragment2.wat> ...]\n",
            .{if (args.len > 0) args[0] else "build-wasi-preview1-adapter"},
        );
        std.process.exit(2);
    }
    const wit_dir = args[1];
    const world_name = args[2];
    const out_path = args[3];
    const fragment_paths = args[4..];

    const ct_section_name = std.fmt.allocPrint(
        gpa,
        "{s}{s}{s}",
        .{ ct_section_name_prefix, world_name, ct_section_name_suffix },
    ) catch |err| {
        std.debug.print("build_adapter: format section name: {any}\n", .{err});
        std.process.exit(1);
    };
    defer gpa.free(ct_section_name);

    const cwd = std.Io.Dir.cwd();

    // Concatenate every fragment in argv order. `wabt.text.Parser`
    // operates on a single source buffer; fragments are line-aligned
    // so a `\n` separator between them keeps source positions sane
    // in any error report.
    var source_buf = std.ArrayListUnmanaged(u8).empty;
    defer source_buf.deinit(gpa);
    for (fragment_paths) |frag_path| {
        const piece = cwd.readFileAlloc(
            init.io,
            frag_path,
            gpa,
            std.Io.Limit.limited(wabt.max_input_file_size),
        ) catch |err| {
            std.debug.print(
                "build_adapter: cannot read '{s}': {any}\n",
                .{ frag_path, err },
            );
            std.process.exit(1);
        };
        defer gpa.free(piece);
        source_buf.appendSlice(gpa, piece) catch |err| {
            std.debug.print("build_adapter: concat fragments: {any}\n", .{err});
            std.process.exit(1);
        };
        // Trailing newline between fragments so any fragment that
        // ends without one doesn't run into the next fragment's
        // first token.
        if (piece.len == 0 or piece[piece.len - 1] != '\n') {
            source_buf.append(gpa, '\n') catch |err| {
                std.debug.print("build_adapter: concat fragments: {any}\n", .{err});
                std.process.exit(1);
            };
        }
    }
    const source = source_buf.items;

    var module = wabt.text.Parser.parseModule(gpa, source) catch |err| {
        std.debug.print(
            "build_adapter: parse concatenated fragments: {any}\n",
            .{err},
        );
        std.process.exit(1);
    };
    defer module.deinit();

    wabt.Validator.validate(&module, .{}) catch |err| {
        std.debug.print(
            "build_adapter: validate concatenated fragments: {any}\n",
            .{err},
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
            "build_adapter: encode module to wasm: {any}\n",
            .{err},
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
