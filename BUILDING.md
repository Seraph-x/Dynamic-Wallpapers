# Build from source

This procedure builds a new local `.app` on an Apple Silicon Mac. It does not replace an installed application or touch a user's media library.

## Prerequisites

- An Apple Silicon build host with a full Xcode installation that includes the macOS 26 SDK or newer, Swift 6, command-line tools, code signing, and C/C++ compilers. The host must meet that Xcode version's macOS requirement. The app's deployment target is macOS 14; that is not the minimum build-host version.
- Python 3.11 or newer, CMake, make, pkg-config, curl, and enough free disk space for CEF extraction, the complete controlled media source builds, SwiftPM outputs and the final apps. Meson and Ninja use locked source inputs. The current mpv runtime closure contains 14 libraries.
- Network access to the fixed HTTPS URLs in `scripts/media-dependencies.json` and the archives recorded in `scripts/mpv-source-lock.json`. Downloads are checked against the recorded SHA256 values; an input mismatch stops preparation.

The repository includes no prepared dependency cache. `scripts/help-requirements.txt` pins the optional Python Markdown package used to verify the bundled offline help.

## Prepare and build

Run these commands from the source root:

```sh
python3 -m venv .build/help-venv
.build/help-venv/bin/python -m pip install -r scripts/help-requirements.txt
.build/help-venv/bin/python scripts/build-help.py --check
python3 scripts/prepare-public-build.py
python3 scripts/verify-current-media.py
bash scripts/build-app.sh --output dist/DynamicWallpaper-source-build.app
python3 scripts/verify-app-bundle.py dist/DynamicWallpaper-source-build.app \
  --report .build/source-build-verification.json
```

Choose a new output and report name for each attempt; existing candidates and reports are never overwritten. The build uses the selected Xcode macOS SDK. FFmpeg's local build record binds the pinned source, build script, SDK, compiler version, and exact tool bytes. If these change, rebuild FFmpeg in a fresh cache instead of accepting a stale product.

Preparation is non-GUI and does not install the application. The subsequent
`verify-current-media.py` command runs owned video/audio fixtures and actual
H.264/AAC conversion on the logged-in build host, then updates the retained
build/acceptance records and their manifest to the precise prepared binary
bytes. It neither launches Main nor installs a screen saver or writes personal
wallpaper. A failed decode, conversion or byte-bound record check stops the
command; old receipts are not accepted for rebuilt tools. Bundle verification checks static contents, signatures, and dependency closure; it does not prove that GUI playback works on every macOS version. A source build for personal use is separate from permission to redistribute the resulting binary. Verify the complete retained [third-party material manifest](Resources/ThirdParty/distribution-status.json), corresponding-source archives, patches and measured records before distributing a built application.

## Package a sanitized release

Build published binaries from a tracked source snapshot in a non-personal path.
Compiler diagnostics and FFmpeg configuration strings can retain their build
paths; moving an already-built app does not remove them.

```sh
RELEASE_SOURCE=$(mktemp -d /tmp/dynamic-wallpaper-release.XXXXXX)
git archive HEAD | tar -x -C "$RELEASE_SOURCE"
cd "$RELEASE_SOURCE"
python3 scripts/prepare-public-build.py
python3 scripts/verify-current-media.py
bash scripts/build-app.sh --output dist/DynamicWallpaper-1.1.0.app
python3 scripts/create-local-release.py \
  --app dist/DynamicWallpaper-1.1.0.app \
  --output dist/releases/1.1.0 \
  --notes docs/releases/1.1.0/RELEASE_NOTES.md
```

Do not reuse prepared CEF wrapper or FFmpeg products from a personal source
directory for a public artifact. Pinned downloaded inputs can be cached, but
rebuild those products inside the release source directory. Verify signatures
and compare the archive's extracted bytes before uploading. Scan the extracted
app and the final source archive for personal paths and credentials; keep
upstream copyright and license notices intact. Local receipts and diagnostic
logs may contain absolute paths and are not release attachments.

Ship `SHA256SUMS.txt` alongside the DMG/ZIP and the five installation notes in
`docs/releases/1.1.0`. The DMG contains the app and those notes; it must be
mounted read-only and the contained app re-verified after image creation. Source
archives contain tracked files without Git history, local libraries, caches or
validation logs. A clean privacy scan and a valid ad-hoc signature do not imply
Apple notarization or replace review of the retained third-party sources and license notices.

## Independent Editor

Editor has its own version and release tag; it is not bundled with Main:

```sh
python3 scripts/build-editor-app.py --output 'dist/editor/Dynamic Wallpaper Editor.app' --zip
```

The builder recompiles its CEF wrapper and Swift modules in a neutral directory,
checks the offline resource provenance and all five localizations, scans packaged
files for personal paths, verifies Mach-O closure and strict signatures, then
checks ZIP extraction. Editor does not include mpv or FFmpeg. See
[installation and removal](docs/editor-install.md).
