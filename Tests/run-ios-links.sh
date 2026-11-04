#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Tests/Support/source-core.sh
build_source_core --macos
mkdir -p .build/ios-regression
swiftc -parse-as-library "${SOURCE_CORE_FLAGS[@]}" iOS/ANI/MobileLinkLibrary.swift Tests/iOS/LinkFavoritesRegression.swift -o .build/ios-regression/links
.build/ios-regression/links
