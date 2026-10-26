#!/bin/bash
# Compile actual SceneSurface/CEF adapters against existing verified build objects.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(python3 scripts/swift_sdk.py build --show-bin-path --disable-sandbox)"
source scripts/swift-harness-inputs.sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$PWD/.build/dependencies/cef/SceneSwiftTests.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -sdk "$SDK" -Xclang-linker -isysroot -Xclang-linker "$SDK" -parse-as-library \
  -swift-version 5 -target arm64-apple-macosx14.0 -module-name SceneSwiftTests \
  "${SWIFT_HARNESS_IMPORTS[@]}" Tests/SceneRuntimeHarness/{swift-main,system-audio}.swift \
  Sources/WallpaperApp/Media/{SceneSurface,ScenePageSession,CEFScenePageSession,CEFApplicationRuntime,CEFPageSession,WebPageSession,WebRuntimePaths}.swift \
  Sources/WallpaperApp/Playback/PlaybackCloseBarrier.swift Sources/WallpaperApp/ApplicationPaths.swift \
  Sources/WallpaperApp/Transcoding/TranscodeTools.swift \
  "${SWIFT_AUDIO_OBJECTS[@]}" "${SWIFT_CORE_OBJECTS[@]}" "${SWIFT_NATIVE_OBJECTS[@]}" "${SWIFT_WEB_OBJECTS[@]}" \
  .build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a \
  -Xlinker -lc++ -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio \
  -framework CoreMedia -framework CoreVideo -o "$APP/Contents/MacOS/SceneSwiftTests"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable': 'SceneSwiftTests',
                  'CFBundleIdentifier': 'local.dynamicwallpaper.scene-swift-tests',
                  'CFBundleName': 'SceneSwiftTests', 'CFBundlePackageType': 'APPL',
                  'LSUIElement': True, 'NSHighResolutionCapable': True,
                  'NSAudioCaptureUsageDescription': 'Verify system audio response using authored test tones. Captured audio is not stored.',
                  'LSMinimumSystemVersion': '14.0'}, output)
PY
bash scripts/build-web-helper.sh "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built Swift scene integration test only: $APP"
