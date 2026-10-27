# FFmpeg software AV1 conversion

This is the remaining toolchain regression in the approved completion scope.
The existing FFmpeg 9 binary fails with exit 69 when decoding actual AV1 on a
machine without hardware AV1 support. Its native AV1 wrapper cannot provide a
software decoder. FFmpeg documents the explicit `--enable-libdav1d` option:
<https://www.ffmpeg.org/ffmpeg-codecs.html#libdav1d>.

Use the already mirrored, unchanged dav1d and XZ sources and pinned source-built
Meson/Ninja. Build static libraries for the offline LGPL tools, and explicitly
enable system zlib/bzlib and static liblzma in the same recipe. The MPV recipe
and its measured binaries remain unchanged. Existing cached FFmpeg tools must
fail the new input verification instead of being silently rebound or reused.

1. [x] Preserve the actual pre-fix AV1 failure and test input/source/tool binding.
2. [x] Build the static codec prerequisites from verified corresponding sources;
   bind all helper/source inputs and actual build tools in a versioned record.
3. [x] Perform actual AV1 MKV/WebM decode and app-equivalent H.264/AAC conversion,
   inspect output streams/pixels/audio, and regress the other recorded formats.
4. [x] Verify LGPL/configuration, system-only Mach-O dependencies, corresponding
   sources/notices, export/package gates, exact diff and publication scan.
5. [ ] Publish an English PR and merge only its tested head.

## Evidence

- The original FFmpeg binary fails actual software AV1 decoding. New input-binding
  tests also failed before implementation because codec helper/source changes
  were not detected and the old record had no versioned codec inputs.
- The actual new source build targets arm64/macOS 14.0 with SDK 27.0. It retains
  LGPL-2.1-or-later and measured GPL/NONFREE/VERSION3/NETWORK flags all zero.
- Two full native conversion runs passed all six input cases. AV1 MKV/WebM,
  H.264 MKV and VP9 WebM each preserve 24 frames; MPEG-4/ZMBV AVI each preserve
  25 frames. Actual changing RGBA pixels and PCM audio are checked on input and
  converted H.264/AAC output. This does not claim lossless H.264 pixel encoding.
- A neutral-path rebuild of the unchanged MPV recipe also passed all six real
  MPVBridge phases, including decoded pixels, CoreAudio time, loop/pause/volume,
  actual renderer/handle destruction and no late callbacks. All 512 decoder
  registrations match the prior measured build. Its refreshed record and native
  captures describe these new bytes, not the old cache.
- Both FFmpeg executables and all 14 rebuilt MPV libraries contain zero personal
  home paths. The first build attempt was explicitly stopped before publication
  after finding embedded personal paths in the old tools; the new artifacts were
  built from source under a neutral temporary directory, not patched afterward.
- Build/acceptance logs remain under ignored `.build/verification/ffmpeg-av1`.
  Retained public JSON is tied to actual tool, source, runner and fixture hashes.
- Final verification passed 121 tooling tests and the complete four-test package
  isolation suite (76.156 seconds). Publication scanning passed all 39 changed
  files and 16 actual binaries. The sole retained source match is an intentional
  `/Users/other` rejection fixture; no pattern is globally allowed.
