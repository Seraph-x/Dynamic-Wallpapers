import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration
@testable import WallpaperApp

@MainActor
final class SceneMediaNativeQueueTests: XCTestCase {
    private struct Service: SystemMediaServicing {
        let metadata = SceneMediaProviderFixture()
        let native: AppleEventMediaService
        func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
            try await metadata.read(source: source, requestAuthorization: requestAuthorization)
        }
        func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws {
            try await native.perform(command, source: source)
        }
    }

    func testPauseCancelsActualQueuedWorkWhileAnotherSceneStaysActive() async throws { try await check(.pause) }
    func testCloseCancelsActualQueuedWorkWhileAnotherSceneStaysActive() async throws { try await check(.close) }
    func testArtworkRetryInvalidatesActualQueuedControlRevision() async throws { try await check(.artwork) }

    private enum Invalidation { case pause, close, artwork }

    private func check(_ invalidation: Invalidation) async throws {
        let queue = DispatchQueue(label: "owned.media.scene.dispatch"), release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        let queued = expectation(description: "Real native control has passed Main gates and entered worker")
        let native = AppleEventMediaService(eventTimeout: 0.15, resolveProcess: { _ in
            XCTFail("Retired instance control must never enter OS process resolution"); return nil
        }, schedule: { operation in queue.async(execute: operation); queued.fulfill() })
        let media = SystemMediaController(service: Service(native: native), pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), a = UUID(), b = UUID()
        let first = SceneMediaSinkFixture(), second = SceneMediaSinkFixture()
        owner.register(a); owner.register(b)
        try await owner.prepare(a, command: first.send); try await owner.prepare(b, command: second.send)
        media.configure(source: .music); owner.setPlaying(a, true); owner.setPlaying(b, true)
        await media.settled(); try await owner.settled(a)
        let revision = try XCTUnwrap(first.received.last).revision
        let control = Task { try await owner.perform(.pause, id: a, revision: revision) }
        await fulfillment(of: [queued], timeout: 2)
        switch invalidation {
        case .pause: owner.setPlaying(a, false)
        case .close: owner.beginClose(a)
        case .artwork: await owner.retryArtwork()
        }
        release.signal()
        do { try await control.value; XCTFail("Expected retired native worker operation to cancel") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected native worker result: \(error)") }
        XCTAssertNotNil(media.snapshot, "The second playing scene retains its provider demand")
        await owner.shutdown()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
