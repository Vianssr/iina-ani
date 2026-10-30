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
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-dependency-regression.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/mpv"
export CFFIXED_USER_HOME="$TEMP_DIR/home"
# AppServices launches a second, real mpv process without the initial fixture's
# --vo/--ao flags. Keep that process independent of user config and display state.
printf 'vo=null\nao=null\n' > "$TEMP_DIR/mpv/mpv.conf"
export MPV_HOME="$TEMP_DIR/mpv"
FLAGS=(-I "$PRODUCTS" -F "$PRODUCTS" -I "$ROOT/Native/include"
    -I "$PACKAGES/SDWebImage/SDWebImage/include"
    -I "$PACKAGES/swift-atomics/Sources/_AtomicsShims/include"
    -I "$PACKAGES/GzipSwift/Sources/system-zlib"
    -I "$PACKAGES/swift-nio/Sources/CNIOWindows/include")
for module in "$BUILD/Intermediates.noindex/GeneratedModuleMaps/"*.modulemap; do
    FLAGS+=(-Xcc "-fmodule-map-file=$module")
done
# Unit-only by default. Real sockets/lifecycle checks stay opt-in until UI integration is complete.
case "${1:---unit}" in
    --unit) REGRESSIONS=(Playback/PlaybackEncodingRegression Playback/PlaybackHistoryRegression Playback/PlaybackSelectionRegression Playback/CompletedSeasonPolicyRegression Sources/ConfiguredSourceRegression Sources/SourceRegistryRegression Torrent/TorrentHTTPRangeRegression Infrastructure/PreferencesRegression) ;;
    --integration) REGRESSIONS=(Infrastructure/HTTPServerLifecycleRegression) ;;
    --playback) REGRESSIONS=(Playback/PlaybackHistoryPlayerSmoke) ;;
    *) echo "Usage: $0 [--unit|--integration|--playback]" >&2; exit 2 ;;
esac
for regression in "${REGRESSIONS[@]}"; do
    name="${regression##*/}"
    xcrun swiftc -swift-version 6 -parse-as-library "${FLAGS[@]}" \
        "$ROOT/Tests/$regression.swift" \
        -Xlinker "$APP/Contents/MacOS/IINA-ANI.debug.dylib" \
        -Xlinker -rpath -Xlinker "$PRODUCTS" \
        -Xlinker -rpath -Xlinker "$APP/Contents/MacOS" \
        -o "$TEMP_DIR/$name"
    "$TEMP_DIR/$name" "$ROOT" "$APP/Contents/Resources/DataModel.momd"
done
