import AppKit
import Foundation
import SwiftUI
import WebWallpaperBridge
import Darwin

@main
enum DynamicWallpaperMain {
    struct StartupContext {
        let product: ProductBundleMetadata
        let paths: ApplicationPaths
    }

    private static let startupResult = Result<StartupContext, Error> {
        let product = try ProductBundleMetadata(bundle: .main)
        let paths = try ApplicationPaths.resolve(arguments: Array(CommandLine.arguments.dropFirst()),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            configuredBundleIdentifier: Bundle.main.object(
                forInfoDictionaryKey: "DWApplicationBundleIdentifier") as? String ?? "")
        return StartupContext(product: product, paths: paths)
    }

    static func requireStartup() -> StartupContext {
        do { return try startupResult.get() }
        catch { fatalError("Application startup failed: \(error)") }
    }

    static func main() {
        do {
            let startup = try startupResult.get()
            if startup.paths.printValidationPaths {
                var record = try startup.paths.encodedRecord(event: "preflight")
                record.append(0x0A)
                FileHandle.standardOutput.write(record)
                return
            }
        } catch {
            fputs("Application startup failed: \(error)\n", stderr)
            Darwin.exit(1)
        }
        DWWebCreateApplication()
        if #available(macOS 27.0, *) {
            MacOS27WallpaperApp.main()
        } else {
            DynamicWallpaperApp.main()
        }
    }
}

struct DynamicWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    private let product: ProductBundleMetadata
    init() {
        let startup = DynamicWallpaperMain.requireStartup()
        product = startup.product
        let model = AppModel(paths: startup.paths)
        do { try model.paths.appendEvidence(event: "startup") }
        catch { fatalError("Validation startup evidence failed: \(error)") }
        _model = StateObject(wrappedValue: model)
        delegate.model = model
    }
    var body: some Scene {
        WallpaperScenes(model: model, product: product)
    }
}

struct WallpaperScenes: Scene {
    let model: AppModel
    let product: ProductBundleMetadata
    @State private var audioPanel = CurrentWallpaperAudioPanel()
    var body: some Scene {
        library
        menuBar
        transcode
        settings
    }

    var library: some Scene {
        Window(product.displayName, id: "library") {
            LibraryView(model: model, product: product)
                .frame(minWidth: 1000, minHeight: 650)
                .appInterfacePreferences(model)
                .background(ManagementWindowSpaceBehavior())
                .modifier(NativeFullScreenWindow())
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            ImportWallpaperCommand(model: model)
            HelpCommand(model: model, product: product)
        }
    }

    var menuBar: some Scene {
        MenuBarExtra {
            MenuContent(model: model, product: product, audioPanel: audioPanel)
                .appInterfacePreferences(model)
        } label: {
            MenuBarLabel(model: model, product: product)
        }
    }

    var transcode: some Scene {
        Window(model.localizer("视频转码"), id: "transcode") {
            TranscodeView(model: model).frame(minWidth: 720, minHeight: 560)
                .appInterfacePreferences(model)
                .background(ManagementWindowSpaceBehavior())
        }.defaultSize(width: 780, height: 700)
    }

    var settings: some Scene {
        Settings {
            SettingsView(model: model, product: product)
                .appInterfacePreferences(model)
                .background(ManagementWindowSpaceBehavior())
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quitPreparation = ApplicationQuitPreparation()
    private lazy var managementWindows = ManagementWindowObserver { [weak self] hasOpenWindows in
        self?.model?.setManagementWindowsOpen(hasOpenWindows)
    }
    weak var model: AppModel?
    private var termination: ApplicationTermination?
    func applicationWillFinishLaunching(_ notification: Notification) {
        managementWindows.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        quitPreparation.installQuitAppleEventHandler()
        model?.finishLaunching(event: NSAppleEventManager.shared().currentAppleEvent)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.loginItems.refresh()
        model?.refreshWebInteractionStatus()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let model else { return true }
        do { try model.paths.appendEvidence(event: "reopen") }
        catch { fatalError("Validation reopen evidence failed: \(error)") }
        model.mainWindow.open()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            quitPreparation.complete(allowed: true)
            return .terminateNow
        }
        if termination == nil {
            termination = ApplicationTermination(shutdown: {
                try await model.shutdownAndWait()
                try model.paths.appendEvidence(event: "shutdown")
            },
                reply: { [quitPreparation] allowed in
                    quitPreparation.complete(allowed: allowed)
                    sender.reply(toApplicationShouldTerminate: allowed)
                }, report: { model.report($0, context: .shutdown) },
                needsConfirmation: { model.transcoding.hasActiveWork },
                confirmCancellation: {
                    let alert = NSAlert()
                    alert.messageText = model.localizer("转码任务仍在运行")
                    alert.informativeText = model.localizer.text(WallpaperCopy.quitTranscoding)
                    alert.addButton(withTitle: model.localizer("暂不退出"))
                    alert.addButton(withTitle: model.localizer("取消任务并退出"))
                    return alert.runModal() == .alertSecondButtonReturn
                })
        }
        let result = termination!.request()
        if result != .terminateLater { quitPreparation.complete(allowed: result == .terminateNow) }
        return result
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        managementWindows.stop()
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    let product: ProductBundleMetadata
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: AppBranding.menuBarIcon)
            .accessibilityLabel(product.displayName)
            .onAppear {
                model.mainWindow.installOpener { [openWindow] in openWindow(id: "library") }
            }
            .onChange(of: model.library.settings.appearance.theme, initial: true) { _, theme in
                NSApplication.shared.appearance = theme.nativeAppearance
            }
    }
}

struct MenuContent: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let product: ProductBundleMetadata
    var audioPanel = CurrentWallpaperAudioPanel()
    var permissionPrompt: ([WebInteractionPermission], AppLocalizer) -> WebInteractionPermission? = {
        WebInteractionPermissionAlert.present(missing: $0, localizer: $1)
    }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text(l10n.playbackSummary(model))
        if let failure = model.presentationFailure {
            Button(l10n("运行模式设置未完成…")) {
                model.activateManagementInterface()
                FailureAlert.present(failure, localizer: l10n)
            }
        }
        Divider()
        GlobalMuteToggle(model: model, showMenuError: true)
        if !model.currentWallpaperAudioTargets.isEmpty {
            Button(l10n("当前壁纸声音")) {
                let location = NSEvent.mouseLocation
                // The menu must finish tracking before the panel takes keyboard focus.
                DispatchQueue.main.async { audioPanel.show(model: model, near: location) }
            }
                .disabled(model.loadFailed || model.isShuttingDown)
        }
        Toggle(l10n("网页交互"), isOn: Binding(
            get: { model.library.settings.webInteractionEnabled },
            set: { enabled in setWebInteractionEnabled(enabled) }))
            .disabled(model.loadFailed || model.isShuttingDown)
            .onAppear { model.refreshWebInteractionStatus() }
        if model.webInteractionFailure != nil {
            Button(l10n("网页交互设置未完成…"), action: presentWebInteractionFailure)
        }
        if let diagnostics = model.webInteractionStatus.diagnostics {
            Button(l10n("网页交互详情…")) {
                FailureAlert.presentDetails(PresentedFailure(title: l10n("网页交互详情"),
                    summary: l10n.webInteractionStatus(model.webInteractionStatus), diagnostics: diagnostics), localizer: l10n)
            }
        }
        Button(model.userPaused ? l10n("继续播放") : l10n("暂停播放"), action: model.togglePause)
        Button(l10n("下一张壁纸")) { model.next() }.disabled(!model.canAdvance())
        Menu(l10n("播放列表")) {
            ForEach(model.library.playlists) { list in
                Button(list.name) { model.applyPlaylist(list.id, displayID: nil, fit: .fill) }.disabled(list.entries.isEmpty)
            }
        }
        Divider()
        Button(l10n("打开 \(product.displayName)")) {
            model.mainWindow.open()
        }
        Button(l10n("转码任务")) {
            openWindow(id: "transcode"); NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(l10n("设置…")) {
            openSettings()
            model.activateManagementInterface()
        }
        Button(l10n("帮助文档")) { AppHelp.open(localizer: model.localizer, product: product) }
        Button(l10n("退出 \(product.displayName)")) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }

    private func setWebInteractionEnabled(_ enabled: Bool) {
        switch model.setWebInteractionEnabled(enabled) {
        case .updated: break
        case .needsPermissions(let missing):
            model.activateManagementInterface()
            if let permission = permissionPrompt(missing, l10n), !model.requestWebInteractionPermission(permission) {
                presentWebInteractionFailure()
            }
        case .failed: presentWebInteractionFailure()
        }
    }

    private func presentWebInteractionFailure() {
        guard let failure = model.webInteractionFailure else { return }
        model.activateManagementInterface()
        FailureAlert.present(failure, localizer: l10n)
    }
}
