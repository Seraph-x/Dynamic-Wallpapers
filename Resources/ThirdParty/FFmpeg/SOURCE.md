# Separate FFmpeg transcoding tool

Version: FFmpeg 9.0.1, official tag `n9.0.1`.

Source: <https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n9.0.1>

`ffmpeg-n9.0.1-source.tar.gz` is the original archive, SHA256:
`195d54bebe1a27f84d77f4b989d193466f305b355da92292766a69f16880b18a`.

On 2026-09-11, all 10,422 source files in the local build tree were checked against the archive: no differences or extra files. No local patches were applied to FFmpeg. Original copyright notices remain in the complete source archive. This software is based in part on the work of the Independent JPEG Group.

`build.sh` is an unchanged copy of `scripts/feasibility/ffmpeg/build.sh`. Run the build entry point from the application source root:

```sh
python3 scripts/prepare-public-build.py ffmpeg
```

The entry point verifies the pinned archive, configures and builds in a separate staging directory, checks the binaries, and writes a local-only build record. It uses Apple clang/clang++, the selected macOS SDK, and make, targeting arm64/macOS 14.0. Configuration and tool output from the earlier machine contain absolute paths and are not in the public source. New build configuration and logs stay in the ignored local build cache. The app bundle verifier checks runtime Mach-O dependencies separately.

`CONFIG_GPL`, `CONFIG_NONFREE`, `CONFIG_VERSION3`, and `CONFIG_NETWORK` are all 0. The previous local build's license check reported LGPL 2.1-or-later; each new build must be checked again. The statically linked FFmpeg libraries are used only by the separate command-line tools; the app invokes transcoding in a subprocess.

Historical output SHA256 values (for audit only, not acceptance values for a new build):

- ffmpeg: `bd2edfcfc32a086c22cd9d98120d7528bf756b0c52904e43020d43726d18acc6`
- ffprobe: `b9167e70d24bcbcd4ff155872dce47ee6fc88f3e758f2fe246366d97c480e7e7`

The source can be rebuilt; a different SDK or compiler is not guaranteed to produce identical binary bytes.
