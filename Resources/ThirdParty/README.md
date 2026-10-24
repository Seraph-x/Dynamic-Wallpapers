# Third-party dependencies and notices

Local app candidate: DynamicWallpaper 0.3.0/build 3.

This directory retains third-party source references and license materials for source builds and local app candidates. [`distribution-status.json`](distribution-status.json) records each retained file's SHA256 and the completeness of each dependency record. A valid code signature confirms the signed bundle's integrity; it does not verify source provenance, license compliance, or application behavior.

- [CEF](CEF/SOURCE.md): the unmodified `LICENSE.txt` and complete `CREDITS.html` from the pinned official minimal distribution.
- [FFmpeg](FFmpeg/SOURCE.md): original notices, the unmodified n9.0.1 source archive, and a portable build script for the separate transcoding tool. Locally generated configuration is not published.
- [mpv](MPV/SOURCE-STATUS.md): URLs and SHA256 values for the 69 downloaded libraries, a summary of build information extracted from the binaries, the ISC-licensed client headers used in the build, and GPL/LGPL license texts. Raw metadata containing absolute paths is not published.

- [WebWallGL](WebWallGL/README.md): exact npm 3.0.0 engine provenance, the MIT license and the separately retained WeScene MIT notice for its vendored code. WeScene is identified by this engine distribution; no separate upstream revision is claimed.
- [Mediabunny](WebWallGL/README.md): exact npm 1.56.0 distribution/source URL, integrity and original MPL-2.0 notice. The scene bundle includes covered Mediabunny modules and is not entirely MIT. The source remains unmodified; the bundled executable form is produced by the locked esbuild recipe.

The local app candidate uses libmpv and its dependencies from IINA 1.4.0's arm64 library distribution; it does not include the IINA app. These playback libraries were built with GPL features, and their embedded FFmpeg 7.0.1 reports GPL version 3 or later. This is distinct from the separate FFmpeg 9.0.1 transcoding tool, whose previous local build reported LGPL-2.1-or-later terms.

The exact corresponding sources, patches, and copyright notices for all 69 playback libraries have not yet been matched. A new build of the separate FFmpeg tool also requires a fresh configuration and license review. Generic GPL/LGPL texts do not replace each project's copyright notices or establish corresponding-source completeness. These materials therefore do not demonstrate complete compliance for redistributing the mpv binary set or the assembled app.
