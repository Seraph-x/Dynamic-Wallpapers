# Independent Wallpaper-Editor repository

The user requests moving Editor out of Dynamic-Wallpapers into a repository named Wallpaper-Editor, and explicitly requires both parts to build independently. These are the authorized scope and acceptance criteria.

## Ownership and approach

Create Seraph-x/Wallpaper-Editor, public like the source repository, from the current public source snapshot at 60af80edc398d30b0b1bc1feaf460924077a160d. Create fresh history using the GitHub noreply author address. Gate the tracked-source allowlist for credentials and personal data before any publication. Record source paths and original hashes; retain original attribution and licenses. Do not rewrite or delete Dynamic-Wallpapers history or previous release assets.

The new root Swift package owns EditorApp, WallpaperEditorCore, WallpaperCore, WallpaperAudioSpectrum and WebWallpaperBridge. Keep the Editor/ directory for application/web sources but remove its parent-package dependency. Own the shared Scene runtime snapshot under Resources/SceneRuntime, with independent dependency locks, resource provenance, fixtures, tests, CEF preparation and packaging. Main source is never fetched or required during builds. Do not introduce a third shared repository or a cross-repository local dependency.

Alternative remote package dependency would still couple Editor releases to Main. A third shared repository would expand scope and complicate standalone builds. Owned snapshots are the chosen bounded extraction; future shared fixes require explicit porting.

Main removes Editor-specific application, core, authoring runtime, tests, scripts and current documentation. Main retains scene playback/script/property support and its existing scene import URL/file contract. Move Editor-specific fixtures used by Main playback tests to Main-owned test helpers before removing Editor/.

## Compatibility

Repository name changes; application bundle identifiers, URL schemes, executable identity, project formats and user-data locations do not. Existing Editor projects and Main import behavior remain compatible. Do not move installed applications or user data. Failures remain explicit; dependency verification, strict teardown and resource provenance checks remain enforced.

## Verification and delivery

1. Independently prepared source trees contain no symlinks or source dependencies into the sibling repository. Ignored binary build caches may be copied for local verification, but tracked preparation scripts must fetch and verify pinned CEF independently.
2. Both Swift package graphs resolve; Main builds and its core/import/playback regressions pass; Editor builds and all Editor/core/audio tests pass.
3. Editor web resources reproduce with their locks/provenance. Native Editor and Main Scene checks exercise actual rendering and teardown. Editor release packaging builds in a neutral temporary tree and verifies embedded dependency closure.
4. Source export checks prove Main excludes Editor ownership and includes all its own build inputs. Test a standalone Editor checkout/archive without a parent project.
5. Review both diffs. Publish the complete new repository first; then push Main cleanup through its protected-branch PR workflow. Verify remote commits and synchronized local checkouts. Do not claim whole-app runtime changes from a structural migration.

## User priority update

Complete and verify Wallpaper-Editor first. Do not rewrite already published history. Main cleanup follows successful new-repository verification/publication. Existing published commit-author email findings are acknowledged and are not part of this extraction.
