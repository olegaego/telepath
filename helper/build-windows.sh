#!/bin/sh
# Agentgram-Helper-Windows.zip: the helper for Windows (its icon by the clock, no console window) and a README.
# Built on the Mac: the Windows side needs no cgo.
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
STAGE=dist/windows
rm -rf "$STAGE" dist/Telepath-Helper-Windows.zip
mkdir -p "$STAGE"
GOOS=windows GOARCH=amd64 go build -ldflags "-H windowsgui -X main.version=$VERSION" -o "$STAGE/Telepath Helper.exe" .
cat > "$STAGE/Прочти меня.txt" <<TXT
Telepath Helper $VERSION для Windows

1. Запусти «Telepath Helper.exe». Если Windows спросит, разрешить ли, нажми «Подробнее» → «Выполнить в любом случае».
2. Значок появится справа внизу, у часов (или под стрелкой «^»).
3. В Telepath на телефоне: Настройки → Telepath → Добавить агента → Windows. Телефон и компьютер в одной Wi-Fi.

Код: https://github.com/olegaego/telepath
TXT
(cd "$STAGE" && zip -qr ../Telepath-Helper-Windows.zip .)
echo "dist/Telepath-Helper-Windows.zip"
