#!/bin/bash
# Sourced only by standalone test-app builders. Production SwiftPM flags stay unchanged.
case "${SCENE_NATIVE_TEST_KEYCHAIN:-system}" in
  system) return 0 ;;
  isolated) ;;
  *) echo "SCENE_NATIVE_TEST_KEYCHAIN must be system or isolated" >&2; return 64 ;;
esac
SCENE_TEST_BRIDGE_ROOT="$PWD/.build/verification/scene-swift-bridge/isolated"
SCENE_TEST_BRIDGE_VERSION="$(python3 -c 'import json; print(json.load(open("scripts/media-dependencies.json"))["modules"]["cef"]["version"])')"
SCENE_TEST_BRIDGE_CEF="$PWD/.build/dependencies/cef/cef_binary_${SCENE_TEST_BRIDGE_VERSION}_macosarm64_minimal"
mkdir -p "$SCENE_TEST_BRIDGE_ROOT"
SWIFT_WEB_OBJECTS=()
for SCENE_TEST_BRIDGE_UNIT in WebRuntime.mm WebPage.mm WebClient.cpp WebAudioOutput.mm LocalProjectFiles.cpp LocalWebRequestContext.cpp SceneProtocol.mm; do
  SCENE_TEST_BRIDGE_OBJECT="$SCENE_TEST_BRIDGE_ROOT/${SCENE_TEST_BRIDGE_UNIT%.*}.o"
  clang++ -std=c++20 -mmacosx-version-min=14.0 -isysroot "${SDK:?Test build requires its selected SDK}" \
    -fobjc-arc -frtti -Wall -Wextra -Werror -DDW_CEF_TEST_KEYCHAIN=1 \
    -isystem "$SCENE_TEST_BRIDGE_CEF" -I Sources/WebWallpaperBridge/include -I Sources/WebWallpaperBridge \
    -c "Sources/WebWallpaperBridge/$SCENE_TEST_BRIDGE_UNIT" -o "$SCENE_TEST_BRIDGE_OBJECT"
  SWIFT_WEB_OBJECTS+=("$SCENE_TEST_BRIDGE_OBJECT")
done
echo "Swift integration test bridge: isolated Keychain; production bridge objects unchanged"
