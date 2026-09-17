#!/bin/sh
# Build Release and install to /Applications (same signing identity, so macOS keeps permissions).
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Capipaste.xcodeproj -scheme Capipaste -configuration Release -derivedDataPath build build -quiet
pkill -x Capipaste || true
rm -rf /Applications/Capipaste.app
cp -R build/Build/Products/Release/Capipaste.app /Applications/
open /Applications/Capipaste.app
echo "Installed /Applications/Capipaste.app"
