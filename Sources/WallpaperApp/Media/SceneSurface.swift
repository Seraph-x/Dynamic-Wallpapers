import AppKit
import WallpaperCore
import WallpaperNative

@MainActor
final class SceneSurface: NSView, PlaybackSurface {
    var view: NSView { self }
    private(set) var state: PlaybackSurfaceState = .idle
    private(set) var releaseFailure: Error?
    var onError: ((Error) -> Void)?
    private let pageFactory: any ScenePageMaking
    private var page: (any ScenePageSession)?
    private var audio = AudioSettings()
    private var globallyMuted = true
    private var suppressed = false
    private var transitionGain = 1.0
    private var wantsPlayback = false
    private var identity = UUID()
    private var revision = 0
    private var closing = false
    private var reportedFailure: Error?
    private var commandTask: Task<Void, Never>?
    private var closeTask: Task<Void, Error>?
    private var clickStart: UUID?

    init(size: CGSize, fit: ContentFit, pageFactory: any ScenePageMaking) {
        self.pageFactory = pageFactory
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }

    override func layout() { super.layout(); subviews.forEach { $0.frame = bounds } }

    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        guard state == .idle, !closing else { throw WallpaperError("场景播放器已使用或关闭。") }
        guard item.kind == .scene, item.backend == .scene, let project = item.sceneProject else {
            throw WallpaperError("场景播放器需要明确的场景工程。")
        }
        try project.validate()
        guard scale.isFinite, scale > 0, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { throw WallpaperError("场景视口无效。") }
        state = .preparing
        do {
            let next = try pageFactory.makeScenePage(size: bounds.size)
            page = next
            next.onError = { [weak self] error in
                guard let self, !self.closing else { return }
                self.fail(error)
            }
            try next.setGain(0)
            try await withTaskCancellationHandler {
                try await next.prepare(project: project, scale: scale, fit: fit)
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.close() } catch { self.fail(error) }
                }
            }
            guard !closing else { throw CancellationError() }
            if let reportedFailure { throw reportedFailure }
            try next.setGain(0)
            next.view.frame = bounds
            next.view.autoresizingMask = [.width, .height]
            addSubview(next.view)
            state = .ready
        } catch {
            if !closing { fail(error) }
            throw error
        }
    }

    func play() {
        guard !closing, reportedFailure == nil,
              state == .ready || state == .paused || state == .pausing else { return }
        wantsPlayback = true
        enqueuePlaying(true)
    }

    func pause() {
        guard !closing, reportedFailure == nil, page != nil,
              state != .idle, state != .preparing else { return }
        wantsPlayback = false
        identity = UUID()
        do { try page?.setGain(0) } catch { fail(error); return }
        state = .pausing
        enqueuePlaying(false)
    }

    /// Serialize browser commands; revision checks prevent a late ack from
    /// applying an earlier intent or enabling audio after pause/close.
    private func enqueuePlaying(_ playing: Bool) {
        page?.setPlaybackIntent(playing)
        revision += 1
        let request = revision
        let previous = commandTask
        commandTask = Task { @MainActor [self] in
            await previous?.value
            guard !closing, reportedFailure == nil, let page else { return }
            do {
                try await page.setPlaying(playing)
                guard !closing, request == revision, reportedFailure == nil else { return }
                state = playing ? .playing : .paused
                applyAudio()
            } catch {
                if !closing { fail(error) }
            }
        }
    }

    func waitForPlaybackCommand() async { await commandTask?.value }

    func prepareToResume() async throws {
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        await commandTask?.value
        try Task.checkCancellation()
        if let reportedFailure { throw reportedFailure }
        guard !closing, !wantsPlayback, state == .paused || state == .ready else {
            throw WallpaperError("场景尚未暂停，不能准备恢复。")
        }
        try page?.setGain(0)
        state = .ready
    }

    func cancelResumePreparation() async throws {
        pause()
        await commandTask?.value
        if let reportedFailure { throw reportedFailure }
        guard !closing else { throw CancellationError() }
    }

    func setAudio(_ value: AudioSettings) {
        do { try value.validate(); audio = value; applyAudio() } catch { fail(error) }
    }
    func setTransitionGain(_ value: Double) {
        guard value.isFinite, (0...1).contains(value) else {
            fail(WallpaperError("场景过渡增益必须在 0 到 1 之间。")); return
        }
        transitionGain = value; applyAudio()
    }
    func setGlobalMute(_ value: Bool) { globallyMuted = value; applyAudio() }
    func setAudioSuppressed(_ value: Bool) { suppressed = value; applyAudio() }
    private func applyAudio() {
        let audible = !closing && reportedFailure == nil && wantsPlayback && state == .playing
            && !globallyMuted && !suppressed && !audio.isMuted
        do { try page?.setGain(audible ? audio.volume * transitionGain : 0) }
        catch { fail(error) }
    }
    private func fail(_ error: Error) {
        page?.setPlaybackIntent(false)
        state = .failed
        wantsPlayback = false
        guard reportedFailure == nil else { return }
        var failure = error
        do { try page?.setGain(0) }
        catch let gateError { failure = WallpaperErrorGroup([error, gateError]) }
        reportedFailure = failure
        onError?(failure)
    }

    var interactivePageID: UUID? {
        state == .playing && wantsPlayback && !closing && reportedFailure == nil ? identity : nil
    }
    @discardableResult
    func sendClick(at point: CGPoint, clickCount: Int, expectedPageID: UUID) throws -> Bool {
        guard clickCount > 0 else { throw WallpaperError("场景点击次数无效。") }
        try sendPointer(at: point, kind: "click", expectedPageID: expectedPageID)
        return true
    }
    func sendPointer(at point: CGPoint, kind: String, expectedPageID: UUID) throws {
        guard expectedPageID == interactivePageID, let page else { throw WallpaperError("场景已暂停或切换。") }
        guard point.x.isFinite, point.y.isFinite, bounds.width > 0, bounds.height > 0,
              point.x >= 0, point.y >= 0, point.x <= bounds.width, point.y <= bounds.height else {
            throw WallpaperError("场景鼠标坐标无效。")
        }
        try page.sendPointer(at: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height), kind: kind)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func topLeft(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - bounds.minX, y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
    }
    override func mouseDown(with event: NSEvent) { clickStart = interactivePageID }
    override func mouseDragged(with event: NSEvent) { clickStart = nil; mouseMoved(with: event) }
    override func mouseUp(with event: NSEvent) {
        defer { clickStart = nil }
        guard let clickStart else { return }
        do { try sendClick(at: topLeft(event), clickCount: event.clickCount, expectedPageID: clickStart) }
        catch { onError?(error) }
    }
    override func mouseMoved(with event: NSEvent) {
        guard let id = interactivePageID else { return }
        do { try sendPointer(at: topLeft(event), kind: "move", expectedPageID: id) } catch { onError?(error) }
    }
    override func mouseExited(with event: NSEvent) {
        guard let id = interactivePageID else { return }
        do { try sendPointer(at: .zero, kind: "leave", expectedPageID: id) } catch { onError?(error) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func close() async throws {
        if let closeTask { try await closeTask.value; return }
        closing = true
        wantsPlayback = false
        identity = UUID()
        revision += 1
        state = .closing
        let retiring = page
        retiring?.onError = nil
        // Gate before the first suspension, then still close after a gate error.
        var gateFailure: Error?
        do { try retiring?.setGain(0) } catch { gateFailure = error }
        let task = Task { @MainActor [self, gateFailure] in
            do {
                try await retiring?.close()
                await commandTask?.value
                page = nil
                subviews.forEach { $0.removeFromSuperview() }
                if let gateFailure { throw gateFailure }
                state = .closed
                onError = nil
            } catch {
                releaseFailure = error
                state = .failed
                throw error
            }
        }
        closeTask = task
        try await task.value
    }
}
