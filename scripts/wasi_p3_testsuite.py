#!/usr/bin/env python3
"""WASI Preview 3 (wasm32-wasip3) component decode gate for wabt.

This is the #267 Phase 4 gate. Where ``scripts/p3_conformance.py`` checks that
the components wabt *produces* from hand-authored single-built-in fixtures are
accepted by Wasmtime (``wasmtime compile``), this gate runs in the other
direction: it feeds wabt the **real-world** ``wasm32-wasip3`` components from
the upstream WASI testsuite and requires wabt's component loader to decode
every one of them.

The upstream testsuite ships *already-componentized* ``wasm32-wasip3`` binaries
(component-model layer-1 modules, magic ``\\0asm\\x0d\\x00\\x01\\x00``), so the
core->component path (``wabt component new``) does not apply. wabt is a toolkit,
not a runtime, so the meaningful analog of the wamr project's wasip3 runtime
gate is *decode/loader parity*: for each fixture run

    wabt component objdump <fixture>.wasm

and require exit 0 -- i.e. wabt's ``src/component/loader.zig`` fully parses every
real P3 component (nested components, async canon built-ins, stream/future,
error-context, ...) that upstream produces.

Per-fixture skips live in ``tests/wasi-p3-testsuite-skip.json`` (each entry a
rationale ending in a tracking issue), keyed by the suite ``name`` from the
testsuite ``manifest.json``, mirroring wamr's ``wasi-p3-testsuite-skip.json``
convention. When the suite is not vendored the gate skips cleanly (exit 0)
unless ``--require-suite`` is passed (set by CI once the submodule is wired).

Run via ``zig build wasi-p3-testsuite`` (preferred) or directly:

    python3 scripts/wasi_p3_testsuite.py --wabt <path-to-wabt> --suite <suite-dir>
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str]) -> tuple[int, str]:
    """Run a command, returning (exit_code, combined_output)."""
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


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

    fixtures = sorted(suite_dir.glob("*.wasm")) if suite_dir.is_dir() else []
    if not fixtures:
        msg = (f"wasm32-wasip3 testsuite not found under '{suite_dir}'; "
               "init the `tests/wasi-testsuite` submodule to enable the P3 "
               "component decode gate (#267 Phase 4)")
        if args.require_suite:
            print(f"::error::{msg}")
            return 1
        print(f"::notice::{msg}; skipping.")
        return 0

    print(f"wasi-p3-testsuite: suite={name} wabt={args.wabt} ({len(fixtures)} fixtures)")
    passed: list[str] = []
    skipped: list[str] = []
    failed: list[tuple[str, str]] = []

    for wasm in fixtures:
        fname = wasm.stem
        if fname in skip:
            skipped.append(fname)
            print(f"  SKIP {fname:28s} - {skip[fname]}")
            continue
        code, out = run([args.wabt, "component", "objdump", str(wasm)])
        if code != 0:
            failed.append((fname, f"`wabt component objdump` exited {code}\n{out.strip()}"))
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
