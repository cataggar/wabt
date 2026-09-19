#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${WABT_OCI_INTEROP_MODE:-refresh}"
case "$MODE" in
  refresh | qualify) ;;
  *)
    echo "WABT_OCI_INTEROP_MODE must be refresh or qualify" >&2
    exit 1
    ;;
esac

if [[ "$(uname -s)" != Linux || "$(uname -m)" != aarch64 ]]; then
  echo "pinned fixture refresh requires Linux/arm64; offline verification is portable" >&2
  exit 1
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  : "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required in GitHub Actions}"
  : "${RUNNER_TEMP:?RUNNER_TEMP is required in GitHub Actions}"
  [[ "$ROOT" == "$(cd "$GITHUB_WORKSPACE" && pwd)" ]]
  STATE_ROOT="${WABT_OCI_INTEROP_STATE_DIR:-$RUNNER_TEMP/wabt-oci-interoperability}"
  STATE_ROOT="$(mkdir -p "$STATE_ROOT" && cd "$STATE_ROOT" && pwd)"
  RUNNER_TEMP_REAL="$(cd "$RUNNER_TEMP" && pwd)"
  case "$STATE_ROOT/" in
    "$RUNNER_TEMP_REAL"/*) ;;
    *)
      echo "GitHub Actions state must remain below RUNNER_TEMP" >&2
      exit 1
      ;;
  esac
else
  case "$ROOT" in
    /d/wabt-worktrees/*) ;;
    *)
      echo "fixture generation requires a dedicated /d/wabt-worktrees checkout" >&2
      exit 1
      ;;
  esac
  STATE_ROOT="${WABT_OCI_INTEROP_STATE_DIR:-$ROOT/zig-out/oci-interoperability}"
  STATE_ROOT="$(mkdir -p "$STATE_ROOT" && cd "$STATE_ROOT" && pwd)"
  case "$STATE_ROOT/" in
    /d/*) ;;
    *)
      echo "local interoperability state must remain below /d" >&2
      exit 1
      ;;
  esac
fi

MAX_STATE_KIB="${WABT_OCI_INTEROP_MAX_STATE_KIB:-12582912}"
[[ "$MAX_STATE_KIB" =~ ^[0-9]+$ ]] && [[ "$MAX_STATE_KIB" -gt 0 ]]
ulimit -f 524288

TOOLS="$STATE_ROOT/tools"
CACHE="$STATE_ROOT/cache"
WORK="$STATE_ROOT/work"
RESULTS="$STATE_ROOT/results"
DOWNLOADS="$TOOLS/downloads"
BIN="$TOOLS/bin"
RUSTUP_HOME="$TOOLS/rustup"
CARGO_HOME="$TOOLS/cargo"
CARGO_TARGET_DIR="$TOOLS/cargo-target"
SOURCE="$CACHE/source/wasm-pkg-tools"
TMPDIR="$CACHE/tmp"
HOME="$CACHE/home"
XDG_CACHE_HOME="$CACHE/xdg-cache"
DOCKER_CONFIG="$HOME/.docker"
ORAS_CACHE="$CACHE/oras"
ZIG_GLOBAL_CACHE_DIR="$CACHE/zig-global"
ZIG_LOCAL_CACHE_DIR="$CACHE/zig-local"
export RUSTUP_HOME CARGO_HOME CARGO_TARGET_DIR TMPDIR HOME XDG_CACHE_HOME
export DOCKER_CONFIG ORAS_CACHE ZIG_GLOBAL_CACHE_DIR ZIG_LOCAL_CACHE_DIR
export CARGO_INCREMENTAL=0 PYTHONDONTWRITEBYTECODE=1

ORAS_VERSION=1.3.4
ORAS_COMMIT=db9e29505c3059f2b8fde34ae8cae266c5c765e9
ORAS_CHECKSUMS_SHA=19d479e497fb5e30c7de3c621e3ed337e3857de0d96542021a73e2d8016dbe5a
ORAS_ARCHIVE_SHA=15702c6e3a4a56a8bd8ac5c17efdbcab56d9bada661ccbcf017f5b10c1d89399
WKG_REVISION=5a4c2ab721e12511f39bb9cb42cf71fe76f6c89a
WKG_LOCK_SHA=bf465c989fa26cb06778624fd2de843ca5d6318b4a58418c9e392e13dc02d732
OCI_WASM_SHA=87689298bd74f0f2675fcac99956a34c31098ca3bdced3d7635e71dc03c5ca21
OCI_WASM_COMMIT=8d1cecafef729cbd7240d9701d2dea5eaa6f4fdd
REGISTRY_VERSION=3.1.1
REGISTRY_ARCHIVE_SHA=8167316d2b4a57e10d44f8c8a3c75fea5f3ec1c71872760bb903e5e8e52e9ad6
RUSTUP_VERSION=1.28.2
RUSTUP_SHA=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c
RUST_VERSION=1.97.0
FIXED_CREATED=2026-09-19T00:00:00Z
REGISTRY_HOST=127.0.0.1:55462
PAYLOAD_SHA=0fa2124f4fe3cec3eddb6b73bb4c49c15fbf71d78199b76f1e0bd79ee0a526e9

if [[ -e "$WORK" ]]; then
  echo "unclean fixture work directory: $WORK" >&2
  exit 1
fi

mkdir -p "$DOWNLOADS" "$BIN" "$CACHE" "$TMPDIR" "$HOME" "$XDG_CACHE_HOME"
mkdir -p "$DOCKER_CONFIG" "$CARGO_HOME" "$CARGO_TARGET_DIR" "$(dirname "$SOURCE")"
printf '{"auths":{}}\n' >"$DOCKER_CONFIG/config.json"

download() {
  local url="$1"
  local output="$2"
  if [[ -f "$output" ]]; then
    return
  fi
  python3 - "$url" "$output" <<'PY'
from pathlib import Path
import sys
from urllib.request import Request, urlopen

url, output = sys.argv[1:]
path = Path(output)
partial = path.with_suffix(path.suffix + ".partial")
partial.unlink(missing_ok=True)
request = Request(url, headers={"User-Agent": "wabt-oci-fixture-generator/1"})
try:
    with urlopen(request, timeout=120) as response, partial.open("wb") as stream:
        while chunk := response.read(1024 * 1024):
            stream.write(chunk)
    partial.replace(path)
finally:
    partial.unlink(missing_ok=True)
PY
}

verify_sha() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(sha256sum "$path" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "checksum mismatch for $path: expected $expected, got $actual" >&2
    exit 1
  fi
}

download \
  "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_checksums.txt" \
  "$DOWNLOADS/oras_${ORAS_VERSION}_checksums.txt"
download \
  "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_arm64.tar.gz" \
  "$DOWNLOADS/oras_${ORAS_VERSION}_linux_arm64.tar.gz"
download \
  "https://github.com/distribution/distribution/releases/download/v${REGISTRY_VERSION}/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz" \
  "$DOWNLOADS/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz"
download \
  "https://github.com/distribution/distribution/releases/download/v${REGISTRY_VERSION}/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz.sha256" \
  "$DOWNLOADS/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz.sha256"
download \
  "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/aarch64-unknown-linux-gnu/rustup-init" \
  "$DOWNLOADS/rustup-init"
download \
  "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/aarch64-unknown-linux-gnu/rustup-init.sha256" \
  "$DOWNLOADS/rustup-init.sha256"

verify_sha "$DOWNLOADS/oras_${ORAS_VERSION}_checksums.txt" "$ORAS_CHECKSUMS_SHA"
verify_sha "$DOWNLOADS/oras_${ORAS_VERSION}_linux_arm64.tar.gz" "$ORAS_ARCHIVE_SHA"
verify_sha "$DOWNLOADS/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz" "$REGISTRY_ARCHIVE_SHA"
verify_sha "$DOWNLOADS/rustup-init" "$RUSTUP_SHA"
grep -Fxq \
  "$ORAS_ARCHIVE_SHA  oras_${ORAS_VERSION}_linux_arm64.tar.gz" \
  "$DOWNLOADS/oras_${ORAS_VERSION}_checksums.txt"
grep -Fxq \
  "$REGISTRY_ARCHIVE_SHA" \
  "$DOWNLOADS/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz.sha256"
grep -Fxq \
  "$RUSTUP_SHA *./rustup-init" \
  "$DOWNLOADS/rustup-init.sha256"
[[ "$(GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git ls-remote \
  https://github.com/oras-project/oras.git 'refs/tags/v1.3.4^{}' |
  awk '{print $1}')" == "$ORAS_COMMIT" ]]
[[ "$(GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git ls-remote \
  https://github.com/bytecodealliance/rust-oci-wasm.git refs/tags/v0.6.0 |
  awk '{print $1}')" == "$OCI_WASM_COMMIT" ]]

rm -rf "$TOOLS/oras-extract" "$TOOLS/registry-extract"
mkdir -p "$TOOLS/oras-extract" "$TOOLS/registry-extract"
tar -xzf "$DOWNLOADS/oras_${ORAS_VERSION}_linux_arm64.tar.gz" -C "$TOOLS/oras-extract"
tar -xzf "$DOWNLOADS/registry_${REGISTRY_VERSION}_linux_arm64.tar.gz" -C "$TOOLS/registry-extract"
install -m 0755 "$TOOLS/oras-extract/oras" "$BIN/oras"
install -m 0755 "$TOOLS/registry-extract/registry" "$BIN/registry"
install -m 0755 "$DOWNLOADS/rustup-init" "$BIN/rustup-init"

if [[ ! -x "$CARGO_HOME/bin/rustc" ]] ||
  [[ "$("$CARGO_HOME/bin/rustc" --version 2>/dev/null | awk '{print $2}' || true)" != "$RUST_VERSION" ]]; then
  "$BIN/rustup-init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
fi
export PATH="$CARGO_HOME/bin:$BIN:$PATH"

if [[ "$("$BIN/oras" version | awk '/Version:/{print $2}')" != "$ORAS_VERSION" ]]; then
  echo "wrong ORAS version" >&2
  exit 1
fi
if ! "$BIN/oras" version | grep -Fq "Git commit:     $ORAS_COMMIT"; then
  echo "wrong ORAS commit" >&2
  exit 1
fi
if ! "$BIN/registry" --version | grep -Fq " $REGISTRY_VERSION"; then
  echo "wrong registry version" >&2
  exit 1
fi
if [[ "$(rustc --version | awk '{print $2}')" != "$RUST_VERSION" ]]; then
  echo "wrong Rust compiler version" >&2
  exit 1
fi

rm -rf "$SOURCE"
mkdir -p "$SOURCE"
git -C "$SOURCE" init --quiet
git -C "$SOURCE" remote add origin https://github.com/bytecodealliance/wasm-pkg-tools.git
GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  git -C "$SOURCE" fetch --quiet --depth=1 origin "$WKG_REVISION"
git -C "$SOURCE" checkout --quiet --detach FETCH_HEAD
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$WKG_REVISION" ]]
[[ "$(git -C "$SOURCE" rev-parse HEAD^{tree})" == ea20d1f82502eec5c5bc7315bc0fd7653a154221 ]]
verify_sha "$SOURCE/Cargo.lock" "$WKG_LOCK_SHA"
python3 - "$SOURCE/Cargo.lock" "$OCI_WASM_SHA" <<'PY'
from pathlib import Path
import sys

lock = Path(sys.argv[1]).read_text(encoding="utf-8")
expected = sys.argv[2]
block = lock.split('name = "oci-wasm"', 1)[1].split("\n\n", 1)[0]
if 'version = "0.6.0"' not in block or f'checksum = "{expected}"' not in block:
    raise SystemExit("Cargo.lock does not contain pinned oci-wasm 0.6.0")
PY

cat >"$BIN/zig-cc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    --target=aarch64-unknown-linux-gnu) args+=("-target" "aarch64-linux-gnu") ;;
    *) args+=("$arg") ;;
  esac
done
exec zig cc "${args[@]}"
EOF
cat >"$BIN/zig-cxx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    --target=aarch64-unknown-linux-gnu) args+=("-target" "aarch64-linux-gnu") ;;
    *) args+=("$arg") ;;
  esac
done
exec zig c++ "${args[@]}"
EOF
cat >"$BIN/zig-ar" <<'EOF'
#!/usr/bin/env bash
exec zig ar "$@"
EOF
chmod 0755 "$BIN/zig-cc" "$BIN/zig-cxx" "$BIN/zig-ar"
export CC="$BIN/zig-cc"
export CXX="$BIN/zig-cxx"
export AR="$BIN/zig-ar"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="$BIN/zig-cc"

cargo build --quiet --locked -p wkg --release --manifest-path "$SOURCE/Cargo.toml"
install -m 0755 "$CARGO_TARGET_DIR/release/wkg" "$BIN/wkg"
python3 - "$BIN/wkg" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
data, count = re.subn(
    rb"(/deps/rustc)[A-Za-z0-9]{6}(/raw-dylibs)",
    rb"\1STATIC\2",
    data,
)
if count != 1:
    raise SystemExit(f"expected one Rust raw-dylibs RUNPATH, found {count}")
path.write_bytes(data)
PY
[[ "$("$BIN/wkg" --version)" == "wkg 0.16.1" ]]
OCI_WASM_CRATE="$(find "$CARGO_HOME/registry/cache" -type f -name 'oci-wasm-0.6.0.crate' -print -quit)"
[[ -n "$OCI_WASM_CRATE" ]]
verify_sha "$OCI_WASM_CRATE" "$OCI_WASM_SHA"

zig cc -shared -fPIC -O2 \
  -o "$BIN/fixed_realtime.so" \
  "$ROOT/scripts/oci/fixed_realtime.c"
if [[ "$(LD_PRELOAD="$BIN/fixed_realtime.so" python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)" != "$FIXED_CREATED" ]]; then
  echo "fixed wall-clock interposer did not take effect" >&2
  exit 1
fi

zig build -Doptimize=ReleaseSafe -Dversion=oci-fixtures
WABT="$ROOT/zig-out/bin/wabt"
[[ "$("$WABT" version)" == "wabt oci-fixtures" ]]

mkdir -p "$WORK"/{stage,pulls,layouts,logs,registry-data}
cp "$ROOT/src/component/fixtures/stdio-echo.wasm" "$WORK/stage/component.wasm"
verify_sha "$WORK/stage/component.wasm" "$PAYLOAD_SHA"

python3 - "$REGISTRY_HOST" <<'PY'
import socket
import sys

host, port = sys.argv[1].split(":")
with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, int(port)))
PY
cat >"$WORK/registry.yml" <<EOF
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: $WORK/registry-data
  delete:
    enabled: true
http:
  addr: $REGISTRY_HOST
  headers:
    X-Content-Type-Options: [nosniff]
EOF

REGISTRY_PID=
cleanup() {
  local status=$?
  if [[ -n "${REGISTRY_PID:-}" ]] && kill -0 "$REGISTRY_PID" 2>/dev/null; then
    kill "$REGISTRY_PID"
    wait "$REGISTRY_PID" || true
  fi
  if [[ $status -eq 0 ]]; then
    rm -rf "$WORK"
  else
    echo "fixture generation failed; evidence retained under $WORK" >&2
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

"$BIN/registry" serve "$WORK/registry.yml" >"$WORK/logs/registry.log" 2>&1 &
REGISTRY_PID=$!
REGISTRY_READY=0
for _ in $(seq 1 50); do
  if python3 - "$REGISTRY_HOST" <<'PY' 2>/dev/null
import sys
from urllib.request import urlopen

with urlopen(f"http://{sys.argv[1]}/v2/", timeout=1) as response:
    raise SystemExit(0 if response.status == 200 and response.read() == b"{}" else 1)
PY
  then
    REGISTRY_READY=1
    break
  fi
  sleep 0.1
done
kill -0 "$REGISTRY_PID"
[[ "$REGISTRY_READY" == 1 ]]

run_wabt() {
  "$WABT" "$@"
}

LD_PRELOAD="$BIN/fixed_realtime.so" "$BIN/wkg" oci push \
  --color never \
  --insecure "$REGISTRY_HOST" \
  --author wabt-interop \
  "$REGISTRY_HOST/wabt/wkg:fixture" \
  "$WORK/stage/component.wasm" \
  >"$WORK/logs/wkg-push.txt"
LD_PRELOAD="$BIN/fixed_realtime.so" "$BIN/wkg" oci push \
  --color never \
  --insecure "$REGISTRY_HOST" \
  --author wabt-interop \
  "$REGISTRY_HOST/wabt/wkg:repro" \
  "$WORK/stage/component.wasm" \
  >"$WORK/logs/wkg-push-repro.txt"
WKG_ROOT="$(awk '/^digest:/{print $2}' "$WORK/logs/wkg-push.txt")"
WKG_REPRO_ROOT="$(awk '/^digest:/{print $2}' "$WORK/logs/wkg-push-repro.txt")"
[[ "$WKG_ROOT" == "$WKG_REPRO_ROOT" ]]
run_wabt oci inspect "$REGISTRY_HOST/wabt/wkg:fixture" \
  --plain-http --no-credential-discovery --json \
  >"$WORK/logs/wabt-inspect-wkg.json"
run_wabt oci pull "$REGISTRY_HOST/wabt/wkg:fixture" \
  -o "$WORK/pulls/wkg-by-wabt.wasm" \
  --plain-http --no-credential-discovery --json \
  >"$WORK/logs/wabt-pull-wkg.json"
cmp "$WORK/stage/component.wasm" "$WORK/pulls/wkg-by-wabt.wasm"
run_wabt oci copy "$REGISTRY_HOST/wabt/wkg:fixture" \
  "oci:$WORK/layouts/wkg-wasm-v0:fixture" \
  --source-plain-http --source-no-credential-discovery --json \
  >"$WORK/logs/wabt-copy-wkg-layout.json"

run_wabt oci push "$REGISTRY_HOST/wabt/wabt-v0:fixture" \
  "$WORK/stage/component.wasm" \
  --created "$FIXED_CREATED" --author wabt-interop \
  --plain-http --no-credential-discovery --json \
  >"$WORK/logs/wabt-push-v0.json"
"$BIN/wkg" oci pull --color never --insecure "$REGISTRY_HOST" \
  -o "$WORK/pulls/wabt-v0-by-wkg.wasm" \
  "$REGISTRY_HOST/wabt/wabt-v0:fixture" \
  >"$WORK/logs/wkg-pull-wabt-v0.txt"
cmp "$WORK/stage/component.wasm" "$WORK/pulls/wabt-v0-by-wkg.wasm"
run_wabt oci copy "$REGISTRY_HOST/wabt/wabt-v0:fixture" \
  "oci:$WORK/layouts/wabt-wasm-v0:fixture" \
  --source-plain-http --source-no-credential-discovery --json \
  >"$WORK/logs/wabt-copy-v0-layout.json"

for spec in v1.0 v1.1; do
  tag="oras-$spec"
  layout="oras-oci-$spec"
  (
    cd "$WORK/stage"
    "$BIN/oras" push --plain-http --no-tty \
      --image-spec "$spec" \
      --artifact-type application/wasm \
      --annotation "org.opencontainers.image.created=$FIXED_CREATED" \
      --format json \
      "$REGISTRY_HOST/wabt/oras:$tag" \
      "component.wasm:application/wasm"
  ) >"$WORK/logs/oras-push-$spec.json"
  run_wabt oci inspect "$REGISTRY_HOST/wabt/oras:$tag" \
    --plain-http --no-credential-discovery --json \
    >"$WORK/logs/wabt-inspect-oras-$spec.json"
  run_wabt oci pull "$REGISTRY_HOST/wabt/oras:$tag" \
    -o "$WORK/pulls/oras-$spec-by-wabt.wasm" \
    --plain-http --no-credential-discovery --json \
    >"$WORK/logs/wabt-pull-oras-$spec.json"
  cmp "$WORK/stage/component.wasm" "$WORK/pulls/oras-$spec-by-wabt.wasm"
  run_wabt oci copy "$REGISTRY_HOST/wabt/oras:$tag" \
    "oci:$WORK/layouts/$layout:fixture" \
    --source-plain-http --source-no-credential-discovery --json \
    >"$WORK/logs/wabt-copy-$layout.json"
done

run_wabt oci push "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  "$WORK/stage/component.wasm" \
  --format oci --created "$FIXED_CREATED" \
  --plain-http --no-credential-discovery --json \
  >"$WORK/logs/wabt-push-oci.json"
"$BIN/oras" resolve --plain-http --full-reference \
  "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  >"$WORK/logs/oras-resolve-wabt-oci.txt"
"$BIN/oras" manifest fetch --plain-http \
  "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  >"$WORK/logs/oras-manifest-wabt-oci.json"
mkdir -p "$WORK/pulls/wabt-oci-by-oras"
"$BIN/oras" pull --plain-http --no-tty \
  -o "$WORK/pulls/wabt-oci-by-oras" \
  "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  >"$WORK/logs/oras-pull-wabt-oci.txt"
cmp "$WORK/stage/component.wasm" "$WORK/pulls/wabt-oci-by-oras/component.wasm"
if "$BIN/wkg" oci pull --color never --insecure "$REGISTRY_HOST" \
  -o "$WORK/pulls/wabt-oci-by-wkg.wasm" \
  "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  >"$WORK/logs/wkg-reject-wabt-oci.stdout" \
  2>"$WORK/logs/wkg-reject-wabt-oci.stderr"; then
  echo "wkg unexpectedly accepted generic OCI output" >&2
  exit 1
fi
[[ ! -e "$WORK/pulls/wabt-oci-by-wkg.wasm" ]]
grep -Eiq 'config|media|wasm' "$WORK/logs/wkg-reject-wabt-oci.stderr"
run_wabt oci copy "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  "oci:$WORK/layouts/wabt-oci-v1.1:fixture" \
  --source-plain-http --source-no-credential-discovery --json \
  >"$WORK/logs/wabt-copy-oci-layout.json"

run_wabt oci copy \
  "oci:$WORK/layouts/wabt-oci-v1.1:fixture" \
  "oci:$WORK/layouts/copy-roundtrip:fixture" \
  --json >"$WORK/logs/copy-layout-layout.json"
python3 - \
  "$WORK/logs/copy-layout-layout.json" \
  "$WORK/logs/wabt-push-oci.json" <<'PY'
import json
import sys

left = json.load(open(sys.argv[1], encoding="utf-8"))["root"]["digest"]
right = json.load(open(sys.argv[2], encoding="utf-8"))["root"]["digest"]
if left != right:
    raise SystemExit(f"layout copy root changed: {left} != {right}")
PY
run_wabt oci copy \
  "oci:$WORK/layouts/wkg-wasm-v0:fixture" \
  "$REGISTRY_HOST/wabt/wkg-layout-copy:fixture" \
  --destination-plain-http --destination-no-credential-discovery --json \
  >"$WORK/logs/copy-layout-registry.json"
"$BIN/wkg" oci pull --color never --insecure "$REGISTRY_HOST" \
  -o "$WORK/pulls/wkg-layout-roundtrip.wasm" \
  "$REGISTRY_HOST/wabt/wkg-layout-copy:fixture" \
  >"$WORK/logs/wkg-pull-layout-copy.txt"
cmp "$WORK/stage/component.wasm" "$WORK/pulls/wkg-layout-roundtrip.wasm"
run_wabt oci copy \
  "$REGISTRY_HOST/wabt/oras:oras-v1.1" \
  "$REGISTRY_HOST/wabt/oras-registry-copy:fixture" \
  --source-plain-http --destination-plain-http \
  --source-no-credential-discovery --destination-no-credential-discovery \
  --json >"$WORK/logs/copy-registry-registry.json"
mkdir -p "$WORK/pulls/oras-registry-copy"
"$BIN/oras" pull --plain-http --no-tty \
  -o "$WORK/pulls/oras-registry-copy" \
  "$REGISTRY_HOST/wabt/oras-registry-copy:fixture" \
  >"$WORK/logs/oras-pull-registry-copy.txt"
cmp "$WORK/stage/component.wasm" "$WORK/pulls/oras-registry-copy/component.wasm"

"$BIN/oras" cp --from-plain-http --to-plain-http --no-tty \
  "$REGISTRY_HOST/wabt/oras:oras-v1.1" \
  "$REGISTRY_HOST/wabt/index:oras" \
  >"$WORK/logs/oras-copy-index-oras.txt"
"$BIN/oras" cp --from-plain-http --to-plain-http --no-tty \
  "$REGISTRY_HOST/wabt/wabt-oci:fixture" \
  "$REGISTRY_HOST/wabt/index:wabt" \
  >"$WORK/logs/oras-copy-index-wabt.txt"
"$BIN/oras" manifest index create --plain-http \
  --artifact-type application/wasm \
  --annotation "org.opencontainers.image.created=$FIXED_CREATED" \
  "$REGISTRY_HOST/wabt/index:fixture" oras wabt \
  >"$WORK/logs/oras-create-index.txt"
run_wabt oci inspect "$REGISTRY_HOST/wabt/index:fixture" \
  --plain-http --no-credential-discovery --json \
  >"$WORK/logs/wabt-inspect-index.json"
if run_wabt oci pull "$REGISTRY_HOST/wabt/index:fixture" \
  -o "$WORK/pulls/index.wasm" \
  --plain-http --no-credential-discovery --json \
  >"$WORK/logs/wabt-pull-index.stdout" \
  2>"$WORK/logs/wabt-pull-index.stderr"; then
  echo "WABT unexpectedly extracted an index" >&2
  exit 1
fi
[[ ! -e "$WORK/pulls/index.wasm" ]]
grep -Eiq 'unsupported|direct|manifest|index|extract' "$WORK/logs/wabt-pull-index.stderr"
run_wabt oci copy "$REGISTRY_HOST/wabt/index:fixture" \
  "oci:$WORK/layouts/index:fixture" \
  --source-plain-http --source-no-credential-discovery --json \
  >"$WORK/logs/wabt-copy-index-layout.json"

find "$WORK/layouts" -type f \
  \( -name '.wabt-oci.lock' -o -name '.*.wabt-oci-bootstrap.lock' \) \
  -delete

if [[ "$MODE" == refresh ]]; then
  python3 "$ROOT/scripts/oci/fixture_manifest.py" write \
    --repo "$ROOT" \
    --work "$WORK" \
    --tools "$TOOLS" \
    --update
else
  python3 "$ROOT/scripts/oci/fixture_manifest.py" qualify \
    --repo "$ROOT" \
    --work "$WORK" \
    --tools "$TOOLS"
fi
python3 "$ROOT/scripts/oci/fixture_manifest.py" verify \
  --fixtures "$ROOT/src/fixtures/oci"

rm -rf "$RESULTS"
mkdir -p "$RESULTS"
cp "$ROOT/src/fixtures/oci/manifest.json" "$RESULTS/manifest.json"
printf 'mode=%s\nverified=%s\n' "$MODE" "$FIXED_CREATED" >"$RESULTS/status.txt"

find "$WORK/layouts" \
  \( -name '.wabt-oci*' -o -name '.*.wabt-oci-bootstrap.lock' -o \
  -name '*.partial' -o -name '*.tmp' \) |
  grep . && {
    echo "partial generation output remains" >&2
    exit 1
  }

STATE_KIB="$(du -sk "$STATE_ROOT" | awk '{print $1}')"
if [[ "$STATE_KIB" -gt "$MAX_STATE_KIB" ]]; then
  echo "interoperability state exceeded ${MAX_STATE_KIB} KiB" >&2
  exit 1
fi

echo "$MODE completed for pinned OCI interoperability fixtures"
