import Foundation
import WallpaperCore

struct SystemWallpaperContent: Equatable, Sendable {
    let item: MediaItem
    let fit: ContentFit
    let width: Int
    let height: Int
}

struct SystemWallpaperTarget: Equatable, Sendable {
    let displayID: String
    let revision: UUID
    let content: SystemWallpaperContent
    let sourceVersion: Result<String, WallpaperError>
}

struct SystemWallpaperKey: Equatable, Sendable {
    let digest: String
    let content: SystemWallpaperContent
    let sourceVersion: String
}
