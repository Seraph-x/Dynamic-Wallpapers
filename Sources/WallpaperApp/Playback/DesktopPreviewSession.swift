import AppKit
import WallpaperCore

struct DesktopPreviewTarget: Hashable {
    let displayID: String?
    let fit: ContentFit
}

/// A silent desktop copy. The inspector remains the only preview audio source.
@MainActor
final class DesktopPreviewSession {
    private struct Geometry: Equatable {
        let frame: CGRect
        let scale: CGFloat
        init(_ screen: NSScreen) { frame = screen.frame; scale = screen.backingScaleFactor }
    }

    let id: UUID
    let displayIDs: Set<String>
    private let item: MediaItem
    private let target: DesktopPreviewTarget
    private let geometry: [String: Geometry]
    private let windows: [String: DesktopWindow]
    private let beforeStart: (Set<String>) async throws -> Void
    private let releaseSources: (Set<String>) -> Task<Void, Error>?
    private let onChange: () -> Void
    private let onError: (Error) -> Void
    private let onRelease: () -> Void
    private var prepared = false
    private var closeTask: Task<Void, Error>?
    private(set) var isActive = false
    var activeSurfaceCount: Int { windows.values.reduce(0) { $0 + $1.activeSurfaceCount } }

    init(id: UUID, item: MediaItem, target: DesktopPreviewTarget, screens: [String: NSScreen],
         surfaceFactory: any SurfaceMaking, beforeStart: @escaping (Set<String>) async throws -> Void,
         releaseSources: @escaping (Set<String>) -> Task<Void, Error>?,
         onChange: @escaping () -> Void, onError: @escaping (Error) -> Void, onRelease: @escaping () -> Void) {
        self.id = id; self.item = item; self.target = target
        displayIDs = Set(screens.keys)
        geometry = screens.mapValues(Geometry.init)
        windows = screens.mapValues { DesktopWindow(screen: $0, surfaceFactory: surfaceFactory, role: .preview) }
        self.beforeStart = beforeStart; self.onChange = onChange
        self.releaseSources = releaseSources
        self.onError = onError; self.onRelease = onRelease
        for window in windows.values {
            window.setGlobalMute(true)
            window.onPlaybackError = { [weak self] in self?.fail($0) }
        }
    }

    func window(on displayID: String) -> DesktopWindow? {
        guard isActive, let window = windows[displayID], window.hasVisibleWallpaper else { return nil }
        return window
    }

    func prepare() async throws {
        try checkOpen()
        let entry = PlaylistEntry(mediaID: item.id, audio: AudioSettings(isMuted: true))
        let prepareWindow: @MainActor @Sendable (DesktopWindow) async throws -> Void = {
            [item, target] window in
            try await window.prepare(item: item, fit: target.fit, entry: entry)
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for window in windows.values {
                    group.addTask { try await prepareWindow(window) }
                }
                do { while try await group.next() != nil { } }
                catch {
                    // Stop real backends before the group waits for cancelled preparations.
                    beginClose()
                    throw error
                }
            }
            try checkOpen()
            prepared = true
        } catch {
            let closing = beginClose()
            do { try await closing.value }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }

    func start() async throws {
        try checkOpen()
        guard prepared else { throw WallpaperError("桌面预览尚未准备就绪。") }
        try await beforeStart(displayIDs)
        try checkOpen()
        isActive = true
        onChange()
        let transitionWindow: @MainActor @Sendable (DesktopWindow) async -> PlaybackTransitionResult = {
            await $0.transition(duration: 0, paused: false)
        }
        let results = await withTaskGroup(of: PlaybackTransitionResult.self) { group in
            for window in windows.values {
                group.addTask { await transitionWindow(window) }
            }
            var results: [PlaybackTransitionResult] = []
            for await result in group { results.append(result) }
            return results
        }
        try checkOpen()
        let errors = results.compactMap(\.error)
        guard errors.isEmpty else {
            beginClose()
            throw WallpaperErrorGroup(errors)
        }
        onChange()
    }

    func refreshScreens(_ screens: [String: NSScreen]) {
        guard closeTask == nil else { return }
        let selected = target.displayID.map { id in screens.filter { $0.key == id } } ?? screens
        guard selected.mapValues(Geometry.init) != geometry else { return }
        fail(WallpaperError("显示器配置已变化，预览已停止，请重新播放预览。"))
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard closeTask == nil else { throw CancellationError() }
    }

    private func fail(_ error: Error) {
        guard closeTask == nil else { return }
        beginClose()
        onError(error)
    }

    @discardableResult
    func beginClose() -> Task<Void, Error> {
        if let closeTask { return closeTask }
        isActive = false
        // Switch consumers first. An in-flight screenshot still requires a live window.
        onChange()
        let sourceRelease = releaseSources(displayIDs)
        windows.values.forEach { $0.invalidatePresentation() }
        let task = Task { @MainActor in
            var failures: [Error] = []
            do { try await sourceRelease?.value } catch { failures.append(error) }
            self.windows.values.forEach { $0.onPlaybackError = nil; $0.shutdown() }
            do {
                try await PlaybackCloseBarrier.wait(for: self.windows.values.map { window in
                    Task { @MainActor in try await window.waitForClosing() }
                })
            } catch { failures.append(error) }
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
            self.onRelease()
        }
        closeTask = task
        return task
    }
}
