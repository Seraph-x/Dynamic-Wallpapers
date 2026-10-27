import Foundation
import WallpaperCore

enum MediaAE {
    static func code(_ value: StaticString) -> OSType {
        let bytes = Array(value.withUTF8Buffer { Array($0) })
        precondition(bytes.count == 4)
        return bytes.reduce(0) { ($0 << 8) | OSType($1) }
    }

    static let playerState = code("pPlS"), position = code("pPos"), currentTrack = code("pTrk")
    static let name = code("pnam"), artist = code("pArt"), album = code("pAlb")
    static let albumArtist = code("pAlA"), duration = code("pDur")
    static func identity(for source: SystemMediaSource) -> OSType {
        source == .spotify ? code("ID  ") : code("pPIS")
    }
    static func eventClass(for source: SystemMediaSource) -> OSType {
        source == .spotify ? code("spfy") : code("hook")
    }
    static func eventID(for command: SystemMediaCommand) -> OSType {
        switch command {
        case .play: code("Play")
        case .pause: code("Paus")
        case .playPause: code("PlPs")
        case .skipNext: code("Next")
        case .skipPrevious: code("Prev")
        }
    }
}
