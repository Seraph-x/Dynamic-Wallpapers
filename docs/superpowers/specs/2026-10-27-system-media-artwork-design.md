# Actual public-provider album artwork

This extends the verified native foundation at Main `7d706d9`; the user already
approved the complete Music/Spotify public Automation scope. No Main/CEF/UI or
shared renderer code changes in this PR. Metadata and transport stay valid when
artwork is absent, pending or failed. There are no generated covers, guessed
search results, fake colors, lyrics, private APIs or player/library mutations.

## Public sources and immutable contract

Music's installed dictionary declares track artwork elements (`cArt`) and raw
artwork bytes (`pRaw`). Read raw data of the first artwork of the stable current
track object through public `core/getd`; a genuinely missing first artwork is
unavailable, while other Apple Event failures are visible artwork failures.
Spotify declares `artwork url` (`aUrl`); the deprecated `tAwk` field explicitly
never returns data and must not be used. Empty/missing artwork is unavailable.
Track identity is checked before and after source extraction against the actual
metadata snapshot. Inconsistent or stale artwork never attaches to another item.

Add `SystemMediaArtworkIdentity` (provider + track ID), an immutable source enum
(`unavailable`, embedded `Data`, validated HTTPS URL), an immutable decoded
artifact (identity + actual PNG bytes + dimensions), and a separate published
artwork state (`unavailable`, `pending(identity)`, `ready(artifact)`,
`failed(identity,error)`). Typed errors preserve provider/network/decode causes.
No artwork error replaces a valid metadata snapshot or stops media transport.
The original native playback state continues to expose fast-forward/rewind;
the existing wallpaper 0/1/2 projection remains explicitly documented as coarse.

## Source, network and lifetime ownership

Extend the production Apple Events service with a separate artwork-source
protocol so existing metadata-only services/tests do not invent artwork. A small
`SystemMediaArtworkController` owns this independent pipeline, and the metadata
controller forwards real snapshot changes and awaits artwork shutdown. It has
its own identity/generation and a cancellable load task. A new item, disabled
source, lost demand or shutdown synchronously clears the previous artwork and
cancels old work. Late OS/network/decode completions cannot publish. Shutdown
drains cancellation and releases ephemeral sessions; a rejected quit accepts
fresh demand. Artwork failures require explicit retry; genuinely unavailable
artwork can be re-probed on later metadata refreshes. Ready artwork is cached
only for the current provider/track identity, avoiding repeated large reads.

The loader uses an ephemeral `URLSession`, no persistent URL cache/cookies,
HTTPS-only initial requests and every redirect, no URL credentials, normal
system TLS validation, explicit non-2xx failures and a finite request timeout.
No arbitrary encoded-byte or decoded-pixel caps are introduced. ImageIO validates
actual image dimensions and decoding failures are explicit artwork errors. The
provider and platform retain their actual resource limits; artwork failures
retain valid metadata.

ImageIO validates the actual encoded image and normalizes its real pixels and
orientation to PNG, preserving the source library bytes. Normalization makes
Music TIFF/JPEG/etc usable in the later Chromium consumer without silently
substituting imagery. No palette/color data is fabricated in this native PR.

## Tests and truthful evidence

Keep all 20 native and 130 Core foundation regressions. Add failing-first tests
for source decoding, missing artwork, strict HTTPS/credentials/redirects, HTTP
errors, invalid images, real PNG pixels/dimensions, metadata
surviving artwork failures, duplicate fetch avoidance, explicit retry, stale
track/source results, cancellation, shutdown and rejected-quit resume.

Extend the owned Apple Event fixture to provide an authored PNG through Music's
actual raw-data object path and Spotify's actual URL field. A local HTTPS server
serves that same PNG plus redirect/error/slow cases. It uses an ephemeral test CA
and server certificate in the test directory. An internal test-only initializer
supplies that exact CA/hostname to a per-task trust evaluator using Security's
normal trust evaluation; no verification is disabled, no global Keychain trust
is changed and production public initialization always uses system trust.
This exercises the real production redirect/data/decode path over actual TLS,
not a URLProtocol fake response. Untrusted/wrong-host certificates must fail.

The real OS client uses the production PID adapter to extract both artwork
sources, downloads/decodes the actual fixture PNG, verifies its known bytes and
pixels and observes errors/stale cancellation/shutdown. It never launches Music
or Spotify or reads/changes personal libraries/preferences. Build separately
(180 seconds), execute targeted tests/actual phases within their 60-second
budgets, and reserve the GUI/native slot before starting fixture/server. Real
vendor-app playback remains a separately labeled isolated smoke requirement.

## Primary references

- Installed vendor `com.apple.Music.sdef` and `Spotify.sdef` publicly declare
  `cArt/pRaw` and `aUrl` respectively; no vendor process was launched to read them.
- [Apple redirect delegate: explicit acceptance/refusal in ephemeral sessions](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession%28_%3Atask%3Awillperformhttpredirection%3Anewrequest%3Acompletionhandler%3A%29).
- [ImageIO image property inspection](https://developer.apple.com/documentation/imageio/cgimagesourcecopyproperties%28_%3A_%3A%29).
- [ImageIO actual image decoding](https://developer.apple.com/documentation/imageio/cgimagesourcecreateimageatindex%28_%3A_%3A%29).

- [Per-session explicit trust anchors](https://developer.apple.com/documentation/security/sectrustsetanchorcertificatesonly%28_%3A_%3A%29).
- [URLSession delegate invalidation releases its callback references](https://developer.apple.com/documentation/foundation/urlsession/invalidateandcancel%28%29).
