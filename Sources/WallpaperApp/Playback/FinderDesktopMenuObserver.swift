import AppKit
import ApplicationServices
import WallpaperCore

/// Owns the AX run-loop source and timer even if the observer is released without stop().
private final class FinderMenuResources {
    private var observer: AXObserver?
    private var timer: Timer?

    init(observer: AXObserver) { self.observer = observer }

    func install(timer: Timer) { self.timer = timer }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
    }

    deinit { stop() }
}

@MainActor
final class FinderDesktopMenuObserver {
    private(set) var evidence = FinderMenuEvidence()
    private(set) var knownClosedSince: UInt64?
    var onChange: (() -> Void)?
    private let queryQueue = DispatchQueue(label: "local.dynamicwallpaper.finder-menu-state")
    private var resources: FinderMenuResources?
    private var application: AXUIElement?
    private var finderPID: pid_t = 0
    private var session = UUID()
    private var queryRunning = false

    func start(finderPID: pid_t) throws {
        stop()
        self.finderPID = finderPID
        let application = AXUIElementCreateApplication(finderPID)
        self.application = application
        var observer: AXObserver?
        let result = AXObserverCreate(finderPID, { _, _, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<FinderDesktopMenuObserver>.fromOpaque(context).takeUnretainedValue()
                    .receive(notification as String)
            }
        }, &observer)
        guard result == .success, let observer else {
            throw WallpaperError("无法监听 Finder 菜单。", diagnostic: "创建菜单监听：AX \(result.rawValue)")
        }
        resources = FinderMenuResources(observer: observer)
        do {
            for name in [kAXMenuOpenedNotification, kAXMenuClosedNotification] {
                let status = AXObserverAddNotification(observer, application, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque())
                guard status == .success else {
                    throw WallpaperError("无法监听 Finder 菜单变化。", diagnostic: "注册 \(name)：AX \(status.rawValue)")
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            // Observe actual state, including a menu already open when enabled.
            // This interval never serves as a quiet-time assertion of menu absence.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            resources?.install(timer: timer)
            RunLoop.main.add(timer, forMode: .common)
            refresh()
        } catch { stop(); throw error }
    }

    func stop() {
        resources?.stop()
        resources = nil
        application = nil; session = UUID(); queryRunning = false
        knownClosedSince = nil; evidence.invalidate()
        onChange?()
    }

    func invalidate() {
        knownClosedSince = nil; evidence.invalidate()
        onChange?()
        refresh()
    }

    private func receive(_ notification: String) {
        knownClosedSince = nil
        if notification == kAXMenuOpenedNotification { evidence.opened() }
        else { evidence.invalidate() } // A submenu close cannot prove the full menu tree is closed.
        onChange?()
        refresh()
    }

    func refresh() {
        guard resources != nil, !queryRunning else { return }
        queryRunning = true
        let generation = evidence.generation, session = session, pid = finderPID
        queryQueue.async { [weak self] in
            let snapshot = FinderDesktopHitSampler.menuSnapshot(finderPID: pid)
            Task { @MainActor [weak self] in
                guard let self, self.resources != nil, self.session == session else { return }
                self.queryRunning = false
                let previous = self.evidence
                guard self.evidence.apply(snapshot, ifUnchanged: generation) else { self.refresh(); return }
                if self.evidence.state != .observedClosed { self.knownClosedSince = nil }
                else if self.knownClosedSince == nil { self.knownClosedSince = DispatchTime.now().uptimeNanoseconds }
                if self.evidence != previous { self.onChange?() }
            }
        }
    }
}
