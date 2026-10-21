import SwiftUI
import WallpaperCore

struct EntryAudioEditor: View {
    @Localized private var l10n
    let audio: AudioSettings
    let globallyMuted: Bool
    let helpText: String
    let onChange: (AudioSettings) -> Void

    init(audio: AudioSettings, globallyMuted: Bool, helpText: String = WallpaperCopy.entryAudioHelp,
         onChange: @escaping (AudioSettings) -> Void) {
        self.audio = audio; self.globallyMuted = globallyMuted
        self.helpText = helpText; self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("此项声音")).font(.subheadline.weight(.medium))
            Toggle(l10n("此项静音"), isOn: Binding(get: { audio.isMuted }, set: { value in
                var updated = audio; updated.isMuted = value; onChange(updated)
            }))
            HStack(spacing: 6) {
                Text(l10n("音量")).font(.caption)
                HelpPopover(title: l10n("音量"), message: helpText)
                Slider(value: Binding(get: { audio.volume }, set: { value in
                    var updated = audio; updated.volume = value; onChange(updated)
                }), in: 0...1, step: 0.01)
                Text("\(Int((audio.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
            }
            if globallyMuted {
                Label(l10n("全局静音已开启，此项及其预览均静音。"), systemImage: "speaker.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
