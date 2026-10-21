#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/.build/xcode/Build}"
PRODUCTS="$BUILD/Products/Debug"
APP="$PRODUCTS/IINA-ANI.app"
PACKAGES="$BUILD/../SourcePackages/checkouts"
if [[ ! -f "$APP/Contents/MacOS/IINA-ANI.debug.dylib" ]]; then
    echo "Build the Debug IINA-ANI app first." >&2
    exit 1
fi
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-w11-range.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
FLAGS=(-I "$PRODUCTS" -F "$PRODUCTS" -I "$ROOT/Native/include"
    -I "$PACKAGES/SDWebImage/SDWebImage/include"
    -I "$PACKAGES/swift-atomics/Sources/_AtomicsShims/include"
    -I "$PACKAGES/GzipSwift/Sources/system-zlib"
    -I "$PACKAGES/swift-nio/Sources/CNIOWindows/include")
for module in "$BUILD/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
    FLAGS+=(-Xcc "-fmodule-map-file=$module")
done
xcrun swiftc -swift-version 6 -parse-as-library "${FLAGS[@]}" \
    "$ROOT/Tests/Torrent/TorrentHTTPRangeRegression.swift" \
    -Xlinker "$APP/Contents/MacOS/IINA-ANI.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -Xlinker -rpath -Xlinker "$APP/Contents/MacOS" \
    -o "$TEMP_DIR/TorrentHTTPRangeRegression"
"$TEMP_DIR/TorrentHTTPRangeRegression"
