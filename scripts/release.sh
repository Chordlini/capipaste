#!/bin/sh
# Cut a release: build, zip the app, publish it to GitHub so the updater has something to fetch.
#   scripts/release.sh 0.2.0 "What changed"
set -e
cd "$(dirname "$0")/.."
VERSION="$1"
NOTES="${2:-}"
[ -z "$VERSION" ] && { echo "usage: scripts/release.sh <version> [notes]"; exit 1; }

# keep Info.plist in step with the tag
/usr/bin/sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$VERSION\"/" project.yml
xcodegen generate >/dev/null
xcodebuild -project Capipaste.xcodeproj -scheme Capipaste -configuration Release -derivedDataPath build build -quiet

APP="build/Build/Products/Release/Capipaste.app"
ZIP="build/Capipaste.app.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

git add -A
git commit -m "Release $VERSION" || true
git tag "v$VERSION" -f
git push --follow-tags
gh release create "v$VERSION" "$ZIP" --title "Capipaste $VERSION" --notes "$NOTES"
echo "released v$VERSION"
