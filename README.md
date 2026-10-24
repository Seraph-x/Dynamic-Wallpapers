# Dynamic Wallpaper

A local-first macOS app for turning your own videos, animated images, pictures, web projects, and local scene projects into desktop wallpapers.

This repository contains the source code and build instructions. A prebuilt release is attached to the [v0.3.0 release](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/v0.3.0); building from source is still the supported path for development. Dynamic Wallpaper is for Apple Silicon Macs and has a macOS 14 deployment target.

## Overview

- **Your media, your desktop:** import local files, web projects or scene projects, preview them on the desktop, and apply a single wallpaper without creating a playlist.
- **Local scenes:** import Wallpaper Engine loose JSON/PKG projects with `project.json`, render offline through bundled WebWallGL/CEF, and pause/resume the same scene. Author defaults are used; engine compatibility varies. System audio spectrum capture, scene editing and scene screen-saver playback are excluded. See [scene validation and limits](docs/testing/scene-wallpapers.md).
- **Playlists and displays:** arrange wallpapers in order or shuffle them, control duration and transitions, and choose independent or synchronized playback across displays.
- **Everyday controls:** adjust fit and audio, pause or switch playback from the menu bar, and optionally publish supported media as a macOS screen saver.

The app and its offline guide are available in English, Simplified Chinese, Japanese, French, and Spanish.

## Requirements

- Apple Silicon Mac with a full Xcode installation that includes the macOS 26 SDK or newer. The build host must meet that Xcode version's macOS requirements; the app's macOS 14 deployment target is not the build-host minimum.
- Python 3.11 or newer, CMake, make, curl, network access, and disk space for CEF, mpv, FFmpeg, SwiftPM outputs, and the app bundle.

## Download a prebuilt build

The [v0.3.0 release](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/v0.3.0) provides `DynamicWallpaper-0.3.0-arm64.dmg` (Apple Silicon, macOS 14 or later). Verify the download before installing:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The published build is ad-hoc signed and not notarized by Apple, so macOS blocks the first launch. Allow it once with Control-click → **Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Dynamic Wallpaper.app"
```

Install notes ship inside the DMG in English, Simplified Chinese, Japanese, French, and Spanish.

## Build from source

Clone the repository, then build a local app bundle:

```sh
git clone https://github.com/Seraph-x/Dynamic-Wallpapers.git
cd Dynamic-Wallpapers
python3 scripts/prepare-public-build.py
bash scripts/build-app.sh --output dist/DynamicWallpaper-source-build.app
```

Preparation downloads SHA256-pinned CEF and mpv binaries and builds FFmpeg from pinned source. See [BUILDING.md](BUILDING.md) for the complete procedure, including help and bundle verification. Build outputs stay local; these commands do not replace an installed app or modify its media library.

## First steps

Launch the app you built:

```sh
open dist/DynamicWallpaper-source-build.app
```

1. In the app, choose **Import Wallpaper** to add local media or a local web project.
2. Select an item to preview it, choose a display and fit mode, then select **Apply Wallpaper**.
3. To rotate several items, create a playlist, add wallpapers, set their order and timing, then select **Apply Playlist**.

## Help and troubleshooting

For display options, audio controls, screen saver setup, and common problems, read the [English user guide](docs/help/en.md). You can switch to the other guide languages from there. Build prerequisites and verification commands are in [BUILDING.md](BUILDING.md).

## License

Project-authored source and documentation are licensed under [GNU GPL version 3 or later](LICENSE) (`GPL-3.0-or-later`). Third-party components retain their own licenses; see the [dependency and notice inventory](Resources/ThirdParty/README.md). Building for personal use does not by itself establish permission to redistribute the resulting app binary.
