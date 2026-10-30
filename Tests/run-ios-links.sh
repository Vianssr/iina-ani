#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ios-regression
swiftc -parse-as-library IINA-ANI/Features/Sources/SourceSelection.swift iOS/ANI/MobileLinkLibrary.swift Tests/iOS/LinkFavoritesRegression.swift -o .build/ios-regression/links
.build/ios-regression/links
