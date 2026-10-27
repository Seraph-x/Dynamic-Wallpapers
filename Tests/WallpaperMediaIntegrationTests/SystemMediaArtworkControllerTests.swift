import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

@MainActor
final class SystemMediaArtworkControllerTests: XCTestCase {
    actor Service: SystemMediaServicing, SystemMediaArtworkServicing {
        let bytes: Data
        var track = "owned-0"
        var reads: [SystemMediaArtworkIdentity] = []
        var commands: [SystemMediaCommand] = []
        var source: SystemMediaArtworkSource?
        var failure: SystemMediaError?
        var hold = false
        var pending: [SystemMediaArtworkIdentity: CheckedContinuation<SystemMediaArtworkSource, Never>] = [:]
        init() throws { bytes = try Data(contentsOf: ArtworkImageDecoderTests.fixtureURL) }
        func setTrack(_ value: String) { track = value }
        func setFailure(_ value: SystemMediaError?) { failure = value }
        func setUnavailable(_ value: Bool) { source = value ? .unavailable : nil }
        func holdNext() { hold = true }
        func isPending(_ identity: SystemMediaArtworkIdentity) -> Bool { pending[identity] != nil }
        func release(_ identity: SystemMediaArtworkIdentity) { pending.removeValue(forKey: identity)?.resume(returning: .embedded(bytes)) }
        func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
            .current(try SystemMediaSnapshot(source: source, trackID: track, state: .playing,
                title: "Actual metadata", artist: "", album: "", albumArtist: nil, position: 0, duration: 1))
        }
        func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws { commands.append(command) }
        func readArtwork(for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtworkSource {
            reads.append(identity)
            if hold { hold = false; return await withCheckedContinuation { pending[identity] = $0 } }
            if let failure { throw failure }
            return source ?? .embedded(bytes)
        }
    }
    let first = SystemMediaArtworkIdentity(source: .music, trackID: "owned-0")

    func testActualReadyImageIsCachedOnlyForCurrentIdentity() async throws {
        let service = try Service()
        let media = SystemMediaController(service: service, pollInterval: 3600)
        media.configure(source: .music); media.setPlaying(UUID(), true); await media.settled(); await media.artwork.settled()
        guard case .ready(let actual) = media.artwork.state else { return XCTFail("Expected actual ready artwork") }
        XCTAssertEqual(actual.identity, first)
        XCTAssertEqual(try ArtworkImageDecoderTests.pixels(actual.pngData), [255, 0, 0, 255, 0, 0, 255, 255])
        await media.refresh(); await media.artwork.settled()
        let once = await service.reads; XCTAssertEqual(once, [first])
        await service.setTrack("owned-1"); await media.refresh(); await media.artwork.settled()
        let twice = await service.reads; XCTAssertEqual(twice.count, 2)
        media.configure(source: .disabled)
        guard case .unavailable = media.artwork.state else { return XCTFail("Disable must immediately clear artwork") }
        await media.shutdown()
    }

    func testArtworkFailurePreservesMetadataAndTransportUntilExplicitArtworkRetry() async throws {
        let service = try Service()
        await service.setFailure(.invalidResponse("Bad actual source"))
        let media = SystemMediaController(service: service, pollInterval: 3600)
        media.configure(source: .music); media.setPlaying(UUID(), true); await media.settled(); await media.artwork.settled()
        guard case .failed(let identity, let failure) = media.artwork.state else { return XCTFail("Expected artwork failure") }
        XCTAssertEqual(identity, first); XCTAssertEqual(failure as? SystemMediaError, .invalidResponse("Bad actual source"))
        XCTAssertEqual(media.status, .available); XCTAssertNotNil(media.snapshot); XCTAssertNil(media.failure)
        try await media.perform(.pause); await media.artwork.settled()
        let commands = await service.commands; XCTAssertEqual(commands, [.pause])
        let reads = await service.reads; XCTAssertEqual(reads.count, 1)
        await service.setFailure(nil); await media.refresh(); await media.artwork.settled()
        guard case .failed = media.artwork.state else { return XCTFail("Refresh must not hide prior failure") }
        await media.artwork.retry()
        guard case .ready = media.artwork.state else { return XCTFail("Explicit artwork retry should load actual image") }
        await media.shutdown()
    }

    func testUnavailableCanBeReprobedWithoutInvalidatingMetadata() async throws {
        let service = try Service(); await service.setUnavailable(true)
        let media = SystemMediaController(service: service, pollInterval: 3600)
        media.configure(source: .music); media.setPlaying(UUID(), true); await media.settled(); await media.artwork.settled()
        guard case .unavailable = media.artwork.state else { return XCTFail("Expected unavailable artwork") }
        XCTAssertNotNil(media.snapshot)
        await service.setUnavailable(false); await media.refresh(); await media.artwork.settled()
        guard case .ready = media.artwork.state else { return XCTFail("Later provider refresh must re-probe actual artwork") }
        await media.shutdown()
    }

    func testOldTrackAndOldSourceCompletionsCannotPublishAndDemandLossClearsImmediately() async throws {
        let service = try Service(); await service.holdNext()
        let media = SystemMediaController(service: service, pollInterval: 3600), demand = UUID()
        media.configure(source: .music); media.setPlaying(demand, true); await media.settled()
        try await waitUntil { await service.isPending(self.first) }
        guard case .pending(let pending) = media.artwork.state, pending == first else { return XCTFail("Expected pending actual source") }
        await service.setTrack("owned-1"); await media.refresh()
        media.configure(source: .spotify); await media.settled()
        await service.release(first); await media.artwork.settled()
        guard case .ready(let actual) = media.artwork.state else { return XCTFail("Expected current source artwork") }
        XCTAssertEqual(actual.identity, SystemMediaArtworkIdentity(source: .spotify, trackID: "owned-1"))
        media.setPlaying(demand, false)
        guard case .unavailable = media.artwork.state else { return XCTFail("Lost demand must immediately clear old image") }
        await media.shutdown()
    }

    func testShutdownDrainsActualPendingArtworkAndRejectedQuitAcceptsFreshDemand() async throws {
        let service = try Service(); await service.holdNext()
        let media = SystemMediaController(service: service, pollInterval: 3600)
        media.configure(source: .music); media.setPlaying(UUID(), true); await media.settled()
        try await waitUntil { await service.isPending(self.first) }
        var finished = false
        let stop = Task { await media.shutdown(); finished = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished)
        guard case .unavailable = media.artwork.state else { return XCTFail("Shutdown must clear immediately") }
        media.cancelShutdown(); media.setPlaying(UUID(), true)
        await service.release(first); await stop.value
        XCTAssertTrue(finished)
        media.cancelShutdown(); media.setPlaying(UUID(), true); await media.settled(); await media.artwork.settled()
        guard case .ready = media.artwork.state else { return XCTFail("Fresh demand after rejected quit must load artwork") }
        await media.shutdown()
    }

    func testArtworkOwnerCannotResumeBeforeItsOwnShutdownDrainFinishes() async throws {
        let service = try Service(); await service.holdNext()
        let artwork = SystemMediaArtworkController(service: service)
        let snapshot = try SystemMediaSnapshot(source: .music, trackID: "owned-0", state: .playing,
            title: "Actual metadata", artist: "", album: "", albumArtist: nil, position: 0, duration: 1)
        artwork.update(snapshot)
        try await waitUntil { await service.isPending(self.first) }
        let stop = Task { await artwork.shutdown() }
        try await Task.sleep(for: .milliseconds(10))
        artwork.cancelShutdown(); artwork.update(snapshot)
        try await Task.sleep(for: .milliseconds(20))
        guard case .unavailable = artwork.state else {
            await service.release(first); await stop.value
            return XCTFail("Pending artwork shutdown must reject premature resume and new work")
        }
        await service.release(first); await stop.value
        let before = await service.reads; XCTAssertEqual(before, [first])
        artwork.cancelShutdown(); artwork.update(snapshot); await artwork.settled()
        guard case .ready = artwork.state else { return XCTFail("Completed drain should allow a fresh artwork owner request") }
        await artwork.shutdown()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for owned artwork source"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
