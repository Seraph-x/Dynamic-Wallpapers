import AppKit
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge

/// External browser transport; the owning controller retains snapshot policy.
@MainActor protocol EditorAuthoringPage: AnyObject {
    var view: NSView { get }
    var ready: Bool { get }
    var closed: Bool { get }
    var onReady: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onEditorDirty: ((Bool) -> Void)? { get set }
    var onEditorResource: (([String: Any]) -> Void)? { get set }
    var onEditorPreview: (() -> Void)? { get set }
    func start()
    func requestEditorCommand(_ payload: [String: Any], completion: @escaping DWEditorCommandCompletion)
    func close(completion: @escaping (Error?) -> Void)
}

extension DWWebPage: EditorAuthoringPage {}

@MainActor protocol EditorPreviewWindow: AnyObject {
    var capturedPropertyInspection: Result<EditorPreviewProperties, Error>? { get set }
    var capturedScripts: EditorCapturedScriptSnapshot? { get set }
    var onSource: ((EditorCapturedScriptLink) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    var onError: ((Error, NSWindow?) -> Void)? { get set }
    func start() throws
    func requestClose() async throws
}

extension EditorScenePreviewWindowController: EditorPreviewWindow {}

@MainActor protocol EditorWindowCoordinator: AnyObject {
    var store: EditorProjectStore! { get }
    var dataRoot: URL! { get }
    func show(_ error: Error, window: NSWindow?)
    func confirmClose() -> NSApplication.ModalResponse
    func retired(_ id: UUID)
}

extension EditorWindowCoordinator {
    func confirmClose() -> NSApplication.ModalResponse {
        let alert = NSAlert(); alert.messageText = text("unsaved"); alert.informativeText = text("unsavedDetail")
        alert.addButton(withTitle: text("save")); alert.addButton(withTitle: text("discard")); alert.addButton(withTitle: text("cancel"))
        return alert.runModal()
    }
}

extension EditorApplicationDelegate: EditorWindowCoordinator {}
