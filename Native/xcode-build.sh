#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for arch in $ARCHS; do
    bash "$ROOT/Native/build.sh" "$arch"
done
# Notices ship with the App; static linking does not remove attribution duties.
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/TorrentLicenses"
ditto "$ROOT/Native/licenses" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/TorrentLicenses"
