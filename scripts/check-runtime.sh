#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
EDGESTASH_RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edgestash-runtime.XXXXXX")"
trap 'rm -rf "$EDGESTASH_RUNTIME_DIR"' EXIT HUP INT TERM
xcrun swiftc -emit-library -emit-module -module-name EdgeStashCore Sources/EdgeStashCore/*.swift \
  -emit-module-path "$EDGESTASH_RUNTIME_DIR/EdgeStashCore.swiftmodule" -o "$EDGESTASH_RUNTIME_DIR/libEdgeStashCore.dylib"
python3 - "$EDGESTASH_RUNTIME_DIR" <<'PYTHON'
from pathlib import Path
import json
import sys
source = Path("Sources/EdgeStash/main.swift").read_text().split("\nlet app = NSApplication.shared", 1)[0]
journal = 'FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]\n        .appendingPathComponent("EdgeStash/recovery.json")'
assert journal in source, "Update the native fixture's journal isolation before running checks"
source = source.replace(journal, 'URL(fileURLWithPath: ' + json.dumps(str(Path(sys.argv[1]) / "recovery.json")) + ')')
Path(sys.argv[1], "AppRuntime.swift").write_text(source)
PYTHON
xcrun swiftc -parse-as-library -I "$EDGESTASH_RUNTIME_DIR" -L "$EDGESTASH_RUNTIME_DIR" -lEdgeStashCore \
  -Xlinker -rpath -Xlinker "$EDGESTASH_RUNTIME_DIR" "$EDGESTASH_RUNTIME_DIR/AppRuntime.swift" Sources/EdgeStash/SettingsWindow.swift Sources/EdgeStash/IndicatorView.swift Sources/EdgeStash/Activity.swift Sources/EdgeStash/WindowImageSlide.swift scripts/runtime-checks.swift -o "$EDGESTASH_RUNTIME_DIR/check-runtime"
"$EDGESTASH_RUNTIME_DIR/check-runtime"
