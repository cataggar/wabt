#!/usr/bin/env python3
"""Static checks for OCI qualification docs, workflow pins, and packaging."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(condition: bool, message: str, errors: list[str]) -> None:
    if not condition:
        errors.append(message)


def require_text(path: str, needles: tuple[str, ...], errors: list[str]) -> None:
    text = read(path)
    for needle in needles:
        require(needle in text, f"{path}: missing {needle!r}", errors)


def require_normalized_text(
    path: str,
    needles: tuple[str, ...],
    errors: list[str],
) -> None:
    text = " ".join(read(path).lower().split())
    for needle in needles:
        normalized = " ".join(needle.lower().split())
        require(normalized in text, f"{path}: missing {needle!r}", errors)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--allow-missing-fixtures",
        action="store_true",
        help="permit the fixture-branch contract paths to be absent before rebase",
    )
    args = parser.parse_args()
    errors: list[str] = []

    workflow_path = ".github/workflows/oci-interop.yml"
    workflow = read(workflow_path)
    action_refs = re.findall(r"^\s*uses:\s*[^@\s]+@([^\s#]+)", workflow, re.MULTILINE)
    require(bool(action_refs), f"{workflow_path}: no actions found", errors)
    for action_ref in action_refs:
        require(
            re.fullmatch(r"[0-9a-f]{40}", action_ref) is not None,
            f"{workflow_path}: action is not pinned by a full commit SHA: {action_ref}",
            errors,
        )
    require("secrets." not in workflow, f"{workflow_path}: must not consume repository secrets", errors)
    require("azure" not in workflow.lower(), f"{workflow_path}: must not run cloud qualification", errors)
    require_text(
        workflow_path,
        (
            "ORAS_VERSION: 1.3.4",
            "db9e29505c3059f2b8fde34ae8cae266c5c765e9",
            "f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454",
            "19d479e497fb5e30c7de3c621e3ed337e3857de0d96542021a73e2d8016dbe5a",
            "5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a",
            "bf465c989fa26cb06778624fd2de843ca5d6318b4a58418c9e392e13dc02d732",
            "87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21",
            "8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd",
            "registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e",
            "scripts/oci/generate_interop_fixtures.sh",
            "scripts/oci/verify_interop_fixtures.sh",
            "if: failure()",
        ),
        errors,
    )

    require_normalized_text(
        "docs/oci.md",
        (
            "wabt oci push",
            "wabt oci pull",
            "wabt oci copy",
            "wabt oci inspect",
            "wabt oci resolve",
            "wabt oci list-tags",
            "wabt.oci.push",
            "wabt.oci.pull",
            "wabt.oci.copy",
            "wabt.oci.inspect",
            "wabt.oci.resolve",
            "wabt.oci.list-tags",
            "00000000-0000-0000-0000-000000000000",
            "az acr login --name \"$ACR_NAME\" --expose-token",
            "transport evidence is not runtime qualification",
            "not automatically wkg-compatible",
            "does not execute",
            "signing or signature verification",
            "production-readiness",
            "Kusto",
        ),
        errors,
    )
    require_normalized_text(
        "README.md",
        ("## OCI artifacts", "[OCI user guide](docs/oci.md)", "does not execute"),
        errors,
    )
    require_text(
        "src/tools/oci.zig",
        (
            "https://github.com/cataggar/wabt/blob/main/docs/oci.md",
            "never execute downloaded WebAssembly",
        ),
        errors,
    )
    require_text(
        "build.zig.zon",
        ('"docs"', '"SOURCE_PROVENANCE.md"', '"THIRD_PARTY_NOTICES.md"'),
        errors,
    )
    require_text(
        ".github/workflows/release.yml",
        (
            'cp -R docs "$PKGNAME/"',
            '"$PKGNAME/docs/oci.md"',
            '"$PKGNAME/docs/oci-authentication.md"',
            "## Highlights",
            "## Full changelog",
            "## Install",
        ),
        errors,
    )
    require_text(
        "scripts/build_wheels.py",
        (
            '("docs/oci.md", "docs/oci.md")',
            '("docs/oci-authentication.md", "docs/oci-authentication.md")',
        ),
        errors,
    )
    require_text(
        ".github/workflows/pypi.yml",
        ("docs/oci.md", "docs/oci-authentication.md"),
        errors,
    )
    require_normalized_text(
        "SOURCE_PROVENANCE.md",
        (
            "ORAS v1.3.4",
            "wasm-pkg-tools",
            "oci-wasm 0.6.0",
            "Distribution registry",
            "transport does not verify signatures",
        ),
        errors,
    )
    require_normalized_text(
        "THIRD_PARTY_NOTICES.md",
        ("External OCI qualification producers", "not WABT runtime dependencies"),
        errors,
    )

    ci = read(".github/workflows/ci.yml")
    require("oci-interop" not in ci, ".github/workflows/ci.yml: external tools leaked into normal CI", errors)
    require(
        "os: [ubuntu-22.04, macos-latest, windows-latest]" in ci
        and "optimize: [Debug, ReleaseSafe]" in ci,
        ".github/workflows/ci.yml: ordinary six-cell matrix changed",
        errors,
    )

    fixture_paths = (
        "src/fixtures/oci/manifest.json",
        "scripts/oci/generate_interop_fixtures.sh",
        "scripts/oci/verify_interop_fixtures.sh",
    )
    missing = [path for path in fixture_paths if not (ROOT / path).is_file()]
    if missing and not args.allow_missing_fixtures:
        errors.append("fixture branch contract is missing: " + ", ".join(missing))
    elif missing:
        print("fixture contract pending rebase: " + ", ".join(missing))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("OCI qualification static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
