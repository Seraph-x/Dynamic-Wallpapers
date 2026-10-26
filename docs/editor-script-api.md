# SceneScript completion and starters

The Script workspace offers a static, offline catalogue for the pinned WebWallGL **3.0.0** runtime. Hints and syntax checking do not execute source or prove its types, runtime capabilities or event delivery. These catalogue limits never make existing author-written source read-only: the source anchor, base value and existing bindings still determine editability.

The current app supplies audio or silence and passes `media: null`. System-media templates are unavailable. Native snapshot previews supply zero spectrum by default; a separate Editor preview opt-in enables real stereo spectrum on macOS 14.2+. Main has its own capture setting. User-property callbacks receive initial values. Independent previews can also [test live values](editor-preview-properties.md), including while paused, without saving or changing exports. Main’s ordinary playback still uses authored defaults.

## Choose a starter

A starter is a complete module. Choosing one edits the draft; Apply commits it. Replacing nonempty source requires an explicit Replace draft / Cancel choice and remains undoable in the local code editor. Starters are never silently appended to existing hooks.

| ID | Actual entry or operation | Availability |
|---|---|---|
| `init` | `init(value)` plus `update(value)` | All supported anchors. The text companion update keeps the script retained. For maxwidth/pointsize/volume, the starter passes values through because the pinned init argument is unavailable. |
| `update` | `update(value)` | All supported anchors. Target-aware examples preserve a captured baseline; maxwidth/pointsize/volume use a direct passthrough. |
| `properties` | `applyUserProperties(properties)` | Records delivered property names in `shared.userPropertyKeys`. Receives initial values and live changes from independent preview controls; values are unwrapped. It does not assume a named project property. |
| `cursor` | `cursorClick(event)` | Records `event.worldPosition` in `shared.cursorWorldPosition`. Requires a rendered, hit-testable layer. Unavailable for effect visibility because the engine does not register its cursor hooks. |
| `media` | `mediaPropertiesChanged(event)` | Unavailable: the current app passes `media: null`. No normal system-media event stream is promised. |
| `animation` | `animationEvent(event, value)` | Requires real authored events on the same layer. Available for vectors, alpha/brightness, layer/effect visibility and text. Other numeric anchors have an unsafe pinned dispatch mismatch. |
| `resize` | `resizeScreen(size)` | Records the actual pixel size in `shared.screenSize`. First render and later CSS size changes dispatch. `size` is an object with numeric x/y/width/height, without Vec2 methods. |
| `timer` | `engine.setTimeout(callback, milliseconds)` | Sets `shared.timerElapsed` after one second. A callback is scheduled from init; there is no exported `timer` or disposal hook. The returned timer handle is a cancellation function. |
| `audio` | `engine.registerAudioBuffers(...)` read in `update` | Typed scalar/vector/boolean/text examples. Unavailable for maxwidth/pointsize/volume because they cannot safely capture a numeric baseline during init in this pin. |

The registry always returns these nine stable IDs. Unavailable entries retain a complete, syntax-valid source string for inspection, but the UI disables insertion and shows their reason.

| Reason code | Meaning |
|---|---|
| `UNSUPPORTED_TARGET` | This target has no supported source-value contract in the catalogue. |
| `MEDIA_HOST_DISABLED` | The app passes `media: null`; normal system-media delivery is disabled. |
| `EFFECT_CURSOR_UNSUPPORTED` | Effect visibility scripts collect cursor functions but are not registered for cursor dispatch. |
| `ANIMATION_SCALAR_UNSUPPORTED` | The pinned animation dispatcher handles this numeric field as a vector. |
| `INITIAL_VALUE_UNAVAILABLE` | The pinned init argument is unavailable for this numeric field, so the baseline-dependent audio starter cannot be offered. |

Cursor, resize, timer and user-property starters preserve the selected field through `update(value)` while recording real event state in `shared`. Callback return values from cursor, media and properties do not write back the field. Animation-event return values do write back, subject to the target-specific dispatch restrictions above.

## Match the value type

Only target `text` uses the text sandbox. Other properties on a text layer still use the object sandbox.

| Source target | Value in update | Starter behavior |
|---|---|---|
| origin, scale, angles, color | Vec3-compatible x/y/z object | Capture a separate Vec3 baseline for motion or audio. Angles use degrees; color components conventionally use 0..1. |
| alpha, brightness, maxwidth, pointsize, volume, intensity, exponent | number | Return finite numbers. Alpha/volume examples stay within 0..1. |
| visible, effects[i].visible | boolean, or retained finite numeric visibility feedback | Return booleans in visibility examples. Fractional numbers are folded as nonzero visibility, not opacity. |
| text | string | Capture static text in init when a starter needs a stable base. Some engine update patterns start their text feedback chain from an empty string. |

### Pinned numeric init and animation limitations

In `activateObjectScript`, the engine reads init arguments from the layer field slot. It maps local origin/scale/angles but does not map maxwidth, pointsize or volume to their actual text/sound slots. Their init callback therefore receives `undefined`; their update callback reads the correct numeric slot through `scalarFieldSlot`.

The supplied init/update/event starters for these fields pass through the engine values and preserve the static field. They do not invent a default number or silently compensate by initializing a baseline in the first update. The audio starter needs that numeric baseline and is explicitly unavailable.

Animation-event sink registration marks only alpha and brightness as scalar. It classifies maxwidth, pointsize, volume, intensity and exponent as vectors. Those fields cannot safely use the animation starter even though the syntax checker accepts `animationEvent`. This restriction applies to the starter catalogue, not to editing or preserving imported source.

## Use positive completion hints

`scriptValueKind(target)` returns `vector`, `scalar`, `boolean`, `text` or `unknown`. `completionOptions(target, scope)` returns fresh `{label, type, detail, info?}` records. `lifecycleTemplates(target)` returns fresh `{id, source, available, reason}` records; available records have `reason: null`.

Global hints include engine/input, typed thisLayer/thisScene, scriptProperties/shared, Vec2/3/4, WEMath/WEColor/WEVector, localStorage, MediaPlaybackEvent and an explicit set of ordinary JavaScript syntax and constructors. The object/effect sandbox also supplies `thisObject` as thisLayer's alias; the text sandbox does not.

Useful member scopes include:

- `engine`: runtime/frametime/timeOfDay, canvasSize/screenResolution, current userProperties, audio resolution constants and buffers, managed timers, registerAsset and host-state query functions. Query functions such as `isRunningInEditor()` must be called.
- `input`: world/screen/normalized cursor positions, previous normalized position and left-button state.
- `value`: Vec3 members for vector targets, String members for text, no vector members for numbers or booleans.
- `thisLayer.origin`, `originalOrigin`, `scale`, `color` and `size` on object anchors: the narrower `makeVec3` proxy members, not the full Vec3 API. Text-sandbox origin uses the same narrower proxy; its color/angles/scale are arrays and receive array hints instead.
- Object-sandbox `thisLayer.angles`: the separate degree-valued angle proxy. Its component assignments and arithmetic methods write back to the layer, so it must not be treated as a detached vector snapshot.
- `thisScene`: conservative real layer lookup/enumeration on object anchors. On text, only getLayer is suggested; it returns a text snapshot rather than a writable object-layer proxy.
- `WEMath`, `WEColor`, `WEVector`, `Vec3`, `Math`, `Date`, `localStorage` and `MediaPlaybackEvent`: reviewed members implemented by this pin. WEMath.deg2rad/rad2deg are numeric factors; its degrees/radians members are functions.

### Distinguish vector values from layer proxies

The vector-valued `value` argument, input cursor vectors and `engine.canvasSize`
use the real Vec3 API. Layer properties do not all expose that same interface:

| Layer proxy | Available members | Mutation behavior |
|---|---|---|
| Object origin/originalOrigin/scale/color/size; text origin | x/y/z, add/subtract/divide/multiply/copy/length/lengthSqr/toArray | `makeVec3` owns a snapshot. add/multiply mutate that snapshot; subtract/divide return a new proxy; copy returns a real Vec3. |
| Object angles | x/y/z, add/subtract/multiply/toArray | `makeScriptAngleVec` exposes degrees. Component writes and arithmetic update the actual layer angles. |
| Text color/angles/scale | Array members from the positive catalogue | These text-sandbox snapshots are arrays, without Vec3 methods. |

For independent Vec3 arithmetic on a layer property, construct a separate
`new Vec3(thisLayer.origin)` first. Completion preserves these distinctions;
for example, it does not suggest full-Vec3 normalize/cross methods on the narrow
origin proxy or length/copy methods on the angle proxy.

The catalogue omits DOM/network/Node globals, the no-op console, host-disabled media controls, no-op sortLayer and dummy text-scene layer creation. It omits speculative members and advanced resource APIs whose effects depend on unavailable resources. Author-defined scriptProperties/shared keys are not invented. An unknown scope returns no hints. Completion neither resolves arbitrary expressions nor evaluates source.

## Check syntax without evaluating it

The existing `checkSceneScript` compiles transformed source, reports actual syntax errors and recognized entry names, and warns for source without a recognized entry or engine-clock use. It does not invoke the module or callbacks.

Syntax success does not establish member existence, target typing, hook registration or host capability. The engine's missing-member proxy can return no-op engine methods, so accepting an arbitrary engine member is not evidence that it works. Arbitrary npm/browser imports are not supported by the catalogue: the transform only provides real namespace aliases for WEMath, WEColor and WEVector, and strips other import forms. No fictional audioChanged, disposal or timer lifecycle entry is offered.

## Verify the pinned evidence

Both packages are pinned to 3.0.0 in [Editor/Web/package.json](../Editor/Web/package.json). [Editor provenance](../Editor/ThirdParty/provenance.json) records editor-entry and bundled-resource hashes. [Runtime provenance](../Resources/ThirdParty/WebWallGL/provenance.json) records the published engine and source hash. Local npm sources below live under `Editor/Web/.build/node_modules/` after installing the pinned build dependencies; they are not public document links or additional runtime dependencies.

| Relative npm source | Functions or sections supporting the catalogue |
|---|---|
| `webwallgl/webwallgl.mjs` | `SANDBOX_PARAM_NAMES`, `SCRIPT_ENTRY_NAMES`, `scriptToFunctionBody`, `checkSceneScript`: checker and import/entry semantics. |
| `webwallgl/webwallgl.mjs` | `evalTextScript`, `evalObjectScript`: actual factory arguments, text/object differences and script-retention predicates. |
| `webwallgl/webwallgl.mjs` | `Vec2`, `Vec3`, `Vec4`, `WEMATH`, `WECOLOR`, `WEVECTOR`, `makeInput`, `createInputView`, `makeSandboxStorage`, `applyEngineHost`: reviewed globals and members. |
| `webwallgl/webwallgl.mjs` | `makeObjectLayerProxy`, `makeThisScene`: object members; the independent thisScene object inside evalTextScript documents the narrower text sandbox. |
| `webwallgl/webwallgl.mjs` | `makeVec3`: narrow snapshot members and mixed arithmetic mutation behavior for object vector properties and text origin; `makeScriptAngleVec`: degree-valued angle members with component/arithmetic writeback. These factories are distinct from the real Vec3 class used by value/input/canvasSize. |
| `webwallgl/webwallgl.mjs` | `activateObjectScript`, `activateEffectVisible`, `addCursorHook`, `dispatchCursor`, `dispatchAnimEvents`, `registerResizeHook`, `dispatchResize`, `scalarFieldSlot`: actual anchor registration and value writeback. |
| `webwallgl/webwallgl.mjs` | `createEngineTimers`, `registerMediaHook`, `diffMediaEvents`, `fillAudioBuffers`, `mergeUserPropertyValues`, `applyLiveProps`: callback, audio and property delivery. |
| `@webwallgl/editor/types.d.ts` | `SceneScriptCheck`, `EditorScriptIssue`, `MediaSnapshot`: public checker/diagnostic/host contracts. These are not a declaration of every script global. |

Published source SHA256: engine `f838e70347df8205edca5f3fc04dbb7c56b31738b5785b27038d912d5c45a1bc`; editor `7480ae1ad96f54cadffebef536f78352db6e84be9477bb2cda22ac1909881d84`.

The app's actual host options are in [scene-runtime.mjs](../Sources/WallpaperApp/Resources/SceneRuntime/scene-runtime.mjs), with real-or-silent audio in [scene-spectrum.mjs](../Sources/WallpaperApp/Resources/SceneRuntime/scene-spectrum.mjs). Workbench source remains non-executing; native snapshot preview and Main run captured source through the shared pinned engine.

Reproduce pure checks with `node --test Editor/Web/script-language.test.mjs`. The independent headless runtime phase is `node Editor/Web/test-script-language-runtime.mjs`; it runs real starter modules through the pinned renderer, with explicit spectrum input, scene events and pointer commands. Browser test debug inspection is not a production API or a replacement for visible CodeMirror editing acceptance.

## Inspect actual runtime issues

The independent preview retains actual `getScriptIssues()` records and generic
renderer warnings. See [runtime diagnostics](editor-script-diagnostics.md) for
captured-source identity, unmapped lines, restart behavior and the pinned
500-issue/200-character/repeated-failure limits. Timer failures do not have
structured source identities in this runtime.
