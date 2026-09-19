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

## OCI interoperability fixture producers

The checked-in corpus under `src/fixtures/oci/` is generated separately from
ordinary tests. `src/fixtures/oci/manifest.json` is the machine-readable source
of truth for every producer command, root/config/payload descriptor, file hash,
expected acceptance or rejection, and actual executable/compiler hash. The
offline verifier and default Zig tests consume only committed bytes.

- **ORAS CLI 1.3.4:** signed tag commit
  [`db9e29505c3059f2b8fde34ae8cae266c5c765e9`](https://github.com/oras-project/oras/commit/db9e29505c3059f2b8fde34ae8cae266c5c765e9).
  The official checksum-list SHA-256 is
  `19d479e497fb5e30c7de3c621e3ed337e3857de0d96542021a73e2d8016dbe5a`;
  the Linux arm64 archive SHA-256 is
  `15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399`.
  The executed binary reported Go 1.25.14, commit `db9e295…`, and SHA-256
  `2915306a072ba69e4efbbe20d79246c5dbba8158efc8c4400841eca70dd5f458`.
- **wkg 0.16.1:** verified wasm-pkg-tools revision
  [`5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a`](https://github.com/bytecodealliance/wasm-pkg-tools/commit/5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a),
  tree `ea20d1f82502eec5c5bc7315bc0fd7653a154221`, with `Cargo.lock`
  SHA-256 `bf465c989fa26cb06778624fd2de843ca5d6318b4a58418c9e392e13dc02d732`.
  It was built `--locked` by rustc 1.97.0
  (`2d8144b7880597b6e6d3dfd63a9a9efae3f533d3`, binary SHA-256
  `cb482cd75185f5dde1d40e50b258c5cd6a4465dcf3f494f2dc0e57224bf314b2`)
  and Cargo 1.97.0 (binary SHA-256
  `48465d951d7b6a98f2fd9cddfa3bfde8ad81796d8c4b56d1f1e4c45775740b53`)
  using Zig 0.16.0 as the native linker (binary SHA-256
  `6e2989a7efbd4e81acbacb6c6378e34340d8e88bb023b10c4a941021be55cdcb`).
  Rust was installed by rustup 1.28.2 from the Linux arm64 `rustup-init`
  binary with SHA-256
  `e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c`.
  The fixture-generation run's normalized wkg binary SHA-256 is
  `da4d86375734ae975007eef0617fb0fd43721ee89e48de7eca50c2d16229d18a`.
  That built-binary hash is recorded as provenance rather than a portable
  rebuild pin because release-mode Rust panic strings and unused RUNPATH
  entries retain absolute Cargo/Rustup state paths. Qualification instead
  pins the source revision/tree, lock file, oci-wasm checksum, Rust/Cargo/Zig
  binaries, and requires the generated OCI bytes to match the corpus exactly.
- **oci-wasm 0.6.0:** crates.io checksum
  `87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21`;
  tag commit
  [`8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd`](https://github.com/bytecodealliance/rust-oci-wasm/commit/8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd).
  Generation checks both the locked crate checksum and authoritative tag
  identity.
- **Distribution registry 3.1.1:** official Linux arm64 archive SHA-256
  `8167316d2b4a57e10d44f8c8a3c75fea5f3ec1c71872760bb903e5e8e52e9ad6`;
  executed binary SHA-256
  `669f0d9892da6ccd44a40954f39a3b929f4455d7ed02a806828346feac572834`.
  It is bound only to loopback and stores disposable data below the explicit
  interoperability state directory.
- **Fixed realtime interposer:** WABT-owned source
  `scripts/oci/fixed_realtime.c`, SHA-256
  `6ff9857612af1f1ef6cdc33908026c6e804c3f65f00c204b907db3c0d5428fbe`,
  fixes only realtime clocks at `2026-09-19T00:00:00Z`; monotonic clocks
  remain real. Its generated binary hash is recorded in the fixture manifest.

These programs are fixture/test producers, not linked WABT dependencies.
Successful transport interoperability does not claim signature verification,
runtime compatibility, production readiness, or general cross-runtime
support.

The external qualification workflow runs the same
`scripts/oci/generate_interop_fixtures.sh` producer path in `qualify` mode on
Linux/arm64; there is no second schema adapter or interoperability runner. It
builds the pinned producer set, starts the pinned registry binary directly on
`127.0.0.1`, and compares every regenerated layout byte with the committed
corpus twice. The expected generic-WABT-to-wkg rejection and all
digest-preserving registry/layout copy directions are part of that producer
path. GitHub Actions state is confined below `RUNNER_TEMP`; local state must be
below `/d`. The workflow has no Azure or other external registry credential
and uploads only a bounded redacted text summary on failure.
