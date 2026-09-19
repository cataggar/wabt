# Third-Party Notices

## miz

The OCI foundation is adapted from
[cataggar/miz](https://github.com/cataggar/miz) at commit
[`669a27982b376311f558e820b69e9a692735b0cd`](https://github.com/cataggar/miz/commit/669a27982b376311f558e820b69e9a692735b0cd).
The upstream source files are:

- `packages/miz/src/oci/content.zig`
- `packages/miz/src/oci/reference.zig`
- `packages/miz/src/oci/model.zig`
- `packages/miz/src/oci/transport.zig`
- `packages/miz/src/oci/layout.zig`
- `packages/miz/src/oci/copy.zig`

The corresponding WABT destinations are under `src/oci/`, with the detailed
source-to-destination mapping recorded in
[`SOURCE_PROVENANCE.md`](SOURCE_PROVENANCE.md).

The WABT adaptation excludes miz's disk-image, filesystem, archive, QEMU,
authentication, registry, signing, and related subsystems. It also replaces
miz's reference spelling, separates artifact-capable validation from strict
container-image validation, centralizes bounded graph planning, and rejects
subject-bearing or unsupported graph nodes.

miz is licensed under the MIT License. The complete license text from the
pinned revision is reproduced in [`LICENSES/miz-MIT.txt`](LICENSES/miz-MIT.txt).

## OCI fixture producers

The regeneration script downloads or builds these pinned public tools only to
produce interoperability test data:

- ORAS CLI v1.3.4, Apache License 2.0
- wasm-pkg-tools `wkg` revision
  `5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a`, Apache License 2.0 with LLVM
  exception
- oci-wasm v0.6.0, Apache License 2.0 with LLVM exception
- Distribution registry v3.1.1, Apache License 2.0
- Rust 1.97.0/rustup 1.28.2, used only as the pinned wkg build toolchain

Their binaries and source trees are not redistributed, linked into WABT, or
required by normal builds, tests, packages, or runtime use. Exact source and
release URLs, checksums, versions, commands, and generated hashes are recorded
in [`SOURCE_PROVENANCE.md`](SOURCE_PROVENANCE.md) and
[`src/fixtures/oci/manifest.json`](src/fixtures/oci/manifest.json). These
notices describe the fixture production boundary and do not apply third-party
licenses to WABT as a whole.
