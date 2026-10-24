import AppKit
import WallpaperCore

@MainActor
protocol ScenePageSession: AnyObject {
    var view: NSView { get }
    var onError: ((Error) -> Void)? { get set }
    /// A real scene frame is ready, the scene clock paused, and output silent.
    func prepare(project: SceneProjectReference, scale: CGFloat, fit: ContentFit) async throws
    func setGain(_ value: Double) throws
    func setPlaying(_ value: Bool) async throws
    func sendPointer(at point: CGPoint, kind: String) throws
    func close() async throws
}

@MainActor
protocol ScenePageMaking: Sendable {
    func makeScenePage(size: CGSize) throws -> any ScenePageSession
}
