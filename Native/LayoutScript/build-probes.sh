#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/.build/LayoutScriptSandboxProbes}"
mkdir -p "$(dirname "$OUT")"
TMP="${OUT}.universal.$$"
trap 'rm -f "$TMP" "${TMP}.arm64" "${TMP}.x86_64"' EXIT
for ARCH in arm64 x86_64; do
  xcrun --sdk macosx swiftc -swift-version 6 -DLAYOUT_HELPER_PROBES -target "${ARCH}-apple-macosx13.5" -framework Foundation -framework JavaScriptCore -framework Security "$ROOT/Native/LayoutScript/main.swift" -o "${TMP}.${ARCH}"
done
xcrun lipo -create "${TMP}.arm64" "${TMP}.x86_64" -output "$TMP"
mv "$TMP" "$OUT"
"$OUT"
