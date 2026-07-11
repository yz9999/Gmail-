#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release -j "${SWIFT_JOBS:-2}" -Xswiftc -disable-batch-mode
BINARY="$(swift build -c release --show-bin-path 2>/dev/null)/GmailReaderApp"
APP="$ROOT/dist/Gmail Reader.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/GmailReaderApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/GmailReader.icns" "$APP/Contents/Resources/GmailReader.icns"
chmod 755 "$APP/Contents/MacOS/GmailReaderApp"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
