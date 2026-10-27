import AppKit
import WallpaperCore

@MainActor
protocol ScenePageSession: AnyObject {
    var view: NSView { get }
    var onError: ((Error) -> Void)? { get set }
    /// A real scene frame is ready, the scene clock paused, and output silent.
    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws
    func setGain(_ value: Double) throws
    /// Synchronous user intent; an obsolete play ack must not start capture.
    func setPlaybackIntent(_ playing: Bool)
    func setPlaying(_ value: Bool) async throws
    func sendPointer(at point: CGPoint, kind: String) throws
    func close() async throws
}

@MainActor
protocol ScenePageMaking: Sendable {
    func makeScenePage(size: CGSize) throws -> any ScenePageSession
}
