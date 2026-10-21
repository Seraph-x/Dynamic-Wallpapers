import AppKit
import WallpaperCore

/// Shares desktop source selection with normal playback without editing its bindings.
@MainActor
final class DesktopPreviewController {
    private let surfaceFactory: any SurfaceMaking
    private let screenProvider: () -> [String: NSScreen]
    private var session: DesktopPreviewSession?
    private var stopped = false
    var beforeStart: ((Set<String>) async throws -> Void)?
    var releaseSources: ((Set<String>) -> Task<Void, Error>?)?
    var onChange: (() -> Void)?
    var suspendedDisplayIDs: Set<String> {
        guard let session, session.isActive else { return [] }
        return session.displayIDs
    }
    var visibleDisplayIDs: Set<String> {
        guard let session else { return [] }
        return Set(session.displayIDs.filter { session.window(on: $0) != nil })
    }

    init(surfaceFactory: any SurfaceMaking, screenProvider: @escaping () -> [String: NSScreen]) {
        self.surfaceFactory = surfaceFactory; self.screenProvider = screenProvider
    }

    func makeSession(id: UUID, item: MediaItem, target: DesktopPreviewTarget,
                     onError: @escaping (Error) -> Void) throws -> DesktopPreviewSession {
        guard !stopped else { throw WallpaperError("应用正在退出，无法开始桌面预览。") }
        guard session == nil else { throw WallpaperError("上一轮桌面预览资源尚未释放，无法开始新的预览。") }
        let screens = screenProvider()
        if let displayID = target.displayID, screens[displayID] == nil {
            throw WallpaperError("目标显示器已断开，请重新选择显示器。")
        }
        let selected = target.displayID.map { id in screens.filter { $0.key == id } } ?? screens
        guard !selected.isEmpty else { throw WallpaperError("没有可用于预览的显示器。") }
        let candidate = DesktopPreviewSession(id: id, item: item, target: target, screens: selected,
            surfaceFactory: surfaceFactory, beforeStart: { [weak self] ids in
                guard let self, !self.stopped, self.session?.id == id else { throw CancellationError() }
                try await self.beforeStart?(ids)
            }, releaseSources: { [weak self] ids in
                self?.releaseSources?(ids)
            }, onChange: { [weak self] in self?.onChange?() }, onError: onError,
            onRelease: { [weak self] in
                guard let self, self.session?.id == id else { return }
                self.session = nil
            })
        session = candidate
        return candidate
    }

    func window(on displayID: String) -> DesktopWindow? { session?.window(on: displayID) }
    func refreshScreens(_ screens: [String: NSScreen]) { session?.refreshScreens(screens) }

    func shutdown() {
        stopped = true
        session?.beginClose()
    }

    func waitForShutdown() async throws {
        if let session { try await session.beginClose().value }
    }
}
