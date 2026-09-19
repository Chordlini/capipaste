#!/bin/sh
# Build Release and install to /Applications (same signing identity, so macOS keeps permissions).
#   scripts/install.sh hooks   also compiles in the launch-argument test hooks (-autocapture, -dictate, …).
#   Leave them out of a copy you use day to day: they let any process drive the app's screen and mic access.
set -e
cd "$(dirname "$0")/.."
[ "$1" = hooks ] && HOOKS='SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) TESTHOOKS'
xcodegen generate >/dev/null
xcodebuild -project Capipaste.xcodeproj -scheme Capipaste -configuration Release -derivedDataPath build -skipPackagePluginValidation -skipMacroValidation ${HOOKS:+"$HOOKS"} build -quiet
pkill -x Capipaste || true
rm -rf /Applications/Capipaste.app
cp -R build/Build/Products/Release/Capipaste.app /Applications/
open /Applications/Capipaste.app
echo "Installed /Applications/Capipaste.app"
