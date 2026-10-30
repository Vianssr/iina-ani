#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ios-regression
swiftc -parse-as-library iOS/ANI/Catalog.swift Tests/iOS/CatalogBrowseRegression.swift -o .build/ios-regression/catalog-browse
.build/ios-regression/catalog-browse
