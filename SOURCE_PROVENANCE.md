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
| `packages/miz/src/oci/registry.zig` | `src/oci/registry_http.zig`, `src/oci/registry.zig`, `src/oci/registry_test.zig` |
| `packages/miz/src/oci/model.zig` | `src/oci/model.zig`, `src/oci/graph.zig` |
| `packages/miz/src/oci/transport.zig` | `src/oci/transport.zig` |
| `packages/miz/src/oci/layout.zig` | `src/oci/layout.zig`, `src/oci/integration_tests.zig` |
| `packages/miz/src/oci/copy.zig` | `src/oci/copy.zig`, `src/oci/copy_engine.zig`, `src/oci/graph.zig`, `src/oci/integration_tests.zig`, `src/oci/registry_test.zig` |

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

`src/oci/registry_http.zig` adapts miz's system-plus-additional CA loading,
manual redirect handling, bounded `Retry-After` parsing, and deterministic
backoff. WABT separates those mechanics from Distribution semantics and adds
canonical origin policy, loopback-only explicit HTTP, authorization stripping,
an injected backend/runtime boundary, absolute operation deadlines, scoped
token-cache integration, secret-safe diagnostics, and explicit Zig 0.16
socket-timeout capability reporting.

`src/oci/registry.zig` materially adapts miz's registry resolve, manifest,
blob, and tag-list read paths behind WABT's repository-bound source and
injected HTTP/authentication boundaries. WABT resolves tags from exact GET
bytes once, derives immutable descriptors, uses digest-only follow-up
requests, validates artifact-capable graphs, separates manifest reads from
opaque blob streaming, enforces bounded same-origin pagination, and returns
typed redacted diagnostics. `src/oci/registry_test.zig` replaces miz's
platform-specific/live assumptions with deterministic injected and loopback
fixtures covering authentication, retries, redirects, corruption, pagination,
output cleanup, destination preflight, verified blob reuse, and same-origin
cross-repository mount outcomes.

The registry destination state and mount request shape adapt miz
`Destination.prepareTransport`, `ensureBlob`, `tryMount`, `mountUrl`, and
`resolveUploadLocation`, plus its spool/upload and manifest publication flow.
WABT requires an explicit destination tag and independent destination
authentication context, re-verifies blob bytes before reuse and after a 201
mount, percent-encodes mount parameters, and disables non-idempotent
redirect/retry/authentication replay. Missing opaque blobs are streamed once
into exclusive private spool files, independently reverified, rehashed again
while serving upload bodies, and uploaded through bounded monolithic PUT or
explicitly configured PATCH/finalize flows. Every returned session Location is
bounded and revalidated; signed queries are preserved, cross-origin
authorization is stripped, offsets/UUIDs/session paths are checked, and
ambiguous writes are resolved by safe exact-state probes before any fresh
session resends the spool from byte zero. Owned redacted incomplete-upload
state documents remote sessions that may remain while local spool files are
always removed; successful recovery may also leave an abandoned remote
session for registry garbage collection.

Exact child manifests/indexes and the root are published at immutable digest
references without JSON reserialization. The destination tag PUT is the final
visibility operation, and an ambiguous final PUT succeeds only after both the
tag and immutable digest resolve to the expected exact content. After that
confirmation, registry `finish` performs no fallible work, so the shared engine
cannot report failure after the tag has become visible. This increment adapts
the four registry/layout copy pairing constructors, but not CLI/profile upload
logic, deletion, signatures, or referrers.

The transport `Source`, `Destination`, and transfer-counting callbacks adapt
the corresponding pinned `transport.zig` contracts. WABT adds allocator-owned
bounded metadata, typed stage/commit results, centralized implementation
adapters, a credential-free normalized registry identity for mount policy, and
sanitized progress/failure events. Upload-session state remains owned by the
registry destination rather than the transport-neutral graph engine.

`src/oci/graph.zig` adapts the traversal ideas from miz
`model.resolveGraph` and `copy.Context.planAll` into one implementation.
Unlike those pinned functions, it performs complete artifact-capable
discovery with explicit depth, descriptor-count, total-byte, and per-document
bounds plus a cumulative retained-metadata bound; verifies exact metadata
before parsing; retains separate blob/document work for a digest used in both
roles; rejects subjects, cycles, conflicts, and unsupported graph nodes; and
does not select a host platform.

`src/oci/layout.zig` adapts miz `layout.Source.resolve`,
`layout.Source.copyVerifiedTo`, `layout.Destination.ensureContent`,
`layout.Destination.commitExact`, and its lock/temp helpers. WABT uses the
frozen transport interfaces, `.wabt-oci-*` staging/temp names, generic
artifact validation, bounded metadata reads, and separate missing-versus-
corrupt blob errors. `src/oci/copy_engine.zig` adapts the dependency-first
execution portion of miz `copy.resolvedToDestination`; `src/oci/copy.zig` and
the registry source/destination methods provide thin constructors for all four
pairings. Discovery remains exclusively in WABT's single `graph.planCopy`
implementation and performs no platform selection. Registry roots resolved
from tags retain their exact first response bytes and expose only
credential-free origin/repository identity to destination mount policy.

## OCI Wasm profile contracts

- **Wasm-v0 source:** [rust-oci-wasm v0.6.0](https://github.com/bytecodealliance/rust-oci-wasm/tree/v0.6.0), commit [`8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd`](https://github.com/bytecodealliance/rust-oci-wasm/commit/8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd)
- **wkg compatibility reference:** [wasm-pkg-tools `wkg` OCI commands](https://github.com/bytecodealliance/wasm-pkg-tools/blob/5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a/crates/wkg/src/oci.rs), commit [`5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a`](https://github.com/bytecodealliance/wasm-pkg-tools/commit/5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a)

`src/oci/wasm.zig` implements these profile contracts with handcrafted,
deterministic fixtures rather than copied upstream binaries. Wasm-v0 uses the
versioned config media type and native WABT parsing for metadata. The generic
profile is the OCI 1.1/ORAS shape with the canonical empty JSON config; it is
generic-OCI compatible but intentionally not accepted by wkg's Wasm-v0 config
check. The OCI 1.0 ORAS shape is accepted for reads only. Tests do not invoke
ORAS, wkg, a registry, an archive tool, or a runtime.
