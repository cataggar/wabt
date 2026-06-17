# example/http — PetStore (composed)

A `wasi:http@0.3.0` **service** written in Zig that implements the
[TypeSpec petstore sample](https://github.com/microsoft/typespec/blob/main/packages/samples/specs/petstore/petstore.tsp),
split into **two components linked with `wabt component compose`**:

- a **frontend** that exports the async `wasi:http/handler@0.3.0#handle`, parses
  HTTP, and serializes JSON (typed, via `std.json`); and
- a separate **storage** component that owns the in-memory pets/toys (seeded with
  examples) and exports a typed `example:petstore/store` data-access interface.

The frontend `import`s `store`; compose binds that import to the storage
provider's export, yielding one servable component (`zig-out/petstore.wasm`).
Each half is built `wasm32-freestanding`, wrapped with `wabt component new`, then
linked with `wabt component compose`.

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

### The `store` boundary (`wit/world.wit`)

`interface store` is a typed data-access API: `pet` / `toy` **records**, with
`option<record>` results and `count` + indexed `*-at` accessors (instead of
`list<record>`). Worlds: `svc` (the frontend) `import`s `store` and wasi:http;
`store-provider` (the backend) `export`s `store`; `store-consumer` is an
import-only world used by bindgen.

Both sides' canonical-ABI glue is **generated at build time** by
`wabt component bindgen`, which emits the flattened `extern`/`export` shells and
the `Pet` / `Toy` Zig types and delegates all marshalling to `wasip3`'s comptime
`canon` library. There is no hand-written `extern struct`, flat-vs-indirect
logic, or lower/lift code on either side.

- **Backend** — `build.zig` runs `bindgen` on `store-provider` to generate the
  `export fn` shells (params lifted with `canon.liftParams`, return type
  `canon.CoreReturn(R)`, result encoded with `canon.returnResult`). The shells
  call **`src/store_impl.zig`** — the in-memory pets/toys store, pure business
  logic returning the generated `Pet` / `Toy` types.
- **Frontend** — `bindgen` on `store-consumer` generates the `store.*` import
  wrappers (results decoded with `canon.liftResultFlat` / `canon.lift`).
  `src/main.zig` calls them and builds `PetJson` / `ToyJson`, serializing with
  `std.json` (`emit_null_optional_fields = false`, so an absent `tag` is
  omitted).

### The HTTP request (WASI 0.3 has no `wasi:io`)

Per request the frontend handler:

1. Reads the request **method** and **path-with-query** (`request.get-method`,
   `request.get-path-with-query`), then the request **body** by `consume-body` +
   a cooperative `stream.read` loop.
2. Routes to the imported `store` calls and serializes JSON into a per-task
   buffer.
3. Builds a `response` (status + `content-type` header + body `stream<u8>`),
   reports it with `task.return`, then streams the body and resolves the
   trailers — cooperatively waiting on a `waitable-set` whenever a write blocks.

**Concurrency.** Hosts may invoke `handle` concurrently (interleaved at `await`
points on one thread). The store is static global state (in the backend
component) mutated by synchronous, await-free `store` calls, and all per-request
data lives in per-task stack buffers — so concurrent in-flight requests never
corrupt each other.

## Prerequisites

- `zig` 0.16, a **P3-capable `wabt`** (with non-primitive stream/future element
  support, value-typed export interfaces, and the `component bindgen` subcommand
  — see cataggar/wabt #281/#282/#283), and **`wasmtime` >= 46** on `PATH` — or
  pointed to via the `WABT` and `WASMTIME` environment variables.

## Build and serve

```sh
git clone --branch example/http --single-branch https://github.com/cataggar/wabt.git petstore
cd petstore
zig build                 # builds both components + composes -> zig-out/petstore.wasm
zig build serve           # wasmtime serve on 127.0.0.1:8080 (default)
zig build bindgen         # write the generated store bindings to zig-out/generated/
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
  -S p3,cli zig-out/petstore.wasm
```
