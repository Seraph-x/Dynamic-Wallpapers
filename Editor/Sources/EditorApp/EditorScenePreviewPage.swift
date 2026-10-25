import AppKit
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge

/// A separate scene page has no EditorSession, authoring commands or resource bridge.
@MainActor final class EditorNativeScenePreviewPage: EditorScenePreviewPage {
    private let page: DWWebPage
    var view: NSView { page.view }
    var origin: String { page.origin }
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onDiagnostic: (([String: Any]) -> Void)?

    init(runtime: DWWebRuntime, project: SceneProjectReference) throws {
        page = try runtime.scenePage(withProjectRoot: project.root.path,
            runtimeRoot: Self.runtimeDirectory().path, entry: project.entry,
            representation: project.representation.rawValue, sceneID: UUID().uuidString,
            generation: 1, size: NSSize(width: 960, height: 540), scale: 1)
        page.onReady = { [weak self] in self?.onReady?() }
        page.onError = { [weak self] error in self?.onError?(error) }
        page.onDiagnostic = { [weak self] diagnostic in self?.onDiagnostic?(diagnostic) }
    }

    static func runtimeDirectory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "ScenePreviewWeb", withExtension: nil) else {
            throw WallpaperError("Editor scene preview resources are missing")
        }
        return url
    }

    func start() throws { try page.setOutputGain(0); page.start() }
    func setPlaying(_ value: Bool) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            page.setScenePlaying(value) { error in
                if let error { reply.resume(throwing: error) } else { reply.resume() }
            }
        }
    }
    func close() async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            page.close { error in
                if let error { reply.resume(throwing: error) } else { reply.resume() }
            }
        }
    }
}
