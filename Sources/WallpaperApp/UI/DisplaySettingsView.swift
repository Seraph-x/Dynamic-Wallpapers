import SwiftUI
import WallpaperCore

struct DisplaySettingsView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(l10n("显示器")).font(.title2.weight(.semibold))
                ForEach(model.displays) { display in
                    DisplayCard(model: model, display: display)
                }
            }.padding(24)
        }
    }
}

private struct DisplayCard: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @Environment(\.appPalette) private var palette
    let display: DisplayInfo
    @State private var selection: DisplaySource.Identity?
    @State private var fit = ContentFit.fill
    private var binding: DisplayBinding? { model.library.displays.first { $0.id == display.id } }
    private var directItem: MediaItem? {
        guard let mediaID = binding?.source.mediaID else { return nil }
        return model.library.media.first { $0.id == mediaID }
    }
    private var applicationTitle: String {
        if case .media = selection { return l10n("应用显示方式") }
        return l10n("应用播放列表")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 34)).foregroundStyle(palette.brandAccent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(display.name).font(.headline)
                    Text(display.size).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(binding == nil ? l10n("系统壁纸") : l10n("自定义壁纸")).font(.caption).foregroundStyle(.secondary)
            }
            if let directItem { Text(l10n("单张壁纸 · \(directItem.name)")).font(.subheadline) }
            if let binding {
                Text(l10n.playbackStatus(model.statuses[binding.groupID] ?? "正在准备壁纸…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            sourcePicker
            if let binding, let directItem, directItem.supportsAudio,
               selection == .media(directItem.id), case .media(_, let audio) = binding.source {
                EntryAudioEditor(audio: audio, globallyMuted: model.library.settings.isMuted,
                                 helpText: WallpaperCopy.displayAudioHelp) {
                    model.updateDirectAudio($0, groupID: binding.groupID)
                }
            }
            HStack {
                Picker(l10n("显示方式"), selection: $fit) {
                    ForEach(ContentFit.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) }
                }
                HelpPopover(title: l10n("显示方式"), message: fit.helpText)
            }
            HStack {
                if let binding {
                    Button(l10n("下一张壁纸")) { model.next(groupID: binding.groupID) }
                        .disabled(!model.canAdvance(groupID: binding.groupID)).tint(AppColors.secondaryActionText)
                }
                Spacer()
                Button(action: applySelection) { Text(applicationTitle) }
                    .appGlassOutlinedButtonStyle().disabled(selection == nil || model.loadFailed || model.isShuttingDown)
            }
            if binding != nil {
                Button(l10n("恢复系统壁纸")) { model.stopDisplay(display.id) }
                    .font(.caption).buttonStyle(.borderless).tint(AppColors.secondaryActionText)
            }
        }.padding(20).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            .onAppear { selection = binding?.source.identity; fit = binding?.fit ?? .fill }
            .onChange(of: binding?.source.identity) { _, value in selection = value }
            .onChange(of: binding?.fit) { _, value in fit = value ?? .fill }
            .onChange(of: model.library.playlists.map(\.id)) { _, ids in
                if case .playlist(let id) = selection, !ids.contains(id) { selection = nil }
            }
    }

    private var sourcePicker: some View {
        Picker(l10n("播放来源"), selection: $selection) {
            Text(l10n("选择播放列表")).tag(Optional<DisplaySource.Identity>.none)
            if let directItem {
                Text(l10n("单张壁纸 · \(directItem.name)")).tag(Optional(DisplaySource.Identity.media(directItem.id)))
            }
            ForEach(model.library.playlists) { Text($0.name).tag(Optional(DisplaySource.Identity.playlist($0.id))) }
        }
    }

    private func applySelection() {
        switch selection {
        case .playlist(let id): model.applyPlaylist(id, displayID: display.id, fit: fit)
        case .media(let id):
            guard let item = directItem, item.id == id, case .media(_, let audio) = binding?.source else {
                model.report(WallpaperError(l10n("此单张壁纸已停止或更换，请重新选择。"))); return
            }
            model.applyMedia(item, displayID: display.id, fit: fit, audio: audio)
        case nil: break
        }
    }
}
