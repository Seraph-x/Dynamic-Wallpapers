import WallpaperAudioSpectrum
import AppKit
import Darwin
import WallpaperCore
import WebWallpaperBridge

/// Observation only: every operation executes against the real CEF session.
@MainActor
private final class ObservedScenePage: ScenePageSession {
    let underlying: any ScenePageSession
    private(set) var gains: [Double] = []
    private(set) var closeCount = 0
    var view: NSView { underlying.view }
    var onError: ((Error) -> Void)? {
        get { underlying.onError }
        set { underlying.onError = newValue }
    }
    init(_ underlying: any ScenePageSession) { self.underlying = underlying }
    func prepare(project: SceneProjectReference, scale: CGFloat, fit: ContentFit) async throws {
        try await underlying.prepare(project: project, scale: scale, fit: fit)
    }
    func setGain(_ value: Double) throws { try underlying.setGain(value); gains.append(value) }
    func setPlaybackIntent(_ value: Bool) { underlying.setPlaybackIntent(value) }
    func setPlaying(_ value: Bool) async throws { try await underlying.setPlaying(value) }
    func sendPointer(at point: CGPoint, kind: String) throws { try underlying.sendPointer(at: point, kind: kind) }
    func close() async throws { try await underlying.close(); closeCount += 1 }
}

@MainActor
private final class ObservedSceneFactory: ScenePageMaking {
    let runtime: CEFApplicationRuntime
    private(set) var pages: [ObservedScenePage] = []
    init(_ runtime: CEFApplicationRuntime) { self.runtime = runtime }
    func makeScenePage(size: CGSize) throws -> any ScenePageSession {
        let page = ObservedScenePage(try runtime.makeScenePage(size: size))
        pages.append(page)
        return page
    }
}

@main
struct SceneSwiftHarness {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw WallpaperError(message) }
    }

    @MainActor
    static func frame(_ view: NSView) throws -> CGImage {
        guard let contents = view.layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { throw WallpaperError("No real CEF scene pixels") }
        return contents as! CGImage
    }

    @MainActor
    static func frameHash(_ view: NSView) throws -> UInt64 {
        guard let bytes = try frame(view).dataProvider?.data else { throw WallpaperError("Cannot read real CEF scene pixels") }
        return (bytes as Data).reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    @MainActor
    static func markerX(_ view: NSView) throws -> Double {
        let image = try frame(view)
        guard let data = image.dataProvider?.data else { throw WallpaperError("Cannot read pointer marker pixels") }
        let bytes = data as Data
        var x = 0.0, count = 0.0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * 4
                if bytes[offset] > 180 && bytes[offset + 1] > 150 && bytes[offset + 2] < 120 {
                    x += Double(column); count += 1
                }
            }
        }
        try require(count > 0, "Authored cyan pointer marker did not render")
        return x / count / Double(image.width)
    }

    @MainActor
    static func waitUntil(_ message: String, predicate: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while try !predicate() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    static func exercise(project: SceneProjectReference, runtime: CEFApplicationRuntime) async throws {
        let factory = ObservedSceneFactory(runtime)
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        var failure: Error?
        surface.onError = { failure = $0 }
        let item = MediaItem(url: project.entryURL, kind: .scene, width: 640, height: 360,
                             backend: .scene, sceneProject: project)
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            try require(surface.state == .ready && runtime.activePageCount == 1, "Scene surface did not prepare one actual page")
            guard let paintView = surface.subviews.first, let observed = factory.pages.first else {
                throw WallpaperError("Scene surface did not mount its actual session")
            }
            try require(observed.gains.allSatisfy { $0 == 0 }, "Prepare submitted audible native gain")
            let prepared = try frameHash(paintView)
            try await Task.sleep(for: .milliseconds(250))
            try require(try frameHash(paintView) == prepared, "Prepared scene clock was not paused")
            surface.setAudio(AudioSettings(isMuted: false, volume: 0.6))
            surface.setGlobalMute(false)
            try require(observed.gains.last == 0, "Ready scene enabled native audio before play")
            surface.play()
            await surface.waitForPlaybackCommand()
            if let failure { throw failure }
            try require(surface.state == .playing && observed.gains.last == 0.6, "Play did not acknowledge with expected gain")
            try await waitUntil("Real scene pixels did not animate") { try frameHash(paintView) != prepared }
            surface.setTransitionGain(0.5)
            try require(observed.gains.last == 0.3, "Scene transition gain did not reach native output")
            let pageID = surface.interactivePageID
            surface.pause()
            try require(observed.gains.last == 0, "Pause did not synchronously gate native output")
            await surface.waitForPlaybackCommand()
            if let failure { throw failure }
            try require(surface.state == .paused && runtime.activePageCount == 1, "Pause released or lost the actual scene instance")
            try await Task.sleep(for: .milliseconds(150))
            let paused = try frameHash(paintView)
            try await Task.sleep(for: .milliseconds(300))
            try require(try frameHash(paintView) == paused, "Paused scene pixels continued animating")
            if let pageID {
                var rejected = false
                do { try surface.sendPointer(at: .zero, kind: "move", expectedPageID: pageID) }
                catch { rejected = true }
                try require(rejected, "Paused scene accepted stale pointer identity")
            }
            try await surface.prepareToResume()
            try require(surface.state == .ready && surface.subviews.first === paintView && factory.pages.count == 1,
                        "Resume preparation recreated the scene")
            surface.play()
            await surface.waitForPlaybackCommand()
            if let failure { throw failure }
            try require(surface.state == .playing && observed.gains.last == 0.3, "Resume did not restore playback gain")
            try await waitUntil("Resumed scene pixels did not animate") { try frameHash(paintView) != paused }
            let before = try markerX(paintView)
            guard let activeID = surface.interactivePageID else { throw WallpaperError("Playing scene has no interaction identity") }
            let target = before < 0.5 ? 0.8 : 0.2
            try surface.sendPointer(at: CGPoint(x: target * 320, y: 54), kind: "move", expectedPageID: activeID)
            try await waitUntil("Scene surface pointer did not move actual pixels") { abs(try markerX(paintView) - before) > 0.2 }
            surface.setGlobalMute(true)
            try require(observed.gains.last == 0, "Global mute did not gate native audio")
            surface.setGlobalMute(false)
            surface.setAudioSuppressed(true)
            try require(observed.gains.last == 0, "Audio suppression did not gate native audio")
            surface.setAudioSuppressed(false)
            try require(observed.gains.last == 0.3, "Audio suppression release did not restore expected gain")
            try await surface.close()
            try require(surface.state == .closed && runtime.activePageCount == 0 && observed.closeCount == 1,
                        "Scene surface retained CEF ownership after close")
            if let failure { throw failure }
            print("SCENE_SWIFT PASS representation=\(project.representation.rawValue) silentPrepare=1 animated=1 pauseRetained=1 resumeSamePage=1 nativeGain=1 pointerPixels=1 closed=1")
            fflush(stdout)
        } catch {
            do { try await surface.close() }
            catch { fputs("SCENE_SWIFT cleanup failure: \(error.localizedDescription)\n", stderr) }
            throw error
        }
    }

    @MainActor
    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 || (arguments.count == 6 && arguments[5] == "--system-audio") else {
            throw WallpaperError("Expected runtime, loose project, package project, cache paths and optional --system-audio")
        }
        let runtime = CEFApplicationRuntime(paths: .resolve(), cache: URL(fileURLWithPath: arguments[4]),
            sceneRuntimeRoot: URL(fileURLWithPath: arguments[1]))
        do {
            try await exercise(project: SceneProjectReference(root: URL(fileURLWithPath: arguments[2]),
                entry: "scene.json", representation: .loose), runtime: runtime)
            try await exercise(project: SceneProjectReference(root: URL(fileURLWithPath: arguments[3]),
                entry: "scene.pkg", representation: .package), runtime: runtime)
            if arguments.count == 6 {
                try await SystemSpectrumEvidence.run(project: SceneProjectReference(root: URL(fileURLWithPath: arguments[2]),
                    entry: "scene.json", representation: .loose), runtime: runtime,
                    directory: URL(fileURLWithPath: arguments[4]).deletingLastPathComponent())
            }
            try await runtime.shutdown()
            print("SCENE_SWIFT SHUTDOWN activePages=0")
        } catch {
            do { try await runtime.shutdown() }
            catch { fputs("SCENE_SWIFT shutdown failure: \(error.localizedDescription)\n", stderr) }
            throw error
        }
    }

    @MainActor
    static func main() {
        DWWebCreateApplication()
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { fputs("SCENE_SWIFT FAILED \(error.localizedDescription)\n", stderr); Darwin.exit(1) }
        }
        NSApp.run()
    }
}
