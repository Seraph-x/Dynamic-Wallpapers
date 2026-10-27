import SwiftUI
import WallpaperCore

struct InspectorView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @State private var displayID = "all"
    @State private var fit = ContentFit.fill
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(l10n("壁纸详情")).font(.headline)
                if let selection = model.inspectorSelection {
                    InspectorDetails(model: model, selection: selection, displayID: $displayID, fit: $fit)
                        .id(selection.id)
                }
                Spacer(minLength: 20)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector-content")
        }
        .onChange(of: model.selectedMedia?.id, initial: true) { _, _ in
            model.inspectorMedia.select(model.selectedMedia)
            model.scenePropertyEditor.select(model.selectedMedia)
        }
        .onDisappear {
            if !model.isShuttingDown { model.inspectorMedia.select(nil); model.scenePropertyEditor.select(nil) }
        }
        .accessibilityIdentifier("wallpaper-inspector")
    }
}

private struct InspectorDetails: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let selection: InspectorSelection
    @Binding var displayID: String
    @Binding var fit: ContentFit
    @State private var previewing = false
    @State private var directAudio = AudioSettings()
    @State private var editingName = false
    @State private var nameDraft = ""
    private var item: MediaItem { selection.item }
    private var isPlaylistEntry: Bool {
        if case .playlist = selection.context { return true }
        return false
    }
    private var playbackAudio: AudioSettings { isPlaylistEntry ? selection.audio : directAudio }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(selection.sourceTitle(using: l10n))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("inspector-source")
            InspectorMediaPreview(model: model, selection: selection, audio: playbackAudio, inspection: model.inspectorMedia,
                                  previewing: $previewing,
                                  desktopTarget: DesktopPreviewTarget(displayID: displayID == "all" ? nil : displayID, fit: fit))
            metadata
            if item.backend == .scene {
                Divider()
                InspectorScenePropertiesView(editor: model.scenePropertyEditor)
            }
            Divider()
            displayOptions
            Divider()
            commonActions
            if case .playlist(let playlist, let entry) = selection.context {
                Divider()
                if item.supportsAudio {
                    EntryAudioEditor(audio: entry.audio, globallyMuted: model.library.settings.isMuted) {
                        model.updateEntryAudio($0, playlistID: playlist.id, entryID: entry.id)
                    }
                    Divider()
                }
                EntryTimingEditor(timing: entry.timing, isStatic: item.kind == .image, isWeb: item.kind == .web || item.kind == .scene) {
                    saveTiming($0, playlistID: playlist.id, entryID: entry.id)
                }
            }
        }
        .onDisappear { previewing = false }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editingName {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(l10n("壁纸名称"), text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveName)
                    Button(l10n("保存修改"), systemImage: "checkmark") { saveName() }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.defaultAction)
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(l10n("取消"), systemImage: "xmark") { editingName = false }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.cancelAction)
                }
            } else {
                Button {
                    nameDraft = item.name
                    editingName = true
                } label: {
                    Text(item.name)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(l10n("重命名"))
            }
            Text(item.kind == .scene ? l10n("本地场景 · WebGL") : item.kind == .web ? l10n("本地网页 · HTML") : "\(item.width) × \(item.height) · \(item.url.pathExtension.uppercased())")
                .font(.caption).foregroundStyle(.secondary)
            if let duration = item.duration {
                Text(l10n("单次播放时长 \(duration.formatted(.number.precision(.fractionLength(2)).locale(l10n.locale))) 秒"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.kind == .scene {
                Text(l10n("暂停时保留场景，继续播放时从原位置恢复。")) .font(.caption).foregroundStyle(.secondary)
            }
            if item.kind == .web {
                Text(l10n("暂停时保留画面，继续播放时重新载入网页。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveName() {
        if model.renameMedia(item.id, name: nameDraft) { editingName = false }
    }

    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(l10n("显示方式")).font(.subheadline.weight(.medium))
                HelpPopover(title: l10n("显示方式"), message: fit.helpText)
            }
            Picker(l10n("显示器"), selection: $displayID) {
                Text(l10n("全部显示器 · 同步")).tag("all")
                ForEach(model.displays) { Text($0.name).tag($0.id) }
            }
            Picker(l10n("显示方式"), selection: $fit) {
                ForEach(ContentFit.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) }
            }.pickerStyle(.segmented)
            if !isPlaylistEntry, item.supportsAudio {
                EntryAudioEditor(audio: directAudio, globallyMuted: model.library.settings.isMuted,
                                 helpText: WallpaperCopy.directAudioHelp) { directAudio = $0 }
            }
            Button {
                model.applyMedia(item, displayID: displayID == "all" ? nil : displayID, fit: fit, audio: playbackAudio)
            } label: {
                Label(l10n("应用壁纸"), systemImage: "desktopcomputer").frame(maxWidth: .infinity)
            }.appGlassOutlinedButtonStyle().controlSize(.large)
        }
    }

    private var commonActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(item.isFavorite ? l10n("取消收藏") : l10n("收藏"), systemImage: item.isFavorite ? "heart.fill" : "heart") {
                model.favorite(item.id)
            }
            Menu {
                ForEach(model.library.playlists) { playlist in
                    Button(playlistTitle(playlist)) { model.add(item.id, to: playlist.id) }
                }
            } label: { Label(l10n("加入播放列表"), systemImage: "text.badge.plus") }
                .disabled(model.library.playlists.isEmpty)
            if model.library.playlists.isEmpty {
                Text(l10n("请先新建播放列表")).font(.caption).foregroundStyle(.secondary)
            }
            Button(l10n("在 Finder 中显示"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(l10n("用于屏保"), systemImage: "sparkles.tv") { _ = model.bindScreenSaver(.media(item.id)) }
                .disabled(model.screenSaver == nil || model.loadFailed || model.isShuttingDown)
            InspectorTranscodeAction(model: model, inspection: model.inspectorMedia, item: item)
        }.buttonStyle(.borderless).font(.callout).tint(AppColors.secondaryActionText)
    }

    private func playlistTitle(_ playlist: Playlist) -> String {
        if case .playlist(let current, _) = selection.context, playlist.id == current.id {
            return l10n("\(playlist.name)（当前播放列表，再次添加）")
        }
        return playlist.name
    }

    private func saveTiming(_ timing: EntryTiming, playlistID: UUID, entryID: UUID) {
        guard var playlist = model.library.playlists.first(where: { $0.id == playlistID }),
              let index = playlist.entries.firstIndex(where: { $0.id == entryID && $0.mediaID == item.id }) else {
            model.report(WallpaperError(l10n("播放列表条目已不存在，无法保存时长。"))); return
        }
        playlist.entries[index].timing = timing
        model.updatePlaylist(playlist)
    }
}

private struct EntryTimingEditor: View {
    @Localized private var l10n
    @State var timing: EntryTiming
    @State private var unit: EntryDurationUnit
    let isStatic: Bool
    let isWeb: Bool
    let onChange: (EntryTiming) -> Void

    init(timing: EntryTiming, isStatic: Bool, isWeb: Bool, onChange: @escaping (EntryTiming) -> Void) {
        _timing = State(initialValue: timing)
        _unit = State(initialValue: .preferred(for: timing.seconds))
        self.isStatic = isStatic
        self.isWeb = isWeb
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(l10n("停留时长")).font(.subheadline.weight(.medium))
                if isStatic { HelpPopover(title: l10n("停留时长"), message: WallpaperCopy.imageTimingHelp) }
            }
            if !isWeb { Picker(l10n("方式"), selection: $timing.mode) {
                Text(l10n("固定时间")).tag(TimingMode.seconds)
                Text(l10n("完整播放一次")).tag(TimingMode.full)
                Text(l10n("指定循环次数")).tag(TimingMode.loops)
            } }
            if timing.mode == .seconds || isStatic {
                HStack {
                    TextField(l10n("停留时长"), value: durationValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                    Picker(l10n("单位"), selection: $unit) {
                        ForEach(EntryDurationUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 80)
                }
            }
            if timing.mode == .loops { Stepper(l10n("\(timing.loops) 次"), value: $timing.loops, in: 1...Int.max) }
            Button(l10n("保存时长")) { onChange(timing) }.disabled(!timing.seconds.isFinite || timing.seconds <= 0 || timing.loops <= 0)
                .tint(AppColors.secondaryActionText)
        }
    }

    private var durationValue: Binding<Double> {
        Binding(get: { unit.value(for: timing.seconds) },
                set: { timing.seconds = unit.seconds(for: $0) })
    }
}
