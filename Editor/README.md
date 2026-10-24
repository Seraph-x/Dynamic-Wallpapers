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

From the repository root, build an independent candidate with its own CEF
framework/helpers, offline editor resources, legal notices and ZIP:

```sh
python3 scripts/build-editor-app.py --output 'dist/editor/Dynamic Wallpaper Editor.app' --zip
```

The output must be new; the script never replaces an installed app. It verifies
the pinned CEF download, release executable SDK, all Mach-O dependencies, ad-hoc
signatures, five localizations and the ZIP after extraction. The checksum file
accompanies the ZIP. No Editor release is published by this command. See
[installation/removal](../docs/editor-install.md) and [acceptance tests](../docs/testing/standalone-editor.md).

The wallpaper menu-bar **Editor** action opens the installed application or
offers **Download Editor / Cancel**. A handoff from Main offers read-only scene
references; imports create Editor-owned copies. **File → Import from Dynamic
Wallpaper** selects from those offers. **File → Open in Dynamic Wallpaper** saves
an immutable standard scene snapshot and imports it into Main's library without
applying it or adding it to a playlist. Each application keeps its own changes;
no automatic file synchronization occurs. Both can run and quit independently.

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
