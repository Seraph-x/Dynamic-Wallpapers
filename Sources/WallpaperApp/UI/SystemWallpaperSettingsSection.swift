import SwiftUI

struct SystemWallpaperSettingsSection: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject private var sync: SystemWallpaperSync

    init(model: AppModel) {
        self.model = model
        sync = model.systemWallpaperSync
    }

    var body: some View {
        Section(l10n("系统壁纸")) {
            Toggle(l10n("同步系统底图"), isOn: Binding(
                get: { model.library.settings.systemWallpaperSyncEnabled },
                set: { model.setSystemWallpaperSyncEnabled($0) }))
                .accessibilityIdentifier("system-wallpaper-sync")
                .disabled(model.loadFailed || model.isShuttingDown)
            if let failure = model.systemWallpaperFailure { FailureNotice(failure: failure) }
            if sync.enabled {
                if boundDisplays.isEmpty {
                    Text(l10n("等待正式壁纸"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(boundDisplays) { display in
                    statusRow(display)
                }
            }
        }
    }

    private var boundDisplays: [DisplayInfo] {
        let boundIDs = Set(model.library.displays.map(\.id))
        return model.displays.filter { boundIDs.contains($0.id) }
    }

    private func statusRow(_ display: DisplayInfo) -> some View {
        let state = sync.states[display.id] ?? .waiting
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                HStack(spacing: 6) {
                    if state == .syncing { ProgressView().controlSize(.small) }
                    Text(l10n.text(title(for: state)))
                }.accessibilityIdentifier("system-wallpaper-status-\(display.id)")
            } label: { Text(verbatim: display.name) }
            if case .failed(let failure) = state {
                FailureNotice(failure: failure)
                Button(l10n("重试同步")) { sync.retry(displayID: display.id) }
                    .accessibilityIdentifier("system-wallpaper-retry-\(display.id)")
                    .disabled(model.isShuttingDown)
            }
        }
    }

    private func title(for state: SystemWallpaperSyncState) -> String {
        switch state {
        case .waiting: return "等待正式壁纸"
        case .syncing: return "正在同步…"
        case .synced: return "已同步"
        case .failed: return "同步失败"
        }
    }
}
