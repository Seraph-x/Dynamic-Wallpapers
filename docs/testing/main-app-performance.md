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

## Six-stage follow-up: 1. Shared thumbnail requests

Same-source concurrent consumers now share one decode. Source metadata participates in cache validity; name/favorite edits do not. The last subscriber cancels the decode, while deletion and shutdown still await actual cleanup and retain release failures.

Validation: 31 thumbnail/inspector/managed-media tests passed. Regression evidence includes overlap (2 callers → 1 decode), independent cancellation, late old-source completion, and one release-error notification with both removal/shutdown still failing. Logs: `.build/verification/main-performance-six/1-{red,green}.log`. No whole-process CPU/RSS improvement is inferred from these counts.

## Six-stage follow-up: 2. Audio edit sessions

Volume samples now update the matching playback endpoints and inspector preview without library serialization/reconciliation. Slider completion, target changes, native panel close, other library mutations and application shutdown flush the draft. The captured media identity prevents a late draft from changing a replacement wallpaper. Failed saves remain visible, retain the draft, and prevent successful shutdown until retried. Reconciliation reapplies the active transient value.

Validation: 67 audio/app-model/lifecycle tests passed in 15.288 seconds after a separate build. A 100-sample workload applies 100 player updates with zero intermediate writes and exactly one final commit. Integration checks assert unchanged disk bytes during the drag, final persistence on shutdown, save-failure retry, actual AVPlayer volume changes without replacement, and reentrant native panel closing. Two combined build/test attempts exceeded the 60-second budget; the final --skip-build run passed. Evidence: `.build/verification/main-performance-six/2-{red,build,build-timeout,green}.log`. Physical mouse dragging was not automated; SwiftUI editing completion/identity wiring was reviewed.

## Six-stage follow-up: 3. Library indexes and filter reuse

Validation builds a media lookup and per-playlist entry ID sets after duplicate checks. Entry validation no longer rescans the media array. Display progress still has to belong to its own playlist. The grid shares one filtered collection per view build; inspector visibility checks only the selected item with the same predicate.

Validation: 162 core/selection/batch tests passed. In the same debug configuration, the fixed 5000-media / 10000-entry / 100-display validation workload took 9.450926625 s before and 0.024351333 s after. These are single-run validation timings, not application startup or whole-process measurements. Evidence: `.build/verification/main-performance-six/3-{before,build,after}.log`.

## Six-stage follow-up: 4. Released mpv frame storage

The software renderer now obtains a shared pixel lease. NSData and its downstream consumers own the lease; delivery acknowledgement does not release it. The last consumer can return a buffer on any queue. One idle allocation is kept for the next render; resize and shutdown release unused storage while outstanding frames remain valid. This does not change videotoolbox-copy decoding or switch to a GPU renderer.

Validation: ASan/UBSan native ownership/resize/cross-thread/shutdown harness passed, measuring 2 pixel allocations for 1001 fixed-size producer frames (previous render code allocated per frame). The real libmpv pending-frame failure-drain test passed. 21 Swift bridge/routing/playback tests passed across MKV, WebM and AVI, including a retained frame checked through 20 real callbacks and close. Evidence: `.build/verification/main-performance-six/4-{pool,drain,build,swift}.log`. The stricter controlled-source acceptance wrapper refused to run because the retained dependency build record describes a different toolchain environment; its record was not modified (`4-native.log`). This limits provenance revalidation, not the passing real playback/ownership checks.

## Six-stage follow-up: 5. Web and scene frame damage

CEF dirty rectangles now reach a damage-aware pixel owner. Each allocation accumulates changes missed while consumers retained it, then copies those pixels directly from the complete current CEF bitmap. First use and geometry changes require full initialization. CGDataProvider owns the resulting immutable lease without an additional CFData base-frame copy. Native/GPU renderer selection is unchanged.

Validation: ASan/UBSan tests cover moving/unchanged damage, invalid input, retained frames, resize-away-and-back, cross-thread release and shutdown. A fixed 1001-frame 128×128 workload with an 8×8 update copied 386816 bytes, including initial complete frames, compared with 65601536 bytes for the previous full-copy path; two pixel allocations. This is a partial-damage workload, not a claim that fullscreen WebGL animations copy less when CEF marks the entire frame dirty.

Actual WebPage CGImage retention tests passed, including comparing all pixels after subsequent paints and close. Real CEF page/frame/lifecycle checks passed with two sequential pages and cancellation; real loose/package Scene protocol, pixels, controls and strict shutdown passed. Main app build passed. Logs: `.build/verification/main-performance-six/5-{storage,runtime,scene,build}.log`; detailed page state run `web-page-state/F168F7DD-669C-4117-B61F-0F3AEFFCC3EF`, CEF run `web-runtime/d441c92f-6acc-4293-a0d2-1dea3b87a3d1`, Scene run `scene-native/89aacd7c-0421-40da-9ce9-fd3209488d1c` under `.build/verification/`.
