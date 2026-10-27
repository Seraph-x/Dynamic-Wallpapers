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

`BUILD-RECORD.json` contains renewed evidence measured from the actual prepared executables on 2026-10-27. Both tool hashes match the verified local record, and actual `ffmpeg -L`, `ffmpeg -buildconf` and corresponding generated `config.h` were checked. `CONFIG_GPL`, `CONFIG_NONFREE`, `CONFIG_VERSION3` and `CONFIG_NETWORK` are all zero; the executable reports LGPL-2.1-or-later. Only prefix and SDK path values in configure options are replaced by named tokens. Hashes of exact raw outputs and generated configuration are retained to make normalization explicit.

The measured SDK is 27.0 and compiler is Apple clang 21.0.0. Actual unsigned-input tool SHA256 values are:

- ffmpeg: `8cabde2696f661ab29ce25323c906696b490d68abd326e3b56dc5f494e5c8030`
- ffprobe: `c8ed201f033852ebbc3941bdbfb23644110420b6b700c1d6840d4f4a30d624b9`

Bundle signing is a later explicit transformation and the release manifest records the final signed bytes. These hashes are evidence for this build, not acceptance values imposed on rebuilds with other SDKs or compilers. Retained inputs support source rebuilds; byte-for-byte identity across toolchains is not claimed.

`scripts/export-media-build-records.py ffmpeg` renews public evidence from a verified local build. Packaging verifies that the distributed record matches actual tools. Static FFmpeg libraries belong only to separate command-line executables; the application invokes transcoding in a subprocess. This FFmpeg9 tool is separate from controlled FFmpeg7 libraries used by libmpv.
