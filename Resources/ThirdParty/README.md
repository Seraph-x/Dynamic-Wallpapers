# Third-party dependencies and notices

Local app candidate: DynamicWallpaper 1.0.0/build 4.

This directory retains third-party source references and license materials for source builds and local app candidates. [`distribution-status.json`](distribution-status.json) records each retained file's SHA256 and the completeness of each dependency record. A valid code signature confirms the signed bundle's integrity; it does not verify source provenance, license compliance, or application behavior.

- [CEF](CEF/SOURCE.md): the unmodified `LICENSE.txt` and complete `CREDITS.html` from the pinned official minimal distribution.
- [FFmpeg](FFmpeg/SOURCE.md): original notices, the unmodified n9.0.1 source archive, the portable recipe and renewed actual tool/source/SDK/license/configuration evidence for the separate transcoding tools. Machine paths use explicitly documented tokens in the public record.
- [mpv](MPV/SOURCE-STATUS.md): the recovered exact 0.38.0+18 tree, pinned complete source closure and original notices, exact 18-commit patch, executable recipes, actual 14-library build record, codec API comparison and six product-bridge native acceptance records with real pixels and input fixtures. The old IINA 69-library metadata is historical only; those binaries are not used or distributed.

- [WebWallGL](WebWallGL/README.md): exact npm 3.0.0 engine provenance, the MIT license and the separately retained WeScene MIT notice for its vendored code. WeScene is identified by this engine distribution; no separate upstream revision is claimed.
- [Mediabunny](WebWallGL/README.md): exact npm 1.56.0 distribution/source URL, integrity and original MPL-2.0 notice. The scene bundle includes covered Mediabunny modules and is not entirely MIT. The source remains unmodified; the bundled executable form is produced by the locked esbuild recipe.

The playback runtime is built from controlled source for arm64/macOS 14.0. The app uses libmpv's software render API, CoreAudio, VideoToolbox-copy and local MKV/WebM/AVI demuxing. mpv uses its GPL-enabled build; its newly built FFmpeg7 libraries report LGPL-2.1-or-later. The separate FFmpeg9 transcoding executables have their own measured LGPL-2.1-or-later record. Each dependency retains its original license; the application source is provided separately under its project license.

The old IINA closure's remaining provenance gaps are not claimed resolved. That unproven binary closure was replaced. Generic license texts are supplemented by complete original source archives and each project's original copyright/license notices. Source/material completeness and application/release functional acceptance are separate records; valid signatures alone do not prove either.
