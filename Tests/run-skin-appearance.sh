#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-skin.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceModel.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceCapability.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceRegistry.swift" \
  "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceValidation.swift" \
  "$ROOT/IINA-ANI/Workspace/Shell/WorkspaceSessionState.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinModel.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinAppearance.swift" \
  "$ROOT/IINA-ANI/Workspace/Skin/SkinPackageValidator.swift" \
  "$ROOT/Tests/Skin/SkinAppearanceRegression.swift" \
  -framework AppKit -framework ImageIO -framework CoreText \
  -o "$TEMP_DIR/SkinAppearanceRegression"
"$TEMP_DIR/SkinAppearanceRegression"
