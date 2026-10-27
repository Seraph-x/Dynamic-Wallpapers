import AppKit
import Darwin
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge

func text(_ key: String) -> String { Bundle.module.localizedString(forKey: key, value: nil, table: nil) }

@main @MainActor
enum EditorApplication {
    static func main() {
        DWWebCreateApplication()
        let delegate = EditorApplicationDelegate()
        NSApp.delegate = delegate
        withExtendedLifetime(delegate) { NSApp.run() }
    }
}

@MainActor final class EditorApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var store: EditorProjectStore!
    private(set) var dataRoot: URL!
    private var lease: Int32 = -1
    let previewAudio = EditorPreviewAudioController()
    private var runtime: DWWebRuntime?
    private var windows: [UUID: EditorWindowController] = [:]
    private var welcome: NSWindow?
    private(set) var terminating = false
    var sharedSceneOffers: [EditorSceneOffer] = []
    var importedSources: [String: UUID] = [:]
    var sharedHostIdentifier: String?
    var pendingEditorURLs: [URL] = []
    var receivingEditorURLs = false
    var active: EditorWindowController? { windows.values.first { $0.window?.isKeyWindow == true } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let environment = ProcessInfo.processInfo.environment
            dataRoot = environment["DYNAMIC_WALLPAPER_EDITOR_DATA_ROOT"].map { URL(fileURLWithPath: $0) } ??
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DynamicWallpaperEditor")
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            dataRoot = dataRoot.resolvingSymlinksInPath()
            lease = Darwin.open(dataRoot.appendingPathComponent(".editor-instance").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lease >= 0 else { throw WallpaperError("Cannot open Editor instance lease") }
            guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "local.dynamicwallpaper.editor")
                        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate(options: [])
                    Darwin.close(lease); lease = -1; NSApp.terminate(nil); return
                }
                throw WallpaperError("Cannot lock Editor instance: \(String(cString: strerror(errno)))")
            }
            store = EditorProjectStore(directory: dataRoot.appendingPathComponent("Projects"))
            Task { await collectResources() }
            buildMenu(); showWelcome(); NSApp.activate(ignoringOtherApps: true)
            receivePendingEditorURLs()
        } catch { show(error); NSApp.terminate(nil) }
    }
    func show(_ error: Error, window: NSWindow? = nil) {
        let alert = NSAlert(); alert.messageText = text("error"); alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    private func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 540,height: 220), styleMask: [.titled,.closable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "Dynamic Wallpaper Editor"; window.isReleasedWhenClosed = false; window.center()
        let label = NSTextField(labelWithString: text("ready")); label.frame = NSRect(x: 28,y: 130,width: 485,height: 50)
        let new = NSButton(title: text("new"), target: self, action: #selector(newProject)); new.frame = NSRect(x: 28,y: 70,width: 210,height: 34)
        let open = NSButton(title: text("open"), target: self, action: #selector(openProject)); open.frame = NSRect(x: 260,y: 70,width: 245,height: 34)
        window.contentView?.addSubview(label); window.contentView?.addSubview(new); window.contentView?.addSubview(open)
        welcome = window; window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if let window = windows.values.first?.window { window.makeKeyAndOrderFront(nil) } else { showWelcome() }; return true
    }
    private func buildMenu() {
        let menu = NSMenu(); NSApp.mainMenu = menu
        func submenu(_ title: String) -> NSMenu { let item = NSMenuItem(); menu.addItem(item); let value = NSMenu(title: title); item.submenu = value; return value }
        func item(_ menu: NSMenu, _ key: String, _ action: Selector, _ shortcut: String = "") {
            let item = NSMenuItem(title: text(key), action: action, keyEquivalent: shortcut); item.target = self; menu.addItem(item)
        }
        item(submenu("Editor"), "quit", #selector(NSApplication.terminate(_:)), "q")
        menu.items[0].submenu?.items[0].target = NSApp
        let file = submenu(text("file"))
        item(file,"new",#selector(newProject),"n"); item(file,"open",#selector(openProject),"o"); file.addItem(.separator())
        item(file,"addImage",#selector(addImage)); item(file,"importModel",#selector(importModel)); item(file,"save",#selector(save),"s")
        item(file,"exportLoose",#selector(exportLoose)); item(file,"exportPkg",#selector(exportPackage))
        item(file,"previewSnapshot",#selector(previewSnapshot))
        file.addItem(.separator()); item(file,"importMain",#selector(importSharedScene)); item(file,"openMain",#selector(openInWallpaper))
        let edit = submenu(text("edit"))
        for (key,action,shortcut) in [("cut","cut:","x"),("copy","copy:","c"),("paste","paste:","v"),("selectAll","selectAll:","a")] {
            edit.addItem(NSMenuItem(title: text(key), action: NSSelectorFromString(action), keyEquivalent: shortcut))
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(importSharedScene) { return !sharedSceneOffers.isEmpty && !terminating }
        if [#selector(save),#selector(addImage),#selector(importModel),#selector(exportLoose),#selector(exportPackage),#selector(openInWallpaper),#selector(previewSnapshot)].contains(menuItem.action) {
            return active?.ready == true && active?.busy == false
        }
        return !terminating
    }
    @objc func newProject() {
        let alert = NSAlert(); alert.messageText = text("new"); alert.addButton(withTitle: text("create")); alert.addButton(withTitle: text("cancel"))
        let view = NSView(frame: NSRect(x: 0,y: 0,width: 320,height: 120))
        let fields = [NSTextField(string: "Untitled"),NSTextField(string: "1920"),NSTextField(string: "1080")]
        for (index,key) in ["title","width","height"].enumerated() {
            let label = NSTextField(labelWithString: text(key)); label.frame = NSRect(x: 0,y: 90-index*38,width: 95,height: 24)
            fields[index].frame = NSRect(x: 100,y: 90-index*38,width: 210,height: 24); fields[index].setAccessibilityLabel(text(key))
            view.addSubview(label); view.addSubview(fields[index])
        }
        alert.accessoryView = view
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let width = Int(fields[1].stringValue), let height = Int(fields[2].stringValue) else { show(WallpaperError("Invalid canvas dimensions")); return }
        Task { do { try await present(store.create(title: fields[0].stringValue, width: width, height: height)) } catch { show(error) } }
    }
    @objc func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = text("chooseProject"); panel.directoryURL = store.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do {
            if url.lastPathComponent == "workspace.json", let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent),
               url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == store.directory {
                try await present(store.open(id: id))
            } else {
                let root = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                try await present(store.importProject(root: root))
            }
        } catch { show(error) } }
    }
    func present(_ owned: EditorOwnedProject) async throws {
        guard !terminating else { throw WallpaperError("Editor is quitting") }
        if let existing = windows[owned.document.id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        await collectResources()
        let resourceSession = try await store.acquireResourceSession(id: owned.document.id)
        let current = try await store.open(id: owned.document.id)
        guard current.document == owned.document else { throw WallpaperError("Project changed before its editing window opened; reopen the project") }
        // Actor hops can overlap another open request or termination.
        guard !terminating else { throw WallpaperError("Editor is quitting") }
        if let existing = windows[owned.document.id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = try EditorWindowController(project: current, resourceSession: resourceSession, coordinator: self, runtime: startedRuntime())
        windows[owned.document.id] = controller; welcome?.orderOut(nil); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        controller.start()
    }
    func retired(_ id: UUID) {
        windows[id] = nil
        if windows.isEmpty {
            Task { await collectResources() }
            if !terminating { showWelcome() }
        }
    }
    private func collectResources() async {
        do {
            let report = try await store.collectUnusedResources()
            for project in report.projects where !project.removedVersions.isEmpty {
                fputs("Editor resource collection: project=\(project.projectID) removed=\(project.removedVersions.count) bytes=\(project.reclaimedBytes)\n", stderr)
            }
            if !report.failures.isEmpty {
                show(WallpaperError(report.failures.map { "\($0.projectID): \($0.message)" }.joined(separator: "\n")))
            }
        } catch { show(error) }
    }
    private func startedRuntime() throws -> DWWebRuntime {
        if let runtime { return runtime }
        guard let frameworks = Bundle.main.privateFrameworksURL else { throw WallpaperError("Editor CEF dependencies are missing") }
        let cache = dataRoot.appendingPathComponent("CEFCache"); try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let runtime = DWWebRuntime(frameworkDirectory: frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path,
            helperExecutable: frameworks.appendingPathComponent("DynamicWallpaperEditor Helper.app/Contents/MacOS/DynamicWallpaperEditor Helper").path,
            cacheDirectory: cache.path)
        self.runtime = runtime
        do { try runtime.start() } catch {
            let failure = error as NSError
            if let exitCode = failure.userInfo["CEFInitializationExitCode"] as? NSNumber { fputs("\(failure.localizedDescription)\n",stderr); Darwin.exit(exitCode.int32Value) }
            throw error
        }
        return runtime
    }
    @objc func addImage() { active?.addImage() }
    @objc func save() { active?.perform { try await $0.save() } }
    @objc func exportLoose() { active?.exportProject(package: false) }
    @objc func exportPackage() { active?.exportProject(package: true) }
    @objc func previewSnapshot() { active?.previewSnapshot() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateCancel }
        terminating = true
        Task {
            do {
                for controller in Array(windows.values) { guard try await controller.requestClose() else { terminating = false; NSApp.reply(toApplicationShouldTerminate: false); return } }
                await collectResources()
                try await previewAudio.shutdown()
                try runtime?.shutdown()
                if lease >= 0 { guard Darwin.close(lease) == 0 else { throw WallpaperError("Cannot release Editor lease") }; lease = -1 }
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                if previewAudio.shuttingDown { previewAudio.cancelShutdown() }
                terminating = false
                if windows.isEmpty { showWelcome() }
                show(error); NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
