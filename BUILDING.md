# Build from source

This procedure builds a new local `.app` on an Apple Silicon Mac. It does not replace an installed application or touch a user's media library.

## Prerequisites

- An Apple Silicon build host with a full Xcode installation that includes the macOS 26 SDK or newer, Swift 6, command-line tools, code signing, and C/C++ compilers. The host must meet that Xcode version's macOS requirement. The app's deployment target is macOS 14; that is not the minimum build-host version.
- Python 3.11 or newer, CMake, make, curl, and enough free disk space for CEF extraction, 69 mpv libraries, an FFmpeg source build, SwiftPM outputs, and the final app.
- Network access to the fixed HTTPS URLs in `scripts/media-dependencies.json`. Downloads are checked against the recorded SHA256 values; an input mismatch stops preparation.

The repository includes no prepared dependency cache. `scripts/help-requirements.txt` pins the optional Python Markdown package used to verify the bundled offline help.

## Prepare and build

Run these commands from the source root:

```sh
python3 -m venv .build/help-venv
.build/help-venv/bin/python -m pip install -r scripts/help-requirements.txt
.build/help-venv/bin/python scripts/build-help.py --check
python3 scripts/prepare-public-build.py
bash scripts/build-app.sh --output dist/DynamicWallpaper-source-build.app
python3 scripts/verify-app-bundle.py dist/DynamicWallpaper-source-build.app \
  --report .build/source-build-verification.json
```

Choose a new output and report name for each attempt; existing candidates and reports are never overwritten. The build uses the selected Xcode macOS SDK. FFmpeg's local build record binds the pinned source, build script, SDK, compiler version, and exact tool bytes. If these change, rebuild FFmpeg in a fresh cache instead of accepting a stale product.

Preparation is non-GUI and does not install the application. Bundle verification checks static contents, signatures, and dependency closure; it does not prove that GUI playback works on every macOS version. A source build for personal use is separate from permission to redistribute the resulting binary. Review the incomplete [third-party materials status](Resources/ThirdParty/distribution-status.json) before distributing a built application.
