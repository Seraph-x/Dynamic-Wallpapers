import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PlaybackStartupTests: XCTestCase {
    func testTimingEditRestartsTheRestoredEntryBeforeItsFirstFrame() async throws {
        try await verifyStartup(restored: true, edit: .timing)
    }

    func testFavoriteEditRestartsTheRestoredEntryBeforeItsFirstFrame() async throws {
        try await verifyStartup(restored: true, edit: .favorite)
    }

    func testTimingEditStillStartsTheFirstEntryWithoutRestoredProgress() async throws {
        try await verifyStartup(restored: false, edit: .timing)
    }

    func testRemovingTheRestoredEntryStartsTheRemainingEntry() async throws {
        try await verifyStartup(restored: true, edit: .removeCurrent)
    }

    func testEditingPausedStartupWaitsForResumeBeforePreparingAgain() async throws {
        try await verifyStartup(restored: true, edit: .timing, paused: true)
    }

    private enum Edit { case timing, favorite, removeCurrent }

    private func verifyStartup(restored: Bool, edit: Edit, paused: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let url = directory.appendingPathComponent("wallpaper.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        var item = MediaItem(url: url, kind: .image, width: 2, height: 2)
        let first = PlaylistEntry(mediaID: item.id)
        let restoredEntry = PlaylistEntry(mediaID: item.id)
        var playlist = Playlist(name: "Startup", entries: [first, restoredEntry])
        let expectedEntry = restored && edit != .removeCurrent ? restoredEntry.id : first.id
        let preparing = expectation(description: "Initial preparation started")
        let cancelled = expectation(description: "Obsolete preparation cancelled")
        let displayed = expectation(description: "Updated startup displayed the expected entry")
        let endpoint = StartupEndpoint()
        endpoint.onInitialPrepare = { preparing.fulfill() }
        endpoint.onCancellation = { cancelled.fulfill() }
        let session = PlaybackSession(playlist: playlist, media: [item], endpoints: [endpoint], fit: .fill,
            current: restored ? restoredEntry.id : nil, autoAdvance: false,
            onCommit: { id in
                XCTAssertEqual(id, expectedEntry, "Restart must retain a valid restored entry")
                displayed.fulfill()
            }, onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        defer { session.stop() }
        session.start()
        await fulfillment(of: [preparing], timeout: 1)
        if paused { session.setPaused(true) }
        switch edit {
        case .timing: playlist.entries[restored ? 1 : 0].timing.seconds = 60
        case .favorite: item.isFavorite = true
        case .removeCurrent: playlist.entries.removeAll { $0.id == restoredEntry.id }
        }
        session.update(playlist: playlist, media: [item])
        await fulfillment(of: [cancelled], timeout: 1)
        if paused {
            XCTAssertEqual(endpoint.preparations, 1, "Editing must not undo a pause")
            XCTAssertEqual(endpoint.transitions, 0)
            session.setPaused(false)
        }
        await fulfillment(of: [displayed], timeout: 1)
        XCTAssertEqual(endpoint.preparations, 2)
        XCTAssertEqual(endpoint.transitions, 1)
        XCTAssertEqual(session.currentEntryID, expectedEntry)
    }
}

@MainActor
private final class StartupEndpoint: PlaybackEndpoint {
    var releaseFailure: Error? { nil }
    private let initialGate = AsyncTestGate()
    var onInitialPrepare: (() -> Void)?
    var onCancellation: (() -> Void)?
    private(set) var preparations = 0
    private(set) var transitions = 0

    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws {
        preparations += 1
        if preparations == 1 {
            onInitialPrepare?()
            do { try await initialGate.pause() }
            catch is CancellationError {
                onCancellation?()
                throw CancellationError()
            }
        }
        try Task.checkCancellation()
    }

    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult {
        transitions += 1
        return .displayed
    }

    func updateAudio(_ settings: [UUID: AudioSettings]) {}
    func discardPreparation() {}
    func setPaused(_ value: Bool) {}
    func prepareToResume(requestID: UUID) async throws { try Task.checkCancellation() }
    func cancelResumePreparation(requestID: UUID) async throws {}
}
