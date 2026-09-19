#!/usr/bin/env python3
"""Run the credential-free, pinned OCI external-tool qualification matrix."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

ORAS_VERSION = "1.3.4"
WKG_VERSION = "0.16.1"
WKG_REVISION = "5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a"
OCI_WASM_VERSION = "0.6.0"
OCI_WASM_CHECKSUM = "87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21"
PAYLOAD_SHA256 = "0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9"
PAYLOAD_SIZE = 58_495
MAX_CAPTURE_BYTES = 16 * 1024


class QualificationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bounded_text(data: str) -> str:
    encoded = data.encode("utf-8", "replace")
    if len(encoded) > MAX_CAPTURE_BYTES:
        encoded = encoded[-MAX_CAPTURE_BYTES:]
    text = encoded.decode("utf-8", "replace")
    text = re.sub(r"(?i)(authorization|password|token)(\s*[:=]\s*)\S+", r"\1\2<redacted>", text)
    text = re.sub(r"(https?://[^\s?]+)\?[^\s]+", r"\1?<redacted-query>", text)
    return text


class Runner:
    def __init__(self, results: dict[str, Any], timeout: int, environment: dict[str, str]):
        self.results = results
        self.timeout = timeout
        self.environment = environment

    def command(
        self,
        label: str,
        argv: list[str],
        *,
        cwd: Path | None = None,
        expected: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        print(f"==> {label}", flush=True)
        started = time.monotonic()
        try:
            completed = subprocess.run(
                argv,
                cwd=cwd,
                env=self.environment,
                text=True,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            elapsed = round((time.monotonic() - started) * 1000)
            self.results["cases"].append(
                {"name": label, "status": "failed", "durationMs": elapsed, "category": "timeout"}
            )
            raise QualificationError(f"{label}: timed out after {self.timeout}s") from error

        elapsed = round((time.monotonic() - started) * 1000)
        status = "passed" if completed.returncode == expected else "failed"
        self.results["cases"].append(
            {
                "name": label,
                "status": status,
                "durationMs": elapsed,
                "returnCode": completed.returncode,
            }
        )
        if completed.returncode != expected:
            diagnostic = bounded_text(completed.stderr or completed.stdout)
            raise QualificationError(
                f"{label}: expected exit {expected}, got {completed.returncode}: {diagnostic}"
            )
        return completed

    def json(
        self,
        label: str,
        argv: list[str],
        *,
        cwd: Path | None = None,
        schema: str | None = None,
    ) -> dict[str, Any]:
        completed = self.command(label, argv, cwd=cwd)
        try:
            value = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise QualificationError(f"{label}: stdout was not one JSON object") from error
        if not isinstance(value, dict):
            raise QualificationError(f"{label}: JSON result was not an object")
        if schema is not None and (
            value.get("schema") != schema or value.get("schemaVersion") != 1
        ):
            raise QualificationError(f"{label}: unexpected JSON schema/version")
        return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise QualificationError(message)


def descriptor_digest(value: dict[str, Any], field: str) -> str:
    descriptor = value.get(field)
    require(isinstance(descriptor, dict), f"missing {field} descriptor")
    digest = descriptor.get("digest")
    require(isinstance(digest, str), f"missing {field} digest")
    return digest


def registry_parts(reference: str) -> tuple[str, str, str]:
    authority, slash, rest = reference.partition("/")
    require(bool(slash and authority and rest), f"invalid registry reference {reference!r}")
    if "@" in rest:
        repository, selector = rest.rsplit("@", 1)
    else:
        repository, colon, selector = rest.rpartition(":")
        require(bool(colon), f"registry reference has no selector: {reference!r}")
    return authority, repository, selector


def registry_request(reference: str, kind: str, selector: str, accept: str | None = None) -> bytes:
    authority, repository, _ = registry_parts(reference)
    url = (
        f"http://{authority}/v2/{quote(repository, safe='/')}/"
        f"{kind}/{quote(selector, safe=':')}"
    )
    headers = {"Accept": accept} if accept else {}
    with urlopen(Request(url, headers=headers), timeout=30) as response:
        return response.read()


def registry_manifest(reference: str) -> tuple[dict[str, Any], bytes]:
    _, _, selector = registry_parts(reference)
    data = registry_request(
        reference,
        "manifests",
        selector,
        (
            "application/vnd.oci.image.manifest.v1+json,"
            "application/vnd.oci.image.index.v1+json"
        ),
    )
    try:
        value = json.loads(data)
    except json.JSONDecodeError as error:
        raise QualificationError(f"{reference}: registry manifest was not JSON") from error
    require(isinstance(value, dict), f"{reference}: registry manifest was not an object")
    return value, data


def registry_blob(reference: str, digest: str) -> bytes:
    return registry_request(reference, "blobs", digest)


def compare_payload(expected: Path, actual: Path, label: str) -> None:
    require(actual.is_file(), f"{label}: expected output {actual} is missing")
    require(expected.read_bytes() == actual.read_bytes(), f"{label}: payload bytes differ")
    require(sha256_file(actual) == PAYLOAD_SHA256, f"{label}: payload SHA-256 differs")


def collect_strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for child in value for item in collect_strings(child)]
    if isinstance(value, dict):
        return [item for child in value.values() for item in collect_strings(child)]
    return []


def safe_work_path(path: Path) -> Path:
    resolved = path.resolve()
    for forbidden in (Path("/tmp"), Path("/var/tmp")):
        try:
            resolved.relative_to(forbidden)
        except ValueError:
            continue
        raise QualificationError(f"work directory must not be below {forbidden}")
    return resolved


def require_loopback_registry(authority: str) -> None:
    parsed = urlsplit(f"//{authority}")
    host = parsed.hostname
    require(host is not None and parsed.port is not None, "registry must include a loopback host and port")
    if host == "localhost":
        return
    try:
        address = ipaddress.ip_address(host)
    except ValueError as error:
        raise QualificationError("registry must be a canonical loopback address") from error
    require(address.is_loopback, "registry must be loopback-only")


def tool_path(value: str) -> Path:
    candidate = Path(value)
    if candidate.parent != Path(".") or candidate.is_absolute():
        resolved = candidate.resolve()
    else:
        found = shutil.which(value)
        require(found is not None, f"tool not found: {value}")
        resolved = Path(found).resolve()
    require(resolved.is_file(), f"tool not found: {value}")
    return resolved


def find_index_fixture(root: Path) -> tuple[Path, str]:
    for index_path in sorted(root.rglob("index.json")):
        try:
            catalog = json.loads(index_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        manifests = catalog.get("manifests") if isinstance(catalog, dict) else None
        if not isinstance(manifests, list):
            continue
        for descriptor in manifests:
            if not isinstance(descriptor, dict):
                continue
            media_type = descriptor.get("mediaType")
            digest = descriptor.get("digest")
            if (
                media_type == "application/vnd.oci.image.index.v1+json"
                and isinstance(digest, str)
            ):
                return index_path.parent, digest
    raise QualificationError("no checked-in OCI layout with an index root was found")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wabt", required=True)
    parser.add_argument("--oras", default=os.environ.get("ORAS", "oras"))
    parser.add_argument("--wkg", default=os.environ.get("WKG", "wkg"))
    parser.add_argument("--registry", default=os.environ.get("OCI_REGISTRY", "127.0.0.1:5000"))
    parser.add_argument(
        "--payload",
        type=Path,
        default=Path("src/component/fixtures/stdio-echo.wasm"),
    )
    parser.add_argument(
        "--fixtures-manifest",
        type=Path,
        default=Path("src/fixtures/oci/manifest.json"),
    )
    parser.add_argument(
        "--fixture-root",
        type=Path,
        default=Path("src/fixtures/oci"),
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=Path(os.environ.get("OCI_INTEROP_WORK_DIR", "zig-out/oci-interop")),
    )
    parser.add_argument(
        "--results",
        type=Path,
        default=Path(os.environ.get("OCI_INTEROP_RESULTS", "zig-out/oci-interop/results.json")),
    )
    parser.add_argument("--command-timeout", type=int, default=180)
    args = parser.parse_args()

    work = safe_work_path(args.work_dir)
    results_path = safe_work_path(args.results)
    results: dict[str, Any] = {
        "schema": "wabt.oci.interop-results",
        "schemaVersion": 1,
        "status": "failed",
        "pins": {
            "oras": ORAS_VERSION,
            "wkgVersion": WKG_VERSION,
            "wkgRevision": WKG_REVISION,
            "ociWasmVersion": OCI_WASM_VERSION,
            "ociWasmChecksum": OCI_WASM_CHECKSUM,
        },
        "tools": {},
        "fixture": {},
        "artifacts": {},
        "cases": [],
    }

    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    results_path.parent.mkdir(parents=True, exist_ok=True)

    environment = os.environ.copy()
    environment.update(
        {
            "LC_ALL": "C",
            "TZ": "UTC",
            "NO_COLOR": "1",
            "DOCKER_CONFIG": str(work / "empty-docker-config"),
        }
    )
    environment.pop("WKG_OCI_USERNAME", None)
    environment.pop("WKG_OCI_PASSWORD", None)
    docker_config = Path(environment["DOCKER_CONFIG"])
    docker_config.mkdir()
    (docker_config / "config.json").write_text('{"auths":{}}\n', encoding="utf-8")

    runner = Runner(results, args.command_timeout, environment)
    wabt = tool_path(args.wabt)
    oras = tool_path(args.oras)
    wkg = tool_path(args.wkg)

    try:
        wabt_version = runner.command("record wabt version", [str(wabt), "version"]).stdout.strip()
        oras_version = runner.command("verify ORAS version", [str(oras), "version"]).stdout.strip()
        wkg_version = runner.command("verify wkg version", [str(wkg), "--version"]).stdout.strip()
        require(re.search(r"\b1\.3\.4\b", oras_version) is not None, "ORAS is not v1.3.4")
        require(re.search(r"\b0\.16\.1\b", wkg_version) is not None, "wkg is not v0.16.1")
        results["tools"] = {
            "wabt": {"version": wabt_version, "sha256": sha256_file(wabt)},
            "oras": {"version": oras_version, "sha256": sha256_file(oras)},
            "wkg": {"version": wkg_version, "sha256": sha256_file(wkg)},
        }

        payload = args.payload.resolve()
        require(payload.is_file(), f"payload is missing: {payload}")
        require(payload.stat().st_size == PAYLOAD_SIZE, "fixture payload size changed")
        require(sha256_file(payload) == PAYLOAD_SHA256, "fixture payload SHA-256 changed")
        staged_payload = work / "input" / "component.wasm"
        staged_payload.parent.mkdir()
        shutil.copyfile(payload, staged_payload)

        fixture_manifest = args.fixtures_manifest.resolve()
        require(fixture_manifest.is_file(), f"fixture manifest is missing: {fixture_manifest}")
        fixture_value = json.loads(fixture_manifest.read_text(encoding="utf-8"))
        fixture_strings = collect_strings(fixture_value)
        require(
            PAYLOAD_SHA256 in fixture_strings or f"sha256:{PAYLOAD_SHA256}" in fixture_strings,
            "fixture manifest does not record the pinned payload digest",
        )
        results["fixture"] = {
            "manifestSha256": sha256_file(fixture_manifest),
            "payloadSha256": PAYLOAD_SHA256,
            "payloadSize": PAYLOAD_SIZE,
        }

        registry = args.registry
        require_loopback_registry(registry)
        run_id = re.sub(
            r"[^a-z0-9-]+",
            "-",
            os.environ.get("OCI_INTEROP_RUN_ID", "local").lower(),
        ).strip("-") or "local"
        repository = f"{registry}/wabt-interop/{run_id}"
        oras_config = str(docker_config / "config.json")
        wabt_source = ["--plain-http", "--no-credential-discovery", "--deadline", "2m"]
        wabt_destination = wabt_source
        created = "2025-01-01T00:00:00Z"

        def wabt_inspect(reference: str, label: str) -> dict[str, Any]:
            return runner.json(
                label,
                [str(wabt), "oci", "inspect", reference, "--json", *wabt_source],
                schema="wabt.oci.inspect",
            )

        def wabt_resolve(reference: str, label: str) -> str:
            endpoint_options = [] if reference.startswith("oci:") else wabt_source
            value = runner.json(
                label,
                [str(wabt), "oci", "resolve", reference, "--json", *endpoint_options],
                schema="wabt.oci.resolve",
            )
            digest = value.get("rootDigest")
            require(isinstance(digest, str), f"{label}: missing rootDigest")
            return digest

        def wabt_pull(reference: str, output: Path, label: str) -> dict[str, Any]:
            value = runner.json(
                label,
                [
                    str(wabt),
                    "oci",
                    "pull",
                    reference,
                    "-o",
                    str(output),
                    "--json",
                    *wabt_source,
                ],
                schema="wabt.oci.pull",
            )
            compare_payload(staged_payload, output, label)
            require(descriptor_digest(value, "payload") == f"sha256:{PAYLOAD_SHA256}", f"{label}: payload digest differs")
            return value

        # wkg -> WABT.
        wkg_ref = f"{repository}/wkg:v1"
        runner.command(
            "wkg push Wasm-v0 component",
            [
                str(wkg),
                "oci",
                "push",
                "--insecure",
                registry,
                "--author",
                "wabt-interop",
                wkg_ref,
                str(staged_payload),
            ],
        )
        wkg_root = wabt_resolve(wkg_ref, "WABT resolve wkg artifact")
        wkg_inspect = wabt_inspect(wkg_ref, "WABT inspect wkg artifact")
        require(wkg_inspect.get("profile") == "wasm-v0", "wkg artifact was not classified as wasm-v0")
        require(descriptor_digest(wkg_inspect, "root") == wkg_root, "wkg root digest disagrees")
        wabt_pull(wkg_ref, work / "wkg-to-wabt.wasm", "WABT pull wkg artifact")
        wkg_manifest, wkg_manifest_bytes = registry_manifest(wkg_ref)
        require(f"sha256:{hashlib.sha256(wkg_manifest_bytes).hexdigest()}" == wkg_root, "wkg manifest digest differs")
        wkg_config_descriptor = wkg_manifest.get("config")
        require(isinstance(wkg_config_descriptor, dict), "wkg config descriptor is missing")
        wkg_config_digest = wkg_config_descriptor.get("digest")
        require(isinstance(wkg_config_digest, str), "wkg config digest is missing")
        wkg_config = json.loads(registry_blob(wkg_ref, wkg_config_digest))
        require(wkg_config.get("architecture") == "wasm", "wkg config architecture is not wasm")
        require(wkg_config.get("os") == "wasip2", "wkg config OS is not wasip2")
        require(wkg_config.get("layerDigests") == [f"sha256:{PAYLOAD_SHA256}"], "wkg layerDigests differ")
        require(wkg_config.get("author") == "wabt-interop", "wkg author differs")
        wkg_component = wkg_config.get("component")
        require(isinstance(wkg_component, dict), "wkg component metadata is missing")
        require(isinstance(wkg_component.get("imports"), list), "wkg component imports are missing")
        require(isinstance(wkg_component.get("exports"), list), "wkg component exports are missing")
        require("target" in wkg_component, "wkg component target is missing")
        require(wkg_root != f"sha256:{PAYLOAD_SHA256}", "wkg manifest and payload digests must differ")

        # WABT Wasm-v0 -> wkg.
        wabt_wasm_ref = f"{repository}/wabt-wasm-v0:v1"
        wabt_wasm = runner.json(
            "WABT push Wasm-v0 component",
            [
                str(wabt),
                "oci",
                "push",
                wabt_wasm_ref,
                str(staged_payload),
                "--format",
                "wasm-v0",
                "--created",
                created,
                "--author",
                "wabt-interop",
                "--json",
                *wabt_destination,
            ],
            schema="wabt.oci.push",
        )
        wabt_wasm_root = descriptor_digest(wabt_wasm, "root")
        wkg_output = work / "wabt-to-wkg.wasm"
        runner.command(
            "wkg pull WABT Wasm-v0 artifact",
            [
                str(wkg),
                "oci",
                "pull",
                "--insecure",
                registry,
                wabt_wasm_ref,
                "-o",
                str(wkg_output),
            ],
        )
        compare_payload(staged_payload, wkg_output, "wkg pull WABT Wasm-v0 artifact")
        wabt_manifest, _ = registry_manifest(wabt_wasm_ref)
        wabt_config_descriptor = wabt_manifest.get("config")
        require(isinstance(wabt_config_descriptor, dict), "WABT Wasm-v0 config is missing")
        wabt_config_digest = wabt_config_descriptor.get("digest")
        require(isinstance(wabt_config_digest, str), "WABT Wasm-v0 config digest is missing")
        wabt_config = json.loads(registry_blob(wabt_wasm_ref, wabt_config_digest))
        require(wabt_config.get("architecture") == "wasm", "WABT config architecture is not wasm")
        require(wabt_config.get("os") == "wasip2", "WABT config OS is not wasip2")
        require(wabt_config.get("layerDigests") == [f"sha256:{PAYLOAD_SHA256}"], "WABT layerDigests differ")
        wabt_component = wabt_config.get("component")
        require(isinstance(wabt_component, dict), "WABT component metadata is missing")
        require(isinstance(wabt_component.get("imports"), list), "WABT component imports are missing")
        require(isinstance(wabt_component.get("exports"), list), "WABT component exports are missing")
        require("target" in wabt_component, "WABT component target is missing")
        require(
            sorted(wabt_component["imports"]) == sorted(wkg_component["imports"]),
            "WABT and wkg component imports differ",
        )
        require(
            sorted(wabt_component["exports"]) == sorted(wkg_component["exports"]),
            "WABT and wkg component exports differ",
        )
        require(
            wabt_component["target"] == wkg_component["target"],
            "WABT and wkg component targets differ",
        )
        require(wabt_wasm_root != f"sha256:{PAYLOAD_SHA256}", "WABT manifest and payload digests must differ")

        # ORAS OCI 1.0 and 1.1 -> WABT.
        oras_roots: dict[str, str] = {}
        oras_configs: dict[str, str] = {}
        for image_spec, expected_profile in (("v1.0", "oci-1.0"), ("v1.1", "oci-1.1")):
            oras_ref = f"{repository}/oras-{image_spec.replace('.', '-')}:v1"
            runner.command(
                f"ORAS push OCI {image_spec}",
                [
                    str(oras),
                    "push",
                    "--plain-http",
                    "--registry-config",
                    oras_config,
                    "--image-spec",
                    image_spec,
                    "--artifact-type",
                    "application/wasm",
                    oras_ref,
                    "component.wasm:application/wasm",
                ],
                cwd=staged_payload.parent,
            )
            inspected = wabt_inspect(oras_ref, f"WABT inspect ORAS OCI {image_spec}")
            require(inspected.get("profile") == expected_profile, f"ORAS {image_spec} profile differs")
            require(descriptor_digest(inspected, "payload") == f"sha256:{PAYLOAD_SHA256}", f"ORAS {image_spec} payload differs")
            root = descriptor_digest(inspected, "root")
            oras_roots[image_spec] = root
            oras_configs[image_spec] = descriptor_digest(inspected, "config")
            oras_manifest, oras_manifest_bytes = registry_manifest(oras_ref)
            require(
                f"sha256:{hashlib.sha256(oras_manifest_bytes).hexdigest()}" == root,
                f"ORAS {image_spec} manifest digest differs",
            )
            if image_spec == "v1.1":
                require(
                    oras_manifest.get("artifactType") == "application/wasm",
                    "ORAS OCI 1.1 artifactType differs",
                )
                config = oras_manifest.get("config")
                require(isinstance(config, dict), "ORAS OCI 1.1 config descriptor is missing")
                require(
                    config.get("mediaType") == "application/vnd.oci.empty.v1+json",
                    "ORAS OCI 1.1 empty-config media type differs",
                )
                config_digest = config.get("digest")
                require(isinstance(config_digest, str), "ORAS OCI 1.1 config digest is missing")
                require(registry_blob(oras_ref, config_digest) == b"{}", "ORAS OCI 1.1 config is not canonical empty JSON")
            wabt_pull(
                oras_ref,
                work / f"oras-{image_spec.replace('.', '-')}-to-wabt.wasm",
                f"WABT pull ORAS OCI {image_spec}",
            )

        # WABT generic OCI 1.1 -> ORAS, and expected rejection by wkg.
        wabt_oci_ref = f"{repository}/wabt-oci:v1"
        wabt_oci = runner.json(
            "WABT push generic OCI artifact",
            [
                str(wabt),
                "oci",
                "push",
                wabt_oci_ref,
                str(staged_payload),
                "--format",
                "oci",
                "--created",
                created,
                "--json",
                *wabt_destination,
            ],
            schema="wabt.oci.push",
        )
        wabt_oci_root = descriptor_digest(wabt_oci, "root")
        require(
            wabt_oci_root != descriptor_digest(wabt_oci, "payload"),
            "WABT generic manifest and payload digests must differ",
        )
        resolved = runner.command(
            "ORAS resolve WABT generic artifact",
            [str(oras), "resolve", "--plain-http", "--registry-config", oras_config, wabt_oci_ref],
        ).stdout.strip()
        require(resolved == wabt_oci_root, "ORAS resolve digest differs from WABT")
        fetched_manifest = work / "wabt-oci-manifest.json"
        runner.command(
            "ORAS fetch WABT generic manifest",
            [
                str(oras),
                "manifest",
                "fetch",
                "--plain-http",
                "--registry-config",
                oras_config,
                "-o",
                str(fetched_manifest),
                wabt_oci_ref,
            ],
        )
        require(
            f"sha256:{sha256_file(fetched_manifest)}" == wabt_oci_root,
            "ORAS-fetched manifest digest differs from WABT",
        )
        oras_output = work / "oras-pull-wabt"
        oras_output.mkdir()
        runner.command(
            "ORAS pull WABT generic artifact",
            [
                str(oras),
                "pull",
                "--plain-http",
                "--registry-config",
                oras_config,
                "-o",
                str(oras_output),
                wabt_oci_ref,
            ],
        )
        compare_payload(staged_payload, oras_output / "component.wasm", "ORAS pull WABT generic artifact")

        rejected = work / "wkg-rejected.wasm"
        started = time.monotonic()
        try:
            rejection = subprocess.run(
                [
                    str(wkg),
                    "oci",
                    "pull",
                    "--insecure",
                    registry,
                    wabt_oci_ref,
                    "-o",
                    str(rejected),
                ],
                env=environment,
                text=True,
                capture_output=True,
                timeout=args.command_timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            results["cases"].append(
                {
                    "name": "wkg rejects WABT generic OCI profile",
                    "status": "failed",
                    "durationMs": round((time.monotonic() - started) * 1000),
                    "category": "timeout",
                }
            )
            raise QualificationError("wkg generic-profile rejection timed out") from error
        elapsed = round((time.monotonic() - started) * 1000)
        rejection_text = bounded_text(rejection.stderr or rejection.stdout).lower()
        rejection_ok = (
            rejection.returncode != 0
            and not rejected.exists()
            and "config" in rejection_text
            and "wasm" in rejection_text
        )
        results["cases"].append(
            {
                "name": "wkg rejects WABT generic OCI profile",
                "status": "passed" if rejection_ok else "failed",
                "durationMs": elapsed,
                "returnCode": rejection.returncode,
                "category": "expected-profile-rejection",
            }
        )
        require(rejection_ok, "wkg generic-profile rejection was absent, ambiguous, or left output")

        def copy_root(
            name: str,
            source_reference: str,
            expected_root: str,
            consumer: str,
        ) -> None:
            layout = work / "layouts" / f"{name}-registry-layout"
            copied = runner.command(
                f"copy {name} registry to layout",
                [
                    str(wabt),
                    "oci",
                    "copy",
                    source_reference,
                    f"oci:{layout}",
                    "--source-plain-http",
                    "--source-no-credential-discovery",
                    "--source-deadline",
                    "2m",
                ],
            ).stdout.strip()
            require(copied == expected_root, f"{name}: registry-to-layout digest changed")
            require(
                wabt_resolve(f"oci:{layout}", f"resolve {name} copied layout") == expected_root,
                f"{name}: copied layout root changed",
            )

            layout_copy = work / "layouts" / f"{name}-layout-layout"
            copied = runner.command(
                f"copy {name} layout to layout",
                [str(wabt), "oci", "copy", f"oci:{layout}", f"oci:{layout_copy}"],
            ).stdout.strip()
            require(copied == expected_root, f"{name}: layout-to-layout digest changed")

            layout_registry_ref = f"{repository}/{name}-layout-registry:v1"
            copied = runner.command(
                f"copy {name} layout to registry",
                [
                    str(wabt),
                    "oci",
                    "copy",
                    f"oci:{layout_copy}",
                    layout_registry_ref,
                    "--destination-plain-http",
                    "--destination-no-credential-discovery",
                    "--destination-deadline",
                    "2m",
                ],
            ).stdout.strip()
            require(copied == expected_root, f"{name}: layout-to-registry digest changed")

            registry_registry_ref = f"{repository}/{name}-registry-registry:v1"
            copied = runner.command(
                f"copy {name} registry to registry",
                [
                    str(wabt),
                    "oci",
                    "copy",
                    source_reference,
                    registry_registry_ref,
                    "--source-plain-http",
                    "--source-no-credential-discovery",
                    "--source-deadline",
                    "2m",
                    "--destination-plain-http",
                    "--destination-no-credential-discovery",
                    "--destination-deadline",
                    "2m",
                ],
            ).stdout.strip()
            require(copied == expected_root, f"{name}: registry-to-registry digest changed")

            for suffix, reference in (
                ("layout-registry", layout_registry_ref),
                ("registry-registry", registry_registry_ref),
            ):
                require(
                    wabt_resolve(reference, f"resolve {name} {suffix} copy") == expected_root,
                    f"{name}: {suffix} root digest changed",
                )
                if consumer == "wkg":
                    output = work / f"{name}-{suffix}-wkg.wasm"
                    runner.command(
                        f"wkg pull {name} {suffix} copy",
                        [
                            str(wkg),
                            "oci",
                            "pull",
                            "--insecure",
                            registry,
                            reference,
                            "-o",
                            str(output),
                        ],
                    )
                    compare_payload(staged_payload, output, f"wkg pull {name} {suffix} copy")
                else:
                    output_dir = work / f"{name}-{suffix}-oras"
                    output_dir.mkdir()
                    runner.command(
                        f"ORAS pull {name} {suffix} copy",
                        [
                            str(oras),
                            "pull",
                            "--plain-http",
                            "--registry-config",
                            oras_config,
                            "-o",
                            str(output_dir),
                            reference,
                        ],
                    )
                    compare_payload(
                        staged_payload,
                        output_dir / "component.wasm",
                        f"ORAS pull {name} {suffix} copy",
                    )

        copy_root("wkg", wkg_ref, wkg_root, "wkg")
        copy_root("oras", f"{repository}/oras-v1-1:v1", oras_roots["v1.1"], "oras")
        copy_root("wabt-oci", wabt_oci_ref, wabt_oci_root, "oras")

        # Checked-in multi-manifest index: preserve the full graph and keep pull rejection.
        index_layout, index_digest = find_index_fixture(args.fixture_root.resolve())
        require(
            index_digest in fixture_strings,
            "fixture manifest does not record the checked-in index root digest",
        )
        index_reference = f"oci:{index_layout}@{index_digest}"
        inspected_index = runner.json(
            "inspect checked-in multi-manifest index",
            [str(wabt), "oci", "inspect", index_reference, "--json"],
            schema="wabt.oci.inspect",
        )
        require(inspected_index.get("documentKind") == "index", "checked-in index was not inspected as an index")
        index_registry_ref = f"{repository}/index:v1"
        copied_index = runner.command(
            "copy checked-in index layout to registry",
            [
                str(wabt),
                "oci",
                "copy",
                index_reference,
                index_registry_ref,
                "--destination-plain-http",
                "--destination-no-credential-discovery",
                "--destination-deadline",
                "2m",
            ],
        ).stdout.strip()
        require(copied_index == index_digest, "index layout-to-registry digest changed")
        index_roundtrip = work / "layouts" / "index-roundtrip"
        copied_index = runner.command(
            "copy index registry to layout",
            [
                str(wabt),
                "oci",
                "copy",
                index_registry_ref,
                f"oci:{index_roundtrip}",
                "--source-plain-http",
                "--source-no-credential-discovery",
                "--source-deadline",
                "2m",
            ],
        ).stdout.strip()
        require(copied_index == index_digest, "index registry-to-layout digest changed")
        registry_index = wabt_inspect(index_registry_ref, "inspect copied registry index")
        require(
            registry_index.get("graph") == inspected_index.get("graph"),
            "registry index graph summary changed",
        )
        layout_index = runner.json(
            "inspect round-tripped index layout",
            [str(wabt), "oci", "inspect", f"oci:{index_roundtrip}@{index_digest}", "--json"],
            schema="wabt.oci.inspect",
        )
        require(
            layout_index.get("graph") == inspected_index.get("graph"),
            "round-tripped index graph summary changed",
        )
        index_output = work / "index-must-not-pull.wasm"
        pull_index = runner.command(
            "WABT rejects direct pull of index",
            [
                str(wabt),
                "oci",
                "pull",
                index_registry_ref,
                "-o",
                str(index_output),
                *wabt_source,
            ],
            expected=1,
        )
        require(not index_output.exists(), "index pull left a partial output")
        require(
            "unsupported OCI content" in pull_index.stderr,
            "index pull did not report the stable unsupported-content category",
        )

        results["artifacts"] = {
            "wkgRoot": wkg_root,
            "wkgConfig": wkg_config_digest,
            "wabtWasmV0Root": wabt_wasm_root,
            "wabtWasmV0Config": wabt_config_digest,
            "orasV10Root": oras_roots["v1.0"],
            "orasV10Config": oras_configs["v1.0"],
            "orasV11Root": oras_roots["v1.1"],
            "orasV11Config": oras_configs["v1.1"],
            "wabtGenericRoot": wabt_oci_root,
            "wabtGenericConfig": descriptor_digest(wabt_oci, "config"),
            "indexRoot": index_digest,
            "payload": f"sha256:{PAYLOAD_SHA256}",
        }
        results["status"] = "passed"
        return_code = 0
    except Exception as error:  # noqa: BLE001 - always persist bounded failure diagnostics
        results["failure"] = bounded_text(str(error))
        print(f"qualification failed: {results['failure']}", file=sys.stderr)
        return_code = 1
    finally:
        results_path.write_text(
            json.dumps(results, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
