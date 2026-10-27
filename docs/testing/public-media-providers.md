# Public media provider foundation

The native `WallpaperMediaIntegration` module supports explicitly selected,
already-running Music and Spotify applications through their public Apple Event
dictionaries. It does not read an arbitrary system-wide Now Playing source,
launch a player, mutate a music library, use private MediaRemote APIs or fall back
to a wallpaper's own audio. `MPNowPlayingInfoCenter` publishes the calling app's
media; it is not a global reader.

This foundation PR adds the module and strict default-off source persistence.
Main settings, consent copy and renderer delivery belong to the dependent
integration PR. A built library alone does not make scene media integration
available in the app. Artwork/lyrics are explicitly absent from this native
foundation; consumers must not synthesize them. The final integration may extend
the native contract with actual available artwork. Lyrics have no supported
public source in this provider scope.

## Consumer contract

`WallpaperCore.SystemMediaSource` has `disabled`, `music`, `spotify`. Legacy
settings without `systemMediaSource` decode disabled; malformed/unknown sources
fail decoding. The controller begins disabled and construction performs no OS
query. The owner configures a source, provides actual playing scene demand via
`setPlaying(id, true/false)` and connects `onSnapshot` with a weak owner capture.
Multiple playing scenes share one query stream. The default polling interval is
one second. A slow read cannot accumulate another read for the same revision.

`configure(source:)`, `refresh()` and automatic polling never request consent.
Only the explicit async `authorize()` user action passes `askUserIfNeeded=true`
to `AEDeterminePermissionToAutomateTarget`. Repeated authorization clicks during
one pending request do not queue more prompts. A missing application, required
permission, denied permission and no current item have distinct statuses.
Permission failures and actual read/action errors stop automatic work until an
explicit retry/authorize/source change. `failure` carries actual errors; a
failed `perform` also throws to its caller.

`SystemMediaSnapshot` is immutable and records source, stable provider track ID,
playback state, title, artist, album, optional album artist, position and duration
in seconds. Spotify does not expose album artist in its public dictionary, so
it is nil. Music seeking states remain explicit; `wallpaperPlaybackState` maps
playing/fast-forward/rewind to 1, stopped to 0 and paused to 2. Music duration is
seconds; Spotify duration is milliseconds even though its dictionary says
seconds. Unicode strings are not JSON/shell-interpolated.

The adapter reads one returned track object and verifies current track identity
again after reading timeline data. A track change during the read is an explicit
`trackChangedDuringRead` failure, requiring retry, rather than a mixed snapshot.
Each blocking Apple Event has a three-second default response timeout; no
unbounded transport retry is performed. The service runs descriptors and the
potentially blocking permission request on one serial background worker.

`shutdown()` clears demand/data, stops polling, invalidates old results and drains
dispatched operations. Concurrent shutdown callers await the same task.
`cancelShutdown()` resumes only after that drain finished and requires fresh
scene demand. The snapshot callback remains installed for a vetoed quit; its
weak owner capture prevents a cycle and it is released with the controller.
Neither an already-dispatched Apple Event nor an OS consent dialog can be
recalled. Source changes/disabling prevent queued old-source controls and prevent
old replies from publishing data; they do not claim to undo a dispatched action.

Before Main exposes the setting, its bundle must include localized
`NSAppleEventsUsageDescription`, the Apple Events entitlement when using Hardened
Runtime, localized unavailable/error/authorization UI and a consent explanation
that trusted scenes can read and control the chosen player. This foundation
does not change the production app's TCC declaration because it is not yet wired.

## Reproducible tests

Build separately from execution:

```sh
python3 scripts/test-public-media.py --build-only
python3 scripts/test-public-media.py --run-only
```

The runner constructs an isolated SwiftPM package using the checkout's actual
Core/native sources and tests. This excludes CEF/mpv and does not run Main or
Editor. It uses the selected SDK, a separate 180-second cold-build phase and a
60-second test-execution phase. The generated package, signed owned test bundles
and `results.json` are under `.build/verification/public-media`.

Unit coverage includes strict source persistence, Unicode/numeric descriptor
decoding, Spotify unit normalization, disabled/missing-app service behavior,
shared scene demand, no implicit prompts, stale source results, control ordering,
failure/retry, duplicate authorization, timer disposal and shutdown/quit races.

For actual OS transport acceptance, reserve the native GUI execution slot and
run outside the development sandbox (AppKit registration is unavailable there):

```sh
python3 scripts/test-public-media.py --run-only --automation --authorize-owned-fixture
```

`--automation` launches only the authored `MediaAutomationFixture.app` and
`MediaAutomationClient.app`. The additional explicit authorization flag may ask
for consent **only for that owned fixture**. It never targets Music/Spotify,
changes their preferences, or accesses their libraries. Omitting the flag tests
without requesting permission and reports a real denial if permission is absent.

The fixture answers the actual public property/event codes for each dictionary
and rejects the other dictionary's transport/identity codes. The production
`AppleEventMediaService`, with only its running-PID resolver injected, sends real
OS Apple Events to that separate process. The client checks actual metadata,
Unicode, duration units, five ordered controls and corresponding state/identity
changes, no-current-item, malformed data, explicit -50 errors, identity changes,
an actual -1712 timeout, a -1708 control rejection and the exited target process.
It checks the fixture's recorded receipts rather than treating a command's return
as proof that transport ran. This is a labeled test fixture, never a product path.

LaunchServices starts the client as its signed app so TCC can identify its bundle
and usage description. A direct child executable inherits the development host's
responsibility chain and may receive a denial. The runner checks the client's
atomic result file and actual PID exit, not `open`'s launch status as a proxy for
test success. It deliberately avoids `open -W`, which can fail installing its
kevent after a fast client has already exited. Fixture processes are terminated
and waited for on both success/failure; no test player remains running.

Fixture evidence proves actual public OS transport and adapter contracts. It
does not claim a live vendor-app playback test. Such acceptance must run in a
separate macOS user/VM or an explicitly chosen disposable Music library, without
touching the user's existing media/library preferences.

## Primary references

- [MPNowPlayingInfoCenter publishes own-app media](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter).
- [Public descriptor sendEvent API](https://developer.apple.com/documentation/foundation/nsappleeventdescriptor/sendevent%28options%3Atimeout%3A%29).
- [Apple Automation consent and blocking behavior](https://developer.apple.com/videos/play/wwdc2019/701/).
- [Apple Events hardened-runtime entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
- Installed vendor dictionaries: Music's `Contents/Resources/com.apple.Music.sdef`
  and Spotify's `Contents/Resources/Spotify.sdef`. No vendor application must be
  launched to inspect those public interface declarations.
- [Direct Spotify duration-mismatch report](https://community.spotify.com/forum/en/discussion/4537211/issue-with-applescript).
- [Apple's separate Music library instructions](https://support.apple.com/en-ph/guide/music/mus7663a920a/mac).
