# Dynamic Wallpaper Editor

A standalone macOS scene editor, developed in the same repository as Dynamic
Wallpaper. It has its own application, process, version, projects and CEF cache.
It is not installed with the wallpaper application. Removing either application
does not delete the Editor's saved projects.

The initial version supports new scenes; importing loose or PKG projects;
image/text layers; layer ordering, visibility and duplication; position, scale,
rotation, color and opacity; canvas picking/dragging; live preview with
play/pause; undo/redo; save/reopen; and loose/PKG export. Script, animation and
property-bound fields remain read-only. Preview is muted with explicit zero
system spectrum; exports preserve audio response for wallpaper playback.
Advanced timelines, skeleton tools and a script IDE are outside this version.

Use **File → New Project** or **Open Project**. Imports create complete owned
copies. **Save** writes the Editor workspace; **Export** creates a standard scene
folder without replacing an existing destination. Reopen `workspace.json` from
the Editor's `Projects` directory to continue a saved workspace. User data is
stored under `~/Library/Application Support/DynamicWallpaperEditor/`.

## Development

Requires Apple Silicon, macOS 14+, Xcode and the repository's pinned CEF SDK and
wrapper. The Editor does not link MPV/FFmpeg or the wallpaper executable. Its
Swift package consumes the repository's shared library products.

```sh
mkdir -p Editor/Web/.build
cp Editor/Web/package.json Editor/Web/package-lock.json Editor/Web/.build/
npm ci --prefix Editor/Web/.build --ignore-scripts
node Editor/Web/build.mjs --check
cd Editor
python3 ../scripts/swift_sdk.py build --disable-sandbox
```

The application package must include its own CEF framework/helpers and SwiftPM
resource bundle. Independent application packaging and the optional Main menu
handoff are provided by the next integration PR. No Editor release is published
by this source change.

`DYNAMIC_WALLPAPER_EDITOR_DATA_ROOT` explicitly selects isolated data for native
acceptance tests. Normal users do not need to configure it.

## References and notices

- [WebWallGL](https://github.com/oneincase/webwallgl): actual pinned playback
  engine and `@webwallgl/editor` API, version 3.0.0; upstream image/text scene
  layout and PKG builder inform this editor. Both are MIT licensed. Our native
  host and focused workbench are implemented in this repository.
- [DSH Wallpaper Engine](https://github.com/elysia395/dsh-wallpaper-engine):
  scene-hosting design reference; no DSH application source is vendored here.
- [CEF](https://bitbucket.org/chromiumembedded/cef/): native browser runtime.
- [Mediabunny](https://github.com/Vanilagy/mediabunny): dependency in the shared
  WebWallGL bundle.

See `ThirdParty/` and the repository's `Resources/ThirdParty/{CEF,WebWallGL}/`
for pinned provenance, upstream license text and distribution status. The Editor
uses the same verified WebWallGL module bytes as Main, and packages its complete
runtime so it can operate independently.
