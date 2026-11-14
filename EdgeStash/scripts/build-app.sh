#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# shortcut: SwiftBuild in Swift 6.4 links with the deployment target as its SDK version; remove this override when corrected upstream.
EDGESTASH_MACOS_SDK="$(xcrun --show-sdk-path)"
swift build --build-system native --sdk "$EDGESTASH_MACOS_SDK" -c release --product EdgeStash
BIN_DIR="$(swift build --build-system native --sdk "$EDGESTASH_MACOS_SDK" -c release --show-bin-path)"
xcrun vtool -show-build "$BIN_DIR/EdgeStash" | awk -v expected="$(xcrun --show-sdk-version)" '
  $1 == "sdk" { found = 1; if ($2 != expected) exit 1 }
  END { if (!found) exit 1 }
' || { printf '%s\n' 'Build failed: linked SDK does not match the selected macOS SDK.' >&2; exit 1; }
APP_DIR="${EDGESTASH_OUTPUT_APP:-$PWD/dist/EdgeStash.app}"
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
<key>CFBundleShortVersionString</key><string>1.18</string>
<key>CFBundleVersion</key><string>19</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
