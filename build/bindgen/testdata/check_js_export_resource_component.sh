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
grep -Fq 'export test:js-exported-resources/provider-a@1.0.0;' <<<"$surface"
grep -Fq 'export test:js-exported-resources/provider-b@1.0.0;' <<<"$surface"
grep -Fq 'export test:js-exported-resources/facade@1.0.0;' <<<"$surface"
grep -Fq 'resource item' <<<"$surface"
grep -Fq 'constructor(seed: u32);' <<<"$surface"
grep -Fq 'replace-with: func(next: item) -> item;' <<<"$surface"
grep -Fq 'inspect: func(other: borrow<item>) -> u32;' <<<"$surface"
grep -Fq 'from-double: static func(value: u32) -> item;' <<<"$surface"
