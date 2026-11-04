#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PACKAGE="$ROOT/.build/ios-source-regression"
# This target is generated entirely from the explicit production/test list below.
# Remove stale copies so renamed or extracted files cannot shadow the package.
rm -rf "$PACKAGE/Sources/SourceRegression"
mkdir -p "$PACKAGE/Sources/SourceRegression"
cat > "$PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SourceRegression", platforms: [.macOS(.v14)], dependencies: [
    .package(path: "../../SourceCore"),
    .package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.13.7")
], targets: [.executableTarget(name: "SourceRegression", dependencies: [.product(name: "SourceCore", package: "SourceCore"), .product(name: "SwiftSoup", package: "SwiftSoup")], swiftSettings: [.swiftLanguageMode(.v5)])])
SWIFT
cp iOS/ANI/MobileSourceLibrary.swift iOS/ANI/SourceFixtures.swift iOS/ANI/Catalog.swift iOS/ANI/Library.swift iOS/ANI/MobileSources.swift iOS/ANI/SourceFlow.swift \
 iOS/ANI/MobileCSS1Configuration.swift iOS/ANI/MobileCSS1Client.swift \
 iOS/ANI/MobileSourceDiscovery.swift iOS/ANI/MobileSourceSubscription.swift iOS/ANI/MobileCatalogDetails.swift iOS/ANI/MobileCollectionSync.swift iOS/ANI/MobileSourceURLImport.swift \
 Tests/iOS/CSS1ProtocolRegression.swift Tests/iOS/MobileCSS1Regression.swift Tests/iOS/CSS1ClientRegression.swift Tests/iOS/CSS1IdentityRegression.swift \
 Tests/iOS/SourceDiscoverySubscriptionRegression.swift Tests/iOS/CatalogDetailsRegression.swift Tests/iOS/SourceURLImportRegression.swift Tests/iOS/DefaultSubscriptionRegression.swift \
 IINA-ANI/Shared/CollectionStatus.swift Tests/iOS/SourceRegression.swift "$PACKAGE/Sources/SourceRegression/"
swift run --package-path "$PACKAGE" SourceRegression "$ROOT"
