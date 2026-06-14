# example/hello

A standalone `wasi:cli` command component written in Zig: it exports
`wasi:cli/run@0.2.6`, prints a greeting to stdout, and returns a process
exit code. Built `wasm32-freestanding` against the
[`wasip2`](https://github.com/cataggar/wabt/tree/wasip2) guest-binding
library (the `wasi_cli` / `wasi_io` / `abi` modules), then wrapped into a
component with `wabt component new`.

This lives on the orphan branch `example/hello`; the `wasip2` library it
depends on lives on the orphan branch `wasip2` of the same repository.

## Prerequisites

- Zig `0.16.0`.
- The `wabt` CLI (cataggar/wabt) on `PATH`.

## Build

```sh
zig build examples
```

Produces `zig-out/examples/hello.wasm`.

## Run

```sh
# wasmtime
wasmtime run -S cli-exit-with-code zig-out/examples/hello.wasm

# wamr (AOT-compile then run)
wamrc run zig-out/examples/hello.wasm
```
