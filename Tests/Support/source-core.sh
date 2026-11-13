#!/bin/bash
# Sourced by standalone regression entry points; flags are passed as an array.
SOURCE_CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

build_source_core() {
    local core_products core_sdk core_arch
    case "$1" in
        --macos)
            swift build --package-path "$SOURCE_CORE_ROOT/SourceCore" --product SourceCore \
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

build_source_runtime() {
    local runtime_products runtime_sdk runtime_arch
    local runtime_args=(--package-path "$SOURCE_CORE_ROOT/SourceCore" --product SourceRuntime)
    case "$1" in
        --macos)
            runtime_args+=(--scratch-path "$SOURCE_CORE_ROOT/.build/source-core")
            ;;
        --simulator)
            runtime_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            runtime_arch="$(uname -m)"
            runtime_args+=(--scratch-path "$SOURCE_CORE_ROOT/.build/source-runtime-simulator"
                --sdk "$runtime_sdk" --triple "$runtime_arch-apple-ios17.0-simulator")
            ;;
        *) echo "Unsupported SourceRuntime regression platform: $1" >&2; return 2 ;;
    esac
    swift build "${runtime_args[@]}" >&2
    runtime_products="$(swift build "${runtime_args[@]}" --show-bin-path)"
    SOURCE_RUNTIME_FLAGS=(-I "$runtime_products/Modules" -I "$runtime_products"
        -L "$runtime_products" -lSourceRuntime)
}
