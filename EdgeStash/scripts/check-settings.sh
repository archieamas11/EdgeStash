#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
EDGESTASH_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edgestash-ui.XXXXXX")"
trap 'rm -rf "$EDGESTASH_CHECK_DIR"' EXIT HUP INT TERM
xcrun swiftc -emit-library -emit-module -module-name EdgeStashCore Sources/EdgeStashCore/*.swift \
  -emit-module-path "$EDGESTASH_CHECK_DIR/EdgeStashCore.swiftmodule" -o "$EDGESTASH_CHECK_DIR/libEdgeStashCore.dylib"
cp scripts/settings-smoke.swift "$EDGESTASH_CHECK_DIR/main.swift"
xcrun swiftc -I "$EDGESTASH_CHECK_DIR" -L "$EDGESTASH_CHECK_DIR" -lEdgeStashCore \
  -Xlinker -rpath -Xlinker "$EDGESTASH_CHECK_DIR" "$EDGESTASH_CHECK_DIR/main.swift" \
  Sources/EdgeStash/SettingsWindow.swift Sources/EdgeStash/IndicatorView.swift -o "$EDGESTASH_CHECK_DIR/check-settings"
if [ "${EDGESTASH_SETTINGS_PREVIEW:-0}" = 1 ]; then
  EDGESTASH_PREVIEW_APP="$EDGESTASH_CHECK_DIR/EdgeStash Settings Preview.app"
  mkdir -p "$EDGESTASH_PREVIEW_APP/Contents/MacOS"
  mv "$EDGESTASH_CHECK_DIR/check-settings" "$EDGESTASH_PREVIEW_APP/Contents/MacOS/SettingsPreview"
  cat > "$EDGESTASH_PREVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SettingsPreview</string>
<key>CFBundleIdentifier</key><string>local.edgestash.settings-preview</string>
<key>CFBundleName</key><string>EdgeStash Settings Preview</string>
<key>CFBundleShortVersionString</key><string>Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - "$EDGESTASH_PREVIEW_APP"
  printf '%s\n' "$EDGESTASH_PREVIEW_APP" > /tmp/edgestash-settings-preview-path
  "$EDGESTASH_PREVIEW_APP/Contents/MacOS/SettingsPreview"
else
  "$EDGESTASH_CHECK_DIR/check-settings"
fi
