#!/bin/bash
# Build an isolated quit probe from the actual NSApplication bridge and quit coordinators.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/swift_sdk.py build --disable-sandbox
BIN="$(python3 scripts/swift_sdk.py build --show-bin-path --disable-sandbox)"
source scripts/swift-harness-inputs.sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$PWD/.build/verification/application-termination/QuitHarness.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -sdk "$SDK" -Xclang-linker -isysroot -Xclang-linker "$SDK" -parse-as-library -swift-version 5 \
  -target arm64-apple-macosx14.0 "${SWIFT_HARNESS_IMPORTS[@]}" \
  Tests/ApplicationTerminationHarness/main.swift \
  Sources/WallpaperApp/{ApplicationQuitPreparation,ApplicationTermination}.swift \
  "${SWIFT_WEB_OBJECTS[@]}" \
  .build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a \
  -Xlinker -lc++ -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio \
  -o "$APP/Contents/MacOS/QuitHarness"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, sys
with (Path(sys.argv[1]) / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleExecutable':'QuitHarness', 'CFBundleIdentifier':'local.dynamicwallpaper.quit-harness',
                  'CFBundleName':'QuitHarness', 'CFBundlePackageType':'APPL', 'LSUIElement':True,
                  'LSMinimumSystemVersion':'14.0'}, stream)
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
swiftc -sdk "$SDK" -Xclang-linker -isysroot -Xclang-linker "$SDK" \
  Tests/ApplicationTerminationHarness/request.swift -o "$(dirname "$APP")/request-quit"
