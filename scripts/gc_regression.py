#!/usr/bin/env python3
"""Run the permanent core-GC corpus through wabt and wasm-tools."""

from __future__ import annotations

import argparse
import json
import os
import signal
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
CORPUS_PATH = ROOT / "src/fixtures/gc-regression/corpus.json"
DEFAULT_WORK_DIR = ROOT / "zig-out/gc-regression-matrix"
EXPECTED_WASM_TOOLS_VERSION = "wasm-tools 1.250.0"
WABT_REJECTION_EXIT_STATUS = 1
WASM_TOOLS_REJECTION_EXIT_STATUS = 1
GC_SUBOPCODES = tuple(range(0x1F))


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int | None
    stdout: str
    stderr: str

    @property
    def accepted(self) -> bool:
        return self.returncode == 0

    def rejected(self, expected_status: int) -> bool:
        return self.returncode == expected_status

    def summary(self) -> str:
        output = self.stderr.strip() or self.stdout.strip()
        last_line = output.splitlines()[-1] if output else "(no output)"
        if self.returncode is None:
            return last_line
        if self.returncode < 0:
            try:
                signal_name = signal.Signals(-self.returncode).name
            except ValueError:
                signal_name = f"signal {-self.returncode}"
            return f"killed by {signal_name}: {last_line}"
        return f"exit {self.returncode}: {last_line}"


def run(
    argv: Sequence[Path | str],
    *,
    required_inputs: Sequence[Path] = (),
) -> CommandResult:
    command = tuple(str(arg) for arg in argv)
    missing = [path for path in required_inputs if not path.is_file()]
    if missing:
        paths = ", ".join(str(path) for path in missing)
        return CommandResult(command, None, "", f"not run: missing input file: {paths}")
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
        return CommandResult(command, None, "", f"could not execute: {error}")
    return CommandResult(command, completed.returncode, completed.stdout, completed.stderr)


def encode_u32(value: int) -> bytes:
    encoded = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            byte |= 0x80
        encoded.append(byte)
        if not value:
            return bytes(encoded)


def module_with_body(body: bytes) -> bytes:
    type_section = bytes((1, 4, 1, 0x60, 0, 0))
    function_section = bytes((3, 2, 1, 0))
    payload = bytes((1,)) + encode_u32(1 + len(body)) + bytes((0,)) + body
    code_section = bytes((10,)) + encode_u32(len(payload)) + payload
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
            f"GC differential matrix: {cases_passed}/{cases_total} cases, "
            f"{checks_passed}/{checks_total} checks"
        )
        print("Checks:")
        for phase, (passed, total) in sorted(self.phase_totals.items()):
            print(f"  {phase}: {passed}/{total}")
        print("Families:")
        for family, (passed, total) in sorted(self.family_totals.items()):
            print(f"  {family}: {passed}/{total}")
        coverage = " ".join(f"0xfb{sub:02x}" for sub in GC_SUBOPCODES)
        print(f"Opcodes ({len(GC_SUBOPCODES)}): {coverage}")
        if self.mismatches:
            print("Mismatches:", file=sys.stderr)
            for mismatch in self.mismatches:
                print(f"  {mismatch}", file=sys.stderr)


def check_manifest(corpus: dict[str, object]) -> None:
    seen: list[int] = []
    for case in corpus["valid"]:
        seen.extend(case["subopcodes"])
    if sorted(seen) != list(GC_SUBOPCODES):
        raise ValueError("valid corpus must list each GC subopcode exactly once")


def command_pair_detail(left: CommandResult, right: CommandResult) -> str:
    return f"wabt {left.summary()}; wasm-tools {right.summary()}"


def rejection_detail(result: CommandResult, expected_status: int) -> str:
    return f"{result.summary()} (expected validation rejection exit {expected_status})"


def rejection_pair_detail(left: CommandResult, right: CommandResult) -> str:
    return (
        f"wabt {rejection_detail(left, WABT_REJECTION_EXIT_STATUS)}; "
        f"wasm-tools {rejection_detail(right, WASM_TOOLS_REJECTION_EXIT_STATUS)}"
    )


def run_valid_case(
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
    tools_wasm = case_dir / f"{name}.wasm-tools.wasm"
    source.write_text(str(case["wat"]), encoding="utf-8")

    passed = True
    wabt_wat = run((wabt, "text", "parse", source, "-o", wabt_wasm))
    tools_wat = run((wasm_tools, "validate", source))
    passed &= matrix.check(
        "wat-verdict",
        name,
        wabt_wat.accepted and tools_wat.accepted,
        command_pair_detail(wabt_wat, tools_wat),
    )

    tools_parse = run((wasm_tools, "parse", source, "-o", tools_wasm))
    tools_binary = (
        run((wasm_tools, "validate", tools_wasm))
        if tools_parse.accepted
        else tools_parse
    )
    passed &= matrix.check(
        "wasm-tools-reference",
        name,
        tools_parse.accepted and tools_binary.accepted,
        f"parse {tools_parse.summary()}; validate {tools_binary.summary()}",
    )

    if wabt_wat.accepted:
        wabt_binary = run((wabt, "module", "validate", wabt_wasm))
        tools_on_wabt = run((wasm_tools, "validate", wabt_wasm))
        passed &= matrix.check(
            "binary-verdict",
            name,
            wabt_binary.accepted and tools_on_wabt.accepted,
            command_pair_detail(wabt_binary, tools_on_wabt),
        )
        passed &= matrix.check(
            "wasm-tools-on-wabt-output",
            name,
            tools_on_wabt.accepted,
            tools_on_wabt.summary(),
        )

        gc_disabled = run(
            (wasm_tools, "validate", "--features=-gc", wabt_wasm),
            required_inputs=(wabt_wasm,),
        )
        passed &= matrix.check(
            "feature-disabled",
            name,
            gc_disabled.rejected(WASM_TOOLS_REJECTION_EXIT_STATUS),
            rejection_detail(gc_disabled, WASM_TOOLS_REJECTION_EXIT_STATUS),
        )

        printed = case_dir / f"{name}.wabt.printed.wat"
        reparsed = case_dir / f"{name}.wabt.reparsed.wasm"
        canonical_before = case_dir / f"{name}.canonical-before.wat"
        canonical_after = case_dir / f"{name}.canonical-after.wat"
        print_result = run((wabt, "text", "print", wabt_wasm, "-o", printed))
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
        tools_printed_wat = (
            run((wasm_tools, "validate", printed))
            if print_result.accepted
            else print_result
        )
        canonical_before_result = run(
            (wasm_tools, "print", wabt_wasm, "-o", canonical_before)
        )
        canonical_after_result = (
            run((wasm_tools, "print", reparsed, "-o", canonical_after))
            if reparse_result.accepted
            else reparse_result
        )
        canonical_equal = (
            canonical_before_result.accepted
            and canonical_after_result.accepted
            and canonical_before.read_bytes() == canonical_after.read_bytes()
        )
        roundtrip_ok = all(
            result.accepted
            for result in (
                print_result,
                reparse_result,
                wabt_revalidate,
                tools_revalidate,
                tools_printed_wat,
            )
        ) and canonical_equal
        passed &= matrix.check(
            "canonical-roundtrip",
            name,
            roundtrip_ok,
            "print/reparse/validation failed or wasm-tools canonical text changed",
        )
    else:
        for phase in (
            "binary-verdict",
            "wasm-tools-on-wabt-output",
            "feature-disabled",
            "canonical-roundtrip",
        ):
            passed &= matrix.check(phase, name, False, "WAT conversion did not produce binary")

    matrix.finish_case(family, bool(passed))


def run_invalid_wat_case(
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
    output = case_dir / f"{name}.wabt.wasm"
    source.write_text(str(case["wat"]), encoding="utf-8")
    wabt_result = run(
        (wabt, "text", "parse", source, "-o", output),
        required_inputs=(source,),
    )
    tools_result = run(
        (wasm_tools, "validate", source),
        required_inputs=(source,),
    )
    passed = matrix.check(
        "wat-verdict",
        name,
        wabt_result.rejected(WABT_REJECTION_EXIT_STATUS)
        and tools_result.rejected(WASM_TOOLS_REJECTION_EXIT_STATUS),
        rejection_pair_detail(wabt_result, tools_result),
    )
    matrix.finish_case(family, passed)


def run_invalid_binary_case(
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
    wasm = case_dir / f"{name}.wasm"
    wasm.write_bytes(module_with_body(bytes.fromhex(str(case["body_hex"]))))
    wabt_result = run(
        (wabt, "module", "validate", wasm),
        required_inputs=(wasm,),
    )
    tools_result = run(
        (wasm_tools, "validate", wasm),
        required_inputs=(wasm,),
    )
    passed = matrix.check(
        "binary-verdict",
        name,
        wabt_result.rejected(WABT_REJECTION_EXIT_STATUS)
        and tools_result.rejected(WASM_TOOLS_REJECTION_EXIT_STATUS),
        rejection_pair_detail(wabt_result, tools_result),
    )
    matrix.finish_case(family, passed)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Differentially run the permanent core-GC regression corpus."
    )
    parser.add_argument("wabt", type=Path, help="path to the built wabt CLI")
    parser.add_argument("wasm_tools", type=Path, help="path to wasm-tools 1.250.0")
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=DEFAULT_WORK_DIR,
        help="materialization directory (default: zig-out/gc-regression-matrix)",
    )
    parser.add_argument(
        "--keep-work",
        action="store_true",
        help="keep materialized WAT, wasm, and canonical-print files",
    )
    args = parser.parse_args()

    wabt = args.wabt.resolve(strict=True)
    wasm_tools = args.wasm_tools.resolve(strict=True)
    version = run((wasm_tools, "--version"))
    version_fields = version.stdout.strip().split()
    if (
        not version.accepted
        or len(version_fields) < 2
        or " ".join(version_fields[:2]) != EXPECTED_WASM_TOOLS_VERSION
    ):
        print(
            f"error: expected {EXPECTED_WASM_TOOLS_VERSION}, got "
            f"{version.stdout.strip() or version.summary()}",
            file=sys.stderr,
        )
        return 2
    wabt_version = run((wabt, "version"))
    if not wabt_version.accepted:
        print(f"error: wabt CLI failed its version command: {wabt_version.summary()}", file=sys.stderr)
        return 2

    corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
    check_manifest(corpus)
    work_dir = args.work_dir.resolve()
    allowed_work_root = (ROOT / "zig-out").resolve()
    if work_dir == allowed_work_root or allowed_work_root not in work_dir.parents:
        print(f"error: --work-dir must be below {allowed_work_root}", file=sys.stderr)
        return 2
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)

    matrix = Matrix()
    for case in corpus["valid"]:
        run_valid_case(matrix, case, work_dir, wabt, wasm_tools)
    for case in corpus["invalid_wat"]:
        run_invalid_wat_case(matrix, case, work_dir, wabt, wasm_tools)
    for case in corpus["invalid_binary"]:
        run_invalid_binary_case(matrix, case, work_dir, wabt, wasm_tools)

    matrix.report()
    failed = bool(matrix.mismatches)
    if args.keep_work or failed:
        print(f"Materialized corpus: {work_dir}")
    else:
        shutil.rmtree(work_dir)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
