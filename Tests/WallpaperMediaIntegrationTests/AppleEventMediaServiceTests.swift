import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class AppleEventMediaServiceTests: XCTestCase {
    func testDisabledNeverResolvesOrSendsToAnApplication() async throws {
        let service = AppleEventMediaService(resolveProcess: { _ in
            XCTFail("Disabled source must not resolve an application"); return nil
        })
        do { _ = try await service.read(source: .disabled, requestAuthorization: true); XCTFail("Expected disabled error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .disabled) }
        do { try await service.perform(.play, source: .disabled); XCTFail("Expected disabled error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .disabled) }
    }

    func testCancelledArtworkAlreadyQueuedBehindRealWorkerNeverResolvesOrSends() async throws {
        let queue = DispatchQueue(label: "owned.public-media.queued-cancellation")
        let entered = expectation(description: "Real serial worker is blocked")
        let queued = expectation(description: "Artwork production operation was actually enqueued")
        let release = DispatchSemaphore(value: 0)
        queue.async { entered.fulfill(); release.wait() }
        await fulfillment(of: [entered], timeout: 2)
        let service = AppleEventMediaService(eventTimeout: 0.15, resolveProcess: { _ in
            XCTFail("Cancelled queued artwork must not enter process resolution, authorization or native read")
            return nil
        }, schedule: { operation in
            queue.async(execute: operation)
            queued.fulfill()
        })
        let artwork = Task {
            try await service.readArtwork(for: SystemMediaArtworkIdentity(source: .music, trackID: "owned-0"))
        }
        await fulfillment(of: [queued], timeout: 2)
        artwork.cancel()
        release.signal()
        do { _ = try await artwork.value; XCTFail("Cancelled queued operation must resume with CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected queued artwork result: \(error)") }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    func testMissingRunningProcessIsExplicitAndNeverLaunchesAPlayer() async throws {
        let service = AppleEventMediaService(resolveProcess: { _ in nil })
        let result = try await service.read(source: .music, requestAuthorization: false)
        XCTAssertEqual(result, .applicationNotRunning)
        do { try await service.perform(.skipNext, source: .spotify); XCTFail("Expected unavailable error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .applicationNotRunning) }
    }
}
