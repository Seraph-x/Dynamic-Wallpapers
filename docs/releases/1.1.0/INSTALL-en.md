# Install Dynamic Wallpaper 1.1.0

Apple Silicon (arm64) · macOS 14.0 or later · build 5

1. Download `DynamicWallpaper-1.1.0-arm64.dmg` and `SHA256SUMS.txt` from the official GitHub release.
2. Run `shasum -a 256 DynamicWallpaper-1.1.0-arm64.dmg` and compare its result with the matching line in `SHA256SUMS.txt`.
3. Open the DMG and drag **Dynamic Wallpaper.app** into **Applications**. Eject the DMG and launch the installed app. For the ZIP build, extract the archive and move the app into Applications.
4. The app is ad-hoc signed and not Apple-notarized. If macOS blocks launch, verify the download first, then use **System Settings → Privacy & Security → Open Anyway** for this app.

Before replacing an older copy, quit it normally. Imported media is stored separately from the application. If you need to downgrade, keep a separate copy of `~/Library/Application Support/DynamicWallpaper` before the first 1.1.0 launch; 1.1.0 saves library schema 4 and older versions may reject the updated file. The app’s “Back Up and Clear Library” action also clears the active library; it is not a backup-only upgrade step.

Choose **Import Wallpaper → Media Files / Web Project / Scene Project**, import your own files, choose a display and apply the wallpaper. A scene project folder must contain `project.json` and its JSON/PKG entry/resources. Only import projects you trust. Scene pause/resume retains the same scene; a paused web page reloads when resumed.

Open the offline **User Guide** for scene properties, explicit Music/Spotify consent and audio response. System audio response requires macOS 14.2 or later; the other app features retain macOS 14.0 support. Scene playback in the native screen saver remains unsupported. Editor 0.1.0 is a separate optional download, with independent projects and settings.

To remove Main, quit it and move only **Dynamic Wallpaper.app** to Trash. If you installed its optional screen saver, remove that item separately in System Settings. Imported media remains in `~/Library/Application Support/DynamicWallpaper/`; delete that folder only if you intentionally want to erase the library. Removing Main does not remove Editor or its projects. The application retains the controlled dependency sources, notices and measured build records in ThirdParty; see the release notes for actual validation limits.
