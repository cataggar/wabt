# example/http — PetStore

A `wasi:http@0.3.0` **service** written in Zig that implements the
[TypeSpec petstore sample](https://github.com/microsoft/typespec/blob/main/packages/samples/specs/petstore/petstore.tsp)
over an **in-memory store** seeded with example pets and toys. It exports the
async `wasi:http/handler@0.3.0#handle`, wrapped into a component with
`wabt component new` and served with `wasmtime serve`.

This lives on the orphan branch `example/http`; the `wasip3` library it depends
on lives on the orphan branch `wasip3` of the same repository.

## API

| Method | Route                | Body / Query        | Response                          |
| ------ | -------------------- | ------------------- | --------------------------------- |
| GET    | `/pets`              |                     | `{ "items": Pet[] }`              |
| POST   | `/pets`              | `Pet` JSON          | created `Pet` (`400` if invalid)  |
| GET    | `/pets/{id}`         |                     | `Pet` or `404` `Error`            |
| DELETE | `/pets/{id}`         |                     | `200` or `404` `Error`            |
| GET    | `/pets/{id}/toys`    |                     | `{ "items": Toy[] }`             |

`Pet` is `{ id, name, tag?, age }` (age is validated to `0..20`); `Toy` is
`{ id, petId, name }`; `Error` is `{ code, message }`.

## How it works

WASI 0.3 has no `wasi:io`. Per request the handler:

1. Reads the request **method** and **path-with-query** (`request.get-method`,
   `request.get-path-with-query`), then the request **body** by `consume-body` +
   a cooperative `stream.read` loop.
2. Routes and updates the in-memory store, serializing JSON into a per-task
   buffer.
3. Builds a `response` (status + `content-type` header + body `stream<u8>`),
   reports it with `task.return`, then streams the body and resolves the
   trailers — cooperatively waiting on a `waitable-set` whenever a write blocks.

**Concurrency.** Hosts may invoke `handle` concurrently (interleaved at `await`
points on one thread). The store is static global state mutated by synchronous,
await-free operations, and all per-request data lives in per-task stack buffers
— so concurrent in-flight requests never corrupt each other.

## Prerequisites

- `zig` 0.16, a **P3-capable `wabt`** (with non-primitive stream/future element
  support), and **`wasmtime` >= 46** on `PATH` — or pointed to via the `WABT`
  and `WASMTIME` environment variables.

## Build and serve

```sh
git clone --branch example/http --single-branch https://github.com/cataggar/wabt.git petstore
cd petstore
zig build                 # produces zig-out/http.wasm
zig build serve           # wasmtime serve on 127.0.0.1:8080 (default)
```

In another terminal:

```sh
curl http://127.0.0.1:8080/pets
# {"items":[{"id":1,"name":"Fluffy","tag":"cat","age":3}, ...]}

curl -X POST http://127.0.0.1:8080/pets -H 'content-type: application/json' \
  -d '{"name":"Whiskers","tag":"cat","age":2}'
# {"id":4,"name":"Whiskers","tag":"cat","age":2}

curl http://127.0.0.1:8080/pets/1/toys
# {"items":[{"id":100,"petId":1,"name":"Yarn Ball"}, ...]}
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
