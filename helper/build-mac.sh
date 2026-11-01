#!/bin/sh
# Agentgram Helper.app for the Mac: the helper with its menu-bar icon, no Dock icon, no terminal.
# Signed with Developer ID; NOTARIZE=1 also sends it to Apple's check, so it opens on any Mac without warnings.
set -e
cd "$(dirname "$0")"
APP="dist/Telepath Helper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
VERSION=$(cat VERSION)
CGO_ENABLED=1 GOARCH=arm64 go build -ldflags "-X main.version=$VERSION" -o dist/helper-arm64 .
CGO_ENABLED=1 GOARCH=amd64 go build -ldflags "-X main.version=$VERSION" -o dist/helper-amd64 .
lipo -create -output "$APP/Contents/MacOS/Telepath Helper" dist/helper-arm64 dist/helper-amd64
rm dist/helper-arm64 dist/helper-amd64
# Whisper for the owner's voice messages, run by the helper; built from whisper.cpp the first time
[ -x whisper/whisper-cli ] || ./whisper/build-whisper-cli.sh
cp whisper/whisper-cli "$APP/Contents/Resources/whisper-cli"
if [ -f icon/app-mac.png ]; then
	ICONSET=dist/AppIcon.iconset
	rm -rf "$ICONSET" && mkdir -p "$ICONSET"
	for s in 16 32 128 256 512; do
		sips -z $s $s icon/app-mac.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
		sips -z $((s*2)) $((s*2)) icon/app-mac.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
	done
	iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
	rm -rf "$ICONSET"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Telepath Helper</string>
	<key>CFBundleDisplayName</key><string>Telepath Helper</string>
	<key>CFBundleIdentifier</key><string>app.agentgram.helper</string>
	<key>CFBundleExecutable</key><string>Telepath Helper</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSLocalNetworkUsageDescription</key><string>Чтобы Telepath на телефоне нашёл этот компьютер в твоей Wi-Fi и подключил его.</string>
	<key>NSBonjourServices</key><array><string>_agentgram._tcp</string></array>
</dict>
</plist>
PLIST
# Developer ID when the Mac has it (hardened runtime, as Apple's check wants), else ad hoc for this Mac only
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/whisper-cli"
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
	codesign --force --deep --sign - "$APP"
fi
# NOTARIZE=1: Apple's check (notarytool profile «agentgram-notary»), the answer stapled to the app; then a zip to publish
if [ "$NOTARIZE" = 1 ]; then
	ditto -c -k --keepParent "$APP" dist/notarize.zip
	xcrun notarytool submit dist/notarize.zip --keychain-profile agentgram-notary --wait
	xcrun stapler staple "$APP"
	rm dist/notarize.zip
	ditto -c -k --keepParent "$APP" "dist/Telepath-Helper-mac.zip"
fi
echo "$APP"
