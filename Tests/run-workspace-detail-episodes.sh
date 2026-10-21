#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/.build/xcode/Build}"
PRODUCTS="$BUILD/Products/Debug"
APP_BINARY="$PRODUCTS/IINA-ANI.app/Contents/MacOS"
PACKAGES="$BUILD/../SourcePackages/checkouts"
if [[ ! -f "$APP_BINARY/IINA-ANI.debug.dylib" ]]; then
    echo "Build the Debug IINA-ANI app using the README command first." >&2
    exit 1
fi
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-detail-episodes.XXXXXX")"
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
    "$ROOT/Tests/Workspace/WorkspaceDetailEpisodeRegression.swift" \
    -Xlinker "$APP_BINARY/IINA-ANI.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -Xlinker -rpath -Xlinker "$APP_BINARY" \
    -o "$TEMP_DIR/WorkspaceDetailEpisodeRegression"
mkdir -p "$TEMP_DIR/home"
CFFIXED_USER_HOME="$TEMP_DIR/home" "$TEMP_DIR/WorkspaceDetailEpisodeRegression"
