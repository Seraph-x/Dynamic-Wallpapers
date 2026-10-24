# Dynamic Wallpaper 1.0.0

Apple Silicon (arm64) · macOS 14.0 or later · build 4

## What is included

- Local videos, animations, images, HTML web projects and Wallpaper Engine loose JSON/PKG scene projects.
- Offline WebWallGL/CEF scene rendering with retained pause/resume, per-item audio controls, fit, frame-rate and opt-in mouse interaction.
- Playlists, transitions, independent/synchronized displays, linked preview, menu-bar controls, optional still system wallpaper synchronization and eligible video transcoding.
- Native screen-saver publication for supported native media; web, scene and extended-player media are excluded.
- Updated README and five-language offline help, including scene import steps, audio/timing behavior and data/upgrade guidance.

## Install and upgrade

Use the DMG or ZIP from this release. Both contain an ad-hoc-signed app; this build is not Apple-notarized. Check `SHA256SUMS.txt` before installation. Intel Macs are not supported by these artifacts.

[简体中文](INSTALL-zh-Hans.md) · [English](INSTALL-en.md) · [日本語](INSTALL-ja.md) · [Français](INSTALL-fr.md) · [Español](INSTALL-es.md)

Quit the old app before replacing it. Preserve a separate copy of the library data if you need to downgrade: this version saves library schema 4, which older builds may reject. Installation does not erase imported media.

## Compatibility and validation limits

Scene compatibility depends on the pinned WebWallGL engine and individual project features. Author defaults are used. System audio spectrum capture, property/scene editors and scene screen-saver playback are outside this release. Import only projects you trust.

Validation covers Apple M1/ANGLE Metal on the available macOS/Swift SDK host; the macOS 14 deployment target is not evidence of testing every supported OS. Scene checks exercise actual loose/PKG rendered pixels, pause/resume, mouse response and resource release. Gain tests invoke the native API; the authored fixtures have no PCM soundtrack. 4K/multi-display performance is not characterized. See [scene validation](../../testing/scene-wallpapers.md) for the existing GUI baseline failures and scope.

The app retains third-party notices and source records. The mpv corresponding-source/per-library notice inventory and each local FFmpeg build’s distribution review remain incomplete, as recorded in `Resources/ThirdParty/distribution-status.json`; this release does not claim that those issues are resolved.
