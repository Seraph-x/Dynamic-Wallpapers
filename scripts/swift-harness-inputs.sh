#!/bin/bash
# Resolve the two SwiftPM artifact layouts for standalone integration harnesses.
# Source this file after obtaining BIN from swift build --show-bin-path.
if [[ -f "$BIN/WallpaperCore.o" ]]; then
    echo "Integration harness inputs: Swift Build consolidated objects"
    SWIFT_HARNESS_IMPORTS=(-I "$BIN" -Xcc
        "-fmodule-map-file=$BIN/../../Intermediates.noindex/GeneratedModuleMaps/WebWallpaperBridge.modulemap")
    SWIFT_AUDIO_OBJECTS=("$BIN/WallpaperAudioSpectrum.o")
    SWIFT_CORE_OBJECTS=("$BIN/WallpaperCore.o")
    SWIFT_NATIVE_OBJECTS=("$BIN/WallpaperNative.o")
    SWIFT_WEB_OBJECTS=("$BIN/WebWallpaperBridge.o")
elif [[ -d "$BIN/Modules" && -d "$BIN/WallpaperCore.build" ]]; then
    echo "Integration harness inputs: legacy SwiftPM per-source objects"
    SWIFT_HARNESS_IMPORTS=(-I "$BIN/Modules" -I "$BIN/WebWallpaperBridge.build")
    SWIFT_AUDIO_OBJECTS=("$BIN"/WallpaperAudioSpectrum.build/*.o)
    SWIFT_CORE_OBJECTS=("$BIN"/WallpaperCore.build/*.o)
    SWIFT_NATIVE_OBJECTS=("$BIN"/WallpaperNative.build/*.o)
    SWIFT_WEB_OBJECTS=("$BIN"/WebWallpaperBridge.build/*.o)
else
    echo "Unsupported Swift build artifact layout: $BIN" >&2
    return 1
fi
if [[ ! -f "${SWIFT_NATIVE_OBJECTS[0]}" ]]; then
    echo "Missing WallpaperNative build objects: $BIN" >&2
    return 1
fi

if [[ ! -f "${SWIFT_AUDIO_OBJECTS[0]}" ]]; then
    echo "Missing WallpaperAudioSpectrum build objects: $BIN" >&2
    return 1
fi
