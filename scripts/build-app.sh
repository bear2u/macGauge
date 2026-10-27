#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --cache-path .build/cache
mkdir -p dist/MacGauge.app/Contents/MacOS dist/MacGauge.app/Contents/Resources
cp .build/release/MacGauge dist/MacGauge.app/Contents/MacOS/MacGauge
cp Resources/Info.plist dist/MacGauge.app/Contents/Info.plist
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o dist/MacGauge.app/Contents/Resources/AppIcon.icns
codesign --force --sign - --identifier com.symverse.MacGauge dist/MacGauge.app
codesign --verify --deep --strict dist/MacGauge.app
printf '%s\n' "Built: $PWD/dist/MacGauge.app"
