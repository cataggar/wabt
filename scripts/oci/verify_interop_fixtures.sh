#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1

python3 "$ROOT/scripts/oci/fixture_manifest.py" verify \
  --fixtures "$ROOT/src/fixtures/oci"

echo "verified checked-in OCI interoperability fixtures offline"
