"""wabt-bin — WebAssembly Binary Toolkit CLI tools."""

import os
import subprocess
import sys
from pathlib import Path


def _get_version() -> str:
    try:
        from importlib.metadata import version

        return version("wabt-bin")
    except Exception:
        return "0.0.0"

_TOOLS = [
    "wat2wasm",
    "wasm2wat",
    "wast2json",
    "wasm-validate",
    "wasm-objdump",
    "wasm-interp",
    "wasm-decompile",
    "wasm-strip",
    "wasm-stats",
    "wat-desugar",
]

_EXT = ".exe" if sys.platform == "win32" else ""


def _binary_path(tool_name: str) -> Path:
    """Return the path to a wabt tool binary."""
    return Path(__file__).parent / f"{tool_name}{_EXT}"


def _run(tool_name: str) -> None:
    """Run a wabt tool binary, replacing the current process on Unix."""
    binary = _binary_path(tool_name)
    if not binary.exists():
        print(f"{tool_name} binary not found at {binary}", file=sys.stderr)
        sys.exit(1)
    args = [str(binary), *sys.argv[1:]]
    if sys.platform != "win32":
        os.execv(args[0], args)
    else:
        raise SystemExit(subprocess.call(args))


def wat2wasm() -> None:
    _run("wat2wasm")


def wasm2wat() -> None:
    _run("wasm2wat")


def wast2json() -> None:
    _run("wast2json")


def wasm_validate() -> None:
    _run("wasm-validate")


def wasm_objdump() -> None:
    _run("wasm-objdump")


def wasm_interp() -> None:
    _run("wasm-interp")


def wasm_decompile() -> None:
    _run("wasm-decompile")


def wasm_strip() -> None:
    _run("wasm-strip")


def wasm_stats() -> None:
    _run("wasm-stats")


def wat_desugar() -> None:
    _run("wat-desugar")
