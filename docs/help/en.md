# Dynamic Wallpaper help

**v1.0.0 · Build 4 · Offline user guide**

<!-- help-languages -->
Read in: [简体中文](zh-Hans.md) · [English](en.md) · [日本語](ja.md) · [Français](fr.md) · [Español](es.md)
<!-- /help-languages -->

Open **User Guide** from the app’s Help menu or its menu bar icon. The guide opens in the current app interface language. The links above change only the guide, not the app’s settings. Help is included with the app and can be read offline.

## Contents {#contents}

1. [About the app](#introduction)
2. [Quick start](#quick-start)
3. [Using the features](#features)
4. [Settings reference](#settings)
5. [Troubleshooting](#troubleshooting)
6. [Performance and power use](#performance)
7. [Keyboard shortcuts and gestures](#shortcuts)
8. [Version information](#version)
9. [Reference](#appendix)

## 1. About the app {#introduction}

Dynamic Wallpaper manages local wallpapers on macOS, bringing videos, animations, pictures, local web projects and scene projects to your desktop, individually or in rotating playlists.

Use it to keep your desktop lively, organize themed collections, or give each display its own content. You can apply a single wallpaper immediately or customize a playlist’s order, timing, transitions, and individual audio levels. The interface is available in Simplified Chinese, English, Japanese, French, and Spanish.

| Your goal | Start here | Saved as an active setup? |
| --- | --- | --- |
| See how it looks | **Play Preview** in media details | No; stopping the preview restores the previous wallpaper |
| Set the desktop | **Apply Wallpaper** in media details, or **Apply Playlist** | Yes; it keeps running after you close the main window |
| Set the macOS screen saver | Publish from **Screen Saver**, then select it in macOS System Settings | Saved separately from desktop wallpapers |

## 2. Quick start {#quick-start}

1. Open Dynamic Wallpaper. Click **Import Wallpaper** (the plus button) in the toolbar, or press `⌘O`.
2. Select **Media Files**, click **Choose Files…**, select one or more videos, animations, or pictures, and confirm the import.
3. Click an item in **All Wallpapers** to open **Wallpaper Details** on the right.
4. Choose the target display. The default, **All Displays · Synchronized**, applies the same source to every display. Select an individual display first if you want to change only that screen.
5. Choose **Fill** or **Fit**, then click **Apply Wallpaper**. A single wallpaper does not need a playlist.
6. For video sound, turn off **Mute All**, then adjust **Mute This Item** and **Volume** in the details before applying the wallpaper.
7. Closing the main window leaves the applied wallpaper running. Use the menu bar icon to pause, resume, switch playlists, open settings, or reopen the main window.

> 💡 **Tip:** **Play Preview** temporarily previews the item in both the details panel and the selected desktop. Click **Apply Wallpaper** afterward to save it as the display’s wallpaper.

## 3. Using the features {#features}

### 3.1 Import, find, and organize media {#library}

The library keeps media records and independent copies of new imports so you can reuse them.

1. Click **Import Wallpaper** to add files, or drag videos, animations, or pictures into the main window.
2. Enter part of a name in **Search wallpapers** to narrow the results.
3. Select an item and click **Favorite** to make it easy to find in **Favorites**.
4. Click **Show in Finder** to locate the managed copy used by the app.

Importing while viewing a playlist also adds the new media to that playlist. Removing media from the library removes its entries from all playlists and deletes its managed copy. Removing an entry from one playlist affects only that playlist, not the copy. Neither action deletes the original file.

### 3.2 Create and play a playlist {#playlists}

A playlist groups media for themed rotation or timed changes to your desktop.

1. Click **New Playlist** in the sidebar.
2. Enter a name, then click **Rename** or press Return.
3. Use **Add Wallpaper** to choose library items, or use **Add to Playlist** in an item’s details.
4. Drag entries, or use their up and down arrows, to change the order.
5. Choose a playback mode, transition, fit option, and display, then click **Apply Playlist**.

| Option | Values and default | Effect and when to use it |
| --- | --- | --- |
| Playback mode | In Order (default); Shuffle Without Repeats; Repeat One | Use In Order for a planned sequence, shuffle for variety, or Repeat One to stay on the current entry |
| Transition | Instant; Fade · 0.3 s (default); Fade · 0.8 s | Fades affect both picture and sound. Instant changes are sharper and reduce overlapping work during transitions |
| Display Duration | Fixed Duration (30 seconds by default); Play Once in Full; Repeat a Set Number of Times (initially 1) | Select an entry, change its timing in the details, then click Save Duration |

For a fixed duration, enter a value and choose s (seconds), m (minutes), or h (hours); for example, 1.5 m is 90 seconds. Full playback and repeats use a video’s or animation’s own duration. For a still image, full playback uses the chosen duration; repeated display lasts “duration × repeats.” Web and scene wallpapers support fixed duration only. Duration must be greater than 0, and repeats must be a positive whole number.

Shuffle Without Repeats works by playlist entry: adding the same media twice creates two entries. With Repeat One selected, **Next Wallpaper** still selects the current entry; change the playback mode to move to another item. If the next entry cannot be prepared, the current picture stays visible and an error is shown. The failing entry is not skipped automatically.

The menu bar’s **Playlists** submenu is a quick way to apply a playlist to all displays using **Fill**.

### 3.3 Set up multiple displays {#displays}

Use independent settings when your main and secondary displays serve different purposes. Use synchronization when you want the same source across displays.

1. Before applying an item or playlist, select one display to change only that screen.
2. Choose **All Displays · Synchronized** for shared playback.
3. Open **Displays** in the sidebar to check each screen’s source and playback status.
4. In a display card, choose a playlist and fit option, then click the corresponding apply button. To choose a different single wallpaper, return to the library.
5. Click **Restore System Wallpaper** on a display to stop the app’s wallpaper on that screen.

**Fill** preserves proportions and crops anything outside the display area. **Fit** keeps the entire picture visible and fills unused space with black. Displays in a synchronized group share their source and related audio settings.

> ⚠️ **Important:** **Restore System Wallpaper** stops the app’s desktop layer. If **Sync System Wallpaper** was enabled, macOS still uses the latest synchronized still image. See [system wallpaper synchronization](#system-wallpaper).

### 3.4 Linked preview and audio {#preview-audio}

Linked preview lets you check framing on the actual desktop without saving a display assignment.

1. Select media or a playlist entry, then choose the display and fit option.
2. Click **Play Preview**. Applied playback is temporarily suspended; if the target belongs to a synchronized group, the whole group is suspended together.
3. Click **Stop Preview**, select another item, or close the window that owns the preview to restore the previous wallpaper.

Only the details panel produces preview sound; desktop copies stay muted. The details and desktop previews are not guaranteed to be frame-synchronized.

| Where you change audio | What it affects and saves |
| --- | --- |
| Item Audio in library details | Used for the current preview; saved to the target display when you click Apply Wallpaper. It does not change playlist audio |
| Item Audio in a playlist entry’s details | Saved to that entry and used for that entry and its preview only |
| Audio for an applied single wallpaper on the Displays page | Updates the current wallpaper immediately. Synchronized displays share the change; playlists are unaffected |
| Mute All | Takes precedence over individual settings and mutes previews too |

Videos, web wallpapers and scenes have individual audio controls. **Mute This Item** is off by default, and **Volume** starts at 100%. Volume ranges from 0–100% in 1% steps. Use Mute All for a quiet desktop, then adjust individual levels when some media is louder than others.

### 3.5 Work with multiple items {#batch}

1. Click **Select Multiple** and select items. **Select All Results** selects the current filtered results.
2. In the library, you can favorite, unfavorite, add to a playlist, or remove selected items together.
3. In a playlist, click **Batch Edit…**. Enable **Change Duration**, **Change Mute Setting**, or **Change Volume**, enter the values, then click **Save Changes**.
4. Click **Done** to leave multiple-selection mode.

All three change switches start off. Fields you do not enable keep their existing values. The editor starts with 30 seconds, 1 repeat, mute off, and 100% volume; these are initial editing values, not a summary of the selected entries. If web or scene entries are selected, batch timing supports fixed duration only. Audio changes apply to videos, web wallpapers and scenes.

### 3.6 Local web wallpapers and interaction {#web}

A local web project is useful for desktop content made with HTML, stylesheets, and scripts.

1. Click **Import Wallpaper** and select **Web Project**.
2. Click **Choose Folder…** and select the folder containing the page and its resources.
3. Set **Entry file (HTML)**. It defaults to `index.html`; use **Choose Entry File…** or enter a relative path such as `pages/index.html`.
4. Click **Import Web Project**, then apply it from the library.

Importing copies the entire project folder, preserves relative paths, and materializes symbolic links within the project as independent files or folders. Links outside the project, cyclic links, and special files cause the import to fail. Later changes to the original project are not synchronized to the copy. Keep HTML, images, stylesheets, and scripts inside the project; access to outside files and the external network remains restricted. Pausing preserves the picture; resuming reloads the page rather than preserving its internal progress.

To interact with a page, open the menu bar icon and enable **Web Interaction** (off by default). Follow the prompts to allow **Accessibility** and **Input Monitoring** in macOS System Settings, then return to the menu and enable Web Interaction again. Revoking permission turns interaction off. It forwards left-clicks on empty Finder desktop space, rather than providing a full browser’s interaction model.

### 3.7 Convert a video for compatibility {#transcoding}

**Transcode…** appears when the details panel’s compatibility check finds that the video is eligible. It creates a more compatible file; the check determines whether the action is available.

1. Click **Transcode…** and wait for the video inspection to finish.
2. Choose **Original Size · Original Frame Rate** (default) or **Fit 1080p · Up to ~30 fps**.
3. Check the output folder and filename. The defaults are the original import source folder and `original-name-h264.mp4`. Output cannot be written into the app’s `Media` folder or its subfolders.
4. Click **Add to Transcoding Queue**. When conversion finishes, click **Import to Library** on the completed job to create a separate managed copy while keeping the output file. Replace playlist entries if needed.

If you close the window, reopen it through **Transcoding Jobs** in the menu bar to check progress.

The output is an MP4 with H.264 video and AAC audio, encoded with VideoToolbox hardware encoding. Re-encoding is not lossless. The original-size option pads odd dimensions to even values; the 1080p option scales down proportionally without enlarging and limits the frame rate to approximately 30 fps. Only the first video track and first audio track are kept; subtitles and chapters are not retained. A silent input remains silent. App mute and volume settings do not affect the output’s audio.

Existing files are never overwritten. Jobs run one at a time and continue if you close the transcoding window. Quitting the app asks you to confirm cancellation of unfinished jobs; completed files remain. Hardware-encoding failures are reported, without automatically switching to software encoding.

### 3.8 Synchronize the system wallpaper {#system-wallpaper}

**Sync System Wallpaper** freezes the applied wallpaper into a PNG and sets it as that display’s macOS wallpaper. This leaves a similar background when the dynamic layer stops.

1. Open **Settings → General** and enable **Sync System Wallpaper**.
2. Apply a wallpaper and check the synchronization status for each display.
3. If synchronization fails, read the error, address the cause, and click **Retry Sync**.

This is a still image, not a system wallpaper updated every frame. Temporary previews do not write a system wallpaper.

> ⚠️ **Important:** Turning synchronization off, stopping playback, or quitting the app leaves the last synchronized image in place. None of these actions restores the system wallpaper from before synchronization. To choose another image, use **Wallpaper** in macOS System Settings.

### 3.9 Appearance and full-screen backgrounds {#appearance}

On macOS 26 and later, including macOS 27, the interface uses Liquid Glass. On macOS 14 and 15, it uses compatible native materials. In **Settings → Appearance**, adjust the color scheme, transparency, and blur to balance background visibility with readable text.

The main window can show the wallpaper behind its interface when it occupies the active full-screen space. Normal windows and background spaces do not continuously capture this full-screen background. Without an app wallpaper, the app uses a still image from the system wallpaper, which may not match the current time-of-day image of a macOS dynamic wallpaper.

### 3.10 Set up the native screen saver {#screensaver}

The **Screen Saver** sidebar page manages system screen saver content independently of desktop wallpaper. Choose a native video, still image, animation, or a playlist containing them. **Import Screen Saver Media…** adds local files. Web projects, scenes and media using the extended player are excluded. After importing or choosing a source, the review dialog centers included items; when exclusions exist, included and excluded items appear side by side. Confirm exclusions before publishing. The original playlist stays unchanged, and newly excluded entries require confirmation again.

The app copies published media to `DynamicWallpaper/ScreenSaverExport` in its Application Support folder. The page shows whether usable content is published. A failed sync reports an error and keeps the last successful copy. Related playlist edits sync automatically; **Sync Now** requests another publication. New content takes effect the **next time the screen saver starts** or when you reopen the in-app preview. A running instance keeps its starting version. Removing source media does not immediately remove a published copy. **Clear Published Screen Saver Content…** affects only screen saver content; older copies are reclaimed after active instances finish.

For first use, click **Install or Update Screen Saver…** on that page and follow the macOS installer. Select **Dynamic Wallpaper Screen Saver** yourself in System Settings. You can then use **Recheck Installation Status**; installation alone does not mean the system selected it. In the screen saver's system configuration panel, authorize the publication folder shown in the app. This separate authorization lets the screen saver read published content after the app quits. A moved folder, expired permission, or missing publication produces an explicit error. The in-app preview shows published content; confirm actual system playback in macOS.

### 3.11 Local scene wallpapers {#scene}

1. Choose **Import Wallpaper → Scene Project**.
2. Select the folder containing `project.json`, the scene JSON or PKG entry, and all referenced resources. Select the folder rather than an isolated JSON/PKG file.
3. Click **Import Scene Project**. The app saves an independent copy; later changes to the original folder are not synchronized.
4. Select the imported scene, preview it, choose a display and fit mode, then click **Apply Wallpaper**.

Use projects you trust because scene scripts can execute. Invalid metadata, unsafe paths or a missing entry produce an import error; keep resource paths inside the project folder.

Use fixed playlist durations. Pause retains the scene clock; resume continues the same instance. Existing volume, mute, fit and web frame-rate settings also apply to scenes. Enable the existing interaction setting and its permissions for mouse movement and blank-desktop left clicks. Preview windows accept direct mouse input.

Playback uses the author’s default properties. Scene editing and native screen-saver playback are not supported. Compatibility is limited to the pinned WebWallGL engine; scene loading/rendering failures report errors, and some unsupported effects or scripts may produce engine warnings. These are recorded in the CEF log; no picture or video substitution is performed.

Development builds add optional **System audio response** in Settings → General → Sound (macOS 14.2+; off by default). Allow system audio recording when prompted. Only playing scenes share one capture service; thumbnails do not start it. Wallpaper mute does not stop spectrum input. Audio is analyzed in memory, excludes this app’s sound, and is not recorded or uploaded; the microphone is not used. Capture stops when all scenes pause/close or the setting is turned off. A capture/device error clears the spectrum and shows an error while animation continues; use **Retry system audio response** after resolving the problem. The scene editor is planned as a separate downloadable/removable plugin.

## 4. Settings reference {#settings}

These defaults apply to a new library; existing preferences are preserved. Ordinary preferences are saved and applied immediately. Editors with a save button, such as duration controls, require you to click it.

### 4.1 General {#general-settings}

| Setting | Values / default | Effect and recommendation |
| --- | --- | --- |
| Interface language | Follow System (default); 简体中文, English, 日本語, Français, Español | Chooses the app’s interface language; see the language section below |
| Launch at login | On / off; a new installation does not register it by default | Runs the app after you log in to macOS. If approval is needed, use Open System Login Items… to confirm it |
| Show app icon in Dock | On / off; on by default | When off, opening a management window temporarily shows the Dock icon and app menus; the icon hides after all management windows close. Minimizing or hiding a window does not close it. The saved preference is unchanged. This does not stop playback and is not a power-saving setting |
| Sync System Wallpaper | On / off; off by default | Saves a frozen image of the applied wallpaper as the system wallpaper. It generates images and writes files; leave off if you do not need it |
| Mute All | On / off; on by default | Mutes all video, web, scene and preview audio without setting individual volume levels to zero |
| Pause in Low Power Mode | On / off; off by default | Responds to macOS Low Power Mode, not a particular battery percentage. Useful when working on battery |
| Pause when the device is hot | On / off; on by default | Pauses when macOS reports a serious or critical thermal condition. Keeping this enabled is recommended |

Playback automatically pauses when the screen is locked, the system or display sleeps, or the user session is inactive. No setting is needed. Playback resumes only after all automatic pause reasons have cleared; a manual pause needs a manual resume. Check the menu bar for pause reasons.

### 4.2 Appearance {#appearance-settings}

| Setting | Values / default | Effect and trade-off |
| --- | --- | --- |
| Appearance mode | Follow System (default), Light, Dark | Changes the interface, not the wallpaper file. Choose what is comfortable for your surroundings |
| Background transparency | 0–100%; 75% by default | 100% is fully transparent without blur; 0% is opaque. Reduce transparency to make text easier to read over busy backgrounds |
| Blur style | Clear, Frosted (default) | Used below 100% transparency. Frosted gives foreground content more separation |
| Full-screen background frame rate | 30 Hz (default), 60 Hz | Sets the app’s full-screen background capture frequency, not the desktop video frame-rate limit. 60 Hz is smoother but requires more processing |

The macOS **Reduce transparency** preference takes priority for readability. It does not overwrite the transparency or blur values saved in the app.

### 4.3 Storage, Advanced, and About {#other-settings}

| Panel | Contents | Purpose |
| --- | --- | --- |
| Storage | Independent-copy explanation, library backup and clearing, latest configuration backup, and pending cleanup count | Manages media and cleanup status without changing originals or app settings |
| Advanced | Configuration filename, library format version, full path, and Show in Finder | Read-only information for locating and backing up the configuration |
| About | App name, version, and description | Confirms the version you are using |

To start with an empty library:

1. Open **Settings → Storage** and click **Back Up and Clear Library…**. Clearing is unavailable while an import is running.
2. Confirm removal of media, including favorites, playlists, and display assignments. App settings, original files, and synchronized system images remain unchanged.
3. Only after a successful backup does the app clear records and delete managed copies. Under **Latest Configuration Backup**, view the path or show the backup in Finder.

The backup contains only JSON, not media, and cannot restore deleted copies. If a related transcoding job still holds the media, wait for it to finish, or cancel it and wait for resource release before retrying; unrelated jobs are unaffected. Cleanup failures display an error and remain in the pending cleanup records for retry at the next launch.

If media has disappeared from the library but its file remains on disk, check the pending cleanup count and error details in **Storage**. The managed folder may have been replaced or may no longer match the app’s record, so deletion is refused; this does not mean the original file was deleted. Confirm which copy is affected before handling an orphaned copy. Do not clear the entire media folder.

### 4.4 Language and regional formatting {#language-settings}

1. Open **Settings → General → Interface language**.
2. Choose **Follow System** or one of the five languages.
3. Once the setting saves successfully, the app’s own interface updates immediately. No restart is required, and wallpaper playback is not restarted.

Follow System uses the first supported language in your macOS preferred-language order, or English if none matches. Number formatting follows the current interface locale. Filenames, media names, and custom playlist names are not translated. System-owned menus and file pickers may still use the macOS language.

Opening **User Guide** again from the app returns to the current app language. Choosing a language at the top of the guide changes only the document you are reading.

## 5. Troubleshooting {#troubleshooting}

First identify whether the problem affects the applied desktop wallpaper, a temporary preview, or the app window’s background. Start with the simplest checks below. If an error offers **View Details…**, keep the text to help identify the affected media or operation.

| Symptom | Possible causes | Checks and fixes | Temporary workaround |
| --- | --- | --- | --- |
| Wallpaper is missing or black | Not applied; wrong display; unavailable file; decoding error; playback still paused | ① Select the media and display, then apply again. ② Use Show in Finder to confirm the file actually in use is readable. ③ Check menu bar pause reasons. ④ Try a readable still image. ⑤ Read that media’s inspection error | Use an image that displays correctly, or stop the app’s wallpaper on that screen |
| Video stutters, drops frames, or uses too much power | High resolution or frame rate; multiple independent sources; previews or conversion running; heat | ① Stop previews. ② Wait for conversion to finish or cancel an unwanted job. ③ Reduce independent animated displays. ④ Set the full-screen background to 30 Hz. ⑤ Where Transcode is available, make a 1080p / approximately 30 fps version | Pause wallpaper playback or use a still image; enable power-saving pause |
| Volume changes seem ineffective | Mute All enabled; wrong entry or temporary preview setting changed; no audio track; wrong macOS output | ① Check global mute, item mute, and volume. ② Confirm the current entry or display. ③ Reapply after changing library-detail audio. ④ Check the source video and macOS sound output | Test with a video known to have audio; keep Mute All enabled when silence is needed |
| Multiple displays change together | All Displays · Synchronized was used; an old target is selected; display connections changed | ① Check connected screens in Displays. ② Apply a source to each screen separately. ③ Reselect targets after reconnecting. ④ Check for a shared synchronization group | Configure one screen first, then the others in turn |
| Local web project will not load | Wrong project folder or entry file; resources moved; network dependency; script error | ① Confirm the HTML/HTM file is inside the selected folder. ② Check the relative path. ③ Restore project resources. ④ Compare with a simple page using only local resources. ⑤ Read the error details | Use a self-contained local project or other media |
| Web wallpaper does not respond to clicks | Interaction off; missing or revoked permission; clicks are not on empty Finder desktop space | ① Enable Web Interaction from the menu bar. ② Check Accessibility and Input Monitoring as prompted. ③ Enable interaction again after authorization. ④ Test a left-click on empty desktop space | Use it as a noninteractive wallpaper |
| Playlist does not advance or behaves unexpectedly | Repeat One selected; duration too long or unsaved; empty list; next entry cannot be prepared | ① Check playback mode. ② Check and save duration, unit, and repeats. ③ Confirm there are entries. ④ Check the file actually used by the next entry. ⑤ Reapply the list after fixing the cause | Use In Order with a shorter fixed duration; manually remove the problematic entry |
| App is unresponsive or crashes | Heavy or faulty media or web page; conversion load; unreadable configuration | ① Allow time for active work. ② If possible, pause playback, quit normally, and reopen. ③ If unresponsive, force quit through macOS and reopen. ④ Test with a simple image. ⑤ Consider reset below only for an explicit library-reading error | Avoid the triggering media; force quitting interrupts unfinished conversions |
| macOS reports a missing permission | Web interaction authorization missing; inaccessible media or output folder; system restriction on full-screen capture | ① Identify the operation named in the error. ② For web interaction, check Accessibility and Input Monitoring. ③ Reselect readable media or a writable output folder. ④ If an earlier macOS 14 version requests Screen Recording for a full-screen background, check that permission and retry | Disable interaction or leave the app’s full-screen mode; use ordinary wallpaper playback |
| Wrong language, untranslated text, or no visible language change | Follow System selected; saving failed; text is a media name; some errors are not fully localized | ① Explicitly select the desired interface language. ② Check for a save error. ③ Reopen the affected window or help. ④ Distinguish system text and filenames from app labels | Temporarily use another available language. Custom playlist names can be renamed. A new library’s initial playlist may still be named “我的播放列表” |
| System wallpaper does not sync, or remains after stopping | Sync off or waiting for an applied wallpaper; sync failure; latest still image intentionally retained | ① Check the switch and each display’s status. ② Apply a wallpaper. ③ Fix file or display problems, then Retry Sync. ④ Choose a different image in macOS Wallpaper settings if needed | Turn synchronization off and choose a system wallpaper yourself. Disabling sync alone does not restore an older image |
| Media has left the library, but a local copy remains | Cleanup is pending, or the folder no longer matches the app’s record | ① Check pending cleanup in **Settings → Storage**. ② Keep the error details and confirm the target is an unneeded managed copy. ③ Relaunch to retry cleanup. ④ If it still fails, handle only the confirmed orphaned copy | Leave the file in place meanwhile; do not delete the whole media folder |

**Back Up & Reset for an unreadable library**

Use this only when the app explicitly reports that it cannot read the library. It backs up the existing configuration, then clears media records, playlists, display assignments, and library settings. Original media files are not deleted. You will need to import and configure them again. If settings are accessible, first use **Advanced** to locate and separately copy the configuration. Reset should not be your first response to a black screen or stuttering video.

## 6. Performance and power use {#performance}

- **Prioritize battery life:** Enable Pause in Low Power Mode and keep thermal pausing enabled. Pause manually from the menu bar when you do not need animation.
- **Reduce CPU and GPU work:** The CPU handles general processing; the GPU handles graphics. Choose resolution and frame rate appropriate for your displays. When conversion is available, the 1080p option can help reduce playback demands.
- **Assign displays by purpose:** Video on the main display and a picture on a secondary display generally cost less than separate high-resolution videos everywhere. Synchronization shares content, but resource use still depends on screen count and size.
- **Avoid overlapping work:** Stop previews when finished. Pause wallpapers if conversion causes stuttering. Fades briefly process both entries; choose Instant to reduce that overlap.
- **Set full-screen backgrounds as needed:** Start with 30 Hz. Choose 60 Hz only when smoother full-screen app backgrounds are useful. This setting does not cap the desktop video’s own frame rate.
- **Keep media available:** Use a reliably connected drive and local web resources. Leave still-image system synchronization off when you do not need it.

## 7. Keyboard shortcuts and gestures {#shortcuts}

| Action | Shortcut or gesture | Where it applies |
| --- | --- | --- |
| Import wallpaper | `⌘O` | App menu |
| Show or hide sidebar | `⌃⌘S` | Main window |
| Quit app | `⌘Q` | App menu; unfinished conversions require confirmation |
| Perform the default action | Return | Dialogs with a default button |
| Cancel or close a help popover | Esc | Applicable dialogs and question-mark help popovers |
| Open a control’s explanation | Focus its help button and press Space or Return, or click it | Controls with a help button |
| Reorder a playlist | Drag entries or click up/down arrows | Playlist, outside multiple-selection mode |
| Import media | Drag files into the window | Main window |
| Open a context menu | Right-click or two-finger click | Media or playlists |

`⌘` means Command and `⌃` means Control. Playback, pause, and next-wallpaper controls are available from the menu bar.

## 8. Version information {#version}

| Item | Information |
| --- | --- |
| App | Dynamic Wallpaper |
| Version | v1.0.0, build 4 |
| Guide scope | Current user-facing tasks, settings, data consequences, and troubleshooting |

Check **Settings → About** for the installed app version. This guide is included with the app for offline use.

## 9. Reference {#appendix}

### 9.1 Glossary {#glossary}

| Term | Meaning |
| --- | --- |
| Library | Media records and independent copies saved on import |
| Playlist entry | One addition to a playlist; the same media can have multiple independent entries |
| Synchronized group | Displays sharing a playback source and playback state |
| Applied wallpaper / linked preview | The first is saved as a display setting; the second is temporary and restores the previous wallpaper when it ends |
| System wallpaper | The macOS wallpaper image beneath the app’s dynamic layer |
| Transcoding | Re-encoding video into another format to create a new file |
| Entry file | The HTML file opened first in a local web project |
| Liquid Glass | The glass-like interface material provided by macOS 26 |

### 9.2 Supported file formats {#formats}

| Type | Extensions |
| --- | --- |
| Video | MP4, MOV, M4V, MKV, WebM, AVI |
| Still image | JPEG/JPG, PNG, HEIC, HEIF |
| Animation | GIF, APNG |
| Local web | HTML, HTM; imported through a web project folder |
| Local scene | Loose JSON or PKG with `project.json`; imported through a scene project folder |

An extension identifies a file type, not a guarantee that every codec inside it will play. Use the app’s inspection result for the specific file. Renaming an extension does not change video encoding.

### 9.3 System and languages {#requirements}

- System: macOS 14.0 or later.
- Processor: Apple Silicon (arm64).
- Resource needs depend on media dimensions, frame rate, page complexity, and display count. Choose media to suit the workload.
- Languages: 简体中文, English, 日本語, Français, Español.

### 9.4 Data locations and what is saved {#data}

To locate the configuration, open **Settings → Advanced** and use **Show in Finder**. Do not move or replace app-managed media folders manually. The app also stores synchronized system images separately.

Media records, favorites, playlists, display assignments, preferences, and pending cleanup records are saved. Searches, multiple selections, temporary previews, manual pause state, and unfinished transcoding queues are not kept across restarts. A configuration backup contains no media and cannot restore deleted copies; keep your originals or separately back up managed media.
