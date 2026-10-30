#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ios-regression
swiftc -parse-as-library iOS/ANI/MobileBT.swift Tests/iOS/MobileBTRegression.swift -o .build/ios-regression/bt
.build/ios-regression/bt
