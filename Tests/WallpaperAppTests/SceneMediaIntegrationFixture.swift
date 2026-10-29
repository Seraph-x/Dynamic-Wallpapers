import Foundation
import WallpaperCore
import WallpaperMediaIntegration

actor SceneMediaProviderFixture: SystemMediaServicing, SystemMediaArtworkServicing {
    var reads: [(SystemMediaSource, Bool)] = []
    var commands: [SystemMediaCommand] = []
    var track = "owned-0"
    var readResult: SystemMediaReadResult?
    var readFailure: SystemMediaError?
    var holdRead = false
    var heldRead: CheckedContinuation<Void, Never>?
    var holdArtwork = false
    var heldArtwork: CheckedContinuation<Void, Never>?

    func setTrack(_ value: String) { track = value }
    func setReadResult(_ value: SystemMediaReadResult?) { readResult = value }
    func setReadFailure(_ value: SystemMediaError?) { readFailure = value }
    func holdNextRead() { holdRead = true }
    func readIsHeld() -> Bool { heldRead != nil }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    func holdNextArtwork() { holdArtwork = true }
    func artworkIsHeld() -> Bool { heldArtwork != nil }
    func releaseArtwork() { heldArtwork?.resume(); heldArtwork = nil }

    func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
        reads.append((source, requestAuthorization))
        if holdRead { holdRead = false; await withCheckedContinuation { heldRead = $0 } }
        if let readFailure { throw readFailure }
        if let readResult { return readResult }
        return .current(try SystemMediaSnapshot(source: source, trackID: track, state: .playing,
            title: track, artist: "Owned Artist", album: "Owned Album", albumArtist: nil, position: 1, duration: 20))
    }

    func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws { commands.append(command) }

    func readArtwork(for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtworkSource {
        if holdArtwork { holdArtwork = false; await withCheckedContinuation { heldArtwork = $0 } }
        let file = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MediaAutomationHarness/Fixtures/owned-artwork.png")
        return .embedded(try Data(contentsOf: file))
    }
}

@MainActor
final class SceneMediaSinkFixture {
    struct Frame: Decodable {
        let hasMedia: Bool
        let title: String
        let thumbnail: String?
    }
    var received: [(frame: Frame, revision: UInt64)] = []
    var holdNext = false
    var pending: CheckedContinuation<Void, Never>?
    var failure: Error?

    func send(_ bytes: Data, _ revision: UInt64) async throws {
        received.append((try JSONDecoder().decode(Frame.self, from: bytes), revision))
        if holdNext { holdNext = false; await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }

    func release() { pending?.resume(); pending = nil }
}
