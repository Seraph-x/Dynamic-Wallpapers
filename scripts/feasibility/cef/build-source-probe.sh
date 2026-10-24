#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
CEF_ROOT="$PWD/.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal"
APP="$PWD/.build/dependencies/cef/CEFSourceProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
# This code catches std::filesystem exceptions by std::exception. On this toolchain
# -fno-rtti breaks that base-class match (isolated RED); do not inherit the old probe's flag.
clang++ -std=c++20 -mmacosx-version-min=14.0 -frtti -fobjc-arc -Wall -Wextra -Werror \
  -isystem "$CEF_ROOT" -I Sources/WebWallpaperBridge \
  Tests/CEFSourceHarness/source-probe.mm Sources/WebWallpaperBridge/LocalProjectFiles.cpp \
  Sources/WebWallpaperBridge/LocalWebRequestContext.cpp Sources/WebWallpaperBridge/SceneProtocol.mm \
  .build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a \
  -framework AppKit -framework Cocoa -o "$APP/Contents/MacOS/CEFSourceProbe"
cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "$APP/Contents/Frameworks/"
cp scripts/feasibility/cef/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CEFSourceProbe' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.dynamicwallpaper.cef-source-probe' "$APP/Contents/Info.plist"
for suffix in '' ' (GPU)' ' (Renderer)' ' (Alerts)' ' (Plugin)'; do
  name="CEFSourceProbe Helper$suffix"
  helper="$APP/Contents/Frameworks/$name.app/Contents"
  mkdir -p "$helper/MacOS"
  cp "$APP/Contents/MacOS/CEFSourceProbe" "$helper/MacOS/$name"
  cp "$APP/Contents/Info.plist" "$helper/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $name" "$helper/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$helper/Info.plist"
done
# A separate diagnostic app, never the delivered DynamicWallpaper.app.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
