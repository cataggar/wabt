# example/http

A standalone `wasi:http@0.3.0` **service** component written in Zig: it exports
the async `wasi:http/handler@0.3.0#handle`, builds a `200` response, and streams
`Hello, WASI!` as the body. Built `wasm32-freestanding`, then wrapped into a
component with `wabt component new`.

This lives on the orphan branch `example/http`; the `wasip3` library it depends
on lives on the orphan branch `wasip3` of the same repository.

## How it works

WASI 0.3 has no `wasi:io`. The handler:

1. Builds empty headers (`fields.constructor`) and a body `stream<u8>`.
2. Creates the trailers `future<result<option<trailers>, error-code>>` and calls
   `response.new(headers, some(body), trailers)`.
3. Reports the response with `task.return` (an async export).
4. **Then** — once the host holds the response and reads concurrently — streams
   the body and resolves the trailers to `ok(none)`, cooperatively waiting on a
   `waitable-set` whenever a write blocks.

## Prerequisites

- `zig` 0.16, a **P3-capable `wabt`** (with non-primitive stream/future element
  support), and **`wasmtime` >= 46** on `PATH` — or pointed to via the `WABT` and
  `WASMTIME` environment variables.

## Build and serve

```sh
git clone --branch example/http --single-branch https://github.com/cataggar/wabt.git http
cd http
zig build                 # produces zig-out/http.wasm
zig build serve           # wasmtime serve on 127.0.0.1:8080 (default)
```

In another terminal:

```sh
curl http://127.0.0.1:8080/
# Hello, WASI!
```

To point at specific tool builds:

```sh
WABT=/path/to/wabt WASMTIME=/path/to/wasmtime zig build serve -- --addr 127.0.0.1:8080
```

## Serve directly

```sh
wasmtime serve -W component-model-async -W component-model-async-stackful \
  -W component-model-more-async-builtins -W component-model-error-context \
  -S p3,cli zig-out/http.wasm
```
