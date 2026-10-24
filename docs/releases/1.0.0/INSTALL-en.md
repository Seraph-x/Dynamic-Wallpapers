# Install Dynamic Wallpaper 1.0.0

Apple Silicon (arm64) · macOS 14.0 or later · build 4

1. Download `DynamicWallpaper-1.0.0-arm64.dmg` and `SHA256SUMS.txt` from the official GitHub release.
2. Run `shasum -a 256 DynamicWallpaper-1.0.0-arm64.dmg` and compare its result with the matching line in `SHA256SUMS.txt`.
3. Open the DMG and drag **Dynamic Wallpaper.app** into **Applications**. Eject the DMG and launch the installed app. For the ZIP build, extract the archive and move the app into Applications.
4. The app is ad-hoc signed and not Apple-notarized. If macOS blocks launch, verify the download first, then use **System Settings → Privacy & Security → Open Anyway** for this app.

Before replacing an older copy, quit it normally. Imported media is stored separately from the application. If you need to downgrade, keep a separate copy of `~/Library/Application Support/DynamicWallpaper` before the first 1.0.0 launch; 1.0.0 saves library schema 4 and older versions may reject the updated file. The app’s “Back Up and Clear Library” action also clears the active library; it is not a backup-only upgrade step.

Choose **Import Wallpaper → Media Files / Web Project / Scene Project**, import your own files, choose a display and apply the wallpaper. A scene project folder must contain `project.json` and its JSON/PKG entry/resources. Only import projects you trust. Scene pause/resume retains the same scene; a paused web page reloads when resumed.

Read **User Guide** inside the app for offline instructions. Scene compatibility varies by effect/script; system audio spectrum capture, scene editing and scene screen-saver playback are excluded. Third-party source/license inventory limitations are retained in the app’s ThirdParty folder and the release notes.
