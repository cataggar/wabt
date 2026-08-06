# Security Policy

## Scope

This repository is an independent **rewrite** of the WebAssembly Binary
Toolkit in Zig, maintained by volunteers with AI assistance. It shares a
name, a CLI heritage, and a test suite with
[WebAssembly/wabt](https://github.com/WebAssembly/wabt), but it shares no
code with it.

That distinction matters for reporting:

- Vulnerabilities in **this** codebase should be reported here, using the
  process below. Upstream cannot fix code it does not have.
- Vulnerabilities in **upstream's C++ implementation** should go to
  [WebAssembly/wabt](https://github.com/WebAssembly/wabt), not here.
- Advisories do not transfer between the two projects in either
  direction. A CVE against upstream's C++ code (for example,
  CVE-2025-2584) does not apply to this rewrite, and a CVE against this
  rewrite does not apply to upstream. Each implementation needs its own
  advisory.

## Reporting a vulnerability

**Please do not open a public issue for a security report.**

Report privately through GitHub's private vulnerability reporting:

**<https://github.com/cataggar/wabt/security/advisories/new>**

This creates a private advisory draft visible only to you and the
maintainers. If you prefer, you can request a private fork from that
draft to develop and review a fix before anything becomes public.

Reports are handled by volunteers on a reasonable-effort basis. We do not
promise a response deadline, but we do read every report and will keep
you informed of what we decide to do with yours.

## What to include

- A description of the vulnerability and its impact
- How to reproduce it, including the input module — a `.wasm`, `.wat`, or
  `.wast` file, or the steps to generate one
- Which `wabt` subcommand is affected (for example `wabt spec run`,
  `wabt module validate`, `wabt component new`)
- The commit SHA or release tag you observed it on
- The build you tested: `zig version` and the `-Doptimize` mode, or the
  release artifact name if you used a published binary
- Your platform and architecture

If you could not build or run the project and your findings are
source-only, that is fine and still useful. Please say so, and say which
claims you verified yourself and which you inferred, so we can prioritise
the right things first.

## Threat model

The `wabt` tools are expected to be run on **untrusted input**. Someone
who can hand you a crafted module should not be able to do anything worse
than make the tool exit with an error. The following are in scope:

- Crashes, panics, assertion failures, or unbounded memory growth
  triggered by a crafted module
- Non-termination, or time and memory use grossly disproportionate to the
  size of the input
- Reads or writes outside the bounds of a buffer, and any other
  memory-safety failure
- **Validator gaps** — a module that should be rejected by validation but
  is accepted, and then reaches the interpreter or a code generator that
  assumed validation had already ruled it out. The validator is a trust
  boundary for everything downstream of it, so a missing check there is a
  security issue even when the immediately observable symptom is mild.
- Incorrect output that would let a module smuggle behaviour past a tool
  used as a filter or verifier

## Build modes and safety guarantees

This matters for judging the severity of a memory-safety report, so it is
stated here rather than left to be inferred.

Published release binaries are built with `-Doptimize=ReleaseSafe`,
`-Dstack-protector=true`, from `.github/workflows/release.yml`. Zig keeps
bounds checks, overflow checks, and other safety checks enabled in
`ReleaseSafe`, so a memory-safety failure in a published binary is a
trapped panic. In practice that means the realistic impact of most such
bugs, **as shipped**, is denial of service rather than memory corruption.

`ReleaseFast` and `ReleaseSmall` elide those checks. A bug that panics in
a published binary may be an exploitable out-of-bounds access when built
in one of those modes. We do not publish `ReleaseFast` artifacts, and
`ReleaseFast` is outside the configuration this policy covers — but we
would still like to hear about the bug, and we will still fix it. Please
do not downgrade a report on the assumption that a safety check catches
it; tell us what you found and let us work out the shipped impact.

`Debug` and `ReleaseSafe` are the supported configurations for running
these tools on untrusted input.

## Supported versions

Only the most recent release and the current `main` branch receive
security fixes. This project is pre-1.0 and publishes `3.0.0-dev.*`
releases; there are no maintenance branches and no backports to earlier
tags. Fixes ship in the next release from `main`.

## Advisories and credit

Confirmed vulnerabilities are published as GitHub Security Advisories on
this repository, which lists them in the public
[GitHub Advisory Database](https://github.com/advisories). We request a
CVE identifier through GitHub where the issue warrants one.

Reporters are credited in the advisory by name and GitHub handle. If you
would rather not be credited, or want to be credited differently, say so
in your report and we will follow your preference.
