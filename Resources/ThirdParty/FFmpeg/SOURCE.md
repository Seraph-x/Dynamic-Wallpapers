# Separate FFmpeg transcoding tool

Version: FFmpeg 9.0.1, official tag `n9.0.1`.

Source: <https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n9.0.1>

`ffmpeg-n9.0.1-source.tar.gz` is the original archive, SHA256:
`195d54bebe1a27f84d77f4b989d193466f305b355da92292766a69f16880b18a`.

No local FFmpeg source patches are applied. Complete original source and per-file copyright notices remain in this archive. This software is based in part on the work of the Independent JPEG Group.

`build.sh` is an unchanged copy of `scripts/feasibility/ffmpeg/build.sh`. From the corresponding application source root:

```sh
python3 scripts/prepare-public-build.py ffmpeg
```

This verifies the pinned archive, configures/builds in a unique staging directory and writes a local build record binding source, recipe, SDK/compiler and actual tool hashes. Existing prepared tools require that matching record; stale or tampered tools are rejected rather than silently rebuilt. The build targets arm64/macOS 14.0, uses Apple clang and the selected SDK, and has only operating-system runtime dependencies.

`BUILD-RECORD.json` contains renewed evidence measured from the current actual prepared executables. Both tool hashes match the verified local record, and actual `ffmpeg -L`, `ffmpeg -buildconf` and corresponding generated `config.h` were checked. `CONFIG_GPL`, `CONFIG_NONFREE`, `CONFIG_VERSION3` and `CONFIG_NETWORK` are all zero; the executable reports LGPL-2.1-or-later. Only prefix and SDK path values in configure options are replaced by named tokens. Hashes of exact raw outputs and generated configuration are retained to make normalization explicit.

The measured SDK/compiler, build-tool versions and exact unsigned-input tool
SHA256 values are recorded in `BUILD-RECORD.json`, including its `tools.ffmpeg`
and `tools.ffprobe` fields. The source/recipe fingerprints identify the inputs
for those precise tool bytes.

Bundle signing is a later explicit transformation and the release manifest records the final signed bytes. These hashes are evidence for this build, not acceptance values imposed on rebuilds with other SDKs or compilers. Retained inputs support source rebuilds; byte-for-byte identity across toolchains is not claimed.

`scripts/verify-current-media.py` reruns owned native and conversion cases and renews public evidence from the verified current build. Packaging verifies that the distributed record matches actual tools. Static FFmpeg libraries belong only to separate command-line executables; the application invokes transcoding in a subprocess. This FFmpeg9 tool is separate from controlled FFmpeg7 libraries used by libmpv.

## Software AV1 and compressed media

The recipe explicitly builds dav1d 1.5.3 and XZ/liblzma 5.8.1 as static
prerequisites, using the unchanged mirrored source archives and original notices
under `MPV/sources` and `MPV/notices`. Meson and Ninja also come from those pinned
sources. No Homebrew runtime library is linked. System zlib/bzlib, VideoToolbox
and AudioToolbox remain explicit configuration options. The LGPL offline tool
configuration does not enable GPL, nonfree, version3 or network features.

The local build record is now schema 2. It binds all codec source archives,
helper/recipe inputs and actual build-tool versions, in addition to FFmpeg source,
SDK/compiler and executable hashes. Existing schema 1 caches are rejected; use
a fresh build cache to rebuild, rather than editing a record to reuse old tools.
The matching exact helper copies are retained under `recipe/scripts` and checked
before packaging. Rebuild from the corresponding application source root, which
retains the scripts and shared source archives at their recorded relative paths.

`acceptance/software-transcode.json` records actual software decoding and
app-equivalent H.264/AAC conversion of AV1 MKV/WebM, H.264 MKV, VP9 WebM,
MPEG-4 AVI and ZMBV AVI. Each case preserves its complete frame count and
checks changing RGBA frames plus decoded PCM audio before and after conversion.
Both AV1 inputs use the actual default libdav1d software decoder with hardware
decoding disabled. The record is bound to the exact tools, fixtures and runner;
packaging rejects a missing, partial, stale or mismatched record.

After preparing all current media products, run the complete byte-bound
acceptance and record update from the corresponding application source root:

```sh
python3 scripts/verify-current-media.py
```

It retains all six conversion cases and all six native mpv cases, refreshes the
material manifest, and rejects any record that differs from the actual current
source, tools, libraries, fixtures or runners. Real media is decoded and audio
is output on the logged-in build host. It never installs or launches Main.

Publication builds use a neutral directory below `/private/tmp`; actual binary
inspection confirms no personal home paths are embedded. Build configuration
output is not patched and executable bytes are not rewritten to disguise paths.
The input mapping and original source archives are retained unchanged.
