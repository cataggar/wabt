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
scripts/oci/generate_interop_fixtures.sh
```

The fixed producer timestamp is `2026-09-19T00:00:00Z`. External tools are
fixture producers only and are never needed by WABT at runtime or by ordinary
tests.
