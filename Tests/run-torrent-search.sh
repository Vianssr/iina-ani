#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-torrent-search.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
    "$ROOT/IINA-ANI/Features/Torrent/TorrentSearchService.swift" \
    "$ROOT/Tests/Torrent/TorrentSearchRegression.swift" \
    -o "$TEMP_DIR/torrent-search"
"$TEMP_DIR/torrent-search" "$@"
