# resolve

A `wasi:cli` command that resolves `localhost` to IP addresses via
`wasi:sockets/ip-name-lookup`, exercising the `wasi_sockets` bindings
(instance-network + the async resolve-address-stream + `wasi_io` poll).

## Build

```sh
zig build examples
```

Produces `zig-out/examples/resolve.wasm`.

## Run

Name lookup requires the host to grant network access and enable the
`ip-name-lookup` + `network-error-code` features:

```sh
wasmtime run -S inherit-network -S allow-ip-name-lookup \
  -S network-error-code -S cli-exit-with-code zig-out/examples/resolve.wasm
```

Prints e.g. `127.0.0.1` / `0:0:0:0:0:0:0:1` and
`resolved 2 address(es) for localhost`.
