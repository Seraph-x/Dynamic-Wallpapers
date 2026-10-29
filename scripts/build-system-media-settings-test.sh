#!/bin/bash
# Link the actual testable Main application module into an owned consent test app.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$(python3 scripts/swift_sdk.py build --show-bin-path --disable-sandbox)"
source scripts/swift-harness-inputs.sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$PWD/.build/verification/media-settings-host/SystemMediaSettingsTests.app"
APP_TEST_OBJECTS=("$BIN"/ExecutableModules/WallpaperApp-*-testable.o)
if [[ ${#APP_TEST_OBJECTS[@]} != 1 || ! -f "${APP_TEST_OBJECTS[0]}" ]]; then
  echo "Build all Main Swift tests first; expected one current testable application object in $BIN/ExecutableModules" >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -sdk "$SDK" -Xclang-linker -isysroot -Xclang-linker "$SDK" -parse-as-library \
  -swift-version 5 -target arm64-apple-macosx14.0 -module-name SystemMediaSettingsTests \
  "${SWIFT_HARNESS_IMPORTS[@]}" \
  -Xcc "-fmodule-map-file=$BIN/../../Intermediates.noindex/GeneratedModuleMaps/MPVBridge.modulemap" \
  Tests/SystemMediaSettingsHarness/main.swift Tests/WallpaperAppTests/AccessibilityTestText.swift \
  "${APP_TEST_OBJECTS[@]}" "${SWIFT_AUDIO_OBJECTS[@]}" "${SWIFT_MEDIA_OBJECTS[@]}" \
  "${SWIFT_CORE_OBJECTS[@]}" "${SWIFT_NATIVE_OBJECTS[@]}" "${SWIFT_WEB_OBJECTS[@]}" \
  "$BIN/ScreenSaverCore.o" "$BIN/ScreenSaverRuntime.o" "$BIN/MPVBridge.o" \
  .build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a \
  "$PWD/.build/media-source-complete/mpv/runtime-lib/libmpv.2.dylib" \
  -Xlinker -rpath -Xlinker "$PWD/.build/media-source-complete/mpv/runtime-lib" \
  -Xlinker -lc++ -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio \
  -framework CoreMedia -framework CoreVideo -framework SwiftUI -o "$APP/Contents/MacOS/SystemMediaSettingsTests"
python3 - "$BIN" "$APP" <<'PY'
import pathlib, plistlib, sys
sys.path.insert(0, 'scripts')
from localization_bundle import prepare_localizations, CONFIG
binary = pathlib.Path(sys.argv[1]) / CONFIG.application.executable
app = pathlib.Path(sys.argv[2])
resources = app / 'Contents/Resources/DynamicWallpaper_WallpaperApp.bundle'
if resources.exists():
    import shutil
    shutil.rmtree(resources)
prepare_localizations(binary, app)
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleExecutable': 'SystemMediaSettingsTests',
                  'CFBundleIdentifier': 'local.dynamicwallpaper.app.validation.media-settings',
                  'CFBundleName': 'SystemMediaSettingsTests', 'CFBundlePackageType': 'APPL',
                  'CFBundleDevelopmentRegion': CONFIG.development_localization,
                  'CFBundleLocalizations': list(CONFIG.localizations),
                  'NSAppleEventsUsageDescription': 'Verify actual media consent controls using an owned fixture only; personal players are never targeted.',
                  'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '14.0'}, output)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built actual Main settings consent test app only: $APP"
