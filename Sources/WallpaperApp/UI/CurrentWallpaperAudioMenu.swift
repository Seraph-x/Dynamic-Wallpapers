import SwiftUI
import WallpaperCore

struct CurrentWallpaperAudioMenu: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @State private var selectedTargetID: CurrentWallpaperAudioTarget.ID?

    var body: some View {
        let targets = model.currentWallpaperAudioTargets
        if let target = selectedTarget(in: targets) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n("当前壁纸声音")).font(.headline)
                if targets.count > 1 {
                    Picker(l10n("当前壁纸声音"), selection: Binding(
                        get: { Optional(target.id) },
                        set: { selectedTargetID = $0 })) {
                        ForEach(targets) { candidate in
                            Text(title(for: candidate)).tag(Optional(candidate.id))
                        }
                    }
                    .labelsHidden()
                } else {
                    Text(title(for: target)).font(.caption).foregroundStyle(.secondary)
                }
                controls(for: target)
            }
            .onAppear { selectedTargetID = target.id }
            .onChange(of: targets.map(\.id)) { _, ids in
                if selectedTargetID.map({ ids.contains($0) }) != true { selectedTargetID = ids.first }
            }
            .disabled(model.loadFailed || model.isShuttingDown)
        }
    }

    @ViewBuilder
    private func controls(for target: CurrentWallpaperAudioTarget) -> some View {
        Toggle(l10n("此项静音"), isOn: Binding(
            get: { currentTarget(target.id)?.audio.isMuted ?? target.audio.isMuted },
            set: { muted in
                var audio = currentTarget(target.id)?.audio ?? target.audio
                audio.isMuted = muted
                update(audio, targetID: target.id)
            })).toggleStyle(.checkbox)
        Slider(value: Binding(
            get: { currentTarget(target.id)?.audio.volume ?? target.audio.volume },
            set: { volume in
                var audio = currentTarget(target.id)?.audio ?? target.audio
                audio.volume = volume
                update(audio, targetID: target.id)
            }), in: 0...1, step: 0.01)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel(l10n("音量"))
    }

    private func selectedTarget(in targets: [CurrentWallpaperAudioTarget]) -> CurrentWallpaperAudioTarget? {
        selectedTargetID.flatMap { id in targets.first { $0.id == id } } ?? targets.first
    }

    private func title(for target: CurrentWallpaperAudioTarget) -> String {
        "\(target.playlistName ?? l10n("单张壁纸")) · \(target.mediaName)"
    }

    private func currentTarget(_ id: CurrentWallpaperAudioTarget.ID) -> CurrentWallpaperAudioTarget? {
        model.currentWallpaperAudioTargets.first { $0.id == id }
    }

    private func update(_ audio: AudioSettings, targetID: CurrentWallpaperAudioTarget.ID) {
        guard !model.updateCurrentWallpaperAudio(audio, targetID: targetID),
              let failure = model.failure else { return }
        model.failure = nil
        FailureAlert.present(PresentedFailure(title: l10n("无法保存当前壁纸声音设置"),
            summary: failure.summary, diagnostics: failure.diagnostics), localizer: l10n)
    }
}
