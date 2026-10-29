#!/bin/bash
# Compile the actual Swift adapter sources into an isolated app; do not launch.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/swift_sdk.py build --disable-sandbox
BIN="$(python3 scripts/swift_sdk.py build --show-bin-path --disable-sandbox)"
source scripts/swift-harness-inputs.sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
source scripts/scene-swift-keychain-inputs.sh
APP="$PWD/.build/dependencies/cef/WebSwiftTests.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -sdk "$SDK" -Xclang-linker -isysroot -Xclang-linker "$SDK" -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-name WebSwiftTests \
  "${SWIFT_HARNESS_IMPORTS[@]}" \
  Tests/WebRuntimeHarness/{swift-main,swift-mirror}.swift \
  Sources/WallpaperApp/ApplicationPaths.swift \
  Sources/WallpaperApp/Media/{WebRuntimePaths,WebPageSession,WebSurface,CEFApplicationRuntime,CEFPageSession,ScenePageSession,CEFScenePageSession,ScenePropertySessionOwner,SceneProjectProbe,SceneMediaSessionOwner}.swift \
  Sources/WallpaperApp/Transcoding/TranscodeTools.swift \
  Sources/WallpaperApp/Playback/{PlaybackCloseBarrier,WallpaperMirrorStream,WallpaperMirrorFrameOutput,WallpaperScreenshotProducer}.swift \
  Sources/WallpaperApp/UI/WallpaperMirrorView.swift \
  "${SWIFT_AUDIO_OBJECTS[@]}" "${SWIFT_MEDIA_OBJECTS[@]}" "${SWIFT_CORE_OBJECTS[@]}" "${SWIFT_NATIVE_OBJECTS[@]}" "${SWIFT_WEB_OBJECTS[@]}" \
  .build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a \
  -Xlinker -lc++ -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio \
  -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit -framework SwiftUI \
  -o "$APP/Contents/MacOS/WebSwiftTests"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app/'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable': 'WebSwiftTests', 'CFBundleIdentifier': 'local.dynamicwallpaper.web-swift-tests',
                  'CFBundleName': 'WebSwiftTests', 'CFBundlePackageType': 'APPL', 'LSUIElement': True,
                  'LSMinimumSystemVersion': '14.0'}, output)
PY
bash scripts/build-web-helper.sh "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built Swift integration test only: $APP"
