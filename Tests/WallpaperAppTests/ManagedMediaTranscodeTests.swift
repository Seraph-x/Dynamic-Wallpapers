import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaTranscodeTests: XCTestCase {
    func testRejectsOutputInManagedDirectoriesAndTheirSymlinkAliases() async throws {
        let queue = TranscodeQueue { _, _ in throw CancellationError() }
        let transcode = TranscodeModel(queue: queue, tools: { TranscodeTestFixtures.tools })
        let fixture = try ManagedLifecycleFixture(transcoding: transcode)
        let video = try await VideoIntegrationTests.makeVideo()
        let original = fixture.directory.appendingPathComponent("source.mp4")
        try FileManager.default.moveItem(at: video, to: original)
        let item = try await fixture.importURL(original)
        transcode.select(item)
        try await wait { !transcode.isProbing }
        XCTAssertNotNil(transcode.media)
        let mediaRoot = fixture.model.managedImport.files.directory
        let linked = fixture.directory.appendingPathComponent("linked-output")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: item.url.deletingLastPathComponent())
        let outwardLink = mediaRoot.appendingPathComponent("external-output")
        try FileManager.default.createSymbolicLink(at: outwardLink, withDestinationURL: fixture.directory)
        for directory in [item.url.deletingLastPathComponent(), mediaRoot, linked, outwardLink] {
            XCTAssertFalse(transcode.enqueue(directory: directory, name: "output.mp4", managedMediaDirectory: mediaRoot), directory.path)
            XCTAssertTrue(transcode.errorMessage?.contains("托管素材目录") == true)
        }
        XCTAssertTrue(queue.jobs.isEmpty, "Rejected destinations must never enter the worker queue")
        try await fixture.close()
    }

    func testWebRemovalChecksTranscodeUseAcrossTheWholeOwnedDirectory() async throws {
        let gate = ManagedReadGate()
        let queue = TranscodeQueue { _, _ in await gate.wait(); throw CancellationError() }
        let fixture = try ManagedLifecycleFixture(transcoding: TranscodeModel(queue: queue))
        defer { gate.release() }
        let root = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<!doctype html>".utf8).write(to: root.appendingPathComponent("pages/index.html"))
        let video = try await VideoIntegrationTests.makeVideo()
        try FileManager.default.moveItem(at: video, to: root.appendingPathComponent("assets/video.mp4"))
        let imported = await fixture.model.importWebProject(WebProjectReference(root: root, entry: "pages/index.html"))
        XCTAssertTrue(imported)
        let item = try XCTUnwrap(fixture.model.library.media.first)
        let source = try XCTUnwrap(item.webProject).root.appendingPathComponent("assets/video.mp4")
        let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        let plan = try TranscodePlan(media: media, preset: .original)
        queue.enqueue(try TranscodeRequest(source: source, destination: fixture.directory.appendingPathComponent("output.mp4"), plan: plan))
        try await wait { gate.started }
        fixture.model.removeMedia(item.id)
        await fixture.model.waitForMediaRemovals()
        XCTAssertTrue(fixture.model.library.media.contains(item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        gate.release()
        try await wait { !queue.hasActiveJobs }
        try await fixture.close()
    }

    func testInheritedProbeReleaseErrorDoesNotClaimAnUnreadSource() async throws {
        let first = URL(fileURLWithPath: "/first.mp4")
        let second = URL(fileURLWithPath: "/second.mp4")
        var probes: [URL] = []
        let model = TranscodeModel(inspect: { url in
            probes.append(url)
            throw TranscodeCleanupFailure(operation: "close first reader", cleanup: WallpaperError("release failed"),
                                          retainedFileURLs: [url])
        })
        let a = MediaItem(url: first, kind: .video, width: 2, height: 2)
        let b = MediaItem(url: second, kind: .video, width: 2, height: 2)
        model.select(a)
        try await wait { !model.isProbing }
        model.select(b)
        try await wait { !model.isProbing }
        XCTAssertEqual(probes, [first])
        XCTAssertThrowsError(try model.validateRemoval([a]))
        XCTAssertNoThrow(try model.validateRemoval([b]))
        do { try await model.beginShutdown().value; XCTFail("Unreleased first probe must still be reported") }
        catch { XCTAssertTrue(error.localizedDescription.contains("release failed")) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Transcode ownership test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
