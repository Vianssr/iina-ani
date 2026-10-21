#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/xcode/Build"
PRODUCTS="$BUILD/Products/Debug"
APP="$PRODUCTS/IINA-ANI.app"
PACKAGES="$ROOT/.build/xcode/SourcePackages/checkouts"
FIXTURE="$ROOT/.build/torrent/$(uname -m)/build/bin/torrent-fixture"
if [[ ! -f "$APP/Contents/MacOS/IINA-ANI.debug.dylib" || ! -x "$FIXTURE" ]]; then
    echo "Build the Debug IINA-ANI app and native torrent fixture first." >&2
    exit 1
fi
mkdir -p "$ROOT/.build/w11.2"
TEMP_DIR="$(mktemp -d "$ROOT/.build/w11.2/runner.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
RUNNER_APP="$TEMP_DIR/TorrentDownloadRegression.app"
mkdir -p "$RUNNER_APP/Contents/MacOS" "$RUNNER_APP/Contents/Resources" "$TEMP_DIR/home" "$TEMP_DIR/seed"
cat > "$RUNNER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>TorrentDownloadRegression</string><key>CFBundleIdentifier</key><string>org.iina.regression.torrent-download</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cp -R "$APP/Contents/Resources/TorrentLicenses" "$RUNNER_APP/Contents/Resources/"
FLAGS=(-I "$PRODUCTS" -F "$PRODUCTS" -I "$ROOT/Native/include"
    -I "$PACKAGES/SDWebImage/SDWebImage/include"
    -I "$PACKAGES/swift-atomics/Sources/_AtomicsShims/include"
    -I "$PACKAGES/GzipSwift/Sources/system-zlib"
    -I "$PACKAGES/swift-nio/Sources/CNIOWindows/include")
for module in "$BUILD/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
    FLAGS+=(-Xcc "-fmodule-map-file=$module")
done
xcrun swiftc -swift-version 6 -parse-as-library "${FLAGS[@]}" \
    "$ROOT/Tests/Torrent/TorrentDownloadRegression.swift" \
    -Xlinker "$APP/Contents/MacOS/IINA-ANI.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PRODUCTS" \
    -Xlinker -rpath -Xlinker "$APP/Contents/MacOS" \
    -o "$RUNNER_APP/Contents/MacOS/TorrentDownloadRegression"
# Synthetic, playable FFV1 video. Multi-file fixture places the decoy before this video.
ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=320x180:rate=24' -t 35 -c:v ffv1 -pix_fmt yuv420p -y "$TEMP_DIR/seed/payload.mkv"
printf 'non-media decoy' > "$TEMP_DIR/seed/decoy.bin"
for mode in v1 v2 hybrid; do
    "$FIXTURE" "$TEMP_DIR/seed" "$TEMP_DIR/fixture-$mode.torrent" "$mode" multi
done
"$FIXTURE" "$TEMP_DIR/seed" "$TEMP_DIR/fixture-private-hybrid.torrent" hybrid multi private
ARGS=("$TEMP_DIR")
if [[ -n "${W112_DISK_FULL_DIR:-}" ]]; then ARGS+=(--disk-full); fi
if [[ -n "${W112_PHASE:-}" ]]; then ARGS+=(--phase "$W112_PHASE"); fi
CFFIXED_USER_HOME="$TEMP_DIR/home" "$RUNNER_APP/Contents/MacOS/TorrentDownloadRegression" "${ARGS[@]}"
