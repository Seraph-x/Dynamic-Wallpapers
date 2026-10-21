import AppKit
import SwiftUI
import WallpaperCore

@MainActor
final class FullScreenWallpaperState: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var mirror: WallpaperMirrorSession?
    @Published var failure: PresentedFailure?
    private var preparedImage: CGImage?
    private var makeMirror: (@MainActor () throws -> WallpaperMirrorSession)?
    private var activeMirror: WallpaperMirrorSession?
    private var isFullScreen = false
    private var generation = UUID()
    private var captureTask: Task<Void, Never>?
    private var mirrorTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Error>?
    private var cleanupRevision = UUID()
    private var cleanupFailure: PresentedFailure?

    var hasBackground: Bool { image != nil || mirror != nil }

    func prepare(mirror: (@MainActor () throws -> WallpaperMirrorSession)? = nil,
                 capture: @escaping @MainActor () async throws -> CGImage) {
        reset()
        makeMirror = mirror
        let generation = self.generation
        captureTask = Task { [weak self] in
            do {
                let image = try await capture()
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.preparedImage = image
                if self.isFullScreen { self.image = image }
                self.captureTask = nil
                self.startMirrorIfReady()
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    func activate() {
        guard !isFullScreen else { return }
        isFullScreen = true
        image = preparedImage
        startMirrorIfReady()
    }

    func reset() {
        cancelCapture()
        image = nil
        mirror = nil
        failure = cleanupFailure
    }

    func detach() {
        cancelCapture()
        let generation = generation
        // AppKit can detach this view while SwiftUI is destroying its graph.
        // Cancel work immediately, but publish cleanup after that update finishes.
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.image = nil
            self.mirror = nil
            self.failure = self.cleanupFailure
        }
    }

    private func cancelCapture() {
        generation = UUID()
        captureTask?.cancel()
        captureTask = nil
        mirrorTask?.cancel()
        mirrorTask = nil
        isFullScreen = false
        preparedImage = nil
        makeMirror = nil
        if let session = activeMirror {
            activeMirror = nil
            // AVSampleBufferDisplayLayer retains its last frame until SwiftUI removes
            // the representable. Hide it synchronously so a following window resize
            // cannot expose that frame in the normal window.
            session.view.isHidden = true
            session.onFailure = nil
            retire(session)
        }
    }

    private func startMirrorIfReady() {
        guard isFullScreen, let image = preparedImage, let makeMirror,
              activeMirror == nil, mirrorTask == nil else { return }
        let generation = generation
        let precedingCleanup = cleanupTask
        mirrorTask = Task { @MainActor [weak self] in
            do {
                try await precedingCleanup?.value
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                let session = try makeMirror()
                session.view.isHidden = false
                self.activeMirror = session
                session.onFailure = { [weak self, weak session] error in
                    guard let self, self.generation == generation, self.activeMirror === session else { return }
                    self.fail(error)
                }
                try await session.start(initialImage: image)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                self.mirror = session
                self.image = nil
                self.mirrorTask = nil
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        cancelCapture()
        image = nil
        mirror = nil
        let details = PresentedFailure(error)
        failure = PresentedFailure(title: "全屏背景无法显示", summary: details.summary,
                                   diagnostics: details.diagnostics)
    }

    private func retire(_ session: WallpaperMirrorSession) {
        let closing = session.beginClose()
        let tasks = [cleanupTask, closing].compactMap { $0 }
        cleanupRevision = UUID()
        cleanupTask = Task { @MainActor [weak self] in
            do { try await PlaybackCloseBarrier.wait(for: tasks) }
            catch {
                let details = PresentedFailure(error)
                let failure = PresentedFailure(title: "全屏背景无法关闭", summary: details.summary,
                                               diagnostics: details.diagnostics)
                self?.cleanupFailure = failure
                self?.failure = failure
                throw error
            }
        }
    }

    func waitForCleanup() async throws {
        while let task = cleanupTask {
            let revision = cleanupRevision
            try await task.value
            if revision == cleanupRevision { return }
        }
    }
}

struct FrozenWallpaperImage: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("fullscreen-wallpaper")
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contents = image
        CATransaction.commit()
    }
}
