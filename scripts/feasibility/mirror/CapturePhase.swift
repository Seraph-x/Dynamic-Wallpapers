import AppKit
import AVFoundation
import ScreenCaptureKit
import WallpaperCore

@available(macOS 14.4, *)
@MainActor
final class CapturePhase {
    enum Mode: String { case frozen, stream, pull30, pull60 }
    struct FrameStatistics: Codable {
        let hostTime: Double
        let received: Int
        let enqueued: Int
        let pending: Int
        let statuses: [Int: Int]
        let latestDisplayTime: UInt64?
    }
    let mode: Mode
    private let source: NSWindow
    private let view: WallpaperMirrorView
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var stream: WallpaperMirrorStream?
    private var output: WallpaperMirrorFrameOutput?
    private var producer: Task<Void, Error>?
    private(set) var failure: Error?
    var recording = false
    private(set) var captureMilliseconds: [Double] = []

    init(mode: Mode, source: NSWindow, view: WallpaperMirrorView,
         filter: SCContentFilter, configuration: SCStreamConfiguration) {
        self.mode = mode; self.source = source; self.view = view
        self.filter = filter; self.configuration = configuration
    }

    var deliveredFrames: Int { output?.statistics.enqueuedFrames ?? 0 }
    var receivedFrames: Int { output?.statistics.receivedFrames ?? 0 }
    var replacedFrames: Int { output?.statistics.replacedFrames ?? 0 }
    var pendingFrames: Int { output?.statistics.pendingFrames ?? 0 }
    var frameStatistics: FrameStatistics? {
        guard let counts = output?.statistics else { return nil }
        return FrameStatistics(hostTime: ProcessInfo.processInfo.systemUptime,
            received: counts.receivedFrames, enqueued: counts.enqueuedFrames,
            pending: counts.pendingFrames, statuses: counts.frameStatuses,
            latestDisplayTime: counts.latestDisplayTime)
    }

    func start() async throws {
        switch mode {
        case .frozen:
            view.setUnderlay(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
        case .stream:
            let stream = try await WallpaperMirrorStream.make(window: source, view: view)
            self.stream = stream; output = stream.output
            stream.onFailure = { [weak self] in self?.failure = $0 }
            try await stream.start()
        case .pull30, .pull60:
            let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
            self.output = output
            output.onFailure = { [weak self] error, _ in self?.failure = error }
            let interval = 1.0 / (mode == .pull30 ? 30.0 : 60.0)
            producer = Task { @MainActor in
                do {
                    while !Task.isCancelled {
                        let began = ProcessInfo.processInfo.systemUptime
                        try await self.captureOneFrame()
                        let remainder = interval - (ProcessInfo.processInfo.systemUptime - began)
                        if remainder > 0 { try await Task.sleep(for: .seconds(remainder)) }
                    }
                    throw CancellationError()
                } catch is CancellationError { throw CancellationError() }
                catch { self.failure = error; throw error }
            }
        }
    }

    private func captureOneFrame() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        if recording { captureMilliseconds.append((ProcessInfo.processInfo.systemUptime - began) * 1000) }
        output?.receive(sample)
        // Do not retain the screenshot's IOSurface across the cadence wait.
    }

    func stop() async throws {
        recording = false
        output?.invalidate()
        producer?.cancel()
        var errors: [Error] = []
        if let producer {
            switch await producer.result {
            case .success: break
            case .failure(is CancellationError): break
            case .failure(let error): errors.append(error)
            }
        }
        producer = nil
        if let stream {
            do { try await stream.beginClose().value } catch { errors.append(error) }
        } else if let output {
            await output.finish()
        }
        view.setUnderlay(nil)
        self.stream = nil; output = nil
        CATransaction.flush()
        if errors.count == 1 { throw errors[0] }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
    }

    func displayedFingerprint() throws -> UInt64? {
        guard let buffer = view.videoLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw WallpaperError("Benchmark readback was not BGRA")
        }
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else { throw WallpaperError("Pixel readback lock: \(status)") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw WallpaperError("Benchmark displayed pixels are unavailable")
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var hash: UInt64 = 14695981039346656037
        for y in 1...7 { for x in 1...7 {
            let offset = (height * y / 8) * stride + width * x / 8 * 4
            for channel in 0..<3 { hash = (hash ^ UInt64(pointer[offset + channel])) &* 1099511628211 }
        } }
        return hash
    }
}
