import Foundation
import WallpaperCore

extension AppModel {
    var filteredMedia: [MediaItem] {
        library.media.filter {
            (section != .favorites || $0.isFavorite) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    var visibleBatchIDs: Set<UUID> {
        if let list = selectedPlaylist { return Set(list.entries.map(\.id)) }
        if section == .displays { return [] }
        return Set(filteredMedia.map(\.id))
    }

    @discardableResult
    func performBatch(_ operation: BatchOperation) -> Bool {
        let saved = mutate { $0 = try operation.applying(to: $0) }
        if saved { batchSelection.clear() }
        return saved
    }

    @discardableResult
    func setGlobalMute(_ muted: Bool) -> Bool { mutate { $0.settings.isMuted = muted } }
}
