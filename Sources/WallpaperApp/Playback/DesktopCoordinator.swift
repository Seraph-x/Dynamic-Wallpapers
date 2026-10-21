import AppKit
import Combine
import WallpaperCore

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let size: String
}

extension NSScreen {
    var wallpaperID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

@MainActor
final class DesktopCoordinator {
    private struct Configuration: Equatable {
        let screenIDs: [String]
        let sourceID: DisplaySource.Identity
        let fit: ContentFit
    }
    private struct Mirror {
        let displayID: String
        let session: WallpaperMirrorSession
    }
    private struct Snapshot {
        let displayID: String
        let windowID: ObjectIdentifier
        let isPreview: Bool
        let task: Task<CGImage, Error>
    }
    private let surfaceFactory: any SurfaceMaking
    private let screenProvider: () -> [String: NSScreen]
    private let mirrorFrameRate: @MainActor () -> WallpaperMirrorFrameRate
    private let mirrorStreamFactory: @MainActor (NSWindow, WallpaperMirrorView) async throws -> WallpaperMirrorStream
    private let snapshotWindow: @MainActor (NSWindow) async throws -> CGImage
    let previews: DesktopPreviewController
    let systemWallpaperSource: DesktopWallpaperSource
    private var windows: [String: DesktopWindow] = [:]
    private var retiringWindows: [String: DesktopWindow] = [:]
    private var sessions: [UUID: PlaybackSession] = [:]
    private var configurations: [UUID: Configuration] = [:]
    private var reconcileTask: Task<Void, Never>?
    private var retirementTasks: [String: Task<Void, Error>] = [:]
    private var latestLibrary: Library?
    private var paused = false
    private var isShuttingDown = false
    private var webInteractionEnabled = false
    private var clickObserver: FinderDesktopClickObserver?
    private var interactionStatus = WebInteractionStatus("网页交互已关闭")
    private var publishedInteractionStatus: WebInteractionStatus?
    private var finderObservers: [NSObjectProtocol] = []
    private let wallpaperSourceChanges = PassthroughSubject<Void, Never>()
    private var wallpaperMirrors: [UUID: Mirror] = [:]
    private var snapshots: [UUID: Snapshot] = [:]
    var onCommit: ((UUID, UUID) -> Void)?
    var onStatus: ((UUID, String) -> Void)?
    var onError: ((Error) -> Void)?
    var onWebInteractionStatus: ((WebInteractionStatus) -> Void)?
    var windowIdentities: [String: ObjectIdentifier] { windows.mapValues(ObjectIdentifier.init) }

    init(surfaceFactory: any SurfaceMaking = SurfaceFactory(),
         screenProvider: @escaping () -> [String: NSScreen] = {
             Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in screen.wallpaperID.map { ($0, screen) } })
         }, mirrorFrameRate: @escaping @MainActor () -> WallpaperMirrorFrameRate = { .hz30 },
         systemWallpaperSource: DesktopWallpaperSource? = nil,
         mirrorStreamFactory: (@MainActor (NSWindow, WallpaperMirrorView) async throws -> WallpaperMirrorStream)? = nil,
         snapshotWindow: (@MainActor (NSWindow) async throws -> CGImage)? = nil) {
        self.surfaceFactory = surfaceFactory
        self.screenProvider = screenProvider
        self.mirrorFrameRate = mirrorFrameRate
        self.snapshotWindow = snapshotWindow ?? { try await WallpaperSnapshot.capture(window: $0) }
        self.mirrorStreamFactory = mirrorStreamFactory ?? { window, view in
            try await WallpaperMirrorStream.makeScreenshot(window: window, view: view, frameRate: mirrorFrameRate)
        }
        self.systemWallpaperSource = systemWallpaperSource ?? DesktopWallpaperSource()
        previews = DesktopPreviewController(surfaceFactory: surfaceFactory, screenProvider: screenProvider)
        previews.beforeStart = { [weak self] ids in
            guard let self else { throw CancellationError() }
            // A committed transition owns its outgoing resources until it really finishes.
            while self.configurations.contains(where: {
                !ids.isDisjoint(with: $0.value.screenIDs) && self.sessions[$0.key]?.isTransitioning == true
            }) {
                try await Task.sleep(for: .milliseconds(30))
            }
            try Task.checkCancellation()
            guard !self.isShuttingDown else { throw CancellationError() }
        }
        previews.onChange = { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            for (id, session) in self.sessions {
                session.setPreviewSuspended(!self.previews.suspendedDisplayIDs.isDisjoint(
                    with: self.configurations[id]?.screenIDs ?? []))
            }
            self.wallpaperSourceChanges.send()
            self.publishWebInteractionStatus()
        }
        previews.releaseSources = { [weak self] ids in
            guard let self else { return nil }
            let mirrors = self.wallpaperMirrors.values.filter { ids.contains($0.displayID) }
            let barriers = mirrors.compactMap { $0.session.sourceReleaseBarrier() }
            let captures = self.snapshots.values.filter { $0.isPreview && ids.contains($0.displayID) }.map(\.task)
            guard !barriers.isEmpty || !captures.isEmpty else { return nil }
            return Task { @MainActor in
                for capture in captures { _ = await capture.result }
                try await PlaybackCloseBarrier.wait(for: barriers)
            }
        }
    }

    /// The same effective source drives desktop capture, full-screen mirrors and interaction.
    func wallpaperWindow(on displayID: String) -> DesktopWindow? {
        previews.window(on: displayID) ?? windows[displayID]
    }

    func captureWallpaper(on screen: NSScreen) async throws -> CGImage {
        guard let id = screen.wallpaperID else { throw WallpaperError("无法识别壁纸所在的显示器。") }
        if let window = wallpaperWindow(on: id), window.hasVisibleWallpaper {
            let underlay = window.hasOpaqueWallpaper ? nil : try WallpaperSnapshot.systemWallpaper(on: screen)
            let request = UUID()
            let capture = Task { @MainActor in try await snapshotWindow(window) }
            snapshots[request] = Snapshot(displayID: id, windowID: ObjectIdentifier(window),
                isPreview: previews.window(on: id) === window, task: capture)
            defer { snapshots.removeValue(forKey: request) }
            let image = try await withTaskCancellationHandler {
                try await capture.value
            } onCancel: { capture.cancel() }
            if let underlay { return try WallpaperSnapshot.composite(image, over: underlay) }
            return image
        }
        return try WallpaperSnapshot.systemWallpaper(on: screen)
    }

    func makeWallpaperMirror(on screen: NSScreen) throws -> WallpaperMirrorSession {
        guard !isShuttingDown else { throw WallpaperError("应用正在退出，无法启动全屏壁纸。") }
        guard let displayID = screen.wallpaperID else { throw WallpaperError("无法识别壁纸所在的显示器。") }
        let id = UUID()
        let mirror = WallpaperMirrorSession(source: { [weak self] in
            guard let self, self.screenProvider()[displayID] != nil else {
                throw WallpaperError("全屏壁纸所在的显示器已断开。")
            }
            guard let window = self.wallpaperWindow(on: displayID), window.isVisible else { return nil }
            return WallpaperMirrorSource(window: window, needsSystemUnderlay: !window.hasOpaqueWallpaper)
        }, systemWallpaper: { [weak self] in
            guard let screen = self?.screenProvider()[displayID] else {
                throw WallpaperError("全屏壁纸所在的显示器已断开。")
            }
            return try WallpaperSnapshot.systemWallpaper(on: screen)
        }, changes: wallpaperSourceChanges.eraseToAnyPublisher(),
           makeStream: mirrorStreamFactory)
        mirror.onClose = { [weak self] result in
            switch result {
            case .success: self?.wallpaperMirrors.removeValue(forKey: id)
            case .failure(let error): self?.onError?(error)
            }
        }
        wallpaperMirrors[id] = Mirror(displayID: displayID, session: mirror)
        return mirror
    }

    func reconcile(_ library: Library) {
        guard !isShuttingDown else { return }
        defer { publishWebInteractionStatus(); wallpaperSourceChanges.send() }
        latestLibrary = library
        // Sound controls must apply even while structural reconciliation waits for a transition.
        windows.values.forEach { $0.setGlobalMute(library.settings.isMuted) }
        for (id, session) in sessions {
            guard let binding = library.displays.first(where: { $0.groupID == id }),
                  binding.source.identity == configurations[id]?.sourceID else { continue }
            do { session.updateAudio(entries: try PlaybackContent(source: binding.source, library: library).entries) }
            catch { onError?(error) }
        }
        let screens = screenProvider()
        previews.refreshScreens(screens)
        let activeBindings = library.displays.filter { screens[$0.id] != nil }
        let activeIDs = Set(activeBindings.map(\.id))
        systemWallpaperSource.updateActiveDisplays(activeIDs)
        retireUnboundGroups(activeDisplayIDs: activeIDs)
        reconcileTask?.cancel()
        if sessions.values.contains(where: \.isTransitioning) {
            reconcileTask = Task { [weak self] in
                do {
                    while self?.sessions.values.contains(where: \.isTransitioning) == true {
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    try Task.checkCancellation()
                    self?.reconcile(library)
                } catch is CancellationError { /* Replaced by newer configuration. */ }
                catch { self?.onError?(error) }
            }
            return
        }
        var resized = Set<String>()
        for (id, window) in windows {
            if let screen = screens[id], window.updateGeometry(frame: screen.frame, scale: screen.backingScaleFactor) { resized.insert(id) }
        }
        let groups = Dictionary(grouping: activeBindings, by: \.groupID)
        var desired: [UUID: Configuration] = [:]
        for (id, bindings) in groups {
            guard let first = bindings.first else { continue }
            desired[id] = Configuration(screenIDs: bindings.map(\.id).sorted(), sourceID: first.source.identity, fit: first.fit)
        }
        for id in Array(sessions.keys) where configurations[id] != desired[id] || !(configurations[id]?.screenIDs.filter { resized.contains($0) }.isEmpty ?? true) {
            sessions.removeValue(forKey: id)?.stop(pauseDisplay: false); configurations.removeValue(forKey: id)
        }
        for id in Array(windows.keys) where !activeIDs.contains(id) {
            if let window = windows.removeValue(forKey: id) {
                retire(window, displayID: id)
            }
        }
        for (groupID, config) in desired {
            let waiting = config.screenIDs.compactMap { retiringWindows[$0] }
            guard waiting.isEmpty else {
                let failure = waiting.compactMap(\.releaseFailure).first
                onStatus?(groupID, failure == nil ? "正在结束上一张壁纸的播放…" : "播放器资源释放失败，暂时无法切换壁纸。")
                continue
            }
            guard let binding = groups[groupID]?.first else { continue }
            let content: PlaybackContent
            do { content = try PlaybackContent(source: binding.source, library: library) }
            catch { onStatus?(groupID, "播放来源不可用，请重新应用壁纸。"); onError?(error); continue }
            if let session = sessions[groupID] { session.update(content: content, media: library.media); continue }
            let endpoints = config.screenIDs.compactMap { id -> DesktopWindow? in
                if let window = windows[id] { return window }
                guard let screen = screens[id] else { return nil }
                let window = DesktopWindow(screen: screen, surfaceFactory: surfaceFactory)
                window.onInteractionChanged = { [weak self] in
                    self?.publishWebInteractionStatus()
                    self?.wallpaperSourceChanges.send()
                }
                windows[id] = window
                return window
            }
            let session = PlaybackSession(content: content, media: library.media, endpoints: endpoints,
                fit: config.fit, current: binding.currentEntryID,
                onCommit: { [weak self] entry in self?.onCommit?(groupID, entry) },
                onStatus: { [weak self] status in
                    self?.onStatus?(groupID, status)
                    self?.publishWebInteractionStatus()
                },
                onError: { [weak self] error in self?.onError?(error) })
            session.onWallpaperDisplayed = { [weak self] item, version in
                guard let self, !self.isShuttingDown, self.configurations[groupID] == config else { return }
                for displayID in config.screenIDs {
                    guard let binding = self.latestLibrary?.displays.first(where: { $0.id == displayID }),
                          binding.groupID == groupID, binding.source.identity == config.sourceID, binding.fit == config.fit else { continue }
                    guard let window = self.windows[displayID] else { continue }
                    do {
                        try self.systemWallpaperSource.commit(window: window, displayID: displayID, item: item,
                                                              fit: config.fit, sourceVersion: version)
                    } catch { self.onError?(error) }
                }
            }
            endpoints.forEach { $0.setGlobalMute(library.settings.isMuted) }
            endpoints.forEach { endpoint in
                endpoint.onPlaybackError = { [weak self, weak session] error in
                    session?.setPaused(true)
                    self?.onStatus?(groupID, content.allowsNext
                        ? "播放失败，已暂停；可尝试切换到下一张壁纸。" : "播放失败，已暂停；请重新应用壁纸。")
                    self?.onError?(error)
                }
            }
            sessions[groupID] = session; configurations[groupID] = config
            session.setPaused(paused)
            session.setPreviewSuspended(!previews.suspendedDisplayIDs.isDisjoint(with: config.screenIDs))
            if !content.entries.isEmpty { session.start() }
        }
    }

    private func retireUnboundGroups(activeDisplayIDs: Set<String>) {
        // A whole group's stop is independent of another group's transition/close transaction.
        // Partial regrouping still waits below so surviving endpoints keep their visible transaction.
        for (groupID, config) in configurations where config.screenIDs.allSatisfy({ !activeDisplayIDs.contains($0) }) {
            sessions.removeValue(forKey: groupID)?.stop(pauseDisplay: false)
            configurations.removeValue(forKey: groupID)
            for displayID in config.screenIDs {
                if let window = windows.removeValue(forKey: displayID) { retire(window, displayID: displayID) }
            }
        }
    }

    private func retire(_ window: DesktopWindow, displayID: String, sourceRelease: Task<Void, Error>? = nil) {
        retiringWindows[displayID] = window
        // The retirement task owns error reporting after this window leaves its session.
        window.onPlaybackError = nil
        let captureRelease = systemWallpaperSource.retire(displayID: displayID)
        let initialCaptures = snapshots.values.filter { $0.windowID == ObjectIdentifier(window) }.map(\.task)
        if captureRelease != nil || sourceRelease != nil || !initialCaptures.isEmpty { window.invalidatePresentation() }
        else { window.shutdown() }
        retirementTasks[displayID] = Task { [weak self] in
            await captureRelease?.value
            // Screenshot errors go to their caller; only the operation's completion
            // releases its source window, including when the caller was cancelled.
            for capture in initialCaptures { _ = await capture.result }
            do {
                try await sourceRelease?.value
                window.shutdown()
                try await window.waitForClosing()
                guard let self, self.retiringWindows[displayID] === window else { return }
                self.retiringWindows.removeValue(forKey: displayID)
                self.retirementTasks.removeValue(forKey: displayID)
                if let library = self.latestLibrary { self.reconcile(library) }
            } catch {
                self?.onError?(error)
                throw error
            }
        }
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        let groups = sessions.filter { !$0.value.referencedMediaIDs.isDisjoint(with: ids) }.map(\.key)
        var displays = Set(groups.flatMap { configurations[$0]?.screenIDs ?? [] })
        displays.formUnion(windows.filter { !$0.value.referencedMediaIDs.isDisjoint(with: ids) }.map(\.key))
        for group in configurations.keys.filter({ !Set(configurations[$0]!.screenIDs).isDisjoint(with: displays) }) {
            sessions.removeValue(forKey: group)?.stop(pauseDisplay: false)
            configurations.removeValue(forKey: group)
        }
        for displayID in displays {
            guard let window = windows.removeValue(forKey: displayID) else { continue }
            // Publishing creates the mirrors' barrier for this retired source.
            wallpaperSourceChanges.send()
            let captures = wallpaperMirrors.values.filter { $0.displayID == displayID }
                .compactMap { $0.session.sourceReleaseBarrier() }
            let release = Task { @MainActor in try await PlaybackCloseBarrier.wait(for: captures) }
            retire(window, displayID: displayID, sourceRelease: release)
        }
        displays.formUnion(retiringWindows.filter { !$0.value.referencedMediaIDs.isDisjoint(with: ids) }.map(\.key))
        let retiring = displays.compactMap { retirementTasks[$0] }
        return Task { @MainActor in try await PlaybackCloseBarrier.wait(for: retiring) }
    }

    func setPaused(_ value: Bool) {
        paused = value
        sessions.values.forEach { $0.setPaused(value) }
        publishWebInteractionStatus()
    }

    // Interaction is current user intent, never a potentially stale playback snapshot.
    func setWebInteractionEnabled(_ enabled: Bool) {
        guard !isShuttingDown, enabled != webInteractionEnabled else { return }
        defer { publishWebInteractionStatus() }
        webInteractionEnabled = enabled
        guard enabled else {
            clickObserver?.stop()
            interactionStatus = WebInteractionStatus("网页交互已关闭")
            return
        }
        if clickObserver == nil {
            let observer = FinderDesktopClickObserver { [weak self] point in self?.desktopClickTarget(at: point) }
            observer.onStatus = { [weak self] status in
                self?.interactionStatus = status
                self?.publishWebInteractionStatus()
            }
            observer.onClick = { [weak self] point, count, target in
                guard let self else { throw WallpaperError("桌面网页接收器已关闭。") }
                return try self.sendDesktopClick(at: point, clickCount: count, target: target)
            }
            clickObserver = observer
            observeFinderLifecycle()
        }
        startClickObserver()
    }

    private func startClickObserver() {
        do {
            try clickObserver?.start()
            interactionStatus = clickObserver?.status ?? WebInteractionStatus("网页交互不可用")
        } catch { interactionStatus = .failure(error) }
        publishWebInteractionStatus()
    }

    private func observeFinderLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            finderObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.apple.finder" else { return }
                let finderTerminated = notification.name == NSWorkspace.didTerminateApplicationNotification
                Task { @MainActor [weak self] in
                    guard let self, self.webInteractionEnabled, !self.isShuttingDown else { return }
                    if finderTerminated {
                        self.clickObserver?.stop(reason: "网页交互不可用：Finder 已退出。")
                    } else { self.startClickObserver() }
                }
            })
        }
    }

    func refreshWebInteractionStatus() {
        clickObserver?.refreshStatus()
        publishWebInteractionStatus()
    }

    private func isStableForClicks(_ screenID: String) -> Bool {
        guard !isShuttingDown else { return false }
        if previews.window(on: screenID) != nil { return true }
        guard !paused, !previews.suspendedDisplayIDs.contains(screenID),
              let group = configurations.first(where: { $0.value.screenIDs.contains(screenID) }),
              let session = sessions[group.key], !session.isTransitioning else { return false }
        return true
    }

    func desktopClickTarget(at point: CGPoint) -> FinderClickTarget? {
        guard webInteractionEnabled, !isShuttingDown else { return nil }
        let screens = screenProvider()
        let targets = Set(windows.keys).union(previews.visibleDisplayIDs).compactMap { id -> FinderClickTarget? in
            guard isStableForClicks(id), let window = wallpaperWindow(on: id), let screen = screens[id],
                  let position = appKitPoint(point, screen: screen), window.desktopClickPoint(atScreenPoint: position) != nil else { return nil }
            return window.desktopClickTarget(screenID: id)
        }
        return targets.count == 1 ? targets[0] : nil
    }

    private func sendDesktopClick(at point: CGPoint, clickCount: Int, target: FinderClickTarget) throws -> Bool {
        guard desktopClickTarget(at: point) == target, let window = wallpaperWindow(on: target.screenID),
              let screen = screenProvider()[target.screenID], let position = appKitPoint(point, screen: screen) else {
            throw WallpaperError("桌面目标已切换或不可交互，点击已取消。")
        }
        return try window.sendDesktopClick(atScreenPoint: position, clickCount: clickCount, target: target)
    }

    private func appKitPoint(_ point: CGPoint, screen: NSScreen) -> CGPoint? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return FinderScreenGeometry(quartzBounds: CGDisplayBounds(number.uint32Value), appKitFrame: screen.frame).appKitPoint(for: point)
    }

    private func publishWebInteractionStatus() {
        let value: WebInteractionStatus
        if !webInteractionEnabled { value = WebInteractionStatus("网页交互已关闭") }
        else if isShuttingDown { value = WebInteractionStatus("正在退出，网页交互已停止") }
        else if clickObserver?.isRunning != true { value = interactionStatus }
        else if paused, previews.visibleDisplayIDs.isEmpty { value = WebInteractionStatus("网页交互暂不可用：壁纸已暂停。") }
        else if !Set(windows.keys).union(previews.visibleDisplayIDs).contains(where: {
            isStableForClicks($0) && wallpaperWindow(on: $0)?.desktopClickTarget(screenID: $0) != nil
        }) {
            value = WebInteractionStatus("网页交互暂不可用：没有可交互的网页壁纸。")
        } else { value = interactionStatus }
        guard value != publishedInteractionStatus else { return }
        publishedInteractionStatus = value
        onWebInteractionStatus?(value)
    }
    func next(groupID: UUID? = nil) {
        let targets: [PlaybackSession]
        if let groupID { targets = sessions[groupID].map { [$0] } ?? [] }
        else { targets = Array(sessions.values) }
        targets.filter(\.canAdvance).forEach { $0.setPaused(paused); $0.next() }
    }
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        wallpaperMirrors.values.forEach { $0.session.beginClose() }
        previews.shutdown()
        clickObserver?.stop(reason: "正在退出，网页交互已停止")
        for observer in finderObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        finderObservers.removeAll()
        publishWebInteractionStatus()
        latestLibrary = nil
        reconcileTask?.cancel()
        sessions.values.forEach { $0.stop() }; sessions.removeAll(); configurations.removeAll()
        for (id, window) in windows {
            retire(window, displayID: id)
        }
        windows.removeAll()
    }

    func waitForShutdown() async throws {
        let windows = Array(retiringWindows.values)
        let retirements = Array(retirementTasks.values)
        try await PlaybackCloseBarrier.wait(for: retirements)
        let tasks = windows.map { window in
            Task { @MainActor in try await window.waitForClosing() }
        } + wallpaperMirrors.values.map { $0.session.beginClose() }
          + [Task { @MainActor in try await self.previews.waitForShutdown() }]
        try await PlaybackCloseBarrier.wait(for: tasks)
    }
}
