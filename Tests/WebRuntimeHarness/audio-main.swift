import AppKit
import CoreMedia
import ScreenCaptureKit
import WebWallpaperBridge
import WallpaperCore
import Darwin

@main
struct WebAudioHarness {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw WallpaperError(message) }
    }
    @MainActor static func run() async throws {
        try require(CommandLine.arguments.count == 2, "Expected isolated project")
        let project = WebProjectReference(root: URL(fileURLWithPath: CommandLine.arguments[1]), entry: "index.html")
        let output = project.root.deletingLastPathComponent()
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "DynamicWallpaper isolated audio test"
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        let capture = SystemAudioEvidence(), queue = DispatchQueue(label: "web-audio-own-output")
        let bypass = SystemAudioEvidence(), bypassQueue = DispatchQueue(label: "web-audio-default-output")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let own = content.applications.first(where: { $0.processID == getpid() }), let display = content.displays.first else {
            throw WallpaperError("Audio test application is not enumerated")
        }
        let stream = try makeStream(SCContentFilter(display: display, including: [own], exceptingWindows: []),
                                    excludingSelf: false, observer: capture, queue: queue)
        let defaultStream = try makeStream(SCContentFilter(display: display,
            excludingApplications: content.applications.filter { $0.processID != getpid() }, exceptingWindows: []),
            excludingSelf: true, observer: bypass, queue: bypassQueue)
        let runtime = CEFApplicationRuntime()
        let surface = WebSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime)
        var error: Error?, windows: [NativeRetirementAudioWindow] = []
        var capturing = false, capturingDefault = false
        surface.onError = { error = $0 }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func writeEvidence() throws {
            try capture.writeEvidence(to: output.appendingPathComponent("native-capture.json"))
            try bypass.writeEvidence(to: output.appendingPathComponent("default-capture.json"))
            try encoder.encode(windows).write(to: output.appendingPathComponent("windows.json"), options: .withoutOverwriting)
        }
        do {
            try await stream.startCapture(); capturing = true
            try await defaultStream.startCapture(); capturingDefault = true
            let captureDeadline = ContinuousClock.now + .seconds(10)
            while capture.snapshot().packets.isEmpty || bypass.snapshot().packets.isEmpty {
                try require(ContinuousClock.now < captureDeadline, "Audio capture did not become ready")
                try require(capture.snapshot().errors.isEmpty && bypass.snapshot().errors.isEmpty, "Capture startup error")
                try await Task.sleep(for: .milliseconds(20))
            }
            print("WEB_AUDIO READY ownPID=\(getpid()) defaultScope=exclude-enumerated-others-and-self")
            let item = MediaItem(url: project.entryURL, kind: .web, width: 320, height: 180,
                                 backend: .web, webProject: project)
            surface.setGlobalMute(false); surface.setAudio(AudioSettings(volume: 0.2))
            window.contentView = surface
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            try await waitForGreen(surface, failure: { error })
            windows.append(try await observe("prepared", silent: true))
            surface.play()
            windows.append(try await observe("volume-20", silent: false))
            surface.setAudio(AudioSettings(volume: 0.8))
            windows.append(try await observe("volume-80", silent: false))
            surface.setGlobalMute(true)
            windows.append(try await observe("global-mute", silent: true))
            surface.setGlobalMute(false)
            surface.setAudio(AudioSettings(isMuted: true, volume: 0.8))
            windows.append(try await observe("entry-mute", silent: true))
            surface.setAudio(AudioSettings(volume: 0.8))
            windows.append(try await observe("unmuted", silent: false))
            let oldView = surface.subviews.first
            let oldFrame = oldView?.layer?.contents as AnyObject?
            surface.pause()
            windows.append(try await observe("paused", silent: true))
            let closeDeadline = ContinuousClock.now + .seconds(8)
            while surface.state == .pausing {
                try require(ContinuousClock.now < closeDeadline, "Pause did not finish closing")
                try await Task.sleep(for: .milliseconds(10))
            }
            if let error { throw error }
            try require(runtime.activePageCount == 0 && surface.state == .paused, "Paused webpage still owns running session")
            try require(surface.subviews.first === oldView && surface.subviews.first?.layer?.contents as AnyObject? === oldFrame,
                        "Pause frame changed")
            try await surface.prepareToResume()
            try require(surface.subviews.first === oldView, "Resume preparation prematurely replaced pause frame")
            windows.append(try await observe("resume-prepared", silent: true))
            surface.play()
            try require(surface.subviews.first !== oldView, "Resume did not commit reloaded page")
            try await waitForGreen(surface, failure: { error })
            windows.append(try await observe("resumed", silent: false))
            try await surface.close()
            windows.append(try await observe("closed", silent: true))
            try require(runtime.activePageCount == 0, "Closed webpage retains session")
            try await runtime.shutdown()
            if let error { throw error }
            try await stop(stream, queue: queue, observer: capture); capturing = false
            try await stop(defaultStream, queue: bypassQueue, observer: bypass); capturingDefault = false
            let native = capture.snapshot(), browser = bypass.snapshot()
            try require(native.errors.isEmpty && browser.errors.isEmpty, "Capture failed")
            let reports = try windows.map { try $0.analyze(native.packets) }
            let bypassReports = try windows.map {
                try NativeRetirementAudioWindow(name: "default-" + $0.name, start: $0.start, end: $0.end, expectsSilence: true)
                    .analyze(browser.packets)
            }
            guard let low = reports.first(where: { $0.name == "volume-20" }), let high = reports.first(where: { $0.name == "volume-80" }) else {
                throw WallpaperError("Gain evidence is missing")
            }
            try require((3.2...4.8).contains(high.stableRMS / low.stableRMS), "Native gain did not change actual output by factor four")
            try encoder.encode(reports).write(to: output.appendingPathComponent("native-analysis.json"))
            try encoder.encode(bypassReports).write(to: output.appendingPathComponent("default-analysis.json"))
            try writeEvidence()
            print("WEB_AUDIO PASS webgl=1 fixture-progress=1 native-gain=1 gates=1 pause-close=1 reload=1 shutdown=1 default-covered-samples=zero continuous=unverified physicalAcoustics=unverified")
        } catch {
            do { try await surface.close(); try await runtime.shutdown() }
            catch { fputs("WEB_AUDIO cleanup failed: \(error)\n", stderr) }
            if capturing { do { try await stop(stream, queue: queue, observer: capture) } catch { fputs("WEB_AUDIO capture cleanup: \(error)\n", stderr) } }
            if capturingDefault { do { try await stop(defaultStream, queue: bypassQueue, observer: bypass) } catch { fputs("WEB_AUDIO default capture cleanup: \(error)\n", stderr) } }
            do { try writeEvidence() } catch { fputs("WEB_AUDIO evidence failed: \(error)\n", stderr) }
            throw error
        }
    }
    static func makeStream(_ filter: SCContentFilter, excludingSelf: Bool, observer: SystemAudioEvidence,
                           queue: DispatchQueue) throws -> SCStream {
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.excludesCurrentProcessAudio = excludingSelf
        config.sampleRate = 48000; config.channelCount = 2; config.width = 2; config.height = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: observer)
        try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: queue)
        return stream
    }
    static func observe(_ name: String, silent: Bool) async throws -> NativeRetirementAudioWindow {
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await Task.sleep(for: .milliseconds(850))
        return .init(name: name, start: start, end: CMClockGetTime(CMClockGetHostTimeClock()).seconds, expectsSilence: silent)
    }
    @MainActor static func waitForGreen(_ surface: WebSurface, failure: () -> Error?) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if let error = failure() { throw error }
            if let contents = surface.subviews.first?.layer?.contents as AnyObject?, CFGetTypeID(contents) == CGImage.typeID {
                let frame = contents as! CGImage
                var pixel = [UInt8](repeating: 0, count: 4)
                let green = pixel.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(frame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return bytes[1] > 220 && bytes[0] < 20 && bytes[2] < 20
                }
                if green { return }
            }
            try require(ContinuousClock.now < deadline, "Actual WebGL/media progression frame never became green")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func stop(_ stream: SCStream, queue: DispatchQueue, observer: SystemAudioEvidence) async throws {
        try await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        observer.markCaptureStoppedAndDrained()
    }
    @MainActor static func main() {
        DWWebCreateApplication(); NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if !(try await HarnessAuthorization.runIfRequested()) {
                    if CommandLine.arguments.count == 3 { try await runPair() }
                    else { try await run() }
                }
                Darwin.exit(0)
            }
            catch { fputs("WEB_AUDIO FAILED \(error)\n", stderr); Darwin.exit(1) }
        }
        NSApp.run()
    }
}
