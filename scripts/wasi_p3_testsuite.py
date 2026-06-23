#!/usr/bin/env python3
"""WASI Preview 3 (wasm32-wasip3) behavioral testsuite parity gate for wabt.

This is the #267 Phase 4 gate. Where ``scripts/p3_conformance.py`` only checks
that wabt's hand-authored single-built-in fixtures *encode* acceptably
(``wasmtime compile``), this gate validates that wabt correctly lifts **real**
``wasm32-wasip3`` guest programs into components that actually *run* and
produce the testsuite's expected behavior. For each vendored fixture it runs:

    wabt component new   <fixture>.wasm   -> component.wasm
    wasmtime run <p3 flags> <wasi args>  component.wasm

and compares the exit code (and stdout, when the fixture spec pins one) to the
upstream testsuite expectation. Wasmtime supplies the WASI Preview 3 host
imports, so a fixture passes iff wabt's componentization is behaviorally
correct end-to-end.

Tool resolution (same convention as ``p3_conformance.py`` / the wamr P3 gate):
  * wabt     — ``--wabt`` (required; ``zig build`` passes the built binary).
  * Wasmtime — ``WASMTIME`` env var, falling back to ``wasmtime`` on ``PATH``.

Skip / fail semantics:
  * No usable Wasmtime          -> notice + skip (exit 0) unless ``--require-wasmtime``.
  * Testsuite not vendored yet  -> notice + skip (exit 0) unless ``--require-suite``.
  * Per-fixture skips live in ``tests/wasi-p3-testsuite-skip.json`` (each entry
    a rationale ending in a tracking issue), mirroring wamr's
    ``wasi-p3-testsuite-skip.json`` convention.

The upstream ``wasm32-wasip3`` fixtures are not vendored in-tree yet, so until
they are this gate skips cleanly and stays green. Run via
``zig build wasi-p3-testsuite`` (preferred) or directly:

    python3 scripts/wasi_p3_testsuite.py --wabt <path-to-wabt> --suite <suite-dir>
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Wasmtime feature flags required to *run* the full P3 surface wabt emits
# (async lift, stream/future, error-context, the async control/context
# built-ins). Kept in sync with scripts/p3_conformance.py. Verified against
# wasmtime 46.0.0.
WASMTIME_FLAGS = [
    "-W", "component-model-async",
    "-W", "component-model-async-stackful",
    "-W", "component-model-more-async-builtins",
    "-W", "component-model-error-context",
]


def run(cmd: list[str], stdin: str | None = None) -> tuple[int, str]:
    """Run a command, returning (exit_code, combined_output)."""
    proc = subprocess.run(
        cmd, input=stdin, capture_output=True, text=True
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def resolve_wasmtime() -> str | None:
    cand = os.environ.get("WASMTIME") or "wasmtime"
    return shutil.which(cand) or (cand if os.path.isfile(cand) else None)


def discover_fixtures(suite_dir: Path) -> list[tuple[str, Path, dict]]:
    """Discover `<name>.wasm` fixtures with their optional `<name>.json` spec.

    Follows the upstream wasi-testsuite layout: each test is a `.wasm` module
    with an optional sibling `.json` config carrying `args`, `dirs`, `env`,
    `stdin`, `exit_code`, and `stdout` keys. Returns (name, wasm_path, spec).
    """
    fixtures: list[tuple[str, Path, dict]] = []
    for wasm in sorted(suite_dir.glob("*.wasm")):
        spec_path = wasm.with_suffix(".json")
        spec = json.loads(spec_path.read_text()) if spec_path.is_file() else {}
        fixtures.append((wasm.stem, wasm, spec))
    return fixtures


def suite_name(suite_dir: Path) -> str:
    manifest = suite_dir / "manifest.json"
    if manifest.is_file():
        try:
            return json.loads(manifest.read_text()).get("name", suite_dir.name)
        except (json.JSONDecodeError, OSError):
            pass
    return suite_dir.name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--wabt", default="wabt", help="path to the wabt CLI binary")
    ap.add_argument(
        "--suite",
        default="tests/wasi-testsuite/tests/rust/testsuite/wasm32-wasip3",
        help="path to the vendored wasm32-wasip3 testsuite directory",
    )
    ap.add_argument("--skip", default="tests/wasi-p3-testsuite-skip.json")
    ap.add_argument(
        "--require-wasmtime", action="store_true",
        help="fail (not skip) when no usable Wasmtime is found (CI)",
    )
    ap.add_argument(
        "--require-suite", action="store_true",
        help="fail (not skip) when the testsuite is not vendored (CI)",
    )
    args = ap.parse_args()

    suite_dir = Path(args.suite)
    name = suite_name(suite_dir)

    skip: dict[str, str] = {}
    skip_path = Path(args.skip)
    if skip_path.is_file():
        data = json.loads(skip_path.read_text())
        skip = {k: v for k, v in data.get(name, {}).items() if not k.startswith("_")}

    # The upstream wasm32-wasip3 fixtures are a sizeable external dependency
    # and are not vendored in-tree yet. Until they are, skip cleanly.
    fixtures = discover_fixtures(suite_dir) if suite_dir.is_dir() else []
    if not fixtures:
        msg = (f"wasm32-wasip3 testsuite not found under '{suite_dir}'; "
               "vendor it to enable the P3 behavioral parity gate (#267 Phase 4)")
        if args.require_suite:
            print(f"::error::{msg}")
            return 1
        print(f"::notice::{msg}; skipping.")
        return 0

    wasmtime = resolve_wasmtime()
    if wasmtime is None:
        msg = ("no usable Wasmtime found (set WASMTIME or put `wasmtime` on PATH; "
               "needs P3 feature flags, e.g. wasmtime >= 46)")
        if args.require_wasmtime:
            print(f"::error::{msg}")
            return 1
        print(f"::notice::{msg}; skipping P3 testsuite parity gate.")
        return 0

    print(f"wasi-p3-testsuite: suite={name} wabt={args.wabt} wasmtime={wasmtime}")
    passed: list[str] = []
    skipped: list[str] = []
    failed: list[tuple[str, str]] = []

    for fname, wasm, spec in fixtures:
        if fname in skip:
            skipped.append(fname)
            print(f"  SKIP {fname:24s} - {skip[fname]}")
            continue
        with tempfile.TemporaryDirectory(prefix=f"wasip3-{fname}-") as td:
            comp = Path(td) / "component.wasm"
            err = None
            code, out = run([args.wabt, "component", "new", str(wasm), "-o", str(comp)])
            if code != 0:
                err = f"`wabt component new` exited {code}\n{out.strip()}"
            else:
                cmd = [wasmtime, "run", *WASMTIME_FLAGS, str(comp), *spec.get("args", [])]
                code, out = run(cmd, stdin=spec.get("stdin"))
                expected_code = spec.get("exit_code", 0)
                if code != expected_code:
                    err = f"exit {code} (expected {expected_code})\n{out.strip()}"
                elif "stdout" in spec and out != spec["stdout"]:
                    err = f"stdout mismatch\n--- expected ---\n{spec['stdout']}\n--- actual ---\n{out}"
            if err:
                failed.append((fname, err))
                print(f"  FAIL {fname}")
            else:
                passed.append(fname)
                print(f"  PASS {fname}")

    print(f"\nwasi-p3-testsuite: {len(passed)} passed, "
          f"{len(skipped)} skipped, {len(failed)} failed")
    for fname, err in failed:
        print(f"\n--- {fname} ---\n{err}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
