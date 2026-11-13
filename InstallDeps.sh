#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -ne 0 ]]; then
  echo "Usage: $0 (the bundled Danmaku plugin is built from local source, not an upstream release)" >&2
  exit 2
fi

"$ROOT/PackageDanmakuPlugin.sh"
( cd "$ROOT/IINA-ANI/WebFiles" && npm ci )
