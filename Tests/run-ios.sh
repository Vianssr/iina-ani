#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Tests/Support/source-core.sh
build_source_core --macos
mkdir -p .build/ios-regression
swiftc -parse-as-library "${SOURCE_CORE_FLAGS[@]}" IINA-ANI/Shared/CollectionStatus.swift iOS/ANI/Catalog.swift iOS/ANI/Library.swift iOS/ANI/MobileCollectionSync.swift Tests/iOS/MobileRegression.swift -o .build/ios-regression/mobile
.build/ios-regression/mobile
swiftc -parse-as-library "${SOURCE_CORE_FLAGS[@]}" IINA-ANI/Shared/CollectionStatus.swift iOS/ANI/Catalog.swift iOS/ANI/Library.swift iOS/ANI/MobileCollectionSync.swift iOS/ANI/MobileBangumiAccount.swift Tests/iOS/MobileCollectionSyncRegression.swift -o .build/ios-regression/collection-sync
.build/ios-regression/collection-sync
