#!/bin/sh
# Agentgram Helper.app for the Mac: the helper with its menu-bar icon, no Dock icon, no terminal.
# Signed ad hoc here; for others it is signed with Developer ID and notarized before a release.
set -e
cd "$(dirname "$0")"
APP="dist/Agentgram Helper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
CGO_ENABLED=1 GOARCH=arm64 go build -o dist/helper-arm64 .
CGO_ENABLED=1 GOARCH=amd64 go build -o dist/helper-amd64 .
lipo -create -output "$APP/Contents/MacOS/Agentgram Helper" dist/helper-arm64 dist/helper-amd64
rm dist/helper-arm64 dist/helper-amd64
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
	<key>CFBundleName</key><string>Agentgram Helper</string>
	<key>CFBundleDisplayName</key><string>Agentgram Helper</string>
	<key>CFBundleIdentifier</key><string>app.agentgram.helper</string>
	<key>CFBundleExecutable</key><string>Agentgram Helper</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>LSUIElement</key><true/>
	<key>NSLocalNetworkUsageDescription</key><string>Чтобы Agentgram на телефоне нашёл этот компьютер в твоей Wi-Fi и подключил его.</string>
	<key>NSBonjourServices</key><array><string>_agentgram._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "$APP"
