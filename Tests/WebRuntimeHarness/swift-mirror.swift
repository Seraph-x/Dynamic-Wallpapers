import AppKit
import AVFoundation
import CoreVideo
import ScreenCaptureKit
import WallpaperCore

/// Exercises the product capture/presentation path, not a second CEF renderer.
@available(macOS 14.4, *)
@MainActor
enum WebSwiftMirrorHarness {
    private struct Pixel: Encodable, Hashable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private struct Sample: Encodable {
        let secondsAfterFullScreen: Double
        let pixel: Pixel
        let receivedFrames: Int
        let enqueuedFrames: Int
        let pendingFrames: Int
    }

    private struct Evidence: Encodable {
        let sourceWindowID: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let capturesAudio: Bool
        var pageID: UUID?
        var didEnterFullScreenAt: Double?
        var captureStartedAt: Double?
        var samples: [Sample] = []
        var observedSpanSeconds = 0.0
        var enqueuedAfterClose: Int?
        var pendingAfterClose: Int?
        var cleanupCompleted = false
        var failure: String?
    }

    static func run(project: WebProjectReference, runtime: CEFApplicationRuntime) async throws {
        guard let screen = NSScreen.main else { throw WallpaperError("CEF mirror test requires a display") }
        try WebSwiftHarness.require(runtime.activePageCount == 0, "Previous lifecycle fixture still owns a page")
        let desktop = makeDesktop(screen: screen)
        let mirror = WallpaperMirrorView()
        let foreground = makeForeground(screen: screen, mirror: mirror)
        let surface = WebSurface(size: screen.frame.size, fit: .fill, pageFactory: runtime)
        desktop.contentView?.addSubview(surface)
        let configuration = try WallpaperMirrorStream.configuration(size: desktop.frame.size, scale: desktop.backingScaleFactor)
        var evidence = Evidence(sourceWindowID: desktop.windowNumber, pixelWidth: configuration.width,
                                pixelHeight: configuration.height, capturesAudio: configuration.capturesAudio)
        var stream: WallpaperMirrorStream?
        var failure: Error?
        surface.onError = { failure = $0 }
        surface.setGlobalMute(true)
        let oldPolicy = NSApp.activationPolicy()
        defer {
            foreground.orderOut(nil); foreground.close()
            surface.removeFromSuperview(); desktop.orderOut(nil); desktop.close()
            NSApp.setActivationPolicy(oldPolicy)
        }
        do {
            try WebSwiftHarness.require(!configuration.capturesAudio, "Mirror enabled a second audio path")
            desktop.orderBack(nil)
            let item = MediaItem(url: project.entryURL, kind: .web,
                                 width: Int(screen.frame.width), height: Int(screen.frame.height),
                                 backend: .web, webProject: project)
            try await surface.prepare(item: item, scale: desktop.backingScaleFactor, fit: .fill)
            surface.play()
            guard let pageID = surface.interactivePageID else { throw WallpaperError("Dynamic CEF fixture did not play") }
            evidence.pageID = pageID
            NSApp.setActivationPolicy(.regular)
            foreground.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await setFullScreen(true, window: foreground)
            let enteredAt = ProcessInfo.processInfo.systemUptime
            evidence.didEnterFullScreenAt = enteredAt
            let capturing = try await WallpaperMirrorStream.make(window: desktop, view: mirror)
            stream = capturing
            capturing.onFailure = { failure = $0 }
            try await capturing.start()
            evidence.captureStartedAt = ProcessInfo.processInfo.systemUptime
            try await observe(capturing, view: mirror, evidence: &evidence) {
                if let failure { throw failure }
                try WebSwiftHarness.require(foreground.styleMask.contains(.fullScreen) && foreground.isOnActiveSpace,
                                            "Mirror target left its native fullscreen Space")
                try WebSwiftHarness.require(runtime.activePageCount == 1 && surface.interactivePageID == pageID,
                                            "Mirror created or replaced the original CEF page")
                try WebSwiftHarness.require(surface.window === desktop && surface.state == .playing,
                                            "The original CEF surface is no longer playing in its desktop window")
            }
            let closing = capturing.beginClose()
            try WebSwiftHarness.require(!capturing.output.isAcceptingFrames, "Exit did not immediately reject mirror frames")
            try await setFullScreen(false, window: foreground)
            try await closing.value
            let stopped = capturing.output.statistics
            try await Task.sleep(for: .milliseconds(100))
            try WebSwiftHarness.require(capturing.isClosed && capturing.releaseFailure == nil,
                                        "Mirror capture cleanup did not complete")
            try WebSwiftHarness.require(stopped.pendingFrames == 0 && capturing.output.statistics.enqueuedFrames == stopped.enqueuedFrames,
                                        "Mirror retained or delivered frames after close")
            try WebSwiftHarness.require(mirror.videoLayer.sampleBufferRenderer.displayedPixelBuffer() == nil,
                                        "Mirror retained its displayed buffer after close")
            try WebSwiftHarness.require(runtime.activePageCount == 1 && surface.interactivePageID == pageID,
                                        "Closing the mirror changed the original CEF page")
            try await surface.close()
            try WebSwiftHarness.require(runtime.activePageCount == 0, "Dynamic CEF fixture did not release its only page")
            if let failure { throw failure }
            evidence.enqueuedAfterClose = stopped.enqueuedFrames
            evidence.pendingAfterClose = stopped.pendingFrames
            evidence.cleanupCompleted = true
            try write(evidence, project: project)
            print("WEB_SWIFT_MIRROR PASS fullscreen=1 displayedChanges=1 sustained=1 uniquePage=1 audio=screen-only cleanup=1")
        } catch {
            if let stream {
                do { try await stream.beginClose().value }
                catch { fputs("WEB_SWIFT_MIRROR capture cleanup failed: \(error)\n", stderr) }
            }
            do { try await surface.close() }
            catch { fputs("WEB_SWIFT_MIRROR page cleanup failed: \(error)\n", stderr) }
            do { try await setFullScreen(false, window: foreground) }
            catch { fputs("WEB_SWIFT_MIRROR fullscreen cleanup failed: \(error)\n", stderr) }
            evidence.failure = String(describing: error)
            do { try write(evidence, project: project) }
            catch { fputs("WEB_SWIFT_MIRROR evidence failed: \(error)\n", stderr) }
            throw error
        }
    }

    private static func observe(_ stream: WallpaperMirrorStream, view: WallpaperMirrorView,
                                evidence: inout Evidence, validate: () throws -> Void) async throws {
        guard let enteredAt = evidence.didEnterFullScreenAt else { throw WallpaperError("Missing didEnterFullScreen evidence") }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while true {
            try validate()
            if let error = view.videoLayer.sampleBufferRenderer.error { throw error }
            let stats = stream.output.statistics
            try WebSwiftHarness.require(stats.pendingFrames <= 1, "Mirror exceeded its single pending buffer contract")
            if let pixel = try displayedPixel(view, width: evidence.pixelWidth, height: evidence.pixelHeight),
               pixel != evidence.samples.last?.pixel {
                let elapsed = ProcessInfo.processInfo.systemUptime - enteredAt
                evidence.samples.append(Sample(secondsAfterFullScreen: elapsed, pixel: pixel,
                    receivedFrames: stats.receivedFrames, enqueuedFrames: stats.enqueuedFrames, pendingFrames: stats.pendingFrames))
                evidence.observedSpanSeconds = elapsed - evidence.samples[0].secondsAfterFullScreen
                print("WEB_SWIFT_MIRROR pixel=\(pixel.red),\(pixel.green),\(pixel.blue) afterFullscreen=\(elapsed) "
                    + "size=\(evidence.pixelWidth)x\(evidence.pixelHeight) enqueued=\(stats.enqueuedFrames) pending=\(stats.pendingFrames)")
                if Set(evidence.samples.map(\.pixel)).count >= 6 && evidence.observedSpanSeconds >= 1.5 { return }
            }
            try WebSwiftHarness.require(ProcessInfo.processInfo.systemUptime < deadline,
                "Displayed CEF mirror did not sustain distinct post-transition pixels for 1.5 seconds")
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func displayedPixel(_ view: WallpaperMirrorView, width: Int, height: Int) throws -> Pixel? {
        guard let buffer = view.videoLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        try WebSwiftHarness.require(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height,
                                    "Displayed mirror buffer lost the desktop's native pixel geometry")
        try WebSwiftHarness.require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
                                    "Displayed mirror buffer is not BGRA")
        try WebSwiftHarness.require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
                                    "Could not lock the actual displayed mirror buffer")
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw WallpaperError("Displayed mirror pixels are unavailable") }
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let offset = (height / 2) * CVPixelBufferGetBytesPerRow(buffer) + (width / 2) * 4
        let pixel = Pixel(red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
        try WebSwiftHarness.require(abs(Int(pixel.green) - 208) <= 12 && abs(Int(pixel.blue) - 24) <= 12,
                                    "Mirror pixels are not from the dynamic CEF fixture (foreground or static frame captured)")
        return pixel
    }

    private static func setFullScreen(_ enabled: Bool, window: NSWindow) async throws {
        if window.styleMask.contains(.fullScreen) == enabled { return }
        var finished = false
        let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { finished = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.toggleFullScreen(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        while !finished {
            try WebSwiftHarness.require(ProcessInfo.processInfo.systemUptime < deadline, "Native fullscreen transition timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
        try WebSwiftHarness.require(window.styleMask.contains(.fullScreen) == enabled, "Native fullscreen notification/state mismatch")
    }

    private static func makeDesktop(screen: NSScreen) -> NSWindow {
        let window = WebMirrorDesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Keep these flags identical to DesktopWindow; do not promote the source into the fullscreen Space.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true; window.hasShadow = false; window.isOpaque = false
        window.backgroundColor = .clear; window.animationBehavior = .none
        window.contentView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        window.setFrame(screen.frame, display: false)
        return window
    }

    private static func makeForeground(screen: NSScreen, mirror: WallpaperMirrorView) -> NSWindow {
        let frame = screen.frame.insetBy(dx: screen.frame.width / 5, dy: screen.frame.height / 5)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — real CEF fullscreen mirror verification"
        window.collectionBehavior = [.fullScreenPrimary]
        mirror.autoresizingMask = [.width, .height]
        mirror.layer?.backgroundColor = NSColor.purple.cgColor
        window.contentView = mirror
        return window
    }

    private static func write(_ evidence: Evidence, project: WebProjectReference) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: project.root.deletingLastPathComponent().appendingPathComponent("mirror.json"))
    }
}

@MainActor
private final class WebMirrorDesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
