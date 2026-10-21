#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_ROOT="${1:?An isolated test run directory is required}"
exec > "$RUN_ROOT/test.log" 2>&1
CEF_ROOT="$PWD/.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal"
WRAPPER="$PWD/.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a"
APP="$PWD/.build/dependencies/cef/WebRuntimeTests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -Wall -Wextra -Werror \
  -isystem "$CEF_ROOT" -I Sources/WebWallpaperBridge/include -I Sources/WebWallpaperBridge \
  Tests/WebRuntimeHarness/main.mm Tests/WebRuntimeHarness/page-contract-tests.mm Sources/WebWallpaperBridge/WebRuntime.mm \
  Sources/WebWallpaperBridge/WebPage.mm Sources/WebWallpaperBridge/WebClient.cpp Sources/WebWallpaperBridge/WebAudioOutput.mm \
  Sources/WebWallpaperBridge/LocalProjectFiles.cpp Sources/WebWallpaperBridge/LocalWebRequestContext.cpp \
  "$WRAPPER" -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio -o "$APP/Contents/MacOS/WebRuntimeTests"
cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app/'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable':'WebRuntimeTests','CFBundleIdentifier':'local.dynamicwallpaper.web-runtime-tests',
                  'CFBundleName':'WebRuntimeTests','CFBundlePackageType':'APPL','LSUIElement':True,
                  'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'}, output)
PY
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -isystem "$CEF_ROOT" \
  Sources/WebWallpaperHelper/main.mm "$WRAPPER" -framework AppKit -o "$RUN_ROOT/WebWallpaperHelper"
for suffix in '' ' (GPU)' ' (Renderer)' ' (Alerts)' ' (Plugin)'; do
  name="WebRuntimeTests Helper$suffix"
  helper="$APP/Contents/Frameworks/$name.app/Contents"
  mkdir -p "$helper/MacOS"
  cp "$RUN_ROOT/WebWallpaperHelper" "$helper/MacOS/$name"
  cp "$APP/Contents/Info.plist" "$helper/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" "$helper/Info.plist"
done
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
exec "$APP/Contents/MacOS/WebRuntimeTests" \
  "$APP/Contents/Frameworks/Chromium Embedded Framework.framework" \
  "$APP/Contents/Frameworks/WebRuntimeTests Helper.app/Contents/MacOS/WebRuntimeTests Helper" \
  "$RUN_ROOT/context" "$RUN_ROOT/project"
