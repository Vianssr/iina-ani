#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/multiplatform-contracts"
mkdir -p "$BUILD"
SOURCES=(
    "$ROOT/IINA-ANI/Shared/CollectionStatus.swift"
    "$ROOT/IINA-ANI/Features/Playback/PlaybackContract.swift"
)
# Both platforms import the same SourceCore module and use the same fixtures.
source "$ROOT/Tests/Support/source-core.sh"
case "${1:---macos}" in
    --macos)
        build_source_core --macos
        for name in MultiplatformContractRegression PlaybackContractRegression; do
            xcrun swiftc -swift-version 5 -parse-as-library \
                "${SOURCE_CORE_FLAGS[@]}" "${SOURCES[@]}" "$ROOT/Tests/Playback/$name.swift" -o "$BUILD/$name-macos"
            "$BUILD/$name-macos" "$ROOT"
        done
        ;;
    --simulator)
        DEVICE="${2:?Pass a booted simulator UDID}"
        SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        ARCH="$(uname -m)"
        build_source_core --simulator
        for name in MultiplatformContractRegression PlaybackContractRegression; do
            SDKROOT="$SDK" xcrun --sdk iphonesimulator swiftc -swift-version 5 -parse-as-library \
                -sdk "$SDK" -target "$ARCH-apple-ios17.0-simulator" \
                "${SOURCE_CORE_FLAGS[@]}" "${SOURCES[@]}" "$ROOT/Tests/Playback/$name.swift" -o "$BUILD/$name-ios"
            xcrun simctl spawn "$DEVICE" "$BUILD/$name-ios" "$ROOT"
        done
        ;;
    *) echo "Usage: $0 [--macos|--simulator BOOTED_UDID]" >&2; exit 2 ;;
esac
