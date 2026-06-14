# example/hello

A standalone `wasi:cli` command component written in Zig: it exports
`wasi:cli/run@0.2.6`, prints to stdout, and returns a process
exit code. Built `wasm32-freestanding`, then wrapped into a
component with `wabt component new`.

This lives on the orphan branch `example/hello`; the `wasip2` library it
depends on lives on the orphan branch `wasip2` of the same repository.

## Prerequisites

- `zig`, `wabt`, and `wasmtime` on `PATH`.

An easy way to install using [ghr](https://github.com/cataggar/ghr):
```
ghr install cataggar/zig@v0.16.0 RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ghr install cataggar/wabt@v3.0.0-dev.18 RWSBnHWjwk/kkqdYc74cGupHMNVobpmF3lPc7b8RIllYMmYBr5G2EyF0
ghr install bytecodealliance/wasmtime@v45.0.1

zig version
wabt version
wasmtime --version
```

## Build and Run

```sh
git clone --branch example/hello --single-branch https://github.com/cataggar/wabt.git hello
cd hello
zig build run
```

## Run Directly

```sh
wasmtime run -S cli-exit-with-code zig-out/hello.wasm
```
