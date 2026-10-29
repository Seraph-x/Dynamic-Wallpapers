import SwiftUI
import WallpaperCore
import WallpaperMediaIntegration

struct SystemMediaSettingsSection: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject private var controller: SystemMediaController
    @ObservedObject private var artwork: SystemMediaArtworkController
    @ObservedObject private var owner: SceneMediaSessionOwner
    @State private var sourceSaveFailure: PresentedFailure?

    init(model: AppModel) {
        self.model = model
        let controller = model.webRuntime.systemMedia
        self.controller = controller
        artwork = controller.artwork
        owner = model.webRuntime.sceneMedia
    }

    var body: some View {
        Picker(l10n("播放器来源"), selection: Binding(
            get: { model.library.settings.systemMediaSource },
            set: { value in
                if model.mutate({ $0.settings.systemMediaSource = value }) { sourceSaveFailure = nil }
                else { sourceSaveFailure = model.failure }
            })) {
                Text(l10n("关闭媒体集成")).tag(SystemMediaSource.disabled)
                Text(verbatim: "Music").tag(SystemMediaSource.music)
                Text(verbatim: "Spotify").tag(SystemMediaSource.spotify)
            }
            .pickerStyle(.radioGroup)
            .disabled(!canEdit)
            .accessibilityIdentifier("system-media-source")
        if let sourceSaveFailure {
            Text(l10n("媒体来源未保存。")).font(.caption)
            FailureNotice(failure: sourceSaveFailure)
        }
        Text(l10n("播放中的场景可读取并控制所选的已运行播放器，请仅使用你信任的场景。选择来源不会弹出授权提示；请点击“授权播放器”以请求权限。"))
            .font(.caption).foregroundStyle(.secondary)
        Text(l10n("封面由播放器提供；歌词和封面配色不可用。"))
            .font(.caption).foregroundStyle(.secondary)
        Text(status).font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("system-media-status")
        if controller.source != .disabled {
            HStack {
                Button(l10n("授权播放器")) {
                    Task { @MainActor in guard canEdit else { return }; await controller.authorize() }
                }.accessibilityIdentifier("system-media-authorize")
                Button(l10n("重试媒体信息")) {
                    Task { @MainActor in guard canEdit else { return }; await controller.retry() }
                }.accessibilityIdentifier("system-media-retry")
            }.disabled(!canEdit || controller.status == .checking)
        }
        if let error = controller.failure { FailureNotice(failure: PresentedFailure(error)) }
        if !owner.failures.isEmpty {
            Text(l10n("场景媒体操作失败。")).font(.caption)
            ForEach(owner.failures.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                if let error = owner.failures[id] { FailureNotice(failure: PresentedFailure(error)) }
            }
        }
        if controller.snapshot != nil { artworkStatus }
        if !owner.artworkFailures.isEmpty {
            Text(l10n("场景封面显示失败，播放信息仍可用。")).font(.caption)
            ForEach(owner.artworkFailures.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                if let message = owner.artworkFailures[id] {
                    FailureNotice(failure: PresentedFailure(WallpaperError(message)))
                }
            }
        }
        if artworkFailed || !owner.artworkFailures.isEmpty {
            Button(l10n("重试封面")) {
                Task { @MainActor in guard canEdit else { return }; await owner.retryArtwork() }
            }.disabled(!canEdit)
                .accessibilityIdentifier("system-media-artwork-retry")
        }
    }

    private var canEdit: Bool { !model.loadFailed && !model.isShuttingDown }
    private var artworkFailed: Bool { if case .failed = artwork.state { true } else { false } }

    @ViewBuilder
    private var artworkStatus: some View {
        switch artwork.state {
        case .unavailable: Text(l10n("播放器未提供封面。")).font(.caption).foregroundStyle(.secondary)
        case .pending: Text(l10n("正在读取播放器封面。")).font(.caption).foregroundStyle(.secondary)
        case .ready: EmptyView()
        case .failed(_, let error):
            Text(l10n("封面读取失败，播放信息仍可用。")).font(.caption)
            FailureNotice(failure: PresentedFailure(error))
        }
    }

    private var status: String {
        switch controller.status {
        case .disabled: l10n("媒体信息已关闭。")
        case .waitingForPlayback: l10n("等待场景播放，当前不向场景提供媒体信息。")
        case .checking: l10n("正在检查所选播放器。")
        case .applicationNotRunning: l10n("所选播放器尚未运行。")
        case .authorizationRequired: l10n("需要授权所选播放器的自动化访问。")
        case .authorizationDenied: l10n("所选播放器的自动化权限被拒绝。")
        case .noCurrentItem: l10n("所选播放器没有当前媒体。")
        case .available: l10n("所选播放器的媒体信息可用。")
        case .failed: l10n("媒体信息暂不可用，请查看错误并重试。")
        }
    }
}
