#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/multiplatform-contracts"
mkdir -p "$BUILD"
SOURCES=(
    "$ROOT/IINA-ANI/Shared/CollectionStatus.swift"
    "$ROOT/IINA-ANI/Features/Sources/SourceSelection.swift"
    "$ROOT/IINA-ANI/Features/Sources/SourceCapabilities.swift"
    "$ROOT/IINA-ANI/Features/Sources/SourceConfiguration.swift"
    "$ROOT/IINA-ANI/Features/Playback/PlaybackContract.swift"
)
# MOBILE_SOURCES isolates desktop parser errors, not identity or capability rules.
# Both executables use exactly the same fixtures and production value types.
case "${1:---macos}" in
    --macos)
        for name in MultiplatformContractRegression PlaybackContractRegression; do
            xcrun swiftc -swift-version 5 -D MOBILE_SOURCES -parse-as-library \
                "${SOURCES[@]}" "$ROOT/Tests/Playback/$name.swift" -o "$BUILD/$name-macos"
            "$BUILD/$name-macos" "$ROOT"
        done
        ;;
    --simulator)
        DEVICE="${2:?Pass a booted simulator UDID}"
        SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        ARCH="$(uname -m)"
        for name in MultiplatformContractRegression PlaybackContractRegression; do
            SDKROOT="$SDK" xcrun --sdk iphonesimulator swiftc -swift-version 5 -D MOBILE_SOURCES -parse-as-library \
                -sdk "$SDK" -target "$ARCH-apple-ios17.0-simulator" \
                "${SOURCES[@]}" "$ROOT/Tests/Playback/$name.swift" -o "$BUILD/$name-ios"
            xcrun simctl spawn "$DEVICE" "$BUILD/$name-ios" "$ROOT"
        done
        ;;
    *) echo "Usage: $0 [--macos|--simulator BOOTED_UDID]" >&2; exit 2 ;;
esac
