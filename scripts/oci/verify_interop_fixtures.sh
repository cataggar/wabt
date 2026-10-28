#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-${RUNNER_TEMP:-$ROOT/.zig-cache}/zig-verify-global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-${RUNNER_TEMP:-$ROOT/.zig-cache}/zig-verify-local}"

zig run "$ROOT/tools/oci_fixture_manifest.zig" -- verify \
  --fixtures "$ROOT/src/fixtures/oci"

echo "verified checked-in OCI interoperability fixtures offline"
