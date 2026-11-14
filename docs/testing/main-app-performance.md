# Main application resource use

The thumbnail owner caches decoded images with `NSCache` and a 32 MiB cost target.
The cost uses bitmap row bytes when available, otherwise the pixel dimensions of
the already-decoded 32-bit thumbnail. It does not decode or serialize an image to
measure its cost. This is an advisory cache target, not a process-memory limit;
[Apple does not guarantee the eviction count or order](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit).

Visible thumbnail views hold their own image. Loading one thumbnail no longer
publishes a change to every thumbnail view. Views release their image state when
they disappear; returning views reuse a cached image or regenerate it through
the existing loader. Decode and resource-release errors still propagate. Removal
and shutdown evict the corresponding cache entries, including protection against
late decoding results repopulating those entries.

The other-app fullscreen monitor stops its timer and ignores workspace refreshes
while power policy already pauses playback (lock, sleep, inactive session, or an
enabled low-power/thermal pause). It retains the previous fullscreen result and
samples immediately when the final power pause clears, before publishing the
combined playback state. Disabling the fullscreen setting still clears its pause
reason; a sampling error still surfaces without inventing a resume.

## Reproduce the focused checks

After preparing the repository's media dependencies, build tests separately so
that cold compilation does not consume the 60-second targeted test budget:

```sh
python3 scripts/swift_sdk.py build --build-tests --disable-sandbox
python3 scripts/test.py --skip-build --filter 'ThumbnailLifetimeTests|ApplicationLifecycleControllerTests|OtherAppFullScreenTests|ManagedMediaLifecycleTests|ApplicationCompositionTests|MediaTests|InspectorMediaModelTests|UISnapshotTests/testRealLibraryWindowRenders'
```

The GUI checks require a logged-in macOS session. The workload test creates 160
real 480 × 270 RGBA thumbnails, checks that they remain loadable, and prints
`THUMBNAIL_CACHE_WORKLOAD` with the retained image count and pixel bytes. It does
not assert a particular eviction order or count. Tests also cover cache hits,
failed decoding/retry, media removal, shutdown, late results, suspended timer and
workspace events, settings changes, immediate resume checks, and sampling errors.

## Recorded comparison, 2026-11-14

On macOS 27.2.1 with SDK 27.2, a debug run of the two focused suites
(`ThumbnailLifetimeTests|ApplicationLifecycleControllerTests`) produced:

| 160-thumbnail workload | Before | After |
| --- | ---: | ---: |
| Images retained by cache | 160 | 64 |
| Retained pixel bytes | 82,944,000 | 33,177,600 |
| Retained pixel MiB | 79.1 | 31.6 |

This run reduced cached pixel storage by 60%. These numbers exclude visible-view
ownership, framework allocations, and renderer/video memory; they are not RSS or
whole-application CPU/GPU measurements. Mixed GUI-suite runs can retain fewer
cached images because `NSCache` eviction is adaptive.

The pre-change tests reproduced retained shutdown images, late cache repopulation,
continued power-paused scans, and missing immediate fullscreen resampling. After
the change, all 14 tests in the initial comparison passed. Additional tests cover
real timer suspension, settings changes, resume errors, and late removal results.
The final expanded run passed all 53 tests, including the real library-window
rendering check; its library screenshot also showed the loaded grid and inspector
thumbnails. `git diff --check` passed. Logs are retained locally under
`.build/verification/main-app-performance-20261114/`.

For this validation the build used an isolated temporary SwiftPM scratch/cache
directory and `--build-system native` (deprecated by this toolchain). The first
combined cold-build/test attempt reached the existing 60-second timeout; a
separate cold build completed in 124.84 seconds. Subsequent targeted runs retain
the repository's 60-second timeout. The retained local mpv libraries and headers
were checked against their build-record hashes before restoring their expected
ignored build-directory link. This is source/test validation, not a newly
packaged or installed release.
