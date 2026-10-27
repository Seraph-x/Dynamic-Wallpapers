import Foundation
import WallpaperCore

public enum SystemMediaPlaybackState: Sendable, Equatable {
    case stopped, playing, paused, fastForwarding, rewinding

    public var wallpaperPlaybackState: Int {
        switch self {
        case .stopped: 0
        case .paused: 2
        case .playing, .fastForwarding, .rewinding: 1
        }
    }
}

/// Actual provider metadata. Artwork and lyrics are not part of this foundation
/// contract; consumers must not substitute generated artwork or media content.
public struct SystemMediaSnapshot: Sendable, Equatable {
    public let source: SystemMediaSource
    public let trackID: String
    public let state: SystemMediaPlaybackState
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String?
    public let position: Double
    public let duration: Double

    public init(source: SystemMediaSource, trackID: String, state: SystemMediaPlaybackState,
                title: String, artist: String, album: String, albumArtist: String?,
                position: Double, duration: Double) throws {
        guard source != .disabled, !trackID.isEmpty,
              position.isFinite, position >= 0, duration.isFinite, duration >= 0 else {
            throw SystemMediaError.invalidResponse("Invalid source, identity or timeline")
        }
        self.source = source; self.trackID = trackID; self.state = state
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
        self.position = position; self.duration = duration
    }
}
