# System media artwork implementation plan

> Execute the approved extension using TDD, isolated worktree, review and verification-before-completion. The user authorized verified English PRs and merging.

**Goal:** Supply actual available Music/Spotify album artwork without invalidating metadata or silently substituting imagery.

**Architecture:** Separate immutable artwork state, public Apple Event source extraction, HTTPS/ImageIO loader and identity-bound controller; Main/CEF integration follows separately.

**Tech stack:** Swift, public Carbon Apple Events, Foundation URLSession, ImageIO/CoreGraphics/Security, XCTest, owned PNG/TLS fixture.

## 1. Typed sources and actual native extraction

Files: new `SystemMediaArtwork.swift`, source protocol; minimal `MediaAppleEventCodes.swift`, `MediaAppleEventAdapter.swift`, `AppleEventMediaService.swift` extension; decoder/source tests.

- [x] Add and observe failing tests for immutable identity/source, HTTPS input and actual missing/malformed/raw-data/URL fields.
- [x] Implement Music first-artwork raw data and Spotify aUrl with identity checks; keep all failures separate from metadata.
- [x] Run targeted tests and existing native/Core regressions after separate cold build.

## 2. Actual HTTPS loading and image validation

Files: new `HTTPSArtworkLoader.swift`, `ArtworkImageDecoder.swift`, dedicated network/decode tests and test TLS helper.

- [x] Write failing tests for real PNG dimensions/pixels, MIME/orientation normalization, invalid data and explicit ImageIO errors.
- [x] Implement ephemeral no-cookie/cache HTTPS loading, every-redirect validation, observable HTTP/TLS/network errors, real image decode/PNG normalization without arbitrary byte/pixel caps.
- [x] Implement strictly internal fixture CA/hostname trust injection without changing production system trust or any Keychain.
- [x] Verify valid TLS, downgrade/credential redirects, wrong certificate/host, status/error/cancellation over the owned server.

## 3. Independent artwork state and generation lifecycle

Files: new `SystemMediaArtworkController.swift`; minimal integration with `SystemMediaController`; artwork lifecycle tests.

- [x] Add meaningful red tests for pending/ready/unavailable/failed states preserving metadata, one load/current identity, retry, stale source/track completion and shutdown.
- [x] Implement task cancellation, immediate clear, identity revisions, explicit failure retry and shared metadata forwarding without blocking transport on network/image decode.
- [x] Verify queued metadata operations, old artwork tasks, timer/deinit and rejected quit all retain the foundation semantics.

## 4. Real owned native acceptance and documentation

Files: `Tests/MediaAutomationHarness` extension, owned TLS server fixture and `scripts/test-public-media.py`/`run-media-automation.py` updates; API/testing docs.

- [x] Build owned authored PNG/source responses and TLS server/error cases, then request root's native execution slot.
- [x] Run actual production Apple Events source extraction + real TLS image fetch/decode/pixel checks, errors, identity changes and cancellation/shutdown; confirm all owned processes exit.
- [x] Run the complete native/Core regression suites, static/package checks and changed-source privacy gate.
- [x] Update docs with exact supported artwork, explicit failures/limits, source retention and coarse playback projection.
- [x] Resolve the root review's queued cancellation finding and verify the final tested sources before publishing.

## Verification record

- API tests first exposed missing artwork symbols; source/loader/controller APIs
  were then implemented. Runtime failing-first regressions additionally caught
  an incorrect raw-format allowlist and premature artwork shutdown resume.
- Owned actual acceptance passed both dictionary adapters without an authorization
  flag or vendor-app launch. It verified exact raw bytes/URL, authored PNG pixels,
  explicit artwork errors, retained metadata/control, stale cancellation, drain
  and rejected-quit recovery. The GUI lease was released after process cleanup.
- Original 20 native and 130 Core tests remain; new tests cover actual ImageIO,
  ephemeral TLS with an exact internal CA/hostname, cancellation and lifetime.
- Loopback tests require unsandboxed execution because the sandbox denies local
  socket binding; this is explicit and no fake network path is supplied.
- Artifacts, per-run certificates and logs live under ignored
  `.build/verification/public-media`; no credentials or source library changes.
- The review regression first failed twice on a real blocked serial queue:
  cancelled work entered the resolver and returned application-not-running.
  Task cancellation now crosses the queue boundary before native work starts;
  a started OS request is still drained rather than reported as aborted.
- Integrating the current Core tests exposed missing fixture paths in isolated
  SwiftPM builds. Their fixture lookup now resolves source symlinks, retaining
  the actual repository fixtures instead of skipping tests or copying defaults.
- Final review verification passed 35 native tests and all 143 current Core
  tests with zero skips/failures, followed by actual owned Music/Spotify
  dictionary transport and artwork acceptance. Neither vendor player was run.
- The publication gate checks all 27 changed files. The only retained strings
  are the two deliberately invalid test URL credential prefixes; three email
  matches are reserved example-domain URL fixtures. No rule is globally allowed.
