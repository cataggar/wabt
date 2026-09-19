# OCI artifacts

WABT provides six transport commands for validated WebAssembly artifacts:
`push`, `pull`, `copy`, `inspect`, `resolve`, and `list-tags`. They operate on
OCI Distribution registries and OCI image layouts. WABT does not execute
WebAssembly.

This is a bounded transport feature, not a production-readiness claim. It does
not provide execution, a runtime, WIT dependency resolution, signing or
signature verification, referrer discovery, deletion, tar extraction, or full
ORAS command parity. Kusto WASI POST-body work is outside this feature.

## References

Registry references have no URI scheme:

```text
AUTHORITY/REPOSITORY:TAG
AUTHORITY/REPOSITORY@sha256:64-lowercase-hex-digits
```

Examples:

```text
registry.example/team/component:v1
registry.example/team/component@sha256:0123456789abcdef...
localhost:5000/team/component:dev
[2001:db8::1]:5000/team/component:v1
```

Authorities and repository components use canonical lowercase registry
spelling. Embedded schemes, user information, query strings, and fragments are
rejected. `list-tags` is the only command that takes a selector-less registry
repository:

```text
registry.example/team/component
```

An OCI image layout is selected with the canonical `oci:` prefix:

```text
oci:PATH
oci:PATH:NAME
oci:PATH@sha256:64-lowercase-hex-digits
```

Relative, POSIX absolute, Windows drive-absolute, and UNC layout paths are
accepted when unambiguous. A layout without a selector must have one
unambiguous root. Named layout roots use OCI's
`org.opencontainers.image.ref.name` annotation. There are no `registry:`,
`artifact:`, or other aliases.

Tags are mutable pointers. Resolve a tag once and use the returned digest
reference when repeatability matters.

## Packaging profiles and interoperability

`wabt oci push` supports two profiles:

| `--format` | Shape | Intended interoperability |
| --- | --- | --- |
| `wasm-v0` (default) | oci-wasm v0 config, one `application/wasm` layer | Compatible with the pinned wkg/oci-wasm qualification |
| `oci` | OCI 1.1 manifest, `artifactType: application/wasm`, canonical empty JSON config, one `application/wasm` layer | Generic ORAS-compatible OCI artifact |

For Wasm-v0, WABT validates the payload and writes `architecture: wasm`,
`os: wasip1` for a core module or `os: wasip2` for a component,
`layerDigests`, and bounded component imports/exports metadata. `--author`
belongs only to this profile.

The generic OCI profile is ORAS-compatible and intentionally not automatically
wkg-compatible. The pinned wkg version requires the Wasm-v0 config profile and
is expected to reject WABT's generic output. WABT also accepts the documented
ORAS OCI 1.0 single-Wasm shape for reads, but does not produce OCI 1.0.

The external qualification workflow pins ORAS v1.3.4, wasm-pkg-tools revision
`5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a` (`wkg` 0.16.1), and oci-wasm
0.6.0, plus Distribution registry 3.1.1, Rust 1.97.0/rustup 1.28.2, and Zig
0.16.0. Exact archives, checksums, source revisions, compiler and producer
binary hashes, generation argv, layout descriptors, and expected outcomes are
recorded in [`src/fixtures/oci/manifest.json`](../src/fixtures/oci/manifest.json)
and summarized in [`SOURCE_PROVENANCE.md`](../SOURCE_PROVENANCE.md).

The committed Linux/arm64 layouts are `wkg-wasm-v0`, `wabt-wasm-v0`,
`oras-oci-v1.0`, `oras-oci-v1.1`, `wabt-oci-v1.1`, `copy-roundtrip`, and
`index`. The matrix requires byte-identical payloads, exact digest-preserving
copies in every registry/layout direction, complete index preservation with
extraction rejection, and the expected rejection of generic OCI output by
wkg. The workflow invokes the fixture producer itself twice in qualification
mode, uses the pinned registry binary on disposable loopback storage, and
rejects any fixture drift or partial output. It has no cloud-registry
credentials. Ordinary Linux, macOS, and Windows Zig tests remain offline with
respect to these external producers.

## Commands

Run `wabt help oci` or `wabt help oci VERB` for the installed syntax.

### Push

```console
$ wabt oci push registry.example/team/echo:v1 component.wasm \
    --format wasm-v0 \
    --author example \
    --created 2026-09-19T14:44:44Z
registry.example/team/echo@sha256:...
```

`push` accepts one registry tag and one validated core module or component. It
publishes blobs and child documents before the root tag and reports an
immutable manifest reference only after publication is confirmed. The input
payload bytes are not rewritten. `--created` makes config and manifest bytes
reproducible; without it, the current UTC second is used.

Generic ORAS-compatible publication:

```console
$ wabt oci push registry.example/team/echo:generic component.wasm \
    --format oci \
    --created 2026-09-19T14:44:44Z
```

Use `--json` to distinguish the root/manifest, config, and payload descriptors.
A manifest digest is not the payload digest.

### Resolve

```console
$ wabt oci resolve registry.example/team/echo:v1
registry.example/team/echo@sha256:...
```

`resolve` captures one exact root descriptor and returns a canonical immutable
reference. Registry follow-up reads use that captured descriptor; a moved tag
is not resolved again. Layout references resolve to
`oci:PATH@sha256:...`.

### Inspect

```console
$ wabt oci inspect registry.example/team/echo@sha256:...
```

`inspect` emits versioned JSON describing the verified root, recognized
profile, direct config/payload descriptors where applicable, and bounded graph
counts. It does not extract or execute the artifact. Indexes are inspected as
indexes; no host platform is selected.

### Pull

```console
$ wabt oci pull registry.example/team/echo@sha256:... \
    -o ./downloaded-component.wasm
```

An explicit output file is always required. WABT accepts one supported direct
Wasm manifest with exactly one raw `application/wasm` layer. Layer title
annotations never choose a filesystem path. Tar-labeled content is rejected
and never unpacked.

The payload is streamed to a private staging file, size- and digest-verified,
and atomically renamed. An existing output is refused. `--force` permits
atomic replacement of one regular file only after the new bytes verify; a
failure leaves the existing file byte-identical. Interrupted or invalid pulls
leave no partial final output.

### Copy

All four pairings use one complete bounded graph plan:

```console
$ wabt oci copy registry.example/team/echo:v1 oci:./echo-layout
$ wabt oci copy oci:./echo-layout registry.example/team/echo:copied
$ wabt oci copy oci:./echo-layout oci:./echo-layout-copy
$ wabt oci copy registry.example/team/echo:v1 \
    registry.example/other/echo:copied
```

Copy preserves exact manifest/index/config/layer bytes and therefore their
digests. It does not reserialize supported documents, select a platform, or
extract a layer. The complete supported graph is validated before destination
publication. The destination tag or layout catalog is the final visibility
change; verified unreferenced remote blobs may remain after a pre-commit
failure for registry garbage collection.

Source and destination registry endpoints are independent. Each has its own
credential policy, CA file, deadline, loopback HTTP opt-in, client, and token
cache. Copy options are correspondingly prefixed with `--source-` and
`--destination-`. If both endpoints request a standard-input secret, WABT
reads the source line first and the destination line second. Registry options
are invalid for an `oci:` side.

### List tags

```console
$ wabt oci list-tags registry.example/team/echo
```

`list-tags` emits stable versioned JSON with deduplicated lexical ordering. It
uses bounded same-origin pagination. Tags are mutable; listing is not a
snapshot of the manifests to which those tags later resolve.

## Stable JSON schemas

JSON output is one compact object plus a newline on stdout. Progress is sent to
stderr. Every object has a stable `schema` name and `schemaVersion: 1`.
Descriptor objects have exactly `mediaType`, `digest`, and `size`.

| Command | Schema | Version 1 fields |
| --- | --- | --- |
| `resolve --json` | `wabt.oci.resolve` | `originalReference`, `reference`, `rootKind`, `rootMediaType`, `rootDigest`, `rootSize`, nullable `manifestMediaType`, `manifestDigest`, `manifestSize` |
| `inspect` | `wabt.oci.inspect` | `originalReference`, `reference`, `root`, `documentKind`, nullable `artifactType`, `subject`, `manifest`, `profile`, `config`, `payload`, and `graph` (`documents`, `descriptors`, `totalSize`) |
| `list-tags` | `wabt.oci.list-tags` | `repository`, `tags` |
| `pull --json` | `wabt.oci.pull` | `originalReference`, `reference`, `root`, `manifest`, `config`, `payload`, `profile`, `output`, `size` |
| `push --json` | `wabt.oci.push` | `originalReference`, `reference`, `profile`, `created`, `createdSource`, `root`, `manifest`, `config`, `payload` |
| `copy --json` | `wabt.oci.copy` | `sourceReference`, `sourceRootReference`, `destinationReference`, `destinationRootReference`, `root`, nullable `manifest`, `config`, `payload`, and `transferred`, `reused`, `mounted` |

Consumers should select by `schema` and `schemaVersion`, tolerate JSON object
field ordering, and treat nullable fields as meaningful. `root` and
`manifest` currently have the same descriptor for a direct image manifest,
but differ conceptually from `payload`.

## Authentication, trust, and deadlines

Registry commands use HTTPS by default and system trust. `--ca-file FILE`
appends a bounded PEM CA bundle; it does not disable normal hostname or
certificate verification. There is no skip-verification option.
`--plain-http` is accepted only for `localhost`, canonical `127.0.0.0/8`, or
`::1` loopback endpoints.

Credential choices are mutually exclusive:

- default bounded Docker/containers auth-file and helper discovery;
- `--no-credential-discovery` for anonymous access;
- one explicit `--auth-file`;
- `--username USER --password-stdin`;
- `--token-stdin`.

Password- or token-valued command-line options are deliberately rejected.
Standard input supplies one nonempty line of at most 64 KiB; the newline is
removed and embedded NUL/newline data is rejected. Do not use shell tracing
while acquiring or piping a secret. See
[OCI authentication library policy](oci-authentication.md) for discovery
order, helper behavior, redirect stripping, and redaction guarantees.

`--deadline DURATION` accepts `ms`, `s`, `m`, or `h`, from 1 ms through 24
hours. The default is five minutes. Authentication, redirects, retries,
backoff, and transfer share one absolute operation budget. Zig's standard HTTP
backend cannot interrupt every DNS/connect/TLS/socket blocking phase, so the
deadline is checked around those phases; embedders needing enforceable
in-flight cancellation must supply a capable backend.

## Error classes and troubleshooting

Diagnostics are intentionally bounded and do not include credentials, bearer
tokens, helper output, response bodies, or signed URL queries.

| Diagnostic | Typical action |
| --- | --- |
| `authentication failed` | Refresh the credential, verify the auth-file/helper selection, or use the correct stdin mode. |
| `authorization denied` | Grant the identity only the required pull or push permission for the repository. |
| `content not found` | Check repository, tag/digest, and authorization that may conceal private content. |
| `source or destination content is corrupt` / `invalid or corrupt OCI content` | Do not retry blindly; compare the immutable descriptor, declared size, and received SHA-256. |
| `unsupported OCI content` | Check root/config/layer media types, layer count, subject/index use, and the selected profile. |
| `registry transport failed` / `TLS validation failed` | Check the canonical authority, HTTPS, proxy/network path, and additional CA. |
| `operation deadline exceeded` | Increase the bounded deadline only after checking registry/network health. |
| `registry upload or publication could not be confirmed` | Resolve the destination tag and immutable digest before retrying; an unreferenced upload may remain. |
| `output exists or cannot be replaced safely` | Choose a new file, or use `--force` only for an intended regular-file replacement. |
| `OCI operation limit exceeded` | Reduce graph/metadata/payload size; WABT does not silently skip excess content. |

For interoperability failures, record actual `wabt version`, ORAS/wkg version
text, binary/archive hashes, the root/config/payload digests, and the error
class. Do not record credentials or private registry output.

## Operator-run Azure Container Registry walkthrough

This procedure is manual and must never run in normal CI or the external-tool
loopback workflow. Use a disposable repository and a short-lived external
Microsoft Entra identity. For an unattended run, prefer workload identity/OIDC
federation for a service principal instead of a stored client secret. For
interactive use, authenticate Azure CLI with the operator's own identity.

Grant only the required scope:

- `AcrPull` for resolve, inspect, pull, and registry-to-layout copy;
- `AcrPush` for push and a registry destination (it also permits pull).

For an ABAC-enabled registry, use the corresponding repository-scoped ACR
reader/writer roles documented for that registry mode. Role assignment and
OIDC trust configuration are administrative prerequisites and are not shown in
the run log.

Set private values locally with shell tracing disabled. Do not paste real
tenant, subscription, client, or registry values into an issue, PR, script, or
workflow:

```bash
set -euo pipefail
set +x

: "${ACR_NAME:?set privately to the registry resource name}"
: "${REPOSITORY:?set privately to a disposable repository}"
: "${TAG:?set privately to a versioned test tag}"

LOGIN_SERVER="$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)"
TAG_REF="${LOGIN_SERVER}/${REPOSITORY}:${TAG}"
COPY_REF="${LOGIN_SERVER}/${REPOSITORY}:${TAG}-copy"
ACR_TOKEN_USER="00000000-0000-0000-0000-000000000000"
RUN_DIR="./zig-out/acr-operator"
mkdir -p "$RUN_DIR"

acr_token() {
  az acr login --name "$ACR_NAME" --expose-token \
    --query accessToken -o tsv
}
```

Microsoft documents the exposed ACR token as a roughly three-hour credential
and the all-zero GUID as its username. `acr_token` must only be used as the
left side of a pipe; never invoke it alone, print its result, store it in a
checked-in auth file, place it in argv, or run with `set -x`. In GitHub Actions,
mask the token before any possible use, but do not put this ACR procedure in
normal or external-tool CI.

If the Azure CLI session itself is federated, acquire it through the
operator's approved service-principal/OIDC integration before this procedure.
Treat the client and tenant identifiers as private and the OIDC assertion as a
secret: do not print it, put it in the run sheet, or persist it after login. Do
not substitute a long-lived service-principal secret for this walkthrough.

Record the source hash, then push. A fresh exposed token is piped directly to
each WABT command:

```bash
SOURCE="./component.wasm"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sha256sum "$SOURCE"

IMMUTABLE="$(
  acr_token |
    wabt oci push "$TAG_REF" "$SOURCE" \
      --format wasm-v0 \
      --created "$CREATED" \
      --author wabt-acr-operator \
      --username "$ACR_TOKEN_USER" \
      --password-stdin
)"
ROOT_DIGEST="${IMMUTABLE##*@}"
test "${ROOT_DIGEST#sha256:}" != "$ROOT_DIGEST"
```

Resolve the mutable tag and require the same immutable reference:

```bash
RESOLVED="$(
  acr_token |
    wabt oci resolve "$TAG_REF" \
      --username "$ACR_TOKEN_USER" \
      --password-stdin
)"
test "$RESOLVED" = "$IMMUTABLE"
```

Inspect and pull **by digest**, never by the mutable tag:

```bash
acr_token |
  wabt oci inspect "$IMMUTABLE" --json \
    --username "$ACR_TOKEN_USER" \
    --password-stdin \
    > "$RUN_DIR/inspect.json"

acr_token |
  wabt oci pull "$IMMUTABLE" \
    -o "$RUN_DIR/pulled-component.wasm" \
    --username "$ACR_TOKEN_USER" \
    --password-stdin

cmp "$SOURCE" "$RUN_DIR/pulled-component.wasm"
sha256sum "$SOURCE" "$RUN_DIR/pulled-component.wasm"
```

Exercise digest-preserving copy with independent endpoint authentication. The
first copy is ACR to a local layout; the second is the local layout to a new ACR
tag:

```bash
COPIED_ROOT="$(
  acr_token |
    wabt oci copy "$IMMUTABLE" "oci:$RUN_DIR/layout" \
      --source-username "$ACR_TOKEN_USER" \
      --source-password-stdin
)"
test "$COPIED_ROOT" = "$ROOT_DIGEST"

COPIED_ROOT="$(
  acr_token |
    wabt oci copy "oci:$RUN_DIR/layout" "$COPY_REF" \
      --destination-username "$ACR_TOKEN_USER" \
      --destination-password-stdin
)"
test "$COPIED_ROOT" = "$ROOT_DIGEST"

COPY_RESOLVED="$(
  acr_token |
    wabt oci resolve "$COPY_REF" \
      --username "$ACR_TOKEN_USER" \
      --password-stdin
)"
test "$COPY_RESOLVED" = "$IMMUTABLE"

acr_token |
  wabt oci pull "$COPY_RESOLVED" \
    -o "$RUN_DIR/copied-component.wasm" \
    --username "$ACR_TOKEN_USER" \
    --password-stdin
cmp "$SOURCE" "$RUN_DIR/copied-component.wasm"
```

Expected authorization failures are useful evidence:

- an absent, malformed, or expired token produces `authentication failed`;
- a valid pull-only identity used for push produces `authorization denied`;
- a missing private reference may be reported as `content not found`.

Do not weaken TLS or print HTTP debug headers to diagnose these cases.

Create a redacted run sheet containing only:

- UTC time;
- `wabt version` and the WABT binary SHA-256;
- `az version --query '"azure-cli"' -o tsv`;
- optional ORAS/wkg/runtime version strings and binary hashes;
- input/output SHA-256;
- manifest/root, config, and payload digests and sizes from `inspect.json`;
- pass/fail for push, both tag-to-digest resolutions, both pulls, byte
  comparisons, and both copy directions.

Before closing the implementation issue or publishing the first release with
OCI support, an operator should complete this procedure once and attach only
that sanitized version/hash/digest record to the issue or pull request.

Never attach token text, `az account show`, tenant/subscription/client IDs,
the private login server or repository listing, signed query strings, debug
HTTP headers, the complete private `inspect.json`, or other private outputs.
Remove local material after recording the sanitized fields:

```bash
rm -rf "$RUN_DIR"
unset LOGIN_SERVER TAG_REF COPY_REF IMMUTABLE RESOLVED COPY_RESOLVED ROOT_DIGEST
```

WABT has no deletion command. Remove disposable ACR tags only through the
operator's approved ACR/ORAS retention or deletion procedure, then clear the
Azure CLI session as required by local policy.

### Runtime execution is outside transport qualification

WAMR and Wasmtime execution is outside transport qualification. A downloaded
component may be run later, as a separate operator process, when its world is
supported by the selected host:

```console
$ wasmtime --version
$ wasmtime run ./pulled-component.wasm
```

Use a WAMR command only when that particular WAMR build advertises the required
component-model and WASI support. Record the runtime version and downloaded
SHA-256. Pull never executes code, and transport evidence is not runtime
qualification, general Wasmtime/WAMR compatibility, Kusto WASI POST-body
support, signature verification, or production readiness.

## Releases, notices, SBOMs, signatures, and attestations

Source packages contain `docs/`, `LICENSE`, `LICENSES/`,
`THIRD_PARTY_NOTICES.md`, and `SOURCE_PROVENANCE.md`. Binary archives and
wheels carry the user/authentication guides and the same license/provenance
notices. Release SBOMs describe shipped binaries; ORAS, wkg, oci-wasm, and the
disposable registry remain external qualification producers rather than
linked runtime dependencies.

Release archives have minisign sidecars and build-provenance attestations.
Those release mechanisms are separate from OCI transport. WABT transport does
not verify signatures or attestations, discover referrers, or infer trust from
a successful digest-preserving copy.
