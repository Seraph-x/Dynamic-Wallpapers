import WallpaperNative
import AppKit
import WallpaperCore

/// The application owns one preview slot, independently of SwiftUI view lifetimes.
@MainActor
final class PreviewLifetime {
    struct Request {
        let id: UUID
        let item: MediaItem
        let size: CGSize
        let scale: CGFloat
        let fit: ContentFit
        let desktopTarget: DesktopPreviewTarget?

        init(id: UUID, item: MediaItem, size: CGSize, scale: CGFloat, fit: ContentFit,
             desktopTarget: DesktopPreviewTarget? = nil) {
            self.id = id; self.item = item; self.size = size
            self.scale = scale; self.fit = fit; self.desktopTarget = desktopTarget
        }
    }

    private final class Instance {
        let id: UUID
        let mediaID: UUID
        let surface: any PlaybackSurface
        var reportError: (Error) -> Void
        var closeTask: Task<Void, Error>?
        var releaseFailure: Error?
        var desktop: DesktopPreviewSession?

        init(id: UUID, mediaID: UUID, surface: any PlaybackSurface, reportError: @escaping (Error) -> Void) {
            self.id = id; self.mediaID = mediaID; self.surface = surface; self.reportError = reportError
        }
    }

    private let surfaceFactory: any SurfaceMaking
    private let desktopPreviews: DesktopPreviewController?
    private var instance: Instance?
    private var generation: UUID?
    private var latestRequestID: UUID?
    private var preparation: (id: UUID, mediaID: UUID, task: Task<Void, Error>)?
    private var removedMediaIDs = Set<UUID>()
    private var stopped = false
    private var powerPaused = false
    private var stopHandler: (id: UUID, action: () -> Void)?
    var activeSurfaceCount: Int { instance == nil ? 0 : 1 }
    var activeDesktopSurfaceCount: Int { instance?.desktop?.activeSurfaceCount ?? 0 }
    var releaseFailure: Error? { instance?.releaseFailure }

    init(surfaceFactory: any SurfaceMaking = SurfaceFactory(), desktopPreviews: DesktopPreviewController? = nil) {
        self.surfaceFactory = surfaceFactory; self.desktopPreviews = desktopPreviews
    }

    func surface(for id: UUID) -> (any PlaybackSurface)? {
        instance?.id == id ? instance?.surface : nil
    }

    func isCurrent(_ id: UUID) -> Bool {
        !stopped && generation == id && instance?.id == id && instance?.closeTask == nil
    }

    func updateErrorHandler(_ report: @escaping (Error) -> Void, for id: UUID) {
        if instance?.id == id { instance?.reportError = report }
    }

    func updateStopHandler(_ action: @escaping () -> Void, for id: UUID) {
        if stopHandler?.id == id { stopHandler = (id, action) }
    }

    func setPowerPaused(_ value: Bool) {
        powerPaused = value
        if value { stopCurrent() }
    }

    /// Reports operational failures and still throws; callers must not turn failure into playback.
    func prepare(_ request: Request, configure: @escaping (any PlaybackSurface) throws -> Void,
                 onError: @escaping (Error) -> Void, onStop: @escaping () -> Void = {}) async throws -> any PlaybackSurface {
        try Task.checkCancellation()
        guard !removedMediaIDs.contains(request.item.id) else { throw CancellationError() }
        guard !stopped else {
            let error = WallpaperError("预览资源已关闭，不能启动新的预览。")
            onError(error)
            throw error
        }
        latestRequestID = request.id
        if powerPaused {
            let error = WallpaperError("当前电源或会话状态要求暂停，暂时无法播放预览。")
            onError(error)
            notifyStop(request.id, action: onStop)
            throw error
        }
        generation = request.id
        stopHandler = (request.id, onStop)
        preparation?.task.cancel()
        let previousClose = instance.map { beginClosing($0) }
        let task = Task { @MainActor in
            try await self.load(request, previousClose: previousClose, configure: configure, onError: onError)
        }
        preparation = (request.id, request.item.id, task)
        defer { if preparation?.id == request.id { preparation = nil } }
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
                Task { @MainActor [weak self] in self?.cancel(request.id) }
            }
            guard isCurrent(request.id), let surface = surface(for: request.id) else { throw CancellationError() }
            return surface
        } catch {
            if let closing = cancel(request.id) { try await closing.value }
            throw error
        }
    }

    private func load(_ request: Request, previousClose: Task<Void, Error>?,
                      configure: (any PlaybackSurface) throws -> Void, onError: @escaping (Error) -> Void) async throws {
        do {
            if let previousClose { try await previousClose.value }
            try Task.checkCancellation()
            guard !stopped, generation == request.id else { throw CancellationError() }
            let surface = try surfaceFactory.makeSurface(item: request.item, size: request.size, fit: request.fit)
            let record = Instance(id: request.id, mediaID: request.item.id, surface: surface, reportError: onError)
            instance = record
            let handleFailure: (Error) -> Void = { [weak self] error in
                guard let self, self.isCurrent(request.id) else { return }
                self.instance?.reportError(error)
                self.stopCurrent()
            }
            surface.onError = handleFailure
            if let target = request.desktopTarget {
                guard let desktopPreviews else { throw WallpaperError("桌面预览协调器未配置，无法启动桌面预览。") }
                record.desktop = try desktopPreviews.makeSession(id: request.id, item: request.item, target: target,
                    onError: handleFailure)
            }
            try configure(surface)
            try Task.checkCancellation()
            guard isCurrent(request.id) else { throw CancellationError() }
            try await surface.prepare(item: request.item, scale: request.scale, fit: request.fit)
            try Task.checkCancellation()
            guard isCurrent(request.id) else { throw CancellationError() }
            try await record.desktop?.prepare()
            try Task.checkCancellation()
            guard isCurrent(request.id) else { throw CancellationError() }
        } catch {
            if !(error is CancellationError), generation == request.id {
                onError(error)
                stopCurrent()
            }
            throw error
        }
    }

    /// Both copies prepare before either starts; only the inspector produces sound.
    func play(_ id: UUID) async throws {
        guard isCurrent(id), let instance else { throw CancellationError() }
        do {
            try await instance.desktop?.start()
            try Task.checkCancellation()
            guard isCurrent(id) else { throw CancellationError() }
            instance.surface.play()
        } catch {
            if !(error is CancellationError), isCurrent(id) {
                instance.reportError(error)
                stopCurrent()
            }
            if let closing = cancel(id) { try await closing.value }
            throw error
        }
    }

    /// External stops (apply, host close, power events) also reset the existing button.
    @discardableResult
    func stop(_ id: UUID) -> Task<Void, Error>? {
        guard generation == id else { return cancel(id) }
        return stopCurrent()
    }

    @discardableResult
    func stopCurrent() -> Task<Void, Error>? {
        guard let id = generation else { return nil }
        let action = stopHandler?.id == id ? stopHandler?.action : nil
        let closing = cancel(id)
        if let action { notifyStop(id, action: action) }
        return closing
    }

    private func notifyStop(_ id: UUID, action: @escaping () -> Void) {
        // SwiftUI may still be dismantling its graph; never publish from that stack.
        Task { @MainActor [weak self] in
            guard let self, self.generation == nil, self.latestRequestID == id else { return }
            action()
        }
    }

    /// Cancels only this generation; stale coordinators cannot close their successors.
    @discardableResult
    func cancel(_ id: UUID) -> Task<Void, Error>? {
        if generation == id { generation = nil }
        if stopHandler?.id == id { stopHandler = nil }
        if preparation?.id == id { preparation?.task.cancel() }
        guard let instance, instance.id == id else { return nil }
        return beginClosing(instance)
    }

    private func beginClosing(_ record: Instance) -> Task<Void, Error> {
        if let existing = record.closeTask { return existing }
        record.surface.setAudioSuppressed(true)
        record.surface.onError = nil
        record.surface.view.removeFromSuperview()
        let desktopClosing = record.desktop?.beginClose()
        let task = Task { @MainActor in
            do {
                let inlineClosing = Task { @MainActor in try await record.surface.close() }
                try await PlaybackCloseBarrier.wait(for: [inlineClosing, desktopClosing].compactMap { $0 })
                if self.instance?.id == record.id { self.instance = nil }
            } catch {
                record.releaseFailure = error
                // Keep both the backend and reporter after its SwiftUI coordinator disappears.
                record.reportError(error)
                throw error
            }
        }
        record.closeTask = task
        return task
    }

    /// Waits for already-started releases. The single slot permits at most one close.
    func waitForClosing() async throws {
        let tasks = instance?.closeTask.map { [$0] } ?? []
        try await PlaybackCloseBarrier.wait(for: tasks)
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        removedMediaIDs.formUnion(ids)
        let preparing = preparation.flatMap { ids.contains($0.mediaID) ? $0 : nil }
        if let preparing {
            if generation == preparing.id { stopCurrent() }
            else { cancel(preparing.id) }
        }
        let closing = instance.flatMap { ids.contains($0.mediaID) ? beginClosing($0) : nil }
        if let instance, ids.contains(instance.mediaID), generation == instance.id { stopCurrent() }
        return Task {
            try await closing?.value
            if let preparing { _ = await preparing.task.result }
        }
    }

    /// Terminal application shutdown: no later request may allocate a new preview.
    func closeAll() async throws {
        stopped = true
        generation = nil
        stopHandler = nil
        let preparing = preparation?.task
        preparing?.cancel()
        let closing = instance.map { beginClosing($0) }
        try await PlaybackCloseBarrier.wait(for: closing.map { [$0] } ?? [])
        // Successful close guarantees the backend preparation can no longer recreate resources.
        // Failed close throws above and keeps the occupied slot, without claiming it stopped.
        if let preparing { _ = await preparing.result }
    }
}
