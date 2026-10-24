import SwiftUI
import WallpaperCore

struct BatchEntryEditor: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let target: BatchEditTarget
    @Environment(\.dismiss) private var dismiss
    @State var draft = BatchEntryDraft()
    @State private var saveFailure: PresentedFailure?

    private var selectedMedia: [MediaItem] {
        let entries = model.library.playlists.first { $0.id == target.playlistID }?.entries ?? []
        let ids = Set(entries.filter { target.entryIDs.contains($0.id) }.map(\.mediaID))
        return model.library.media.filter { ids.contains($0.id) }
    }
    private var hasWeb: Bool { selectedMedia.contains { $0.kind == .web || $0.kind == .scene } }
    private var audioCount: Int {
        let ids = Set(selectedMedia.filter(\.supportsAudio).map(\.id))
        return model.library.playlists.first { $0.id == target.playlistID }?.entries.filter {
            target.entryIDs.contains($0.id) && ids.contains($0.mediaID)
        }.count ?? 0
    }
    private var validationMessage: String? {
        do { _ = try draft.patch(hasVideo: audioCount > 0, hasWeb: hasWeb); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n("批量编辑 \(target.entryIDs.count) 项")).font(.title2.weight(.semibold))
            Text(l10n("仅修改勾选的设置。")).font(.callout).foregroundStyle(.secondary)
            Form {
                Section {
                    Toggle(l10n("修改停留时长"), isOn: $draft.changeTiming)
                        .accessibilityIdentifier("batch-change-timing")
                    if draft.changeTiming {
                        Picker(l10n("方式"), selection: $draft.mode) {
                            Text(l10n("固定时间")).tag(TimingMode.seconds)
                            if !hasWeb {
                                Text(l10n("完整播放一次")).tag(TimingMode.full)
                                Text(l10n("指定循环次数")).tag(TimingMode.loops)
                            }
                        }
                        HStack(spacing: 6) {
                            TextField(l10n("停留时长"), text: $draft.durationValue)
                            Picker(l10n("单位"), selection: $draft.durationUnit) {
                                ForEach(EntryDurationUnit.allCases, id: \.self) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }.labelsHidden().pickerStyle(.menu).frame(width: 80)
                            HelpPopover(title: l10n("停留时长"), message: WallpaperCopy.imageTimingHelp)
                        }
                        if draft.mode == .loops {
                            TextField(l10n("循环次数"), text: $draft.loops)
                        }
                        if hasWeb { Text(l10n("包含网页或场景时，仅支持固定停留时长。")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section(l10n("声音设置（适用于 \(audioCount) 项）")) {
                    Text(l10n("声音设置仅适用于所选视频、网页和场景，图片与动图不受影响。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(l10n("修改静音"), isOn: $draft.changeMute).disabled(audioCount == 0)
                    if draft.changeMute { Toggle(l10n("所选项静音"), isOn: $draft.muted) }
                    Toggle(l10n("修改音量"), isOn: $draft.changeVolume).disabled(audioCount == 0)
                    if draft.changeVolume {
                        HStack {
                            Slider(value: $draft.volume, in: 0...1, step: 0.01)
                            Text("\(Int((draft.volume * 100).rounded()))%").monospacedDigit().frame(width: 45)
                        }
                    }
                    if model.library.settings.isMuted {
                        Label(l10n("全局静音已开启，修改声音设置不会解除静音。"), systemImage: "speaker.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            if let saveFailure {
                FailureNotice(failure: saveFailure)
            } else if let message = validationMessage {
                Text(l10n.text(message)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(l10n("取消"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .tint(AppColors.secondaryActionText)
                Button(l10n("保存修改")) {
                    do {
                        let patch = try draft.patch(hasVideo: audioCount > 0, hasWeb: hasWeb)
                        if model.performBatch(.editEntries(playlistID: target.playlistID, ids: target.entryIDs, patch: patch)) { dismiss() }
                        else { saveFailure = model.failure; model.failure = nil }
                    } catch { saveFailure = PresentedFailure(error, context: .save) }
                }.appGlassOutlinedButtonStyle().keyboardShortcut(.defaultAction).disabled(validationMessage != nil)
            }
        }.padding(24).frame(width: 500, height: 600)
            .appGlassPresentation(appearance: model.library.settings.appearance)
    }
}
