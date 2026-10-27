# Complete the remaining application and Editor work

Status: the user requested all remaining items on 2026-10-27, including items
previously held because Main was outside scope. That earlier restriction is
superseded for this completion series. Existing English-PR, real-email,
verification-before-merge, source-preservation and no-silent-fallback rules apply.

## Delivery contract

Deliver working external resource scripts, safe resource cleanup, live text/font
bindings, persisted per-wallpaper properties, real system-media integration and
complete dependency build/distribution records. Correct historical docs and
publish current Main and independent Editor binaries after full validation.
Code changes use separate coherent PRs, verified and merged under the existing
authorization. Documentation/release-only updates can go directly to Main.

Each feature needs targeted regression tests plus actual affected native/browser
execution. Editor edits include undo/redo, save/reopen and loose/PKG playback.
Preserve personal data, original source bytes and unknown metadata. No mock
success, silent conversion, swallowed errors or unsupported capability claims.

## Architecture and PR sequence

1. **Live text and font bindings.** Keep the pinned WebWallGL distribution intact
   in the build cache. Apply a small recorded, exact-match source patch during
   reproducible bundling, then record upstream and patch/output hashes. Refresh
   actual text layer state and text widgets when their user properties change,
   including the real paused rendering frame. Preserve script precedence and
   instance/generation lifetime. Main and Editor consume the same tested bundle.
2. **External resource scripts.** Extend the existing Script workspace and
   immutable resource transactions. Discover supported material/particle and
   package-derived resource script anchors with logical file paths. Compilation
   never executes scripts. Apply stages a new resource version and one history
   transaction; source originals stay unchanged. Unrecognized anchors remain
   visible read-only, with a reason. Integrate drafts, native capture, source
   diagnostics, restart and actual exported playback.
3. **Editor resource cleanup.** Use process-held filesystem leases to protect
   open project sessions, staged edits and all in-memory undo/redo. Collection
   happens only for projects without live editing sessions, against their saved
   resource roots under the same filesystem lock. Snapshot previews and handoffs
   already materialize independent copies; verify that retirement and collection
   cannot race a capture. Closed-project maintenance reclaims only unreferenced
   content-addressed versions and reports failures, never source project files.
4. **Persistent wallpaper properties.** Save typed overrides per managed scene
   identity, independent of authored defaults and Editor projects. Expose a
   localized Main settings panel with validation/reset and actual live delivery.
   Restore overrides at scene preparation before presentation. Keep one
   serialized, identity-bound command path; stale acknowledgements, pauses,
   crossfades, screen-saver policy and close cannot apply another scene's values.
   Unknown/missing/incompatible declarations produce explicit status and retain
   the stored data until an explicit user reset or correction.
5. **Real system media.** Native providers publish actual metadata and transport
   through a data-only shared source. Default off, explicit permissions, visible
   unavailable/denied states, no wallpaper-audio or simulated-media substitution.
   The renderer must honor an explicitly supplied external provider even when it
   has no current item. Public macOS APIs do not expose a generic other-app
   global now-playing source. Music/Spotify public Automation provider scope is
   awaiting the user's focused choice; unrelated work continues meanwhile.
6. **Dependency distribution closure.** Reconstruct exact source/patch records
   where provable. The old mpv commit is recoverable in the upstream fork
   network, but that alone does not prove the other 69 binary inputs. If the
   complete original closure cannot be established, build a controlled source
   closure supporting the bridge's actual software-render/CoreAudio/VideoToolbox
   contract. Archive all sources, patches, recipes, notices and actual build
   records; verify original hashes and resulting Mach-O dependencies. Only mark
   distribution records complete when those checks pass. Revalidate the separate
   FFmpeg tools against their exact sources/configuration and actual binaries.

Dependencies are deliberate: the live renderer fix precedes the Main property
panel, and external resource transactions precede final cleanup integration.
Media and distribution research/builds may run independently in isolated
worktrees. Their changes integrate through separate reviewed PRs.

## Verification and release

Maintain the existing 180-second CEF harness build and 60-second phase budgets;
targeted backend execution defaults to 60 seconds after a separate cold build.
Full Swift suites follow repository budgets. Use the pinned full test browser,
real CEF, owned fixtures, actual pixels/callbacks and normal shutdown evidence.
Do not install over the user's application or alter their wallpaper as a test.

Release Main as a new minor version and Editor under its independent version;
use distinct new tags and artifacts. Include current five-language install and
removal instructions, checksums, exact source archives, licenses, build records
and truthful signing/notarization status. Build from the final merged revision,
validate extracted archives and app signatures/dependency closure, run the
sanitized-public-export gate, then publish to GitHub Releases as authorized.

## Completion record

The companion completion ledger records PR links, tested revisions, evidence,
remaining work and any real external blockers. A merged partial PR does not mark
this entire request complete. Historical roadmap wording must match actual
implemented features at publication.
