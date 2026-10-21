#!/bin/bash
# Build an isolated benchmark from the actual capture and native-player sources.
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 scripts/swift_sdk.py build --disable-sandbox
BIN="$(python3 scripts/swift_sdk.py build --show-bin-path --disable-sandbox)"
source scripts/swift-harness-inputs.sh
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$PWD/.build/verification/live-fullscreen-wallpaper-20260913/performance/MirrorCaptureBenchmark.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -sdk "$SDK" -Xclang-linker -isysroot -Xclang-linker "$SDK" -parse-as-library -swift-version 5 -target arm64-apple-macosx14.4 -warnings-as-errors -O "${SWIFT_HARNESS_IMPORTS[@]}" \
  scripts/feasibility/mirror/{BenchmarkMain,CapturePhase}.swift \
  Sources/WallpaperApp/Playback/{WallpaperMirrorStream,WallpaperMirrorFrameOutput,WallpaperScreenshotProducer}.swift \
  Sources/WallpaperApp/UI/WallpaperMirrorView.swift \
  "${SWIFT_CORE_OBJECTS[@]}" "${SWIFT_NATIVE_OBJECTS[@]}" \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreVideo -framework QuartzCore -framework SwiftUI -framework ImageIO \
  -o "$APP/Contents/MacOS/MirrorCaptureBenchmark"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
with p.open('wb') as f:
    plistlib.dump({'CFBundleExecutable':'MirrorCaptureBenchmark',
        'CFBundleIdentifier':'local.dynamicwallpaper.mirror-benchmark',
        'CFBundleName':'Mirror Capture Benchmark','CFBundlePackageType':'APPL',
        'LSMinimumSystemVersion':'14.4','NSHighResolutionCapable':True},f)
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built benchmark only: %s\n' "$APP"
