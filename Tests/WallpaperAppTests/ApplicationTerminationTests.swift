import AppKit
import Combine
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ApplicationTerminationTests: XCTestCase {
    func testContinueRunningDecisionDoesNotStartShutdown() async {
        var shutdowns = 0
        var confirmations = 0
        let termination = ApplicationTermination(shutdown: { shutdowns += 1 },
            reply: { _ in XCTFail("No deferred reply for a cancelled quit") }, report: { XCTFail("\($0)") },
            needsConfirmation: { true }, confirmCancellation: { confirmations += 1; return false })
        XCTAssertEqual(termination.request(), .terminateCancel)
        await Task.yield()
        XCTAssertEqual(shutdowns, 0)
        XCTAssertEqual(confirmations, 1)
    }

    func testConfirmedQuitDefersReplyAndDoesNotRepeatConfirmation() async throws {
        let started = expectation(description: "shutdown started")
        let replied = expectation(description: "actual shutdown completed")
        var completion: CheckedContinuation<Void, Never>?
        var confirmations = 0
        let termination = ApplicationTermination(shutdown: {
            await withCheckedContinuation { completion = $0; started.fulfill() }
        }, reply: { XCTAssertTrue($0); replied.fulfill() }, report: { XCTFail("\($0)") },
            needsConfirmation: { true }, confirmCancellation: { confirmations += 1; return true })
        XCTAssertEqual(termination.request(), .terminateLater)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(termination.request(), .terminateLater)
        XCTAssertEqual(confirmations, 1)
        completion?.resume()
        await fulfillment(of: [replied], timeout: 1)
    }

    func testQueuedScreenRefreshIsIgnoredOnceShutdownStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail(error.localizedDescription) }
        }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let original = try Data(contentsOf: store.url)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        let refreshed = expectation(description: "no screen refresh after shutdown")
        refreshed.isInverted = true
        refreshed.assertForOverFulfill = false
        let observer = model.$displays.dropFirst().sink { _ in refreshed.fulfill() }
        // The observer queues a MainActor task before removal; it must recheck the shutdown state.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.shutdown()
        try await model.shutdownAndWait()
        await fulfillment(of: [refreshed], timeout: 0.1)
        observer.cancel()
        XCTAssertTrue(model.isShuttingDown)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
    }

    func testReplyIsDeferredUntilActualShutdownCompletesAndDuplicateRequestsShareWork() async throws {
        var completion: CheckedContinuation<Void, Error>?
        var starts = 0
        var replies: [Bool] = []
        let started = expectation(description: "shutdown entered")
        let finished = expectation(description: "termination reply")
        let termination = ApplicationTermination(shutdown: {
            starts += 1
            try await withCheckedThrowingContinuation { completion = $0; started.fulfill() }
        }, reply: { replies.append($0); finished.fulfill() }, report: { XCTFail($0.localizedDescription) })
        XCTAssertEqual(termination.request(), .terminateLater)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(termination.request(), .terminateLater)
        XCTAssertEqual(starts, 1)
        completion?.resume()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(replies, [true])
    }

    func testFailedShutdownReportsErrorAndCancelsTermination() async {
        let replied = expectation(description: "failed termination cancelled")
        var errors: [String] = []
        var replies: [Bool] = []
        let termination = ApplicationTermination(shutdown: { throw WallpaperError("decoder close failed") },
            reply: { replies.append($0); replied.fulfill() }, report: { errors.append($0.localizedDescription) })
        XCTAssertEqual(termination.request(), .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(errors, ["decoder close failed"])
    }

    func testCloseBarrierWaitsForOtherResourcesAfterOneFailure() async {
        let started = expectation(description: "slow close began")
        var release: CheckedContinuation<Void, Never>?
        let failed = Task<Void, Error> { throw WallpaperError("first close failed") }
        let slow = Task<Void, Error> {
            await withCheckedContinuation { release = $0; started.fulfill() }
        }
        var completed = false
        let barrier = Task {
            do { try await PlaybackCloseBarrier.wait(for: [failed, slow]); XCTFail("Must report close failure") }
            catch { XCTAssertEqual(error.localizedDescription, "first close failed") }
            completed = true
        }
        await fulfillment(of: [started], timeout: 1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(completed, "Failure is not permission to abandon other closing resources")
        release?.resume()
        await barrier.value
        XCTAssertTrue(completed)
    }
}
