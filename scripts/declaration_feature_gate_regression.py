#!/usr/bin/env python3
"""Freeze wasm-tools 1.250.0 declaration and constant-expression gates."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


EXPECTED_WASM_TOOLS_VERSION = "wasm-tools 1.250.0"


@dataclass(frozen=True)
class Case:
    name: str
    features: str
    accepted: bool
    wat: str


@dataclass(frozen=True)
class BinaryCase:
    name: str
    accepted: bool
    hex: str


CASES = (
    Case("dead-v128-type", "all,-simd", False, "(module (type (func (param v128))))"),
    Case(
        "imported-v128-param",
        "all,-simd",
        False,
        '(module (import "m" "f" (func (param v128))))',
    ),
    Case("defined-v128-param", "all,-simd", False, "(module (func (param v128)))"),
    Case("v128-local", "all,-simd", False, "(module (func (local v128)))"),
    Case(
        "v128-global",
        "all,-simd",
        False,
        "(module (global v128 (v128.const i32x4 0 0 0 0)))",
    ),
    Case(
        "imported-v128-global",
        "all,-simd",
        False,
        '(module (import "m" "g" (global v128)))',
    ),
    Case(
        "v128-block-result",
        "all,-simd",
        False,
        "(module (func (block (result v128) unreachable) drop))",
    ),
    Case(
        "externref-table",
        "all,-reference-types",
        False,
        "(module (table 1 externref))",
    ),
    Case(
        "imported-externref-table",
        "all,-reference-types",
        False,
        '(module (import "m" "t" (table 1 externref)))',
    ),
    Case(
        "defined-table64",
        "all,-memory64",
        False,
        "(module (table i64 1 funcref))",
    ),
    Case(
        "imported-table64",
        "all,-memory64",
        False,
        '(module (import "m" "t" (table i64 1 funcref)))',
    ),
    Case(
        "ordinary-table32-without-memory64",
        "all,-memory64",
        True,
        "(module (table 1 funcref))",
    ),
    Case(
        "mvp-funcref-table",
        "all,-reference-types",
        True,
        "(module (table 1 funcref))",
    ),
    Case(
        "mvp-function-index-element",
        "all,-reference-types",
        True,
        "(module (func) (table 1 funcref) "
        "(elem (i32.const 0) func 0))",
    ),
    Case(
        "expression-element",
        "all,-reference-types",
        False,
        "(module (func) (elem funcref (ref.func 0)))",
    ),
    Case("tag", "all,-exceptions", False, "(module (tag))"),
    Case(
        "imported-tag",
        "all,-exceptions",
        False,
        '(module (import "m" "e" (tag)))',
    ),
    Case("tag-v128-param", "all,-simd", False, "(module (tag (param v128)))"),
    # wasm-tools permits tag result types. WABT's existing validator rejects
    # every non-empty tag result with TypeMismatch before proposal gates.
    Case(
        "tag-result",
        "all",
        True,
        "(module (type $t (func (result i32))) (tag (type $t)))",
    ),
    Case(
        "tag-v128-result",
        "all,-simd",
        False,
        "(module (type $t (func (result v128))) (tag (type $t)))",
    ),
    Case("dead-struct", "all,-gc", False, "(module (type (struct)))"),
    Case("dead-array", "all,-gc", False, "(module (type (array i32)))"),
    Case(
        "recursive-concrete-struct",
        "all,-gc",
        False,
        "(module (rec (type $s (struct (field (ref null $s))))))",
    ),
    Case(
        "recursive-func",
        "all,-gc",
        False,
        "(module (rec (type (func))))",
    ),
    Case(
        "function-subtype",
        "all,-gc",
        False,
        "(module (type $p (sub (func))) (type (sub $p (func))))",
    ),
    Case(
        "self-supertype",
        "all",
        False,
        "(module (type (sub 0 (func))))",
    ),
    Case(
        "forward-supertype",
        "all",
        False,
        "(module (type (sub 1 (func))) (type (sub (func))))",
    ),
    Case(
        "backward-supertype",
        "all",
        True,
        "(module (type (sub (func))) (type (sub 0 (func))))",
    ),
    Case(
        "recursive-group-backward-supertype",
        "all",
        True,
        "(module (rec (type (sub (func))) (type (sub 0 (func)))))",
    ),
    # wasm-tools treats a final subtype with no parent as an ordinary type.
    # WABT intentionally preserves and gates the explicit subtype declaration.
    Case(
        "final-subtype-without-parent",
        "all,-gc",
        True,
        "(module (type (sub final (func))))",
    ),
    Case(
        "nullable-abstract-func",
        "all,-function-references,-gc",
        True,
        "(module (type (func (param (ref null func)))))",
    ),
    Case(
        "nonnull-abstract-func",
        "all,-function-references",
        False,
        "(module (type (func (param (ref func)))))",
    ),
    Case(
        "concrete-func-via-gc",
        "all,-function-references",
        True,
        "(module (type $f (func)) "
        "(type (func (param (ref null $f)))))",
    ),
    Case(
        "concrete-func-disabled",
        "all,-function-references,-gc",
        False,
        "(module (type $f (func)) "
        "(type (func (param (ref null $f)))))",
    ),
    Case(
        "exception-ref-without-reference-types",
        "all,-reference-types",
        False,
        "(module (type (func (param exnref))))",
    ),
    Case(
        "exception-ref-without-exceptions",
        "all,-exceptions",
        False,
        "(module (type (func (param exnref))))",
    ),
    Case(
        "multi-result-function",
        "all,-multi-value",
        False,
        "(module (type (func (result i32 i64))))",
    ),
    Case(
        "block-parameter",
        "all,-multi-value",
        False,
        "(module (type $t (func (param i32))) "
        "(func i32.const 0 (block (type $t) drop)))",
    ),
    Case(
        "indexed-empty-block",
        "all,-multi-value",
        False,
        "(module (type $t (func)) (func (block (type $t))))",
    ),
    Case(
        "indexed-one-result-block",
        "all,-multi-value",
        False,
        "(module (type $t (func (result i32))) "
        "(func (block (type $t) i32.const 0) drop))",
    ),
    Case(
        "inline-one-result-block",
        "all,-multi-value",
        True,
        "(module (func (block (result i32) i32.const 0) drop))",
    ),
    Case(
        "self-recursive-function-type",
        "all,-gc",
        False,
        "(module (type $f (func (param (ref null $f)))))",
    ),
    Case(
        "backward-concrete-function-type",
        "all,-gc",
        True,
        "(module (type $a (func)) "
        "(type $b (func (param (ref null $a)))))",
    ),
    Case(
        "mutually-recursive-function-types",
        "all,-gc",
        False,
        "(module (rec "
        "(type $a (func (param (ref null $b)))) "
        "(type $b (func (param (ref null $a))))))",
    ),
    Case(
        "table-ref-null-initializer",
        "all,-function-references",
        False,
        "(module (table 1 funcref (ref.null func)))",
    ),
    Case(
        "table64-ref-null-initializer",
        "all",
        True,
        "(module (table i64 1 funcref (ref.null func)))",
    ),
    Case(
        "table64-ref-null-initializer-without-memory64",
        "all,-memory64",
        False,
        "(module (table i64 1 funcref (ref.null func)))",
    ),
    Case(
        "table-ref-func-initializer",
        "all,-function-references",
        False,
        "(module (func $f) (elem declare func $f) "
        "(table 1 funcref (ref.func $f)))",
    ),
    Case(
        "table-concrete-initializer",
        "all,-function-references",
        False,
        "(module (type $f (func)) "
        "(table 1 (ref null $f) (ref.null $f)))",
    ),
    Case(
        "ordinary-table-without-function-references",
        "all,-function-references",
        True,
        "(module (table 1 funcref))",
    ),
    Case(
        "imported-table-without-function-references",
        "all,-function-references",
        True,
        '(module (import "m" "t" (table 1 funcref)))',
    ),
    Case(
        "passive-function-index-element",
        "all,-bulk-memory",
        False,
        "(module (func) (elem func 0))",
    ),
    Case(
        "declared-function-index-element",
        "all,-bulk-memory",
        False,
        "(module (func) (elem declare func 0))",
    ),
    Case(
        "active-function-index-element-without-bulk",
        "all,-bulk-memory",
        True,
        "(module (func) (table 1 funcref) "
        "(elem (i32.const 0) func 0))",
    ),
    Case(
        "active-imported-table-element-without-bulk",
        "all,-bulk-memory",
        True,
        '(module (import "m" "t" (table 1 funcref)) (func) '
        "(elem (table 0) (i32.const 0) func 0))",
    ),
    Case(
        "active-expression-element-without-bulk",
        "all,-bulk-memory",
        True,
        "(module (table 1 funcref) "
        "(elem (i32.const 0) funcref (ref.null func)))",
    ),
    Case(
        "passive-expression-element-without-bulk",
        "all,-bulk-memory",
        False,
        "(module (elem funcref (ref.null func)))",
    ),
    Case(
        "declared-expression-element-without-bulk",
        "all,-bulk-memory",
        False,
        "(module (elem declare funcref (ref.null func)))",
    ),
    Case(
        "passive-data-without-bulk",
        "all,-bulk-memory",
        False,
        '(module (data "x"))',
    ),
    Case(
        "empty-passive-data-without-bulk",
        "all,-bulk-memory",
        False,
        '(module (data ""))',
    ),
    Case(
        "active-data-without-bulk",
        "all,-bulk-memory",
        True,
        '(module (memory 1) (data (i32.const 0) "x"))',
    ),
    Case(
        "indexed-active-data-without-bulk",
        "all,-bulk-memory",
        True,
        '(module (memory 1) (memory 1) '
        '(data (memory 1) (i32.const 0) "x"))',
    ),
    Case(
        "imported-mutable-global",
        "all,-mutable-global",
        False,
        '(module (import "m" "g" (global (mut i32))))',
    ),
    Case(
        "exported-mutable-global",
        "all,-mutable-global",
        False,
        '(module (global (export "g") (mut i32) (i32.const 0)))',
    ),
    Case(
        "defined-mutable-global",
        "all,-mutable-global",
        True,
        "(module (global (mut i32) (i32.const 0)))",
    ),
    Case(
        "ref-null-constant",
        "all,-reference-types",
        False,
        "(module (global funcref (ref.null func)))",
    ),
    Case(
        "ref-func-constant",
        "all,-reference-types",
        False,
        "(module (func $f) (elem declare func $f) "
        "(global funcref (ref.func $f)))",
    ),
    Case(
        "gc-constant",
        "all,-gc",
        False,
        "(module (global i31ref (ref.i31 (i32.const 0))))",
    ),
)

BINARY_CASES = (
    BinaryCase(
        "initialized-table-reserved-zero",
        True,
        "0061736d010000000409014000700001d0700b",
    ),
    BinaryCase(
        "initialized-table-reserved-one",
        False,
        "0061736d010000000409014001700001d0700b",
    ),
    BinaryCase(
        "initialized-table-reserved-truncated",
        False,
        "0061736d0100000004020140",
    ),
    BinaryCase(
        "initialized-table64-limits",
        True,
        "0061736d010000000409014000700401d0700b",
    ),
)


@dataclass(frozen=True)
class Result:
    returncode: int | None
    stdout: bytes
    stderr: bytes

    @property
    def accepted(self) -> bool:
        return self.returncode == 0

    def summary(self) -> str:
        output = (self.stderr or self.stdout).decode(errors="replace").strip()
        return output.splitlines()[-1] if output else f"exit {self.returncode}"


def run(argv: Sequence[Path | str], input_: bytes | None = None) -> Result:
    try:
        completed = subprocess.run(
            tuple(str(arg) for arg in argv),
            input=input_,
            check=False,
            capture_output=True,
            env={**os.environ, "NO_COLOR": "1"},
        )
    except OSError as error:
        return Result(None, b"", str(error).encode())
    return Result(completed.returncode, completed.stdout, completed.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wasm_tools", type=Path, help="path to wasm-tools 1.250.0")
    args = parser.parse_args()

    wasm_tools = args.wasm_tools.resolve(strict=True)
    version = run((wasm_tools, "--version"))
    if not version.accepted or not version.stdout.decode().startswith(
        EXPECTED_WASM_TOOLS_VERSION
    ):
        print(
            f"error: expected {EXPECTED_WASM_TOOLS_VERSION}, got {version.summary()}",
            file=sys.stderr,
        )
        return 2

    passed = 0
    total = 0
    mismatches: list[str] = []
    for case in CASES:
        wat = case.wat.encode()
        wat_result = run(
            (wasm_tools, "validate", f"--features={case.features}", "-"),
            wat,
        )
        total += 1
        if wat_result.accepted == case.accepted:
            passed += 1
        else:
            mismatches.append(
                f"{case.name} [wat]: expected accepted={case.accepted}, "
                f"got {wat_result.summary()}"
            )

        parsed = run((wasm_tools, "parse", "-"), wat)
        binary_result = (
            run(
                (wasm_tools, "validate", f"--features={case.features}", "-"),
                parsed.stdout,
            )
            if parsed.accepted
            else parsed
        )
        total += 1
        if parsed.accepted and binary_result.accepted == case.accepted:
            passed += 1
        else:
            mismatches.append(
                f"{case.name} [binary]: parse {parsed.summary()}; "
                f"validate {binary_result.summary()}"
            )

    for case in BINARY_CASES:
        result = run(
            (wasm_tools, "validate", "--features=all", "-"),
            bytes.fromhex(case.hex),
        )
        total += 1
        if result.accepted == case.accepted:
            passed += 1
        else:
            mismatches.append(
                f"{case.name} [raw-binary]: expected accepted={case.accepted}, "
                f"got {result.summary()}"
            )

    case_count = len(CASES) + len(BINARY_CASES)
    failed_cases = {m.split(" [")[0] for m in mismatches}
    print(
        f"Declaration/constant wasm-tools oracle: "
        f"{case_count - len(failed_cases)}/{case_count} "
        f"cases, {passed}/{total} checks"
    )
    if mismatches:
        print("Mismatches:", file=sys.stderr)
        for mismatch in mismatches:
            print(f"  {mismatch}", file=sys.stderr)
    return 1 if mismatches else 0


if __name__ == "__main__":
    raise SystemExit(main())
