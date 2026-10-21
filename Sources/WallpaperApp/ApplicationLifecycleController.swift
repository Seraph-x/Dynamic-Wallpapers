import AppKit
import WallpaperCore

@MainActor
struct ApplicationShutdownPlan {
    let immediate: () -> Void
    let importing: Task<Bool, Never>?
    let drain: () async -> Void
    let makeCloseTasks: () -> [Task<Void, Error>]
    let requireReleased: () throws -> Void
    let shutdownWebRuntime: () async throws -> Void
}

@MainActor
final class ApplicationLifecycleController {
    private let power: PowerMonitor
    private let fullScreenMonitor: OtherAppFullScreenMonitor
    private let notificationCenter: NotificationCenter
    private let screens: () -> [NSScreen]
    private var powerPauseReasons = Set<String>()
    private var screenObserver: NSObjectProtocol?
    private var shutdownTask: Task<Void, Error>?
    private var isShuttingDown = false

    var onPauseReasons: ((Set<String>) -> Void)?
    var onScreensChanged: (([DisplayInfo]) -> Void)?
    var onError: ((Error) -> Void)?

    init(power: PowerMonitor? = nil,
         fullScreenMonitor: OtherAppFullScreenMonitor? = nil,
         notificationCenter: NotificationCenter = .default,
         screens: @escaping () -> [NSScreen] = { NSScreen.screens }) {
        self.power = power ?? PowerMonitor()
        self.fullScreenMonitor = fullScreenMonitor ?? OtherAppFullScreenMonitor()
        self.notificationCenter = notificationCenter
        self.screens = screens
        self.power.onChange = { [weak self] reasons in
            guard let self, !self.isShuttingDown else { return }
            self.powerPauseReasons = reasons
            self.publishPauseReasons()
        }
        self.fullScreenMonitor.onChange = { [weak self] _ in self?.publishPauseReasons() }
        self.fullScreenMonitor.onError = { [weak self] error in
            guard let self, !self.isShuttingDown else { return }
            self.onError?(error)
        }
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshScreens() }
        }
    }

    func update(settings: AppSettings) {
        guard !isShuttingDown else { return }
        power.settings = settings
        fullScreenMonitor.setEnabled(settings.pauseOnOtherAppFullScreen)
    }

    func refreshScreens() {
        guard !isShuttingDown else { return }
        let displays = screens().compactMap { screen -> DisplayInfo? in
            guard let id = screen.wallpaperID else {
                onError?(WallpaperError("无法读取显示器标识：\(screen.localizedName)"))
                return nil
            }
            return DisplayInfo(id: id, name: screen.localizedName,
                size: "\(Int(screen.frame.width * screen.backingScaleFactor)) × \(Int(screen.frame.height * screen.backingScaleFactor))")
        }
        onScreensChanged?(displays)
    }

    func beginShutdown(plan: ApplicationShutdownPlan) -> Task<Void, Error> {
        if let shutdownTask { return shutdownTask }
        var closeTasksContinuation: AsyncStream<[Task<Void, Error>]>.Continuation!
        let closeTasksStream = AsyncStream<[Task<Void, Error>]> { continuation in
            closeTasksContinuation = continuation
        }
        let task = Task { @MainActor [weak self] in
            var iterator = closeTasksStream.makeAsyncIterator()
            guard let closeTasks = await iterator.next() else {
                preconditionFailure("Shutdown close tasks were not supplied")
            }
            _ = await plan.importing?.value
            await plan.drain()
            do {
                try await PlaybackCloseBarrier.wait(for: closeTasks)
                try plan.requireReleased()
                try await plan.shutdownWebRuntime()
            } catch {
                self?.onError?(error)
                throw error
            }
        }
        shutdownTask = task
        isShuttingDown = true
        plan.immediate()
        power.shutdown()
        fullScreenMonitor.shutdown()
        if let screenObserver { notificationCenter.removeObserver(screenObserver) }
        screenObserver = nil
        let closeTasks = plan.makeCloseTasks()
        closeTasksContinuation.yield(closeTasks)
        closeTasksContinuation.finish()
        return task
    }

    private func publishPauseReasons() {
        guard !isShuttingDown else { return }
        var reasons = powerPauseReasons
        if fullScreenMonitor.isActive { reasons.insert("其他应用全屏") }
        onPauseReasons?(reasons)
    }
}
