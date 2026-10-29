import SwiftUI
import WallpaperCore

struct SettingsView: View {
    @Localized private var l10n
    // Leave room for all five localized tabs, including the longer Spanish labels.
    static let minimumSize = CGSize(width: 800, height: 680)
    @ObservedObject var model: AppModel
    let product: ProductBundleMetadata
    @Environment(\.appPalette) private var palette
    @State private var selectedTab = SettingsTab.general

    private enum SettingsTab: String { case general, appearance, storage, advanced, about }

    var body: some View {
        VStack(spacing: 0) {
            tabs.padding(.horizontal, 20).padding(.vertical, 8)
            selectedPage
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .appGlassBackground(.window, appearance: model.library.settings.appearance,
                            receivesTransparentClicks: true,
                            captureWallpaper: model.captureWallpaper, makeWallpaperMirror: model.makeWallpaperMirror)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private var tabs: some View {
        // Keep navigation inside the shared glass surface. Native Settings toolbar
        // tabs lose their mouse-hit region when the window background is transparent.
        HStack(spacing: 4) {
            tabButton("通用", systemImage: "gearshape", tab: .general)
            tabButton("外观", systemImage: "paintpalette", tab: .appearance)
            tabButton("存储与素材", systemImage: "externaldrive", tab: .storage)
            tabButton("高级", systemImage: "slider.horizontal.3", tab: .advanced)
            tabButton("关于", systemImage: "info.circle", tab: .about)
        }
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ title: String.LocalizationValue, systemImage: String, tab: SettingsTab) -> some View {
        Button { selectedTab = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 20)).frame(height: 24)
                Text(l10n(title)).font(.system(size: 12)).fixedSize()
            }
            .frame(minWidth: 60)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTab == tab ? palette.brandAccent : .primary)
        .accessibilityLabel(l10n(title))
        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selectedTab {
        case .general: GeneralSettingsView(model: model)
        case .appearance: AppearanceSettingsView(model: model)
        case .storage: StorageSettingsView(model: model)
        case .advanced: AdvancedSettingsView(model: model)
        case .about: AboutSettingsView(product: product)
        }
    }
}

private struct GeneralSettingsView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            LanguageSettingsSection(model: model)
            StartupSettingsSection(model: model)
            SystemWallpaperSettingsSection(model: model)
            Section(l10n("声音")) {
                GlobalMuteToggle(model: model)
                SystemAudioSpectrumSettingsSection(model: model)
            }
            Section(l10n("媒体信息与控制")) {
                SystemMediaSettingsSection(model: model)
            }
            Section(l10n("节能")) {
                Toggle(l10n("低电量模式时暂停"), isOn: Binding(
                    get: { model.library.settings.pauseOnLowPower },
                    set: { value in model.mutate { $0.settings.pauseOnLowPower = value } }))
                Toggle(l10n("设备温度较高时暂停"), isOn: Binding(
                    get: { model.library.settings.pauseOnHighTemperature },
                    set: { value in model.mutate { $0.settings.pauseOnHighTemperature = value } }))
                Toggle(l10n("其他应用全屏时暂停"), isOn: Binding(
                    get: { model.library.settings.pauseOnOtherAppFullScreen },
                    set: { value in model.mutate { $0.settings.pauseOnOtherAppFullScreen = value } }))
            }
            Section(l10n("系统事件")) {
                HStack(spacing: 6) {
                    Text(l10n("锁屏或休眠时自动暂停。")).font(.caption).foregroundStyle(.secondary)
                    HelpPopover(title: l10n("暂停与恢复"), message: WallpaperCopy.pauseHelp)
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

private struct StorageSettingsView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section(l10n("本地素材")) {
                Text(l10n.text(WallpaperCopy.storageExplanation))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(l10n("素材库管理")) {
                Text(l10n.text(WallpaperCopy.clearLibraryConfirmation))
                    .font(.callout).foregroundStyle(.secondary)
                Button(l10n("备份并清空素材库…"), role: .destructive) { confirmingClear = true }
                    .disabled(model.loadFailed || model.importing || model.isShuttingDown
                        || (model.library.media.isEmpty && model.library.playlists.isEmpty && model.library.displays.isEmpty))
                if !model.library.pendingMediaDeletions.isEmpty {
                    Text(l10n("待清理副本：\(model.library.pendingMediaDeletions.count)"))
                    Text(l10n("清理失败会保留记录并在下次启动时重试。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let backup = model.lastLibraryBackup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n("最近配置备份"))
                        Text(l10n("备份文件夹"))
                        Text(backup.deletingLastPathComponent().path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    Button(l10n("在 Finder 中显示备份")) { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
                        .tint(AppColors.secondaryActionText)
                }
                if let failure = model.failure { FailureNotice(failure: failure) }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
        .confirmationDialog(l10n("备份并清空素材库？"), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(l10n("取消"), role: .cancel) { confirmingClear = false }
            Button(l10n("备份并清空"), role: .destructive) { model.clearMediaLibrary() }
        } message: { Text(l10n.text(WallpaperCopy.clearLibraryConfirmation)) }
        .onReceive(NotificationCenter.default.publisher(for: .cancelPendingPresentationsForQuit)) { _ in
            confirmingClear = false
        }
    }
}

private struct AdvancedSettingsView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent(l10n("文件名"), value: model.store.url.lastPathComponent)
                    .textSelection(.enabled)
                LabeledContent(l10n("素材库格式版本"), value: String(model.library.version))
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n("完整路径"))
                    Text(model.store.url.path)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Button(l10n("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }
                    .tint(AppColors.secondaryActionText)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n("配置文件"))
                    Text(l10n("仅供排查问题时参考"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }
}
