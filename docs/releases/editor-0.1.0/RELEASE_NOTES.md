# Dynamic Wallpaper Editor 0.1.0

Independent application · Apple Silicon (arm64) · macOS 14.0+ · build 1

## Included authoring

Create/import loose and PKG scenes, edit image/text layers, animate property timelines, undo/redo, save/reopen and export owned resources. Model tools include image-to-puppet meshes, skeleton hierarchy/rest transforms, numeric/painted weights, glTF/GLB conversion, clips, poses, mixing, frame events, FK/IK baking and sparse keys.

The offline Script workspace supplies source-aware API hints, templates, syntax checks, Check/Apply/Revert, resource transactions and retained runtime diagnostics. Supported inline and material/particle resource sources participate in ordinary project history and loose/PKG export. Unsupported bindings/data report an explicit reason. The editing canvas does not execute scripts. Independent Run preview executes the captured revision, with visible diagnostics, pause/restart and live property tests. Optional system audio response needs macOS 14.2+ and is off by default; player media remains empty.

Editor uses its own process, projects, settings, version and CEF dependencies. It does not include mpv or FFmpeg. Main can play exported scenes without Editor installed. File → Open in Dynamic Wallpaper imports a saved owned copy without applying wallpaper automatically.

## Install and remove

Download the Editor ZIP separately and verify `SHA256SUMS.txt`. Move **Dynamic Wallpaper Editor.app** into Applications. It is ad-hoc signed and not Apple-notarized. Removing the app preserves saved projects and Main playback.

[简体中文](INSTALL-zh-Hans.md) · [English](INSTALL-en.md) · [日本語](INSTALL-ja.md) · [Français](INSTALL-fr.md) · [Español](INSTALL-es.md)

The attached `RELEASE_VERIFICATION.json` records the exact source and final package acceptance. The source archive is the corresponding complete tracked repository snapshot, without Git history or local caches. Main is a separate download and is not included in this ZIP.

## Validation limits

The 54-stage source browser/native acceptance uses actual editor interactions, known pixels/resources, undo/save/export, both loose/PKG Main playback and normal CEF shutdown. Final packaged acceptance is separately recorded in the attached verification record. Syntax checking does not prove script runtime success; no step debugger or operating-system process isolation is promised. Compatibility depends on the pinned engine and individual imported assets. The available M1/Metal host does not establish every OS version, 4K or multi-display performance.
