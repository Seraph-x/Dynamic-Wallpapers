# Dynamic Wallpaper 1.1.0

Apple Silicon (arm64) · macOS 14.0 or later · build 5

## Included behavior

- Local media, web and loose/PKG scene playback, playlists, independent or synchronized displays, linked previews and optional native screen saver for supported media.
- Persistent per-wallpaper scene properties with typed validation, author defaults, reset and acknowledged live updates. The original project stays unchanged.
- Optional shared system audio response for playing scenes on macOS 14.2+, off by default. No microphone, saved recording or upload; wallpaper output mute is independent.
- Default-off Music/Spotify integration for trusted playing scenes. Choose one already-running player, then explicitly request Automation access. Actual metadata/artwork and five transport commands use the current scene/source identity. Pause, disable, close and shutdown clear data and revoke controls. Provider and artwork errors have separate visible retry actions. Lyrics, derived colors, other players and global Now Playing are unavailable.
- A menu-bar entry for the separately installed Editor 0.1.0. Neither app installs or requires the other. Editor previews do not receive system-player media.
- Complete controlled media source, patch, notice and measured build records, a 14-library runtime closure and software AV1 conversion fixes. Historical IINA binaries are not current runtime inputs.
- Current five-language offline help and installation/removal instructions.

## Install, upgrade and remove

Use the DMG or ZIP and verify `SHA256SUMS.txt`. Both contain an ad-hoc-signed application; it is not Apple-notarized. Intel Macs are not supported by these artifacts.

[简体中文](INSTALL-zh-Hans.md) · [English](INSTALL-en.md) · [日本語](INSTALL-ja.md) · [Français](INSTALL-fr.md) · [Español](INSTALL-es.md)

Quit an old copy normally before replacing it. Imported media remains separate. This release continues library schema 4; older apps can reject newer fields or unsupported data. Keep a separate library copy before upgrading if rollback is required. The backup-and-clear action also clears the active library. Removing Main preserves Editor and its projects; remove the optional installed screen saver separately.

## Evidence and limits

The attached `RELEASE_VERIFICATION.json` records the exact merged source revision, final packaged/extracted application checks, controlled dependency records and actual acceptance scope. `SHA256SUMS.txt` identifies the shipped bytes; the source archive is the exact tracked snapshot without Git history or local build caches. Signing and source/notices are separate facts.

Source/runtime validation passed 54 complete Editor browser/native stages, actual Main CEF metadata/artwork/control/clear/shutdown checks, owned Apple Events/TLS consent checks, 199 isolated media/Core/owner tests, 464 Editor JavaScript tests and packaging gates. Owned player fixtures do not establish vendor-app playback: Music and Spotify were not running, so live vendor playback remains unverified.

The complete Swift suite was attempted and failed. Missing authored media fixtures were restored and affected media/TLS, real audio and screen-saver reruns passed; unrelated inspector UI and actual 30/60 Hz capture-cadence assertions remained failed. This release does not claim a passing complete suite or guaranteed measured 60 Hz capture. Scene compatibility remains limited by the pinned WebWallGL engine, individual effects/scripts and available system resources. Scene screen-saver playback is unsupported.

Validation uses the available Apple M1/Metal host. The macOS 14 deployment target does not prove every supported OS was tested. 4K, multi-display performance and physical acoustic/display synchronization are not characterized.
