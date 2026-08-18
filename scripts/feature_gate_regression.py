#!/usr/bin/env python3
"""Differentially check function-body feature gates with wasm-tools 1.250.0."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORK_DIR = ROOT / "zig-out/feature-gate-matrix"
EXPECTED_WASM_TOOLS_VERSION = "wasm-tools 1.250.0"


@dataclass(frozen=True)
class Case:
    family: str
    feature: str
    wat: str
    wabt_mode: str = "default"


CASES = (
    Case("exceptions", "exceptions", "(module (tag $e) (func throw $e))"),
    Case(
        "tail-call",
        "tail-call",
        "(module (func $callee) (func return_call $callee))",
    ),
    Case(
        "function-references",
        "function-references",
        "(module (func (result (ref func)) ref.null func ref.as_non_null))",
    ),
    Case(
        "sign-extension",
        "sign-extension",
        "(module (func i32.const 0 i32.extend8_s drop))",
    ),
    Case(
        "saturating-float-to-int",
        "saturating-float-to-int",
        "(module (func f32.const 0 i32.trunc_sat_f32_s drop))",
    ),
    Case(
        "bulk-memory",
        "bulk-memory",
        "(module (memory 1) "
        "(func i32.const 0 i32.const 0 i32.const 0 memory.copy))",
    ),
    Case(
        "reference-types",
        "reference-types",
        "(module (table 1 funcref) "
        "(func i32.const 0 table.get 0 drop))",
    ),
    Case(
        "typed-select",
        "reference-types",
        "(module (func i32.const 1 i32.const 2 i32.const 0 "
        "select (result i32) drop))",
    ),
    Case("gc", "gc", "(module (func i32.const 0 ref.i31 drop))"),
    Case(
        "wide-arithmetic",
        "wide-arithmetic",
        "(module (func (result i64 i64) unreachable i64.add128))",
        "wide",
    ),
    Case(
        "simd",
        "simd",
        "(module (func v128.const i32x4 0 0 0 0 drop))",
    ),
    Case(
        "relaxed-simd",
        "relaxed-simd",
        "(module (func unreachable i8x16.relaxed_swizzle drop))",
        "library-only",
    ),
    Case(
        "threads",
        "threads",
        "(module (memory 1 1 shared) "
        "(func i32.const 0 i32.atomic.load drop))",
    ),
)


@dataclass(frozen=True)
class Result:
    returncode: int | None
    stdout: str
    stderr: str

    @property
    def accepted(self) -> bool:
        return self.returncode == 0

    @property
    def rejected(self) -> bool:
        return self.returncode == 1

    def summary(self) -> str:
        output = self.stderr.strip() or self.stdout.strip() or "(no output)"
        return f"exit {self.returncode}: {output.splitlines()[-1]}"


def run(argv: Sequence[Path | str]) -> Result:
    try:
        completed = subprocess.run(
            tuple(str(arg) for arg in argv),
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, "NO_COLOR": "1"},
        )
    except OSError as error:
        return Result(None, "", f"could not execute: {error}")
    return Result(completed.returncode, completed.stdout, completed.stderr)


class Matrix:
    def __init__(self) -> None:
        self.totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        self.family_totals = [0, 0]
        self.mismatches: list[str] = []

    def check(self, phase: str, case: str, ok: bool, detail: str) -> None:
        total = self.totals[phase]
        total[1] += 1
        if ok:
            total[0] += 1
        else:
            self.mismatches.append(f"{case} [{phase}]: {detail}")

    def finish_case(self, passed: bool) -> None:
        self.family_totals[1] += 1
        if passed:
            self.family_totals[0] += 1

    def report(self) -> None:
        passed = sum(value[0] for value in self.totals.values())
        total = sum(value[1] for value in self.totals.values())
        print(
            "Function-body feature matrix: "
            f"{self.family_totals[0]}/{self.family_totals[1]} families, "
            f"{passed}/{total} checks"
        )
        for phase, (phase_passed, phase_total) in sorted(self.totals.items()):
            print(f"  {phase}: {phase_passed}/{phase_total}")
        if self.mismatches:
            print("Mismatches:", file=sys.stderr)
            for mismatch in self.mismatches:
                print(f"  {mismatch}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wabt", type=Path, help="path to the built wabt CLI")
    parser.add_argument("wasm_tools", type=Path, help="path to wasm-tools 1.250.0")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()

    wabt = args.wabt.resolve(strict=True)
    wasm_tools = args.wasm_tools.resolve(strict=True)
    version = run((wasm_tools, "--version"))
    if not version.accepted or not version.stdout.startswith(
        EXPECTED_WASM_TOOLS_VERSION
    ):
        print(
            f"error: expected {EXPECTED_WASM_TOOLS_VERSION}, got {version.summary()}",
            file=sys.stderr,
        )
        return 2

    work_dir = args.work_dir.resolve()
    allowed_root = (ROOT / "zig-out").resolve()
    if work_dir == allowed_root or allowed_root not in work_dir.parents:
        print(f"error: --work-dir must be below {allowed_root}", file=sys.stderr)
        return 2
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)

    matrix = Matrix()
    for case in CASES:
        mismatch_count = len(matrix.mismatches)
        case_dir = work_dir / case.family
        case_dir.mkdir()
        wat = case_dir / f"{case.family}.wat"
        tools_wasm = case_dir / f"{case.family}.wasm-tools.wasm"
        wat.write_text(case.wat, encoding="utf-8")

        enabled_features = "all"
        disabled_features = f"all,-{case.feature}"
        tools_wat_enabled = run(
            (wasm_tools, "validate", f"--features={enabled_features}", wat)
        )
        tools_wat_disabled = run(
            (wasm_tools, "validate", f"--features={disabled_features}", wat)
        )
        matrix.check(
            "wasm-tools-wat-enabled",
            case.family,
            tools_wat_enabled.accepted,
            tools_wat_enabled.summary(),
        )
        matrix.check(
            "wasm-tools-wat-disabled",
            case.family,
            tools_wat_disabled.rejected,
            tools_wat_disabled.summary(),
        )

        tools_parse = run((wasm_tools, "parse", wat, "-o", tools_wasm))
        tools_binary_enabled = (
            run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={enabled_features}",
                    tools_wasm,
                )
            )
            if tools_parse.accepted
            else tools_parse
        )
        tools_binary_disabled = (
            run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={disabled_features}",
                    tools_wasm,
                )
            )
            if tools_parse.accepted
            else tools_parse
        )
        matrix.check(
            "wasm-tools-binary-enabled",
            case.family,
            tools_parse.accepted and tools_binary_enabled.accepted,
            f"parse {tools_parse.summary()}; validate {tools_binary_enabled.summary()}",
        )
        matrix.check(
            "wasm-tools-binary-disabled",
            case.family,
            tools_parse.accepted and tools_binary_disabled.rejected,
            f"parse {tools_parse.summary()}; validate {tools_binary_disabled.summary()}",
        )

        if case.wabt_mode == "library-only":
            matrix.finish_case(len(matrix.mismatches) == mismatch_count)
            continue

        wabt_wasm = case_dir / f"{case.family}.wabt.wasm"
        alias = ("--enable-wide-arithmetic",) if case.wabt_mode == "wide" else ()
        wabt_parse = run((wabt, "text", "parse", *alias, wat, "-o", wabt_wasm))
        wabt_validate = (
            run((wabt, "module", "validate", *alias, wabt_wasm))
            if wabt_parse.accepted
            else wabt_parse
        )
        matrix.check(
            "wabt-enabled-wat",
            case.family,
            wabt_parse.accepted,
            wabt_parse.summary(),
        )
        matrix.check(
            "wabt-enabled-binary",
            case.family,
            wabt_parse.accepted and wabt_validate.accepted,
            wabt_validate.summary(),
        )

        if case.wabt_mode == "wide" and wabt_parse.accepted:
            wabt_parse_disabled = run(
                (
                    wabt,
                    "text",
                    "parse",
                    wat,
                    "-o",
                    case_dir / "wide-disabled.wasm",
                )
            )
            wabt_binary_disabled = run(
                (wabt, "module", "validate", wabt_wasm)
            )
            matrix.check(
                "wabt-disabled-wat-alias",
                case.family,
                wabt_parse_disabled.rejected,
                wabt_parse_disabled.summary(),
            )
            matrix.check(
                "wabt-disabled-binary-alias",
                case.family,
                wabt_binary_disabled.rejected,
                wabt_binary_disabled.summary(),
            )
        matrix.finish_case(len(matrix.mismatches) == mismatch_count)

    matrix.report()
    failed = bool(matrix.mismatches)
    if args.keep_work or failed:
        print(f"Materialized matrix: {work_dir}")
    else:
        shutil.rmtree(work_dir)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
