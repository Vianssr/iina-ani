#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ios-regression
swiftc -parse-as-library iOS/ANI/MobileAutomaticDanmaku.swift iOS/ANI/MobileDanmaku.swift Tests/iOS/MobileDanmakuRegression.swift -o .build/ios-regression/danmaku
.build/ios-regression/danmaku
swiftc -parse-as-library iOS/ANI/MobileAutomaticDanmaku.swift iOS/ANI/MobileDanmaku.swift Tests/iOS/MobileAutomaticDanmakuRegression.swift -o .build/ios-regression/automatic-danmaku
.build/ios-regression/automatic-danmaku
