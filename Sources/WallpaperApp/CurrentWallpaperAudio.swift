import Foundation
import WallpaperCore

struct CurrentWallpaperAudioTarget: Identifiable, Equatable {
    enum ID: Hashable {
        case playlist(playlistID: UUID, entryID: UUID)
        case direct(groupID: UUID)
    }

    let id: ID
    let playlistName: String?
    let mediaName: String
    let audio: AudioSettings
}

extension AppModel {
    var currentWallpaperAudioTargets: [CurrentWallpaperAudioTarget] {
        let connectedDisplays = Set(displays.map(\.id))
        var seen = Set<CurrentWallpaperAudioTarget.ID>()
        return library.displays.compactMap { binding in
            guard connectedDisplays.contains(binding.id),
                  let target = currentWallpaperAudioTarget(for: binding) else { return nil }
            let id = target.id
            guard seen.insert(id).inserted else { return nil }
            return target
        }
    }

    @discardableResult
    func updateCurrentWallpaperAudio(_ audio: AudioSettings,
                                     targetID: CurrentWallpaperAudioTarget.ID) -> Bool {
        guard currentWallpaperAudioTargets.contains(where: { $0.id == targetID }) else {
            report(WallpaperError("当前壁纸已切换，无法保存声音设置。"), context: .save)
            return false
        }
        return mutate { library in
            switch targetID {
            case .playlist(let playlistID, let entryID):
                guard let playlistIndex = library.playlists.firstIndex(where: { $0.id == playlistID }),
                      let entryIndex = library.playlists[playlistIndex].entries.firstIndex(where: {
                          $0.id == entryID
                      }) else {
                    throw WallpaperError("当前播放列表条目已不存在，无法保存声音设置。")
                }
                library.playlists[playlistIndex].entries[entryIndex].audio = audio
            case .direct(let groupID):
                guard let binding = library.displays.first(where: { $0.groupID == groupID }),
                      case .media(let mediaID, _) = binding.source else {
                    throw WallpaperError("此单张壁纸已停止或更换，无法保存声音设置。")
                }
                for index in library.displays.indices where library.displays[index].groupID == groupID {
                    library.displays[index].source = .media(mediaID, audio: audio)
                }
            }
        }
    }

    private func currentWallpaperAudioTarget(for binding: DisplayBinding) -> CurrentWallpaperAudioTarget? {
        switch binding.source {
        case .playlist(let playlistID):
            guard let entryID = binding.currentEntryID,
                  let playlist = library.playlists.first(where: { $0.id == playlistID }),
                  let entry = playlist.entries.first(where: { $0.id == entryID }),
                  let media = library.media.first(where: { $0.id == entry.mediaID }),
                  media.supportsAudio else { return nil }
            return CurrentWallpaperAudioTarget(id: .playlist(playlistID: playlistID, entryID: entryID),
                playlistName: playlist.name, mediaName: media.name, audio: entry.audio)
        case .media(let mediaID, let audio):
            guard let media = library.media.first(where: { $0.id == mediaID }),
                  media.supportsAudio else { return nil }
            return CurrentWallpaperAudioTarget(id: .direct(groupID: binding.groupID),
                playlistName: nil, mediaName: media.name, audio: audio)
        }
    }
}
