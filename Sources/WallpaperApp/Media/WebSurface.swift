import WallpaperNative
import AppKit
import WallpaperCore

@MainActor
final class WebSurface: NSView, PlaybackSurface {
    var view: NSView { self }
    private(set) var state: PlaybackSurfaceState = .idle
    var onError: ((Error) -> Void)?
    private let pageFactory: any WebPageMaking
    private var page: (any WebPageSession)?
    private var pageSize: CGSize = .zero
    private var clickStart: (pageID: UUID, clickCount: Int)?
    private var stagedResumeView: NSView?
    private var generation = UUID()
    private var project: WebProjectReference?
    private var scale: CGFloat = 1
    private var fit: ContentFit
    private var audio = AudioSettings()
    private var globallyMuted = true
    private var suppressed = false
    private var transitionGain = 1.0
    private var wantsPlayback = false
    private var resumePreparationRequested = false
    @MainActor
    private final class ResumeRequest {
        var release: Task<Void, Error>?
    }
    private var resumeRequest: ResumeRequest?
    private var finalClose = false
    private var closeFailure: Error?
    var releaseFailure: Error? { closeFailure }
    private var reportedFailure: Error?
    private var releaseTask: Task<Void, Error>?
    private var reloadTask: Task<Void, Error>?
    private var activePreparations = 0
    private var preparationExitWaiters: [CheckedContinuation<Void, Never>] = []

    init(size: CGSize, fit: ContentFit, pageFactory: any WebPageMaking) {
        self.pageFactory = pageFactory
        self.fit = fit
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }

    var interactivePageID: UUID? {
        guard state == .playing, !finalClose, closeFailure == nil, reportedFailure == nil, page != nil else { return nil }
        return generation
    }

    /// False identifies a fit-mode letterbox click, where no webpage was drawn.
    @discardableResult
    func sendClick(at point: CGPoint, clickCount: Int, expectedPageID: UUID) throws -> Bool {
        guard expectedPageID == interactivePageID, let page else { throw WallpaperError("网页已暂停或切换，点击已取消。") }
        guard clickCount > 0, clickCount <= Int(Int32.max), point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < bounds.width, point.y < bounds.height else {
            throw WallpaperError("网页点击坐标或次数无效。")
        }
        guard let projected = projectedClick(point) else { return false }
        try page.sendClick(at: projected, clickCount: clickCount)
        return true
    }

    private func projectedClick(_ point: CGPoint) -> CGPoint? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let factors = (bounds.width / pageSize.width, bounds.height / pageSize.height)
        let factor = fit == .fill ? max(factors.0, factors.1) : min(factors.0, factors.1)
        guard factor.isFinite, factor > 0 else { return nil }
        let origin = CGPoint(x: (bounds.width - pageSize.width * factor) / 2,
                             y: (bounds.height - pageSize.height * factor) / 2)
        let projected = CGPoint(x: (point.x - origin.x) / factor, y: (point.y - origin.y) / factor)
        return CGRect(origin: .zero, size: pageSize).contains(projected) ? projected : nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: point.x - bounds.minX, y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
        clickStart = projectedClick(topLeft) == nil ? nil : interactivePageID.map { ($0, event.clickCount) }
    }
    override func mouseDragged(with event: NSEvent) { clickStart = nil }
    override func mouseUp(with event: NSEvent) {
        defer { clickStart = nil }
        guard let clickStart, clickStart.pageID == interactivePageID, clickStart.clickCount == event.clickCount else { return }
        let point = convert(event.locationInWindow, from: nil)
        let topLeft = CGPoint(x: point.x - bounds.minX, y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
        guard CGRect(origin: .zero, size: bounds.size).contains(topLeft) else { return }
        do { try sendClick(at: topLeft, clickCount: event.clickCount, expectedPageID: clickStart.pageID) }
        catch { onError?(error) }
    }

    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        guard state == .idle else { throw WallpaperError("网页播放器已准备或关闭，无法重新初始化。") }
        guard item.backend == .web, item.kind == .web, let project = item.webProject else {
            throw WallpaperError("网页播放器需要明确的网页项目。")
        }
        try project.validate()
        guard scale.isFinite, scale > 0, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { throw WallpaperError("网页视口尺寸无效。") }
        self.project = project; self.scale = scale; self.fit = fit
        try await loadPage()
    }

    private func loadPage(mountWhenReady: Bool = true) async throws {
        guard !finalClose, closeFailure == nil, let project else { throw CancellationError() }
        activePreparations += 1
        defer {
            activePreparations -= 1
            if activePreparations == 0 {
                let waiters = preparationExitWaiters
                preparationExitWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        let token = UUID()
        generation = token
        state = .preparing
        do {
            let next = try pageFactory.makePage(size: bounds.size)
            pageSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
            page = next
            next.onError = { [weak self] error in
                guard let self, self.generation == token, !self.finalClose else { return }
                self.fail(error)
            }
            try next.setGain(0)
            try await withTaskCancellationHandler {
                try await next.prepare(project: project, scale: scale)
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.wantsPlayback = false
                    self.beginRelease()
                }
            }
            guard generation == token, !finalClose else { throw CancellationError() }
            if let reportedFailure { throw reportedFailure }
            try next.setGain(0)
            let content = next.view
            content.frame = bounds
            content.autoresizingMask = [.width, .height]
            content.layer?.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
            if mountWhenReady { mount(content) }
            else { stagedResumeView = content }
            state = .ready
        } catch {
            guard generation == token, !finalClose else { throw CancellationError() }
            if error is CancellationError {
                wantsPlayback = false
                beginRelease()
            } else { fail(error) }
            throw error
        }
    }

    func play() {
        guard !finalClose, closeFailure == nil, state != .failed else { return }
        resumeRequest = nil
        resumePreparationRequested = false
        wantsPlayback = true
        if state == .ready {
            if let stagedResumeView { mount(stagedResumeView); self.stagedResumeView = nil }
            state = .playing
            applyAudio()
        } else if state == .pausing || state == .paused {
            startReloadIfNeeded()
        }
    }

    private func mount(_ content: NSView) {
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(content)
    }

    func pause() {
        wantsPlayback = false
        guard !finalClose, state != .closed, state != .idle else { return }
        beginRelease()
        resumeRequest = nil
        resumePreparationRequested = false
    }

    private func beginRelease() {
        if let releaseTask { resumeRequest?.release = releaseTask; return }
        guard closeFailure == nil else { return }
        stagedResumeView = nil
        generation = UUID()
        if state != .failed { state = finalClose ? .closing : .pausing }
        page?.onError = nil
        do { try page?.setGain(0) } catch { fail(error) }
        let retiring = page
        releaseTask = Task { @MainActor [self] in
            do {
                try await retiring?.close()
                // A resumed prepare continuation may still be unwinding its method.
                await waitForPreparationExit()
                page = nil
                if state != .failed { state = finalClose ? .closed : .paused }
            } catch {
                closeFailure = error
                fail(error)
                throw error
            }
        }
        resumeRequest?.release = releaseTask
    }

    private func awaitRelease() async throws {
        if let closeFailure { throw closeFailure }
        if let releaseTask { try await releaseTask.value }
        if let closeFailure { throw closeFailure }
    }

    private func waitForPreparationExit() async {
        guard activePreparations > 0 else { return }
        await withCheckedContinuation { preparationExitWaiters.append($0) }
    }

    private func startReloadIfNeeded() {
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor [self] in
            defer {
                reloadTask = nil
                // A newer play intent can arrive while this cancelled load is draining.
                if !finalClose, wantsPlayback, state == .pausing || state == .paused {
                    startReloadIfNeeded()
                }
            }
            try await awaitRelease()
            guard !finalClose, state != .failed else { throw CancellationError() }
            guard wantsPlayback || resumePreparationRequested else { return }
            releaseTask = nil
            try await loadPage(mountWhenReady: false)
            if wantsPlayback { play() }
        }
        let task = reloadTask!
        Task { @MainActor [weak self] in
            do { try await task.value }
            catch is CancellationError { /* Explicit cancellation or terminal close. */ }
            catch { self?.fail(error) }
        }
    }

    /// Group coordinators call this before allowing any member to play.
    func prepareToResume() async throws {
        let request = ResumeRequest()
        resumeRequest = request
        defer {
            if resumeRequest === request {
                resumeRequest = nil
                resumePreparationRequested = false
            }
        }
        if Task.isCancelled { try await cancelResume(request) }
        if let closeFailure { throw closeFailure }
        if let reportedFailure { throw reportedFailure }
        guard !finalClose else { throw CancellationError() }
        wantsPlayback = false
        resumePreparationRequested = true
        if state == .ready { try page?.setGain(0); return }
        guard state == .paused || state == .pausing || reloadTask != nil else {
            throw WallpaperError("网页尚未暂停，不能准备恢复。")
        }
        startReloadIfNeeded()
        let requestedReload = reloadTask
        do {
            try await withTaskCancellationHandler {
                try await requestedReload?.value
                try Task.checkCancellation()
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, !self.finalClose, self.resumeRequest === request else { return }
                    self.wantsPlayback = false
                    self.resumePreparationRequested = false
                    requestedReload?.cancel()
                    self.beginRelease()
                }
            }
        } catch is CancellationError {
            try await cancelResume(request)
        }
        guard resumeRequest === request else { try await cancelResume(request); return }
        guard !finalClose, state == .ready else { throw CancellationError() }
    }

    private func cancelResume(_ request: ResumeRequest) async throws {
        if resumeRequest === request {
            if let closeFailure { throw closeFailure }
            wantsPlayback = false
            resumePreparationRequested = false
            reloadTask?.cancel()
            beginRelease()
        }
        // Superseded requests may await their own release, but never touch a successor.
        try await request.release?.value
        throw CancellationError()
    }

    func cancelResumePreparation() async throws {
        pause()
        try await awaitRelease()
    }

    func setAudio(_ value: AudioSettings) {
        do { try value.validate(); audio = value; applyAudio() }
        catch { fail(error) }
    }
    func setTransitionGain(_ value: Double) {
        guard value.isFinite, (0...1).contains(value) else {
            fail(WallpaperError("网页过渡增益必须在 0 到 1 之间。")); return
        }
        transitionGain = value; applyAudio()
    }
    func setGlobalMute(_ value: Bool) { globallyMuted = value; applyAudio() }
    func setAudioSuppressed(_ value: Bool) { suppressed = value; applyAudio() }
    private func applyAudio() {
        let audible = state == .playing && !globallyMuted && !suppressed && !audio.isMuted
        do { try page?.setGain(audible ? audio.volume * transitionGain : 0) }
        catch { fail(error) }
    }
    private func fail(_ error: Error) {
        state = .failed
        wantsPlayback = false
        // A failed gain operation remains visible; shutdown still retains the page.
        do { try page?.setGain(0) }
        catch { if reportedFailure == nil { reportedFailure = error; onError?(error) }; return }
        guard reportedFailure == nil else { return }
        reportedFailure = error
        onError?(error)
    }

    func close() async throws {
        if let closeFailure { throw closeFailure }
        if state == .closed { return }
        finalClose = true
        wantsPlayback = false
        generation = UUID()
        reloadTask?.cancel()
        beginRelease()
        resumeRequest = nil
        resumePreparationRequested = false
        try await awaitRelease()
        if let reloadTask {
            do { try await reloadTask.value }
            catch is CancellationError { /* This close invalidated the reload. */ }
            catch { throw error }
        }
        state = .closed
        onError = nil
    }
}
