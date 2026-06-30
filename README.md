# example/http — PetStore

A `wasi:http` service loosely based on this
[TypeSpec](https://github.com/microsoft/typespec/blob/main/packages/samples/specs/petstore/petstore.tsp).

## Build and Run

```sh
git clone --branch example/petstore --single-branch https://github.com/cataggar/wabt.git petstore
cd petstore
zig build
zig build serve           # wasmtime serve on 127.0.0.1:8080 (default)
zig build test            # run integration tests (walks every endpoint)
```

## Example Requests

```sh
# List all pets
curl http://127.0.0.1:8080/pets

# Create a pet
curl -X POST http://127.0.0.1:8080/pets \
  -H "Content-Type: application/json" \
  -d '{"name":"Fluffy","age":3}'

# Get a pet by ID
curl http://127.0.0.1:8080/pets/1

# Get toys for a pet
curl http://127.0.0.1:8080/pets/1/toys

# Delete a pet
curl -X DELETE http://127.0.0.1:8080/pets/1
```
