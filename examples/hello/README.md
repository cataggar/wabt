# hello

A minimal `wasi:cli` command component written in Zig. It exports
`wasi:cli/run@0.2.6`, prints a greeting to stdout, and returns a process
exit code.

## Build

```sh
zig build examples
```

Produces `zig-out/examples/hello.wasm`.

## Run

```sh
# wamr
wamr run zig-out/examples/hello.wasm

# wasmtime
wasmtime run -S cli-exit-with-code zig-out/examples/hello.wasm
```
