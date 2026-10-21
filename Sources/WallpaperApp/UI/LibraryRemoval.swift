import SwiftUI
import WallpaperCore

enum LibraryRemoval {
    case wallpaper(MediaItem)
    case playlist(Playlist)

    var title: String {
        switch self {
        case .wallpaper(let item): return "从素材库移除“\(item.name)”？"
        case .playlist(let playlist): return "删除播放列表“\(playlist.name)”？"
        }
    }

    func title(using l10n: AppLocalizer) -> String {
        switch self {
        case .wallpaper(let item): return l10n("从素材库移除“\(item.name)”？")
        case .playlist(let playlist): return l10n("删除播放列表“\(playlist.name)”？")
        }
    }

    var actionTitle: String {
        switch self {
        case .wallpaper: return "移除壁纸"
        case .playlist: return "删除播放列表"
        }
    }

    var message: String {
        switch self {
        case .wallpaper(let item):
            return item.origin == nil ? "将从素材库和所有播放列表中移除此壁纸，原文件不会删除。"
                : "将从素材库和所有播放列表中移除此壁纸，并删除托管副本；原文件不会删除。"
        case .playlist: return "正在使用此播放列表的显示器会恢复系统壁纸，素材库中的壁纸和原文件不变。"
        }
    }

    @MainActor
    func confirm(in model: AppModel) {
        switch self {
        case .wallpaper(let item): model.removeMedia(item.id)
        case .playlist(let playlist): model.deletePlaylist(playlist.id)
        }
    }
}

struct LibraryRemovalConfirmation: ViewModifier {
    @Localized private var l10n
    @Binding var removal: LibraryRemoval?
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.confirmationDialog(removal?.title(using: l10n) ?? l10n("确认移除？"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), titleVisibility: .visible, presenting: removal) { removal in
            Button(l10n("取消"), role: .cancel) { self.removal = nil }
            Button(l10n.text(removal.actionTitle), role: .destructive) { removal.confirm(in: model); self.removal = nil }
        } message: { removal in Text(l10n.text(removal.message)) }
    }
}
