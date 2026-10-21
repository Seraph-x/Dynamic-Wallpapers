import Foundation
import WallpaperCore

struct ProjectionFixture {
    let image = MediaItem(url: URL(fileURLWithPath: "/screensaver-test/still.png"), kind: .image, width: 64, height: 32)
    let animation = MediaItem(url: URL(fileURLWithPath: "/screensaver-test/animated.png"), kind: .animatedImage,
                              width: 64, height: 32, duration: 2)
    let extended = MediaItem(url: URL(fileURLWithPath: "/screensaver-test/extended.mp4"), kind: .video,
                             width: 64, height: 32, duration: 3, backend: .extended)
    let web: MediaItem
    var library: Library
    var list: Playlist { library.playlists[0] }

    init() {
        let project = WebProjectReference(root: URL(fileURLWithPath: "/screensaver-test/web"), entry: "index.html")
        web = MediaItem(url: project.entryURL, kind: .web, width: 64, height: 32, backend: .web, webProject: project)
        let entries = [
            PlaylistEntry(mediaID: image.id, timing: EntryTiming(seconds: 9), audio: AudioSettings(volume: 0.2)),
            PlaylistEntry(mediaID: extended.id),
            PlaylistEntry(mediaID: image.id, timing: EntryTiming(mode: .loops, seconds: 4, loops: 3),
                          audio: AudioSettings(isMuted: true, volume: 0.7)),
            PlaylistEntry(mediaID: animation.id, timing: EntryTiming(mode: .full)),
            PlaylistEntry(mediaID: web.id)
        ]
        library = Library()
        library.media = [web, animation, extended, image]
        let list = Playlist(name: "Mixed source", entries: entries, transition: 0.8)
        library.playlists = [list]
        library.displays = [DisplayBinding(id: "test-display", playlistID: list.id,
                                           currentEntryID: entries[2].id, fit: .fit)]
    }
}
