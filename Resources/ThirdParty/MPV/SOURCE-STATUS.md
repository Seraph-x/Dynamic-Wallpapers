# libmpv and 69-library source status

These dylibs come from IINA's official `https://iina.io/dylibs/1.4.0/arm64/` release directory. `binary-manifest.json` locks each downloaded file's URL, SHA256, arm64 architecture, and minimum system version. The original binaries total 54,517,360 bytes. Packaging changes only the library search paths in copied files and re-signs those copies ad hoc; the original cached bytes are unchanged.

The pinned provenance is IINA v1.4.0's official README description of its prebuilt libraries: <https://raw.githubusercontent.com/iina/iina/v1.4.0/README.md>. The IINA app source or copyright files from an installed app of another version are not treated as corresponding materials for these libraries.

Confirmed from the actual binaries:

- libmpv reports runtime version v0.38.0, a build prefix containing `mpv-iina/HEAD-c0dd2b3`, and the `gpl` feature.
- Embedded FFmpeg has a build prefix of `ffmpeg-iina/7.0.1` and enables `--enable-gpl --enable-version3`.
- libavcodec contains the license string `GPL version 3 or later`.
- These identifiers and features were read from the binaries. Raw metadata containing upstream build-machine absolute paths is not in the public source. A reported runtime version does not prove that the source is identical to an unpatched upstream release.

`client.h` and `render.h` are pinned mpv v0.38.0 client headers retaining their ISC copyright and license. The GPL/LGPL texts are standard texts from the bundled FFmpeg n9.0.1 source. They are not a complete collection of copyright notices for every dylib.

Still unresolved: exact corresponding source versions, IINA/Homebrew patches, build inputs, and copyright texts for each of the 69 libraries. Checks on 2026-09-11 returned HTTP 404 for `https://raw.githubusercontent.com/iina/mpv/c0dd2b3/Copyright` and `https://codeload.github.com/iina/mpv/tar.gz/c0dd2b3`. The current tap formula points to a later `iina-release/1.5.0` and cannot be treated as the recipe for these 1.4.0 binaries.

This record therefore remains explicitly incomplete. It does not claim that corresponding source, all copyright notices, or materials for third-party binary redistribution are complete.
