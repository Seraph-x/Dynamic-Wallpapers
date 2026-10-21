# Dynamic Wallpaper

A local-first macOS app for turning your own videos, animated images, pictures, and web projects into desktop wallpapers.

This repository contains source code and build instructions, not a prebuilt app. Dynamic Wallpaper is for Apple Silicon Macs and has a macOS 14 deployment target.

## Overview

- **Your media, your desktop:** import local files or web projects, preview them on the desktop, and apply a single wallpaper without creating a playlist.
- **Playlists and displays:** arrange wallpapers in order or shuffle them, control duration and transitions, and choose independent or synchronized playback across displays.
- **Everyday controls:** adjust fit and audio, pause or switch playback from the menu bar, and optionally publish supported media as a macOS screen saver.

The app and its offline guide are available in English, Simplified Chinese, Japanese, French, and Spanish.

## Requirements

- Apple Silicon Mac with a full Xcode installation that includes the macOS 26 SDK or newer. The build host must meet that Xcode version's macOS requirements; the app's macOS 14 deployment target is not the build-host minimum.
- Python 3.11 or newer, CMake, make, curl, network access, and disk space for CEF, mpv, FFmpeg, SwiftPM outputs, and the app bundle.

## Build from source

Clone the repository, then build a local app bundle:

```sh
git clone https://github.com/Seraph-x/Dynamic-Wallpapers.git
cd Dynamic-Wallpaper
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
