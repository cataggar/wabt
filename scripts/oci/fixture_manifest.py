#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


SCHEMA = "wabt.oci.interop-fixtures"
FIXED_CREATED = "2026-09-19T00:00:00Z"
PAYLOAD_SHA256 = "0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9"
PAYLOAD_SIZE = 58495
LAYOUT_NAMES = (
    "wkg-wasm-v0",
    "wabt-wasm-v0",
    "oras-oci-v1.0",
    "oras-oci-v1.1",
    "wabt-oci-v1.1",
    "copy-roundtrip",
    "index",
)
NEGATIVE_CASES = {
    "wrong-descriptor-size": {
        "baseLayout": "wabt-oci-v1.1",
        "mutations": [
            {"target": "root.size", "operation": "add", "value": 1},
            {"target": "manifest.config.size", "operation": "add", "value": 1},
            {"target": "manifest.layers[0].size", "operation": "add", "value": 1},
        ],
        "expected": {
            "result": "reject",
            "category": "descriptor-size-mismatch",
            "finalOutput": "absent-or-byte-identical",
            "destinationTag": "absent-or-unchanged",
        },
    },
    "wrong-descriptor-digest": {
        "baseLayout": "wabt-oci-v1.1",
        "mutations": [
            {"target": "root.digest", "operation": "replace", "value": "sha256:" + "0" * 64},
            {
                "target": "manifest.config.digest",
                "operation": "replace",
                "value": "sha256:" + "1" * 64,
            },
            {
                "target": "manifest.layers[0].digest",
                "operation": "replace",
                "value": "sha256:" + "2" * 64,
            },
        ],
        "expected": {
            "result": "reject",
            "category": "descriptor-digest-mismatch",
            "staging": "removed",
            "finalOutput": "absent-or-byte-identical",
            "destinationTag": "absent-or-unchanged",
        },
    },
    "moved-tag": {
        "baseLayout": "wkg-wasm-v0",
        "scenario": {
            "resolve": "original-root",
            "moveTagBeforeBlobReads": "replacement-root",
            "subsequentReads": "original-digest-only",
        },
        "expected": {
            "result": "accept-original",
            "tagResolutions": 1,
            "reportedRoot": "original-root",
        },
    },
    "missing-title": {
        "baseLayout": "wabt-oci-v1.1",
        "mutation": {
            "target": "manifest.layers[0].annotations.org.opencontainers.image.title",
            "operation": "remove",
        },
        "expected": {
            "result": "accept",
            "outputSelection": "explicit-only",
            "payload": "byte-identical",
        },
    },
    "hostile-titles": {
        "baseLayout": "wabt-oci-v1.1",
        "mutation": {
            "target": "manifest.layers[0].annotations.org.opencontainers.image.title",
            "operation": "replace-each",
            "values": [
                "../../escape.wasm",
                "/absolute/escape.wasm",
                "C:\\escape.wasm",
                "\\\\server\\share\\escape.wasm",
                "x" * 4096,
            ],
        },
        "expected": {
            "result": "accept-explicit-output",
            "createdPaths": ["explicit-output"],
            "unsafeDiagnosticEcho": False,
        },
    },
    "layer-count": {
        "baseLayout": "wabt-oci-v1.1",
        "mutations": [
            {"target": "manifest.layers", "operation": "replace", "value": []},
            {
                "target": "manifest.layers",
                "operation": "duplicate-first",
                "count": 2,
            },
        ],
        "expected": {
            "inspect": "accept-descriptors",
            "pull": "reject",
            "category": "invalid-layer-count",
            "finalOutput": "absent",
        },
    },
    "tar-labeled-raw-wasm": {
        "baseLayout": "wabt-oci-v1.1",
        "mutation": {
            "target": "manifest.layers[0].mediaType",
            "operation": "replace",
            "value": "application/vnd.oci.image.layer.v1.tar",
        },
        "expected": {
            "result": "reject",
            "category": "unsupported-layer-media-type",
            "unpacked": False,
            "finalOutput": "absent",
        },
    },
    "unsupported-media-types": {
        "baseLayout": "wabt-oci-v1.1",
        "mutations": [
            {
                "target": "root.mediaType",
                "operation": "replace",
                "value": "application/vnd.example.root",
            },
            {
                "target": "manifest.config.mediaType",
                "operation": "replace",
                "value": "application/vnd.example.config",
            },
            {
                "target": "manifest.layers[0].mediaType",
                "operation": "replace",
                "value": "application/vnd.example.layer",
            },
        ],
        "expected": {
            "result": "reject",
            "category": "unsupported-profile-or-media-type",
            "finalOutput": "absent",
        },
    },
    "index-extraction": {
        "baseLayout": "index",
        "expected": {
            "inspect": "accept-complete-graph",
            "copy": "preserve-complete-graph",
            "pull": "reject",
            "platformSelection": False,
            "finalOutput": "absent",
        },
    },
    "interrupted-publication": {
        "baseLayout": "wabt-oci-v1.1",
        "failurePoints": [
            "truncated-layer-download",
            "interrupted-blob-upload",
            "declined-cross-repository-mount",
            "final-manifest-put",
            "final-tag-put",
        ],
        "expected": {
            "result": "reject",
            "rootPublishedBeforeDependencies": False,
            "committedDigestPrinted": False,
            "finalOutput": "absent-or-byte-identical",
            "destinationTag": "absent-or-unchanged",
        },
    },
}


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path, base):
    return {
        "path": path.relative_to(base).as_posix(),
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def descriptor_key(descriptor):
    return (
        descriptor["mediaType"],
        descriptor["digest"],
        descriptor["size"],
    )


def graph_for_layout(layout_path):
    index = json.loads((layout_path / "index.json").read_text(encoding="utf-8"))
    roots = index.get("manifests")
    if not isinstance(roots, list) or not roots:
        raise ValueError(f"{layout_path}: missing layout roots")

    entries = {}
    documents = set()

    def add(descriptor, role):
        key = descriptor_key(descriptor)
        item = entries.setdefault(
            key,
            {
                "mediaType": descriptor["mediaType"],
                "digest": descriptor["digest"],
                "size": descriptor["size"],
                "roles": [],
            },
        )
        if role not in item["roles"]:
            item["roles"].append(role)
        return item

    def blob_path(descriptor):
        algorithm, encoded = descriptor["digest"].split(":", 1)
        if algorithm != "sha256" or len(encoded) != 64:
            raise ValueError(f"{layout_path}: unsupported digest {descriptor['digest']}")
        return layout_path / "blobs" / "sha256" / encoded

    def visit_document(descriptor, role):
        add(descriptor, role)
        key = descriptor_key(descriptor)
        if key in documents:
            return
        documents.add(key)
        path = blob_path(descriptor)
        data = path.read_bytes()
        if len(data) != descriptor["size"] or sha256_bytes(data) != descriptor["digest"][7:]:
            raise ValueError(f"{layout_path}: corrupt descriptor {descriptor['digest']}")
        document = json.loads(data)
        media_type = descriptor["mediaType"]
        if media_type == "application/vnd.oci.image.index.v1+json":
            for child in document.get("manifests", []):
                visit_document(child, "child-manifest")
        elif media_type == "application/vnd.oci.image.manifest.v1+json":
            add(document["config"], "config")
            for layer in document.get("layers", []):
                add(layer, "payload")
        else:
            raise ValueError(f"{layout_path}: unsupported document {media_type}")

    root_records = []
    for root in roots:
        visit_document(root, "root")
        root_records.append(
            {
                "mediaType": root["mediaType"],
                "digest": root["digest"],
                "size": root["size"],
                "tag": (root.get("annotations") or {}).get(
                    "org.opencontainers.image.ref.name"
                ),
            }
        )

    for item in entries.values():
        path = blob_path(item)
        data = path.read_bytes()
        if len(data) != item["size"] or sha256_bytes(data) != item["digest"][7:]:
            raise ValueError(f"{layout_path}: corrupt blob {item['digest']}")
        item["roles"].sort()

    return {
        "roots": root_records,
        "descriptors": sorted(entries.values(), key=lambda item: item["digest"]),
    }


def run_output(argv, env=None):
    return subprocess.run(
        argv,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    ).stdout.strip()


def binary_record(path, version_output):
    return {
        "versionOutput": version_output.splitlines(),
        "sha256": sha256_file(path),
    }


def layout_commands():
    registry = "${REGISTRY}"
    payload = "${PAYLOAD}"
    return {
        "wkg-wasm-v0": [
            [
                "wkg",
                "oci",
                "push",
                "--color",
                "never",
                "--insecure",
                registry,
                "--author",
                "wabt-interop",
                f"{registry}/wabt/wkg:fixture",
                payload,
            ],
            [
                "wabt",
                "oci",
                "copy",
                f"{registry}/wabt/wkg:fixture",
                "oci:${LAYOUT}:fixture",
                "--source-plain-http",
                "--source-no-credential-discovery",
                "--json",
            ],
        ],
        "wabt-wasm-v0": [
            [
                "wabt",
                "oci",
                "push",
                f"{registry}/wabt/wabt-v0:fixture",
                payload,
                "--created",
                FIXED_CREATED,
                "--author",
                "wabt-interop",
                "--plain-http",
                "--no-credential-discovery",
                "--json",
            ]
        ],
        "oras-oci-v1.0": [
            [
                "oras",
                "push",
                "--plain-http",
                "--no-tty",
                "--image-spec",
                "v1.0",
                "--artifact-type",
                "application/wasm",
                "--annotation",
                f"org.opencontainers.image.created={FIXED_CREATED}",
                f"{registry}/wabt/oras:oras-v1.0",
                "component.wasm:application/wasm",
            ]
        ],
        "oras-oci-v1.1": [
            [
                "oras",
                "push",
                "--plain-http",
                "--no-tty",
                "--image-spec",
                "v1.1",
                "--artifact-type",
                "application/wasm",
                "--annotation",
                f"org.opencontainers.image.created={FIXED_CREATED}",
                f"{registry}/wabt/oras:oras-v1.1",
                "component.wasm:application/wasm",
            ]
        ],
        "wabt-oci-v1.1": [
            [
                "wabt",
                "oci",
                "push",
                f"{registry}/wabt/wabt-oci:fixture",
                payload,
                "--format",
                "oci",
                "--created",
                FIXED_CREATED,
                "--plain-http",
                "--no-credential-discovery",
                "--json",
            ]
        ],
        "copy-roundtrip": [
            [
                "wabt",
                "oci",
                "copy",
                "oci:${WABT_OCI_LAYOUT}:fixture",
                "oci:${COPY_LAYOUT}:fixture",
                "--json",
            ]
        ],
        "index": [
            [
                "oras",
                "manifest",
                "index",
                "create",
                "--plain-http",
                "--artifact-type",
                "application/wasm",
                "--annotation",
                f"org.opencontainers.image.created={FIXED_CREATED}",
                f"{registry}/wabt/index:fixture",
                "oras",
                "wabt",
            ]
        ],
    }


def layout_expectations():
    return {
        "wkg-wasm-v0": ("wkg", "wasm-v0", "accept"),
        "wabt-wasm-v0": ("wabt", "wasm-v0", "accept"),
        "oras-oci-v1.0": ("oras", "oci-1.0", "accept"),
        "oras-oci-v1.1": ("oras", "oci-1.1", "accept"),
        "wabt-oci-v1.1": ("wabt", "oci-1.1", "accept"),
        "copy-roundtrip": ("wabt-copy", "oci-1.1", "accept"),
        "index": ("oras+wabt", None, "reject-extraction"),
    }


def create_readme(path):
    path.write_text(
        """# OCI interoperability fixtures

These committed OCI layouts are untrusted test data. They prove only the
transport/profile assertions recorded in `manifest.json`; they are not signed
packages, runtime compatibility evidence, or a production-readiness claim.

Offline verification:

```sh
scripts/oci/verify_interop_fixtures.sh
```

Pinned Linux/arm64 regeneration (network and a loopback-only disposable
registry are required):

```sh
scripts/oci/generate_interop_fixtures.sh
```

The fixed producer timestamp is `2026-09-19T00:00:00Z`. External tools are
fixture producers only and are never needed by WABT at runtime or by ordinary
tests.
""",
        encoding="utf-8",
    )


def publish_candidate(candidate, target):
    backup = target.with_name(target.name + ".previous")
    if backup.exists():
        shutil.rmtree(backup)
    if target.exists():
        target.rename(backup)
    try:
        candidate.rename(target)
    except Exception:
        if backup.exists() and not target.exists():
            backup.rename(target)
        raise
    if backup.exists():
        shutil.rmtree(backup)


def compare_trees(expected, actual):
    expected_files = {
        path.relative_to(expected).as_posix(): path
        for path in expected.rglob("*")
        if path.is_file()
    }
    actual_files = {
        path.relative_to(actual).as_posix(): path
        for path in actual.rglob("*")
        if path.is_file()
    }
    if set(expected_files) != set(actual_files):
        missing = sorted(set(expected_files) - set(actual_files))
        extra = sorted(set(actual_files) - set(expected_files))
        raise ValueError(
            f"regeneration file set drift; missing={missing}, extra={extra}"
        )
    changed = [
        relative
        for relative in sorted(expected_files)
        if expected_files[relative].read_bytes() != actual_files[relative].read_bytes()
    ]
    if changed:
        raise ValueError(f"regeneration byte drift: {changed}")


def build_manifest(args, candidate):
    root = Path(args.repo).resolve()
    work = Path(args.work).resolve()
    tools = Path(args.tools).resolve()
    cache = tools.parent / "oci-cache"
    source = cache / "source" / "wasm-pkg-tools"
    cargo_home = tools / "cargo"
    rustup_home = tools / "rustup"
    toolchain_bin = (
        rustup_home
        / "toolchains"
        / "1.97.0-aarch64-unknown-linux-gnu"
        / "bin"
    )
    tool_bin = tools / "bin"
    wabt = root / "zig-out" / "bin" / "wabt"
    rust_env = os.environ.copy()
    rust_env["CARGO_HOME"] = str(cargo_home)
    rust_env["RUSTUP_HOME"] = str(rustup_home)

    zig_path = Path(shutil.which("zig") or "")
    python_path = Path(sys.executable)
    producers = {
        "oras": {
            "version": "1.3.4",
            "tag": "v1.3.4",
            "commit": "db9e29505c3059f2b8fde34ae8cae266c5c765e9",
            "releaseUrl": "https://github.com/oras-project/oras/releases/tag/v1.3.4",
            "checksumList": {
                "url": "https://github.com/oras-project/oras/releases/download/v1.3.4/oras_1.3.4_checksums.txt",
                "sha256": "19d479e497fb5e30c7de3c621e3ed337e3857de0d96542021a73e2d8016dbe5a",
            },
            "archive": {
                "name": "oras_1.3.4_linux_arm64.tar.gz",
                "url": "https://github.com/oras-project/oras/releases/download/v1.3.4/oras_1.3.4_linux_arm64.tar.gz",
                "sha256": "15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399",
            },
            "binary": binary_record(
                tool_bin / "oras", run_output([tool_bin / "oras", "version"])
            ),
        },
        "wkg": {
            "version": "0.16.1",
            "sourceRevision": "5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a",
            "sourceTree": "ea20d1f82502eec5c5bc7315bc0fd7653a154221",
            "sourceUrl": "https://github.com/bytecodealliance/wasm-pkg-tools/tree/5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a",
            "cargoLockSha256": "bf465c989fa26cb06778624fd2de843ca5d6318b4a58418c9e392e13dc02d732",
            "binary": binary_record(
                tool_bin / "wkg", run_output([tool_bin / "wkg", "--version"])
            ),
            "build": {
                "argv": ["cargo", "build", "--locked", "-p", "wkg", "--release"],
                "binaryNormalization": {
                    "operation": "replace-rustc-temporary-raw-dylibs-directory-with-rustcSTATIC",
                    "reason": "Zig cc records Rust's random temporary raw-dylibs directory in RUNPATH; the directory is unused after static release linking",
                },
                "compiler": binary_record(
                    toolchain_bin / "rustc",
                    run_output(
                        [toolchain_bin / "rustc", "--version", "--verbose"],
                        rust_env,
                    ),
                ),
                "cargo": binary_record(
                    toolchain_bin / "cargo",
                    run_output(
                        [toolchain_bin / "cargo", "--version", "--verbose"],
                        rust_env,
                    ),
                ),
                "zigLinker": binary_record(zig_path, run_output(["zig", "version"])),
            },
        },
        "oci-wasm": {
            "version": "0.6.0",
            "crateChecksumSha256": "87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21",
            "tag": "v0.6.0",
            "tagCommit": "8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd",
            "sourceTree": "f2c85bbff39d344247d244caece52d98307ae2cc",
            "sourceUrl": "https://github.com/bytecodealliance/rust-oci-wasm/tree/v0.6.0",
        },
        "registry": {
            "version": "3.1.1",
            "releaseUrl": "https://github.com/distribution/distribution/releases/tag/v3.1.1",
            "archive": {
                "name": "registry_3.1.1_linux_arm64.tar.gz",
                "url": "https://github.com/distribution/distribution/releases/download/v3.1.1/registry_3.1.1_linux_arm64.tar.gz",
                "sha256": "8167316d2b4a57e10d44f8c8a3c75fea5f3ec1c71872760bb903e5e8e52e9ad6",
            },
            "binary": binary_record(
                tool_bin / "registry",
                "registry "
                + run_output([tool_bin / "registry", "--version"]).split(" ", 1)[1],
            ),
            "scope": "loopback-only ephemeral fixture producer",
        },
        "fixedRealtime": {
            "fixedUtc": FIXED_CREATED,
            "source": {
                "path": "scripts/oci/fixed_realtime.c",
                "sha256": sha256_file(root / "scripts" / "oci" / "fixed_realtime.c"),
            },
            "binarySha256": sha256_file(tool_bin / "fixed_realtime.so"),
            "scope": "fixture refresh only; monotonic clocks remain real",
        },
        "rustup": {
            "version": "1.28.2",
            "archive": {
                "url": "https://static.rust-lang.org/rustup/archive/1.28.2/aarch64-unknown-linux-gnu/rustup-init",
                "sha256": "e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c",
            },
            "binarySha256": sha256_file(tool_bin / "rustup-init"),
        },
        "python": binary_record(
            python_path, run_output([python_path, "--version"])
        ),
        "wabtUnderTest": binary_record(wabt, run_output([wabt, "version"])),
    }
    if sha256_file(source / "Cargo.lock") != producers["wkg"]["cargoLockSha256"]:
        raise ValueError("wkg Cargo.lock changed")
    if run_output(["git", "-C", source, "rev-parse", "HEAD"]) != producers["wkg"][
        "sourceRevision"
    ]:
        raise ValueError("wkg source revision changed")

    layouts = {}
    commands = layout_commands()
    expectations = layout_expectations()
    for name in LAYOUT_NAMES:
        layout_path = candidate / "layouts" / name
        graph = graph_for_layout(layout_path)
        producer, profile, extraction = expectations[name]
        layouts[name] = {
            "producer": producer,
            "commands": commands[name],
            "expected": {
                "inspection": "accept",
                "extraction": extraction,
                "profile": profile,
                "payloadSha256": None if name == "index" else PAYLOAD_SHA256,
            },
            **graph,
        }

    roots = {
        name: layouts[name]["roots"][0]["digest"] for name in LAYOUT_NAMES
    }
    matrix = [
        {
            "id": "wkg-to-wabt",
            "producer": "wkg 0.16.1",
            "consumer": "WABT",
            "result": "pass",
            "rootDigest": roots["wkg-wasm-v0"],
            "payloadSha256": PAYLOAD_SHA256,
            "assertions": ["accepted-wasm-v0", "byte-identical-payload"],
        },
        {
            "id": "wabt-wasm-v0-to-wkg",
            "producer": "WABT",
            "consumer": "wkg 0.16.1",
            "result": "pass",
            "rootDigest": roots["wabt-wasm-v0"],
            "payloadSha256": PAYLOAD_SHA256,
            "assertions": ["accepted-wasm-v0", "byte-identical-payload"],
        },
        {
            "id": "oras-oci-1.0-to-wabt",
            "producer": "ORAS 1.3.4",
            "consumer": "WABT",
            "result": "pass",
            "rootDigest": roots["oras-oci-v1.0"],
            "payloadSha256": PAYLOAD_SHA256,
            "assertions": ["accepted-documented-oci-1.0", "byte-identical-payload"],
        },
        {
            "id": "oras-oci-1.1-to-wabt",
            "producer": "ORAS 1.3.4",
            "consumer": "WABT",
            "result": "pass",
            "rootDigest": roots["oras-oci-v1.1"],
            "payloadSha256": PAYLOAD_SHA256,
            "assertions": ["accepted-oci-1.1", "byte-identical-payload"],
        },
        {
            "id": "wabt-generic-to-oras",
            "producer": "WABT",
            "consumer": "ORAS 1.3.4",
            "result": "pass",
            "rootDigest": roots["wabt-oci-v1.1"],
            "payloadSha256": PAYLOAD_SHA256,
            "assertions": [
                "resolve",
                "manifest-fetch",
                "pull",
                "byte-identical-payload",
            ],
        },
        {
            "id": "wabt-generic-to-wkg",
            "producer": "WABT",
            "consumer": "wkg 0.16.1",
            "result": "pass-expected-rejection",
            "rootDigest": roots["wabt-oci-v1.1"],
            "assertions": [
                "nonzero-exit",
                "generic-config-incompatible",
                "no-output",
            ],
        },
        {
            "id": "digest-preserving-copies",
            "producer": "WABT copy",
            "consumer": "WABT, ORAS 1.3.4, wkg 0.16.1",
            "result": "pass",
            "rootDigest": roots["copy-roundtrip"],
            "assertions": [
                "registry-to-layout",
                "layout-to-layout",
                "layout-to-registry",
                "registry-to-registry",
                "exact-root-bytes",
                "exact-child-digests",
                "byte-identical-payload",
            ],
        },
        {
            "id": "index-preservation-and-extraction-rejection",
            "producer": "ORAS 1.3.4 + WABT",
            "consumer": "WABT",
            "result": "pass",
            "rootDigest": roots["index"],
            "assertions": [
                "inspect-complete-graph",
                "copy-complete-graph",
                "pull-rejected",
                "no-platform-selection",
                "no-output",
            ],
        },
    ]
    matrix.extend(
        {
            "id": f"negative-{case_id}",
            "producer": "checked-in mutation",
            "consumer": "hermetic WABT fixture tests",
            "result": "pass",
            "assertions": [data["expected"]],
        }
        for case_id, data in NEGATIVE_CASES.items()
    )

    fixture_files = []
    for path in sorted(candidate.rglob("*")):
        if path.is_file() and path.name != "manifest.json":
            fixture_files.append(file_record(path, candidate))

    return {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "fixedCreated": FIXED_CREATED,
        "executionPlatform": "linux/arm64",
        "generator": {
            "ordinaryVerification": "offline",
            "sources": [
                file_record(root / relative, root)
                for relative in (
                    Path("scripts/oci/fixed_realtime.c"),
                    Path("scripts/oci/fixture_manifest.py"),
                    Path("scripts/oci/generate_interop_fixtures.sh"),
                    Path("scripts/oci/verify_interop_fixtures.sh"),
                )
            ],
        },
        "profiles": {
            "core": {
                "path": "profiles/core.wasm",
                "kind": "core-module",
                "size": 8,
                "sha256": sha256_file(candidate / "profiles" / "core.wasm"),
                "expected": {"wasmV0Target": "wasip1"},
            },
            "component": {
                "path": "profiles/component.wasm",
                "kind": "component",
                "size": PAYLOAD_SIZE,
                "sha256": PAYLOAD_SHA256,
                "expected": {
                    "wasmV0Target": "wasip2",
                    "payload": "byte-identical",
                },
            },
        },
        "producers": producers,
        "layouts": layouts,
        "negativeCases": [
            {
                "id": case_id,
                "path": f"negative/{case_id}.json",
                "expectedResult": data["expected"].get(
                    "result", data["expected"].get("pull")
                ),
            }
            for case_id, data in NEGATIVE_CASES.items()
        ],
        "matrix": matrix,
        "fixtureFiles": fixture_files,
    }


def assemble(args):
    root = Path(args.repo).resolve()
    work = Path(args.work).resolve()
    target = root / "src" / "fixtures" / "oci"
    candidate = work / "candidate"
    if candidate.exists():
        shutil.rmtree(candidate)
    (candidate / "profiles").mkdir(parents=True)
    (candidate / "layouts").mkdir()
    (candidate / "negative").mkdir()

    component = root / "src" / "component" / "fixtures" / "stdio-echo.wasm"
    if component.stat().st_size != PAYLOAD_SIZE or sha256_file(component) != PAYLOAD_SHA256:
        raise ValueError("component payload changed")
    shutil.copyfile(component, candidate / "profiles" / "component.wasm")
    (candidate / "profiles" / "core.wasm").write_bytes(b"\x00asm\x01\x00\x00\x00")

    for name in LAYOUT_NAMES:
        source = work / "layouts" / name
        if not source.is_dir():
            raise ValueError(f"missing generated layout {name}")
        shutil.copytree(source, candidate / "layouts" / name)

    for case_id, data in NEGATIVE_CASES.items():
        document = {
            "schema": "wabt.oci.negative-fixture",
            "schemaVersion": 1,
            "id": case_id,
            **data,
        }
        (candidate / "negative" / f"{case_id}.json").write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    create_readme(candidate / "README.md")
    manifest = build_manifest(args, candidate)
    (candidate / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    verify_tree(candidate)
    if target.exists():
        compare_trees(target, candidate)
        shutil.rmtree(candidate)
    else:
        publish_candidate(candidate, target)
    verify_tree(target)


def verify_tree(target):
    manifest_path = target / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != SCHEMA or manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported fixture manifest")
    if manifest.get("fixedCreated") != FIXED_CREATED:
        raise ValueError("fixture timestamp drift")
    if manifest.get("executionPlatform") != "linux/arm64":
        raise ValueError("fixture producer platform drift")
    repo = target.parents[2]
    generator = manifest.get("generator", {})
    if generator.get("ordinaryVerification") != "offline":
        raise ValueError("ordinary fixture verification must remain offline")
    for source in generator.get("sources", []):
        path = repo / source["path"]
        if path.stat().st_size != source["size"] or sha256_file(path) != source["sha256"]:
            raise ValueError(f"fixture generator source drift: {source['path']}")

    producers = manifest["producers"]
    required = {
        ("oras", "version"): "1.3.4",
        ("oras", "commit"): "db9e29505c3059f2b8fde34ae8cae266c5c765e9",
        ("wkg", "version"): "0.16.1",
        ("wkg", "sourceRevision"): "5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a",
        ("wkg", "cargoLockSha256"): "bf465c989fa26cb06778624fd2de843ca5d6318b4a58418c9e392e13dc02d732",
        ("oci-wasm", "version"): "0.6.0",
        ("oci-wasm", "crateChecksumSha256"): "87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21",
        ("oci-wasm", "tagCommit"): "8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd",
        ("registry", "version"): "3.1.1",
    }
    for (producer, field), expected in required.items():
        if producers[producer][field] != expected:
            raise ValueError(f"{producer} {field} drift")

    component = target / manifest["profiles"]["component"]["path"]
    if component.stat().st_size != PAYLOAD_SIZE or sha256_file(component) != PAYLOAD_SHA256:
        raise ValueError("component profile drift")
    core = target / manifest["profiles"]["core"]["path"]
    if core.read_bytes() != b"\x00asm\x01\x00\x00\x00":
        raise ValueError("core profile drift")

    expected_files = {
        item["path"]: (item["size"], item["sha256"])
        for item in manifest["fixtureFiles"]
    }
    actual_files = {
        path.relative_to(target).as_posix(): path
        for path in target.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    }
    if set(expected_files) != set(actual_files):
        missing = sorted(set(expected_files) - set(actual_files))
        extra = sorted(set(actual_files) - set(expected_files))
        raise ValueError(f"fixture file set drift; missing={missing}, extra={extra}")
    for relative, path in actual_files.items():
        size, digest = expected_files[relative]
        if path.stat().st_size != size or sha256_file(path) != digest:
            raise ValueError(f"fixture file drift: {relative}")

    if set(manifest["layouts"]) != set(LAYOUT_NAMES):
        raise ValueError("layout set drift")
    for name, expected in manifest["layouts"].items():
        actual = graph_for_layout(target / "layouts" / name)
        if actual["roots"] != expected["roots"]:
            raise ValueError(f"{name}: root drift")
        if actual["descriptors"] != expected["descriptors"]:
            raise ValueError(f"{name}: descriptor drift")
        if not expected.get("commands") or not all(
            isinstance(command, list) and command for command in expected["commands"]
        ):
            raise ValueError(f"{name}: missing generation argv")

    negative = {
        item["id"]: item["path"] for item in manifest.get("negativeCases", [])
    }
    if set(negative) != set(NEGATIVE_CASES):
        raise ValueError("negative fixture set drift")
    for case_id, relative in negative.items():
        document = json.loads((target / relative).read_text(encoding="utf-8"))
        if (
            document.get("schema") != "wabt.oci.negative-fixture"
            or document.get("schemaVersion") != 1
            or document.get("id") != case_id
        ):
            raise ValueError(f"invalid negative fixture {case_id}")

    required_matrix = {
        "wkg-to-wabt",
        "wabt-wasm-v0-to-wkg",
        "oras-oci-1.0-to-wabt",
        "oras-oci-1.1-to-wabt",
        "wabt-generic-to-oras",
        "wabt-generic-to-wkg",
        "digest-preserving-copies",
        "index-preservation-and-extraction-rejection",
        *(f"negative-{case_id}" for case_id in NEGATIVE_CASES),
    }
    matrix = manifest.get("matrix", [])
    if {item.get("id") for item in matrix} != required_matrix:
        raise ValueError("fixture matrix drift")
    if any(not str(item.get("result", "")).startswith("pass") for item in matrix):
        raise ValueError("fixture matrix contains a non-passing result")

    leftovers = [
        path
        for path in target.rglob("*")
        if path.name.startswith(".wabt-oci")
        or path.name.endswith(".wabt-oci-bootstrap.lock")
        or path.name.endswith(".partial")
        or path.name.endswith(".tmp")
    ]
    if leftovers:
        raise ValueError(f"partial fixture output remains: {leftovers}")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    write = subparsers.add_parser("write")
    write.add_argument("--repo", required=True)
    write.add_argument("--work", required=True)
    write.add_argument("--tools", required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--fixtures", required=True)
    args = parser.parse_args()

    try:
        if args.command == "write":
            assemble(args)
        else:
            verify_tree(Path(args.fixtures).resolve())
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"fixture verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
