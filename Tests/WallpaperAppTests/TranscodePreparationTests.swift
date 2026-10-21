import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodePreparationTests: XCTestCase {
    func testOldOrdinaryProbeFailureDoesNotPolluteNewSource() async throws {
        let probe = SuspendedProbe()
        let model = TranscodeModel(inspect: probe.run)
        model.select(item("a"))
        try await wait { probe.starts == ["a.mkv"] }
        let second = item("b")
        model.select(second)
        XCTAssertEqual(model.source?.id, second.id)
        XCTAssertNil(model.media)
        XCTAssertEqual(probe.starts.count, 1)
        probe.finish(.failure(WallpaperError("a metadata failed, resources already closed")))
        try await wait { probe.starts.count == 2 }
        probe.finish(.success(try media(width: 222)))
        try await wait { !model.isProbing }
        XCTAssertEqual(model.source?.id, second.id)
        XCTAssertEqual(model.media?.width, 222)
        XCTAssertNil(model.errorMessage, "Old ordinary failure must not belong to b")
        try await model.beginShutdown().value
    }

    func testShutdownPreservesOldCleanupFailureWhileReplacementIsCancelled() async throws {
        let probe = SuspendedProbe()
        let model = TranscodeModel(inspect: probe.run)
        model.select(item("a"))
        try await wait { probe.starts.count == 1 }
        model.select(item("b"))
        let closing = model.beginShutdown()
        var closed = false
        let observer = Task { defer { closed = true }; try await closing.value }
        await Task.yield()
        XCTAssertFalse(closed)
        probe.finish(.failure(TranscodeCleanupFailure(operation: "Close probe a", cleanup: WallpaperError("probe cleanup failed"))))
        do { try await observer.value; XCTFail("Old cleanup failure must prevent a successful shutdown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("probe cleanup failed")) }
        XCTAssertEqual(probe.starts, ["a.mkv"])
    }

    func testCleanCancellationDoesNotStartReplacementAndAllowsShutdown() async throws {
        let probe = SuspendedProbe()
        let model = TranscodeModel(inspect: probe.run)
        model.select(item("a"))
        try await wait { probe.starts.count == 1 }
        model.select(item("b"))
        let closing = model.beginShutdown()
        probe.finish(.failure(CancellationError()))
        try await closing.value
        XCTAssertEqual(probe.starts, ["a.mkv"])
        XCTAssertFalse(model.isProbing)
    }

    func testInvalidNamesAreRejectedAfterSuccessfulProbe() async throws {
        let model = TranscodeModel(inspect: { _ in try self.media(width: 320) })
        model.select(item("a"))
        try await wait { !model.isProbing }
        XCTAssertNotNil(model.media)
        for name in ["../overwrite.mp4", "", "missing.mov", "invalid\0.mp4", "folder/out.mp4"] {
            XCTAssertFalse(model.enqueue(directory: URL(fileURLWithPath: "/tmp"), name: name,
                                         managedMediaDirectory: URL(fileURLWithPath: "/tmp/Media")))
            XCTAssertTrue(try XCTUnwrap(model.errorMessage).contains("文件名"), name)
        }
        XCTAssertTrue(model.queue.jobs.isEmpty)
        try await model.beginShutdown().value
    }

    private func item(_ name: String) -> MediaItem {
        MediaItem(url: URL(fileURLWithPath: "/tmp/\(name).mkv"), kind: .video, width: 320, height: 180, backend: .extended)
    }
    private func media(width: Int) throws -> TranscodeMedia {
        try TranscodeMedia(json: Data("""
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":\(width),"height":180,"avg_frame_rate":"24/1"}],"format":{"duration":"2"}}
        """.utf8))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Probe test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SuspendedProbe {
    var starts: [String] = []
    var completion: CheckedContinuation<TranscodeMedia, Error>?
    func run(_ source: URL) async throws -> TranscodeMedia {
        starts.append(source.lastPathComponent)
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(_ result: Result<TranscodeMedia, Error>) {
        let current = completion; completion = nil
        current?.resume(with: result)
    }
}
