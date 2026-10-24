import SwiftUI

struct SystemAudioSpectrumSettingsSection: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject private var controller: SystemAudioSpectrumController

    init(model: AppModel) {
        self.model = model
        controller = model.webRuntime.systemAudioSpectrum
    }

    var body: some View {
        Toggle(l10n("系统音频响应"), isOn: Binding(
            get: { model.library.settings.systemAudioSpectrumEnabled },
            set: { value in model.mutate { $0.settings.systemAudioSpectrumEnabled = value } }))
            .disabled(!controller.supported || model.loadFailed || model.isShuttingDown)
            .accessibilityIdentifier("system-audio-spectrum-toggle")
        Text(status).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("system-audio-spectrum-status")
        Text(l10n("仅在场景播放时分析系统声音，不录制文件、不上传、不使用麦克风。壁纸静音不影响音频响应。"))
            .font(.caption).foregroundStyle(.secondary)
        if let error = controller.failure {
            FailureNotice(failure: PresentedFailure(error))
            Button(l10n("重试系统音频响应")) { controller.retry() }
                .disabled(model.isShuttingDown)
                .accessibilityIdentifier("system-audio-spectrum-retry")
        }
    }

    private var status: String {
        switch controller.status {
        case .unsupported: l10n("系统音频响应需要 macOS 14.2 或更新版本。")
        case .disabled: l10n("系统音频响应已关闭。")
        case .waiting: l10n("等待场景播放，尚未采集系统音频。")
        case .starting: l10n("正在启动系统音频采集，请允许系统音频录制权限。")
        case .capturing: l10n("正在分析系统音频。")
        case .failed: l10n("系统音频响应已停止，请查看错误并重试。")
        }
    }
}
