#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-work-library.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
MODEL_DIR="$TEMP_DIR/DataModel.momd"
RUNNER="$TEMP_DIR/work-library-regression"

xcrun momc "$ROOT/IINA-ANI/Core Data/DataModel.xcdatamodeld" "$MODEL_DIR"
swiftc -swift-version 6 -parse-as-library -framework CoreData -framework Foundation \
    "$ROOT/IINA-ANI/Features/Sources/SourceSelection.swift" \
    "$ROOT/IINA-ANI/Shared/CollectionStatus.swift" \
    "$ROOT/IINA-ANI/Features/Bangumi/BangumiModels.swift" \
    "$ROOT/IINA-ANI/Features/Downloads/DownloadModels.swift" \
    "$ROOT/IINA-ANI/Infrastructure/Persistence/WorkLibrary.swift" \
    "$ROOT/Tests/Library/WorkLibraryRegression.swift" \
    -o "$RUNNER"
"$RUNNER" "$MODEL_DIR"
