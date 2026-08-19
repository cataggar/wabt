#!/usr/bin/env python3
"""Run the frozen cross-feature corpus against wabt and wasm-tools 1.250.0."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "src/fixtures/cross-feature-regression/corpus.json"
DEFAULT_WORK_DIR = ROOT / "zig-out/cross-feature-matrix"
EXPECTED_WASM_TOOLS_VERSION = "1.250.0"


@dataclass(frozen=True)
class Result:
    returncode: int | None
    stdout: str
    stderr: str

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
        self.surface_totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        self.mismatches: list[str] = []

    def check(
        self,
        phase: str,
        surface: str,
        case: str,
        result: Result,
        expected_exit: int,
    ) -> None:
        phase_total = self.totals[phase]
        surface_total = self.surface_totals[surface]
        phase_total[1] += 1
        surface_total[1] += 1
        if result.returncode == expected_exit:
            phase_total[0] += 1
            surface_total[0] += 1
        else:
            self.mismatches.append(
                f"{case} [{phase}]: expected exit {expected_exit}, "
                f"got {result.summary()}"
            )

    def report(self, case_count: int) -> None:
        passed = sum(value[0] for value in self.totals.values())
        total = sum(value[1] for value in self.totals.values())
        print(
            f"Cross-feature differential matrix: {case_count} cases, "
            f"{passed}/{total} checks"
        )
        print("Surfaces:")
        for surface, (surface_passed, surface_total) in sorted(
            self.surface_totals.items()
        ):
            print(f"  {surface}: {surface_passed}/{surface_total}")
        print("Phases:")
        for phase, (phase_passed, phase_total) in sorted(self.totals.items()):
            print(f"  {phase}: {phase_passed}/{phase_total}")
        if self.mismatches:
            print("Mismatches:", file=sys.stderr)
            for mismatch in self.mismatches:
                print(f"  {mismatch}", file=sys.stderr)


def validate_corpus(corpus: object) -> dict[str, object]:
    if not isinstance(corpus, dict) or corpus.get("version") != 1:
        raise ValueError("corpus must be an object with version 1")
    required_lists = ("wat_cases", "invalid_wat_cases", "binary_cases")
    for name in required_lists:
        if not isinstance(corpus.get(name), list):
            raise ValueError(f"corpus field {name!r} must be a list")

    names: set[str] = set()
    for group in required_lists:
        for case in corpus[group]:
            if not isinstance(case, dict):
                raise ValueError(f"{group} entries must be objects")
            name = case.get("name")
            if not isinstance(name, str) or not name:
                raise ValueError(f"{group} entry has an invalid name")
            if name in names:
                raise ValueError(f"duplicate case name {name!r}")
            names.add(name)
            if not isinstance(case.get("surface"), str):
                raise ValueError(f"{name!r} has an invalid surface")

            if group == "wat_cases":
                if not isinstance(case.get("wat"), str):
                    raise ValueError(f"{name!r} has invalid WAT")
                variants = case.get("variants")
                if not isinstance(variants, list) or not variants:
                    raise ValueError(f"{name!r} must have feature variants")
                for variant in variants:
                    if (
                        not isinstance(variant, dict)
                        or not isinstance(variant.get("features"), str)
                        or (
                            "wasm_tools_features" in variant
                            and not isinstance(
                                variant["wasm_tools_features"], str
                            )
                        )
                        or variant.get("expected_exit") not in (0, 1)
                    ):
                        raise ValueError(f"{name!r} has an invalid variant")
            else:
                if (
                    not isinstance(case.get("features"), str)
                    or case.get("expected_exit") not in (0, 1)
                    or case.get("failure_kind")
                    not in ("malformed", "truncated")
                ):
                    raise ValueError(f"{name!r} has invalid expectations")
                if group == "invalid_wat_cases" and not isinstance(
                    case.get("wat"), str
                ):
                    raise ValueError(f"{name!r} has invalid WAT")
                if group == "binary_cases":
                    hex_bytes = case.get("hex")
                    if not isinstance(hex_bytes, str):
                        raise ValueError(f"{name!r} has invalid hex")
                    try:
                        bytes.fromhex(hex_bytes)
                    except ValueError as error:
                        raise ValueError(
                            f"{name!r} has invalid hex: {error}"
                        ) from error
    return corpus


def load_corpus() -> dict[str, object]:
    with CORPUS.open(encoding="utf-8") as source:
        return validate_corpus(json.load(source))


def validate_wat_cases(
    matrix: Matrix,
    cases: list[dict[str, object]],
    wabt: Path,
    wasm_tools: Path,
    work_dir: Path,
) -> None:
    for case in cases:
        name = str(case["name"])
        surface = str(case["surface"])
        case_dir = work_dir / name
        case_dir.mkdir()
        wat = case_dir / f"{name}.wat"
        tools_wasm = case_dir / f"{name}.wasm-tools.wasm"
        wat.write_text(str(case["wat"]), encoding="utf-8")

        tools_parse = run((wasm_tools, "parse", wat, "-o", tools_wasm))
        matrix.check("wasm-tools-parse", surface, name, tools_parse, 0)

        for index, variant in enumerate(case["variants"]):
            features = str(variant["features"])
            tools_features = str(variant.get("wasm_tools_features", features))
            expected_exit = int(variant["expected_exit"])
            variant_name = f"{name}/{index}:{features}"
            wabt_wasm = case_dir / f"{name}.{index}.wabt.wasm"

            wabt_wat = run(
                (
                    wabt,
                    "text",
                    "parse",
                    f"--features={features}",
                    wat,
                    "-o",
                    wabt_wasm,
                )
            )
            tools_wat = run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={tools_features}",
                    wat,
                )
            )
            matrix.check(
                "wabt-wat", surface, variant_name, wabt_wat, expected_exit
            )
            matrix.check(
                "wasm-tools-wat",
                surface,
                variant_name,
                tools_wat,
                expected_exit,
            )

            if tools_parse.returncode == 0:
                wabt_binary = run(
                    (
                        wabt,
                        "module",
                        "validate",
                        f"--features={features}",
                        tools_wasm,
                    )
                )
                tools_binary = run(
                    (
                        wasm_tools,
                        "validate",
                        f"--features={tools_features}",
                        tools_wasm,
                    )
                )
                matrix.check(
                    "wabt-binary",
                    surface,
                    variant_name,
                    wabt_binary,
                    expected_exit,
                )
                matrix.check(
                    "wasm-tools-binary",
                    surface,
                    variant_name,
                    tools_binary,
                    expected_exit,
                )

            if expected_exit == 0 and wabt_wat.returncode == 0:
                tools_on_wabt = run(
                    (
                        wasm_tools,
                        "validate",
                        f"--features={tools_features}",
                        wabt_wasm,
                    )
                )
                matrix.check(
                    "wasm-tools-on-wabt",
                    surface,
                    variant_name,
                    tools_on_wabt,
                    0,
                )


def validate_invalid_wat_cases(
    matrix: Matrix,
    cases: list[dict[str, object]],
    wabt: Path,
    wasm_tools: Path,
    work_dir: Path,
) -> None:
    for case in cases:
        name = str(case["name"])
        surface = str(case["surface"])
        features = str(case["features"])
        expected_exit = int(case["expected_exit"])
        wat = work_dir / f"{name}.wat"
        output = work_dir / f"{name}.wabt.wasm"
        wat.write_text(str(case["wat"]), encoding="utf-8")
        matrix.check(
            "wabt-invalid-wat",
            surface,
            name,
            run(
                (
                    wabt,
                    "text",
                    "parse",
                    f"--features={features}",
                    wat,
                    "-o",
                    output,
                )
            ),
            expected_exit,
        )
        matrix.check(
            "wasm-tools-invalid-wat",
            surface,
            name,
            run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={features}",
                    wat,
                )
            ),
            expected_exit,
        )


def validate_binary_cases(
    matrix: Matrix,
    cases: list[dict[str, object]],
    wabt: Path,
    wasm_tools: Path,
    work_dir: Path,
) -> None:
    for case in cases:
        name = str(case["name"])
        surface = str(case["surface"])
        features = str(case["features"])
        expected_exit = int(case["expected_exit"])
        binary = work_dir / f"{name}.wasm"
        binary.write_bytes(bytes.fromhex(str(case["hex"])))
        matrix.check(
            "wabt-malformed-binary",
            surface,
            name,
            run(
                (
                    wabt,
                    "module",
                    "validate",
                    f"--features={features}",
                    binary,
                )
            ),
            expected_exit,
        )
        matrix.check(
            "wasm-tools-malformed-binary",
            surface,
            name,
            run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={features}",
                    binary,
                )
            ),
            expected_exit,
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wabt", type=Path, help="path to the built wabt CLI")
    parser.add_argument(
        "wasm_tools", type=Path, help="path to wasm-tools 1.250.0"
    )
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()

    wabt = args.wabt.resolve(strict=True)
    wasm_tools = args.wasm_tools.resolve(strict=True)
    version = run((wasm_tools, "--version"))
    version_fields = version.stdout.split()
    if (
        version.returncode != 0
        or len(version_fields) < 2
        or version_fields[0] != "wasm-tools"
        or version_fields[1] != EXPECTED_WASM_TOOLS_VERSION
    ):
        print(
            "error: expected wasm-tools "
            f"{EXPECTED_WASM_TOOLS_VERSION}, got {version.summary()}",
            file=sys.stderr,
        )
        return 2

    try:
        corpus = load_corpus()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: invalid corpus: {error}", file=sys.stderr)
        return 2

    work_dir = args.work_dir.resolve()
    allowed_root = (ROOT / "zig-out").resolve()
    if work_dir == allowed_root or allowed_root not in work_dir.parents:
        print(
            f"error: --work-dir must be below {allowed_root}", file=sys.stderr
        )
        return 2
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)

    matrix = Matrix()
    wat_cases = corpus["wat_cases"]
    invalid_wat_cases = corpus["invalid_wat_cases"]
    binary_cases = corpus["binary_cases"]
    validate_wat_cases(matrix, wat_cases, wabt, wasm_tools, work_dir)
    validate_invalid_wat_cases(
        matrix, invalid_wat_cases, wabt, wasm_tools, work_dir
    )
    validate_binary_cases(matrix, binary_cases, wabt, wasm_tools, work_dir)

    case_count = len(wat_cases) + len(invalid_wat_cases) + len(binary_cases)
    matrix.report(case_count)
    if not args.keep_work and not matrix.mismatches:
        shutil.rmtree(work_dir)
    return 1 if matrix.mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
