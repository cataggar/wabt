# Source Provenance

## miz OCI foundation

- **Upstream:** [cataggar/miz](https://github.com/cataggar/miz)
- **Pinned revision:** [`669a27982b376311f558e820b69e9a692735b0cd`](https://github.com/cataggar/miz/commit/669a27982b376311f558e820b69e9a692735b0cd)
- **Pinned source tree:** <https://github.com/cataggar/miz/tree/669a27982b376311f558e820b69e9a692735b0cd/packages/miz/src/oci>
- **License:** MIT; see [`LICENSES/miz-MIT.txt`](LICENSES/miz-MIT.txt)

The following paths identify the pinned sources and their WABT destinations:

| Pinned miz source | WABT destination |
| --- | --- |
| `packages/miz/src/oci/content.zig` | `src/oci/content.zig` |
| `packages/miz/src/oci/reference.zig` | `src/oci/reference.zig` |
| `packages/miz/src/oci/auth.zig` | `src/oci/auth.zig` |
| `packages/miz/src/oci/model.zig` | `src/oci/model.zig`, `src/oci/graph.zig` |
| `packages/miz/src/oci/transport.zig` | `src/oci/transport.zig` |
| `packages/miz/src/oci/layout.zig` | `src/oci/layout.zig`, `src/oci/integration_tests.zig` |
| `packages/miz/src/oci/copy.zig` | `src/oci/copy.zig`, `src/oci/graph.zig`, `src/oci/integration_tests.zig` |

The adaptation does not copy miz's `oci.zig` facade wholesale or its registry,
image, layer, filesystem, bundle, snapshot, repack, signing, disk-image, or
QEMU integrations. WABT's implementation uses
scheme-less explicit registry references, artifact-capable generic
validation, one bounded graph planner, and explicit rejection of
subject-bearing and unknown graph nodes.

`src/oci/auth.zig` adapts miz's bounded RFC 9110 challenge parser, Docker and
containers credential-file matching, credential-helper protocol, Basic
authorization construction, token-response parsing, and token-cache ideas.
WABT adds a mutually exclusive credential-policy union, caller-injected
file/environment/process/token boundaries, cumulative parser bounds,
duplicate-parameter rejection, exact normalized authority matching, strict
base64 decoding, explicit unsupported identity-token handling, helper
deadlines, redacted formatting, deterministic scope canonicalization, and
registry-origin/context/generation cache isolation. It performs no HTTP and
does not inspect ambient credentials unless the caller invokes the enabled
policy.

The transport `Source`, `Destination`, and transfer-counting callbacks adapt
the corresponding pinned `transport.zig` contracts. WABT adds allocator-owned
bounded metadata, typed stage/commit results, centralized implementation
adapters, and sanitized progress/failure events; it omits miz's registry
identity and upload-specific details.

`src/oci/graph.zig` adapts the traversal ideas from miz
`model.resolveGraph` and `copy.Context.planAll` into one implementation.
Unlike those pinned functions, it performs complete artifact-capable
discovery with explicit depth, descriptor-count, total-byte, and per-document
bounds; verifies exact metadata before parsing; retains content-addressed
bytes; rejects subjects, cycles, conflicts, and unsupported graph nodes; and
does not select a host platform.

`src/oci/layout.zig` adapts miz `layout.Source.resolve`,
`layout.Source.copyVerifiedTo`, `layout.Destination.ensureContent`,
`layout.Destination.commitExact`, and its lock/temp helpers. WABT uses the
frozen transport interfaces, `.wabt-oci-*` staging/temp names, generic
artifact validation, bounded metadata reads, and separate missing-versus-
corrupt blob errors. `src/oci/copy.zig` adapts the dependency-first execution
portion of miz `copy.resolvedToDestination`; discovery remains exclusively in
WABT's single `graph.planCopy` implementation and performs no platform
selection.
