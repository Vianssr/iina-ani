#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PACKAGE="$ROOT/.build/ios-source-regression"
mkdir -p "$PACKAGE/Sources/SourceRegression"
cat > "$PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SourceRegression", platforms: [.macOS(.v14)], dependencies: [
    .package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.13.7")
], targets: [.executableTarget(name: "SourceRegression", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")], swiftSettings: [.define("MOBILE_SOURCES"), .swiftLanguageMode(.v5)])])
SWIFT
cp iOS/ANI/MobileSourceLibrary.swift iOS/ANI/SourceFixtures.swift iOS/ANI/Catalog.swift iOS/ANI/Library.swift iOS/ANI/MobileSources.swift iOS/ANI/SourceFlow.swift \
 iOS/ANI/MobileCSS1Configuration.swift iOS/ANI/MobileCSS1Client.swift \
 iOS/ANI/MobileSourceDiscovery.swift iOS/ANI/MobileSourceSubscription.swift iOS/ANI/MobileCatalogDetails.swift iOS/ANI/MobileCollectionSync.swift iOS/ANI/MobileSourceURLImport.swift \
 Tests/iOS/MobileCSS1Regression.swift Tests/iOS/CSS1ClientRegression.swift Tests/iOS/CSS1IdentityRegression.swift \
 Tests/iOS/SourceDiscoverySubscriptionRegression.swift Tests/iOS/CatalogDetailsRegression.swift Tests/iOS/SourceURLImportRegression.swift Tests/iOS/DefaultSubscriptionRegression.swift \
 IINA-ANI/Features/Sources/SourceSelection.swift IINA-ANI/Features/Sources/SourceCapabilities.swift \
 IINA-ANI/Features/Sources/SourceSubscriptionRules.swift \
 IINA-ANI/Features/Sources/SourceConfiguration.swift IINA-ANI/Shared/CollectionStatus.swift Tests/iOS/SourceRegression.swift "$PACKAGE/Sources/SourceRegression/"
swift run --package-path "$PACKAGE" SourceRegression "$ROOT"
