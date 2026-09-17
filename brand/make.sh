#!/bin/sh
# Regenerates every brand asset from the one engine (brand/make-art.swift),
# then refreshes the copies the app icon and the website use.
set -e
cd "$(dirname "$0")"
A=assets
swift make-art.swift icon   $A/acorn-icon.png 1024
swift make-art.swift mark   $A/acorn-mark.png 1024
swift make-art.swift dots   $A/acorn-dots-56.json 56
swift make-art.swift talk   $A/acorn-talk.gif 320
swift make-art.swift talk   $A/acorn-spin.gif 1040 --spin
swift make-art.swift banner $A/banner.png 1600 560 "Capipaste" "Screenshot, talk, paste." "⌘⇧S · local speech-to-text · macOS"
swift make-art.swift banner $A/social.png 1280 640 "Capipaste" "Screenshot, talk, paste." "⌘⇧S · local speech-to-text · macOS"
swift make-art.swift steps  $A/steps.png 1600 520

# app icon (every size macOS asks for)
ICONSET=../Capipaste/Assets.xcassets/AppIcon.appiconset
for n in 16 32 64 128 256 512 1024; do
  sips -z $n $n $A/acorn-icon.png --out $ICONSET/icon-$n.png >/dev/null
done

# website copies
cp $A/acorn-spin.gif $A/acorn-talk.gif $A/acorn-mark.png $A/social.png ../site/assets/
sips -z 64 64 $A/acorn-mark.png --out ../site/assets/favicon.png >/dev/null
echo "brand assets rebuilt"
