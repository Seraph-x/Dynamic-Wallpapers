import Foundation
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaReleaseClassificationTests: XCTestCase {
    func testProbeWorkspaceCleanupFailureDoesNotKeepItsClosedInputInUse() async throws {
        try await withWorkspaceFailure { source, failure in
            let item = MediaItem(url: source, kind: .video, width: 2, height: 2)
            let model = TranscodeModel(inspect: { _ in throw failure })
            model.select(item)
            try await wait { !model.isProbing }
            let presented = try XCTUnwrap(model.failure)
            XCTAssertNoThrow(try model.validateRemoval([item]))
            model.didRemoveMedia([item.id])
            XCTAssertEqual(model.failure, presented)
            do { try await model.beginShutdown().value; XCTFail("The original cleanup error must remain observable") }
            catch { XCTAssertTrue(error.localizedDescription.contains("workspace cleanup failed")) }
        }
    }

    func testCompletedQueueWorkspaceFailureDoesNotClaimSourceOrDestination() async throws {
        try await withWorkspaceFailure { source, failure in
            let metadata = Data("""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":2,"height":2,"avg_frame_rate":"24/1"}],"format":{"duration":"1"}}
            """.utf8)
            let plan = try TranscodePlan(media: TranscodeMedia(json: metadata), preset: .original)
            let queue = TranscodeQueue { _, _ in throw failure }
            queue.enqueue(try TranscodeRequest(source: source, destination: source.deletingLastPathComponent().appendingPathComponent("output.mp4"), plan: plan))
            try await wait { !queue.hasActiveJobs }
            XCTAssertTrue(queue.inUseURLs.isEmpty)
            guard case .failed = queue.jobs[0].state else { return XCTFail("Cleanup failure must not become a successful job") }
            do { try await queue.beginShutdown().value; XCTFail("The original cleanup error must remain observable") }
            catch { XCTAssertTrue(error.localizedDescription.contains("workspace cleanup failed")) }
        }
    }

    func testInspectionWorkspaceCleanupFailureDoesNotBlockFileRemoval() async throws {
        try await withWorkspaceFailure { source, failure in
            let item = MediaItem(url: source, kind: .video, width: 2, height: 2)
            let model = InspectorMediaModel { _ in throw failure }
            model.select(item)
            try await wait { !model.isChecking }
            XCTAssertNotNil(model.failure)
            do { try await model.beginRemovingMedia([item.id]).value }
            catch { XCTFail("A closed input must not block deletion: \(error)") }
            do { try await model.beginShutdown().value; XCTFail("The original cleanup error must remain observable") }
            catch { XCTAssertTrue(error.localizedDescription.contains("workspace cleanup failed")) }
        }
    }

    private func withWorkspaceFailure(_ body: (URL, Error) async throws -> Void) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("source.mp4")
        try Data("input bytes".utf8).write(to: source)
        var staging: URL?
        var inputFile: FileHandle?
        defer {
            do {
                if let staging { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: staging.path) }
                try FileManager.default.removeItem(at: parent)
            } catch { XCTFail("Could not clean workspace fixture: \(error)") }
        }
        let failure: Error
        do {
            try await TranscodeInput.withFile(source: source) { @MainActor @Sendable input in
                inputFile = input.file
                try await TranscodeWorkspace.withDirectory(in: parent, successCleanupMessage: "workspace cleanup failed") { @MainActor @Sendable directory in
                    staging = directory
                    XCTAssertEqual(try input.file.readToEnd(), Data("input bytes".utf8))
                    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)
                }
            }
            XCTFail("Expected a real filesystem cleanup failure")
            throw WallpaperError("Workspace fixture did not fail")
        } catch { failure = error }
        XCTAssertTrue(failure is TranscodeCleanupFailure)
        XCTAssertThrowsError(try XCTUnwrap(inputFile).offset(), "The source handle must already be closed")
        try await body(source, failure)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Release classification timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
