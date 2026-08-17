#!/usr/bin/env python3
"""Differentially validate typed select with wabt and wasm-tools 1.250.0."""

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
CORPUS_PATH = ROOT / "src/fixtures/typed-select-regression/corpus.json"
DEFAULT_WORK_DIR = ROOT / "zig-out/typed-select-matrix"
EXPECTED_WASM_TOOLS_VERSION = "wasm-tools 1.250.0"
GATE_FEATURES = (
    "reference-types",
    "function-references",
    "gc",
    "exceptions",
)


@dataclass(frozen=True)
class Result:
    argv: tuple[str, ...]
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
    command = tuple(str(arg) for arg in argv)
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, "NO_COLOR": "1"},
        )
    except OSError as error:
        return Result(command, None, "", f"could not execute: {error}")
    return Result(command, completed.returncode, completed.stdout, completed.stderr)


def uleb(value: int) -> bytes:
    encoded = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            byte |= 0x80
        encoded.append(byte)
        if not value:
            return bytes(encoded)


def s33(value: int) -> bytes:
    encoded = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        done = (value == 0 and byte & 0x40 == 0) or (
            value == -1 and byte & 0x40 != 0
        )
        encoded.append(byte if done else byte | 0x80)
        if done:
            return bytes(encoded)


def section(section_id: int, payload: bytes) -> bytes:
    return bytes((section_id,)) + uleb(len(payload)) + payload


def type_entry(kind: str, type_index: int) -> bytes:
    if kind == "func":
        return bytes((0x60, 0, 0))
    if kind == "struct":
        return bytes((0x5F, 0))
    if kind == "array":
        return bytes((0x5E, 0x7F, 0))
    if kind == "recursive-struct":
        field = bytes((0x5F, 1, 0x63)) + s33(type_index) + bytes((0,))
        return bytes((0x4E, 1)) + field
    raise ValueError(f"unknown binary test type kind: {kind}")


def module_with_body(case: dict[str, object], body: bytes) -> bytes:
    target_index = int(case.get("type_index", 0))
    target_kind = str(case.get("type_kind", "func"))
    entries: list[bytes] = []
    function_type_index: int | None = None
    for index in range(target_index + 1):
        kind = target_kind if index == target_index else "func"
        entries.append(type_entry(kind, index))
        if function_type_index is None and kind == "func":
            function_type_index = index
    if function_type_index is None:
        function_type_index = target_index + 1
        entries.append(type_entry("func", function_type_index))

    type_section = section(1, uleb(len(entries)) + b"".join(entries))
    function_section = section(3, bytes((1,)) + uleb(function_type_index))
    body_entry = uleb(1 + len(body)) + bytes((0,)) + body
    code_section = section(10, bytes((1,)) + body_entry)
    return b"\0asm\1\0\0\0" + type_section + function_section + code_section


class Matrix:
    def __init__(self) -> None:
        self.phase_totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        self.family_totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        self.mismatches: list[str] = []

    def check(self, phase: str, case: str, ok: bool, detail: str) -> bool:
        totals = self.phase_totals[phase]
        totals[1] += 1
        if ok:
            totals[0] += 1
        else:
            self.mismatches.append(f"{case} [{phase}]: {detail}")
        return ok

    def finish_case(self, family: str, passed: bool) -> None:
        totals = self.family_totals[family]
        totals[1] += 1
        if passed:
            totals[0] += 1

    def report(self) -> None:
        checks_passed = sum(value[0] for value in self.phase_totals.values())
        checks_total = sum(value[1] for value in self.phase_totals.values())
        cases_passed = sum(value[0] for value in self.family_totals.values())
        cases_total = sum(value[1] for value in self.family_totals.values())
        print(
            f"Typed select differential matrix: {cases_passed}/{cases_total} cases, "
            f"{checks_passed}/{checks_total} checks"
        )
        print("Checks:")
        for phase, (passed, total) in sorted(self.phase_totals.items()):
            print(f"  {phase}: {passed}/{total}")
        print("Families:")
        for family, (passed, total) in sorted(self.family_totals.items()):
            print(f"  {family}: {passed}/{total}")
        if self.mismatches:
            print("Mismatches:", file=sys.stderr)
            for mismatch in self.mismatches:
                print(f"  {mismatch}", file=sys.stderr)


def pair_detail(wabt: Result, tools: Result) -> str:
    return f"wabt {wabt.summary()}; wasm-tools {tools.summary()}"


def gate_enabled(gate: str, enabled: set[str]) -> bool:
    if gate == "reference-types":
        return "reference-types" in enabled
    if gate == "function-references":
        return {"reference-types", "function-references"} <= enabled
    if gate == "gc":
        return {"reference-types", "gc"} <= enabled
    if gate == "exceptions":
        return {"reference-types", "exceptions"} <= enabled
    if gate == "function-references-or-gc":
        return "reference-types" in enabled and bool(
            {"function-references", "gc"} & enabled
        )
    raise ValueError(f"unknown feature gate: {gate}")


def run_feature_gate(
    matrix: Matrix,
    case: dict[str, object],
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    name = str(case["name"])
    gate = str(case["gate"])
    case_dir = work_dir / name
    case_dir.mkdir()
    source = case_dir / f"{name}.wat"
    binary = case_dir / f"{name}.wasm"
    source.write_text(str(case["wat"]), encoding="utf-8")

    wabt_parse = run((wabt, "text", "parse", source, "-o", binary))
    wabt_validate = (
        run((wabt, "module", "validate", binary))
        if wabt_parse.accepted
        else wabt_parse
    )
    tools_default = run((wasm_tools, "validate", source))
    passed = matrix.check(
        "feature-gate-default",
        name,
        wabt_parse.accepted
        and wabt_validate.accepted
        and tools_default.accepted,
        f"parse {wabt_parse.summary()}; "
        f"validate {wabt_validate.summary()}; "
        f"wasm-tools {tools_default.summary()}",
    )

    for mask in range(16):
        enabled = {
            feature
            for bit, feature in enumerate(GATE_FEATURES)
            if mask & (1 << bit)
        }
        settings = [
            feature if feature in enabled else f"-{feature}"
            for feature in GATE_FEATURES
        ]
        tools_result = run(
            (
                wasm_tools,
                "validate",
                f"--features={','.join(settings)}",
                source,
            )
        )
        expected = gate_enabled(gate, enabled)
        verdict_matches = (
            tools_result.accepted if expected else tools_result.rejected
        )
        bits = "".join(
            "1" if feature in enabled else "0" for feature in GATE_FEATURES
        )
        passed &= matrix.check(
            "feature-gate-combination",
            f"{name}/{bits}",
            verdict_matches,
            f"gate {gate}, expected {'accept' if expected else 'reject'}; "
            f"{tools_result.summary()}",
        )

    matrix.finish_case("feature-gate", bool(passed))


def run_valid_wat(
    matrix: Matrix,
    case: dict[str, object],
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    name = str(case["name"])
    family = str(case["family"])
    case_dir = work_dir / name
    case_dir.mkdir()
    source = case_dir / f"{name}.wat"
    wabt_wasm = case_dir / f"{name}.wabt.wasm"
    tools_wasm = case_dir / f"{name}.tools.wasm"
    printed = case_dir / f"{name}.printed.wat"
    reparsed = case_dir / f"{name}.reparsed.wasm"
    canonical_before = case_dir / f"{name}.before.wat"
    canonical_after = case_dir / f"{name}.after.wat"
    source.write_text(str(case["wat"]), encoding="utf-8")

    passed = True
    wabt_wat = run((wabt, "text", "parse", source, "-o", wabt_wasm))
    tools_wat = run((wasm_tools, "validate", source))
    passed &= matrix.check(
        "wat-verdict",
        name,
        wabt_wat.accepted and tools_wat.accepted,
        pair_detail(wabt_wat, tools_wat),
    )

    tools_parse = run((wasm_tools, "parse", source, "-o", tools_wasm))
    wabt_on_tools = (
        run((wabt, "module", "validate", tools_wasm))
        if tools_parse.accepted
        else tools_parse
    )
    passed &= matrix.check(
        "wabt-on-reference-binary",
        name,
        tools_parse.accepted and wabt_on_tools.accepted,
        f"parse {tools_parse.summary()}; validate {wabt_on_tools.summary()}",
    )

    if wabt_wat.accepted:
        wabt_binary = run((wabt, "module", "validate", wabt_wasm))
        tools_binary = run((wasm_tools, "validate", wabt_wasm))
        passed &= matrix.check(
            "binary-verdict",
            name,
            wabt_binary.accepted and tools_binary.accepted,
            pair_detail(wabt_binary, tools_binary),
        )

        disabled = run(
            (wasm_tools, "validate", "--features=-reference-types", wabt_wasm)
        )
        passed &= matrix.check(
            "reference-types-disabled",
            name,
            disabled.rejected,
            disabled.summary(),
        )

        print_result = run((wabt, "text", "print", wabt_wasm, "-o", printed))
        tools_printed = (
            run((wasm_tools, "validate", printed))
            if print_result.accepted
            else print_result
        )
        reparse_result = (
            run((wabt, "text", "parse", printed, "-o", reparsed))
            if print_result.accepted
            else print_result
        )
        wabt_revalidate = (
            run((wabt, "module", "validate", reparsed))
            if reparse_result.accepted
            else reparse_result
        )
        tools_revalidate = (
            run((wasm_tools, "validate", reparsed))
            if reparse_result.accepted
            else reparse_result
        )
        before_result = run((wasm_tools, "print", wabt_wasm, "-o", canonical_before))
        after_result = (
            run((wasm_tools, "print", reparsed, "-o", canonical_after))
            if reparse_result.accepted
            else reparse_result
        )
        canonical_equal = (
            before_result.accepted
            and after_result.accepted
            and canonical_before.read_bytes() == canonical_after.read_bytes()
        )
        passed &= matrix.check(
            "wabt-output",
            name,
            all(
                result.accepted
                for result in (
                    print_result,
                    tools_printed,
                    reparse_result,
                    wabt_revalidate,
                    tools_revalidate,
                )
            )
            and canonical_equal,
            "print/reparse validation failed or wasm-tools canonical text changed",
        )
    else:
        for phase in (
            "binary-verdict",
            "reference-types-disabled",
            "wabt-output",
        ):
            passed &= matrix.check(phase, name, False, "WAT conversion produced no binary")

    matrix.finish_case(family, bool(passed))


def run_invalid_wat(
    matrix: Matrix,
    case: dict[str, object],
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    name = str(case["name"])
    family = str(case["family"])
    case_dir = work_dir / name
    case_dir.mkdir()
    source = case_dir / f"{name}.wat"
    output = case_dir / f"{name}.wasm"
    source.write_text(str(case["wat"]), encoding="utf-8")
    wabt_result = run((wabt, "text", "parse", source, "-o", output))
    tools_result = run((wasm_tools, "validate", source))
    passed = matrix.check(
        "invalid-wat-verdict",
        name,
        wabt_result.rejected and tools_result.rejected,
        pair_detail(wabt_result, tools_result),
    )
    matrix.finish_case(family, passed)


def run_binary(
    matrix: Matrix,
    case: dict[str, object],
    valid: bool,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    name = str(case["name"])
    family = str(case["family"])
    case_dir = work_dir / name
    case_dir.mkdir()
    binary = case_dir / f"{name}.wasm"
    binary.write_bytes(
        module_with_body(case, bytes.fromhex(str(case["body_hex"])))
    )

    wabt_result = run((wabt, "module", "validate", binary))
    tools_result = run((wasm_tools, "validate", binary))
    verdict_ok = (
        wabt_result.accepted and tools_result.accepted
        if valid
        else wabt_result.rejected and tools_result.rejected
    )
    passed = matrix.check(
        "valid-binary-verdict" if valid else "invalid-binary-verdict",
        name,
        verdict_ok,
        pair_detail(wabt_result, tools_result),
    )

    if valid:
        printed = case_dir / f"{name}.wat"
        reparsed = case_dir / f"{name}.reparsed.wasm"
        print_result = run((wabt, "text", "print", binary, "-o", printed))
        tools_printed = (
            run((wasm_tools, "validate", printed))
            if print_result.accepted
            else print_result
        )
        reparse_result = (
            run((wabt, "text", "parse", printed, "-o", reparsed))
            if print_result.accepted
            else print_result
        )
        tools_reparsed = (
            run((wasm_tools, "validate", reparsed))
            if reparse_result.accepted
            else reparse_result
        )
        passed &= matrix.check(
            "valid-binary-output",
            name,
            all(
                result.accepted
                for result in (
                    print_result,
                    tools_printed,
                    reparse_result,
                    tools_reparsed,
                )
            ),
            "wabt print/reparse output was not accepted by wasm-tools",
        )

    matrix.finish_case(family, bool(passed))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wabt", type=Path)
    parser.add_argument("wasm_tools", type=Path)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()

    wabt = args.wabt.resolve()
    wasm_tools = args.wasm_tools.resolve()
    version = run((wasm_tools, "--version"))
    if (
        not version.accepted
        or not version.stdout.startswith(EXPECTED_WASM_TOOLS_VERSION)
    ):
        print(
            f"expected '{EXPECTED_WASM_TOOLS_VERSION}', got {version.summary()}",
            file=sys.stderr,
        )
        return 2

    corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
    if corpus.get("version") != 1:
        print("unsupported typed-select corpus version", file=sys.stderr)
        return 2

    work_dir = args.work_dir.resolve()
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)

    matrix = Matrix()
    for case in corpus["feature_gates"]:
        run_feature_gate(matrix, case, work_dir, wabt, wasm_tools)
    for case in corpus["valid"]:
        run_valid_wat(matrix, case, work_dir, wabt, wasm_tools)
    for case in corpus["invalid_wat"]:
        run_invalid_wat(matrix, case, work_dir, wabt, wasm_tools)
    for case in corpus["valid_binary"]:
        run_binary(matrix, case, True, work_dir, wabt, wasm_tools)
    for case in corpus["invalid_binary"]:
        run_binary(matrix, case, False, work_dir, wabt, wasm_tools)

    matrix.report()
    if matrix.mismatches:
        return 1
    if not args.keep_work:
        shutil.rmtree(work_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
