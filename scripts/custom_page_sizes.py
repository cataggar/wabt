#!/usr/bin/env python3
"""Differentially validate custom memory page sizes with wasm-tools 1.250.0."""

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
DEFAULT_WORK_DIR = ROOT / "zig-out/custom-page-sizes-matrix"
EXPECTED_WASM_TOOLS_VERSION = "wasm-tools 1.250.0"
WASM_FEATURES = "-all,custom-page-sizes,memory64,multi-memory,threads"
WASM_FEATURES_DISABLED = "-all,memory64,multi-memory,threads"
WABT_FEATURE = "--enable-custom-page-sizes"


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


@dataclass(frozen=True)
class WatCase:
    name: str
    wat: str
    custom: bool
    page_one_count: int = 0
    page_default_count: int = 0


@dataclass(frozen=True)
class BinaryCase:
    name: str
    wasm: bytes
    custom: bool
    page_one_count: int = 0
    page_default_count: int = 0


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


def section(section_id: int, payload: bytes) -> bytes:
    return bytes((section_id,)) + uleb(len(payload)) + payload


def module(*sections: bytes) -> bytes:
    return b"\0asm\1\0\0\0" + b"".join(sections)


def limits(
    flags: int,
    minimum: int = 0,
    maximum: int | None = None,
    log2: bytes = b"",
) -> bytes:
    encoded = bytes((flags,)) + uleb(minimum)
    if flags & 0x01:
        assert maximum is not None
        encoded += uleb(maximum)
    return encoded + log2


def memories(*entries: bytes) -> bytes:
    return section(5, uleb(len(entries)) + b"".join(entries))


def imported_memory(entry: bytes) -> bytes:
    payload = uleb(1) + b"\1m\1n" + b"\2" + entry
    return section(2, payload)


VALID_WAT_CASES = (
    WatCase("implicit-default", "(module (memory $m 1))", False),
    WatCase("ordinary-table", "(module (table $t 1 2 funcref))", False),
    WatCase(
        "defined-named-memory32-page1",
        '(module (memory $m 1 (pagesize 1)) (export "m" (memory $m)))',
        True,
        page_one_count=1,
    ),
    WatCase(
        "defined-explicit-default",
        "(module (memory $m 1 (pagesize 65536)))",
        True,
        page_default_count=1,
    ),
    WatCase(
        "standalone-import-memory32",
        '(module (import "a" "b" (memory $m 0 4294967295 (pagesize 1))))',
        True,
        page_one_count=1,
    ),
    WatCase(
        "inline-import-memory64",
        '(module (memory $m (import "a" "b") i64 0 18446744073709551615 (pagesize 1)))',
        True,
        page_one_count=1,
    ),
    WatCase(
        "shared-memory32",
        "(module (memory $m 0 4294967295 shared (pagesize 1)))",
        True,
        page_one_count=1,
    ),
    WatCase(
        "shared-memory64-explicit-default",
        "(module (memory $m i64 0 281474976710656 shared (pagesize 65536)))",
        True,
        page_default_count=1,
    ),
    WatCase(
        "memory32-page1-upper-bound",
        "(module (memory 4294967295 (pagesize 1)))",
        True,
        page_one_count=1,
    ),
    WatCase(
        "memory32-default-upper-bound",
        "(module (memory 65536 (pagesize 65536)))",
        True,
        page_default_count=1,
    ),
    WatCase(
        "memory64-page1-upper-bound",
        "(module (memory i64 18446744073709551615 (pagesize 1)))",
        True,
        page_one_count=1,
    ),
    WatCase(
        "multiple-mixed-named",
        (
            "(module "
            "(memory $a 1 (pagesize 1)) "
            "(memory $b i64 281474976710656 (pagesize 65536)) "
            '(export "a" (memory $a)) (export "b" (memory $b)))'
        ),
        True,
        page_one_count=1,
        page_default_count=1,
    ),
    WatCase(
        "inline-data-page1",
        '(module (memory (pagesize 1) (data "xyz")))',
        True,
        page_one_count=1,
    ),
    WatCase(
        "inline-data-named-export-page1",
        (
            '(module (memory $m (export "m") '
            '(pagesize 1) (data "xyz")))'
        ),
        True,
        page_one_count=1,
    ),
    WatCase(
        "inline-data-export-memory64-page1",
        '(module (memory (export "m") i64 (pagesize 1) (data "x")))',
        True,
        page_one_count=1,
    ),
    WatCase(
        "inline-data-named-export-memory64-page1",
        (
            '(module (memory $m (export "m") i64 '
            '(pagesize 1) (data "x")))'
        ),
        True,
        page_one_count=1,
    ),
    WatCase(
        "inline-data-empty-explicit-default",
        '(module (memory (pagesize 65536) (data "")))',
        True,
        page_default_count=1,
    ),
)


INVALID_WAT_CASES = {
    "page-zero": "(module (memory 1 (pagesize 0)))",
    "page-two": "(module (memory 1 (pagesize 2)))",
    "page-three": "(module (memory 1 (pagesize 3)))",
    "page-intermediate-power": "(module (memory 1 (pagesize 32768)))",
    "page-non-power-upper": "(module (memory 1 (pagesize 65537)))",
    "page-u32-max": "(module (memory 1 (pagesize 4294967295)))",
    "page-u32-overflow": "(module (memory 1 (pagesize 4294967296)))",
    "defined-memory64-page-three": "(module (memory $m i64 1 (pagesize 3)))",
    "standalone-import-page-three": (
        '(module (import "a" "b" (memory $m 1 (pagesize 3))))'
    ),
    "inline-import-page-three": (
        '(module (memory $m (import "a" "b") 1 (pagesize 3)))'
    ),
    "shared-without-max": "(module (memory 1 shared (pagesize 1)))",
    "max-below-min": "(module (memory 2 1 shared (pagesize 1)))",
    "memory32-default-min-overflow": (
        "(module (memory 65537 (pagesize 65536)))"
    ),
    "memory32-default-max-overflow": (
        "(module (memory 0 65537 (pagesize 65536)))"
    ),
    "memory32-page1-count-overflow": (
        "(module (memory 4294967296 (pagesize 1)))"
    ),
    "memory64-default-count-overflow": (
        "(module (memory i64 281474976710657 (pagesize 65536)))"
    ),
    "memory64-count-u64-overflow": (
        "(module (memory i64 18446744073709551616 (pagesize 1)))"
    ),
    "multiple-second-invalid": (
        "(module (memory $a 1 (pagesize 1)) (memory $b 1 (pagesize 3)))"
    ),
    "table-page-size": "(module (table 1 (pagesize 1) funcref))",
    "shared-table-defined": "(module (table 0 1 shared funcref))",
    "shared-table-imported": (
        '(module (import "m" "t" (table 0 1 shared funcref)))'
    ),
    "page-size-before-shared": (
        "(module (memory 1 2 (pagesize 1) shared))"
    ),
    "duplicate-page-size": (
        "(module (memory 1 (pagesize 1) (pagesize 1)))"
    ),
    "inline-data-invalid-page-size": (
        '(module (memory (pagesize 2) (data "x")))'
    ),
    "inline-data-page-size-after-data": (
        '(module (memory (data "x") (pagesize 1)))'
    ),
    "inline-data-export-after-page-size": (
        '(module (memory (pagesize 1) (export "m") (data "x")))'
    ),
    "inline-data-export-after-memory64": (
        '(module (memory i64 (export "m") (data "x")))'
    ),
    "inline-data-memory64-after-page-size": (
        '(module (memory (pagesize 1) i64 (data "x")))'
    ),
    "inline-data-import-after-memory64": (
        '(module (memory i64 (import "m" "n") 1))'
    ),
    "inline-data-memory64-after-data": (
        '(module (memory (data "x") i64))'
    ),
}


VALID_BINARY_CASES = (
    BinaryCase(
        "binary-overlong-log2-zero",
        module(memories(limits(0x08, log2=b"\x80\x00"))),
        True,
        page_one_count=1,
    ),
    BinaryCase(
        "binary-explicit-default",
        module(memories(limits(0x08, log2=uleb(16)))),
        True,
        page_default_count=1,
    ),
    BinaryCase(
        "binary-implicit-default",
        module(memories(limits(0x00))),
        False,
    ),
    BinaryCase(
        "binary-imported-page1",
        module(imported_memory(limits(0x08, log2=uleb(0)))),
        True,
        page_one_count=1,
    ),
    BinaryCase(
        "binary-memory64-shared-page1",
        module(
            memories(
                limits(
                    0x0F,
                    minimum=0,
                    maximum=0xFFFFFFFFFFFFFFFF,
                    log2=uleb(0),
                )
            )
        ),
        True,
        page_one_count=1,
    ),
)


INVALID_BINARY_CASES = {
    "binary-log2-one": module(memories(limits(0x08, log2=uleb(1)))),
    "binary-log2-fifteen": module(memories(limits(0x08, log2=uleb(15)))),
    "binary-log2-seventeen": module(memories(limits(0x08, log2=uleb(17)))),
    "binary-log2-u32-max": module(
        memories(limits(0x08, log2=uleb(0xFFFFFFFF)))
    ),
    "binary-log2-overflow": module(
        memories(limits(0x08, log2=b"\x80\x80\x80\x80\x10"))
    ),
    "binary-memory32-limit-overflow": module(
        memories(b"\x00\x80\x80\x80\x80\x10")
    ),
    "binary-memory64-limit-overflow": module(
        memories(b"\x04" + b"\x80" * 9 + b"\x02")
    ),
    "binary-truncated-log2": module(memories(limits(0x08))),
    "binary-unknown-flags": module(memories(limits(0x10))),
    "binary-shared-without-max": module(
        memories(limits(0x0A, log2=uleb(0)))
    ),
    "binary-table-custom-page": module(
        section(4, b"\x01\x70" + limits(0x08, log2=uleb(0)))
    ),
    "binary-table-shared": module(
        section(4, b"\x01\x70" + limits(0x03, maximum=1))
    ),
    "binary-memory32-default-overflow": module(
        memories(limits(0x08, minimum=65537, log2=uleb(16)))
    ),
    "binary-memory64-default-overflow": module(
        memories(limits(0x0C, minimum=(1 << 48) + 1, log2=uleb(16)))
    ),
    "binary-import-log2-three": module(
        imported_memory(limits(0x08, log2=uleb(3)))
    ),
    "binary-multiple-second-invalid": module(
        memories(
            limits(0x08, log2=uleb(0)),
            limits(0x08, log2=uleb(1)),
        )
    ),
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
            "Custom page-size differential matrix: "
            f"{self.case_totals[0]}/{self.case_totals[1]} cases, "
            f"{passed}/{total} checks"
        )
        for phase, (phase_passed, phase_total) in sorted(
            self.phase_totals.items()
        ):
            print(f"  {phase}: {phase_passed}/{phase_total}")
        print("  accepted page sizes: 1, 65536 bytes")
        if self.mismatches:
            print("Mismatches:", file=sys.stderr)
            for mismatch in self.mismatches:
                print(f"  {mismatch}", file=sys.stderr)


def pair_detail(wabt_result: Result, tools_result: Result) -> str:
    return (
        f"wabt {wabt_result.summary()}; "
        f"wasm-tools {tools_result.summary()}"
    )


def marker_counts_ok(path: Path, page_one: int, page_default: int) -> bool:
    text = path.read_text(encoding="utf-8")
    return (
        text.count("(pagesize 0x1)") == page_one
        and text.count("(pagesize 0x10000)") == page_default
    )


def run_valid_paths(
    matrix: Matrix,
    name: str,
    source: Path,
    wasm: Path,
    printed: Path,
    reparsed: Path,
    custom: bool,
    page_one_count: int,
    page_default_count: int,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    passed = True
    wabt_enabled = run(
        (wabt, "text", "parse", WABT_FEATURE, source, "-o", wasm)
    )
    tools_enabled = run(
        (wasm_tools, "validate", f"--features={WASM_FEATURES}", source)
    )
    passed &= matrix.check(
        "wat-enabled",
        name,
        wabt_enabled.accepted and tools_enabled.accepted,
        pair_detail(wabt_enabled, tools_enabled),
    )

    disabled_wasm = wasm.with_name("disabled.wasm")
    wabt_disabled = run(
        (wabt, "text", "parse", source, "-o", disabled_wasm)
    )
    tools_disabled = run(
        (
            wasm_tools,
            "validate",
            f"--features={WASM_FEATURES_DISABLED}",
            source,
        )
    )
    disabled_ok = (
        wabt_disabled.rejected and tools_disabled.rejected
        if custom
        else wabt_disabled.accepted and tools_disabled.accepted
    )
    passed &= matrix.check(
        "wat-disabled",
        name,
        disabled_ok,
        pair_detail(wabt_disabled, tools_disabled),
    )

    if wabt_enabled.accepted:
        wabt_binary = run(
            (wabt, "module", "validate", WABT_FEATURE, wasm)
        )
        tools_binary = run(
            (wasm_tools, "validate", f"--features={WASM_FEATURES}", wasm)
        )
        passed &= matrix.check(
            "binary-enabled",
            name,
            wabt_binary.accepted and tools_binary.accepted,
            pair_detail(wabt_binary, tools_binary),
        )

        wabt_binary_disabled = run((wabt, "module", "validate", wasm))
        tools_binary_disabled = run(
            (
                wasm_tools,
                "validate",
                f"--features={WASM_FEATURES_DISABLED}",
                wasm,
            )
        )
        binary_disabled_ok = (
            wabt_binary_disabled.rejected and tools_binary_disabled.rejected
            if custom
            else (
                wabt_binary_disabled.accepted
                and tools_binary_disabled.accepted
            )
        )
        passed &= matrix.check(
            "binary-disabled",
            name,
            binary_disabled_ok,
            pair_detail(wabt_binary_disabled, tools_binary_disabled),
        )

        canonical_before = printed.with_name("canonical-before.wat")
        canonical_after = printed.with_name("canonical-after.wat")
        print_result = run((wabt, "text", "print", wasm, "-o", printed))
        marker_ok = (
            print_result.accepted
            and marker_counts_ok(
                printed, page_one_count, page_default_count
            )
        )
        tools_on_printed = (
            run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={WASM_FEATURES}",
                    printed,
                )
            )
            if print_result.accepted
            else print_result
        )
        reparse_result = (
            run(
                (
                    wabt,
                    "text",
                    "parse",
                    WABT_FEATURE,
                    printed,
                    "-o",
                    reparsed,
                )
            )
            if print_result.accepted
            else print_result
        )
        wabt_revalidate = (
            run((wabt, "module", "validate", WABT_FEATURE, reparsed))
            if reparse_result.accepted
            else reparse_result
        )
        tools_revalidate = (
            run(
                (
                    wasm_tools,
                    "validate",
                    f"--features={WASM_FEATURES}",
                    reparsed,
                )
            )
            if reparse_result.accepted
            else reparse_result
        )
        canonical_before_result = run(
            (wasm_tools, "print", wasm, "-o", canonical_before)
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
        roundtrip_ok = (
            marker_ok
            and tools_on_printed.accepted
            and reparse_result.accepted
            and wabt_revalidate.accepted
            and tools_revalidate.accepted
            and canonical_equal
        )
        passed &= matrix.check(
            "text-binary-roundtrip",
            name,
            roundtrip_ok,
            (
                f"print {print_result.summary()}; "
                f"reparse {reparse_result.summary()}; "
                f"marker counts ok={marker_ok}; "
                f"canonical equal={canonical_equal}"
            ),
        )
    else:
        for phase in (
            "binary-enabled",
            "binary-disabled",
            "text-binary-roundtrip",
        ):
            passed &= matrix.check(
                phase, name, False, "wabt did not produce a binary"
            )
    matrix.finish_case(bool(passed))


def run_valid_wat_case(
    matrix: Matrix,
    case: WatCase,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    case_dir = work_dir / case.name
    case_dir.mkdir()
    source = case_dir / "input.wat"
    source.write_text(case.wat, encoding="utf-8")
    run_valid_paths(
        matrix,
        case.name,
        source,
        case_dir / "wabt.wasm",
        case_dir / "printed.wat",
        case_dir / "reparsed.wasm",
        case.custom,
        case.page_one_count,
        case.page_default_count,
        wabt,
        wasm_tools,
    )


def run_valid_binary_case(
    matrix: Matrix,
    case: BinaryCase,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    case_dir = work_dir / case.name
    case_dir.mkdir()
    wasm = case_dir / "input.wasm"
    printed = case_dir / "printed.wat"
    reparsed = case_dir / "reparsed.wasm"
    wasm.write_bytes(case.wasm)

    passed = True
    wabt_enabled = run(
        (wabt, "module", "validate", WABT_FEATURE, wasm)
    )
    tools_enabled = run(
        (wasm_tools, "validate", f"--features={WASM_FEATURES}", wasm)
    )
    passed &= matrix.check(
        "valid-binary-enabled",
        case.name,
        wabt_enabled.accepted and tools_enabled.accepted,
        pair_detail(wabt_enabled, tools_enabled),
    )

    wabt_disabled = run((wabt, "module", "validate", wasm))
    tools_disabled = run(
        (
            wasm_tools,
            "validate",
            f"--features={WASM_FEATURES_DISABLED}",
            wasm,
        )
    )
    disabled_ok = (
        wabt_disabled.rejected and tools_disabled.rejected
        if case.custom
        else wabt_disabled.accepted and tools_disabled.accepted
    )
    passed &= matrix.check(
        "valid-binary-disabled",
        case.name,
        disabled_ok,
        pair_detail(wabt_disabled, tools_disabled),
    )

    print_result = run((wabt, "text", "print", wasm, "-o", printed))
    marker_ok = (
        print_result.accepted
        and marker_counts_ok(
            printed, case.page_one_count, case.page_default_count
        )
    )
    reparse_result = (
        run(
            (
                wabt,
                "text",
                "parse",
                WABT_FEATURE,
                printed,
                "-o",
                reparsed,
            )
        )
        if print_result.accepted
        else print_result
    )
    wabt_revalidate = (
        run((wabt, "module", "validate", WABT_FEATURE, reparsed))
        if reparse_result.accepted
        else reparse_result
    )
    tools_revalidate = (
        run(
            (
                wasm_tools,
                "validate",
                f"--features={WASM_FEATURES}",
                reparsed,
            )
        )
        if reparse_result.accepted
        else reparse_result
    )
    passed &= matrix.check(
        "valid-binary-roundtrip",
        case.name,
        (
            marker_ok
            and reparse_result.accepted
            and wabt_revalidate.accepted
            and tools_revalidate.accepted
        ),
        (
            f"print {print_result.summary()}; "
            f"reparse {reparse_result.summary()}; marker counts ok={marker_ok}"
        ),
    )
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
            WABT_FEATURE,
            source,
            "-o",
            work_dir / f"{name}.wasm",
        )
    )
    tools_result = run(
        (wasm_tools, "validate", f"--features={WASM_FEATURES}", source)
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
    wasm_bytes: bytes,
    work_dir: Path,
    wabt: Path,
    wasm_tools: Path,
) -> None:
    wasm = work_dir / f"{name}.wasm"
    wasm.write_bytes(wasm_bytes)
    wabt_result = run(
        (wabt, "module", "validate", WABT_FEATURE, wasm)
    )
    tools_result = run(
        (wasm_tools, "validate", f"--features={WASM_FEATURES}", wasm)
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
    parser.add_argument(
        "wasm_tools", type=Path, help="path to wasm-tools 1.250.0"
    )
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--keep-work", action="store_true")
    args = parser.parse_args()

    wabt = args.wabt.resolve(strict=True)
    wasm_tools = args.wasm_tools.resolve(strict=True)
    version = run((wasm_tools, "--version"))
    if (
        not version.accepted
        or not version.stdout.startswith(EXPECTED_WASM_TOOLS_VERSION)
    ):
        print(
            f"error: expected {EXPECTED_WASM_TOOLS_VERSION}, got "
            f"{version.stdout.strip() or version.summary()}",
            file=sys.stderr,
        )
        return 2

    work_dir = args.work_dir.resolve()
    allowed_root = (ROOT / "zig-out").resolve()
    if work_dir == allowed_root or allowed_root not in work_dir.parents:
        print(
            f"error: --work-dir must be below {allowed_root}",
            file=sys.stderr,
        )
        return 2
    shutil.rmtree(work_dir, ignore_errors=True)
    work_dir.mkdir(parents=True)

    matrix = Matrix()
    for case in VALID_WAT_CASES:
        run_valid_wat_case(matrix, case, work_dir, wabt, wasm_tools)
    for case in VALID_BINARY_CASES:
        run_valid_binary_case(matrix, case, work_dir, wabt, wasm_tools)
    for name, wat in INVALID_WAT_CASES.items():
        run_invalid_wat_case(
            matrix, name, wat, work_dir, wabt, wasm_tools
        )
    for name, wasm_bytes in INVALID_BINARY_CASES.items():
        run_invalid_binary_case(
            matrix, name, wasm_bytes, work_dir, wabt, wasm_tools
        )

    matrix.report()
    failed = bool(matrix.mismatches)
    if args.keep_work or failed:
        print(f"Materialized matrix: {work_dir}")
    else:
        shutil.rmtree(work_dir)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
