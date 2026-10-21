import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeQueueTests: XCTestCase {
    func testCompletedReleaseFailureKeepsResourceAndStillPreventsLaterShutdown() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        let weakResource = WeakTranscodeWitness()
        _ = queue.enqueue(try request("release-failure"))
        try await wait { worker.started.count == 1 }
        do {
            let resource = TranscodeResourceWitness()
            weakResource.value = resource
            worker.finish(.failure(TranscodeCleanupFailure(operation: "close encoder handle",
                cleanup: WallpaperError("resource not released"), resource: resource)))
        }
        try await wait { !queue.hasActiveJobs }
        await Task.yield()
        XCTAssertNotNil(weakResource.value, "A failed job must not discard an unreleased resource")
        do { try await queue.beginShutdown().value; XCTFail("Historical release failure must still reject shutdown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("resource not released")) }
    }

    func testCompletedOrdinaryJobFailureDoesNotPreventShutdown() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        _ = queue.enqueue(try request("ordinary-failure"))
        try await wait { worker.started.count == 1 }
        worker.finish(.failure(WallpaperError("unsupported input; resources closed")))
        try await wait { !queue.hasActiveJobs }
        try await queue.beginShutdown().value
    }

    func testShutdownWaitsForActualExitCancelsWaitingAndRejectsLateWork() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        _ = queue.enqueue(try request("first"))
        _ = queue.enqueue(try request("waiting"))
        try await wait { worker.started.count == 1 }
        let closing = queue.beginShutdown()
        var closed = false
        let observer = Task { try await closing.value; closed = true }
        _ = queue.enqueue(try request("late"))
        await Task.yield()
        XCTAssertFalse(closed)
        XCTAssertTrue(queue.hasActiveJobs)
        XCTAssertEqual(queue.jobs[0].state, .cancelling)
        XCTAssertEqual(queue.jobs[1].state, .cancelled)
        guard case .failed = queue.jobs[2].state else { return XCTFail("Shutdown must reject new jobs visibly") }
        worker.finish(.failure(CancellationError()))
        try await observer.value
        XCTAssertTrue(closed)
        XCTAssertFalse(queue.hasActiveJobs)
        XCTAssertEqual(worker.started.count, 1)
    }

    func testShutdownReportsCleanupFailureRatherThanApprovingExit() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        _ = queue.enqueue(try request("first"))
        try await wait { worker.started.count == 1 }
        let closing = queue.beginShutdown()
        worker.finish(.failure(WallpaperError("cleanup failed")))
        do { try await closing.value; XCTFail("Cleanup failure must reach application termination") }
        catch { XCTAssertEqual(error.localizedDescription, "cleanup failed") }
        XCTAssertEqual(queue.jobs[0].state, .failed(PresentedFailure(WallpaperError("cleanup failed"), context: .transcode)))
    }

    func testCommittedSuccessIsNotRelabelledCancelledByLateRequest() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        let request = try request("committed")
        let id = queue.enqueue(request)
        try await wait { worker.started.count == 1 }
        worker.finish(.success(request.destination))
        queue.cancel(id)
        try await wait { !queue.hasActiveJobs }
        XCTAssertEqual(queue.jobs[0].state, .succeeded)
        XCTAssertEqual(queue.jobs[0].output, request.destination)
    }

    func testSerialQueueWaitsForActualCancellationBeforeStartingNext() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        let first = queue.enqueue(try request("first"))
        let second = queue.enqueue(try request("second"))
        await Task.yield()
        XCTAssertEqual(worker.started, ["first.mp4"])
        queue.cancel(first)
        XCTAssertEqual(queue.jobs.first?.state, .cancelling)
        await Task.yield()
        XCTAssertEqual(worker.started.count, 1, "Cancellation request is not process exit")
        worker.finish(.failure(CancellationError()))
        try await wait { worker.started.count == 2 }
        XCTAssertEqual(queue.jobs.first?.state, .cancelled)
        worker.finish(.success(try request("second").destination))
        try await wait { !queue.hasActiveJobs }
        XCTAssertEqual(queue.jobs.first { $0.id == second }?.state, .succeeded)
    }
    func testWaitingCancellationAndFailureDoNotStopRemainingJobs() async throws {
        let worker = SuspendedTranscodeWorker()
        let queue = TranscodeQueue(execute: worker.run)
        _ = queue.enqueue(try request("first"))
        let waiting = queue.enqueue(try request("waiting"))
        _ = queue.enqueue(try request("last"))
        queue.cancel(waiting)
        await Task.yield()
        worker.finish(.failure(WallpaperError("encoder failed")))
        try await wait { worker.started.count == 2 }
        XCTAssertEqual(worker.started, ["first.mp4", "last.mp4"])
        XCTAssertEqual(queue.jobs[0].state, .failed(PresentedFailure(WallpaperError("encoder failed"), context: .transcode)))
        XCTAssertEqual(queue.jobs[1].state, .cancelled)
        worker.finish(.success(try request("last").destination))
        try await wait { !queue.hasActiveJobs }
    }
    private func request(_ name: String) throws -> TranscodeRequest {
        let data = Data("""
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":320,"height":180,"avg_frame_rate":"24/1"}],"format":{"duration":"2"}}
        """.utf8)
        return try TranscodeRequest(source: URL(fileURLWithPath: "/tmp/test-input.mkv"),
            destination: URL(fileURLWithPath: "/tmp/\(name).mp4"),
            plan: TranscodePlan(media: TranscodeMedia(json: data), preset: .original))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Queue test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SuspendedTranscodeWorker {
    var started: [String] = []
    var completion: CheckedContinuation<URL, Error>?
    func run(_ request: TranscodeRequest, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        started.append(request.destination.lastPathComponent)
        progress(0.3)
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(_ result: Result<URL, Error>) {
        let continuation = completion; completion = nil
        continuation?.resume(with: result)
    }
}
