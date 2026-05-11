//! `build_adapter` — assemble the wasi-preview1 → preview2 adapter
//! artifact from the WAT source.
//!
//! Driven by `zig build adapter`. CLI:
//!
//!     build-wasi-preview1-adapter <adapter.wat> <output.wasm>
//!
//! Pipeline (current scaffold):
//!
//!   1. Read the WAT source file.
//!   2. Parse + validate via `wabt.text.Parser.parseModule` +
//!      `wabt.Validator.validate` (same path as `wabt text parse`).
//!   3. Serialise via `wabt.binary.writer.writeModule`.
//!   4. Write the bytes to the output path.
//!
//! Deferred (tracked as separate follow-ups under cataggar/wamr#453):
//!
//!   * Step 5 — append a `component-type:wabt:0.0.0:wasi:cli@0.2.6:
//!     command:encoded world` custom section. Requires WIT-encoder
//!     support for resource handles (the real `wasi:io/streams`
//!     interface uses `[method]output-stream.…(borrow<output-stream>,
//!     …)`); `metadata_encode.zig` currently rejects those with
//!     `error.UnsupportedWitFeature`. Until that lands, the produced
//!     `wasi_snapshot_preview1.command.wasm` is shape-only: parses +
//!     validates as a core wasm module but is not yet consumable by
//!     `wabt component new` (the splicer's `decode.zig` requires an
//!     encoded-world payload). See `../README.md` § Status.
//!
//!   * Step 6 — replace the stub function bodies in
//!     `../src/adapter.wat` with real preview1 → preview2 logic
//!     (`fd_write` iterates iovecs and calls
//!     `output-stream.blocking-write-and-flush`, `args_get` lowers
//!     `wasi:cli/environment.get-arguments`, etc.).

const std = @import("std");
const wabt = @import("wabt");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len != 3) {
        std.debug.print(
            "usage: {s} <adapter.wat> <output.wasm>\n",
            .{if (args.len > 0) args[0] else "build-wasi-preview1-adapter"},
        );
        std.process.exit(2);
    }
    const in_path = args[1];
    const out_path = args[2];

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

    const wasm = wabt.binary.writer.writeModule(gpa, &module) catch |err| {
        std.debug.print(
            "build_adapter: encode '{s}': {any}\n",
            .{ in_path, err },
        );
        std.process.exit(1);
    };
    defer gpa.free(wasm);

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
