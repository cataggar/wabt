#!/usr/bin/env python3
"""WASI Preview 3 (component-model-async) conformance gate for wabt.

wabt is a *toolkit*: it produces components, it does not run them. So this
gate validates that the components wabt produces from P3 guest fixtures are
accepted by upstream Wasmtime. For each `tests/p3/<name>.wat` fixture it runs:

    wabt text parse   <name>.wat        -> core.wasm
    wabt component embed -w <world> world.wit core.wasm -> embed.wasm
    wabt component new  embed.wasm      -> component.wasm
    wasmtime compile  <p3 flags> component.wasm

A fixture passes when every step exits 0 (i.e. Wasmtime accepts the encoding).

The Wasmtime binary is resolved from the ``WASMTIME`` environment variable,
falling back to ``wasmtime`` on ``PATH`` (same convention as the wamr P3
parity gate). When no usable Wasmtime is found the gate prints a notice and
exits 0 (skipped) unless ``--require-wasmtime`` is passed (set by CI).

Skip-list entries (``tests/p3-conformance-skip.json``) must each carry a
rationale + tracking issue, mirroring wamr's ``wasi-p3-testsuite-skip.json``.

Run via ``zig build p3-conformance`` (preferred) or directly:

    python3 scripts/p3_conformance.py --wabt <path-to-wabt> --fixtures tests/p3
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

# Wasmtime feature flags required to validate the full P3 built-in surface
# that wabt emits (async lift, stream/future, error-context, the async
# control/context built-ins). Verified against wasmtime 46.0.0.
WASMTIME_FLAGS = [
    "-W", "component-model-async",
    "-W", "component-model-async-stackful",
    "-W", "component-model-more-async-builtins",
    "-W", "component-model-error-context",
]

# The shared world exported by every fixture (see tests/p3/world.wit).
WORLD = "hello"


def run(cmd: list[str]) -> tuple[int, str]:
    """Run a command, returning (exit_code, combined_output)."""
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def resolve_wasmtime() -> str | None:
    cand = os.environ.get("WASMTIME") or "wasmtime"
    found = shutil.which(cand) or (cand if os.path.isfile(cand) else None)
    if not found:
        return None
    code, _ = run([found, "--version"])
    return found if code == 0 else None


def main() -> int:
    ap = argparse.ArgumentParser(description="wabt WASI Preview 3 conformance gate")
    ap.add_argument("--wabt", default="wabt", help="path to the wabt CLI binary")
    ap.add_argument("--fixtures", default="tests/p3", help="directory of <name>.wat fixtures")
    ap.add_argument("--skip", default="tests/p3-conformance-skip.json", help="skip-list JSON")
    ap.add_argument("--require-wasmtime", action="store_true",
                    help="fail (not skip) when no usable Wasmtime is found (CI)")
    args = ap.parse_args()

    fixtures_dir = Path(args.fixtures)
    world_wit = fixtures_dir / "world.wit"
    if not world_wit.is_file():
        print(f"error: shared world WIT not found: {world_wit}", file=sys.stderr)
        return 2

    skip: dict[str, str] = {}
    skip_path = Path(args.skip)
    if skip_path.is_file():
        data = json.loads(skip_path.read_text())
        skip = {k: v for k, v in data.items() if not k.startswith("_")}

    wasmtime = resolve_wasmtime()
    if wasmtime is None:
        msg = ("no usable Wasmtime found (set WASMTIME or put `wasmtime` on PATH; "
               "needs P3 feature flags, e.g. wasmtime >= 46)")
        if args.require_wasmtime:
            print(f"error: {msg}", file=sys.stderr)
            return 2
        print(f"notice: p3-conformance skipped - {msg}")
        return 0

    fixtures = sorted(fixtures_dir.glob("*.wat"))
    if not fixtures:
        print(f"error: no .wat fixtures under {fixtures_dir}", file=sys.stderr)
        return 2

    passed: list[str] = []
    skipped: list[str] = []
    failed: list[tuple[str, str]] = []

    print(f"p3-conformance: wabt={args.wabt} wasmtime={wasmtime}")
    for wat in fixtures:
        name = wat.stem
        if name in skip:
            skipped.append(name)
            print(f"  SKIP {name:20s} - {skip[name]}")
            continue
        with tempfile.TemporaryDirectory(prefix=f"p3-{name}-") as td:
            tmp = Path(td)
            core = tmp / "core.wasm"
            embed = tmp / "embed.wasm"
            comp = tmp / "component.wasm"
            cwasm = tmp / "component.cwasm"
            steps = [
                [args.wabt, "text", "parse", str(wat), "-o", str(core)],
                [args.wabt, "component", "embed", "-w", WORLD, str(world_wit), str(core), "-o", str(embed)],
                [args.wabt, "component", "new", str(embed), "-o", str(comp)],
                [wasmtime, "compile", *WASMTIME_FLAGS, str(comp), "-o", str(cwasm)],
            ]
            err = None
            for cmd in steps:
                code, out = run(cmd)
                if code != 0:
                    err = f"`{' '.join(Path(c).name if i == 0 else c for i, c in enumerate(cmd))}` exited {code}\n{out.strip()}"
                    break
            if err:
                failed.append((name, err))
                print(f"  FAIL {name}")
            else:
                passed.append(name)
                print(f"  PASS {name}")

    print(f"\np3-conformance: {len(passed)} passed, {len(skipped)} skipped, {len(failed)} failed")
    for name, err in failed:
        print(f"\n--- {name} ---\n{err}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
