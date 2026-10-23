#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-feed-grid.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
    "$ROOT/IINA-ANI/Workspace/Panels/WorkspaceFeedGridLayout.swift" \
    "$ROOT/Tests/Workspace/WorkspaceFeedGridRegression.swift" \
    -o "$TEMP_DIR/WorkspaceFeedGridRegression"
# Keep this overlay-scroller fixture stable while AppKit loads system preferences; process-local only.
"$TEMP_DIR/WorkspaceFeedGridRegression" -AppleShowScrollBars WhenScrolling
