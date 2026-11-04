#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/ios-history-regression"
mkdir -p "$BUILD"
SOURCES=(
    "$ROOT/IINA-ANI/Features/Playback/PlaybackContract.swift"
    "$ROOT/iOS/ANI/MobileLocalMedia.swift"
    "$ROOT/iOS/ANI/MobilePlaybackHistory.swift"
    "$ROOT/Tests/iOS/PlaybackHistoryRegression.swift"
)
source "$ROOT/Tests/Support/source-core.sh"
case "${1:---macos}" in
    --macos)
        build_source_core --macos
        xcrun swiftc -swift-version 5 -parse-as-library \
            "${SOURCE_CORE_FLAGS[@]}" "${SOURCES[@]}" -o "$BUILD/history-macos"
        "$BUILD/history-macos" "$ROOT"
        ;;
    --simulator)
        DEVICE="${2:?Pass a booted simulator UDID}"
        SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        ARCH="$(uname -m)"
        build_source_core --simulator
        SDKROOT="$SDK" xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
            -sdk "$SDK" -target "$ARCH-apple-ios17.0-simulator" \
            "${SOURCE_CORE_FLAGS[@]}" "${SOURCES[@]}" -o "$BUILD/history-ios"
        xcrun simctl spawn "$DEVICE" "$BUILD/history-ios" "$ROOT"
        ;;
    *) echo "Usage: $0 [--macos|--simulator BOOTED_UDID]" >&2; exit 2 ;;
esac
