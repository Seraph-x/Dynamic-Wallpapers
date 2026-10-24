import WallpaperNative
import AppKit
import WallpaperCore

@MainActor
final class DesktopWindow: NSWindow, PlaybackEndpoint {
    enum Role { case wallpaper, preview }
    @MainActor
    private final class Instance {
        let id = UUID()
        let surface: any PlaybackSurface
        let entryID: UUID
        let mediaID: UUID
        var closeTask: Task<Void, Error>?
        var ready = false
        var releaseFailure: Error?
        init(surface: any PlaybackSurface, entryID: UUID, mediaID: UUID) {
            self.surface = surface; self.entryID = entryID; self.mediaID = mediaID
        }
    }
    private struct Closing {
        let instance: Instance
        let task: Task<Void, Error>
    }
    private var current: Instance?
    private var pending: Instance?
    private var incoming: Instance?
    private var resumeAttempt: (id: UUID, instance: Instance)?
    private var closing: [UUID: Closing] = [:]
    private let surfaceFactory: any SurfaceMaking
    private var preparationGeneration = UUID()
    var releaseFailure: Error? {
        [current, pending, incoming].compactMap { $0?.releaseFailure ?? $0?.surface.releaseFailure }.first
            ?? closing.values.lazy.compactMap { $0.instance.releaseFailure ?? $0.instance.surface.releaseFailure }.first
    }
    var activeSurfaceCount: Int {
        [current, pending, incoming].compactMap { $0 }.count + closing.count
    }
    var referencedMediaIDs: Set<UUID> {
        Set([current, pending, incoming].compactMap { $0?.mediaID } + closing.values.map { $0.instance.mediaID })
    }
    var hasVisibleWallpaper: Bool {
        guard !closed, isVisible, contentView?.isHidden != true else { return false }
        if current?.ready == true { return true }
        return incoming.map { $0.ready && $0.surface.view.alphaValue > 0 } ?? false
    }
    var hasOpaqueWallpaper: Bool {
        if current?.ready == true { return true }
        return incoming.map { $0.ready && $0.surface.view.alphaValue == 1 } ?? false
    }
    var committedWallpaperID: UUID? {
        guard !closed, incoming == nil, isVisible, contentView?.isHidden != true,
              let current, current.ready else { return nil }
        return current.id
    }
    private var closed = false
    private var displayScale: CGFloat
    private var globallyMuted = true
    private var interactionGeneration = UUID()
    private var isPlaybackPaused = false
    var onPlaybackError: ((Error) -> Void)?
    var onInteractionChanged: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func desktopClickTarget(screenID: String) -> FinderClickTarget? {
        guard !closed, !isPlaybackPaused, incoming == nil, closing.isEmpty, releaseFailure == nil,
              isVisible, let current, current.ready, let surface = current.surface as? any DesktopInteractiveSurface,
              surface.view.superview === contentView, surface.view.window === self, surface.view.alphaValue == 1,
              let pageID = surface.interactivePageID, let id = UInt32(exactly: windowNumber), id != 0 else { return nil }
        return FinderClickTarget(screenID: screenID, pageID: pageID, windowID: id,
                                 interactionGeneration: interactionGeneration)
    }

    func desktopClickPoint(atScreenPoint point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, let surface = current?.surface as? any DesktopInteractiveSurface else { return nil }
        let local = surface.view.convert(convertPoint(fromScreen: point), from: nil)
        let topLeft = CGPoint(x: local.x - surface.view.bounds.minX,
            y: surface.view.isFlipped ? local.y - surface.view.bounds.minY : surface.view.bounds.maxY - local.y)
        return CGRect(origin: .zero, size: surface.view.bounds.size).contains(topLeft) ? topLeft : nil
    }

    func sendDesktopClick(atScreenPoint point: CGPoint, clickCount: Int, target: FinderClickTarget) throws -> Bool {
        guard target == desktopClickTarget(screenID: target.screenID),
              let surface = current?.surface as? any DesktopInteractiveSurface, let local = desktopClickPoint(atScreenPoint: point) else {
            throw WallpaperError("桌面网页已暂停、切换或位置发生变化，点击已取消。")
        }
        return try surface.sendClick(at: local, clickCount: clickCount, expectedPageID: target.pageID)
    }

    func sendDesktopPointer(atScreenPoint point: CGPoint, kind: String, target: FinderClickTarget) throws {
        guard target == desktopClickTarget(screenID: target.screenID),
              let surface = current?.surface as? SceneSurface else { return }
        if kind == "leave" {
            try surface.sendPointer(at: .zero, kind: kind, expectedPageID: target.pageID)
        } else if let local = desktopClickPoint(atScreenPoint: point) {
            try surface.sendPointer(at: local, kind: kind, expectedPageID: target.pageID)
        }
    }

    private func invalidateDesktopClicks() {
        interactionGeneration = UUID()
        onInteractionChanged?()
    }

    init(screen: NSScreen, surfaceFactory: any SurfaceMaking = SurfaceFactory(), role: Role = .wallpaper) {
        self.surfaceFactory = surfaceFactory
        displayScale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        canHide = false
        // Both layers remain below Finder's desktop icons and never become key windows.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + (role == .preview ? 2 : 1))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true; hasShadow = false; isOpaque = false
        backgroundColor = .clear; animationBehavior = .none
        contentView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        setFrame(screen.frame, display: false)
    }

    @discardableResult
    func updateGeometry(frame: CGRect, scale: CGFloat) -> Bool {
        guard self.frame != frame || displayScale != scale else { return false }
        displayScale = scale
        setFrame(frame, display: true)
        contentView?.layoutSubtreeIfNeeded()
        invalidateDesktopClicks()
        return true
    }

    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws {
        guard !closed, let contentView else { throw WallpaperError("目标显示器窗口已关闭。") }
        if let releaseFailure { throw releaseFailure }
        guard incoming == nil else { throw WallpaperError("目标显示器仍在过渡中。") }
        discardPreparation()
        let generation = preparationGeneration
        try await waitForClosing()
        try Task.checkCancellation()
        guard generation == preparationGeneration, !closed else { throw CancellationError() }
        if let releaseFailure { throw releaseFailure }
        let surface = try surfaceFactory.makeSurface(item: item, size: contentView.bounds.size, fit: fit)
        let instance = Instance(surface: surface, entryID: entry.id, mediaID: item.id)
        surface.setAudio(entry.audio)
        surface.setGlobalMute(globallyMuted)
        surface.view.alphaValue = 0
        surface.onError = { [weak self] error in
            guard let self, !self.closed, self.containsActive(instance.id) else { return }
            self.onPlaybackError?(error)
        }
        pending = instance
        contentView.addSubview(surface.view)
        orderBack(nil)
        do {
            try await surface.prepare(item: item, scale: displayScale, fit: fit)
            try Task.checkCancellation()
            guard pending?.id == instance.id, generation == preparationGeneration, !closed else {
                throw CancellationError()
            }
            instance.ready = true
        } catch {
            if pending?.id == instance.id { pending = nil }
            let closeTask = beginClosing(instance)
            // Cleanup failures must be visible and retain their resource slot.
            try await closeTask.value
            throw error
        }
    }

    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult {
        guard !closed else { return .notDisplayed(WallpaperError("目标显示器窗口已关闭。")) }
        if let releaseFailure { return .notDisplayed(releaseFailure) }
        guard incoming == nil, closing.isEmpty else {
            return .notDisplayed(releaseFailure ?? WallpaperError("目标显示器仍在过渡或关闭媒体资源。"))
        }
        guard let instance = pending, instance.ready else {
            return .notDisplayed(WallpaperError("待播媒体尚未提交首帧。"))
        }
        pending = nil; incoming = instance
        isPlaybackPaused = paused
        invalidateDesktopClicks()
        defer { onInteractionChanged?() }
        let outgoingSurface = current?.surface
        let incomingSurface = instance.surface
        let finish: @MainActor @Sendable () async -> PlaybackTransitionResult = { [self, instance] in
            await finishTransition(instance, duration: duration, paused: paused)
        }
        return await withTaskCancellationHandler(operation: finish) {
            // Capture only this transaction's instances, never a future current item.
            Task { @MainActor [outgoingSurface, incomingSurface] in
                outgoingSurface?.setAudioSuppressed(true)
                incomingSurface.setAudioSuppressed(true)
            }
        }
    }

    private func finishTransition(_ instance: Instance, duration: Double, paused: Bool) async -> PlaybackTransitionResult {
        let surface = instance.surface
        let outgoingSurface = current?.surface
        if duration == 0 { outgoingSurface?.setAudioSuppressed(true) }
        surface.setTransitionGain(duration == 0 ? 1 : 0)
        if Task.isCancelled {
            outgoingSurface?.setAudioSuppressed(true)
            surface.setAudioSuppressed(true)
        }
        if paused { surface.pause() } else { surface.play() }
        // Like the existing visual animation, this transaction finishes even if
        // its requesting task is cancelled. Pause gates output independently.
        do {
            try await Task { @MainActor in
                try await SharedTransition.run(duration: duration) { [weak self] progress in
                    guard let self, !self.closed, self.incoming?.id == instance.id else { return }
                    outgoingSurface?.setTransitionGain(1 - progress)
                    surface.setTransitionGain(progress)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    surface.view.alphaValue = progress
                    CATransaction.commit()
                }
            }.value
        } catch {
            outgoingSurface?.setAudioSuppressed(true)
            surface.setAudioSuppressed(true)
            return .notDisplayed(error)
        }
        guard !closed, incoming?.id == instance.id else {
            return .notDisplayed(WallpaperError("目标显示器在过渡完成前已关闭或失效。"))
        }
        let outgoing = current
        current = instance; incoming = nil
        if let outgoing {
            do { try await beginClosing(outgoing, reportFailure: false).value }
            catch { return .displayedWithReleaseFailure(error) }
        }
        return .displayed
    }

    func discardPreparation() {
        preparationGeneration = UUID()
        guard let pending else { return }
        self.pending = nil
        beginClosing(pending)
    }

    private func containsActive(_ id: UUID) -> Bool {
        [current, pending, incoming].contains { $0?.id == id }
    }

    @discardableResult
    private func beginClosing(_ instance: Instance, reportFailure: Bool = true) -> Task<Void, Error> {
        if let existing = instance.closeTask { return existing }
        instance.surface.setAudioSuppressed(true)
        instance.surface.onError = nil
        instance.surface.view.removeFromSuperview()
        let task = Task { @MainActor in
            do {
                try await instance.surface.close()
                self.closing.removeValue(forKey: instance.id)
                if self.resumeAttempt?.instance.id == instance.id { self.resumeAttempt = nil }
                self.onInteractionChanged?()
            } catch {
                instance.releaseFailure = error
                if reportFailure { self.onPlaybackError?(error) }
                throw error
            }
        }
        instance.closeTask = task
        closing[instance.id] = Closing(instance: instance, task: task)
        invalidateDesktopClicks()
        return task
    }

    func waitForClosing() async throws {
        try await PlaybackCloseBarrier.wait(for: closing.values.map(\.task))
    }

    func updateAudio(_ settings: [UUID: AudioSettings]) {
        for instance in [current, pending, incoming].compactMap({ $0 }) {
            if let audio = settings[instance.entryID] { instance.surface.setAudio(audio) }
        }
    }
    func setGlobalMute(_ value: Bool) {
        globallyMuted = value
        for instance in [current, pending, incoming].compactMap({ $0 }) { instance.surface.setGlobalMute(value) }
    }
    func setPaused(_ paused: Bool) {
        if !paused, let releaseFailure { onPlaybackError?(releaseFailure); return }
        if paused != isPlaybackPaused {
            isPlaybackPaused = paused
            invalidateDesktopClicks()
        }
        defer { onInteractionChanged?() }
        for instance in [current, incoming].compactMap({ $0 }) {
            if paused { instance.surface.pause() }
            else {
                instance.surface.setAudioSuppressed(false)
                instance.surface.play()
            }
        }
    }

    /// Stop presenting without destroying a window still referenced by an in-flight capture.
    func invalidatePresentation() {
        contentView?.isHidden = true
        setPaused(true)
    }

    func prepareToResume(requestID: UUID) async throws {
        guard !closed, incoming == nil else { throw WallpaperError("目标窗口仍在过渡或已经关闭。") }
        try await waitForClosing()
        try Task.checkCancellation()
        guard !closed, let instance = current else { throw CancellationError() }
        resumeAttempt = (requestID, instance)
        instance.surface.setAudioSuppressed(true)
        try await instance.surface.prepareToResume()
        try Task.checkCancellation()
        guard !closed, current?.id == instance.id, resumeAttempt?.id == requestID else { throw CancellationError() }
    }

    func cancelResumePreparation(requestID: UUID) async throws {
        guard let attempt = resumeAttempt, attempt.id == requestID else { return }
        do {
            if let closeTask = attempt.instance.closeTask { try await closeTask.value }
            else { try await attempt.instance.surface.cancelResumePreparation() }
            if resumeAttempt?.id == requestID { resumeAttempt = nil }
        } catch {
            attempt.instance.releaseFailure = error
            throw error
        }
    }
    func shutdown() {
        guard !closed else { return }
        closed = true
        invalidateDesktopClicks()
        discardPreparation()
        if let current { self.current = nil; beginClosing(current) }
        if let incoming { self.incoming = nil; beginClosing(incoming) }
        orderOut(nil); close()
    }
}
