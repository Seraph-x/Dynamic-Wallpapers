import AppKit
import WallpaperCore

@MainActor
protocol WebPageSession: AnyObject {
    var view: NSView { get }
    var onError: ((Error) -> Void)? { get set }
    /// Completes only after committing a displayable frame, with output silent.
    func prepare(project: WebProjectReference, scale: CGFloat) async throws
    func setGain(_ linearGain: Double) throws
    /// Complete left click in the rendered viewport's logical, top-left coordinates.
    func sendClick(at point: CGPoint, clickCount: Int) throws
    /// Cancels pending preparation and waits for all page resources to close.
    func close() async throws
}

@MainActor
protocol WebPageMaking: Sendable {
    func makePage(size: CGSize) throws -> any WebPageSession
}
