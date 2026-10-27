# Offline scene renderer

The application ships `webwallgl.bundle.mjs`, built from **WebWallGL 3.0.0**
(MIT) and **Mediabunny 1.56.0** (MPL-2.0). The bundle is not entirely MIT.
The separate WeScene MIT notice applies to engine code derived from that project.
All three notices accompany the app; bundled legal comments are retained.

`provenance.json` records the npm distribution, integrity and generated SHA-256.
The original WebWallGL entry is checked against its recorded SHA-256 before
bundling. `scripts/scene-runtime-build/package-lock.json` fixes all build inputs.
The build applies the recorded transforms in `scripts/scene-engine-patches.mjs`
to that verified entry in memory. They update live text/font bindings and text
layout, draw text textures before the acknowledged frame, isolate asynchronous
frame acknowledgements and reject outstanding promises on disposal. The patch
source hash, transformed entry hash, reasons and exact anchor counts are recorded
in `provenance.json`; the installed upstream source remains untouched.
To reproduce from a clean checkout:

```sh
npm ci --prefix scripts/scene-runtime-build
node scripts/scene-bundle.mjs --check
node --test scripts/test-scene-engine-patches.mjs
node --test scripts/test-scene-runtime.mjs
node scripts/test-scene-rendering.mjs
```

The last command requires Playwright Chromium (`npx --prefix
scripts/scene-runtime-build playwright install chromium`). It uses a temporary
localhost test server, never the user's app or library. Set
`SCENE_CHROMIUM_EXECUTABLE` to explicitly select another installed Chromium.
`SCENE_DEVICE_SCALE=2` exercises Retina backing resolution.
The application itself has no localhost server, Node requirement or network
runtime dependency.

Mediabunny source is unmodified and available in the exact distribution at
https://registry.npmjs.org/mediabunny/-/mediabunny-1.56.0.tgz (`package/src`).
This is the Source Code Form corresponding to the MPL-covered bundled modules;
recipients may obtain it under MPL-2.0. WebWallGL's original distributable is at
https://registry.npmjs.org/webwallgl/-/webwallgl-3.0.0.tgz.
No upstream example wallpapers, donation images or third-party artwork are
included. The fixtures under `Tests/Fixtures` are authored for this project.

The trusted shell supplies a fixed zero spectrum and disables simulated Now
Playing data. It disables automatic quality changes rather than silently
lowering rendering quality. Engine errors and missing/denied project resources
remain observable; unsupported scenes never become a picture or video fallback.
Scene scripts execute in the page's CEF renderer and are not a security sandbox.
Only import projects you trust, as with executable web wallpapers.
