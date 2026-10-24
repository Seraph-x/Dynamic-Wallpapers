#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_ROOT="$PWD/.build/verification/web-page-state/$(uuidgen)"
mkdir -p "$RUN_ROOT"
echo "WEB_PAGE_STATE artifacts=$RUN_ROOT"
exec > "$RUN_ROOT/test.log" 2>&1
CEF_ROOT="$PWD/.build/dependencies/cef/cef_binary_152.0.6+g708dc14+chromium-152.0.7977.83_macosarm64_minimal"
WRAPPER="$PWD/.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a"
clang++ -std=c++20 -mmacosx-version-min=14.0 -fobjc-arc -frtti -O2 -DNS_BLOCK_ASSERTIONS -Wall -Wextra -Werror \
  -isystem "$CEF_ROOT" -I Sources/WebWallpaperBridge/include -I Sources/WebWallpaperBridge \
  Tests/WebRuntimeHarness/page-state-main.mm Tests/WebRuntimeHarness/page-state-tests.mm \
  Sources/WebWallpaperBridge/WebRuntime.mm Sources/WebWallpaperBridge/WebClient.cpp Sources/WebWallpaperBridge/WebAudioOutput.mm \
  Sources/WebWallpaperBridge/LocalProjectFiles.cpp Sources/WebWallpaperBridge/LocalWebRequestContext.cpp Sources/WebWallpaperBridge/SceneProtocol.mm \
  "$WRAPPER" -framework AppKit -framework QuartzCore -framework AVFoundation -framework CoreAudio -o "$RUN_ROOT/WebPageStateTests"
set +e
"$RUN_ROOT/WebPageStateTests"
result=$?
printf '%s\n' "$result" > "$RUN_ROOT/exit-code.txt"
exit "$result"
