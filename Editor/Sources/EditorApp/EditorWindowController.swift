import AppKit
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge

@MainActor final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private unowned let coordinator: EditorApplicationDelegate
    private var project: EditorOwnedProject
    private var workspace: EditorProjectDocument
    private let page: DWWebPage
    private(set) var ready = false
    private(set) var busy = false
    private var dirty = false
    private var closing = false
    private var editingWasEnabled = false

    init(project: EditorOwnedProject, coordinator: EditorApplicationDelegate, runtime: DWWebRuntime) throws {
        self.project = project; workspace = project.document; self.coordinator = coordinator
        guard let resources = Bundle.module.url(forResource: "EditorWeb", withExtension: nil) else { throw WallpaperError("Editor browser resources are missing") }
        var configuration: [String: Any] = ["language": Bundle.module.preferredLocalizations.first ?? "en", "document": try Self.browserDocument(project.document)]
        if let package = project.document.sourcePackage { configuration["sourcePackage"] = package }
        page = try runtime.editorPage(withProjectRoot: project.resources.path, runtimeRoot: resources.path,
            configuration: configuration, size: NSSize(width: 1180,height: 760))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1180,height: 760),
            styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 850,height: 540); window.isReleasedWhenClosed = false
        window.title = "\(project.document.title) — \(text("preparing"))"; window.center()
        super.init(window: window); window.delegate = self
        page.view.frame = window.contentView!.bounds; page.view.autoresizingMask = [.width,.height]; window.contentView?.addSubview(page.view)
        page.onReady = { [weak self] in
            guard let self, !self.closing else { return }
            Task { do {
                guard !self.closing else { return }
                self.editingWasEnabled = true
                _ = try await self.command(["type":"thaw"])
                if !self.closing { self.ready = true; self.window?.title = self.workspace.title }
            } catch { self.coordinator.show(error,window:self.window) } }
        }
        page.onEditorDirty = { [weak self] dirty in self?.dirty = dirty; self?.window?.isDocumentEdited = dirty }
        page.onEditorResource = { [weak self] request in
            guard let self else { return }
            Task {
                let result = await EditorResourceBridge.result(request, store: self.coordinator.store, id: self.workspace.id)
                do { _ = try await self.command(["type":"resource-reply", "requestID":request["id"]!, "result":result]) }
                catch { if !self.page.closed { self.coordinator.show(error, window:self.window) } }
            }
        }
        page.onError = { [weak self] error in
            guard let self else { return }; self.ready = false
            // A failed transport cannot prove the absence of unsent browser edits.
            if self.editingWasEnabled { self.dirty = true; self.window?.isDocumentEdited = true }
            self.coordinator.show(error,window: self.window)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func start() { page.start() }
    static func browserDocument(_ workspace: EditorProjectDocument) throws -> [String: Any] {
        var result: [String:Any] = ["title": workspace.title, "entry": workspace.sceneEntry,
         "scene": try JSONSerialization.jsonObject(with: workspace.scene), "project": try JSONSerialization.jsonObject(with: workspace.project)]
        if !workspace.resourceOverrides.isEmpty { result["resourceOverrides"] = workspace.resourceOverrides.mapValues(\.id) }
        return result
    }
    func command(_ payload: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            page.requestEditorCommand(payload) { reply, error in
                if let error { continuation.resume(throwing: error) }
                else if let reply, let failure = reply["error"] as? String { continuation.resume(throwing: WallpaperError(failure)) }
                else if let reply { continuation.resume(returning: reply) }
                else { continuation.resume(throwing: WallpaperError("Editor command completed without a reply")) }
            }
        }
    }
    func snapshot() async throws -> [String: Any] {
        guard let workspace = try await command(["type":"snapshot"])["document"] as? [String: Any] else { throw WallpaperError("Editor snapshot is missing its workspace") }
        return workspace
    }
    func save() async throws {
        let state = try await command(["type":"freeze"])
        guard let snapshot = state["document"] as? [String:Any] else { throw WallpaperError("Missing save snapshot") }
        do {
        if state["dirty"] as? Bool == true { _ = try await self.snapshot() } // Surfaces invalid visible input before any write.
        guard let scene = snapshot["scene"] as? [String: Any], let metadata = snapshot["project"] as? [String: Any],
              let title = snapshot["title"] as? String, snapshot["entry"] as? String == workspace.sceneEntry else { throw WallpaperError("Invalid Editor snapshot") }
        let overrides: [String:EditorResourceVersion]
        if let raw = snapshot["resourceOverrides"] as? [String:String] { overrides = try raw.mapValues { try EditorResourceVersion(id:$0) } }
        else if snapshot["resourceOverrides"] == nil { overrides = [:] }
        else { throw WallpaperError("Invalid Editor resource overrides") }
        workspace = try await coordinator.store.save(workspace, scene: JSONSerialization.data(withJSONObject: scene),
            project: JSONSerialization.data(withJSONObject: metadata), title: title, resourceOverrides:overrides)
        _ = try await command(["type":"mark-saved", "document":snapshot])
        window?.title = workspace.title
        if !closing { _ = try await command(["type":"thaw"]) }
        } catch {
            if !closing { do { _ = try await command(["type":"thaw"]) } catch let thaw { throw WallpaperErrorGroup([error,thaw]) } }
            throw error
        }
    }
    func perform(_ operation: @escaping @MainActor (EditorWindowController) async throws -> Void) {
        guard ready, !busy, !closing else { return }
        busy = true
        Task { defer { busy = false }; do { try await operation(self) } catch { coordinator.show(error, window: window) } }
    }
    func addImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { controller in
            let data = try Data(contentsOf: url)
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { throw WallpaperError("Cannot decode selected image") }
            let suffix: String
            if data.starts(with: [0x89,0x50,0x4e,0x47]) { suffix = "png" }
            else if data.starts(with: [0xff,0xd8]) { suffix = "jpg" }
            else { throw WallpaperError("The selected file is not PNG or JPEG") }
            let resource = try await controller.coordinator.store.addImage(id: controller.workspace.id, data: data, extension: suffix,
                width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            _ = try await controller.command(["type":"add-image","image":["name":url.deletingPathExtension().lastPathComponent,
                "model":resource.model,"width":bitmap.pixelsWide,"height":bitmap.pixelsHigh]])
        }
    }
    func exportProject(package: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = workspace.title; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform { controller in
            try await controller.save()
            if package {
                let paths = try await controller.coordinator.store.resourcePaths(id: controller.workspace.id)
                let reply = try await controller.command(["type":"export-pkg","paths":paths])
                guard let base64 = reply["pkg"] as? String, let bytes = Data(base64Encoded: base64) else { throw WallpaperError("Editor returned invalid PKG bytes") }
                _ = try await controller.coordinator.store.exportPackage(controller.workspace, package: bytes, to: destination)
            } else { _ = try await controller.coordinator.store.exportLoose(controller.workspace, to: destination) }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
    func materializeSavedHandoff() async throws -> SceneProjectReference {
        let handoffs = coordinator.dataRoot.appendingPathComponent("Handoffs")
        try FileManager.default.createDirectory(at:handoffs,withIntermediateDirectories:true)
        // Keep the immutable export after sending: Main imports asynchronously and owns its own copy.
        return try await coordinator.store.exportLoose(workspace,to:handoffs.appendingPathComponent(UUID().uuidString))
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { do { _ = try await requestClose() } catch { coordinator.show(error,window: window) } }
        return false
    }
    func requestClose() async throws -> Bool {
        guard !closing else { return false }
        guard !busy else { throw WallpaperError(text("busy")) }
        closing = true; defer { closing = false }
        var frozen = false
        do {
        // Notifications update the title bar, but never decide whether edits can be discarded.
        // Freeze flushes DOM fields/dragging and blocks further input before returning this snapshot.
        let needsSave: Bool
        if page.ready {
            let state = try await command(["type":"freeze"]); frozen = true
            guard let snapshot = state["document"] as? [String:Any], let changed = state["dirty"] as? Bool else { throw WallpaperError("Invalid close snapshot") }
            let baseline = try Self.browserDocument(workspace)
            needsSave = changed || !NSDictionary(dictionary:snapshot).isEqual(to: baseline)
        } else { needsSave = dirty }
        if needsSave {
            let alert = NSAlert(); alert.messageText = text("unsaved"); alert.informativeText = text("unsavedDetail")
            alert.addButton(withTitle: text("save")); alert.addButton(withTitle: text("discard")); alert.addButton(withTitle: text("cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try await save()
                let latest = try await snapshot()
                guard NSDictionary(dictionary: latest).isEqual(to: try Self.browserDocument(workspace)) else {
                    _ = try await command(["type":"thaw"]); return false
                }
            case .alertSecondButtonReturn: break
            default:
                if frozen { _ = try await command(["type":"thaw"]) }
                return false
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            page.close { error in if let error { continuation.resume(throwing:error) } else { continuation.resume() } }
        }
        ready = false; window?.delegate = nil; window?.close(); coordinator.retired(workspace.id)
        return true
        } catch {
            if frozen {
                do { _ = try await command(["type":"thaw"]) } catch let thaw { throw WallpaperErrorGroup([error,thaw]) }
            }
            throw error
        }
    }
}
