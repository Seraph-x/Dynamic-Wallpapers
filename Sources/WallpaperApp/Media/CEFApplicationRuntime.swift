import AppKit
import WebWallpaperBridge
import WallpaperCore
import Darwin

/// Owns every page until its real close callback succeeds, including failed closes.
@MainActor
final class CEFApplicationRuntime: WebPageMaking {
    private let paths: WebRuntimePaths
    private let cache: URL
    private var bridge: DWWebRuntime?
    private var sessions: [UUID: CEFPageSession] = [:]
    private(set) var frameRate = WebWallpaperFrameRate.fps30
    private var shuttingDown = false
    private var shutdownTask: Task<Void, Error>?

    init(paths: WebRuntimePaths = .resolve(), cache: URL = ApplicationPaths.production(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName).cefCache) {
        self.paths = paths; self.cache = cache
    }

    var activePageCount: Int { sessions.count }

    func makePage(size: CGSize) throws -> any WebPageSession {
        guard !shuttingDown else { throw WallpaperError("网页运行时正在退出，不能创建页面。") }
        let session = CEFPageSession(owner: self, size: size, frameRate: frameRate)
        sessions[session.id] = session
        return session
    }

    func setFrameRate(_ value: WebWallpaperFrameRate) {
        frameRate = value
        sessions.values.forEach { $0.setFrameRate(value) }
    }

    func createPage(project: WebProjectReference, size: CGSize, scale: CGFloat) throws -> DWWebPage {
        guard !shuttingDown else { throw CancellationError() }
        try project.validate()
        if bridge == nil {
            try paths.validate()
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            bridge = DWWebRuntime(frameworkDirectory: paths.framework.path,
                                  helperExecutable: paths.helper.path, cacheDirectory: cache.path)
        }
        guard let bridge else { preconditionFailure("Runtime construction returned no owner") }
        do { try bridge.start() }
        catch {
            let failure = error as NSError
            if failure.domain == "DynamicWallpaper.Web",
               let exitCode = failure.userInfo["CEFInitializationExitCode"] as? NSNumber {
                // CEF requires immediate process exit after failed initialization.
                // Do not pump AppKit, retry CEF, or claim a successful shutdown.
                fputs("\(failure.localizedDescription)\n", stderr)
                Darwin.exit(exitCode.int32Value)
            }
            throw error
        }
        let page = try bridge.page(withProjectRoot: project.root.path, entry: project.entry, size: size, scale: scale)
        try page.setFrameRate(UInt(frameRate.rawValue))
        return page
    }

    func retire(_ id: UUID) { sessions.removeValue(forKey: id) }

    func shutdown() async throws {
        if let shutdownTask { try await shutdownTask.value; return }
        shuttingDown = true
        let pages = Array(sessions.values)
        let task = Task { @MainActor in
            let closing = pages.map { page in Task { @MainActor in try await page.close() } }
            try await PlaybackCloseBarrier.wait(for: closing)
            try self.bridge?.shutdown()
            if FileManager.default.fileExists(atPath: self.cache.path) {
                try FileManager.default.removeItem(at: self.cache)
            }
        }
        shutdownTask = task
        try await task.value
    }
}
