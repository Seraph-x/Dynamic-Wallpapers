# System audio spectrum validation

## Scope and platform

The optional scene spectrum backend uses a private Core Audio Tap on macOS 14.2+.
The application's deployment target remains macOS 14.0. Other wallpaper types,
microphone input and the future separately installed editor are outside this
feature. The published 1.0.0 artifacts are unchanged.

Validation ran on Apple M1/macOS 27.0.1 with Xcode SDK 27.0 and Swift 6.4 in Swift 5
language mode. Actual CEF reported ANGLE Metal Renderer: Apple M1. No conclusions
about Intel Macs, older OS point releases, Bluetooth/device changes or protected
audio sources are inferred from this machine's results.

## Reproducible checks

Build before applying the 60-second focused-test budget:

```sh
python3 scripts/swift_sdk.py build --build-tests --disable-sandbox
python3 scripts/test.py --skip-build --filter 'WallpaperCoreTests|WallpaperAudioSpectrumTests|SceneSurfaceTests|LocalizationResourceTests'
node --test scripts/test-scene-runtime.mjs scripts/test-scene-spectrum.mjs
python3 scripts/test-product-configuration.py
python3 scripts/test-app-packaging.py
python3 scripts/test-audio-capture-localization.py
python3 scripts/build-help.py --check
python3 scripts/test-help.py
bash scripts/build-scene-swift-test.sh
python3 scripts/test-scene-swift.py --system-audio
```

Use the pinned `scripts/help-requirements.txt` environment for help regeneration.
The product-configuration test invokes SwiftPM's manifest sandbox, which requires
an environment where nested `sandbox-exec` is permitted. Real CEF/audio tests
require access to WindowServer and macOS system audio recording authorization.
They fail visibly when those facilities are unavailable; they do not substitute
simulated input. Running the audio test emits short authored test tones.

## Results

- Focused Swift verification passes 123 core tests and 30 related application tests.
- FFT tests cover stereo frequency separation, coherent amplitude scaling,
  silence, partial packet equivalence and invalid samples/rates.
- Controller tests cover default-off behavior, multiple subscribers, subscription
  changes during pending start, disabling during start, start/stop/poll errors,
  explicit retry, failed cleanup ownership and unsupported systems.
- Surface tests verify synchronous pause intent before a late play acknowledgment.
- Native protocol checks cover exact channel sizes/ranges, invalid numbers,
  trusted main-frame routing, replacement and retired-session cancellation.
- Eleven JavaScript tests cover existing scene behavior, spectrum identity/range,
  one request in flight, disposal and explicit transport/protocol errors.
- Product and packaging suites pass (41 and 42 tests), along with localized
  permission copying and the 14-test help suite. A real development application
  was packaged and passed signature/dependency validation; its main-only audio
  permission, five localized prompts and spectrum runtime were verified.

Two complete real CEF/Core Audio runs each completed two capture/release cycles:

- A separate `/usr/bin/afplay` process plays an authored stereo WAV, 1 kHz left
  and 4 kHz right. Real captured FFT values must reach the corresponding bands
  with channel separation, and the scene's audio marker must turn red.
- The same test tone played by the host AVAudioEngine must leave that marker
  green, proving host-output exclusion.
- Disabling capture while the external tone plays must restore the green marker.
- Core Audio tap and device inventories must equal their pre-test sets after
  each cycle. Closing the scene must remove its capture demand.
- Loose and PKG scene animation, pause/resume, pointer pixels, native gain and
  CEF release are checked in the same process before the audio cases.

The second run includes the final synchronous playback-intent fix. Test logs and
per-run result JSON live under `.build/verification/scene-swift/`; no captured PCM
is written. Only authored fixture audio and ordinary diagnostic records persist.

## Permission and failure behavior

The main application contains `NSAudioCaptureUsageDescription` and localized
`InfoPlist.strings` for all five languages. Helpers and the screen saver do not
request system audio capture. The opt-in is persisted with a legacy default of
off; a malformed present value fails decoding.

Core Audio's successful start is not an independent proof of authorization or
audible content: valid silence is represented by zero samples. The implementation
does not invent permission status from a zero spectrum. OS/device/sample errors
that Core Audio reports are visible, clear the spectrum and require explicit
retry. Such capture errors do not stop scene animation.

During close, an already authorized spectrum request may finish after native
retirement. It receives an explicit HTTP 410 and a cancellation diagnostic; this
does not turn a successful page release into a resource-denial failure. Other
resource denials retain their existing error behavior.

## Shared capture implementation

The FFT, Core Audio driver and serial capture controller now live in
`Sources/WallpaperAudioSpectrum/`. Main and Editor link this small shared library
without linking each other’s executable. The original analyzer/controller tests
live in `Tests/WallpaperAudioSpectrumTests/`. Editor has a separate explicit
preview opt-in; see [Editor preview audio](../editor-preview-audio.md).
