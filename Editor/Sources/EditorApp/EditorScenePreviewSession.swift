import AppKit
import WallpaperCore

@MainActor protocol EditorScenePreviewPage: AnyObject {
    var view: NSView { get }
    var origin: String { get }
    var onReady: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onDiagnostic: (([String: Any]) -> Void)? { get set }
    func start() throws
    func setPlaying(_ value: Bool) async throws
    func close() async throws
}

/// Owns one immutable snapshot until every acquired native page has released.
@MainActor final class EditorScenePreviewSession {
    enum State: String { case idle, loading, playing, paused, failed, closing, closed }
    private let makePage: () throws -> any EditorScenePreviewPage
    private let cleanup: () async throws -> Void
    private var page: (any EditorScenePreviewPage)?
    private var generation = UUID()
    private(set) var state: State = .idle
    private(set) var busy = false
    private(set) var failure: Error?
    private(set) var diagnostic: [String: Any]?
    var onChange: (() -> Void)?
    var view: NSView? { page?.view }
    var origin: String? { page?.origin }

    init(makePage: @escaping () throws -> any EditorScenePreviewPage,
         cleanup: @escaping () async throws -> Void) {
        self.makePage = makePage; self.cleanup = cleanup
    }

    func start() throws {
        guard state == .idle else { throw WallpaperError("Preview has already started") }
        try mount()
    }

    private func mount() throws {
        generation = UUID(); let capturedGeneration = generation
        failure = nil; diagnostic = nil; state = .loading
        do {
            let acquired = try makePage(); page = acquired
            acquired.onReady = { [weak self] in
                guard let self, self.generation == capturedGeneration, self.state == .loading else { return }
                self.state = .playing; self.onChange?()
            }
            acquired.onError = { [weak self] error in
                guard let self, self.generation == capturedGeneration,
                      self.state != .closing, self.state != .closed else { return }
                self.fail(error)
            }
            acquired.onDiagnostic = { [weak self] diagnostic in
                guard let self, self.generation == capturedGeneration,
                      self.state != .closing, self.state != .closed else { return }
                self.diagnostic = diagnostic; self.onChange?()
            }
            onChange?() // Attach the native view before starting its child browser.
            try acquired.start()
        } catch { fail(error); throw error }
    }

    func setPlaying(_ value: Bool) async throws {
        guard !busy, [.playing, .paused].contains(state), let page else {
            throw WallpaperError("Preview is not ready for playback commands")
        }
        busy = true; onChange?(); defer { busy = false; onChange?() }
        do {
            try await page.setPlaying(value)
            if let failure { throw failure }
            state = value ? .playing : .paused
        } catch { fail(error); throw error }
    }

    func restart() async throws {
        guard !busy, state != .closed, state != .idle else {
            throw WallpaperError("Preview is busy or closed")
        }
        busy = true; onChange?(); defer { busy = false; onChange?() }
        do { try await releasePage(); try mount() }
        catch { fail(error); throw error }
    }

    func close() async throws {
        if state == .closed { return }
        guard !busy else { throw WallpaperError("Preview operation is still in progress") }
        busy = true; onChange?(); defer { busy = false; onChange?() }
        do {
            try await releasePage()
            try await cleanup()
            state = .closed; failure = nil; diagnostic = nil
        } catch { fail(error); throw error }
    }

    private func releasePage() async throws {
        // Invalidate ready/error/diagnostic callbacks before the asynchronous close.
        generation = UUID(); state = .closing; onChange?()
        if let page {
            try await page.close()
            self.page = nil; onChange?()
        }
    }

    private func fail(_ error: Error) {
        failure = error; state = .failed; onChange?()
    }
}
