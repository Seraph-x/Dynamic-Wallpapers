import Foundation
import WallpaperCore

/// Runtime playback instructions; a direct wallpaper does not create a Playlist.
struct PlaybackContent: Equatable {
    let entries: [PlaylistEntry]
    let mode: PlaybackMode
    let transition: Double
    let allowsNext: Bool

    init(playlist: Playlist) {
        entries = playlist.entries
        mode = playlist.mode
        transition = playlist.transition
        allowsNext = true
    }

    private init(mediaID: UUID, audio: AudioSettings) {
        entries = [PlaylistEntry(id: mediaID, mediaID: mediaID, audio: audio)]
        mode = .repeatOne
        transition = 0.3
        allowsNext = false
    }

    init(source: DisplaySource, library: Library) throws {
        switch source {
        case .playlist(let id):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else {
                throw WallpaperError("播放列表已不存在，请重新应用壁纸。")
            }
            self.init(playlist: playlist)
        case .media(let id, let audio):
            guard library.media.contains(where: { $0.id == id }) else {
                throw WallpaperError("壁纸已不在素材库中，请重新应用壁纸。")
            }
            self.init(mediaID: id, audio: audio)
        }
    }

    func hasSameSchedule(as other: PlaybackContent) -> Bool {
        mode == other.mode && transition == other.transition && allowsNext == other.allowsNext
            && entries.elementsEqual(other.entries) {
                $0.id == $1.id && $0.mediaID == $1.mediaID && $0.timing == $1.timing
            }
    }
}
