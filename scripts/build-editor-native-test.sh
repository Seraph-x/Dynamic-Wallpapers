#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_ROOT="${1:?An isolated test directory is required}"
CEF_ROOT="$PWD/.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal"
WRAPPER="$PWD/.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a"
APP="$RUN_ROOT/EditorNativeTests.app"
mkdir -p "$APP/Contents/MacOS"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -Wall -Wextra -Werror \
  -framework Foundation -I Sources/WebWallpaperBridge Tests/EditorRuntimeHarness/protocol-tests.mm \
  Sources/WebWallpaperBridge/SceneProtocol.mm -o "$RUN_ROOT/protocol-tests"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -Wall -Wextra -Werror \
  -isystem "$CEF_ROOT" -I Sources/WebWallpaperBridge/include -I Sources/WebWallpaperBridge \
  Tests/EditorRuntimeHarness/main.mm Sources/WebWallpaperBridge/WebRuntime.mm Sources/WebWallpaperBridge/WebClient.cpp \
  Sources/WebWallpaperBridge/WebAudioOutput.mm Sources/WebWallpaperBridge/LocalProjectFiles.cpp \
  Sources/WebWallpaperBridge/LocalWebRequestContext.cpp Sources/WebWallpaperBridge/SceneProtocol.mm \
  "$WRAPPER" -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio \
  -o "$APP/Contents/MacOS/EditorNativeTests"
if [ "${2:-}" = "--reuse-dependencies" ]; then
  codesign --verify --deep --strict "$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
elif [ "$#" -eq 1 ]; then
  bash scripts/build-web-helper.sh "$APP"
else
  echo "usage: build-editor-native-test.sh RUN_ROOT [--reuse-dependencies]" >&2
  exit 64
fi
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1])
with (app/'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable':'EditorNativeTests','CFBundleIdentifier':'local.dynamicwallpaper.editor-native-tests',
                  'CFBundleName':'EditorNativeTests','CFBundlePackageType':'APPL','LSUIElement':True,
                  'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'},output)
PY
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
