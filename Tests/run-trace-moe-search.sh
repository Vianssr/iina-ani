#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-trace-moe-search.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
    "$ROOT/IINA-ANI/Features/Discovery/TraceMoeSearchService.swift" \
    "$ROOT/Tests/Discovery/TraceMoeSearchRegression.swift" \
    -o "$TEMP_DIR/trace-moe-search"
"$TEMP_DIR/trace-moe-search" "$@"
