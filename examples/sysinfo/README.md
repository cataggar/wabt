# sysinfo

A `wasi:cli` command that prints a monotonic clock reading and a random
`u64`, exercising the `wasi_clocks` and `wasi_random` guest bindings.

## Build

```sh
zig build examples
```

Produces `zig-out/examples/sysinfo.wasm`.

## Run

```sh
wasmtime run -S cli-exit-with-code zig-out/examples/sysinfo.wasm
```
