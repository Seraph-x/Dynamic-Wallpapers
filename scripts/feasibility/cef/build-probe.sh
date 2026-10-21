#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
CEF_ROOT="$PWD/.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal"
PROBE_ROOT="$PWD/.build/dependencies/cef/CEFProbe.app"
mkdir -p "$PROBE_ROOT/Contents/MacOS" "$PROBE_ROOT/Contents/Frameworks"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fno-rtti \
  -I "$CEF_ROOT" scripts/feasibility/cef/probe.mm \
  .build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a \
  -framework AppKit -framework Cocoa -framework IOSurface -framework AVFoundation \
  -o "$PROBE_ROOT/Contents/MacOS/CEFProbe"
cp -R "$CEF_ROOT/Release/Chromium Embedded Framework.framework" "$PROBE_ROOT/Contents/Frameworks/"
cp scripts/feasibility/cef/Info.plist "$PROBE_ROOT/Contents/Info.plist"
for suffix in '' ' (GPU)' ' (Renderer)' ' (Alerts)' ' (Plugin)'; do
  helper="CEFProbe Helper$suffix"
  helper_root="$PROBE_ROOT/Contents/Frameworks/$helper.app/Contents"
  mkdir -p "$helper_root/MacOS"
  cp "$PROBE_ROOT/Contents/MacOS/CEFProbe" "$helper_root/MacOS/$helper"
  cp scripts/feasibility/cef/Info.plist "$helper_root/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $helper" "$helper_root/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$helper_root/Info.plist"
done
codesign --force --deep --sign - "$PROBE_ROOT"
