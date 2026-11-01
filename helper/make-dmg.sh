#!/bin/sh
# Agentgram-Helper.dmg: the app, a link to Applications with an arrow between them, and a README. Run after
# NOTARIZE=1 ./build-mac.sh; the dmg itself is signed and sent to Apple's check too.
set -e
cd "$(dirname "$0")"
APP="dist/Telepath Helper.app"
DMG="dist/Telepath-Helper.dmg"
STAGE=dist/dmg-stage
rm -rf "$STAGE" "$DMG" dist/rw.dmg
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp dmg/README.txt "$STAGE/Прочти меня.txt"
cp dmg/background.tiff "$STAGE/.background/background.tiff"
hdiutil create -quiet -volname "Telepath Helper" -srcfolder "$STAGE" -fs HFS+ -format UDRW dist/rw.dmg
DEV=$(hdiutil attach -readwrite -noverify -noautoopen dist/rw.dmg | awk '/Apple_HFS/ {print $1}')
sleep 1
osascript <<OSA
tell application "Finder"
	tell disk "Telepath Helper"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set bounds of container window to {200, 120, 800, 580}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 96
		set text size of opts to 13
		set background picture of opts to file ".background:background.tiff"
		set position of item "Telepath Helper.app" of container window to {150, 200}
		set position of item "Applications" of container window to {450, 200}
		set position of item "Прочти меня.txt" of container window to {300, 385}
		update without registering applications
		delay 1
		close
	end tell
end tell
OSA
sync
hdiutil detach -quiet "$DEV"
hdiutil convert -quiet dist/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf dist/rw.dmg "$STAGE"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
	codesign --force --timestamp --sign "$IDENTITY" "$DMG"
	if [ "$NOTARIZE" = 1 ]; then
		xcrun notarytool submit "$DMG" --keychain-profile agentgram-notary --wait
		xcrun stapler staple "$DMG"
	fi
fi
echo "$DMG"
