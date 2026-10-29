import Foundation

/// Data-only projection of actual provider state. Missing data stays empty;
/// artwork may arrive independently, but must belong to this exact item.
public struct SystemMediaSceneSnapshot: Sendable, Encodable, Equatable {
    public let hasMedia: Bool
    public let state: Int
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String
    public let position: Double
    public let duration: Double
    public let thumbnail: String?

    public init(snapshot: SystemMediaSnapshot?, artwork: SystemMediaArtworkState) {
        hasMedia = snapshot != nil
        state = snapshot?.state.wallpaperPlaybackState ?? 0
        title = snapshot?.title ?? ""
        artist = snapshot?.artist ?? ""
        album = snapshot?.album ?? ""
        albumArtist = snapshot?.albumArtist ?? ""
        position = snapshot?.position ?? 0
        duration = snapshot?.duration ?? 0
        if let snapshot, case .ready(let image) = artwork,
           image.identity == SystemMediaArtworkIdentity(snapshot) {
            thumbnail = "data:image/png;base64," + image.pngData.base64EncodedString()
        } else {
            thumbnail = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case hasMedia, state, title, artist, album, albumArtist, position, duration, thumbnail
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasMedia, forKey: .hasMedia)
        try container.encode(state, forKey: .state)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encode(position, forKey: .position)
        try container.encode(duration, forKey: .duration)
        // An explicit null clears old artwork in every consumer.
        try container.encode(thumbnail, forKey: .thumbnail)
    }
}
