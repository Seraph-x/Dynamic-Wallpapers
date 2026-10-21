import Foundation
import WallpaperCore

/// A detail panel describes either a library item or one verified playlist entry,
/// never a media selection combined with an unrelated entry's settings.
struct InspectorSelection: Identifiable {
    enum Context {
        case library, favorites
        case playlist(Playlist, PlaylistEntry)
    }

    struct ID: Hashable {
        let section: SidebarSection
        let mediaID: UUID
        let entryID: UUID?
    }

    let item: MediaItem
    let context: Context
    let id: ID

    @MainActor
    init?(model: AppModel) {
        guard !model.batchSelection.isActive,
              let section = model.section,
              let item = model.library.media.first(where: { $0.id == model.selectedMediaID }) else { return nil }
        switch section {
        case .library, .favorites:
            guard model.filteredMedia.contains(where: { $0.id == item.id }) else { return nil }
            context = section == .favorites ? .favorites : .library
            id = ID(section: section, mediaID: item.id, entryID: nil)
        case .playlist:
            guard let playlist = model.selectedPlaylist,
                  let entry = playlist.entries.first(where: {
                      $0.id == model.selectedEntryID && $0.mediaID == item.id
                  }) else { return nil }
            context = .playlist(playlist, entry)
            id = ID(section: section, mediaID: item.id, entryID: entry.id)
        case .displays, .screenSaver:
            return nil
        }
        self.item = item
    }

    var sourceTitle: String {
        switch context {
        case .library: return "来自：全部壁纸"
        case .favorites: return "来自：我的收藏"
        case .playlist(let playlist, _): return "来自：播放列表 \(playlist.name)"
        }
    }

    func sourceTitle(using l10n: AppLocalizer) -> String {
        switch context {
        case .library: return l10n("来自：全部壁纸")
        case .favorites: return l10n("来自：我的收藏")
        case .playlist(let playlist, _): return l10n("来自：播放列表 \(playlist.name)")
        }
    }

    var audio: AudioSettings {
        if case .playlist(_, let entry) = context { return entry.audio }
        return AudioSettings()
    }
}
