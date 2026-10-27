# Persistent per-wallpaper user properties

This implements the approved completion backlog. Changes affect Main's owned
library and data-only scene property commands, never the original project.

## Persistence and exact identity

Add an optional legacy-compatible `scenePropertyOverrides` array to `MediaItem`.
Each entry contains an exact authored name and a finite JSON scalar. Missing
fields decode as an empty array; malformed fields fail. Non-scene media cannot
carry overrides. Names use UTF-8 bytes as identity: canonically equivalent names
remain distinct. Arrays and independently encoded JSON keys avoid Swift String
dictionary/set normalization. No library schema rewrite or metadata flattening is
needed for this additive field.

Metadata uses a flat iterative JSON parser with exact UTF-8 object identities;
never cast authored objects to a Swift String-keyed dictionary or dynamic
CodingKey container. Foundation preserves canonical-equivalent NSString keys
but keeps the first duplicate member and rejects deep unknown metadata, as real
regressions demonstrated. The native parser instead follows JavaScript's
last-member-wins semantics without adding a nesting limit. String scalar and
choice membership use UTF-8 bytes; catalog ties sort by UTF-16 code units.

A pure Core catalog mirrors the existing shared JavaScript property contract:
boolean, number, color, text and choice. Unsupported/preset-only/conditional or
malformed declarations remain visible with explicit reasons. Property and choice
names retain exact identity; choice ordering and numeric-choice engine behavior
are preserved. Catalog tests compare independently specified fixtures against
the existing JS catalog, including Unicode identity and invalid declarations.
The original metadata bytes remain immutable.

Stored values are validated as one patch before persistence or playback. Unknown,
read-only, invalid or duplicate overrides fail visibly; no subset is silently
applied or discarded. Reset removes stored overrides and explicitly delivers the
current declared editable defaults. Unavailable stored settings can be cleared
through an explicit reset. A stale catalog cannot overwrite a later selection,
metadata change, deletion or application shutdown.

## Native integration

Read `project.json` through the existing descriptor-relative SceneProjectProbe
reader. Main's inspector owns a typed property panel with boolean, numeric, color,
text and choice controls, current/default values, individual reset and reset-all.
Unsupported rows explain their reason. Save validates the capture and commits the
library before publishing a live update. A disk failure leaves running scenes
unchanged. A later browser failure remains visible as a saved setting whose live
application failed; no fabricated successful acknowledgement or hidden rollback.

Initial overrides apply while each new scene is paused and silent, before its
view becomes visible or playback starts. All currently owned instances of that
media receive serialized data-only commands; changing values does not remount
scripts. Paused scenes receive one acknowledged repaint. The session owner keeps
in-flight work through actual close, rejects stale commands and preserves all
existing gain/playback/shutdown invariants. Library reconciliation must not
recreate unchanged desktop playback solely for a property-value update.

Screen saver/desktop/inspector instances receive the saved `MediaItem` values on
their next normal preparation. Live updates apply to instances owned by the
current application process; no new cross-process control interface is invented.

## Delivery and verification

Two coherent PRs: Core catalog/persistence/wire foundation first, then complete
native UI/session integration and real playback acceptance. The foundation does
not expose an inactive product UI or claim complete end-user functionality.

Use failing Core tests before implementation; validate exact Unicode identity,
strict types/ranges, legacy decode, round trip, reset, duplicate rejection and
source immutability. Native owner tests cover initial ordering, multi-instance
updates, save failure, stale selection/deletion, paused frames and close races.
Real CEF fixtures prove default/initial/live/reset text, font, visibility and
color pixels without remounting; all five UI languages and retained unknown
metadata remain covered. GUI tests are serialized. Focused backend execution
uses the existing 60-second budget after a separate cold build; full suites use
repository budgets. Verify source privacy and exact tested heads before merging.
