#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_ROOT="${1:?An isolated test run directory is required}"
CEF_ROOT="$PWD/.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal"
WRAPPER="$PWD/.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a"
APP="$RUN_ROOT/SceneNativeTests.app"
case "${SCENE_NATIVE_TEST_KEYCHAIN:-system}" in
  system) KEYCHAIN_TEST_FLAG="-DDW_CEF_TEST_KEYCHAIN=0" ;;
  isolated) KEYCHAIN_TEST_FLAG="-DDW_CEF_TEST_KEYCHAIN=1" ;;
  *) echo "SCENE_NATIVE_TEST_KEYCHAIN must be system or isolated" >&2; exit 64 ;;
esac
mkdir -p "$APP/Contents/MacOS"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -Wall -Wextra -Werror \
  -framework Foundation -I Sources/WebWallpaperBridge \
  Tests/SceneRuntimeHarness/protocol-tests.mm Sources/WebWallpaperBridge/SceneProtocol.mm \
  Sources/WebWallpaperBridge/LocalProjectFiles.cpp -o "$RUN_ROOT/protocol-tests"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -Wall -Wextra -Werror \
  "$KEYCHAIN_TEST_FLAG" -isystem "$CEF_ROOT" -I Sources/WebWallpaperBridge/include -I Sources/WebWallpaperBridge \
  Tests/SceneRuntimeHarness/main.mm Sources/WebWallpaperBridge/WebRuntime.mm \
  Sources/WebWallpaperBridge/WebPage.mm Sources/WebWallpaperBridge/WebClient.cpp \
  Sources/WebWallpaperBridge/WebAudioOutput.mm Sources/WebWallpaperBridge/LocalProjectFiles.cpp \
  Sources/WebWallpaperBridge/LocalWebRequestContext.cpp Sources/WebWallpaperBridge/SceneProtocol.mm \
  "$WRAPPER" -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio \
  -o "$APP/Contents/MacOS/SceneNativeTests"
bash scripts/build-web-helper.sh "$APP"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable': 'SceneNativeTests',
                  'CFBundleIdentifier': 'local.dynamicwallpaper.scene-native-tests',
                  'CFBundleName': 'SceneNativeTests', 'CFBundlePackageType': 'APPL',
                  'LSUIElement': True, 'NSHighResolutionCapable': True,
                  'LSMinimumSystemVersion': '14.0'}, output)
PY
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
