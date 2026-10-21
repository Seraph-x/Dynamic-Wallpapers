import Foundation

public struct EntryBatchPatch: Equatable {
    public var timing: EntryTiming?
    public var isMuted: Bool?
    public var volume: Double?

    public init(timing: EntryTiming? = nil, isMuted: Bool? = nil, volume: Double? = nil) {
        self.timing = timing; self.isMuted = isMuted; self.volume = volume
    }

    public func validate(hasVideo: Bool) throws {
        guard timing != nil || isMuted != nil || volume != nil else {
            throw WallpaperError("请至少勾选一项设置。")
        }
        if let timing { try timing.validate() }
        if let volume { try AudioSettings(volume: volume).validate() }
        if (isMuted != nil || volume != nil) && !hasVideo {
            throw WallpaperError("所选条目中没有视频或网页，无法修改声音。")
        }
    }
}

public enum BatchOperation {
    case addMedia(ids: Set<UUID>, playlistID: UUID)
    case favoriteMedia(ids: Set<UUID>, value: Bool)
    case removeMedia(ids: Set<UUID>)
    case editEntries(playlistID: UUID, ids: Set<UUID>, patch: EntryBatchPatch)
    case removeEntries(playlistID: UUID, ids: Set<UUID>)

    public func applying(to library: Library) throws -> Library {
        var result = library
        switch self {
        case let .addMedia(ids, playlistID):
            try Self.validate(ids, within: library.media.map(\.id))
            let index = try Self.playlistIndex(playlistID, in: library)
            result.playlists[index].entries += library.media.filter { ids.contains($0.id) }.map { PlaylistEntry(mediaID: $0.id) }
        case let .favoriteMedia(ids, value):
            try Self.validate(ids, within: library.media.map(\.id))
            for index in result.media.indices where ids.contains(result.media[index].id) { result.media[index].isFavorite = value }
        case let .removeMedia(ids):
            try Self.validate(ids, within: library.media.map(\.id))
            result.media.removeAll { ids.contains($0.id) }
            result.displays.removeAll { $0.source.mediaID.map(ids.contains) == true }
            for index in result.playlists.indices { result.playlists[index].entries.removeAll { ids.contains($0.mediaID) } }
            result = result.clearingMissingCurrent()
        case let .editEntries(playlistID, ids, patch):
            let index = try Self.playlistIndex(playlistID, in: library)
            try Self.validate(ids, within: library.playlists[index].entries.map(\.id))
            let videos = Set(library.media.filter(\.supportsAudio).map(\.id))
            try patch.validate(hasVideo: library.playlists[index].entries.contains { ids.contains($0.id) && videos.contains($0.mediaID) })
            for entryIndex in result.playlists[index].entries.indices where ids.contains(result.playlists[index].entries[entryIndex].id) {
                var entry = result.playlists[index].entries[entryIndex]
                if let timing = patch.timing { entry.timing = timing }
                if videos.contains(entry.mediaID) {
                    if let isMuted = patch.isMuted { entry.audio.isMuted = isMuted }
                    if let volume = patch.volume { entry.audio.volume = volume }
                }
                result.playlists[index].entries[entryIndex] = entry
            }
        case let .removeEntries(playlistID, ids):
            let index = try Self.playlistIndex(playlistID, in: library)
            try Self.validate(ids, within: library.playlists[index].entries.map(\.id))
            result.playlists[index].entries.removeAll { ids.contains($0.id) }
            result = result.clearingMissingCurrent()
        }
        try result.validate()
        return result
    }

    private static func validate(_ ids: Set<UUID>, within available: [UUID]) throws {
        guard !ids.isEmpty else { throw WallpaperError("请先选择要操作的壁纸。") }
        guard ids.isSubset(of: Set(available)) else { throw WallpaperError("部分所选项已不存在，请重新选择。") }
    }

    private static func playlistIndex(_ id: UUID, in library: Library) throws -> Int {
        guard let index = library.playlists.firstIndex(where: { $0.id == id }) else {
            throw WallpaperError("播放列表已不存在，请重新选择。")
        }
        return index
    }
}

extension Library {
    public func clearingMissingCurrent() -> Library {
        var result = self
        let entriesByList = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, Set($0.entries.map(\.id))) })
        for index in result.displays.indices {
            let binding = result.displays[index]
            if let playlistID = binding.playlistID, let current = binding.currentEntryID,
               entriesByList[playlistID]?.contains(current) != true {
                result.displays[index].currentEntryID = nil
            }
        }
        return result
    }
}
