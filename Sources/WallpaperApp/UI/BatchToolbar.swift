import SwiftUI
import WallpaperCore

struct BatchEditTarget: Identifiable {
    let id = UUID()
    let playlistID: UUID
    let entryIDs: Set<UUID>
}

private struct BatchRemoval: Identifiable {
    let id = UUID()
    let operation: BatchOperation
    let count: Int
    let isLibrary: Bool
}

struct BatchToolbar: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @State private var editing: BatchEditTarget?
    @State private var removal: BatchRemoval?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassControlGroup {
                HStack {
                    if model.batchSelection.isActive {
                        Text(l10n("已选 \(model.batchSelection.ids.count) 项")).font(.caption.monospacedDigit())
                        Spacer()
                        Button(l10n("全选当前结果")) { model.batchSelection.selectAll(model.visibleBatchIDs) }
                        Button(l10n("清空选择")) { model.batchSelection.clear() }.disabled(model.batchSelection.ids.isEmpty)
                        Button(l10n("完成")) { model.batchSelection.finish() }
                    } else {
                        Spacer()
                        Button(l10n("批量选择")) { model.batchSelection.start() }
                            .disabled(model.visibleBatchIDs.isEmpty || model.loadFailed)
                    }
                }
            }.appGlassControlStyle().tint(AppColors.secondaryActionText)
            if model.batchSelection.isActive {
                HStack {
                    if let list = model.selectedPlaylist {
                        Button(l10n("批量编辑…")) { editing = BatchEditTarget(playlistID: list.id, entryIDs: model.batchSelection.ids) }
                            .tint(AppColors.secondaryActionText)
                    } else {
                        Menu(l10n("加入播放列表")) {
                            ForEach(model.library.playlists) { list in
                                Button(list.name) { model.performBatch(.addMedia(ids: model.batchSelection.ids, playlistID: list.id)) }
                            }
                        }.disabled(model.library.playlists.isEmpty)
                        Menu(l10n("收藏")) {
                            Button(l10n("收藏")) { model.performBatch(.favoriteMedia(ids: model.batchSelection.ids, value: true)) }
                            Button(l10n("取消收藏")) { model.performBatch(.favoriteMedia(ids: model.batchSelection.ids, value: false)) }
                        }
                    }
                    Spacer()
                    Button(l10n("移除…"), role: .destructive) {
                        let ids = model.batchSelection.ids
                        let operation: BatchOperation = model.selectedPlaylist.map { .removeEntries(playlistID: $0.id, ids: ids) } ?? .removeMedia(ids: ids)
                        removal = BatchRemoval(operation: operation, count: ids.count, isLibrary: model.selectedPlaylist == nil)
                    }
                }.disabled(model.batchSelection.ids.isEmpty || model.loadFailed)
            }
        }
        .controlSize(.small)
        .sheet(item: $editing) { target in
            BatchEntryEditor(model: model, target: target).appInterfacePreferences(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelPendingPresentationsForQuit)) { _ in
            removal = nil
        }
        .alert(l10n("移除选中的 \(removal?.count ?? 0) 项？"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        ), presenting: removal) { target in
            Button(l10n("取消"), role: .cancel) { removal = nil }
            Button(l10n("移除"), role: .destructive) { model.performBatch(target.operation); removal = nil }
        } message: { target in
            Text(target.isLibrary ? l10n("将从素材库和所有播放列表中移除所选壁纸，并删除托管副本；原文件不会删除。") : l10n("仅从当前播放列表移除所选条目，素材库中的壁纸和原文件不变。"))
        }
    }
}
