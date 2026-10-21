#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iina-workspace.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceModel.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceCapability.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceRegistry.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceValidation.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceStore.swift" \
    "$ROOT/IINA-ANI/Workspace/Shell/WorkspaceSessionState.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceTransactions.swift" \
    "$ROOT/IINA-ANI/Workspace/Layout/WorkspaceLayoutEditor.swift" \
    "$ROOT/Tests/Workspace/WorkspaceLayoutRegression.swift" \
    -o "$TEMP_DIR/WorkspaceLayoutRegression"
"$TEMP_DIR/WorkspaceLayoutRegression"
