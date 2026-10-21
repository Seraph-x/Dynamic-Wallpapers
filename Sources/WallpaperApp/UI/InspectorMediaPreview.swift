import SwiftUI
import WallpaperCore

struct InspectorMediaPreview: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let selection: InspectorSelection
    let audio: AudioSettings
    @ObservedObject var inspection: InspectorMediaModel
    @Binding var previewing: Bool
    let desktopTarget: DesktopPreviewTarget
    private var item: MediaItem { selection.item }
    private var matchesSource: Bool { inspection.source?.id == item.id }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if previewing {
                    LivePreview(item: item, audio: audio, globallyMuted: model.library.settings.isMuted,
                                lifetime: model.previewLifetime, onError: { model.report($0, context: .preview) },
                                desktopTarget: desktopTarget, onStop: { previewing = false })
                        .id(desktopTarget)
                } else {
                    ThumbnailContent(item: item, image: matchesSource ? inspection.image : nil,
                                     error: matchesSource ? inspection.errorMessage : nil)
                }
            }.aspectRatio(16 / 10, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
            Group {
                Button(previewing ? l10n("停止预览") : l10n("播放预览"), systemImage: previewing ? "stop.fill" : "play.fill") {
                    previewing.toggle()
                }
                .buttonStyle(.borderless).font(.caption).tint(AppColors.secondaryActionText)
                .disabled(model.isShuttingDown || (!previewing && (!canPreview || !model.pauseReasons.isEmpty)))
                .help(l10n("同时在详情栏和所选显示器预览；停止后恢复原壁纸。"))
                if previewing {
                    Text(item.supportsAudio ? previewAudioStatus : l10n("预览中"))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("preview-playback-status")
                }
            }
            if matchesSource, inspection.isChecking {
                ProgressView(l10n("正在检查壁纸…")).controlSize(.small).font(.caption)
            } else if matchesSource, let failure = inspection.failure {
                VStack(alignment: .leading, spacing: 8) {
                    FailureNotice(failure: failure)
                    Button(l10n("重新检查"), action: inspection.retry)
                        .buttonStyle(.borderless).font(.caption).tint(AppColors.secondaryActionText)
                        .disabled(model.isShuttingDown)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var canPreview: Bool {
        matchesSource && !inspection.isChecking && inspection.errorMessage == nil && inspection.transcodeReason == nil
    }

    private var previewAudioStatus: String {
        if model.library.settings.isMuted { return l10n("预览中 · 全局静音") }
        if audio.isMuted { return l10n("预览中 · 此项静音") }
        return l10n("预览中 · 音量 \(Int((audio.volume * 100).rounded()))%")
    }
}

struct InspectorTranscodeAction: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject var inspection: InspectorMediaModel
    let item: MediaItem
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if inspection.source?.id == item.id, let reason = inspection.transcodeReason {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.text(reason)).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Button(l10n("转码…"), systemImage: "arrow.triangle.2.circlepath") {
                        model.transcoding.select(item)
                        openWindow(id: "transcode")
                    }.disabled(model.isShuttingDown)
                    Text(l10n("转为兼容性更好的 H.264 MP4"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
