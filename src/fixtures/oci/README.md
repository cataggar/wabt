# OCI interoperability fixtures

These committed OCI layouts are untrusted test data. They prove only the
transport/profile assertions recorded in `manifest.json`; they are not signed
packages, runtime compatibility evidence, or a production-readiness claim.

Offline verification:

```sh
scripts/oci/verify_interop_fixtures.sh
```

Pinned Linux/arm64 regeneration (network and a loopback-only disposable
registry are required):

```sh
WABT_OCI_INTEROP_STATE_DIR=/d/wabt-worktrees/.cache/wabt-oci-interop \
  scripts/oci/generate_interop_fixtures.sh
```

To execute the same live matrix without replacing producer metadata:

```sh
WABT_OCI_INTEROP_MODE=qualify \
  WABT_OCI_INTEROP_STATE_DIR=/d/wabt-worktrees/.cache/wabt-oci-interop \
  scripts/oci/generate_interop_fixtures.sh
```

The fixed producer timestamp is `2026-09-19T00:00:00Z`. External tools are
fixture producers only and are never needed by WABT at runtime or by ordinary
tests.
