#!/usr/bin/env python3
"""Differentially validate wide arithmetic with wabt and wasm-tools 1.250.0."""

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
DEFAULT_WORK_DIR = ROOT / "zig-out/wide-arithmetic-matrix"
EXPECTED_WASM_TOOLS_VERSION = "wasm-tools 1.250.0"
WIDE_FEATURE = "wide-arithmetic"
SPEC_WAST = ROOT / "test/spec-new/wide-arithmetic.wast"


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
    body_entry = encode_u32(1 + len(body)) + bytes((0,)) + body
    code_payload = bytes((1,)) + body_entry
    code_section = bytes((10,)) + encode_u32(len(code_payload)) + code_payload
    return b"\0asm\1\0\0\0" + type_section + function_section + code_section


VALID_CASES = {
    "add128": (
        "(module (func (param i64 i64 i64 i64) (result i64 i64) "
        "local.get 0 local.get 1 local.get 2 local.get 3 i64.add128))"
    ),
    "sub128": (
        "(module (func (param i64 i64 i64 i64) (result i64 i64) "
        "local.get 0 local.get 1 local.get 2 local.get 3 i64.sub128))"
    ),
    "mul-wide-s": (
        "(module (func (param i64 i64) (result i64 i64) "
        "local.get 0 local.get 1 i64.mul_wide_s))"
    ),
    "mul-wide-u": (
        "(module (func (param i64 i64) (result i64 i64) "
        "local.get 0 local.get 1 i64.mul_wide_u))"
    ),
    "add128-unreachable": "(module (func (result i64 i64) unreachable i64.add128))",
    "sub128-unreachable": "(module (func (result i64 i64) unreachable i64.sub128))",
    "mul-wide-s-unreachable": (
        "(module (func (result i64 i64) unreachable i64.mul_wide_s))"
    ),
    "mul-wide-u-unreachable": (
        "(module (func (result i64 i64) unreachable i64.mul_wide_u))"
    ),
}

INVALID_WAT_CASES = {
    "add128-missing-operand": (
        "(module (func i64.const 0 i64.const 0 i64.const 0 i64.add128 drop drop))"
    ),
    "sub128-missing-operand": (
        "(module (func i64.const 0 i64.const 0 i64.const 0 i64.sub128 drop drop))"
    ),
    "mul-wide-s-missing-operand": (
        "(module (func i64.const 0 i64.mul_wide_s drop drop))"
    ),
    "mul-wide-u-missing-operand": (
        "(module (func i64.const 0 i64.mul_wide_u drop drop))"
    ),
    "add128-wrong-operand": (
        "(module (func i64.const 0 i64.const 0 i32.const 0 i64.const 0 "
        "i64.add128 drop drop))"
    ),
    "sub128-wrong-operand": (
        "(module (func i64.const 0 i64.const 0 i64.const 0 i32.const 0 "
        "i64.sub128 drop drop))"
    ),
    "mul-wide-s-wrong-operand": (
        "(module (func i32.const 0 i64.const 0 i64.mul_wide_s drop drop))"
    ),
    "mul-wide-u-wrong-operand": (
        "(module (func i64.const 0 i32.const 0 i64.mul_wide_u drop drop))"
    ),
    "add128-result-count": (
        "(module (func (result i64) i64.const 0 i64.const 0 i64.const 0 "
        "i64.const 0 i64.add128))"
    ),
    "sub128-result-count": (
        "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 "
        "i64.const 0 i64.const 0 i64.sub128))"
    ),
    "mul-wide-s-result-count": (
        "(module (func (result i64) i64.const 0 i64.const 0 i64.mul_wide_s))"
    ),
    "mul-wide-u-result-count": (
        "(module (func (result i64 i64 i64) i64.const 0 i64.const 0 "
        "i64.mul_wide_u))"
    ),
    "add128-result-type": (
        "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.const 0 "
        "i64.const 0 i64.add128))"
    ),
    "sub128-result-type": (
        "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.const 0 "
        "i64.const 0 i64.sub128))"
    ),
    "mul-wide-s-result-type": (
        "(module (func (result i32 i64) i64.const 0 i64.const 0 i64.mul_wide_s))"
    ),
    "mul-wide-u-result-type": (
        "(module (func (result i64 i32) i64.const 0 i64.const 0 i64.mul_wide_u))"
    ),
    "add128-unreachable-result": (
        "(module (func (result i32 i64) unreachable i64.add128))"
    ),
    "sub128-unreachable-result": (
        "(module (func (result i32 i64) unreachable i64.sub128))"
    ),
    "mul-wide-s-unreachable-result": (
        "(module (func (result i32 i64) unreachable i64.mul_wide_s))"
    ),
    "mul-wide-u-unreachable-result": (
        "(module (func (result i32 i64) unreachable i64.mul_wide_u))"
    ),
}

INVALID_BINARY_CASES = {
    "truncated-prefix": bytes((0xFC,)),
    "malformed-subopcode-leb": bytes(
        (0xFC, 0x80, 0x80, 0x80, 0x80, 0x80, 0x0B)
    ),
    "unknown-before-wide": bytes((0xFC, 0x12, 0x0B)),
    "unknown-after-wide": bytes((0xFC, 0x17, 0x0B)),
}


class Matrix:
    def __init__(self) -> None:
        self.phase_totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
        self.case_totals = [0, 0]
        self.mismatches: list[str] = []

    def check(self, phase: str, case: str, ok: bool, detail: str) -> bool:
        totals = self.phase_totals[phase]
        totals[1] += 1
        if ok:
            totals[0] += 1
        else:
            self.mismatches.append(f"{case} [{phase}]: {detail}")
        return ok

    def finish_case(self, passed: bool) -> None:
        self.case_totals[1] += 1
        if passed:
            self.case_totals[0] += 1

    def report(self) -> None:
        passed = sum(value[0] for value in self.phase_totals.values())
        total = sum(value[1] for value in self.phase_totals.values())
        print(
            "Wide arithmetic differential matrix: "
            f"{self.case_totals[0]}/{self.case_totals[1]} cases, "
            f"{passed}/{total} checks"
        )
        for phase, (phase_passed, phase_total) in sorted(self.phase_totals.items()):
            print(f"  {phase}: {phase_passed}/{phase_total}")
        print("  opcodes: 0xfc13 0xfc14 0xfc15 0xfc16")
        if self.mismatches:
            print("Mismatches:", file=sys.stderr)
            for mismatch in self.mismatches:
                print(f"  {mismatch}", file=sys.stderr)


def pair_detail(wabt_result: Result, tools_result: Result) -> str:
    return f"wabt {wabt_result.summary()}; wasm-tools {tools_result.summary()}"


def run_valid_case(
    matrix: Matrix,
    name: str,
    wat: str,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    case_dir = work_dir / name
    case_dir.mkdir()
    source = case_dir / f"{name}.wat"
    wasm = case_dir / f"{name}.wabt.wasm"
    printed = case_dir / f"{name}.wabt.wat"
    reparsed = case_dir / f"{name}.reparsed.wasm"
    source.write_text(wat, encoding="utf-8")

    passed = True
    wabt_enabled = run(
        (wabt, "text", "parse", "--enable-wide-arithmetic", source, "-o", wasm)
    )
    tools_enabled = run(
        (wasm_tools, "validate", f"--features={WIDE_FEATURE}", source)
    )
    passed &= matrix.check(
        "wat-enabled",
        name,
        wabt_enabled.accepted and tools_enabled.accepted,
        pair_detail(wabt_enabled, tools_enabled),
    )

    wabt_disabled = run((wabt, "text", "parse", source, "-o", case_dir / "disabled.wasm"))
    tools_disabled = run(
        (wasm_tools, "validate", f"--features=-{WIDE_FEATURE}", source)
    )
    passed &= matrix.check(
        "wat-disabled",
        name,
        wabt_disabled.rejected and tools_disabled.rejected,
        pair_detail(wabt_disabled, tools_disabled),
    )

    if wabt_enabled.accepted:
        wabt_binary = run(
            (wabt, "module", "validate", "--enable-wide-arithmetic", wasm)
        )
        tools_binary = run(
            (wasm_tools, "validate", f"--features={WIDE_FEATURE}", wasm)
        )
        passed &= matrix.check(
            "binary-enabled",
            name,
            wabt_binary.accepted and tools_binary.accepted,
            pair_detail(wabt_binary, tools_binary),
        )

        wabt_binary_disabled = run((wabt, "module", "validate", wasm))
        tools_binary_disabled = run(
            (wasm_tools, "validate", f"--features=-{WIDE_FEATURE}", wasm)
        )
        passed &= matrix.check(
            "binary-disabled",
            name,
            wabt_binary_disabled.rejected and tools_binary_disabled.rejected,
            pair_detail(wabt_binary_disabled, tools_binary_disabled),
        )

        print_result = run((wabt, "text", "print", wasm, "-o", printed))
        tools_on_printed = run(
            (wasm_tools, "validate", f"--features={WIDE_FEATURE}", printed)
        )
        passed &= matrix.check(
            "wasm-tools-on-wabt-output",
            name,
            print_result.accepted and tools_on_printed.accepted,
            f"print {print_result.summary()}; validate {tools_on_printed.summary()}",
        )

        reparse_result = run(
            (
                wabt,
                "text",
                "parse",
                "--enable-wide-arithmetic",
                printed,
                "-o",
                reparsed,
            )
        )
        wabt_revalidate = run(
            (wabt, "module", "validate", "--enable-wide-arithmetic", reparsed)
        )
        tools_revalidate = run(
            (wasm_tools, "validate", f"--features={WIDE_FEATURE}", reparsed)
        )
        passed &= matrix.check(
            "wabt-roundtrip",
            name,
            reparse_result.accepted
            and wabt_revalidate.accepted
            and tools_revalidate.accepted,
            (
                f"reparse {reparse_result.summary()}; "
                f"wabt {wabt_revalidate.summary()}; "
                f"wasm-tools {tools_revalidate.summary()}"
            ),
        )
    else:
        for phase in (
            "binary-enabled",
            "binary-disabled",
            "wasm-tools-on-wabt-output",
            "wabt-roundtrip",
        ):
            passed &= matrix.check(phase, name, False, "wabt did not produce a binary")

    matrix.finish_case(bool(passed))


def run_invalid_wat_case(
    matrix: Matrix,
    name: str,
    wat: str,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    source = work_dir / f"{name}.wat"
    source.write_text(wat, encoding="utf-8")
    wabt_result = run(
        (
            wabt,
            "text",
            "parse",
            "--enable-wide-arithmetic",
            source,
            "-o",
            work_dir / f"{name}.wasm",
        )
    )
    tools_result = run(
        (wasm_tools, "validate", f"--features={WIDE_FEATURE}", source)
    )
    passed = matrix.check(
        "invalid-wat",
        name,
        wabt_result.rejected and tools_result.rejected,
        pair_detail(wabt_result, tools_result),
    )
    matrix.finish_case(passed)


def run_invalid_binary_case(
    matrix: Matrix,
    name: str,
    body: bytes,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    wasm = work_dir / f"{name}.wasm"
    wasm.write_bytes(module_with_body(body))
    wabt_result = run(
        (wabt, "module", "validate", "--enable-wide-arithmetic", wasm)
    )
    tools_result = run(
        (wasm_tools, "validate", f"--features={WIDE_FEATURE}", wasm)
    )
    passed = matrix.check(
        "invalid-binary",
        name,
        wabt_result.rejected and tools_result.rejected,
        pair_detail(wabt_result, tools_result),
    )
    matrix.finish_case(passed)


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
    if not version.accepted or not version.stdout.startswith(EXPECTED_WASM_TOOLS_VERSION):
        print(
            f"error: expected {EXPECTED_WASM_TOOLS_VERSION}, got "
            f"{version.stdout.strip() or version.summary()}",
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
    wast_result = run(
        (
            wasm_tools,
            "wast",
            "--color",
            "never",
            f"--features={WIDE_FEATURE}",
            SPEC_WAST,
        )
    )
    matrix.check(
        "proposal-wast",
        "wide-arithmetic.wast",
        wast_result.accepted,
        wast_result.summary(),
    )
    for name, wat in VALID_CASES.items():
        run_valid_case(matrix, name, wat, work_dir, wabt, wasm_tools)
    for name, wat in INVALID_WAT_CASES.items():
        run_invalid_wat_case(matrix, name, wat, work_dir, wabt, wasm_tools)
    for name, body in INVALID_BINARY_CASES.items():
        run_invalid_binary_case(matrix, name, body, work_dir, wabt, wasm_tools)

    matrix.report()
    failed = bool(matrix.mismatches)
    if args.keep_work or failed:
        print(f"Materialized matrix: {work_dir}")
    else:
        shutil.rmtree(work_dir)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
