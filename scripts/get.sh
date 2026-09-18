#!/bin/sh
# One-line install: curl -fsSL https://raw.githubusercontent.com/Chordlini/capipaste/main/scripts/get.sh | sh
# Downloads the latest release into /Applications and opens it.
set -e
URL="https://github.com/Chordlini/capipaste/releases/latest/download/Capipaste.app.zip"
TMP="$(mktemp -d)"
echo "Downloading Capipaste…"
curl -fsSL "$URL" -o "$TMP/Capipaste.zip"
/usr/bin/ditto -x -k "$TMP/Capipaste.zip" "$TMP"
pkill -x Capipaste 2>/dev/null || true
rm -rf /Applications/Capipaste.app
mv "$TMP/Capipaste.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Capipaste.app 2>/dev/null || true
rm -rf "$TMP"
open /Applications/Capipaste.app
echo "Installed. Look for the acorn in your menu bar."
