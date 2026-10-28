#!/usr/bin/env python3
"""Runtime and CLI regression suite for `wabt module optimize`.

Validates that `wabt module optimize` preserves observable WebAssembly
semantics (return values, side effects, host imports, start functions, and
traps) when executed under Wasmtime, enforces CLI safety/policy rules, and
reports binary size reductions across a representative corpus.

Run via `zig build optimize-regression` (preferred) or directly:

    python3 scripts/optimize_regression.py --wabt <path-to-wabt>
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class CmdResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def combined(self) -> str:
        return (self.stdout or "") + (self.stderr or "")


@dataclass(frozen=True)
class Invocation:
    export: str
    args: tuple[str, ...] = ()
    expected_stdout: tuple[str, ...] | None = None
    expected_trap: str | None = None


@dataclass(frozen=True)
class BehavioralFixture:
    name: str
    category: str
    wat: str
    invocations: tuple[Invocation, ...]
    companion_wat: str | None = None
    companion_name: str = "host"
    expect_shrink: bool = True
    optimize_flags: tuple[str, ...] = ()


@dataclass
class SizeRecord:
    name: str
    category: str
    before_bytes: int
    after_bytes: int

    @property
    def delta(self) -> int:
        return self.after_bytes - self.before_bytes

    @property
    def pct(self) -> float:
        if self.before_bytes == 0:
            return 0.0
        return (self.delta / self.before_bytes) * 100.0


def run_cmd(argv: Sequence[Path | str]) -> CmdResult:
    cmd = tuple(str(a) for a in argv)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "NO_COLOR": "1"},
    )
    return CmdResult(cmd, proc.returncode, proc.stdout or "", proc.stderr or "")


def resolve_wasmtime(explicit: str | None) -> str | None:
    cand = explicit or os.environ.get("WASMTIME") or "wasmtime"
    found = shutil.which(cand) or (cand if os.path.isfile(cand) else None)
    if not found:
        return None
    res = run_cmd([found, "--version"])
    return found if res.returncode == 0 else None


def extract_trap_line(stderr: str) -> str | None:
    for line in stderr.splitlines():
        idx = line.find("wasm trap:")
        if idx != -1:
            return line[idx:].strip()
    return None


def uleb(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            byte |= 0x80
        out.append(byte)
        if not value:
            return bytes(out)


def make_custom_section(name: str, payload: bytes) -> bytes:
    name_bytes = name.encode("utf-8")
    body = uleb(len(name_bytes)) + name_bytes + payload
    return b"\x00" + uleb(len(body)) + body


FIXTURES: tuple[BehavioralFixture, ...] = (
    BehavioralFixture(
        name="const-fold-i32",
        category="constant-folding",
        expect_shrink=True,
        wat="""
(module
  (func (export "arith_wrap") (result i32)
    ;; (0x7fffffff + 1) ^ ((0x80000000 - 1) + (65536 * 65536))
    ;; = -2147483648 ^ (2147483647 + 0) = -1
    (i32.xor
      (i32.add (i32.const 0x7fffffff) (i32.const 1))
      (i32.add
        (i32.sub (i32.const 0x80000000) (i32.const 1))
        (i32.mul (i32.const 65536) (i32.const 65536)))))

  (func (export "bitops_shifts") (result i32)
    ;; Bitwise & masked shifts/rotates with shift counts >= 32
    (i32.add
      (i32.xor
        (i32.or (i32.const 0xf0a0) (i32.const 0x0f05))
        (i32.and (i32.const 0xffff) (i32.const 0x5555)))
      (i32.add
        (i32.add
          (i32.shl (i32.const 3) (i32.const 36))
          (i32.shr_s (i32.const -64) (i32.const 35)))
        (i32.add
          (i32.shr_u (i32.const 0x80000000) (i32.const 63))
          (i32.rotl
            (i32.rotr (i32.const 0x12345678) (i32.const 40))
            (i32.const 8))))))

  (func (export "unary_ops") (result i32)
    (i32.add
      (i32.add
        (i32.sub (i32.eqz (i32.const 0)) (i32.eqz (i32.const 99)))
        (i32.add (i32.clz (i32.const 0x00010000)) (i32.ctz (i32.const 0x00080000))))
      (i32.add
        (i32.popcnt (i32.const 0x0f0f0f0f))
        (i32.add
          (i32.extend8_s (i32.const 0x00000080))
          (i32.extend16_s (i32.const 0x0000ff80))))))

  (func (export "comparisons") (result i32)
    ;; Pack 10 boolean comparison results into a 10-bit mask:
    ;; bit0: eq(7,7)=1
    ;; bit1: ne(7,8)=1
    ;; bit2: lt_s(-1,1)=1
    ;; bit3: lt_u(-1,1)=0
    ;; bit4: gt_s(1,-1)=1
    ;; bit5: gt_u(-1,1)=1
    ;; bit6: le_s(-1,-1)=1
    ;; bit7: le_u(1,-1)=1
    ;; bit8: ge_s(-2,-1)=0
    ;; bit9: ge_u(-1,1)=1
    ;; mask = 1 + 2 + 4 + 0 + 16 + 32 + 64 + 128 + 0 + 512 = 759
    (i32.or
      (i32.or
        (i32.or
          (i32.eq (i32.const 7) (i32.const 7))
          (i32.shl (i32.ne (i32.const 7) (i32.const 8)) (i32.const 1)))
        (i32.or
          (i32.shl (i32.lt_s (i32.const -1) (i32.const 1)) (i32.const 2))
          (i32.shl (i32.lt_u (i32.const -1) (i32.const 1)) (i32.const 3))))
      (i32.or
        (i32.or
          (i32.shl (i32.gt_s (i32.const 1) (i32.const -1)) (i32.const 4))
          (i32.shl (i32.gt_u (i32.const -1) (i32.const 1)) (i32.const 5)))
        (i32.or
          (i32.or
            (i32.shl (i32.le_s (i32.const -1) (i32.const -1)) (i32.const 6))
            (i32.shl (i32.le_u (i32.const 1) (i32.const -1)) (i32.const 7)))
          (i32.or
            (i32.shl (i32.ge_s (i32.const -2) (i32.const -1)) (i32.const 8))
            (i32.shl (i32.ge_u (i32.const -1) (i32.const 1)) (i32.const 9)))))))
)
""",
        invocations=(
            Invocation("arith_wrap", expected_stdout=("-1",)),
            Invocation("bitops_shifts", expected_stdout=("305463697",)),
            Invocation("unary_ops", expected_stdout=("-205",)),
            Invocation("comparisons", expected_stdout=("759",)),
        ),
    ),
    BehavioralFixture(
        name="const-fold-i64",
        category="constant-folding",
        expect_shrink=True,
        wat="""
(module
  (func (export "arith64_wrap") (result i64)
    ;; (0x7fffffffffffffff + 1) ^ ((0x8000000000000000 - 1) + (0x100000000 * 0x100000000))
    ;; = -1
    (i64.xor
      (i64.add (i64.const 0x7fffffffffffffff) (i64.const 1))
      (i64.add
        (i64.sub (i64.const 0x8000000000000000) (i64.const 1))
        (i64.mul (i64.const 0x100000000) (i64.const 0x100000000)))))

  (func (export "bitops_shifts64") (result i64)
    (i64.add
      (i64.xor
        (i64.or (i64.const 0xf0f000000000) (i64.const 0x0f0f00000000))
        (i64.and (i64.const 0xffff00000000) (i64.const 0x555500000000)))
      (i64.add
        (i64.add
          (i64.shl (i64.const 5) (i64.const 68))
          (i64.shr_s (i64.const -128) (i64.const 67)))
        (i64.add
          (i64.shr_u (i64.const 0x8000000000000000) (i64.const 127))
          (i64.rotl
            (i64.rotr (i64.const 0x0102030405060708) (i64.const 72))
            (i64.const 8))))))

  (func (export "unary64_ops") (result i64)
    (i64.add
      (i64.extend_i32_s
        (i32.sub (i64.eqz (i64.const 0)) (i64.eqz (i64.const 1))))
      (i64.add
        (i64.add (i64.clz (i64.const 1)) (i64.ctz (i64.const 32)))
        (i64.add
          (i64.popcnt (i64.const 0xff00ff00))
          (i64.add
            (i64.extend8_s (i64.const 0x80))
            (i64.add
              (i64.extend16_s (i64.const 0x8000))
              (i64.extend32_s (i64.const 0x80000000))))))))

  (func (export "comparisons64") (result i32)
    ;; bit0: eq=1, bit1: ne=1, bit2: lt_s=1, bit3: lt_u=0, bit4: gt_s=1,
    ;; bit5: gt_u=1, bit6: le_s=1, bit7: le_u=1, bit8: ge_s=0, bit9: ge_u=1 -> 759
    (i32.or
      (i32.or
        (i32.or
          (i64.eq (i64.const 42) (i64.const 42))
          (i32.shl (i64.ne (i64.const 42) (i64.const 43)) (i32.const 1)))
        (i32.or
          (i32.shl (i64.lt_s (i64.const -10) (i64.const 10)) (i32.const 2))
          (i32.shl (i64.lt_u (i64.const -10) (i64.const 10)) (i32.const 3))))
      (i32.or
        (i32.or
          (i32.shl (i64.gt_s (i64.const 10) (i64.const -10)) (i32.const 4))
          (i32.shl (i64.gt_u (i64.const -10) (i64.const 10)) (i32.const 5)))
        (i32.or
          (i32.or
            (i32.shl (i64.le_s (i64.const -10) (i64.const -10)) (i32.const 6))
            (i32.shl (i64.le_u (i64.const 10) (i64.const -10)) (i32.const 7)))
          (i32.or
            (i32.shl (i64.ge_s (i64.const -20) (i64.const -10)) (i32.const 8))
            (i32.shl (i64.ge_u (i64.const -10) (i64.const 10)) (i32.const 9)))))))
)
""",
        invocations=(
            Invocation("arith64_wrap", expected_stdout=("-1",)),
            Invocation("bitops_shifts64", expected_stdout=("72811506911545161",)),
            Invocation("unary64_ops", expected_stdout=("-2147516459",)),
            Invocation("comparisons64", expected_stdout=("759",)),
        ),
    ),
    BehavioralFixture(
        name="control-flow-simplification",
        category="control-flow",
        expect_shrink=True,
        wat="""
(module
  (type $pair (func (result i32 i32)))
  (global $side (mut i32) (i32.const 0))

  (func (export "const_if_branches") (result i32)
    (nop)
    (block
      (nop))
    (if (i32.const 0)
      (then (global.set $side (i32.const 999))))
    (if (i32.const 1)
      (then (global.set $side (i32.const 10))))
    (i32.add
      (global.get $side)
      (i32.add
        (if (result i32) (i32.const 5)
          (then (i32.add (i32.const 11) (i32.const 21)))
          (else (i32.const 500)))
        (if (result i32) (i32.const 0)
          (then (i32.const 600))
          (else (i32.sub (i32.const 20) (i32.const 12)))))))

  (func (export "nested_if_self_and_outer_br") (param i32) (result i32)
    (block $outer (result i32)
      ;; Truthy constant-if with branches targeting inner (0), the if itself (1), and $outer (2)
      (if (result i32) (i32.const 1)
        (then
          (drop
            (block $inner (result i32)
              (i32.const 300)
              (local.get 0)
              (br_table 0 1 2 0)))
          (i32.const 100)
          (br_if 0 (i32.eq (local.get 0) (i32.const 0)))
          (drop)
          (i32.const 200))
        (else
          (i32.const 999)))
      (i32.const 5)
      (i32.add)))

  (func (export "const_br_if_and_empty_blocks") (result i32)
    (block (result i32)
      (block)
      (nop)
      (i32.const 11)
      (br_if 0 (i32.const 0))
      (drop)
      (i32.const 77)
      (br_if 0 (i32.const 9))
      (drop)
      (i32.const 88)))

  (func (export "multivalue_if") (type $pair) (result i32 i32)
    (if (type $pair) (i32.const 0)
      (then (i32.const 1) (i32.const 2))
      (else
        (i32.add (i32.const 30) (i32.const 12))
        (i32.mul (i32.const 100) (i32.const 3)))))
)
""",
        invocations=(
            Invocation("const_if_branches", expected_stdout=("50",)),
            Invocation("nested_if_self_and_outer_br", args=("0",), expected_stdout=("105",)),
            Invocation("nested_if_self_and_outer_br", args=("1",), expected_stdout=("305",)),
            Invocation("nested_if_self_and_outer_br", args=("2",), expected_stdout=("300",)),
            Invocation("nested_if_self_and_outer_br", args=("3",), expected_stdout=("205",)),
            Invocation("const_br_if_and_empty_blocks", expected_stdout=("77",)),
            Invocation("multivalue_if", expected_stdout=("42", "300")),
        ),
    ),
    BehavioralFixture(
        name="dead-code-elimination",
        category="dead-code",
        expect_shrink=True,
        wat="""
(module
  (memory 1)
  (global $g (mut i32) (i32.const 0))

  (func $record_call (param i32)
    (global.set $g (i32.add (global.get $g) (local.get 0))))

  (func $after_return_and_br_impl (param i32) (result i32)
    (call $record_call (i32.const 5))
    (i32.store (i32.const 0) (i32.const 40))
    (if (result i32) (local.get 0)
      (then
        (call $record_call (i32.const 2))
        (return (i32.add (global.get $g) (i32.load (i32.const 0))))
        (global.set $g (i32.const 9999))
        (i32.store (i32.const 0) (i32.const 8888))
        (i32.const -1))
      (else
        (block $b (result i32)
          (i32.store (i32.const 4) (i32.const 13))
          (br $b (i32.add (global.get $g) (i32.load (i32.const 4))))
          (global.set $g (i32.const 7777))
          (i32.const -2))))
    (return)
    (global.set $g (i32.const 6666))
    (i32.const -3))

  (func (export "after_return_and_br") (param i32) (result i32)
    (call $after_return_and_br_impl (local.get 0)))

  (func (export "after_br_table") (param i32) (result i32)
    (block $out (result i32)
      (block $mid (result i32)
        (i32.const 90)
        (local.get 0)
        (br_table $mid $out $mid)
        (global.set $g (i32.const 5555))
        (i32.const 1234))
      (i32.add (i32.const 9))))

  (func (export "run_and_read_state") (result i32)
    (drop (call $after_return_and_br_impl (i32.const 1)))
    (drop (call $after_return_and_br_impl (i32.const 0)))
    (i32.add
      (global.get $g)
      (i32.add (i32.load (i32.const 0)) (i32.load (i32.const 4)))))
)
""",
        invocations=(
            Invocation("after_return_and_br", args=("1",), expected_stdout=("47",)),
            Invocation("after_return_and_br", args=("0",), expected_stdout=("18",)),
            Invocation("after_br_table", args=("0",), expected_stdout=("99",)),
            Invocation("after_br_table", args=("1",), expected_stdout=("90",)),
            Invocation("run_and_read_state", expected_stdout=("65",)),
        ),
    ),
    BehavioralFixture(
        name="dead-func-and-remap",
        category="dead-function-removal",
        expect_shrink=True,
        companion_name="host",
        companion_wat="""
(module
  (func (export "add_bias") (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 100)))
  (func (export "scale") (param i32) (result i32)
    (i32.mul (local.get 0) (i32.const 3)))
)
""",
        wat="""
(module
  (type $unary (func (param i32) (result i32)))
  (import "host" "add_bias" (func $imp_bias (param i32) (result i32)))
  (import "host" "scale" (func $imp_scale (param i32) (result i32)))

  (table $tab 4 funcref)
  (memory 1)
  (global $boot_val (mut i32) (i32.const 0))
  (global $gref funcref (ref.func $from_global_ref))

  (start $on_start)

  ;; Active element segment at slot 0
  (elem (i32.const 0) func $from_active_elem)
  ;; Passive element segment loaded dynamically via table.init
  (elem $passive_seg func $from_passive_elem)
  ;; Declared element segment enabling ref.func in code
  (elem declare func $from_declared_ref)

  (func $dead_unused_0 (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 1111)))

  (func $on_start
    (global.set $boot_val (call $start_helper (i32.const 7)))
    (i32.store (i32.const 0) (global.get $boot_val)))

  (func $dead_unused_chain_a (result i32)
    (call $dead_unused_chain_b))

  (func $dead_unused_chain_b (result i32)
    (call $dead_unused_0 (i32.const 2222)))

  (func $start_helper (param i32) (result i32)
    (call $imp_bias (local.get 0)))

  (func $from_active_elem (type $unary) (param i32) (result i32)
    (i32.add (call $imp_scale (local.get 0)) (i32.const 1)))

  (func $from_passive_elem (type $unary) (param i32) (result i32)
    (i32.add (call $imp_bias (local.get 0)) (i32.const 2)))

  (func $from_declared_ref (type $unary) (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 30)))

  (func $from_global_ref (type $unary) (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 40)))

  (func $dead_from_folded_if (param i32) (result i32)
    (i32.add (local.get 0) (i32.const 9999)))

  (func $tail_callee (param i32) (result i32)
    (call $imp_scale (i32.add (local.get 0) (global.get $boot_val))))

  (func (export "check_start") (result i32)
    (i32.add (global.get $boot_val) (i32.load (i32.const 0))))

  (func (export "run_direct_and_tail") (param i32) (result i32)
    (if (result i32) (i32.eq (i32.const 10) (i32.const 20))
      (then (call $dead_from_folded_if (local.get 0)))
      (else (return_call $tail_callee (local.get 0)))))

  (func (export "run_table_dispatches") (param i32) (result i32)
    ;; Slot 0 is already $from_active_elem; populate slots 1, 2, 3 from passive, declared, and global ref.func
    (table.init $tab $passive_seg (i32.const 1) (i32.const 0) (i32.const 1))
    (table.set $tab (i32.const 2) (ref.func $from_declared_ref))
    (table.set $tab (i32.const 3) (global.get $gref))
    (i32.add
      (i32.add
        (call_indirect $tab (type $unary) (local.get 0) (i32.const 0))
        (call_indirect $tab (type $unary) (local.get 0) (i32.const 1)))
      (i32.add
        (call_indirect $tab (type $unary) (local.get 0) (i32.const 2))
        (call_indirect $tab (type $unary) (local.get 0) (i32.const 3)))))
)
""",
        invocations=(
            Invocation("check_start", expected_stdout=("214",)),
            Invocation("run_direct_and_tail", args=("5",), expected_stdout=("336",)),
            Invocation("run_table_dispatches", args=("10",), expected_stdout=("233",)),
        ),
    ),
    BehavioralFixture(
        name="preserved-traps-and-effects",
        category="traps-and-effects",
        expect_shrink=True,
        wat="""
(module
  (memory 1)
  (global $state (mut i32) (i32.const 10))
  (start $init)

  (func $dead_helper (result i32)
    (i32.const 424242))

  (func $init
    (global.set $state (i32.add (global.get $state) (i32.add (i32.const 2) (i32.const 3))))
    (i32.store (i32.const 8) (i32.const 77)))

  (func (export "read_initialized") (result i32)
    (i32.add (global.get $state) (i32.load (i32.const 8))))

  (func (export "trap_div_s_zero") (result i32)
    (i32.div_s (i32.add (i32.const 10) (i32.const 5)) (i32.const 0)))

  (func (export "trap_div_u_zero") (result i32)
    (i32.div_u (i32.const 15) (i32.sub (i32.const 4) (i32.const 4))))

  (func (export "trap_rem_s_zero64") (result i64)
    (i64.rem_s (i64.const 99) (i64.const 0)))

  (func (export "trap_div_s_overflow") (result i32)
    (i32.div_s (i32.const -2147483648) (i32.const -1)))

  (func (export "trap_oob_load") (result i32)
    (i32.load (i32.const 65536)))

  (func (export "trap_oob_store")
    (i32.store (i32.const 65536) (i32.const 1)))

  (func (export "trap_unreachable_after_effect") (result i32)
    (global.set $state (i32.const 99))
    (i32.store (i32.const 0) (i32.const 55))
    (unreachable)
    (i32.const 0))
)
""",
        invocations=(
            Invocation("read_initialized", expected_stdout=("92",)),
            Invocation("trap_div_s_zero", expected_trap="integer divide by zero"),
            Invocation("trap_div_u_zero", expected_trap="integer divide by zero"),
            Invocation("trap_rem_s_zero64", expected_trap="integer divide by zero"),
            Invocation("trap_div_s_overflow", expected_trap="integer overflow"),
            Invocation("trap_oob_load", expected_trap="out of bounds memory access"),
            Invocation("trap_oob_store", expected_trap="out of bounds memory access"),
            Invocation("trap_unreachable_after_effect", expected_trap="unreachable"),
        ),
    ),
)


def run_behavioral_fixture(
    fixture: BehavioralFixture,
    work_dir: Path,
    wabt: Path,
    wasmtime: str,
    sizes: list[SizeRecord],
    failures: list[str],
) -> bool:
    case_dir = work_dir / fixture.name
    case_dir.mkdir(parents=True, exist_ok=True)

    wat_path = case_dir / f"{fixture.name}.wat"
    before_wasm = case_dir / "before.wasm"
    after_wasm = case_dir / "after.wasm"
    wat_path.write_text(fixture.wat.strip() + "\n", encoding="utf-8")

    preload_args: list[str] = []
    if fixture.companion_wat is not None:
        comp_wat = case_dir / f"{fixture.companion_name}.wat"
        comp_wasm = case_dir / f"{fixture.companion_name}.wasm"
        comp_wat.write_text(fixture.companion_wat.strip() + "\n", encoding="utf-8")
        comp_parse = run_cmd([wabt, "text", "parse", comp_wat, "-o", comp_wasm])
        if comp_parse.returncode != 0:
            failures.append(
                f"{fixture.name}: companion parse failed ({comp_parse.returncode}):\n{comp_parse.combined.strip()}"
            )
            return False
        preload_args = ["--preload", f"{fixture.companion_name}={comp_wasm}"]

    parse_res = run_cmd([wabt, "text", "parse", wat_path, "-o", before_wasm])
    if parse_res.returncode != 0:
        failures.append(
            f"{fixture.name}: `wabt text parse` failed ({parse_res.returncode}):\n{parse_res.combined.strip()}"
        )
        return False

    opt_res = run_cmd(
        [wabt, "module", "optimize", *fixture.optimize_flags, before_wasm, "-o", after_wasm]
    )
    if opt_res.returncode != 0:
        failures.append(
            f"{fixture.name}: `wabt module optimize` failed ({opt_res.returncode}):\n{opt_res.combined.strip()}"
        )
        return False

    val_res = run_cmd([wabt, "module", "validate", after_wasm])
    if val_res.returncode != 0:
        failures.append(
            f"{fixture.name}: `wabt module validate` failed on after.wasm ({val_res.returncode}):\n{val_res.combined.strip()}"
        )
        return False

    before_size = before_wasm.stat().st_size
    after_size = after_wasm.stat().st_size
    sizes.append(SizeRecord(fixture.name, fixture.category, before_size, after_size))

    if fixture.expect_shrink and not (after_size < before_size):
        failures.append(
            f"{fixture.name}: expected optimized binary to shrink, got {before_size} -> {after_size} bytes"
        )
        return False

    ok = True
    for inv in fixture.invocations:
        before_cmd = [
            wasmtime,
            "run",
            *preload_args,
            "--invoke",
            inv.export,
            str(before_wasm),
            *inv.args,
        ]
        after_cmd = [
            wasmtime,
            "run",
            *preload_args,
            "--invoke",
            inv.export,
            str(after_wasm),
            *inv.args,
        ]
        before_run = run_cmd(before_cmd)
        after_run = run_cmd(after_cmd)

        label = f"{fixture.name}::{inv.export}({', '.join(inv.args)})"
        if before_run.returncode != after_run.returncode:
            failures.append(
                f"{label}: exit status mismatch: before={before_run.returncode}, after={after_run.returncode}\n"
                f"--- before ---\n{before_run.combined.strip()}\n"
                f"--- after ---\n{after_run.combined.strip()}"
            )
            ok = False
            continue

        if inv.expected_trap is not None:
            if before_run.returncode == 0:
                failures.append(f"{label}: expected trap '{inv.expected_trap}', but execution succeeded")
                ok = False
                continue
            before_trap = extract_trap_line(before_run.stderr)
            after_trap = extract_trap_line(after_run.stderr)
            if before_trap is None or after_trap is None or before_trap != after_trap:
                failures.append(
                    f"{label}: trap line mismatch: before={before_trap!r}, after={after_trap!r}\n"
                    f"--- before stderr ---\n{before_run.stderr.strip()}\n"
                    f"--- after stderr ---\n{after_run.stderr.strip()}"
                )
                ok = False
                continue
            if inv.expected_trap not in after_trap:
                failures.append(
                    f"{label}: expected trap containing {inv.expected_trap!r}, got {after_trap!r}"
                )
                ok = False
                continue
        else:
            if before_run.returncode != 0:
                failures.append(
                    f"{label}: unexpected non-zero exit ({before_run.returncode}):\n{before_run.combined.strip()}"
                )
                ok = False
                continue
            if before_run.stdout != after_run.stdout:
                failures.append(
                    f"{label}: stdout mismatch:\n"
                    f"  before: {before_run.stdout.strip()!r}\n"
                    f"  after:  {after_run.stdout.strip()!r}"
                )
                ok = False
                continue
            if inv.expected_stdout is not None:
                actual_lines = tuple(
                    line.strip() for line in after_run.stdout.strip().splitlines() if line.strip()
                )
                if actual_lines != inv.expected_stdout:
                    failures.append(
                        f"{label}: expected stdout {inv.expected_stdout!r}, got {actual_lines!r}"
                    )
                    ok = False
                    continue

    return ok


def run_policy_and_cli_checks(
    work_dir: Path,
    wabt: Path,
    wasmtime: str,
    sizes: list[SizeRecord],
    failures: list[str],
) -> tuple[int, int]:
    policy_dir = work_dir / "policy-checks"
    policy_dir.mkdir(parents=True, exist_ok=True)
    passed = 0
    total = 0

    def record(name: str, cond: bool, detail: str) -> None:
        nonlocal passed, total
        total += 1
        if cond:
            passed += 1
            print(f"  PASS policy/{name}")
        else:
            failures.append(f"policy/{name}: {detail}")
            print(f"  FAIL policy/{name}")

    # 1. Custom section rejected without --strip-custom, accepted with --strip-custom
    base_wat = policy_dir / "custom_base.wat"
    base_wasm = policy_dir / "custom_base.wasm"
    custom_wasm = policy_dir / "with_custom.wasm"
    rejected_out = policy_dir / "rejected_custom_out.wasm"
    stripped_out = policy_dir / "stripped_custom_out.wasm"
    base_wat.write_text(
        '(module (func $dead (result i32) (i32.const 99)) '
        '(func (export "answer") (result i32) (i32.add (i32.const 19) (i32.const 23))))\n',
        encoding="utf-8",
    )
    parse_res = run_cmd([wabt, "text", "parse", base_wat, "-o", base_wasm])
    if parse_res.returncode != 0:
        record("custom-section-reject", False, f"setup parse failed: {parse_res.combined.strip()}")
    else:
        custom_wasm.write_bytes(
            base_wasm.read_bytes() + make_custom_section("producer_meta", b"custom-payload-bytes")
        )
        reject_res = run_cmd([wabt, "module", "optimize", custom_wasm, "-o", rejected_out])
        record(
            "custom-section-reject",
            reject_res.returncode != 0 and not rejected_out.exists(),
            f"expected non-zero exit and no output file, got exit={reject_res.returncode}, exists={rejected_out.exists()}",
        )

        strip_res = run_cmd(
            [wabt, "module", "optimize", "--strip-custom", custom_wasm, "-o", stripped_out]
        )
        val_res = (
            run_cmd([wabt, "module", "validate", stripped_out])
            if strip_res.returncode == 0 and stripped_out.exists()
            else strip_res
        )
        before_exec = run_cmd([wasmtime, "run", "--invoke", "answer", custom_wasm])
        after_exec = (
            run_cmd([wasmtime, "run", "--invoke", "answer", stripped_out])
            if strip_res.returncode == 0 and stripped_out.exists()
            else strip_res
        )
        if strip_res.returncode == 0 and stripped_out.exists():
            sizes.append(
                SizeRecord(
                    "custom-section-strip",
                    "policy",
                    custom_wasm.stat().st_size,
                    stripped_out.stat().st_size,
                )
            )
        record(
            "custom-section-strip",
            strip_res.returncode == 0
            and val_res.returncode == 0
            and before_exec.returncode == 0
            and after_exec.returncode == 0
            and before_exec.stdout == after_exec.stdout
            and after_exec.stdout.strip() == "42"
            and stripped_out.stat().st_size < custom_wasm.stat().st_size,
            f"strip={strip_res.returncode}, validate={val_res.returncode}, stdout={after_exec.stdout.strip()!r}",
        )

    # 2. Unsupported proposals rejected cleanly before creating output
    unsupported_cases = (
        ("reject-simd", "(module (func (export \"f\") (drop (v128.const i32x4 1 2 3 4))))\n"),
        ("reject-atomics", "(module (memory 1 1 shared) (func (export \"f\") (drop (i32.atomic.load (i32.const 0)))))\n"),
        ("reject-gc-struct", "(module (type $s (struct (field i32))) (func (export \"f\")))\n"),
        ("reject-exceptions-try-table", "(module (func (export \"f\") (block (try_table (catch_all 0) (nop)))))\n"),
    )
    for name, wat_src in unsupported_cases:
        u_wat = policy_dir / f"{name}.wat"
        u_wasm = policy_dir / f"{name}.wasm"
        u_out = policy_dir / f"{name}.out.wasm"
        u_wat.write_text(wat_src, encoding="utf-8")
        p_res = run_cmd([wabt, "text", "parse", u_wat, "-o", u_wasm])
        if p_res.returncode != 0:
            record(name, False, f"setup parse failed: {p_res.combined.strip()}")
            continue
        o_res = run_cmd([wabt, "module", "optimize", u_wasm, "-o", u_out])
        record(
            name,
            o_res.returncode != 0 and not u_out.exists(),
            f"expected rejection and no output file, got exit={o_res.returncode}, exists={u_out.exists()}",
        )

    # 3. Missing -o and input/output path aliasing rejected without clobbering input
    alias_in = policy_dir / "alias_input.wasm"
    shutil.copyfile(base_wasm, alias_in)
    original_bytes = alias_in.read_bytes()

    missing_o = run_cmd([wabt, "module", "optimize", alias_in])
    record(
        "reject-missing-output-flag",
        missing_o.returncode != 0 and alias_in.read_bytes() == original_bytes,
        f"expected non-zero exit and intact input, got exit={missing_o.returncode}",
    )

    same_path = run_cmd([wabt, "module", "optimize", alias_in, "-o", alias_in])
    dot_alias_path = policy_dir / "." / "alias_input.wasm"
    dot_alias = run_cmd([wabt, "module", "optimize", alias_in, "-o", dot_alias_path])
    record(
        "reject-input-output-alias",
        same_path.returncode != 0
        and dot_alias.returncode != 0
        and alias_in.read_bytes() == original_bytes,
        f"same_path={same_path.returncode}, dot_alias={dot_alias.returncode}, intact={alias_in.read_bytes() == original_bytes}",
    )

    return passed, total


def print_size_report(sizes: Sequence[SizeRecord]) -> None:
    print("\nByte-size report (before -> after):")
    print(f"  {'Fixture':28s} {'Category':22s} {'Before':>8s} {'After':>8s} {'Delta':>8s} {'Change':>8s}")
    print(f"  {'-' * 28} {'-' * 22} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 8}")
    total_before = 0
    total_after = 0
    for rec in sizes:
        total_before += rec.before_bytes
        total_after += rec.after_bytes
        print(
            f"  {rec.name:28s} {rec.category:22s} "
            f"{rec.before_bytes:8d} {rec.after_bytes:8d} "
            f"{rec.delta:+8d} {rec.pct:+7.1f}%"
        )
    total_delta = total_after - total_before
    total_pct = (total_delta / total_before * 100.0) if total_before else 0.0
    print(f"  {'-' * 28} {'-' * 22} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 8}")
    print(
        f"  {'TOTAL':28s} {'all fixtures':22s} "
        f"{total_before:8d} {total_after:8d} "
        f"{total_delta:+8d} {total_pct:+7.1f}%"
    )


def main() -> int:
    ap = argparse.ArgumentParser(description="wabt module optimize runtime regression gate")
    ap.add_argument("--wabt", default="wabt", help="path to the wabt CLI binary")
    ap.add_argument("--wasmtime", default=None, help="path to the wasmtime CLI binary")
    ap.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help="working directory for generated artifacts (defaults to a temporary directory respecting TMPDIR)",
    )
    ap.add_argument(
        "--require-wasmtime",
        action="store_true",
        help="fail (not skip) when no usable Wasmtime is found (CI)",
    )
    args = ap.parse_args()

    wasmtime = resolve_wasmtime(args.wasmtime)
    if wasmtime is None:
        msg = "no usable Wasmtime found (pass --wasmtime, set WASMTIME, or put `wasmtime` on PATH)"
        if args.require_wasmtime:
            print(f"error: {msg}", file=sys.stderr)
            return 2
        print(f"notice: optimize-regression skipped - {msg}")
        return 0

    wabt_cand = shutil.which(args.wabt) or (args.wabt if os.path.isfile(args.wabt) else None)
    if wabt_cand is None:
        print(f"error: wabt binary not found: {args.wabt}", file=sys.stderr)
        return 2
    wabt = Path(wabt_cand).resolve()

    # Respect TMPDIR if set; otherwise prefer a repo-local .tmp directory when present.
    tmp_base = os.environ.get("TMPDIR")
    if not tmp_base and (ROOT / ".tmp").is_dir():
        tmp_base = str((ROOT / ".tmp").resolve())

    sizes: list[SizeRecord] = []
    failures: list[str] = []
    passed_fixtures = 0

    print(f"optimize-regression: wabt={wabt} wasmtime={wasmtime}")

    def execute_in(work_dir: Path) -> None:
        nonlocal passed_fixtures
        for fixture in FIXTURES:
            if run_behavioral_fixture(fixture, work_dir, wabt, wasmtime, sizes, failures):
                passed_fixtures += 1
                rec = sizes[-1]
                print(
                    f"  PASS {fixture.name:28s} ({rec.before_bytes} -> {rec.after_bytes} bytes, {rec.delta:+d})"
                )
            else:
                print(f"  FAIL {fixture.name}")

        run_policy_and_cli_checks(work_dir, wabt, wasmtime, sizes, failures)

    if args.work_dir is not None:
        work_dir = args.work_dir.resolve()
        if work_dir.exists():
            shutil.rmtree(work_dir)
        work_dir.mkdir(parents=True, exist_ok=True)
        execute_in(work_dir)
    else:
        with tempfile.TemporaryDirectory(prefix="optimize-regression-", dir=tmp_base) as td:
            execute_in(Path(td))

    print_size_report(sizes)
    print(
        f"\noptimize-regression: {passed_fixtures}/{len(FIXTURES)} behavioral fixtures passed, "
        f"{len(failures)} failure(s)"
    )
    if failures:
        for failure in failures:
            print(f"\n--- FAILURE ---\n{failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
