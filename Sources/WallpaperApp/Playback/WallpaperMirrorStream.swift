import AppKit
import ScreenCaptureKit
import WallpaperCore

@MainActor
struct WallpaperCaptureDriver {
    let start: () async throws -> Void
    let stop: () async throws -> Void
    let removeOutput: () throws -> Void
    let cancelPendingWork: () -> Void

    init(start: @escaping () async throws -> Void, stop: @escaping () async throws -> Void,
         removeOutput: @escaping () throws -> Void, cancelPendingWork: @escaping () -> Void = {}) {
        self.start = start; self.stop = stop; self.removeOutput = removeOutput
        self.cancelPendingWork = cancelPendingWork
    }
}

@MainActor
final class WallpaperMirrorStream {
    let output: WallpaperMirrorFrameOutput
    var onFailure: ((Error) -> Void)?
    private(set) var isClosed = false
    private(set) var releaseFailure: Error?
    private var driver: WallpaperCaptureDriver?
    private var startTask: Task<Void, Error>?
    private var closeTask: Task<Void, Error>?

    init(driver: WallpaperCaptureDriver, output: WallpaperMirrorFrameOutput) {
        self.driver = driver
        self.output = output
        output.onFailure = { [weak self] error, _ in
            guard let self, self.closeTask == nil else { return }
            self.onFailure?(error)
        }
    }

    func start() async throws {
        guard closeTask == nil, let driver else { throw CancellationError() }
        if startTask == nil { startTask = Task { try await driver.start() } }
        try await startTask?.value
        try Task.checkCancellation()
        guard closeTask == nil else { throw CancellationError() }
    }

    @discardableResult
    func beginClose() -> Task<Void, Error> {
        if let closeTask { return closeTask }
        output.invalidate()
        driver?.cancelPendingWork()
        let task = Task { @MainActor in
            do {
                if let starting = self.startTask, case .success = await starting.result, !self.output.hasStoppedCapture {
                    try await self.driver?.stop()
                }
                try self.driver?.removeOutput()
                await self.output.finish()
                self.output.onFailure = nil
                self.driver = nil
                self.startTask = nil
                self.isClosed = true
            } catch {
                await self.output.finish()
                self.releaseFailure = error
                throw error
            }
        }
        closeTask = task
        return task
    }

    static func make(window: NSWindow, view: WallpaperMirrorView) async throws -> WallpaperMirrorStream {
        let target = try await captureTarget(window: window)
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let stream = SCStream(filter: target.filter, configuration: target.configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        return WallpaperMirrorStream(driver: WallpaperCaptureDriver(
            start: { try await stream.startCapture() }, stop: { try await stream.stopCapture() },
            removeOutput: { try stream.removeStreamOutput(output, type: .screen) }), output: output)
    }

    static func makeScreenshot(window: NSWindow, view: WallpaperMirrorView,
                               frameRate: @escaping @MainActor () -> WallpaperMirrorFrameRate = { .hz30 }) async throws -> WallpaperMirrorStream {
        let target = try await captureTarget(window: window)
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let producer = WallpaperScreenshotProducer(output: output, frameRate: frameRate) {
            try await SCScreenshotManager.captureSampleBuffer(contentFilter: target.filter,
                                                               configuration: target.configuration)
        }
        return WallpaperMirrorStream(driver: producer.driver, output: output)
    }

    private static func captureTarget(window: NSWindow) async throws
        -> (filter: SCContentFilter, configuration: SCStreamConfiguration) {
        guard window.isVisible, let windowID = CGWindowID(exactly: window.windowNumber), windowID != 0 else {
            throw WallpaperError("壁纸窗口当前不可见，无法实时镜像。")
        }
        let configuration = try configuration(size: window.frame.size, scale: window.backingScaleFactor)
        let content: SCShareableContent
        if #available(macOS 14.4, *) { content = try await SCShareableContent.currentProcess }
        else { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        try Task.checkCancellation()
        guard let source = content.windows.first(where: { $0.windowID == windowID }) else {
            throw WallpaperError("未找到当前壁纸窗口，无法实时镜像。")
        }
        return (SCContentFilter(desktopIndependentWindow: source), configuration)
    }

    static func configuration(size: CGSize, scale: CGFloat) throws -> SCStreamConfiguration {
        guard size.width > 0, size.height > 0, scale.isFinite, scale > 0,
              let width = Int(exactly: (size.width * scale).rounded()), width > 0,
              let height = Int(exactly: (size.height * scale).rounded()), height > 0 else {
            throw WallpaperError("壁纸窗口的像素尺寸无效，无法实时镜像。")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = .zero // Follow the source display's native refresh rate.
        configuration.queueDepth = 3 // Capture, pending presentation and displayed IOSurface.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.scalesToFit = true
        return configuration
    }
}
