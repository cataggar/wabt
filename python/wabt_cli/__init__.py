"""wabt-bin — WebAssembly Binary Toolkit CLI tool.

Provides a helper to locate the `wabt` binary installed via the
data/scripts/ wheel layout. The binary is placed directly in the scripts
directory by pip and does not require Python at runtime.

Invoke subcommands as `wabt parse`, `wabt validate`, `wabt spectest`, etc.
Run `wabt help` for a full list.
"""

from __future__ import annotations

import os
import sys
import sysconfig

TOOLS = ["wabt"]


def find_wabt_bin(tool: str = "wabt") -> str:
    """Return the path to the wabt binary.

    Searches the scripts directories where pip installs data/scripts/ files.
    """
    ext = ".exe" if sys.platform == "win32" else ""
    exe = f"{tool}{ext}"

    targets = [
        sysconfig.get_path("scripts"),
        sysconfig.get_path("scripts", vars={"base": sys.base_prefix}),
    ]

    # User scheme
    if sys.version_info >= (3, 10):
        user_scheme = sysconfig.get_preferred_scheme("user")
    elif os.name == "nt":
        user_scheme = "nt_user"
    else:
        user_scheme = "posix_user"
    targets.append(sysconfig.get_path("scripts", scheme=user_scheme))

    seen: list[str] = []
    for target in targets:
        if not target or target in seen:
            continue
        seen.append(target)
        path = os.path.join(target, exe)
        if os.path.isfile(path):
            return path

    locations = "\n".join(f" - {t}" for t in seen)
    raise FileNotFoundError(
        f"Could not find {exe} in:\n{locations}\n"
    )
