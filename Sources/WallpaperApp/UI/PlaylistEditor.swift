import SwiftUI
import WallpaperCore

struct PlaylistEditor: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let playlist: Playlist
    @State private var name = ""
    @State private var displayID = "all"
    @State private var fit = ContentFit.fill
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(l10n("播放列表名称"), text: $name).font(.title2.weight(.semibold)).textFieldStyle(.plain)
                        .onSubmit { change { $0.name = name } }
                    Button(l10n("重命名")) { change { $0.name = name } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == playlist.name)
                        .appGlassControlStyle()
                        .tint(AppColors.secondaryActionText)
                }
                HStack(spacing: 6) {
                    Text(l10n("\(playlist.entries.count) 项壁纸")).font(.caption).foregroundStyle(.secondary)
                    HelpPopover(title: l10n("排序与编辑"), message: WallpaperCopy.sortingHelp)
                }
                HStack {
                    Picker(l10n("播放模式"), selection: Binding(get: { playlist.mode }, set: { value in change { $0.mode = value } })) {
                        ForEach(PlaybackMode.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) }
                    }.labelsHidden()
                    Spacer()
                    Text(l10n("过渡")).font(.caption).foregroundStyle(.secondary)
                    HelpPopover(title: l10n("过渡"), message: playlist.transition == 0 ? l10n("画面与声音直接切换。") : WallpaperCopy.transitionHelp)
                    Picker(l10n("过渡"), selection: Binding(get: { playlist.transition }, set: { value in change { $0.transition = value } })) {
                        Text(l10n("直接切换")).tag(0.0)
                        Text(l10n("渐变 · 0.3 秒")).tag(0.3)
                        Text(l10n("渐变 · 0.8 秒")).tag(0.8)
                    }.labelsHidden().frame(width: 150)
                }
            }.padding(.horizontal, 24).padding(.top, 24)
            BatchToolbar(model: model).padding(.horizontal, 24)
            if playlist.entries.isEmpty {
                EmptyState(l10n("播放列表中还没有壁纸"), subtitle: l10n("从素材库添加壁纸，或点击“导入壁纸”。")) {
                    Image(systemName: "rectangle.stack")
                } actions: {
                    HStack(spacing: 12) {
                        Button(l10n("导入壁纸")) { model.importFiles() }
                            .disabled(model.importing || model.loadFailed || model.isShuttingDown)
                        Menu {
                            ForEach(model.library.media) { item in Button(item.name) { model.add(item.id, to: playlist.id) } }
                        } label: {
                            Text(l10n("从素材库添加")).foregroundStyle(AppColors.secondaryActionText)
                        }.buttonStyle(.bordered)
                    }
                }.frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.batchSelection.isActive ? nil : model.selectedEntryID },
                                        set: { if !model.batchSelection.isActive { model.selectedEntryID = $0 } })) {
                    ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                        if let item = model.library.media.first(where: { $0.id == entry.mediaID }) {
                            entryRow(index: index, entry: entry, item: item).tag(entry.id)
                                .selectionRowStyle(isSelected: model.batchSelection.isActive
                                    ? model.batchSelection.ids.contains(entry.id) : model.selectedEntryID == entry.id)
                        }
                    }.onMove(perform: model.batchSelection.isActive ? nil : { source, destination in
                        change { $0.entries.move(fromOffsets: source, toOffset: destination) }
                    })
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
            VStack(spacing: 12) {
                HStack {
                    Menu(l10n("添加壁纸"), systemImage: "plus") {
                        ForEach(model.library.media) { item in Button(item.name) { model.add(item.id, to: playlist.id) } }
                    }
                    Spacer()
                    Picker(l10n("显示方式"), selection: $fit) {
                        ForEach(ContentFit.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) }
                    }.frame(width: 185)
                    HelpPopover(title: l10n("显示方式"), message: fit.helpText)
                }
                HStack {
                    Picker(l10n("显示器"), selection: $displayID) {
                        Text(l10n("全部显示器 · 同步")).tag("all")
                        ForEach(model.displays) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                    Button {
                        model.applyPlaylist(playlist.id, displayID: displayID == "all" ? nil : displayID, fit: fit)
                    } label: {
                        Label(l10n("应用播放列表"), systemImage: "play.fill")
                    }.appGlassOutlinedButtonStyle().disabled(playlist.entries.isEmpty)
                    Button { _ = model.bindScreenSaver(.playlist(playlist.id)) } label: {
                        Label(l10n("用于屏保"), systemImage: "sparkles.tv")
                    }
                    .disabled(playlist.entries.isEmpty || model.screenSaver == nil || model.loadFailed || model.isShuttingDown)
                }
            }.padding(.horizontal, 24).padding(.bottom, 20)
        }.onAppear { name = playlist.name }
            .onChange(of: playlist.id) { _, _ in name = playlist.name }
    }
    private func entryRow(index: Int, entry: PlaylistEntry, item: MediaItem) -> some View {
        HStack(spacing: 12) {
            if model.batchSelection.isActive {
                Toggle(l10n("选择 \(item.name)"), isOn: Binding(get: { model.batchSelection.ids.contains(entry.id) },
                    set: { _ in model.batchSelection.toggle(entry.id) })).labelsHidden().toggleStyle(.checkbox)
            }
            Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22)
            ThumbnailView(item: item, lifetime: model.thumbnails).frame(width: 78, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).lineLimit(1)
                Text(timingLabel(entry, item: item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.batchSelection.isActive {
                VStack(spacing: 4) {
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        .help(l10n("上移")).accessibilityLabel(l10n("上移"))
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == playlist.entries.count - 1)
                        .help(l10n("下移")).accessibilityLabel(l10n("下移"))
                }.font(.system(size: 9)).buttonStyle(.borderless)
                Button { change { $0.entries.removeAll { $0.id == entry.id } } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(l10n("从当前播放列表移除")).accessibilityLabel(l10n("从当前播放列表移除"))
            }
        }.padding(.vertical, 6)
    }
    private func change(_ update: (inout Playlist) -> Void) { var changed = playlist; update(&changed); model.updatePlaylist(changed) }
    private func move(_ index: Int, by offset: Int) { change { $0.entries.swapAt(index, index + offset) } }
    private func timingLabel(_ entry: PlaylistEntry, item: MediaItem) -> String {
        switch entry.timing.mode {
        case .seconds:
            let unit = EntryDurationUnit.preferred(for: entry.timing.seconds)
            let value = unit.value(for: entry.timing.seconds)
                .formatted(.number.precision(.fractionLength(0...2)).locale(l10n.locale))
            return l10n("停留 \(value) \(unit.rawValue)")
        case .full: return l10n("完整播放 · \(entry.timing.duration(mediaDuration: item.duration).formatted(.number.precision(.fractionLength(0...2)).locale(l10n.locale))) 秒")
        case .loops: return l10n("循环 \(entry.timing.loops) 次")
        }
    }
}
