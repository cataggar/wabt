# Source Provenance

## miz OCI foundation

- **Upstream:** [cataggar/miz](https://github.com/cataggar/miz)
- **Pinned revision:** [`669a27982b376311f558e820b69e9a692735b0cd`](https://github.com/cataggar/miz/commit/669a27982b376311f558e820b69e9a692735b0cd)
- **Pinned source tree:** <https://github.com/cataggar/miz/tree/669a27982b376311f558e820b69e9a692735b0cd/packages/miz/src/oci>
- **License:** MIT; see [`LICENSES/miz-MIT.txt`](LICENSES/miz-MIT.txt)

The initial `src/oci.zig` namespace is WABT-owned scaffolding and contains no
adapted implementation. The following paths identify the pinned sources and
planned WABT destinations for later foundation increments:

| Pinned miz source | Planned WABT destination |
| --- | --- |
| `packages/miz/src/oci/content.zig` | `src/oci/content.zig` |
| `packages/miz/src/oci/reference.zig` | `src/oci/reference.zig` |
| `packages/miz/src/oci/model.zig` | `src/oci/model.zig`, `src/oci/graph.zig` |
| `packages/miz/src/oci/transport.zig` | `src/oci/transport.zig` |
| `packages/miz/src/oci/layout.zig` | `src/oci/layout.zig`, `src/oci/integration_tests.zig` |
| `packages/miz/src/oci/copy.zig` | `src/oci/copy.zig`, `src/oci/graph.zig`, `src/oci/integration_tests.zig` |

The adaptation will not copy miz's `oci.zig` facade wholesale or its
authentication, registry, image, layer, filesystem, bundle, snapshot, repack,
signing, disk-image, or QEMU integrations. WABT's implementation will use
scheme-less explicit registry references, artifact-capable generic
validation, one bounded graph planner, and explicit rejection of
subject-bearing and unknown graph nodes.
