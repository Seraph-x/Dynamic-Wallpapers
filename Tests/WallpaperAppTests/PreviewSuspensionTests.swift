import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PreviewSuspensionTests: XCTestCase {
    func testEndingPreviewDoesNotResumeAnOriginallyPausedSession() async throws {
        let fixture = Fixture()
        defer { fixture.session.stop() }
        fixture.session.start()
        try await wait { fixture.commits.count == 1 }
        fixture.session.setPaused(true)
        fixture.session.setPreviewSuspended(true)
        fixture.session.setPreviewSuspended(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(fixture.endpoint.paused)
        XCTAssertEqual(fixture.endpoint.preparations, 1)
    }

    func testUserResumeCannotPlayBehindAnActivePreview() async throws {
        let fixture = Fixture()
        defer { fixture.session.stop() }
        fixture.session.start()
        try await wait { fixture.commits.count == 1 }
        fixture.session.setPaused(true)
        fixture.session.setPreviewSuspended(true)
        fixture.session.setPaused(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(fixture.endpoint.paused)
        fixture.session.setPreviewSuspended(false)
        try await wait { !fixture.endpoint.paused }
        XCTAssertEqual(fixture.endpoint.preparations, 1, "Resume must retain the original player")
    }

    func testPauseRequestedDuringPreviewSurvivesItsEnd() async throws {
        let fixture = Fixture()
        defer { fixture.session.stop() }
        fixture.session.start()
        try await wait { fixture.commits.count == 1 }
        fixture.session.setPreviewSuspended(true)
        fixture.session.setPaused(true)
        fixture.session.setPreviewSuspended(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(fixture.endpoint.paused)
    }

    func testPreviewSuspendsPlaylistClockAndResumesTheSameEntry() async throws {
        let fixture = Fixture(duration: 0.35)
        defer { fixture.session.stop() }
        fixture.session.start()
        try await wait { fixture.commits.count == 1 }
        let entry = fixture.session.currentEntryID
        fixture.session.setPreviewSuspended(true)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(fixture.commits, [try XCTUnwrap(entry)])
        fixture.session.setPreviewSuspended(false)
        try await wait { !fixture.endpoint.paused }
        XCTAssertEqual(fixture.session.currentEntryID, entry)
        try await wait { fixture.commits.count == 2 }
        XCTAssertNotEqual(fixture.session.currentEntryID, entry)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Preview suspension timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private final class Fixture {
        let endpoint = Endpoint()
        private(set) var session: PlaybackSession!
        var commits: [UUID] = []

        init(duration: Double = 3600) {
            let item = MediaItem(url: URL(fileURLWithPath: "/suspend.png"), kind: .image, width: 32, height: 32)
            let entries = [PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: duration)),
                           PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: 3600))]
            session = PlaybackSession(playlist: Playlist(name: "suspend", entries: entries, transition: 0),
                media: [item], endpoints: [endpoint], fit: .fit,
                onCommit: { [weak self] in self?.commits.append($0) }, onStatus: { _ in },
                onError: { XCTFail($0.localizedDescription) })
        }
    }

    @MainActor private final class Endpoint: PlaybackEndpoint {
        var releaseFailure: Error? { nil }
        var paused = false
        var preparations = 0
        func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws { preparations += 1 }
        func updateAudio(_ settings: [UUID: AudioSettings]) {}
        func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult {
            self.paused = paused
            return .displayed
        }
        func discardPreparation() {}
        func setPaused(_ paused: Bool) { self.paused = paused }
        func prepareToResume(requestID: UUID) async throws { try Task.checkCancellation() }
        func cancelResumePreparation(requestID: UUID) async throws { paused = true }
    }
}
