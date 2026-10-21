import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class TranscodeAppModelTests: XCTestCase {
    func testVideoPreparationQueueAndExplicitLibraryOnlyImport() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let item = try await MediaProbe.inspect(source)
        var library = Library.empty
        library.media = [item]
        library.playlists[0].entries = [PlaylistEntry(mediaID: item.id)]
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(library)
        let before = try Data(contentsOf: store.url)
        let transcoding = TranscodeModel(tools: { TranscodeTestFixtures.tools })
        let model = AppModel(store: store, transcoding: transcoding)
        defer { model.shutdown() }
        model.section = .playlist(library.playlists[0].id)
        transcoding.select(item)
        try await wait { !transcoding.isProbing }
        XCTAssertNil(transcoding.errorMessage)
        XCTAssertNotNil(transcoding.media)
        XCTAssertTrue(transcoding.enqueue(directory: directory, name: "new video.mp4", managedMediaDirectory: model.managedImport.files.directory))
        try await wait { !transcoding.queue.hasActiveJobs }
        XCTAssertEqual(transcoding.queue.jobs[0].state, .succeeded)
        XCTAssertEqual(try Data(contentsOf: store.url), before, "Transcoding must not import or mutate playlists")
        let output = try XCTUnwrap(transcoding.queue.jobs[0].output)
        model.importTranscodedOutput(output)
        try await wait { !model.importing }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.library.media.count, 2)
        XCTAssertEqual(model.library.playlists, library.playlists)
        XCTAssertEqual(try store.load().playlists, library.playlists)
        try await model.shutdownAndWait()
    }

    func testClosingTranscodeWindowKeepsApplicationOwnedJobAndShutdownWaits() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let started = expectation(description: "worker started")
        var completion: CheckedContinuation<URL, Error>?
        let queue = TranscodeQueue { _, _ in
            try await withCheckedThrowingContinuation { completion = $0; started.fulfill() }
        }
        let transcoding = TranscodeModel(queue: queue, tools: { TranscodeTestFixtures.tools })
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store, transcoding: transcoding)
        let source = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let media = try await FFmpegJob.inspect(source: source, tools: TranscodeTestFixtures.tools)
        let request = try TranscodeRequest(source: source, destination: directory.appendingPathComponent("output.mp4"),
                                          plan: TranscodePlan(media: media, preset: .original))
        _ = queue.enqueue(request)
        await fulfillment(of: [started], timeout: 1)
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 760, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: (TranscodeView(model: model)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderBack(nil)
        window.close(); window.contentView = nil
        XCTAssertEqual(queue.jobs[0].state, .running)
        XCTAssertTrue(queue.hasActiveJobs)
        var ended = false
        let shutdown = Task { try await model.shutdownAndWait(); ended = true }
        try await wait { queue.jobs[0].state == .cancelling }
        XCTAssertFalse(ended)
        completion?.resume(throwing: CancellationError())
        try await shutdown.value
        XCTAssertTrue(ended)
    }

    func testInvalidOutputNameAndNonVideoSourceAreReported() async throws {
        let transcoding = TranscodeModel(tools: { TranscodeTestFixtures.tools })
        transcoding.select(MediaItem(url: URL(fileURLWithPath: "/tmp/test.png"), kind: .image, width: 10, height: 10))
        XCTAssertNotNil(transcoding.errorMessage)
        XCTAssertFalse(transcoding.isProbing)
        XCTAssertFalse(transcoding.enqueue(directory: URL(fileURLWithPath: "/tmp"), name: "../overwrite.mp4",
                                           managedMediaDirectory: URL(fileURLWithPath: "/tmp/Media")))
        XCTAssertTrue(transcoding.queue.jobs.isEmpty)
        try await transcoding.beginShutdown().value
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Transcode model test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
