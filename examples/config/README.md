# config

A `wasi:cli` command that reads runtime configuration via the
off-by-default `wasi:config@0.2.0-rc.1` proposal (`store.get` /
`store.get-all`), exercising the `wasi_config` bindings.

The `wasi:config` WIT is vendored under `wit/deps/config/` because the
released `wabt` CLI does not yet embed the proposal packages (that lands
with the multi-version embed work). Once a `wabt` that embeds proposals
is on PATH, the `wit/deps/` copy can be removed.

## Build

```sh
zig build examples
```

Produces `zig-out/examples/config.wasm` (built + `wabt module validate`d).

## Run

Running needs a host that implements `wasi:config`; `wasmtime` 45 does
not, so this example is validated at build time only.
