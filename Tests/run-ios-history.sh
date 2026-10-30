#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/ios-history-regression"
mkdir -p "$BUILD"
SOURCES=(
    "$ROOT/IINA-ANI/Features/Sources/SourceSelection.swift"
    "$ROOT/IINA-ANI/Features/Sources/SourceCapabilities.swift"
    "$ROOT/IINA-ANI/Features/Sources/SourceConfiguration.swift"
    "$ROOT/IINA-ANI/Features/Playback/PlaybackContract.swift"
    "$ROOT/iOS/ANI/MobileLocalMedia.swift"
    "$ROOT/iOS/ANI/MobilePlaybackHistory.swift"
    "$ROOT/Tests/iOS/PlaybackHistoryRegression.swift"
)
case "${1:---macos}" in
    --macos)
        xcrun swiftc -swift-version 5 -D MOBILE_SOURCES -parse-as-library \
            "${SOURCES[@]}" -o "$BUILD/history-macos"
        "$BUILD/history-macos" "$ROOT"
        ;;
    --simulator)
        DEVICE="${2:?Pass a booted simulator UDID}"
        SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        ARCH="$(uname -m)"
        SDKROOT="$SDK" xcrun --sdk iphonesimulator swiftc -swift-version 5 -D MOBILE_SOURCES -parse-as-library \
            -sdk "$SDK" -target "$ARCH-apple-ios17.0-simulator" \
            "${SOURCES[@]}" -o "$BUILD/history-ios"
        xcrun simctl spawn "$DEVICE" "$BUILD/history-ios" "$ROOT"
        ;;
    *) echo "Usage: $0 [--macos|--simulator BOOTED_UDID]" >&2; exit 2 ;;
esac
