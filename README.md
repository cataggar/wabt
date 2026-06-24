# example/hello

A standalone `wasi:cli` command component written in Zig: it exports
`wasi:cli/run@0.3.0`,
prints to stdout, and returns a process exit code. Built
`wasm32-freestanding`, then wrapped into a component with `wabt component new`.

## Prerequisites

- `zig`, `wabt`, and `wasmtime` on `PATH`.

An easy way to install using [ghr](https://github.com/cataggar/ghr):
```
ghr install cataggar/zig@v0.16.0 RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ghr install cataggar/wabt@v3.0.0-dev.19 RWSBnHWjwk/kkqdYc74cGupHMNVobpmF3lPc7b8RIllYMmYBr5G2EyF0
ghr install bytecodealliance/wasmtime@v46.0.0
```

```
zig version
wabt version
wasmtime --version
```

## Build and Run

```sh
git clone --branch example/hello --single-branch https://github.com/cataggar/wabt.git hello
cd hello
zig build run -- Johnny
```

Pass a different first argument (or none) to get the non-matching branch and
exit code `5`:

```sh
zig build run -- Alice
```

## Run Directly

WASI 0.3 components use the Component-Model async ABI, so wasmtime needs the
P3 async features enabled:

```sh
wasmtime run \
  -W component-model-async \
  -W component-model-async-stackful \
  -W component-model-more-async-builtins \
  -W component-model-error-context \
  -S cli-exit-with-code \
  zig-out/hello.wasm Johnny
```

## Uninstall

```
ghr uninstall cataggar/zig
ghr uninstall cataggar/wabt
ghr uninstall bytecodealliance/wasmtime
```
