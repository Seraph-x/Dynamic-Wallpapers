import Foundation
import WallpaperCore

public struct ScreenSaverMediaFile: Codable, Equatable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let kind: MediaKind
    public let backend: MediaBackend
    public let width: Int
    public let height: Int
    public let duration: Double?
    public let byteCount: Int64
    public let sha256: String

    public init(media: MediaItem, relativePath: String, byteCount: Int64, sha256: String) throws {
        id = media.id; kind = media.kind; backend = media.backend
        width = media.width; height = media.height; duration = media.duration
        self.relativePath = relativePath; self.byteCount = byteCount; self.sha256 = sha256
        try validate()
    }

    public func validate() throws {
        try ScreenSaverPaths.validateMediaPath(relativePath)
        guard backend == .native, kind != .web, width > 0, height > 0, byteCount > 0,
              duration.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw ScreenSaverFailure(code: .invalidSourceMetadata(relativePath))
        }
        if kind == .video || kind == .animatedImage {
            guard let duration else { throw ScreenSaverFailure(code: .missingDuration(relativePath)) }
            try EntryTiming.validateClockDuration(duration)
        }
        let bytes = sha256.utf8
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ScreenSaverFailure(code: .integrityMismatch(relativePath))
        }
    }

    private enum CodingKeys: String, CodingKey { case id, relativePath, kind, backend, width, height, duration, byteCount, sha256 }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        kind = try values.decode(MediaKind.self, forKey: .kind)
        backend = try values.decode(MediaBackend.self, forKey: .backend)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        byteCount = try values.decode(Int64.self, forKey: .byteCount)
        sha256 = try values.decode(String.self, forKey: .sha256)
        try validate()
    }
}
