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
"$EDGESTASH_CHECK_DIR/check-settings"
