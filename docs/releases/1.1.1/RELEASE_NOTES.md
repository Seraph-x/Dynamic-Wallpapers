# Dynamic Wallpaper 1.1.1

Apple Silicon (arm64) · macOS 14.0 or later · build 6

## Changes

- Reduce retained thumbnail pixel storage and share concurrent decoding requests for the same source. Stop fullscreen polling while an existing power policy pauses playback.
- Apply volume changes immediately while saving the interaction as one completed edit, instead of repeatedly serializing the library during a drag.
- Index library validation and reuse filtered media collections to avoid repeated scans.
- Reuse released mpv pixel buffers and copy changed web/scene frame regions while preserving retained-frame ownership.
- Schedule desktop interaction work on demand and replace repeated CEF page-lifecycle polling with event notifications and deadline timers. The required CEF message pump remains active.
- Group localized menu-bar actions into playback, wallpaper and management controls.
- Move Editor source, authoring tools, tests and packaging into [Wallpaper-Editor](https://github.com/Seraph-x/Wallpaper-Editor). Main builds independently and retains scene playback, scripts, properties and saved-scene import. The Editor launch entry is removed; start the separate app from Applications.

These changes include the eight performance/menu commits merged at `60af80e`. [Recorded source-level workloads](../../testing/main-app-performance.md) describe specific tests; they do not establish an overall CPU, GPU or resident-memory reduction for every wallpaper.

## Compatibility and installation

Application identifiers, URL-based scene import, project formats and user-data locations are unchanged. The library remains at schema 4. Existing scene projects continue to use the same import and playback contract; the repository split does not migrate or delete installed apps, libraries or Editor projects.

Download the DMG or ZIP from [v1.1.1](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/v1.1.1) and compare it with `SHA256SUMS.txt`. The app is ad-hoc signed and not Apple-notarized. These artifacts support Apple Silicon, not Intel Macs.

[简体中文](INSTALL-zh-Hans.md) · [English](INSTALL-en.md) · [日本語](INSTALL-ja.md) · [Français](INSTALL-fr.md) · [Español](INSTALL-es.md)

Quit the previous copy normally before replacing it. Imported media is stored separately. For rollback, keep a separate library copy before upgrading; older applications may reject newer fields. “Back Up and Clear Library” also clears the active library. Removing Main preserves Editor and its projects; remove an installed optional screen saver separately. Earlier release assets remain unchanged under their original tags.

## Verification scope

The attached `RELEASE_VERIFICATION.json` records the exact source revision, final packaged/extracted application checks, dependency records and actual acceptance scope. `SHA256SUMS.txt` identifies the shipped bytes. Consult that record for this release's results; source-level tests and earlier release records do not by themselves verify these final artifacts.

Scene compatibility remains bounded by the pinned engine, imported effects/scripts and system resources. Scene playback in the native screen saver is unsupported. Optional system audio response requires macOS 14.2 or later. A macOS 14 deployment target does not mean every supported OS was tested, and no general 4K, multi-display or physical synchronization guarantee is made.
