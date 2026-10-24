# Standalone Scene Editor and Two-Way File Interface

## Confirmed direction

The user clarified that Editor is an independent wallpaper-editor application,
not a generic plugin framework inside the wallpaper app. Source stays in this
repository under `Editor/`, with its own package, version, application bundle and
release artifact. The wallpaper app exposes one `Editor` menu-bar action. It
ships no Editor application or UI payload and never installs/downloads Editor
on startup. A missing Editor only prompts when the user chooses that action.
Ordinary playback, playlists, audio, startup and quit remain independent.

The approved first scope remains: create/import loose and PKG scenes; image,
text and basic layer editing; real-time preview; undo/redo; save/reopen; loose
and PKG export. Advanced bones, timeline/keyframes and a script IDE are excluded.
Removing the Editor application leaves saved projects intact. README credits
DSH Wallpaper Engine as design reference and WebWallGL/other actual dependencies.
Docs-only/release-only changes need no PR; this feature uses several focused
English PRs and the configured real-email author.

## Projects and shared code

Expose small library products from this repository for the existing scene types,
managed resource-copy logic, rendering bridge and new authoring/file-interface
logic. `Editor/Package.swift` depends on those local products. Main playback does
not depend on the Editor executable or authoring UI. Keep Apple Silicon/macOS
14.0 as deployment targets; the existing optional spectrum remains 14.2+.

Use the exact published MIT @webwallgl/editor 3.0.0 and webwallgl 3.0.0 APIs,
bundled offline. The Editor application runs its own native CEF child views,
reusing common bridge/build code while packaging its own runtime closure. No
Node server, Electron wrapper, CDN or native-code plugin loading is introduced.

Main can provide read-only scene offers and a versioned render-resource
reference. Editor may use the pinned shared WebWallGL module only after exact
version/hash verification; its own identical pinned module is always available.
Resource-source selection never substitutes a different renderer or hides a
missing capability. Both use the same scene format and resource handling. An
Editor app remains usable without a running/installed wallpaper application.

## Two-way interface, version 1

Use typed file URLs/JSON and targeted macOS application opening, with explicit
API version 1 and exact allowed query fields. Reject unknown versions/actions,
remote file hosts, non-file resource URLs, duplicate fields, malformed scene
references and unsafe project-relative paths. Data arguments are never shell
commands or caller-provided executable JavaScript.

Main -> Editor: open the application or a scene-project offer. On the explicit
Editor action, Main may atomically publish one versioned descriptor containing
its scene offers and optional pinned renderer resource. The descriptor contains
no write/process API and is not generated/hashed during routine app startup.
Editor reads offers, then imports a complete owned copy before editing.

Editor -> Main: materialize a saved loose scene export, target the known wallpaper
application, and request import. Main validates/probes it through the existing
managed scene importer, opens the selected library item and leaves current
wallpaper playback unchanged until the user applies it. If Main is absent,
Editor still saves/exports normally and explains the missing integration only
when that integration action is selected.

Discover/focus a registered Editor application by its expected bundle identifier
and targeted NSWorkspace opening. If absent, ask whether to install Editor, with only Download Editor and Cancel
actions. Open the official download only after confirmation. Main does not grow its
own app installer/updater, ZIP plugin store or background editor service. Users
remove Editor like an ordinary macOS application.

## Owned authoring projects

Editor has its own Application Support/Projects directory and CEF cache. Neither
cache is the wallpaper app's root_cache_path, and neither process deletes the
other's cache. New/imported projects have stable UUIDs, a stable resource root,
and one authoritative schema-1 workspace document containing scene/project JSON.
Save atomically replaces that document after validation and revision checking.
Export materializes ordinary project.json/scene JSON and resources.

Preserve unknown JSON fields and all unmodified resources. Import is a complete
copy through existing descriptor-checked managed-file logic; never edit the
original folder or Main's currently playing library copy. PKG extraction checks
header/table/string/offset bounds, duplicate/case aliases and safe relative paths
against actual file length before materializing files. Unsupported containers
fail visibly. No synthetic success or picture/video replacement.

One Editor application instance per project-store root holds a process lease.
Each project UUID has one live editing session; repeated open focuses its window.
Save also rejects a changed on-disk revision rather than overwriting another
process/external edit. Relaunching Main or clicking Editor repeatedly focuses the
existing Editor instance. Main quitting leaves unsaved Editor work alive; Editor
is responsible for its own Save/Discard/Cancel close and CEF shutdown.

## Editor behavior and UI

Native project/file actions: New, Open, Add Image, Save, Export Loose/PKG and Open
in Dynamic Wallpaper. The browser UI supplies a layer tree, actual WebGL canvas,
selection/transform interaction and inspector. Support rename, visibility,
ordering, duplicate/delete, position, scale, rotation, color/opacity, image and
text layers. Basic supported fields on other layer types remain editable while
the rest of their data survives. Script/animation-controlled fields are clearly
identified and read-only in this first inspector, preserving bindings.

Each edit is undoable and must change both document and actual rendered pixels.
Use upstream hot controls where valid and deliberate scene rebuild/seek for
structural edits. Image creation follows upstream model/material/source-image
layout. PKG export uses buildScenePkg (PNG/JPEG-to-TEX wrapping), retains project
metadata outside the container, and checks output with checkWeCompat/read-back.
Diagnostics remain visible; do not claim every Wallpaper Engine feature works.
Editor preview is muted and supplies explicit zero spectrum instead of synthetic
engine input; exported scenes retain audio-response data for real Main playback.

All user-facing host/editor controls support the existing five languages. Do not
expose plugin-management settings or extra menu-bar icons. Editor-specific errors
and downloads stay in Editor's action/window, outside Main's playback error flow.

## CEF boundary and runtime ownership

A separate Editor process owns its CEF runtime. Native child views provide real
keyboard, focus, text selection, pointer and resize behavior. Keep the wallpaper
app's offscreen pages unchanged. Each editing page has its own unpredictable
origin, descriptor-bound runtime/project mounts, session/generation and typed
ready/dirty/document/export/error events. Unique request IDs reject stale and
unsolicited replies. Native file mutations/dialogs originate in native user
commands; scene code receives no arbitrary filesystem/process primitive.

Only claim ready after the actual engine first frame and trusted handshake.
External navigation, network and OS-protocol execution from scene/editor content
are denied. Closing owns browsers, contexts, readers and continuations until
actual release. A close failure keeps the window/session owned and visible.
Editor closes its pages before its own runtime shutdown. Editor crash/CEF failure
cannot shut down Main's independent process or alter its wallpaper state.

## Delivery and acceptance

1. Shared file interface and safe authoring/project module.
2. Standalone Editor application, native CEF UI, editing and import/export.
3. Main menu/first-use integration, two-way project opening and independent release
   packaging/documentation/acceptance. Cross-link dependencies and merge order.

TDD covers URL/schema boundaries, project copy/save/conflicts, PKG bounds and
round trips, unknown-field preservation, edit/undo/redo, dirty/save failures,
stale messages and actual close lifetimes. Build before 60-second targeted test
budgets. Native acceptance creates image/text projects, verifies edit/undo/redo
pixels, saves/reopens, exports loose/PKG and renders both with Main's scene player.
Run simultaneous wallpaper playback and Editor, remove Editor and verify Main
still works and projects remain, and quit/reopen Main while unsaved Editor lives.
Verify a normal Main application has no Editor bundle/payload and does no Editor
lookup/install/network operation until its menu action. Use authored fixtures and
isolated app data; do not change the user's installed app or library.

## References

- https://github.com/oneincase/webwallgl (published editor API 3.0.0; reviewed
  source tree 197abe54266c31d346cebc314e49a26b70c960cc)
- https://github.com/elysia395/dsh-wallpaper-engine (hosting/input design reference)
