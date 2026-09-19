#!/usr/bin/env python3
"""Check OCI qualification workflow, documentation, and package contracts."""

from __future__ import annotations

import json
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
    errors: list[str] = []
    workflow_path = ".github/workflows/oci-interop.yml"
    workflow = read(workflow_path)
    generator = read("scripts/oci/generate_interop_fixtures.sh")
    manifest = json.loads(read("src/fixtures/oci/manifest.json"))
    producers = manifest["producers"]

    action_refs = re.findall(r"^\s*uses:\s*[^@\s]+@([^\s#]+)", workflow, re.MULTILINE)
    require(bool(action_refs), f"{workflow_path}: no actions found", errors)
    for action_ref in action_refs:
        require(
            re.fullmatch(r"[0-9a-f]{40}", action_ref) is not None,
            f"{workflow_path}: action is not pinned by a full commit SHA: {action_ref}",
            errors,
        )
    require(
        "secrets." not in workflow, f"{workflow_path}: must not consume secrets", errors
    )
    require(
        "azure" not in workflow.lower(), f"{workflow_path}: must not run Azure", errors
    )
    require("acr" not in workflow.lower(), f"{workflow_path}: must not run ACR", errors)
    require(
        "docker " not in workflow,
        f"{workflow_path}: must use the pinned registry binary",
        errors,
    )
    require_text(
        workflow_path,
        (
            "runs-on: ubuntu-22.04-arm",
            "persist-credentials: false",
            "WABT_OCI_INTEROP_MODE: qualify",
            "WABT_OCI_INTEROP_STATE_DIR=$RUNNER_TEMP/wabt-oci-interoperability",
            "${{ runner.temp }}/wabt-oci-interoperability/tools/downloads",
            "for pass in one two",
            "scripts/oci/generate_interop_fixtures.sh",
            "scripts/oci/verify_interop_fixtures.sh",
            "git diff --exit-code -- src/fixtures/oci",
            "if: failure()",
            "summary.txt",
            "retention-days: 3",
        ),
        errors,
    )

    require(
        manifest.get("schema") == "wabt.oci.interop-fixtures",
        "fixture schema drift",
        errors,
    )
    require(manifest.get("schemaVersion") == 1, "fixture schema version drift", errors)
    require(
        manifest.get("executionPlatform") == "linux/arm64",
        "fixture platform drift",
        errors,
    )
    require(
        set(manifest["layouts"])
        == {
            "copy-roundtrip",
            "index",
            "oras-oci-v1.0",
            "oras-oci-v1.1",
            "wabt-oci-v1.1",
            "wabt-wasm-v0",
            "wkg-wasm-v0",
        },
        "fixture layout set drift",
        errors,
    )
    matrix = {item["id"]: item for item in manifest["matrix"]}
    for case in (
        "wkg-to-wabt",
        "wabt-wasm-v0-to-wkg",
        "oras-oci-1.0-to-wabt",
        "oras-oci-1.1-to-wabt",
        "wabt-generic-to-oras",
        "wabt-generic-to-wkg",
        "digest-preserving-copies",
        "index-preservation-and-extraction-rejection",
    ):
        require(case in matrix, f"fixture matrix missing {case}", errors)
    require(
        matrix.get("wabt-generic-to-wkg", {}).get("result")
        == "pass-expected-rejection",
        "generic-to-wkg must remain an expected rejection",
        errors,
    )

    pinned_values = (
        producers["oras"]["version"],
        producers["oras"]["commit"],
        producers["oras"]["checksumList"]["sha256"],
        producers["oras"]["archive"]["sha256"],
        producers["wkg"]["version"],
        producers["wkg"]["sourceRevision"],
        producers["wkg"]["sourceTree"],
        producers["wkg"]["cargoLockSha256"],
        producers["oci-wasm"]["version"],
        producers["oci-wasm"]["crateChecksumSha256"],
        producers["oci-wasm"]["tagCommit"],
        producers["registry"]["version"],
        producers["registry"]["archive"]["sha256"],
        producers["rustup"]["version"],
        producers["rustup"]["archive"]["sha256"],
        producers["wkg"]["build"]["compiler"]["versionOutput"][0].split()[1],
    )
    for value in pinned_values:
        require(value in generator, f"generator missing manifest pin {value}", errors)
    require_text(
        "scripts/oci/generate_interop_fixtures.sh",
        (
            "WABT_OCI_INTEROP_MODE",
            "WABT_OCI_INTEROP_STATE_DIR",
            "RUNNER_TEMP",
            'registry" serve',
            'fixture_manifest.py" qualify',
            'fixture_manifest.py" verify',
            "MAX_STATE_KIB",
        ),
        errors,
    )
    require(
        not (ROOT / "scripts/oci_interop.py").exists(),
        "duplicate scripts/oci_interop.py must not be retained",
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
            "operator-run azure container registry walkthrough",
            "00000000-0000-0000-0000-000000000000",
            'az acr login --name "$acr_name" --expose-token',
            "transport evidence is not runtime qualification",
            "not automatically wkg-compatible",
            "does not execute",
            "signing or signature verification",
            "production-readiness",
            "wamr and wasmtime execution is outside transport qualification",
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

    provenance_values = (
        producers["oras"]["archive"]["sha256"],
        producers["oras"]["binary"]["sha256"],
        producers["wkg"]["binary"]["sha256"],
        producers["registry"]["archive"]["sha256"],
        producers["registry"]["binary"]["sha256"],
        producers["wkg"]["build"]["compiler"]["sha256"],
        producers["wkg"]["build"]["cargo"]["sha256"],
        producers["wkg"]["build"]["zigLinker"]["sha256"],
    )
    provenance = read("SOURCE_PROVENANCE.md")
    for value in provenance_values:
        require(value in provenance, f"SOURCE_PROVENANCE.md missing {value}", errors)
    require_normalized_text(
        "SOURCE_PROVENANCE.md",
        (
            "oras cli 1.3.4",
            "wkg 0.16.1",
            "oci-wasm 0.6.0",
            "distribution registry 3.1.1",
            "transport interoperability does not claim signature verification",
        ),
        errors,
    )
    require_normalized_text(
        "THIRD_PARTY_NOTICES.md",
        ("oci fixture and qualification producers", "not runtime dependencies"),
        errors,
    )

    ci = read(".github/workflows/ci.yml")
    require("oci-interop" not in ci, "external tools leaked into normal CI", errors)
    require(
        "os: [ubuntu-22.04, macos-latest, windows-latest]" in ci
        and "optimize: [Debug, ReleaseSafe]" in ci,
        "ordinary six-cell matrix changed",
        errors,
    )

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    print("OCI qualification static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
