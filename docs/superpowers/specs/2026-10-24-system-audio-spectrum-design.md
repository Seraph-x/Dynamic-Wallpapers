# System Audio Spectrum for Scene Wallpapers

## Approved scope

The user approved Core Audio Tap capture on macOS 14.2+, with the rest of the
application retaining macOS 14.0 support. Implement system spectrum first. The
scene editor remains a future independently downloadable/removable plugin; no
editor payload or plugin framework belongs to this change. Keep the published
1.0.0 release unchanged. Use English commits/PRs and the configured real author.

## Capture choice and privacy

Use a private stereo global Core Audio process tap, excluding the application's
audio process, and a private tap-only aggregate device. Do not change the default
output device, mute tapped processes, install a loopback driver, capture a
microphone, persist PCM, or send audio over a network. Native CEF scene audio is
already played by the application's AVAudioEngine, so excluding the host process
also excludes that output. Verify exclusion with real own-process/external tones.

Core Audio Tap better matches this audio-only feature than ScreenCaptureKit's
screen-content permission model. ScreenCaptureKit would preserve 14.0 spectrum
support but requires another capture backend. Do not introduce a silent backend
fallback. On 14.0/14.1 show an explicit 14.2 requirement and disable the control.
Add NSAudioCaptureUsageDescription only to the main application bundle.

## User behavior

Add a persistent, default-off system-audio-response switch and observable status
to the existing General > Sound settings. Old libraries default to off; malformed
present values fail decoding. Spectrum input is independent of wallpaper output
mute and volume. Only playing scenes subscribe; static preparation/thumbnail
generation does not capture. Multiple scenes/displays share one capture owner.
Live previews that are actually playing are eligible under the same switch.

Enabling with no subscriber waits without requesting capture permission. Start
when the first playing scene subscribes; stop when the last one pauses/closes,
the setting is disabled, or the application shuts down. Permission and device
failures clear the spectrum and show an explicit error while scene animation
continues. No simulated spectrum or hidden retry. Offer an explicit Retry control
after a capture error. Device changes are surfaced for explicit restart rather
than silently changing capture semantics.

## Components and data flow

1. A testable PCM analyzer applies a 2048-sample Hann window and FFT, producing
   64 logarithmic frequency bands per channel, bounded to 0...1. It validates the
   format and finite samples, buffers partial packets, and preserves channel
   separation. It runs on the capture serial queue, not the AppKit main thread.
2. A Core Audio driver owns the process tap, aggregate device, IO proc, property
   listeners and latest spectrum. Its callback retains only its independent
   analysis state. Sample data is used synchronously while the callback owns it.
   Start rollback and stop attempt all owned resource releases, preserving and
   reporting any failures. Never report release success before actual cleanup.
3. A MainActor observable controller reconciles the user's enabled intent and a
   set of playing scene IDs. Serialize start/stop transitions and invalidate old
   callbacks by generation. A single 30 Hz timer reads the latest snapshot and
   broadcasts to the currently subscribed pages. Retain failed cleanup owners.
4. The existing CEF application runtime owns the controller and page membership.
   Pause/close removes membership before suspension; successful play ack adds it.
   Failed or retired pages never receive new spectrum data.
5. Each native scene session stores only its latest spectrum behind its existing
   mutex. Add a narrow same-origin trusted-main-frame GET endpoint for that page's
   snapshot, with no-cache response headers. It has no resource path or arbitrary
   JS evaluation parameter. Validate exactly 64 finite values per channel.
6. The trusted scene shell polls the snapshot at 30 Hz with at most one request
   outstanding. WebWallGL's pull AudioSource reads the latest validated snapshot
   at render time. Stop polling on destruction; zero on disabled/paused capture.
   A transport/protocol error uses the existing visible scene failure channel.

    Core Audio PCM -> serial FFT -> shared latest spectrum -> active native pages
    -> per-page local endpoint -> trusted shell -> WebWallGL AudioSource

The endpoint replaces data instead of queueing frame-by-frame command acks, so
slow scenes cannot accumulate stale audio or delay pause commands. Use current
scene identity/generation and the existing origin/resource isolation. Ordinary
web wallpapers and screen savers remain outside this feature.

## Validation

Use failing tests before implementation for FFT tone placement, channel
separation, amplitude response, silence, invalid/partial PCM; setting migration;
single-owner subscription/start/stop/error/retry/shutdown; stale transitions;
native snapshot validation/origin restrictions; JS update/poll/disposal behavior.
Keep deterministic tests separate from permission-dependent macOS integration.

Build the application and test targets. Run relevant Swift suites with a 60 s
test budget after building, scene JS/native tests, packaging and localization
checks. A real Core Audio harness must capture an independently generated tone,
exclude the host's own output, observe no tap/device leaks after repeated cycles,
and feed a self-authored audio-responsive scene through actual CEF rendering.
Do not change the user's wallpaper/library or reset their privacy permissions.
If OS authorization prevents a real check, report that check as unverified.
Perform a final independent code review and inspect the diff before committing.

## Primary API references

- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- https://developer.apple.com/documentation/coreaudio/catapdescription/initstereoglobaltapbutexcludeprocesses%3A
