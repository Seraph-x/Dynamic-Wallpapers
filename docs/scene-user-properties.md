# Per-wallpaper property data contracts

This foundation adds typed catalog and persistence APIs. Main's property panel
and live session integration are a separate implementation stage; this document
does not claim that an inspector control is already available.

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
catalog. They do not substitute for the later native UI/CEF playback acceptance.
