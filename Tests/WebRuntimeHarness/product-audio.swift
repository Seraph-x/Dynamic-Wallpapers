import AppKit
import ScreenCaptureKit
import WallpaperCore

@MainActor
private final class ProductAudioCapture {
    let native = SystemAudioEvidence(), browser = SystemAudioEvidence()
    private let nativeQueue = DispatchQueue(label: "product-audio-native")
    private let browserQueue = DispatchQueue(label: "product-audio-browser")
    private var streams: [(SCStream, DispatchQueue, SystemAudioEvidence)] = []
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let own = content.applications.first(where: { $0.processID == getpid() }), let display = content.displays.first else {
            throw WallpaperError("Product audio test process is not enumerated")
        }
        let filters = [SCContentFilter(display: display, including: [own], exceptingWindows: []),
            SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID != getpid() },
                            exceptingWindows: [])]
        for (index, filter) in filters.enumerated() {
            let config = SCStreamConfiguration()
            config.capturesAudio = true; config.excludesCurrentProcessAudio = index == 1
            config.sampleRate = 48000; config.channelCount = 2; config.width = 2; config.height = 2
            let observer = index == 0 ? native : browser, queue = index == 0 ? nativeQueue : browserQueue
            let stream = SCStream(filter: filter, configuration: config, delegate: observer)
            try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            streams.append((stream, queue, observer))
        }
        try await ProductAcceptanceHarness.wait("Product audio capture did not become ready", failure: {
            let errors = self.native.snapshot().errors + self.browser.snapshot().errors
            return errors.isEmpty ? nil : WallpaperError(errors.joined(separator: "; "))
        }, until: { !self.native.snapshot().packets.isEmpty && !self.browser.snapshot().packets.isEmpty })
    }
    func stop() async throws {
        var failures: [String] = []
        var remaining: [(SCStream, DispatchQueue, SystemAudioEvidence)] = []
        for (stream, queue, observer) in streams {
            do {
                try await stream.stopCapture()
                await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
                observer.markCaptureStoppedAndDrained()
            } catch {
                remaining.append((stream, queue, observer))
                failures.append(error.localizedDescription)
            }
        }
        streams = remaining
        if !failures.isEmpty { throw WallpaperError(failures.joined(separator: "; ")) }
    }
    func save(_ directory: URL) throws {
        try native.writeEvidence(to: directory.appendingPathComponent("native-capture.json"))
        try browser.writeEvidence(to: directory.appendingPathComponent("default-capture.json"))
    }
}

extension ProductAcceptanceHarness {
    @MainActor static func runAudio(_ run: URL) async throws {
        let fixtures = run.appendingPathComponent("fixtures")
        let native = try await MediaProbe.inspect(fixtures.appendingPathComponent("native-330.mp4"))
        let extended = try await MediaProbe.inspect(fixtures.appendingPathComponent("extended-440.mkv"))
        let still = try await MediaProbe.inspect(fixtures.appendingPathComponent("still.png"))
        let web = try WebProjectProbe.inspect(WebProjectReference(root: fixtures.appendingPathComponent("web"), entry: "index.html"))
        let peer = try WebProjectProbe.inspect(WebProjectReference(root: fixtures.appendingPathComponent("peer"), entry: "index.html"))
        guard let screen = NSScreen.main else { throw WallpaperError("A display is required") }
        let runtime = CEFApplicationRuntime()
        let anchor = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 100, height: 50),
                              styleMask: [.titled], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false; anchor.title = "DynamicWallpaper product audio acceptance"
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil); anchor.close() }
        let window = DesktopWindow(screen: screen, surfaceFactory: SurfaceFactory(webPages: runtime))
        window.updateGeometry(frame: CGRect(x: 100, y: 100, width: 320, height: 180), scale: screen.backingScaleFactor)
        window.setGlobalMute(false)
        var failure: Error?, windows: [NativeRetirementAudioWindow] = []
        var groupWindows: [DesktopWindow] = [], session: PlaybackSession?
        window.onPlaybackError = { failure = $0 }
        let capture = ProductAudioCapture()
        struct Ramp: Codable { let name: String; let start: Double; let outgoing: String; let incoming: String }
        var ramps: [Ramp] = []
        func observe(_ name: String, silent: Bool) async throws {
            if let failure { throw failure }
            let start = hostNow
            try await Task.sleep(for: .milliseconds(850))
            windows.append(.init(name: name, start: start, end: hostNow, expectsSilence: silent))
            if let failure { throw failure }
        }
        func prepare(_ item: MediaItem) async throws {
            try await window.prepare(item: item, fit: .fit,
                entry: PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.8)))
            if item.kind == .web {
                guard let surface = window.contentView?.subviews.compactMap({ $0 as? WebSurface }).last else {
                    throw WallpaperError("Prepared product webpage view is missing")
                }
                try await wait("Actual product WebGL fixture did not become ready", failure: { failure }) {
                    webFrameIsGreen(surface)
                }
            }
        }
        func transition(_ name: String, duration: Double, outgoing: String, incoming: String) async throws {
            let start = hostNow
            let result = await window.transition(duration: duration, paused: false)
            try require(result.didDisplay, "Actual product window did not display \(name)")
            if let error = result.error { throw error }
            if duration > 0 { ramps.append(Ramp(name: name, start: start, outgoing: outgoing, incoming: incoming)) }
            try require(window.activeSurfaceCount == 1, "Completed transition retains old product surfaces")
        }
        func save() throws {
            try capture.save(run)
            try write(windows, to: run.appendingPathComponent("windows.json"))
            try write(ramps, to: run.appendingPathComponent("ramps.json"))
        }
        do {
            try await capture.start()
            try await prepare(native)
            try await transition("initial-native", duration: 0, outgoing: "silence", incoming: "native")
            try await observe("native", silent: false)
            try await prepare(extended)
            try await observe("native-with-preloaded-mpv", silent: false)
            try await transition("native-to-mpv", duration: 0.8, outgoing: "native", incoming: "mpv")
            try await observe("mpv", silent: false)
            try await prepare(web)
            try await observe("mpv-with-preloaded-web", silent: false)
            try await transition("mpv-to-web", duration: 0.8, outgoing: "mpv", incoming: "web")
            try await observe("web", silent: false)
            try await prepare(extended)
            try await transition("web-to-mpv", duration: 0.8, outgoing: "web", incoming: "mpv")
            try await observe("mpv-returned", silent: false)
            try await prepare(web)
            try await transition("direct-mpv-to-web", duration: 0, outgoing: "mpv", incoming: "web")
            try await observe("web-direct", silent: false)
            try await prepare(still)
            try await transition("web-to-still", duration: 0.8, outgoing: "web", incoming: "silence")
            try await observe("still", silent: true)
            try await prepare(web)
            try await transition("still-to-web", duration: 0.8, outgoing: "silence", incoming: "web")
            try await observe("web-from-still", silent: false)
            window.shutdown(); try await window.waitForClosing()
            try require(runtime.activePageCount == 0, "Initial product window retained a webpage")
            try await observe("single-window-closed", silent: true)

            for index in 0..<2 {
                let target = DesktopWindow(screen: screen, surfaceFactory: SurfaceFactory(webPages: runtime))
                target.updateGeometry(frame: CGRect(x: 100 + index * 340, y: 100, width: 320, height: 180),
                                      scale: screen.backingScaleFactor)
                target.setGlobalMute(false); target.onPlaybackError = { failure = $0 }
                groupWindows.append(target)
            }
            let entries = [web, peer].map { PlaylistEntry(mediaID: $0.id, timing: EntryTiming(seconds: 3),
                                                         audio: AudioSettings(volume: 0.8)) }
            var commits: [UUID] = [], status = ""
            let group = PlaybackSession(playlist: Playlist(name: "Isolated real group", entries: entries, transition: 0.8),
                media: [web, peer], endpoints: groupWindows, fit: .fit, autoAdvance: false,
                onCommit: { commits.append($0) }, onStatus: { status = $0; print("PRODUCT_GROUP status=\($0)") },
                onError: { failure = $0 })
            session = group; group.start()
            try await wait("Initial real group did not commit", failure: { failure }) { commits.last == entries[0].id }
            try await observe("group-playing", silent: false)
            group.next()
            try await wait("Real group did not start its webpage transition", failure: { failure }) { group.isTransitioning }
            try await Task.sleep(for: .milliseconds(180))
            group.setPaused(true)
            try await observe("group-transition-paused", silent: true)
            try await wait("Paused transition did not close all pages and commit its final entry", failure: { failure }) {
                !group.isTransitioning && commits.last == entries[1].id && runtime.activePageCount == 0
            }
            let pausedSurfaces = groupWindows.compactMap { $0.contentView?.subviews.first as? WebSurface }
            try require(pausedSurfaces.count == 2 && pausedSurfaces.allSatisfy { $0.state == .paused },
                        "Paused group did not retain its final webpage surfaces")
            let oldViews = pausedSurfaces.compactMap { $0.subviews.first }
            try require(oldViews.count == 2 && oldViews.allSatisfy { $0.layer?.contents != nil }, "Paused group lost its actual frames")
            group.setPaused(false)
            try await wait("Real group did not resume after all webpages were ready", failure: { failure }) {
                status == "正在播放" && runtime.activePageCount == 2 && pausedSurfaces.allSatisfy { $0.state == .playing }
            }
            try require(zip(pausedSurfaces, oldViews).allSatisfy { pair in pair.0.subviews.first !== pair.1 },
                        "Resume did not reload final webpages")
            try await observe("group-resumed", silent: false)
            group.stop(); session = nil
            for target in groupWindows { target.shutdown() }
            for target in groupWindows { try await target.waitForClosing() }
            try require(runtime.activePageCount == 0, "Closed real group retains webpages")
            try await runtime.shutdown()
            try await observe("all-closed", silent: true)
            try await capture.stop()
            try require(capture.native.snapshot().errors.isEmpty && capture.browser.snapshot().errors.isEmpty, "Product capture error")
            let packets = capture.native.snapshot().packets
            let reports = try windows.map { try $0.analyze(packets) }
            let defaults = try windows.map { try NativeRetirementAudioWindow(name: "default-" + $0.name,
                start: $0.start, end: $0.end, expectsSilence: true).analyze(capture.browser.snapshot().packets) }
            let levels = Dictionary(uniqueKeysWithValues: reports.map { ($0.name, $0.stableRMS) })
            func energy(_ name: String) throws -> Double {
                if name == "silence" { return 0 }
                guard let rms = levels[name] else { throw WallpaperError("Missing baseline \(name)") }
                return rms * rms
            }
            var ratios: [String: Double] = [:]
            for ramp in ramps {
                let middle = packets.filter { $0.start >= ramp.start + 0.32 && $0.end <= ramp.start + 0.48 }
                try require(middle.count >= 5 && middle.first!.start <= ramp.start + 0.35 && middle.last!.end >= ramp.start + 0.45,
                            "\(ramp.name): transition capture coverage is insufficient")
                let actual = middle.reduce(0) { $0 + $1.energy } / Double(middle.reduce(0) { $0 + $1.samples })
                let ratio = actual / (try energy(ramp.outgoing) + energy(ramp.incoming))
                try require((0.18...0.38).contains(ratio), "\(ramp.name): actual sound did not follow the shared transition, ratio=\(ratio)")
                ratios[ramp.name] = ratio
            }
            for (actual, baseline) in [("native-with-preloaded-mpv", "native"), ("mpv-with-preloaded-web", "mpv"),
                                      ("mpv-returned", "mpv"), ("web-direct", "web"), ("web-from-still", "web")] {
                let ratio = sqrt(try energy(actual) / energy(baseline))
                try require((0.85...1.15).contains(ratio), "\(actual): preload or retired output changed actual sound")
            }
            try write(reports, to: run.appendingPathComponent("native-analysis.json"))
            try write(defaults, to: run.appendingPathComponent("default-analysis.json"))
            try write(ratios, to: run.appendingPathComponent("transition-analysis.json"))
            try save()
            print("PRODUCT_AUDIO PASS actual-DesktopWindow=1 native-mpv-web=1 two-audible-transition=1 actual-PlaybackSession=1 transition-pause=1 group-reload=1 shutdown=1 physicalDisplays=one continuous=unverified")
        } catch {
            session?.stop()
            for target in [window] + groupWindows { target.shutdown() }
            for target in [window] + groupWindows {
                do { try await target.waitForClosing() } catch { fputs("PRODUCT_AUDIO window cleanup: \(error)\n", stderr) }
            }
            do { try await runtime.shutdown() } catch { fputs("PRODUCT_AUDIO runtime cleanup: \(error)\n", stderr) }
            do { try await capture.stop() } catch { fputs("PRODUCT_AUDIO capture cleanup: \(error)\n", stderr) }
            do { try save() } catch { fputs("PRODUCT_AUDIO evidence: \(error)\n", stderr) }
            throw error
        }
    }

    @MainActor private static func webFrameIsGreen(_ surface: WebSurface) -> Bool {
        guard let value = surface.subviews.first?.layer?.contents as AnyObject?, CFGetTypeID(value) == CGImage.typeID else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        return pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(value as! CGImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return bytes[0] < 20 && bytes[1] > 220 && bytes[2] < 20
        }
    }
}
