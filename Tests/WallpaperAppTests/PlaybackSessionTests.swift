import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PlaybackSessionTests: XCTestCase {
    func testAudioEditDoesNotCancelPendingSwitch() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let entries = [PlaylistEntry(mediaID: item.id), PlaylistEntry(mediaID: item.id)]
        var list = Playlist(name: "test", entries: entries)
        let first = expectation(description: "first committed")
        let second = expectation(description: "second committed after audio edit")
        let preparing = expectation(description: "second preparing")
        let endpoint = TestEndpoint()
        let session = PlaybackSession(playlist: list, media: [item], endpoints: [endpoint], fit: .fill,
            autoAdvance: false, onCommit: { id in
                if id == entries[0].id { first.fulfill() } else { second.fulfill() }
            }, onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        defer { session.stop() }
        session.start()
        await fulfillment(of: [first], timeout: 1)
        endpoint.delay = .milliseconds(100)
        endpoint.onPrepare = { preparing.fulfill() }
        session.next()
        await fulfillment(of: [preparing], timeout: 1)
        list.entries[1].audio.volume = 0.4
        session.update(playlist: list, media: [item])
        await fulfillment(of: [second], timeout: 1)
        XCTAssertFalse(endpoint.preparationCancelled)
    }

    func testFailedScreenCancelsSlowPreparationPromptly() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let slow = TestEndpoint(), bad = TestEndpoint()
        slow.delay = .seconds(10)
        bad.failure = WallpaperError("screen failed")
        let failed = expectation(description: "failure reported without waiting for slow screen")
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: [PlaylistEntry(mediaID: item.id)]),
            media: [item], endpoints: [slow, bad], fit: .fill, autoAdvance: false,
            onCommit: { _ in XCTFail("must not commit") }, onStatus: { _ in },
            onError: { error in
                XCTAssertEqual(error.localizedDescription, "screen failed")
                failed.fulfill()
            })
        session.start()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(slow.preparationCancelled)
        XCTAssertGreaterThanOrEqual(slow.discards, 2)
        XCTAssertNil(session.currentEntryID)
        session.stop()
    }

    func testClearingPlaylistDuringTransitionKeepsVisibleFrameWithoutError() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        var list = Playlist(name: "test", entries: [PlaylistEntry(mediaID: item.id)])
        let endpoint = TestEndpoint()
        let finished = expectation(description: "transition finished with empty playlist status")
        let resumed = expectation(description: "new entry plays after empty playlist")
        var restoredEntry: UUID?
        let session = PlaybackSession(playlist: list, media: [item], endpoints: [endpoint], fit: .fill,
            onCommit: { id in
                XCTAssertEqual(id, restoredEntry, "removed entry must not be persisted")
                resumed.fulfill()
            },
            onStatus: { if $0 == "播放列表为空，保留当前画面" { finished.fulfill() } },
            onError: { XCTFail($0.localizedDescription) })
        endpoint.onTransitionStart = { [weak session] _ in
            session?.next()
            list.entries = []
            session?.update(playlist: list, media: [item])
        }
        session.start()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(endpoint.transitions, 1)
        XCTAssertFalse(endpoint.paused)
        endpoint.onTransitionStart = nil
        list.entries = [PlaylistEntry(mediaID: item.id)]
        restoredEntry = list.entries[0].id
        session.update(playlist: list, media: [item])
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(endpoint.transitions, 2)
        session.stop()
    }

    func testPauseBetweenScreenStartsUsesCurrentPauseState() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let endpoints = [TestEndpoint(), TestEndpoint()]
        let done = expectation(description: "committed")
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: [PlaylistEntry(mediaID: item.id)]),
            media: [item], endpoints: endpoints, fit: .fill, autoAdvance: false,
            onCommit: { _ in done.fulfill() }, onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        var pauseArguments: [Bool] = []
        for endpoint in endpoints {
            endpoint.onTransitionStart = { [weak session] paused in
                pauseArguments.append(paused)
                session?.setPaused(true)
            }
        }
        session.start()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(pauseArguments, [false, true])
        session.stop()
    }
    func testEditingCurrentTimingReschedulesImmediately() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let entries = [PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: 3600)), PlaylistEntry(mediaID: item.id)]
        var list = Playlist(name: "test", entries: entries, transition: 0)
        let started = expectation(description: "first"), advanced = expectation(description: "edited duration")
        let session = PlaybackSession(playlist: list, media: [item], endpoints: [TestEndpoint()], fit: .fill,
            onCommit: { id in if id == entries[0].id { started.fulfill() } else { advanced.fulfill() } },
            onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        session.start()
        await fulfillment(of: [started], timeout: 1)
        list.entries[0].timing.seconds = 0.05
        session.update(playlist: list, media: [item])
        await fulfillment(of: [advanced], timeout: 1)
        session.stop()
    }

    func testTransitionTimeCountsTowardActualPlayback() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let entries = [PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: 1)), PlaylistEntry(mediaID: item.id)]
        let endpoint = TestEndpoint()
        endpoint.transitionDelay = .milliseconds(800)
        let secondPreparation = expectation(description: "next prepared")
        var preparations = 0
        endpoint.onPrepare = { preparations += 1; if preparations == 2 { secondPreparation.fulfill() } }
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: entries), media: [item], endpoints: [endpoint], fit: .fill,
            onCommit: { _ in }, onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        session.start()
        await fulfillment(of: [secondPreparation], timeout: 1.3)
        session.stop()
    }
    func testHandingOffSessionKeepsOldSurfacePlaying() {
        let endpoint = TestEndpoint()
        let session = PlaybackSession(playlist: Playlist(name: "test"), media: [], endpoints: [endpoint],
            fit: .fill, autoAdvance: false, onCommit: { _ in }, onStatus: { _ in }, onError: { _ in })
        session.stop(pauseDisplay: false)
        XCTAssertFalse(endpoint.paused)
    }
    func testFailedScreenAbortsWholeGroupWithoutAdvancing() async throws {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let list = Playlist(name: "test", entries: [PlaylistEntry(mediaID: item.id)])
        let good = TestEndpoint(), bad = TestEndpoint()
        bad.failure = WallpaperError("screen failed")
        let failed = expectation(description: "failure surfaced")
        let session = PlaybackSession(playlist: list, media: [item], endpoints: [good, bad], fit: .fill,
            autoAdvance: false, onCommit: { _ in XCTFail("must not commit") }, onStatus: { _ in },
            onError: { _ in failed.fulfill() })
        session.start()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(good.transitions, 0)
        XCTAssertEqual(bad.transitions, 0)
        XCTAssertNil(session.currentEntryID)
        session.stop()
    }

    func testSuccessCommitsOnlyAfterEveryScreenTransition() async throws {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let entry = PlaylistEntry(mediaID: item.id)
        let first = TestEndpoint(), second = TestEndpoint()
        let committed = expectation(description: "committed")
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: [entry]), media: [item],
            endpoints: [first, second], fit: .fill, autoAdvance: false,
            onCommit: { id in
                XCTAssertEqual(id, entry.id)
                XCTAssertEqual(first.transitions, 1)
                XCTAssertEqual(second.transitions, 1)
                committed.fulfill()
            }, onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        session.start()
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(session.currentEntryID, entry.id)
        session.stop()
    }

    func testUndisplayedTransitionWaitsForOtherScreenAndDoesNotCommit() async {
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        let first = TestEndpoint(), second = TestEndpoint()
        first.transitionResult = .notDisplayed(WallpaperError("no prepared frame"))
        second.transitionDelay = .milliseconds(50)
        let failed = expectation(description: "transition error reported after every screen")
        var status = ""
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: [PlaylistEntry(mediaID: item.id)]),
            media: [item], endpoints: [first, second], fit: .fit, autoAdvance: false,
            onCommit: { _ in XCTFail("A partially displayed group must not commit") },
            onStatus: { status = $0 }, onError: { error in
                XCTAssertEqual(error.localizedDescription, "no prepared frame")
                XCTAssertEqual(first.transitions, 1)
                XCTAssertEqual(second.transitions, 1, "Other screen must finish despite the first failure")
                failed.fulfill()
            })
        defer { session.stop() }
        session.start()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertNil(session.currentEntryID)
        XCTAssertFalse(session.isTransitioning)
        XCTAssertTrue(first.paused)
        XCTAssertTrue(second.paused)
        XCTAssertTrue(status.contains("切换未完成"))
    }

    func testCancelledSlowRequestNeverCommits() async throws {
        let items = (0..<2).map { MediaItem(url: URL(fileURLWithPath: "/\($0).png"), kind: .image, width: 32, height: 32) }
        let entries = items.map { PlaylistEntry(mediaID: $0.id) }
        let endpoint = TestEndpoint()
        endpoint.delay = .milliseconds(30)
        let done = expectation(description: "latest")
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: entries), media: items,
            endpoints: [endpoint], fit: .fill, autoAdvance: false,
            onCommit: { XCTAssertEqual($0, entries[1].id); done.fulfill() },
            onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        session.start()
        await Task.yield()
        session.next()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(endpoint.transitions, 1)
        session.stop()
    }
}

@MainActor
private final class TestEndpoint: PlaybackEndpoint {
    var releaseFailure: Error?
    var transitionResult: PlaybackTransitionResult = .displayed
    var preparationCancelled = false
    var discards = 0
    var failure: Error?
    var transitions = 0
    var delay: Duration = .zero
    var paused = false
    var transitionDelay: Duration = .zero
    var onPrepare: (() -> Void)?
    var onTransitionStart: ((Bool) -> Void)?
    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws {
        onPrepare?()
        do { try await Task.sleep(for: delay) }
        catch is CancellationError { preparationCancelled = true; throw CancellationError() }
        if let failure { throw failure }
    }
    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult {
        onTransitionStart?(paused)
        do { try await Task.sleep(for: transitionDelay) } catch { }
        transitions += 1
        return transitionResult
    }
    func discardPreparation() { discards += 1 }
    func updateAudio(_ settings: [UUID: AudioSettings]) {}
    func setPaused(_ paused: Bool) { self.paused = paused }
    func prepareToResume(requestID: UUID) async throws { try Task.checkCancellation() }
    func cancelResumePreparation(requestID: UUID) async throws { paused = true }
}
