import CryptoKit
import Foundation
import WallpaperCore

public struct ScreenSaverSourceRevision: Codable, Equatable, Hashable, Sendable {
    public let value: String

    public init(projection: ScreenSaverProjection, settings: ScreenSaverSettings) throws {
        try settings.validate()
        guard settings.source == projection.source else { throw ScreenSaverFailure(code: .invalidProjection) }
        let input = RevisionInput(projection: projection, settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        value = SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case value }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decode(String.self, forKey: .value)
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ScreenSaverFailure(code: .integrityMismatch("sourceRevision"))
        }
    }
}

private struct RevisionMedia: Encodable {
    let id: UUID
    let url: URL
    let kind: MediaKind
    let width: Int
    let height: Int
    let duration: Double?
    let backend: MediaBackend

    init(_ item: MediaItem) {
        id = item.id; url = item.url; kind = item.kind; width = item.width; height = item.height
        duration = item.duration; backend = item.backend
    }
}

private struct RevisionInput: Encodable {
    let schemaVersion = 1
    let source: ScreenSaverSource
    let name: String
    let entries: [PlaylistEntry]
    let media: [RevisionMedia]
    let mode: PlaybackMode
    let transition: Double
    let exclusions: [ScreenSaverExclusionSignature]
    let isMuted: Bool
    let fit: ContentFit

    init(projection: ScreenSaverProjection, settings: ScreenSaverSettings) {
        source = projection.source; name = projection.name
        entries = projection.entries; mode = projection.mode; transition = projection.transition
        media = projection.media.sorted { $0.id.uuidString < $1.id.uuidString }.map(RevisionMedia.init)
        exclusions = projection.exclusions.map(\.signature).sorted { $0.entryID.uuidString < $1.entryID.uuidString }
        isMuted = settings.isMuted; fit = settings.fit
        // Favorites, import origin, desktop progress and the receipt itself do not change published playback.
        // Actual source/copy byte hashes are deliberately owned by the publication stage.
    }
}
