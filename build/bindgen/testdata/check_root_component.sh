#!/usr/bin/env bash
set -euo pipefail

wit="$1"
core="$2"
component="$3"
embedded="${component}.embedded.wasm"
trap 'rm -f "$embedded"' EXIT

wasm-tools component embed --world guest "$wit" "$core" -o "$embedded"
wasm-tools component new "$embedded" -o "$component"
wasm-tools validate --features all "$component"

surface="$(wasm-tools component wit "$component")"
grep -Fq 'import add-one: func(value: u32) -> u32;' <<<"$surface"
grep -Fq 'import notify: func(message: string);' <<<"$surface"
grep -Fq 'import reshape: func(value: root-record) -> root-record;' <<<"$surface"
grep -Fq 'import flip-choice: func(value: root-choice-alias) -> root-choice-alias;' <<<"$surface"
grep -Fq 'import flip-chain: func(value: alias) -> alias;' <<<"$surface"
grep -Fq 'import translate: func(value: point) -> point;' <<<"$surface"
grep -Fq 'import test:root-imports/host@0.1.0;' <<<"$surface"
