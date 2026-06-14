# nn

A `wasi:cli` command that constructs and inspects a tensor via the
experimental `wasi:nn@0.2.0-rc-2024-10-28` proposal (the `tensor`
interface), exercising the `wasi_nn` bindings.

The `wasi:nn` WIT is vendored under `wit/deps/nn/` because the released
`wabt` CLI does not yet embed the proposal packages.

## Build

```sh
zig build examples
```

Produces `zig-out/examples/nn.wasm` (built + `wabt module validate`d).

## Run

Running needs a host with a `wasi:nn` backend (e.g. `wasmtime -S nn`,
experimental); this example is validated at build time only.
