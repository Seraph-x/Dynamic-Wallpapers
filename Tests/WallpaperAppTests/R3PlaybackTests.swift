import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class R3PlaybackTests: XCTestCase {
    private func session(_ endpoints: [ResumeEndpoint], seconds: Double = 10,
                         onCommit: @escaping (UUID) -> Void, onError: @escaping (Error) -> Void) -> PlaybackSession {
        let item = MediaItem(url: URL(fileURLWithPath: "/r3.html"), kind: .web, width: 32, height: 32,
            backend: .web, webProject: WebProjectReference(root: URL(fileURLWithPath: "/"), entry: "r3.html"))
        let entries = [PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: seconds)), PlaylistEntry(mediaID: item.id)]
        return PlaybackSession(playlist: Playlist(name: "R3", entries: entries, transition: 0), media: [item],
            endpoints: endpoints, fit: .fit, onCommit: onCommit, onStatus: { _ in }, onError: onError)
    }

    func testGroupWaitsForSlowScreenWithoutAdvancingClock() async throws {
        let first = ResumeEndpoint(), slow = ResumeEndpoint()
        let committed = expectation(description: "initial commit")
        var commits = 0
        let session = session([first, slow], seconds: 0.2, onCommit: { _ in
            commits += 1; if commits == 1 { committed.fulfill() }
        }, onError: { XCTFail($0.localizedDescription) })
        defer { session.stop() }
        session.start()
        await fulfillment(of: [committed], timeout: 1)
        session.setPaused(true)
        slow.holdResume = true
        let preparing = expectation(description: "slow resume started")
        slow.onResume = { preparing.fulfill() }
        session.setPaused(false)
        await fulfillment(of: [preparing], timeout: 1)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertTrue(first.paused && slow.paused)
        XCTAssertEqual(first.playCalls, 0)
        XCTAssertEqual(commits, 1, "Loading time must not consume the paused entry's remaining time")
        XCTAssertEqual(first.preparations, 1, "No automatic next item may preload during resume")
        let playing = expectation(description: "all screens resumed")
        slow.onPlay = { playing.fulfill() }
        slow.finishResume()
        await fulfillment(of: [playing], timeout: 1)
        XCTAssertEqual(first.playCalls, 1)
        XCTAssertFalse(first.playedBeforeReady || slow.playedBeforeReady)
    }

    func testFailedScreenCancelsReadyPeerAndWaitsForCleanup() async throws {
        let ready = ResumeEndpoint(), bad = ResumeEndpoint()
        let committed = expectation(description: "initial commit")
        let failed = expectation(description: "resume failed after cleanup")
        let session = session([ready, bad], onCommit: { _ in committed.fulfill() }, onError: { _ in failed.fulfill() })
        defer { session.stop() }
        session.start(); await fulfillment(of: [committed], timeout: 1)
        session.setPaused(true)
        bad.holdResume = true
        let pending = expectation(description: "failing resume pending")
        bad.onResume = { pending.fulfill() }
        session.setPaused(false)
        await fulfillment(of: [pending], timeout: 1)
        bad.finishResume(error: WallpaperError("R3 screen failed"))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(ready.cancelCalls, 1)
        XCTAssertEqual(bad.cancelCalls, 1)
        XCTAssertEqual(ready.ownedResumes + bad.ownedResumes, 0)
        XCTAssertTrue(ready.paused && bad.paused)
        XCTAssertEqual(ready.playCalls + bad.playCalls, 0)
    }

    func testResumeCleanupFailureRetainsSlotAndBlocksRetry() async throws {
        let good = ResumeEndpoint(), bad = ResumeEndpoint()
        let committed = expectation(description: "initial commit"), failed = expectation(description: "failure")
        let session = session([good, bad], onCommit: { _ in committed.fulfill() }, onError: { _ in failed.fulfill() })
        defer { session.stop() }
        session.start(); await fulfillment(of: [committed], timeout: 1)
        session.setPaused(true)
        good.closeError = WallpaperError("R3 release failed")
        bad.holdResume = true
        let goodReady = expectation(description: "peer ready before failure")
        let badPending = expectation(description: "failing peer started")
        good.onResume = { goodReady.fulfill() }
        bad.onResume = { badPending.fulfill() }
        session.setPaused(false)
        await fulfillment(of: [goodReady, badPending], timeout: 1)
        bad.finishResume(error: WallpaperError("R3 load failed"))
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(good.ownedResumes, 1)
        XCTAssertNotNil(good.releaseFailure)
        let count = good.resumeCalls
        session.setPaused(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(good.resumeCalls, count)
        XCTAssertEqual(good.playCalls, 0)
    }

    func testPauseCancelsInFlightGroupResumeAndLateReadyCannotPlay() async throws {
        let endpoint = ResumeEndpoint()
        let committed = expectation(description: "initial commit"), preparing = expectation(description: "resume pending")
        let session = session([endpoint], onCommit: { _ in committed.fulfill() }, onError: { XCTFail($0.localizedDescription) })
        defer { session.stop() }
        session.start(); await fulfillment(of: [committed], timeout: 1)
        session.setPaused(true)
        endpoint.holdResume = true; endpoint.onResume = { preparing.fulfill() }
        session.setPaused(false)
        await fulfillment(of: [preparing], timeout: 1)
        let cancelled = expectation(description: "cancelled resume closed")
        endpoint.onCancel = { cancelled.fulfill() }
        session.setPaused(true)
        await fulfillment(of: [cancelled], timeout: 1)
        endpoint.finishResume()
        XCTAssertEqual(endpoint.ownedResumes, 0)
        XCTAssertEqual(endpoint.playCalls, 0)
    }

    func testResumeDuringTransitionWaitsForFinalCurrentItem() async throws {
        let endpoint = ResumeEndpoint()
        let initial = expectation(description: "initial commit"), transition = expectation(description: "second transition")
        var committed: UUID?
        let session = session([endpoint], onCommit: { id in if committed == nil { initial.fulfill() }; committed = id },
            onError: { XCTFail($0.localizedDescription) })
        defer { session.stop() }
        session.start(); await fulfillment(of: [initial], timeout: 1)
        endpoint.holdTransition = true; endpoint.onTransition = { transition.fulfill() }
        session.next(); await fulfillment(of: [transition], timeout: 1)
        session.setPaused(true); session.setPaused(false)
        XCTAssertEqual(endpoint.resumeCalls, 0)
        let resumed = expectation(description: "final item resumed")
        endpoint.onPlay = { resumed.fulfill() }
        endpoint.finishTransition()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertEqual(endpoint.resumeEntries, [committed!])
        XCTAssertEqual(endpoint.resumeCalls, 1)
    }
}

@MainActor
private final class ResumeEndpoint: PlaybackEndpoint {
    var releaseFailure: Error?
    var paused = false
    var playedBeforeReady = false
    var preparations = 0, resumeCalls = 0, playCalls = 0, cancelCalls = 0, ownedResumes = 0
    var holdResume = false, holdTransition = false
    var resumeError: Error?, closeError: Error?
    var onResume: (() -> Void)?, onPlay: (() -> Void)?, onCancel: (() -> Void)?, onTransition: (() -> Void)?
    var resumeEntries: [UUID] = []
    private var pending: UUID?, current: UUID?, request: UUID?
    private var resumeReady = false
    private var resumeContinuation: CheckedContinuation<Void, Error>?
    private var transitionContinuation: CheckedContinuation<Void, Never>?
    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws {
        preparations += 1; pending = entry.id
    }
    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult {
        onTransition?()
        if holdTransition { await withCheckedContinuation { transitionContinuation = $0 } }
        current = pending; pending = nil
        return .displayed
    }
    func discardPreparation() { pending = nil }
    func updateAudio(_ settings: [UUID: AudioSettings]) {}
    func setPaused(_ value: Bool) {
        paused = value
        if !value { playedBeforeReady = playedBeforeReady || !resumeReady; playCalls += 1; onPlay?() }
    }
    func prepareToResume(requestID: UUID) async throws {
        request = requestID; resumeCalls += 1; ownedResumes += 1
        if let current { resumeEntries.append(current) }
        try await withTaskCancellationHandler {
            if holdResume {
                try await withCheckedThrowingContinuation { resumeContinuation = $0; onResume?() }
            } else { onResume?() }
            try Task.checkCancellation()
            if let resumeError { throw resumeError }
            resumeReady = true
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishResume(error: CancellationError()) }
        }
    }
    func cancelResumePreparation(requestID: UUID) async throws {
        guard request == requestID else { return }
        cancelCalls += 1; paused = true; resumeReady = false
        finishResume(error: CancellationError())
        if let closeError { releaseFailure = closeError; onCancel?(); throw closeError }
        ownedResumes -= 1; request = nil; onCancel?()
    }
    func finishResume(error: Error? = nil) {
        guard let continuation = resumeContinuation else { return }
        resumeContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func finishTransition() { transitionContinuation?.resume(); transitionContinuation = nil }
}
