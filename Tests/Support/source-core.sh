#!/bin/bash
# Sourced by standalone regression entry points; flags are passed as an array.
SOURCE_CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

build_source_core() {
    local core_products core_sdk core_arch
    case "$1" in
        --macos)
            swift build --package-path "$SOURCE_CORE_ROOT/SourceCore" \
                --scratch-path "$SOURCE_CORE_ROOT/.build/source-core" >&2
            core_products="$(swift build --package-path "$SOURCE_CORE_ROOT/SourceCore" \
                --scratch-path "$SOURCE_CORE_ROOT/.build/source-core" --show-bin-path)"
            # SwiftPM's native and Xcode build systems place modules differently.
            SOURCE_CORE_FLAGS=(-I "$core_products/Modules" -I "$core_products" -L "$core_products" -lSourceCore)
            ;;
        --simulator)
            core_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            core_arch="$(uname -m)"
            core_products="$SOURCE_CORE_ROOT/.build/source-core-simulator/$core_arch"
            mkdir -p "$core_products"
            xcrun --sdk iphonesimulator swiftc -swift-version 6 -parse-as-library \
                -sdk "$core_sdk" -target "$core_arch-apple-ios17.0-simulator" \
                -module-name SourceCore -emit-library -static -emit-module \
                -emit-module-path "$core_products/SourceCore.swiftmodule" \
                "$SOURCE_CORE_ROOT/SourceCore/Sources/SourceCore/"*.swift \
                -o "$core_products/libSourceCore.a"
            SOURCE_CORE_FLAGS=(-I "$core_products" -L "$core_products" -lSourceCore)
            ;;
        *) echo "Unsupported SourceCore regression platform: $1" >&2; return 2 ;;
    esac
}
