#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ios-regression
swiftc -parse-as-library IINA-ANI/Shared/CollectionStatus.swift IINA-ANI/Features/Sources/SourceSelection.swift iOS/ANI/Catalog.swift iOS/ANI/Library.swift iOS/ANI/MobileCollectionSync.swift Tests/iOS/MobileRegression.swift -o .build/ios-regression/mobile
.build/ios-regression/mobile
swiftc -parse-as-library IINA-ANI/Shared/CollectionStatus.swift IINA-ANI/Features/Sources/SourceSelection.swift iOS/ANI/Catalog.swift iOS/ANI/Library.swift iOS/ANI/MobileCollectionSync.swift iOS/ANI/MobileBangumiAccount.swift Tests/iOS/MobileCollectionSyncRegression.swift -o .build/ios-regression/collection-sync
.build/ios-regression/collection-sync
