# preopens

A `wasi:cli` command that lists the directories the host preopened,
exercising the `wasi_filesystem` `preopens.get-directories` binding.

## Build

```sh
zig build examples
```

Produces `zig-out/examples/preopens.wasm`.

## Run

```sh
# With a preopened directory:
wasmtime run -S cli-exit-with-code --dir .::/ zig-out/examples/preopens.wasm

# Without any --dir, it prints "no preopened directories".
wasmtime run -S cli-exit-with-code zig-out/examples/preopens.wasm
```
