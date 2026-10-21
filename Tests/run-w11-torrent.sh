#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/xcode/Build"
PRODUCTS="$BUILD/Products/Debug"
APP_BINARY="$PRODUCTS/IINA-ANI.app/Contents/MacOS"
PACKAGES="$ROOT/.build/xcode/SourcePackages/checkouts"
FIXTURE="$ROOT/.build/torrent/$(uname -m)/install/bin/torrent-fixture"
if [[ ! -f "$APP_BINARY/IINA-ANI.debug.dylib" || ! -x "$FIXTURE" ]]; then
    echo "Build the Debug IINA-ANI app using the README command first." >&2
    exit 1
fi
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-w11-torrent.XXXXXX")"
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
    "$ROOT/Tests/Torrent/TorrentCoreRegression.swift" \
    -Xlinker "$APP_BINARY/IINA-ANI.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -Xlinker -rpath -Xlinker "$APP_BINARY" \
    -o "$TEMP_DIR/TorrentCoreRegression"
mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/seed"
# Self-created bytes, including a partial final piece; no copyrighted media.
xcrun swift -e 'import Foundation; let data = Data((0..<4194427).map { UInt8(truncatingIfNeeded: ($0 &* 73) ^ ($0 >> 7) ^ ($0 >> 15)) }); try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))' "$TEMP_DIR/seed/payload.bin"
"$FIXTURE" "$TEMP_DIR/seed" "$TEMP_DIR/fixture.torrent"
CFFIXED_USER_HOME="$TEMP_DIR/home" "$TEMP_DIR/TorrentCoreRegression" "$TEMP_DIR"
