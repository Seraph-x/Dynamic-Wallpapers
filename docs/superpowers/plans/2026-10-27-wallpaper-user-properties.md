# Per-wallpaper properties execution plan

The user's approved completion scope owns requirements; no second interview.

1. [x] Add red Core tests for the scalar/catalog/override contracts and legacy
   MediaItem persistence, including exact Unicode identity. Record real failure.
2. [x] Implement pure Core types, catalog validation and exact-name wire encoding;
   add the optional MediaItem field without changing project files or schemas.
3. [x] Run complete Core tests, shared-JS catalog parity and package checks;
   inspect/review/privacy-check the foundation diff and merge an English PR.
4. [x] Add native UI/session regression tests for initial application ordering,
   atomic save, all owned instances, stale captures and close/paused lifetimes.
5. [x] Implement descriptor-bound catalog reading, inspector controls/reset and
   persistent save plus acknowledged data-only updates; retain playback identity.
6. [x] Run actual CEF default/initial/live/reset playback and native lifetime
   tests, five-language UI verification, full relevant regressions and review.
7. [ ] Publish/merge the independently verified integration PR and record both
   PRs in the umbrella completion ledger; only then mark this package complete.

## Foundation and integration verification

- Missing APIs produced the initial red Core build before implementation.
- A raw duplicate-member regression exposed Foundation's first-value behavior;
  the exact-member parser follows the renderer's last-value behavior.
- A 12,000-level unknown-array regression then exposed Foundation's unrelated
  metadata depth rejection. A flat iterative node arena now parses and destroys
  these documents without recursive descent or an invented nesting limit.
- All 143 Core tests pass, including strict scalar/range/choice identity,
  legacy persistence, invalid JSON, source immutability and exact Unicode names.
- Eight actual raw-JSON fixture cases match the existing JavaScript catalog,
  including duplicate declarations, readonly metadata and ECMAScript colors.
- Foundation PR #42 is merged; native controls and playback are the dependent
  integration worktree, and are not complete until its final acceptance and merge.
- Independent review's exact-string equality finding was reproduced with two
  failing assertions, then corrected for both definitions and choice values.

- Independent review found no other P1/P2 issues in parser, catalog or persistence.
  The 143-test full Core suite and eight-case JavaScript parity passed after the
  exact-string equality correction. Authored source diff checks pass.

- Native regression reproduced a property-only media edit cancelling a pending
  wallpaper switch; scheduling now ignores only scene property override changes.
- Actual CEF acceptance exposed the old PKG header probe's missing length prefix.
  A real authored package import test failed before the header fix. The prior
  synthetic unprefixed test headers were corrected to actual package bytes.
- A 12,000-level unknown metadata fixture exposed Foundation's nesting rejection
  in native project inspection. Flat declaration reading now preserves the raw
  metadata and uses the same exact duplicate-member policy as the renderer.
- A receiver-failure regression exposed attachment of stale prepared values.
  The owner now preserves each receiver failure and refuses to expose its view
  until a subsequent successful update; failures remain visible to their caller.
- One complete real CEF run passed default/restored pixels, all owned instances,
  playing/paused state, reset, original loose/PKG bytes and complete shutdown.
  Repetition after the final ownership review remains required.
- Actual AppModel persistence/reopen/reset passed. The AppKit control test uses
  its real field editor, keyboard editing notifications and accessible Save
  action; direct AX representation changes do not substitute for text editing.

- Final ownership review reproduced premature close while a dispatched native
  metadata reader was held. Native close now drains that real task. Panel
  shutdown/removal also drains all earlier cancelled selection readers and save
  revalidation; the corresponding targeted regressions pass.
- Actual AppKit editing reproduced stale saved status and numeric drafts surviving
  reload. Draft state now clears on the capture revision and numeric editing
  clears result status. Per-row default actions preserve persisted values until
  Save, as the actual field-editor/button test verifies.
- The final current integration suite passes all 143 Core and 62 affected App
  tests with no failures or skips, plus eight actual JavaScript parity cases.
  Three final actual CEF runs passed serially with fresh owned loose/PKG fixtures,
  all four acceptance records per run and zero remaining native pages.
  This integration diff received a full manual lifetime/source-preservation
  review.
