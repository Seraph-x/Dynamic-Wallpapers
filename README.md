# Dynamic Wallpaper

Play local videos, animations, images, web projects and scene wallpapers on an Apple Silicon Mac. Apply one wallpaper or rotate a playlist across independent or synchronized displays.

[Download v1.0.0](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/v1.0.0) · [中文指南](docs/help/zh-Hans.md) · [English guide](docs/help/en.md) · [日本語](docs/help/ja.md) · [Français](docs/help/fr.md) · [Español](docs/help/es.md)

## Install 1.0.0

Requires **Apple Silicon (arm64), macOS 14.0 or later**. Intel Macs are not supported by these builds.

1. Download `DynamicWallpaper-1.0.0-arm64.dmg` and `SHA256SUMS.txt` from the release page.
2. Verify the download: `shasum -a 256 DynamicWallpaper-1.0.0-arm64.dmg`, then compare the result with `SHA256SUMS.txt`.
3. Open the DMG, drag **Dynamic Wallpaper.app** into **Applications**, then eject the DMG.
4. Launch the app from Applications. This build is ad-hoc signed and is **not Apple-notarized**. If macOS blocks it, verify the download first, then use **System Settings → Privacy & Security → Open Anyway** for this app.

A ZIP build is available too. Extract it and move the app into Applications. Installation notes in all five app languages are included in the DMG and attached to the release. Read the [1.0.0 release notes](docs/releases/1.0.0/RELEASE_NOTES.md) for tested behavior and limitations.

## Use your own wallpapers

Choose **Import Wallpaper** and select the matching source:

| Source | What to select | Playback |
| --- | --- | --- |
| Media Files | A local video, GIF/APNG or still image | Per-item audio, fit, preview and playlist timing |
| Web Project | A project folder and its HTML entry | Local resources; pause keeps the picture and resume reloads the page |
| Scene Project | A folder containing `project.json` and its loose JSON or PKG scene | Offline real-time rendering; pause and resume retain the same scene and clock |

Imports create independent copies in the library. Changes to the original files are not synchronized. Select an item, choose a display and fit mode, preview it, then click **Apply Wallpaper**. For rotation, create a playlist, add items and click **Apply Playlist**. Removing imported media does not delete the originals.

- Set different wallpapers per display or use **All Displays · Synchronized**.
- Use menu-bar controls to pause, resume, switch wallpapers or mute output. Configure volume per item or playlist entry.
- Scenes and web pages use fixed playlist durations. Scene playback uses the author’s default properties; compatibility depends on the pinned WebWallGL engine.
- Enable **Web Interaction** and its macOS permissions for empty-desktop clicks and scene mouse movement. It is off by default.
- Publish supported media to the bundled native screen saver. Web and scene projects are excluded.
- Optionally synchronize a still system wallpaper or transcode eligible videos from the app.

The app and its bundled offline help support **简体中文, English, 日本語, Français and Español**. Open **User Guide** from the app or menu-bar icon; no network connection is needed to read it.

## System audio response (source builds)

Optional system audio response uses Core Audio Tap on macOS 14.2+. Enable it in Settings → General → Sound and allow system audio recording when prompted. Playing scenes share one stereo spectrum capture; wallpaper output mute is independent. Capture excludes this app’s audio, uses no microphone, and does not save or upload audio. Pausing/closing all scenes or disabling the setting stops capture. Capture errors remain visible and offer an explicit retry. Other app features retain macOS 14.0 support. These additions are not part of the published 1.0.0 binaries.

## Standalone Editor (source builds)

The [scene Editor](Editor/README.md) is an independent application with its own
version, process, projects and runtime. It is never installed with the wallpaper
app. The menu-bar **Editor** action opens it when installed; otherwise it asks
**Download Editor** or **Cancel**, with no automatic installation. Download opens
the official releases page. The published 1.0.0 binaries predate this feature;
an independent Editor release has not been published yet.

Create or import loose/PKG scenes, edit image/text layers with live preview,
undo/redo, save projects and export loose/PKG. **File → Open in Dynamic Wallpaper**
imports an owned copy into the wallpaper library without automatically applying
it. Both applications work independently. Removing Editor leaves saved projects
and wallpaper playback intact. See [installation and removal](docs/editor-install.md).

The two applications share source modules in this repository and ship their own
runtime dependencies. Editor has its own version (currently 0.1.0), bundle
identity and CEF cache. Building Editor requires the complete repository;
the resulting application can run on its own.

### Repository and data layout

```text
Dynamic-Wallpapers/
├── Package.swift                    # Main app and shared library products
├── Sources/
│   ├── WallpaperApp/                # Wallpaper app, including the Editor entry
│   ├── WallpaperCore/               # Shared models and versioned file contracts
│   ├── WallpaperEditorCore/         # Editor-owned projects, resources and export
│   └── WebWallpaperBridge/          # Shared native CEF rendering bridge
├── Editor/
│   ├── Package.swift                # Independent Editor application package
│   ├── product.json                 # Editor identity and version
│   ├── Sources/EditorApp/            # Native Editor host and offline resources
│   └── Web/                         # Workbench source and browser tests
├── Tests/
└── scripts/build-editor-app.py      # Separate Editor app/ZIP builder
```

| Application | User data | Removing the application |
| --- | --- | --- |
| Dynamic Wallpaper | `~/Library/Application Support/DynamicWallpaper/` | Editor and its projects remain available |
| Dynamic Wallpaper Editor | `~/Library/Application Support/DynamicWallpaperEditor/` | Existing wallpaper playback and saved Editor projects remain available |

Editor workspaces live in `Projects/<project ID>/workspace.json`, with scene
assets alongside them in `Project/`. `Handoffs/` holds exported snapshots and
`CEFCache/` holds Editor's browser cache. Main's `Media/` stores its own imported
copies. Each application saves its own managed copy; edits are not synchronized
automatically.

## Scene compatibility and data

Import projects you trust: scene scripts execute inside the CEF renderer. Scenes are rendered locally using bundled WebWallGL/CEF; the app does not download an engine from a CDN or require Node at runtime. The optional Editor is packaged separately; scene screen-saver playback is not included. Some unsupported effects produce engine warnings. See [scene validation and limits](docs/testing/scene-wallpapers.md).

Version 1.0.0 saves library schema 4. Libraries from earlier supported versions load without rewriting the existing file until a save. An older app may reject a library saved by 1.0.0. Keep a separate copy of your library data before upgrading if you need to downgrade later; see the guide’s [data section](docs/help/en.md#data).

## Build from source

Use an Apple Silicon Mac with full Xcode, a macOS 26 SDK or newer, Python 3.11+, CMake, make and curl. The build host must meet Xcode’s system requirements; macOS 14 is the app deployment target.

```sh
git clone https://github.com/Seraph-x/Dynamic-Wallpapers.git
cd Dynamic-Wallpapers
python3 scripts/prepare-public-build.py
bash scripts/build-app.sh --output dist/DynamicWallpaper-source-build.app
```

Preparation verifies pinned CEF/mpv inputs and builds FFmpeg from pinned source. The scene bundle is checked into source; Node is only needed to reproduce that bundle or run browser tests. Build commands create a new candidate and do not replace the installed app or alter its library. See [BUILDING.md](BUILDING.md) for verification and [release notes](docs/releases/1.0.0/RELEASE_NOTES.md) for release packaging.

## References and acknowledgements

The scene-wallpaper work draws on these projects:

| Project | Role in Dynamic Wallpaper |
| --- | --- |
| [DSH Wallpaper Engine](https://github.com/elysia395/dsh-wallpaper-engine) | Design reference for hosting WebWallGL scene wallpapers and supplying audio spectrum and pointer input from the host application. |
| [WebWallGL](https://github.com/oneincase/webwallgl) | The bundled scene renderer: parses local Wallpaper Engine projects and renders them with WebGL. The current playback integration pins version 3.0.0. The standalone Editor uses the pinned `@webwallgl/editor` 3.0.0 API, image/text scene conventions and PKG builder. |
| [Chromium Embedded Framework](https://github.com/chromiumembedded/cef) | The embedded Chromium runtime used for web and scene wallpaper playback. |
| [mpv](https://github.com/mpv-player/mpv) and [FFmpeg](https://ffmpeg.org/) | Extended media playback, probing and transcoding. |
| [Mediabunny](https://github.com/Vanilagy/mediabunny) | Media handling included in the pinned WebWallGL bundle. |

WebWallGL's distribution also includes vendored code with a retained
[WeScene MIT notice](Resources/ThirdParty/WebWallGL/WeScene-LICENSE). Exact pinned
inputs, source URLs and license notices are recorded in the
[dependency inventory](Resources/ThirdParty/README.md).

## License and third-party materials

Project-authored code and documentation use [GPL-3.0-or-later](LICENSE). Dependencies retain their own licenses, including WebWallGL/WeScene (MIT) and Mediabunny (MPL-2.0). See the [dependency inventory](Resources/ThirdParty/README.md).

The retained mpv corresponding-source/per-library notice records and per-build FFmpeg distribution review remain incomplete; the release preserves that status. A valid signature, successful build or 1.0.0 version number does not establish complete redistribution compliance.
