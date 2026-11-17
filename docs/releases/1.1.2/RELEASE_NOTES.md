# Dynamic Wallpaper 1.1.2

Apple Silicon (arm64) · macOS 14.0 or later · build 7

## Changes

Fix the **Open System Settings** button under **Screen Saver → System Installation** displaying Chinese when another app language is selected. The button already used the app's localizer, but its translation entry was missing. Add the entry for English, Simplified Chinese, Japanese, French and Spanish, and include it in the existing screen saver localization coverage.

## Installation

Download the DMG or ZIP from [v1.1.2](https://github.com/Seraph-x/Dynamic-Wallpapers/releases/tag/v1.1.2) and compare it with `SHA256SUMS.txt`. Quit the previous copy before replacing **Dynamic Wallpaper.app** in Applications. The app is ad-hoc signed and not Apple-notarized.

[简体中文](INSTALL-zh-Hans.md) · [English](INSTALL-en.md) · [日本語](INSTALL-ja.md) · [Français](INSTALL-fr.md) · [Español](INSTALL-es.md)

## Verification scope

This is a localization-only patch. Release validation covers compilation, packaging, bundled translations, code signatures, ZIP extraction and the read-only mounted DMG. The full regression suite and runtime acceptance were not run for this patch. The initial targeted localization test attempt exceeded its 60-second build budget before tests ran.

`RELEASE_VERIFICATION.json` records the source revision and completed artifact checks. `SHA256SUMS.txt` identifies the shipped files.
