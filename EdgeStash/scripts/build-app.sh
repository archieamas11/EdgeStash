#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product EdgeStash
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PWD/dist/EdgeStash.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/EdgeStash" "$APP_DIR/Contents/MacOS/EdgeStash.next"
chmod 755 "$APP_DIR/Contents/MacOS/EdgeStash.next"
mv -f "$APP_DIR/Contents/MacOS/EdgeStash.next" "$APP_DIR/Contents/MacOS/EdgeStash"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EdgeStash</string>
<key>CFBundleIdentifier</key><string>local.edgestash.app</string>
<key>CFBundleName</key><string>EdgeStash</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
