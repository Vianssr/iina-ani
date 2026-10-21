#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/xcode/Build"
PRODUCTS="$BUILD/Products/Debug"
APP_BINARY="$PRODUCTS/IINA-ANI.app/Contents/MacOS"
PACKAGES="$ROOT/.build/xcode/SourcePackages/checkouts"
if [[ ! -f "$APP_BINARY/IINA-ANI.debug.dylib" ]]; then
    echo "Build the Debug IINA-ANI app using the README command first." >&2
    exit 1
fi
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-w6-downloads.XXXXXX")"
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
    "$ROOT/Tests/Downloads/DownloadRegression.swift" \
    -Xlinker "$APP_BINARY/IINA-ANI.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -Xlinker -rpath -Xlinker "$APP_BINARY" \
    -o "$TEMP_DIR/DownloadRegression"
mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/media"
/usr/bin/python3 "$ROOT/Tests/Downloads/DownloadFixtureMedia.py" "$TEMP_DIR/media"
CFFIXED_USER_HOME="$TEMP_DIR/home" "$TEMP_DIR/DownloadRegression" \
    "$ROOT/Tests/Downloads/DownloadHTTPFixture.py" "$TEMP_DIR/media"
