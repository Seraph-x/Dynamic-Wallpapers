# Public Music and Spotify media providers

The user approved Music/Spotify public Automation integration, default disabled,
with explicit permission and no generic global source. This is the independently
testable native foundation PR in the approved completion series. Renderer/UI
integration follows in its own PR; no incomplete Main capability is exposed here.

## Contract and ownership

`WallpaperCore.SystemMediaSource` persists disabled/music/spotify in library
settings; absent legacy fields decode disabled, malformed fields fail. The native
`WallpaperMediaIntegration` target depends only on Core, Foundation, AppKit,
Combine and public Apple Event APIs. Immutable snapshots identify their source
and track and contain state, title, artist, album, album artist and seconds-based
position/duration. Artwork and lyrics are explicitly unavailable in this PR;
there are no synthetic images, lookup services or placeholder media items.

`SystemMediaController` owns current source, subscriber demand, status, failure,
snapshot and callbacks. It does no work by default. Selecting a source never
prompts. Only an explicit `authorize()` action may ask for consent. Polling only
runs while the source is enabled and at least one actual scene is playing.
`refresh()` and transport are explicit asynchronous operations. A single ordered
operation chain prevents overlapping permission/query/control work. Source and
demand revisions invalidate old results; disabling synchronously clears the
snapshot. Shutdown stops the timer, rejects new work, waits for in-flight work,
clears data and has an explicit rejected-quit resume operation. The weak-owner
snapshot callback remains installed for a rejected quit and is released with
the controller. Errors
stop automatic work and remain visible until an explicit retry/source change.
App-not-running/no-current-track are ordinary distinct statuses, never failures
converted into fake success. Public APIs cannot find an arbitrary system player.

The service discovers only an already-running Music/Spotify process and creates
an `NSAppleEventDescriptor(processIdentifier:)` target. It never launches apps.
`AEDeterminePermissionToAutomateTarget` runs on a dedicated serial worker;
`askUserIfNeeded` is true only for `authorize`. Reads/transport use explicit finite
Apple Event timeouts and never request UI. Raw public events avoid string/shell
interpolation and OSA runtime initialization. Adapter code is constrained to
known event/property codes and strictly decodes descriptors. Production permits
injected PID resolution for owned integration fixtures without adding a third
user-selectable provider. Poll failures and action failures expose actual errors.

Music and Spotify dictionaries share pTrk/pPlS/pPos and track pnam/pArt/pAlb/pDur;
Music transport event class is hook, Spotify spfy, ids Play/Paus/PlPs/Next/Prev.
Music durations are seconds; Spotify durations are milliseconds despite its
dictionary description. Positions are seconds. No library mutation events are
sent. Only the selected provider is queried and controlled; there is no fallback.

The later Main integration must add NSAppleEventsUsageDescription, localized
purpose text, hardened-runtime entitlement where applicable, localized status/UI,
and the consent explanation that trusted scenes may read/control the selected
player. It must wire the native controller lifetime before enabling the feature.
This PR does not alter Info.plist because it ships no app integration yet.

## Verification

Core settings tests prove disabled legacy default and strict persistence. Typed
descriptor tests cover invalid type/value, Unicode metadata, states, empty track
and the Spotify unit conversion. Controller tests use controllable async service
boundaries for default-off, shared demand, no implicit consent, source changes
during a pending query/control, errors, retry, shutdown and rejected quit.

An owned standalone AppKit fixture responds to real public Apple Events with
two temporary track states and records all received operations. The production
adapter addresses its injected PID, reads metadata and exercises all five
transport commands, then observes forced error/malformed/timeout results and
process exit. A separate harness process and temporary test bundle exercise OS
transport rather than replacing service success. No Music/Spotify is launched,
no personal Music library or preference is read/changed, and no GUI is launched
until the root agent authorizes native execution. Actual vendor-app playback is
not claimed by fixture evidence; final isolated real-app smoke remains explicit.

Primary references: Apple MPNowPlayingInfoCenter describes own-app publishing
(https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter),
public descriptor sendEvent API
(https://developer.apple.com/documentation/foundation/nsappleeventdescriptor/sendevent(options:timeout:)),
permission API and blocking behavior
(https://developer.apple.com/videos/play/wwdc2019/701/), and the installed vendors'
Music/Spotify .sdef dictionaries. Spotify's duration mismatch is documented by a
direct report on its community
(https://community.spotify.com/forum/en/discussion/4537211/issue-with-applescript).
