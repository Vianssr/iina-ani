#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d /tmp/iina-skin-store.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT
clang -c -I "$ROOT/IINA-ANI/Workspace/Skin" "$ROOT/IINA-ANI/Workspace/Skin/SkinZipBridge.c" -o "$TEMP_DIR/SkinZipBridge.o"
swiftc -swift-version 6 -parse-as-library \
  -import-objc-header "$ROOT/IINA-ANI/Workspace/Skin/SkinZipBridge.h" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceModel.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceCapability.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceRegistry.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceValidation.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceStore.swift" \
  "$ROOT/IINA-ANI/Workspace/Shell/WorkspaceSessionState.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceTransactions.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinModel.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinAppearance.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinPackageValidator.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinArchive.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinStore.swift" \
  "$ROOT/Tests/Skin/SkinPackageStoreRegression.swift" \
  "$TEMP_DIR/SkinZipBridge.o" -lz \
  -framework AppKit -framework ImageIO -framework CoreText \
  -o "$TEMP_DIR/SkinPackageStoreRegression"
"$TEMP_DIR/SkinPackageStoreRegression"
