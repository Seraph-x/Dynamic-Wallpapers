import AppKit
import ScreenSaverCore
import SwiftUI

struct ScreenSaverManagementView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject var screenSaver: ScreenSaverModel
    let product: ProductBundleMetadata
    @State private var installation: ScreenSaverInstallation.Status?
    @State private var installationFailure: ScreenSaverFailure?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(l10n("屏幕保护")).font(.title2.weight(.semibold))
                ScreenSaverStatusView(state: screenSaver.state, startupFailure: screenSaver.startupFailure)
                ScreenSaverSourceView(model: model, screenSaver: screenSaver)
                previewCard
                installationControls
            }
            .padding(24)
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: refreshInstallation)
    }

    private var previewCard: some View {
        ScreenSaverPreview(model: model, screenSaver: screenSaver)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var installationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("系统安装")).font(.headline)
            Text(installationDescription).font(.callout)
            if let installationFailure {
                Text(l10n.screenSaverError(installationFailure))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(l10n("安装或更新屏保…"), action: openInstaller)
                Button(l10n("重新检查安装状态"), action: refreshInstallation)
                Button(l10n("打开系统设置"), action: openSystemSettings)
            }
            Text(l10n("安装后请在系统设置中自行选中屏保，并在屏保配置中授权下方发布目录。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(screenSaver.exportRoot.path).font(.caption.monospaced()).textSelection(.enabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var installationDescription: String {
        switch installation {
        case .notInstalled: return l10n("尚未安装匹配的屏保")
        case .installed(let version, _): return l10n("已安装屏保版本 \(version)")
        case .updateAvailable(let installed, let bundled, _):
            return l10n("已安装版本 \(installed)，可更新到 \(bundled)")
        case .ambiguous: return l10n("找到多个同标识屏保，请检查安装目录")
        case nil: return l10n("安装状态尚未确认")
        }
    }

    private var bundledURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns")
            .appendingPathComponent(product.screenSaverBundleName)
    }

    private func refreshInstallation() {
        do {
            installation = try ScreenSaverInstallation(bundledURL: bundledURL, product: product).refresh()
            installationFailure = nil
        } catch {
            installation = nil
            installationFailure = ScreenSaverAppFailure.capture(error, phase: .install)
        }
    }

    private func openInstaller() {
        do {
            installation = try ScreenSaverInstallation(bundledURL: bundledURL, product: product).install()
            installationFailure = nil
        } catch {
            installation = nil
            installationFailure = ScreenSaverAppFailure.capture(error, phase: .install)
        }
    }

    private func openSystemSettings() {
        guard let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences"),
              NSWorkspace.shared.open(settings) else {
            installationFailure = ScreenSaverFailure(code: .installationFailed)
            return
        }
        installationFailure = nil
    }
}
