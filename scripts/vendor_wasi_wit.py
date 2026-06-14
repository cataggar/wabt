#!/usr/bin/env python3
"""Vendor canonical WASI `.wit` files into the embedded `wasi-canon` tree.

The CLI `@embedFile`s these so apps never need an on-disk `wit/deps/` copy
(issue 261). This script fetches every package's `.wit` files from the
upstream git **tag** via the GitHub API (`gh`) and writes them under:

    src/component/wit/wasi-canon/<version>/<package>/<file>.wit

`deps/`, `deps.toml` and `deps.lock` are skipped — cross-package
references resolve against the other embedded packages at resolve time.

Files are written with LF line endings (as served by GitHub); `.gitattributes`
(`* text=auto`) normalizes them in git, matching the existing 0.2.6 vendor.

Usage:
    python scripts/vendor_wasi_wit.py                 # all version sets
    python scripts/vendor_wasi_wit.py --only 0.2.12   # one version dir
    python scripts/vendor_wasi_wit.py --list          # print the manifest

Requires the GitHub CLI (`gh`) to be installed and authenticated.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.parse
from dataclasses import dataclass, field

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST_ROOT = os.path.join(
    REPO_ROOT, "src", "component", "wit", "wasi-canon"
)


@dataclass
class Pkg:
    """One embedded package: `name` is the destination subdir; `dir` is the
    source directory (relative to the repo root) holding its `.wit` files."""

    name: str
    dir: str


@dataclass
class VersionSet:
    """A `wasi-canon/<version>/` directory sourced from one repo+tag."""

    version: str
    repo: str
    ref: str
    packages: list[Pkg] = field(default_factory=list)


def _core(repo: str, ref: str, version: str, root: str, wit_subdir: str,
          names: list[str]) -> VersionSet:
    """Build a WebAssembly/WASI core version set. `root` is the in-repo
    directory holding per-package dirs (`wasip2` or `proposals`); `wit_subdir`
    is "" (0.2.6 flat) or "wit" (0.2.12 / 0.3.0)."""
    pkgs = []
    for n in names:
        parts = [root, n] + ([wit_subdir] if wit_subdir else [])
        pkgs.append(Pkg(name=n, dir="/".join(parts)))
    return VersionSet(version=version, repo=repo, ref=ref, packages=pkgs)


# Core WASI repo packages present at each tag.
_CORE_P2 = ["cli", "clocks", "filesystem", "http", "io", "random", "sockets"]
_CORE_P3 = ["cli", "clocks", "filesystem", "http", "random", "sockets"]  # no io

MANIFEST: list[VersionSet] = [
    _core("WebAssembly/WASI", "v0.2.6", "0.2.6", "wasip2", "", _CORE_P2),
    _core("WebAssembly/WASI", "v0.2.12", "0.2.12", "proposals", "wit", _CORE_P2),
    _core("WebAssembly/WASI", "v0.3.0", "0.3.0", "proposals", "wit", _CORE_P3),
    # Off-by-default proposals, each in its own repo. The package's `.wit`
    # files live directly under `wit/`; the destination subdir is the bare
    # package name.
    VersionSet("0.2.0-rc.1", "WebAssembly/wasi-config", "v0.2.0-rc.1",
               [Pkg("config", "wit")]),
    VersionSet("0.2.0-draft", "WebAssembly/wasi-keyvalue", "v0.2.0-draft",
               [Pkg("keyvalue", "wit")]),
    VersionSet("0.2.0-rc-2024-10-28", "WebAssembly/wasi-nn",
               "0.2.0-rc-2024-10-28", [Pkg("nn", "wit")]),
    VersionSet("0.2.0-draft", "WebAssembly/wasi-tls", "v0.2.0-draft+6781ae2",
               [Pkg("tls", "wit")]),
]


def gh_api(path: str, raw: bool = False) -> bytes:
    cmd = ["gh", "api", path]
    if raw:
        cmd += ["-H", "Accept: application/vnd.github.raw"]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        raise SystemExit(f"gh api failed for {path!r}")
    return proc.stdout


def list_wit_files(repo: str, ref: str, directory: str) -> list[str]:
    q = urllib.parse.quote(ref, safe="")
    path = f"repos/{repo}/contents/{directory}?ref={q}"
    items = json.loads(gh_api(path).decode("utf-8"))
    return sorted(
        it["name"] for it in items
        if it.get("type") == "file" and it["name"].endswith(".wit")
    )


def fetch_file(repo: str, ref: str, directory: str, name: str) -> bytes:
    q = urllib.parse.quote(ref, safe="")
    path = f"repos/{repo}/contents/{directory}/{name}?ref={q}"
    return gh_api(path, raw=True)


def vendor(vs: VersionSet) -> int:
    count = 0
    for pkg in vs.packages:
        dst_dir = os.path.join(DEST_ROOT, vs.version, pkg.name)
        os.makedirs(dst_dir, exist_ok=True)
        names = list_wit_files(vs.repo, vs.ref, pkg.dir)
        if not names:
            sys.stderr.write(
                f"  warning: no .wit files in {vs.repo}@{vs.ref}:{pkg.dir}\n"
            )
        for name in names:
            data = fetch_file(vs.repo, vs.ref, pkg.dir, name)
            # Normalize to LF; GitHub raw already serves LF, but be defensive.
            data = data.replace(b"\r\n", b"\n")
            with open(os.path.join(dst_dir, name), "wb") as fh:
                fh.write(data)
            count += 1
            print(f"  {vs.version}/{pkg.name}/{name}")
    return count


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only", action="append", default=None,
                    help="vendor only the given version dir(s); repeatable")
    ap.add_argument("--list", action="store_true",
                    help="print the manifest and exit")
    args = ap.parse_args()

    if args.list:
        for vs in MANIFEST:
            pkgs = ", ".join(p.name for p in vs.packages)
            print(f"{vs.version:24} {vs.repo}@{vs.ref}  [{pkgs}]")
        return 0

    total = 0
    for vs in MANIFEST:
        if args.only and vs.version not in args.only:
            continue
        print(f"# {vs.version}  <- {vs.repo}@{vs.ref}")
        total += vendor(vs)
    print(f"vendored {total} .wit file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
