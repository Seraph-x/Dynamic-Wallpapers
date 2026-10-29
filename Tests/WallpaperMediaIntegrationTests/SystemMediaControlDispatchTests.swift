import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

@MainActor
final class SystemMediaControlDispatchTests: XCTestCase {
    struct QueuedNativeControls: SystemMediaServicing {
        let native: AppleEventMediaService
        func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
            .current(try SystemMediaSnapshot(source: source, trackID: "owned-0", state: .playing,
                title: "Owned", artist: "", album: "", albumArtist: nil, position: 0, duration: 1))
        }
        func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws {
            try await native.perform(command, source: source)
        }
    }

    func testCallerCancellationReachesActualAppleEventWorker() async throws { try await check(.caller) }
    func testSourceSwitchCancelsControlAlreadyQueuedAtActualWorker() async throws { try await check(.source) }
    func testDemandLossCancelsControlAlreadyQueuedAtActualWorker() async throws { try await check(.demand) }
    func testShutdownCancelsControlAlreadyQueuedAtActualWorker() async throws { try await check(.shutdown) }

    private enum Invalidation { case caller, source, demand, shutdown }

    private func check(_ invalidation: Invalidation) async throws {
        let queue = DispatchQueue(label: "owned.media.controller.dispatch")
        let queued = expectation(description: "Production control entered the real blocked worker queue")
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let native = AppleEventMediaService(eventTimeout: 0.15, resolveProcess: { _ in
            XCTFail("An invalidated control must not resolve a process or send an Apple Event"); return nil
        }, schedule: { operation in queue.async(execute: operation); queued.fulfill() })
        let media = SystemMediaController(service: QueuedNativeControls(native: native), pollInterval: 3600)
        let id = UUID()
        media.configure(source: .music); media.setPlaying(id, true); await media.settled()
        let control = Task { try await media.perform(.skipNext) }
        await fulfillment(of: [queued], timeout: 2)
        var shutdown: Task<Void, Never>?
        switch invalidation {
        case .caller: control.cancel()
        case .source: media.configure(source: .spotify)
        case .demand: media.setPlaying(id, false)
        case .shutdown:
            shutdown = Task { await media.shutdown() }
            while media.status != .disabled { await Task.yield() }
        }
        release.signal()
        do { try await control.value; XCTFail("Expected cancellation before actual OS dispatch") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected dispatch result: \(error)") }
        await shutdown?.value
        await media.shutdown()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
