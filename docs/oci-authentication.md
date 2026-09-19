# OCI authentication library policy

WABT's OCI authentication module is a pure library policy layer. Importing or
testing `wabt.oci.auth` does not inspect the environment, read files, spawn
credential helpers, access a registry, or acquire a token. Callers must invoke
credential resolution and provide its environment, filesystem, process, clock,
and token-acquisition boundaries explicitly.

## Registry HTTP endpoint policy

`wabt.oci.registry_http` implements the endpoint and HTTP policy used by later
registry operations; it does not expose registry commands or manifest, tag,
blob, upload, or profile APIs.

Endpoints take a scheme-less authority. HTTPS is the default and the production
backend retains Zig's hostname verification and system trust loading. An
explicit additional PEM CA file or PEM buffer is bounded and appended after a
system-bundle rescan. Missing, empty, malformed, or certificate-less CA input
fails explicitly. There is no insecure or skip-verification option.

Plain HTTP requires an explicit `plain_http` option and is accepted only for
`localhost`, canonical IPv4 literals in `127.0.0.0/8`, or the IPv6 loopback
literal `::1`, with an optional port. Userinfo, embedded schemes, fragments,
non-canonical/disguised numeric addresses, percent-encoded hosts, and every
non-loopback cleartext endpoint are rejected before a request.

Registry and token request redirects remain same-origin. Blob redirects may
cross origin only to HTTPS, or to another loopback HTTP origin when cleartext
development mode was explicitly enabled. HTTPS downgrade is always rejected.
On the first origin change, Authorization, cookies, and caller-marked secret
headers are removed and cannot be reacquired later in the chain. Caller
overrides for Host, framing, content encoding, connection, Authorization, and
proxy-authorization headers are rejected. Redirect locations, headers, bodies,
attempts, and backoff are bounded; only replay-safe GET and HEAD operations are
redirected or retried. Both delta-seconds and IMF-fixdate `Retry-After` values
are capped.

Every call receives one absolute deadline. Backend calls, authentication,
redirects, retries, and sleeps consume that same budget, with per-attempt and
body-idle values clamped to what remains. Zig 0.16's `std.http.Client` does not
provide interruptible DNS, connect, TLS-handshake, write, response-head, or
body-idle socket timeouts through this API. The production backend therefore
reports those capabilities as unsupported and can check the absolute deadline
only immediately before and after a blocking standard-library request. Callers
that require enforceable in-flight cancellation must inject a backend that
implements and reports those timeout capabilities.

Constructing an HTTP client copies only explicit endpoint, CA, and
authorization inputs. It performs no environment, credential-file, helper, or
other ambient credential discovery.

## Registry source behavior

`wabt.oci.registry.Source` is bound to one normalized registry authority and
repository. Construction applies the explicit `CredentialPolicy` once and
owns an independent HTTP client, authorization value, bearer-token cache, and
redacted diagnostic slot. The injected initialization path validates endpoint
transport policy before reading an authentication file or invoking a helper.
There is no fallback to ambient credentials beyond the selected policy.

`resolve` performs one GET of the selected tag or digest with the OCI and
Docker schema-2 manifest/index Accept set. It hashes the exact response bytes,
checks a requested digest, corroborates any single
`Docker-Content-Digest`, validates the response media type and artifact-capable
document, and returns an owned immutable descriptor/reference plus the exact
bytes. `inspect(reference)` calls `resolve` once; `inspectResolved` reuses
those root bytes. Child manifest and blob requests are digest-addressed and do
not revisit the mutable tag.

Recognized manifest metadata uses the manifest endpoint, and
`readManifestMetadata` forces that endpoint for index children whose extension
media type is not otherwise recognized. Other metadata uses the blob endpoint.
`copyVerifiedTo` always streams an opaque descriptor from the blob endpoint
through a fixed 64 KiB buffer into a caller-owned file while counting and
hashing. A present `Content-Length` must agree, but chunked responses are
accepted when the verified byte count and digest match.
Retries truncate and restart the destination from byte zero; every final
failure attempts to truncate it again. No blob-sized allocation or hidden
temporary file is used.

Tag listing accepts only a selector-free reference for the bound repository.
Each JSON page must contain the exact repository name and either an array of
valid tags or `null`. Duplicate JSON fields, malformed or ambiguous Link
values, multiple `rel=next` links, cross-origin links, fragments, userinfo,
downgrades, cycles, and configured page/tag/byte limit exhaustion are
rejected. Results are deduplicated and returned in lexical order. Every page
uses the source's authorization policy and the same absolute operation
deadline supplied to the source.

Successful registry and token responses must be identity encoded. Manifest
media types, descriptor sizes and SHA-256 digests, and any digest or length
corroboration headers are checked before content is accepted. Stable errors
distinguish authentication, authorization, missing content, invalid content,
transport/TLS/deadline/retry failures, and explicit policy or limit failures.
Diagnostics retain only bounded operation/category/status/code,
authority/repository, and expected-digest context; response detail, bodies,
credentials, tokens, helper output, and full URLs or queries are never
retained.

These APIs implement library reads only. They do not provide uploads,
destinations, registry commands, command-line secret handling, or live/cloud
test behavior.

## Credential policies

`CredentialPolicy` has four mutually exclusive modes:

- `none`: remain anonymous. No environment, file, or helper boundary is used.
- `supplied`: copy only the caller-owned Basic credential or bearer token into
  wipe-on-free storage. No discovery occurs.
- `auth_file`: read only the named Docker or containers authentication file.
  A missing file, missing matching record, malformed record, unsupported
  credential type, or configured helper failure is final.
- `discover`: search the documented ambient locations below.

Explicit credentials and explicit authentication files never fall back to
unrelated ambient sources.

The library accepts secrets as caller-owned memory, not as command-line
arguments. Any future command-line integration must use a non-interactive
secret channel such as standard input; password- or token-valued arguments are
outside this API contract.

Owned credentials, authorization values, decoded authentication data, helper
output, and cached tokens are wiped before release where the standard-library
ownership boundary permits it. Their formatting is redacted, and typed errors
do not contain usernames, passwords, tokens, helper output, or helper stderr.

## Ambient discovery

`discover` checks these locations in order:

1. `REGISTRY_AUTH_FILE`, when set. It is authoritative and failure does not
   continue elsewhere.
2. `$XDG_RUNTIME_DIR/containers/auth.json`.
3. `$XDG_CONFIG_HOME/containers/auth.json`, or
   `$HOME/.config/containers/auth.json`.
4. `$DOCKER_CONFIG/config.json`, or `$HOME/.docker/config.json`.
5. `$HOME/.dockercfg`.

`USERPROFILE` is the testable Windows home fallback when `HOME` is absent.
Missing ambient files and files without a matching registry may continue;
malformed files, matching unsupported records, and helper failures stop.
Callers choose the path flavor, so tests never need a real home directory.

Matching normalizes authority case while preserving explicit ports. Repository
paths use the most-specific segment-boundary match. Docker Hub's documented
aliases are equivalent, with an exact normalized authority preferred.

Supported inline records are strict canonical base64 `auth` values containing
`username:secret`. Matching `username`/`password`, `identitytoken`,
`registrytoken`, partial, empty, mixed, or otherwise unsupported credential
records fail as `UnsupportedCredentialType`; they are not treated as anonymous
credentials.

## Credential helpers

A matching `credHelpers` entry takes precedence over inline authentication;
`credsStore` applies globally. Helpers are invoked only during an explicitly
requested file/discovery resolution:

```text
docker-credential-<validated-name> get
```

The registry lookup key is sent on standard input with a newline. Registry
values and secrets are never placed in arguments. WABT never invokes `store`,
`erase`, or `list`.

Helper names, input, stdout, stderr, and duration are bounded. The process
boundary must kill and reap timed-out helpers. Captured stderr is wiped and is
never returned in diagnostics. Malformed output, the helper `<token>` identity
form, nonzero exit, timeout, and output-limit failures are final and do not
fall back to inline credentials. Registry source construction also clamps each
helper invocation to the remaining absolute source deadline.

## Challenges and tokens

Repeated `WWW-Authenticate` fields are parsed with cumulative header,
challenge, parameter-count, name, and value limits. Scheme and parameter names
are case-insensitive; quoted commas and escapes are retained correctly.
Duplicate singleton parameters are rejected. Repeated Bearer scopes are
deduplicated and sorted.

Bearer is preferred when offered. A malformed, realm-less, or inconsistent
Bearer challenge fails instead of silently downgrading to Basic.

Token acquisition and time are injected. The module performs no HTTP. Cache
keys include the registry origin, authentication context, credential
generation, realm, service, and complete canonical scope set. Entries use a
10-second expiry skew, a 60-second default lifetime, a 24-hour cap, bounded
oldest-entry eviction, and wipe-on-expiry/removal. Separate source and
destination contexts therefore cannot share pull/push credentials or tokens.
