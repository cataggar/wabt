#!/usr/bin/env python3
"""Compare live spectest results against test/spec-baseline.tsv.

Fails (exit code 1) on any drift:
    - fewer passes than baseline,
    - more failures than baseline,
    - more skips than baseline,
    - a baseline file is missing from the testsuite,
    - a testsuite .wast file is missing from the baseline.

Pass --update to overwrite the baseline file with current results
instead of checking.

Usage:
    zig build -Doptimize=ReleaseSafe
    python3 scripts/check_spec_baseline.py
    python3 scripts/check_spec_baseline.py --update
    python3 scripts/check_spec_baseline.py --wabt zig-out/bin/wabt \
        --suite third_party/testsuite \
        --baseline test/spec-baseline.tsv
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WABT = REPO_ROOT / "zig-out" / "bin" / "wabt"
DEFAULT_SUITE = REPO_ROOT / "third_party" / "testsuite"
DEFAULT_BASELINE = REPO_ROOT / "test" / "spec-baseline.tsv"

SUMMARY_RE = re.compile(r"(\d+) passed, (\d+) failed, (\d+) skipped")


class Counts:
    """Either (passed, failed, skipped) ints or an `error` sentinel.

    Files where wabt fails to produce a `<n> passed, <n> failed, <n> skipped`
    line (e.g. it panics or aborts) are recorded as `error=True`. The check
    treats those as "current behaviour; do not regress further", and treats a
    transition from error -> proper summary as an improvement.
    """

    __slots__ = ("passed", "failed", "skipped", "error")

    def __init__(self, passed: int = 0, failed: int = 0, skipped: int = 0,
                 error: bool = False) -> None:
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.error = error

    @classmethod
    def err(cls) -> "Counts":
        return cls(error=True)

    def fmt(self) -> str:
        if self.error:
            return "ERROR\tERROR\tERROR"
        return f"{self.passed}\t{self.failed}\t{self.skipped}"

    def desc(self) -> str:
        if self.error:
            return "no summary (panic/abort)"
        return f"{self.passed}p/{self.failed}f/{self.skipped}s"


def run_one(wabt: Path, wast: Path) -> Counts:
    """Run `wabt spec run <wast>` and return parsed counts, or Counts.err()."""
    proc = subprocess.run(
        [str(wabt), "spec", "run", str(wast)],
        capture_output=True,
        text=True,
        check=False,
    )
    last = None
    for line in (proc.stdout + proc.stderr).splitlines():
        m = SUMMARY_RE.search(line)
        if m:
            last = m
    if last is None:
        return Counts.err()
    return Counts(int(last.group(1)), int(last.group(2)), int(last.group(3)))


def load_baseline(path: Path) -> dict[str, Counts]:
    baseline: dict[str, Counts] = {}
    with path.open() as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 4:
                sys.exit(f"baseline {path}: malformed line: {line!r}")
            name, p, f, s = parts
            if p == "ERROR" and f == "ERROR" and s == "ERROR":
                baseline[name] = Counts.err()
                continue
            try:
                baseline[name] = Counts(int(p), int(f), int(s))
            except ValueError:
                sys.exit(f"baseline {path}: non-integer counts in: {line!r}")
    return baseline


def write_baseline(path: Path, results: dict[str, Counts]) -> None:
    header = (
        "# Spec-test baseline. Each line lists the expected pass/fail/skip\n"
        "# counts for one .wast file under third_party/testsuite/. CI compares\n"
        "# the live spectest output against this file and fails on any drift\n"
        "# (fewer passes, more fails, or more skips). Regenerate via:\n"
        "#\n"
        "#   zig build -Doptimize=ReleaseSafe\n"
        "#   python3 scripts/check_spec_baseline.py --update\n"
        "#\n"
        "# Columns: file<TAB>passed<TAB>failed<TAB>skipped\n"
    )
    with path.open("w") as fh:
        fh.write(header)
        for name in sorted(results):
            fh.write(f"{name}\t{results[name].fmt()}\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--wabt", type=Path, default=DEFAULT_WABT,
                   help=f"Path to wabt binary (default: {DEFAULT_WABT.relative_to(REPO_ROOT)})")
    p.add_argument("--suite", type=Path, default=DEFAULT_SUITE,
                   help=f"Path to testsuite directory (default: {DEFAULT_SUITE.relative_to(REPO_ROOT)})")
    p.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE,
                   help=f"Path to baseline TSV (default: {DEFAULT_BASELINE.relative_to(REPO_ROOT)})")
    p.add_argument("--update", action="store_true",
                   help="Overwrite the baseline with current results instead of checking.")
    p.add_argument("--jobs", "-j", type=int, default=os.cpu_count() or 1,
                   help="Parallelism (default: ncpu)")
    args = p.parse_args()

    if not args.wabt.is_file():
        # On Windows the binary is wabt.exe; try that automatically.
        with_exe = args.wabt.with_suffix(".exe")
        if with_exe.is_file():
            args.wabt = with_exe
        else:
            sys.exit(f"wabt binary not found: {args.wabt}\nRun `zig build -Doptimize=ReleaseSafe` first.")
    if not args.suite.is_dir():
        sys.exit(f"testsuite directory not found: {args.suite}")

    wast_files = sorted(args.suite.glob("*.wast"))
    if not wast_files:
        sys.exit(f"no .wast files under {args.suite}")

    results: dict[str, Counts] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        future_map = {ex.submit(run_one, args.wabt, w): w for w in wast_files}
        for fut in concurrent.futures.as_completed(future_map):
            wast = future_map[fut]
            results[wast.name] = fut.result()

    total_pass = sum(c.passed for c in results.values() if not c.error)
    total_fail = sum(c.failed for c in results.values() if not c.error)
    total_skip = sum(c.skipped for c in results.values() if not c.error)
    n_err = sum(1 for c in results.values() if c.error)
    print(f"Live: {total_pass} passed, {total_fail} failed, {total_skip} skipped, "
          f"{n_err} no-summary across {len(results)} files")

    if args.update:
        write_baseline(args.baseline, results)
        print(f"Wrote {args.baseline}")
        return 0

    if not args.baseline.is_file():
        sys.exit(f"baseline not found: {args.baseline}\n"
                 f"Generate it with: python3 scripts/check_spec_baseline.py --update")
    baseline = load_baseline(args.baseline)

    base_total_pass = sum(c.passed for c in baseline.values() if not c.error)
    base_total_fail = sum(c.failed for c in baseline.values() if not c.error)
    base_total_skip = sum(c.skipped for c in baseline.values() if not c.error)
    base_n_err = sum(1 for c in baseline.values() if c.error)
    print(f"Base: {base_total_pass} passed, {base_total_fail} failed, "
          f"{base_total_skip} skipped, {base_n_err} no-summary "
          f"across {len(baseline)} files")

    drift: list[str] = []
    live_files = set(results)
    base_files = set(baseline)
    for missing in sorted(base_files - live_files):
        drift.append(f"  {missing}: in baseline but missing from suite")
    for extra in sorted(live_files - base_files):
        drift.append(f"  {extra}: new file (live={results[extra].desc()}) — "
                     f"add to baseline with --update")
    for name in sorted(live_files & base_files):
        live = results[name]
        base = baseline[name]
        problems = []
        if base.error:
            # Tolerate continued no-summary; flag improvements in the
            # "improved" section below.
            continue
        if live.error:
            problems.append("regressed to no-summary (panic/abort)")
        else:
            if live.passed < base.passed:
                problems.append(f"passed {base.passed} -> {live.passed}")
            if live.failed > base.failed:
                problems.append(f"failed {base.failed} -> {live.failed}")
            if live.skipped > base.skipped:
                problems.append(f"skipped {base.skipped} -> {live.skipped}")
        if problems:
            drift.append(f"  {name}: " + ", ".join(problems))

    if drift:
        print(f"::error::Spec-test baseline drift detected ({len(drift)} files):")
        for line in drift:
            print(line)
        print("Re-run with --update if the change is intentional.")
        return 1

    improved: list[str] = []
    for name in sorted(live_files & base_files):
        live = results[name]
        base = baseline[name]
        if base.error and not live.error:
            improved.append(name)
        elif not base.error and not live.error and (
            live.passed > base.passed
            or live.failed < base.failed
            or live.skipped < base.skipped
        ):
            improved.append(name)
    if improved:
        print(f"note: {len(improved)} file(s) improved over the baseline. "
              f"Lock in with --update.")
        for name in improved[:10]:
            print(f"  {name}: base={baseline[name].desc()} -> "
                  f"live={results[name].desc()}")
        if len(improved) > 10:
            print(f"  ... and {len(improved) - 10} more")

    print("OK: spec-test results match baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
