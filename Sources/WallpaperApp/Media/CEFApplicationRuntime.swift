import WallpaperAudioSpectrum
import AppKit
import WebWallpaperBridge
import WallpaperCore
import Darwin

/// Owns every page until its real close callback succeeds, including failed closes.
@MainActor
final class CEFApplicationRuntime: WebPageMaking, ScenePageMaking {
    let systemAudioSpectrum = SystemAudioSpectrumController()
    private var playingSceneIDs = Set<UUID>()
    private let paths: WebRuntimePaths
    private let sceneRuntimeRoot: URL?
    private let cache: URL
    private var bridge: DWWebRuntime?
    private var sessions: [UUID: CEFPageSession] = [:]
    private var sceneSessions: [UUID: CEFScenePageSession] = [:]
    private(set) var frameRate = WebWallpaperFrameRate.fps30
    private var shuttingDown = false
    private var shutdownTask: Task<Void, Error>?

    init(paths: WebRuntimePaths = .resolve(), cache: URL = ApplicationPaths.production(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName).cefCache,
         sceneRuntimeRoot: URL? = nil) {
        self.paths = paths; self.cache = cache; self.sceneRuntimeRoot = sceneRuntimeRoot
        systemAudioSpectrum.onSpectrum = { [weak self] value in
            guard let self else { return }
            for (id, session) in self.sceneSessions where value == .zero || self.playingSceneIDs.contains(id) {
                session.updateSpectrum(value)
            }
        }
    }

    var activePageCount: Int { sessions.count + sceneSessions.count }

    func makePage(size: CGSize) throws -> any WebPageSession {
        guard !shuttingDown else { throw WallpaperError("网页运行时正在退出，不能创建页面。") }
        let session = CEFPageSession(owner: self, size: size, frameRate: frameRate)
        sessions[session.id] = session
        return session
    }

    func makeScenePage(size: CGSize) throws -> any ScenePageSession {
        guard !shuttingDown else { throw WallpaperError("场景运行时正在退出。") }
        let session = CEFScenePageSession(owner: self, size: size, frameRate: frameRate)
        sceneSessions[session.id] = session
        return session
    }

    func setFrameRate(_ value: WebWallpaperFrameRate) {
        frameRate = value
        sessions.values.forEach { $0.setFrameRate(value) }
        sceneSessions.values.forEach { $0.setFrameRate(value) }
    }

    func createPage(project: WebProjectReference, size: CGSize, scale: CGFloat) throws -> DWWebPage {
        guard !shuttingDown else { throw CancellationError() }
        try project.validate()
        let bridge = try startedBridge()
        let page = try bridge.page(withProjectRoot: project.root.path, entry: project.entry, size: size, scale: scale)
        try page.setFrameRate(UInt(frameRate.rawValue))
        return page
    }

    private func startedBridge() throws -> DWWebRuntime {
        guard !shuttingDown else { throw CancellationError() }
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
        return bridge
    }

    func createScenePage(project: SceneProjectReference, id: UUID, size: CGSize, scale: CGFloat) throws -> DWWebPage {
        try project.validate()
        guard let runtime = sceneRuntimeRoot,
              FileManager.default.fileExists(atPath: runtime.appendingPathComponent("index.html").path) else {
            throw WallpaperError("场景渲染资源缺失。")
        }
        return try startedBridge().scenePage(withProjectRoot: project.root.path, runtimeRoot: runtime.path,
            entry: project.entry, representation: project.representation.rawValue, sceneID: id.uuidString,
            generation: 1, size: size, scale: scale)
    }

    func setScenePlaying(_ id: UUID, _ playing: Bool) {
        guard sceneSessions[id] != nil else { return }
        if playing { playingSceneIDs.insert(id) }
        else { playingSceneIDs.remove(id); sceneSessions[id]?.updateSpectrum(.zero) }
        systemAudioSpectrum.setPlaying(id, playing)
    }

    func retireScene(_ id: UUID) {
        setScenePlaying(id, false)
        sceneSessions.removeValue(forKey: id)
    }

    func retire(_ id: UUID) { sessions.removeValue(forKey: id) }

    func shutdown() async throws {
        if let shutdownTask { try await shutdownTask.value; return }
        shuttingDown = true
        let pages = Array(sessions.values)
        let scenes = Array(sceneSessions.values)
        let task = Task { @MainActor in
            let closing = pages.map { page in Task { @MainActor in try await page.close() } }
                + scenes.map { page in Task { @MainActor in try await page.close() } }
            try await PlaybackCloseBarrier.wait(for: closing)
            try await self.systemAudioSpectrum.shutdown()
            try self.bridge?.shutdown()
            if FileManager.default.fileExists(atPath: self.cache.path) {
                try FileManager.default.removeItem(at: self.cache)
            }
        }
        shutdownTask = task
        try await task.value
    }
}
