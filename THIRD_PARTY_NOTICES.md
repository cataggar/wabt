# Third-Party Notices

## miz

The OCI foundation is being adapted from
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
