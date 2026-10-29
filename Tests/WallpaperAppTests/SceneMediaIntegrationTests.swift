import XCTest
import WallpaperCore
import WallpaperMediaIntegration
@testable import WallpaperApp

@MainActor
final class SceneMediaIntegrationTests: XCTestCase {
    func testDefaultOffPreparingPrivacyAndOneSharedProviderAcrossPlayingScenes() async throws {
        let service = SceneMediaProviderFixture()
        let media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media)
        let a = UUID(), b = UUID(), first = SceneMediaSinkFixture(), second = SceneMediaSinkFixture()
        owner.register(a); owner.register(b)
        owner.setPlaying(b, true) // An unprepared page is never actual playing demand.
        try await owner.prepare(a, command: first.send)
        owner.setPlaying(a, true); await media.settled(); try await owner.settled(a)
        XCTAssertFalse(try XCTUnwrap(first.received.last).frame.hasMedia)
        let disabled = await service.reads; XCTAssertTrue(disabled.isEmpty)
        media.configure(source: .music); await media.settled(); try await owner.settled(a)
        XCTAssertEqual(first.received.last?.frame.title, "owned-0")
        try await owner.prepare(b, command: second.send)
        XCTAssertFalse(try XCTUnwrap(second.received.last).frame.hasMedia)
        owner.setPlaying(b, true); try await owner.settled(b)
        XCTAssertTrue(try XCTUnwrap(second.received.last).frame.hasMedia)
        let shared = await service.reads
        XCTAssertEqual(shared.count, 1); XCTAssertFalse(shared[0].1)
        owner.setPlaying(a, false); try await owner.settled(a)
        XCTAssertFalse(try XCTUnwrap(first.received.last).frame.hasMedia)
        XCTAssertNotNil(media.snapshot)
        owner.setPlaying(b, false); try await owner.settled(b)
        XCTAssertNil(media.snapshot)
        XCTAssertFalse(try XCTUnwrap(second.received.last).frame.hasMedia)
        await owner.shutdown()
    }

    func testArtworkCompletionPublishesWithoutAnotherMetadataReadAndFailureIsIndependent() async throws {
        let service = SceneMediaProviderFixture(); await service.holdNextArtwork()
        let media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), id = UUID(), sink = SceneMediaSinkFixture()
        owner.register(id); try await owner.prepare(id, command: sink.send)
        media.configure(source: .music); owner.setPlaying(id, true)
        await media.settled(); try await owner.settled(id)
        try await waitUntil { await service.artworkIsHeld() }
        XCTAssertTrue(try XCTUnwrap(sink.received.last).frame.hasMedia)
        XCTAssertNil(sink.received.last?.frame.thumbnail)
        await service.releaseArtwork(); await media.artwork.settled(); try await owner.settled(id)
        let ready = try XCTUnwrap(sink.received.last)
        XCTAssertTrue(try XCTUnwrap(ready.frame.thumbnail).hasPrefix("data:image/png;base64,"))
        let reads = await service.reads; XCTAssertEqual(reads.count, 1)
        owner.artworkFailed(id, revision: ready.revision, message: "Actual renderer decoder rejected PNG")
        XCTAssertNotNil(owner.artworkFailures[id]); XCTAssertTrue(owner.failures.isEmpty)
        XCTAssertEqual(media.status, .available); XCTAssertNotNil(media.snapshot)
        try await owner.perform(.pause, id: id, revision: ready.revision)
        XCTAssertNotNil(owner.artworkFailures[id], "Metadata refresh must not hide the renderer error")
        await owner.retryArtwork(); try await owner.settled(id)
        let retried = try XCTUnwrap(sink.received.last)
        XCTAssertGreaterThan(retried.revision, ready.revision); XCTAssertNotNil(retried.frame.thumbnail)
        owner.artworkFailed(id, revision: ready.revision, message: "Late retired error")
        XCTAssertNil(owner.artworkFailures[id])
        await owner.shutdown()
    }

    func testSourceSwitchAndDisableClearAndRejectOldControlTokens() async throws {
        let service = SceneMediaProviderFixture(), media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), id = UUID(), sink = SceneMediaSinkFixture()
        owner.register(id); try await owner.prepare(id, command: sink.send)
        media.configure(source: .music); owner.setPlaying(id, true); await media.settled(); try await owner.settled(id)
        let old = try XCTUnwrap(sink.received.last).revision
        await service.holdNextRead(); media.configure(source: .spotify)
        try await owner.settled(id)
        XCTAssertFalse(try XCTUnwrap(sink.received.last).frame.hasMedia)
        try await waitUntil { await service.readIsHeld() }
        await expectCancellation { try await owner.perform(.skipNext, id: id, revision: old) }
        await service.releaseRead(); await media.settled(); try await owner.settled(id)
        XCTAssertTrue(try XCTUnwrap(sink.received.last).frame.hasMedia)
        let fresh = try XCTUnwrap(sink.received.last).revision
        media.configure(source: .disabled); try await owner.settled(id)
        XCTAssertFalse(try XCTUnwrap(sink.received.last).frame.hasMedia)
        await expectCancellation { try await owner.perform(.play, id: id, revision: fresh) }
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        await owner.shutdown()
    }

    func testQueuedControlRechecksPausedInstanceEvenWhenAnotherSceneKeepsProviderActive() async throws {
        let service = SceneMediaProviderFixture(), media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), a = UUID(), b = UUID()
        let first = SceneMediaSinkFixture(), second = SceneMediaSinkFixture()
        owner.register(a); owner.register(b)
        try await owner.prepare(a, command: first.send); try await owner.prepare(b, command: second.send)
        media.configure(source: .music); owner.setPlaying(a, true); owner.setPlaying(b, true)
        await media.settled(); try await owner.settled(a)
        let revision = try XCTUnwrap(first.received.last).revision
        await service.holdNextRead()
        let refresh = Task { await media.refresh() }
        try await waitUntil { await service.readIsHeld() }
        let control = Task { try await owner.perform(.skipNext, id: a, revision: revision) }
        await Task.yield()
        owner.setPlaying(a, false)
        await service.releaseRead(); await refresh.value
        await expectCancellation { try await control.value }
        try await owner.settled(a); try await owner.settled(b)
        XCTAssertFalse(try XCTUnwrap(first.received.last).frame.hasMedia)
        XCTAssertTrue(try XCTUnwrap(second.received.last).frame.hasMedia)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        await owner.shutdown()
    }

    func testHeldPublicationFinishesBeforeClearAndCannotRestoreTheOldItem() async throws {
        let service = SceneMediaProviderFixture(), media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), id = UUID(), sink = SceneMediaSinkFixture()
        owner.register(id); try await owner.prepare(id, command: sink.send)
        sink.holdNext = true
        media.configure(source: .music); owner.setPlaying(id, true)
        await media.settled()
        try await waitUntil { sink.pending != nil }
        owner.setPlaying(id, false)
        var cleared = false
        let clear = Task { try await owner.settled(id); cleared = true }
        await Task.yield(); XCTAssertFalse(cleared)
        sink.release(); try await clear.value
        XCTAssertFalse(try XCTUnwrap(sink.received.last).frame.hasMedia)
        XCTAssertNil(sink.received.last?.frame.thumbnail)
        await owner.shutdown()
    }

    func testDeliveryFailureIsVisibleAndCloseDrainsPendingPublication() async throws {
        let service = SceneMediaProviderFixture(), media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), id = UUID(), sink = SceneMediaSinkFixture()
        owner.register(id); try await owner.prepare(id, command: sink.send)
        sink.failure = SystemMediaError.invalidResponse("Native command delivery failed")
        media.configure(source: .music); owner.setPlaying(id, true); await media.settled()
        do { try await owner.settled(id); XCTFail("Expected actual sink error") }
        catch { XCTAssertEqual(error as? SystemMediaError, .invalidResponse("Native command delivery failed")) }
        XCTAssertNotNil(owner.failures[id]); XCTAssertEqual(media.status, .available)
        sink.failure = nil; sink.holdNext = true
        await service.setTrack("owned-1"); await media.refresh()
        try await waitUntil { sink.pending != nil }
        owner.beginClose(id)
        var retired = false
        let close = Task { await owner.retire(id); retired = true }
        await Task.yield(); XCTAssertFalse(retired)
        sink.release(); await close.value
        XCTAssertEqual(owner.count, 0); XCTAssertNil(owner.failures[id])
        owner.setPlaying(id, true); XCTAssertNil(media.snapshot)
        await owner.shutdown()
    }

    func testShutdownDrainsProviderAndOldCallbacksCannotRestartReads() async throws {
        let service = SceneMediaProviderFixture(), media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), old = UUID(), sink = SceneMediaSinkFixture()
        owner.register(old); try await owner.prepare(old, command: sink.send)
        await service.holdNextRead(); media.configure(source: .music); owner.setPlaying(old, true)
        try await waitUntil { await service.readIsHeld() }
        var stopped = false
        let stop = Task { await owner.shutdown(); stopped = true }
        try await waitUntil { media.status == .disabled }
        XCTAssertFalse(stopped)
        await service.releaseRead(); await stop.value
        owner.setPlaying(old, true); await media.settled()
        XCTAssertNil(media.snapshot)
        XCTAssertEqual(owner.count, 0)
        await owner.shutdown()
    }

    func testRejectedQuitLeavesActualMediaOwnerRunning() async throws {
        let service = SceneMediaProviderFixture(), media = SystemMediaController(service: service, pollInterval: 3600)
        let owner = SceneMediaSessionOwner(controller: media), id = UUID(), sink = SceneMediaSinkFixture()
        owner.register(id); try await owner.prepare(id, command: sink.send)
        media.configure(source: .music); owner.setPlaying(id, true); await media.settled(); try await owner.settled(id)
        let revision = try XCTUnwrap(sink.received.last).revision
        let termination = ApplicationTermination(shutdown: { await owner.shutdown() },
            reply: { _ in XCTFail("Rejected quit has no deferred reply") }, report: { XCTFail("\($0)") },
            needsConfirmation: { true }, confirmCancellation: { false })
        XCTAssertEqual(termination.request(), .terminateCancel)
        try await owner.perform(.pause, id: id, revision: revision)
        XCTAssertEqual(media.status, .available)
        let commands = await service.commands; XCTAssertEqual(commands, [.pause])
        await owner.shutdown()
    }

    private func expectCancellation(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected retired media action to be cancelled") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected failure: \(error)") }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Owned operation did not reach its gate"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
