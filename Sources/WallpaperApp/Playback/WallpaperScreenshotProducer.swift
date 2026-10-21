import CoreMedia
import Foundation
import WallpaperCore

/// Serial pull capture. No request or pixel-buffer local survives a cadence wait.
@MainActor
final class WallpaperScreenshotProducer {
    private var frameInterval: Duration { .seconds(1.0 / Double(frameRate().rawValue)) }
    private let output: WallpaperMirrorFrameOutput
    private let frameRate: @MainActor () -> WallpaperMirrorFrameRate
    private let capture: @MainActor () async throws -> CMSampleBuffer
    private let clock = ContinuousClock()
    private var task: Task<Void, Never>?
    private var closing = false
    private var closeFailure: Error?

    init(output: WallpaperMirrorFrameOutput,
         frameRate: @escaping @MainActor () -> WallpaperMirrorFrameRate = { .hz30 },
         capture: @escaping @MainActor () async throws -> CMSampleBuffer) {
        self.output = output
        self.frameRate = frameRate
        self.capture = capture
    }

    var driver: WallpaperCaptureDriver {
        WallpaperCaptureDriver(start: { try await self.start() }, stop: { try await self.stop() },
            removeOutput: { try self.finish() }, cancelPendingWork: { self.cancelPendingWork() })
    }

    private func start() async throws {
        let requestedAt = clock.now
        do {
            try await captureAndPresent()
            task = Task { await self.produce(next: requestedAt + self.frameInterval) }
        } catch {
            retainClosingError(error)
            throw error
        }
    }

    private func produce(next initialDeadline: ContinuousClock.Instant) async {
        var next = initialDeadline
        while !closing && output.isAcceptingFrames {
            do {
                try await clock.sleep(until: next)
                let requestedAt = clock.now
                try await captureAndPresent()
                next = requestedAt + frameInterval
            } catch {
                if closing { retainClosingError(error) }
                else { output.captureDidStop(error) }
                return
            }
        }
    }

    private func captureAndPresent() async throws {
        try Task.checkCancellation()
        guard !closing, output.isAcceptingFrames else { throw CancellationError() }
        let sample = try await capture()
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        try output.receive(sample).get()
    }

    private func cancelPendingWork() {
        closing = true
        task?.cancel()
    }

    private func stop() async throws {
        cancelPendingWork()
        await task?.value
        try finish()
    }

    private func retainClosingError(_ error: Error) {
        // Cancellation is expected on close; an ordinary in-flight failure is not.
        if closing, !(error is CancellationError), closeFailure == nil { closeFailure = error }
    }

    private func finish() throws {
        task = nil
        if let closeFailure { throw closeFailure }
    }
}
