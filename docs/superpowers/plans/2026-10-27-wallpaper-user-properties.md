# Per-wallpaper properties execution plan

The user's approved completion scope owns requirements; no second interview.

1. [x] Add red Core tests for the scalar/catalog/override contracts and legacy
   MediaItem persistence, including exact Unicode identity. Record real failure.
2. [x] Implement pure Core types, catalog validation and exact-name wire encoding;
   add the optional MediaItem field without changing project files or schemas.
3. [ ] Run complete Core tests, shared-JS catalog parity and package checks;
   inspect/review/privacy-check the foundation diff and merge an English PR.
4. [ ] Add native UI/session regression tests for initial application ordering,
   atomic save, all owned instances, stale captures and close/paused lifetimes.
5. [ ] Implement descriptor-bound catalog reading, inspector controls/reset and
   persistent save plus acknowledged data-only updates; retain playback identity.
6. [ ] Run actual CEF default/initial/live/reset playback and native lifetime
   tests, five-language UI verification, full relevant regressions and review.
7. [ ] Publish/merge the independently verified integration PR and record both
   PRs in the umbrella completion ledger; only then mark this package complete.

## Foundation verification in progress

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
- Native UI and playback integration remains a separate required PR.
- Independent review's exact-string equality finding was reproduced with two
  failing assertions, then corrected for both definitions and choice values.

- Independent review found no other P1/P2 issues in parser, catalog or persistence.
  The 143-test full Core suite and eight-case JavaScript parity passed after the
  exact-string equality correction. Authored source diff checks pass.
