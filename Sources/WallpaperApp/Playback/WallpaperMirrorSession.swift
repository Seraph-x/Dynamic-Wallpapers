import AppKit
import Combine
import WallpaperCore

typealias WallpaperMirrorFactory = @MainActor (NSScreen) throws -> WallpaperMirrorSession

@MainActor
struct WallpaperMirrorSource {
    let window: NSWindow
    var needsSystemUnderlay = false
}

@MainActor
final class WallpaperMirrorSession {
    private struct SourceKey: Equatable {
        let window: ObjectIdentifier?
        let size: CGSize
        let scale: CGFloat

        @MainActor init(_ source: WallpaperMirrorSource?) {
            window = source.map { ObjectIdentifier($0.window) }
            size = source?.window.frame.size ?? .zero
            scale = source?.window.backingScaleFactor ?? 1
        }
    }

    let view = WallpaperMirrorView()
    var onFailure: ((Error) -> Void)?
    var onClose: ((Result<Void, Error>) -> Void)?
    private(set) var failure: Error?
    private(set) var isClosed = false
    private let source: () throws -> WallpaperMirrorSource?
    private let systemWallpaper: () throws -> CGImage
    private let changes: AnyPublisher<Void, Never>
    private let makeStream: (NSWindow, WallpaperMirrorView) async throws -> WallpaperMirrorStream
    private var subscription: AnyCancellable?
    private var stream: WallpaperMirrorStream?
    private var requestedKey: SourceKey?
    private var revision = UUID()
    private var updateTask: Task<Void, Error>?
    private var sourceReleaseTask: Task<Void, Error>?
    private var closeTask: Task<Void, Error>?

    init(source: @escaping () throws -> WallpaperMirrorSource?,
         systemWallpaper: @escaping () throws -> CGImage,
         changes: AnyPublisher<Void, Never>,
         makeStream: @escaping (NSWindow, WallpaperMirrorView) async throws -> WallpaperMirrorStream = {
             try await WallpaperMirrorStream.makeScreenshot(window: $0, view: $1)
         }) {
        self.source = source
        self.systemWallpaper = systemWallpaper
        self.changes = changes
        self.makeStream = makeStream
    }

    var statistics: WallpaperMirrorFrameOutput.Statistics? { stream?.output.statistics }

    func start(initialImage: CGImage) async throws {
        guard subscription == nil, closeTask == nil else { throw CancellationError() }
        view.setUnderlay(initialImage)
        subscription = changes.sink { [weak self] in self?.refresh() }
        refresh()
        try await waitForUpdates()
    }

    func waitForUpdates() async throws {
        while let task = updateTask {
            let currentRevision = revision
            let result = await task.result
            guard closeTask == nil else { throw CancellationError() }
            if let failure { throw failure }
            if currentRevision != revision { continue }
            try result.get()
            return
        }
        if let failure { throw failure }
        if closeTask != nil { throw CancellationError() }
    }

    /// Snapshot this barrier synchronously after publishing a source change. It excludes
    /// the replacement's factory/start, which must not hold the retired window alive.
    func sourceReleaseBarrier() -> Task<Void, Error>? {
        if let closeTask { return closeTask }
        if failure != nil { return beginClose() }
        return sourceReleaseTask
    }

    private func refresh() {
        guard closeTask == nil, failure == nil else { return }
        do {
            let target = try source()
            let key = SourceKey(target)
            guard key != requestedKey else { return }
            requestedKey = key
            revision = UUID()
            let revision = revision
            let previous = updateTask
            previous?.cancel()
            // Invalidate frame delivery before a retiring desktop window can disappear.
            stream?.beginClose()
            let releasing = Task { @MainActor in
                _ = await previous?.result
                try await self.releaseStream()
            }
            sourceReleaseTask = releasing
            updateTask = Task { @MainActor in
                do {
                    try await releasing.value
                    try self.checkRevision(revision)
                    try await self.replaceSource(target, revision: revision)
                }
                catch is CancellationError { throw CancellationError() }
                catch { self.report(error); throw error }
            }
        } catch { report(error) }
    }

    private func replaceSource(_ target: WallpaperMirrorSource?, revision: UUID) async throws {
        try checkRevision(revision)
        guard let target else {
            view.setUnderlay(try systemWallpaper())
            return
        }
        if target.needsSystemUnderlay { view.setUnderlay(try systemWallpaper()) }
        let candidate: WallpaperMirrorStream
        do { candidate = try await makeStream(target.window, view) }
        catch {
            // A superseded factory has no returned resource to retire. Its error
            // belongs to that revision, not the replacement currently waiting.
            try checkRevision(revision)
            throw error
        }
        stream = candidate
        candidate.onFailure = { [weak self, weak candidate] error in
            guard let self, let candidate, self.stream === candidate,
                  self.revision == revision, self.closeTask == nil else { return }
            self.report(error)
            candidate.beginClose()
        }
        do {
            try checkRevision(revision)
            try await candidate.start()
            try checkRevision(revision)
        } catch {
            do { try await releaseStream() }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            // Cleanup failures above remain fatal even for cancelled revisions.
            try checkRevision(revision)
            throw error
        }
    }

    private func releaseStream() async throws {
        guard let stream else { return }
        try await stream.beginClose().value
        if self.stream === stream { self.stream = nil }
    }

    private func checkRevision(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard self.revision == revision, closeTask == nil else { throw CancellationError() }
        if let failure { throw failure }
    }

    private func report(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onFailure?(error)
    }

    @discardableResult
    func beginClose() -> Task<Void, Error> {
        if let closeTask { return closeTask }
        revision = UUID()
        subscription?.cancel()
        subscription = nil
        let updating = updateTask
        updating?.cancel()
        stream?.beginClose()
        let task = Task { @MainActor in
            _ = await updating?.result
            do {
                try await self.releaseStream()
                self.view.setUnderlay(nil)
                self.updateTask = nil
                self.sourceReleaseTask = nil
                self.onFailure = nil
                self.isClosed = true
                self.onClose?(.success(()))
                self.onClose = nil
            } catch {
                self.onClose?(.failure(error))
                throw error
            }
        }
        closeTask = task
        return task
    }
}
