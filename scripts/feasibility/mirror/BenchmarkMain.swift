import WallpaperNative
import AppKit
import AVFoundation
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import WallpaperCore

@main
struct MirrorCaptureBenchmark {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        setbuf(stdout, nil)
        Task { @MainActor in
            do {
                guard #available(macOS 14.4, *) else { throw WallpaperError("Benchmark requires macOS 14.4 for displayed-pixel readback") }
                let benchmark = BenchmarkRun()
                defer { withExtendedLifetime(benchmark) {} }
                try await benchmark.run()
                Darwin.exit(0)
            } catch {
                fputs("BENCHMARK FAILED: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
        NSApp.run()
    }
}

@available(macOS 14.4, *)
@MainActor
private final class BenchmarkRun {
    struct Observation: Codable {
        let hostTime: Double
        let playerTime: Double
        let capture: CapturePhase.FrameStatistics?
        let targetFullScreen: Bool
        let targetOnActiveSpace: Bool
        let sourceOnActiveSpace: Bool
        let sourceOcclusionState: UInt
    }
    struct PhaseResult: Codable {
        let phase: String
        let mode: String
        let startUnix: Double
        let endUnix: Double
        let seconds: Double
        let cpuPercentOneCore: Double
        let processLifetimePeakResidentMiB: Double
        let receivedFPS: Double
        let deliveredFPS: Double
        let observedDisplayChangesPerSecond: Double
        let observedDisplaySamples: Int
        let displayObservationSeconds: Double
        let displayObservationStatus: String
        let playerProgressSamples: [Double]
        let performanceObservations: [Observation]
        let readbackObservations: [Observation]
        let pendingFramesMaximum: Int
        let replacedFrames: Int
        let captureMilliseconds: [Double]
    }
    private var sourceFailure: Error?
    private var results: [PhaseResult] = []
    private let view = WallpaperMirrorView()
    private weak var sourceWindow: NSWindow?
    private var directory = URL(fileURLWithPath: "/")

    func run() async throws {
        guard CommandLine.arguments.count == 4 else { throw WallpaperError("Expected video path, output directory and forward/reverse order") }
        directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path), let screen = NSScreen.main else {
            throw WallpaperError("Benchmark output directory or screen missing")
        }
        let order = CommandLine.arguments[3]
        guard ["forward", "reverse"].contains(order) else { throw WallpaperError("Unknown benchmark order") }
        let modes: [CapturePhase.Mode] = order == "forward"
            ? [.frozen, .stream, .pull30, .pull60, .frozen]
            : [.frozen, .pull60, .pull30, .stream, .frozen]
        let source = SourceWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        source.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        source.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        source.ignoresMouseEvents = true; source.hasShadow = false; source.isOpaque = false
        source.backgroundColor = .clear; source.animationBehavior = .none
        let surface = MediaSurface(size: screen.frame.size, fit: .fill)
        source.contentView = surface
        sourceWindow = source
        surface.onError = { [weak self] in self?.sourceFailure = $0 }
        let target = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.title = "Dynamic Wallpaper — capture performance comparison"
        target.collectionBehavior = [.fullScreenPrimary]
        target.contentView = view
        defer { target.close(); source.close() }
        do {
            source.orderBack(nil); target.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let item = MediaItem(url: URL(fileURLWithPath: CommandLine.arguments[1]), kind: .video,
                                 width: 1920, height: 1080, duration: 4)
            try await surface.prepare(item: item, scale: screen.backingScaleFactor, fit: .fill)
            surface.play()
            guard let player = surface.layer?.sublayers?.compactMap({ $0 as? AVPlayerLayer }).first?.player else {
                throw WallpaperError("Benchmark native player is unavailable")
            }
            try await fullScreen(true, window: target)
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) else {
                throw WallpaperError("Benchmark desktop source missing from own-process capture list")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = try WallpaperMirrorStream.configuration(size: source.frame.size, scale: source.backingScaleFactor)
            try writeJSON(["width": configuration.width, "height": configuration.height, "sourceFPS": 60,
                           "sourceWidth": 1920, "sourceHeight": 1080, "pid": Int(getpid()), "queueDepth": configuration.queueDepth], name: "geometry.json")
            for (index, mode) in modes.enumerated() {
                let phase = "\(index)-\(mode.rawValue)"
                let capture = CapturePhase(mode: mode, source: source, view: view, filter: filter, configuration: configuration)
                try await measure(capture, phase: phase, target: target, player: player)
            }
            try await fullScreen(false, window: target)
            try await surface.close()
            try writeJSON(["phase": "finished", "state": "finished", "pid": String(getpid())], name: "phase.json")
            try writeJSON(results, name: "results.json")
            print("BENCHMARK COMPLETE \(directory.path)")
        } catch {
            do { try await surface.close() } catch { fputs("BENCHMARK source cleanup failed: \(error)\n", stderr) }
            do { try await fullScreen(false, window: target) } catch { fputs("BENCHMARK fullscreen cleanup failed: \(error)\n", stderr) }
            throw error
        }
    }

    private func measure(_ capture: CapturePhase, phase: String, target: NSWindow, player: AVPlayer) async throws {
        try mark(phase, state: "warmup")
        do {
            try await capture.start()
            try await Task.sleep(for: .seconds(1))
            if let error = sourceFailure ?? capture.failure { throw error }
            try mark(phase, state: "measure")
            let began = ProcessInfo.processInfo.systemUptime, unix = Date().timeIntervalSince1970
            let cpuStart = try usage()
            let received = capture.receivedFrames, delivered = capture.deliveredFrames, replaced = capture.replacedFrames
            capture.recording = true
            var maxPending = 0
            var playerTimes: [Double] = []
            var performanceObservations: [Observation] = []
            // Pixel readback forces CPU/GPU synchronization. Keep it out of the performance window.
            while ProcessInfo.processInfo.systemUptime - began < 4 {
                if let error = sourceFailure ?? capture.failure { throw error }
                playerTimes.append(player.currentTime().seconds)
                performanceObservations.append(try observe(capture, target: target, player: player))
                maxPending = max(maxPending, capture.pendingFrames)
                try await Task.sleep(for: .milliseconds(50))
            }
            let end = ProcessInfo.processInfo.systemUptime, cpuEnd = try usage(), endUnix = Date().timeIntervalSince1970
            capture.recording = false
            let seconds = end - began
            let receivedFPS = Double(capture.receivedFrames - received) / seconds
            let deliveredFPS = Double(capture.deliveredFrames - delivered) / seconds
            let replacedFrames = capture.replacedFrames - replaced
            try mark(phase, state: "readback-evidence")
            let evidenceBegan = ProcessInfo.processInfo.systemUptime
            var previous: UInt64?, changes = 0, samples = 0
            var readbackObservations: [Observation] = []
            while ProcessInfo.processInfo.systemUptime - evidenceBegan < 2 {
                if let error = sourceFailure ?? capture.failure { throw error }
                readbackObservations.append(try observe(capture, target: target, player: player))
                if let fingerprint = try capture.displayedFingerprint() {
                    if let previous, previous != fingerprint { changes += 1 }
                    previous = fingerprint; samples += 1
                }
                try await Task.sleep(for: .seconds(1.0 / 60))
            }
            let evidenceSeconds = ProcessInfo.processInfo.systemUptime - evidenceBegan
            let observation = capture.mode == .frozen ? "frozen-baseline"
                : samples == 0 ? "unavailable" : changes == 0 ? "stalled" : "updating"
            let result = PhaseResult(phase: phase, mode: capture.mode.rawValue, startUnix: unix, endUnix: endUnix,
                seconds: seconds, cpuPercentOneCore: (cpuEnd.cpu - cpuStart.cpu) / seconds * 100,
                processLifetimePeakResidentMiB: cpuEnd.memory / 1048576, receivedFPS: receivedFPS,
                deliveredFPS: deliveredFPS,
                observedDisplayChangesPerSecond: Double(changes) / evidenceSeconds, observedDisplaySamples: samples,
                displayObservationSeconds: evidenceSeconds, displayObservationStatus: observation,
                playerProgressSamples: playerTimes,
                performanceObservations: performanceObservations, readbackObservations: readbackObservations,
                pendingFramesMaximum: maxPending, replacedFrames: replacedFrames,
                captureMilliseconds: capture.captureMilliseconds)
            results.append(result)
            try writeJSON(result, name: "\(phase).json")
            try mark(phase, state: "evidence")
            try await screenshot(target, name: "\(phase)-visible.png")
            print("PHASE \(phase) cpu=\(result.cpuPercentOneCore)% delivered=\(result.deliveredFPS)fps displayedChanges=\(result.observedDisplayChangesPerSecond)/s content=\(observation)")
            try mark(phase, state: "cleanup")
            try await capture.stop()
            try await Task.sleep(for: .milliseconds(150))
        } catch {
            do { try await capture.stop() } catch { fputs("BENCHMARK capture cleanup failed: \(error)\n", stderr) }
            throw error
        }
    }

    private func observe(_ capture: CapturePhase, target: NSWindow, player: AVPlayer) throws -> Observation {
        guard let source = sourceWindow else { throw WallpaperError("Benchmark source window was released") }
        return Observation(hostTime: ProcessInfo.processInfo.systemUptime, playerTime: player.currentTime().seconds,
            capture: capture.frameStatistics, targetFullScreen: target.styleMask.contains(.fullScreen),
            targetOnActiveSpace: target.isOnActiveSpace, sourceOnActiveSpace: source.isOnActiveSpace,
            sourceOcclusionState: source.occlusionState.rawValue)
    }

    private func usage() throws -> (cpu: Double, memory: Double) {
        var value = rusage()
        guard getrusage(RUSAGE_SELF, &value) == 0 else { throw WallpaperError("getrusage failed: \(errno)") }
        return (Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000, Double(value.ru_maxrss))
    }
    private func mark(_ phase: String, state: String) throws {
        try writeJSON(["phase": phase, "state": state, "pid": String(getpid())], name: "phase.json")
    }
    private func writeJSON<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func fullScreen(_ enabled: Bool, window: NSWindow) async throws {
        if window.styleMask.contains(.fullScreen) == enabled { return }
        var finished = false
        let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { finished = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        window.toggleFullScreen(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !finished {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw WallpaperError("Benchmark native fullscreen transition timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func screenshot(_ window: NSWindow, name: String) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw WallpaperError("Benchmark foreground missing from own-process capture list")
        }
        let config = try WallpaperMirrorStream.configuration(size: window.frame.size, scale: window.backingScaleFactor)
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: config)
        guard let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else { throw WallpaperError("Could not create benchmark screenshot") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError("Could not save benchmark screenshot") }
    }
}

@MainActor
private final class SourceWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
