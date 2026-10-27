# Per-wallpaper scene properties

Select a scene wallpaper and open **Scene properties** in the inspector. Boolean,
number, RGB color, text and declared choice controls edit this wallpaper's library
record. **Save and apply** persists the whole validated patch before sending it
to every owned instance of that wallpaper, including playing and paused previews.
The original project, package and default values are unchanged. The Editor is
not required.

Each editable row shows its authored default. **Use default** changes that draft
only; **Save and apply** commits it. Reloading or changing selection clears numeric
drafts from the previous capture.

**Reset properties** explicitly clears stored overrides and applies the current
defaults. **Reload properties** rereads metadata. Changed/unsupported declarations
and invalid saved values stay visible; no valid subset is silently applied.
Save failures leave live values unchanged. If persistence succeeds but rendering
fails, the inspector states that settings were saved and shows the actual error.

Numbers use declared slider bounds when representable and permit direct finite
numeric entry. Invalid numeric input disables saving; declared bounds and choices
are still validated before committing. Unsupported/conditional/preset-only rows
show a reason instead of an invented editable value. UI text is localized in
Chinese, English, Japanese, French and Spanish; authored labels remain unchanged.

## Validate a saved value

`ScenePropertyCatalog(projectJSON:)` accepts the original `project.json` bytes.
The caller must bind that read to the intended local project and revalidate the
capture before saving. For the owned fixture in `Tests/Fixtures/ScenePropertyCatalog`:

```swift
let catalog = try ScenePropertyCatalog(projectJSON: projectData)
let changes = [ScenePropertyOverride(name: "caption", value: .string("Live 雪"))]
try catalog.validate(overrides: changes)
let wire = try catalog.wireJSON(overrides: changes)
```

The fixture and this sequence are exercised by Core tests. The resulting JSON
contains scalar values and exact authored names, suitable for the existing
data-only scene-property transport. No source file is written by these APIs.

| API | Result |
|---|---|
| `rows` | Ordered declarations, including explicit read-only reasons. |
| `validate(overrides:)` | Validates the whole patch, rejecting duplicates, unknown/read-only names and invalid values. |
| `wireJSON(overrides:)` | Encodes only validated changes without normalizing authored names. |
| `resolvedValues(overrides:)` | Returns editable defaults combined with validated overrides, suitable for a complete reset/application. |

Boolean, slider, RGB color, text and declared choice values follow the shared
JavaScript catalog. Preset-only, unsupported/conditional or malformed rows stay
visible as read-only. Invalid metadata objects fail explicitly. A slider uses
declared finite bounds; step is metadata rather than an invented rounding rule.

## Preserve identity and original metadata

Names, string values and choice membership compare UTF-8 bytes. Canonically
equivalent strings such as `é` and `e` plus combining acute remain distinct.
Equal-order rows sort by JavaScript UTF-16 code units. Definitions and choices
also use exact string equality, so UI comparison cannot hide an authored change.

The parser retains original bytes in `projectJSON` and uses a flat node arena.
It follows JSON's grammar and the renderer's last-member-wins duplicate semantics
without recursive traversal or a custom depth limit. Unknown large numeric
lexemes remain in the retained bytes; non-finite declared values are read-only.
Invalid UTF-8 or invalid Unicode scalar strings fail explicitly at the native
boundary. Unrelated fields are never serialized back to a replacement project.

## Persist overrides

`MediaItem.scenePropertyOverrides` is an array of exact name/scalar entries.
Older library records without the field decode to an empty array. An explicit
malformed field fails decoding; duplicates/non-finite values and overrides on
non-scene media fail normal library validation. The additive field does not
change original project defaults or require a library schema migration.

Catalog validation belongs before committing a changed library and again before
applying settings against newly read metadata. A saved property whose declaration
has changed must produce a visible error; callers must not apply only the valid
subset or silently discard stored values. Reset is an explicit caller operation:
clear persisted entries and deliver validated current defaults.

## Reproduce verification

Build Core tests separately:

```sh
python3 scripts/swift_sdk.py build --disable-sandbox --target WallpaperCoreTests
```

Run the compiled `WallpaperCoreTests.xctest` with the repository's `scripts/test.py`
process-group supervisor and its 60-second targeted budget. Setting
`SCENE_PROPERTY_CATALOG_PARITY_OUTPUT` to an ignored artifact path makes the
parity test export its actual catalog results. Compare those results with:

```sh
node scripts/test-scene-property-catalog-parity.mjs "$SCENE_PROPERTY_CATALOG_PARITY_OUTPUT"
```

The tests cover strict types/ranges, exact Unicode identity, original bytes,
legacy persistence, duplicate members, malformed tokens, 12,000-level unknown
metadata and independent raw-JSON comparisons against the existing JavaScript
catalog.

## Native persistence and playback ownership

`SceneProjectProbe` reads relative to one directory descriptor. A property capture
binds exact metadata bytes to the root device/inode; save and initial playback
revalidate that capture. The project declaration uses the same flat parser, so
deep unrelated metadata is not rejected by Foundation's nesting limit. PKG
inspection checks the actual length-prefixed `PKGV` header, including the real
authored package fixture, rather than treating an unprefixed string as a package.

`ScenePropertyEditorModel` validates drafts, saves atomically through the library
store and then publishes acknowledged property commands. Selection/reload and
shutdown invalidate queued actions. Metadata readers, including cancelled earlier
selections and save revalidation, remain owned until real completion before media
removal or application shutdown. Invalid stored values require explicit reset.
`ScenePropertySessionOwner` serializes all owned instances, gives pending pages
the latest values before attaching their view and rejects attachment after a
failed latest update. Closing cancels new commands and retains ownership until
the native close callback and in-flight operations drain. Playback scheduling
ignores property-only differences while retaining all other media comparisons.

Build and run the actual Swift/CEF acceptance separately:

```sh
python3 scripts/swift_sdk.py build --disable-sandbox --build-tests
bash scripts/build-scene-swift-test.sh
python3 scripts/test-scene-swift.py --properties
```

The native fixture uses independently authored callback and direct-binding GPU
oracles. It checks default and restored first-frame pixels, all five property
types, playing/paused instances, reset, retained view identity, closing during
an update and unchanged original loose/PKG bytes. The runner requires each
acceptance record plus complete runtime shutdown; a zero exit alone is insufficient.
Actual AppModel save/reopen/reset and real AppKit field-editor/button interaction
have separate tests. All fixture data and CEF profiles use owned temporary roots.
