import AppKit
import WallpaperNative

@MainActor
protocol DesktopInteractiveSurface: PlaybackSurface {
    var interactivePageID: UUID? { get }
    @discardableResult
    func sendClick(at point: CGPoint, clickCount: Int, expectedPageID: UUID) throws -> Bool
}

extension WebSurface: DesktopInteractiveSurface {}
extension SceneSurface: DesktopInteractiveSurface {}
