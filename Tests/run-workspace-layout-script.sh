#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-layout-script.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
bash "$ROOT/Native/LayoutScript/build.sh" "$TEMP_DIR/LayoutScriptHelper"
swiftc -swift-version 6 -parse-as-library \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceModel.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceCapability.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceRegistry.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceValidation.swift" \
    "$ROOT/IINA-ANI/Workspace/Shell/WorkspaceSessionState.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceStore.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceLayoutScriptRunner.swift" \
    "$ROOT/Tests/Workspace/WorkspaceLayoutScriptRegression.swift" \
    -o "$TEMP_DIR/WorkspaceLayoutScriptRegression"
"$TEMP_DIR/WorkspaceLayoutScriptRegression" "$TEMP_DIR/LayoutScriptHelper"
