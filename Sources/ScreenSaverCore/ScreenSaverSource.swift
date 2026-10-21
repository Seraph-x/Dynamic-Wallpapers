import Foundation

public enum ScreenSaverSource: Equatable, Hashable, Sendable, Codable {
    case media(UUID)
    case playlist(UUID)

    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case media, playlist }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .media: self = .media(id)
        case .playlist: self = .playlist(id)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .media(let id):
            try values.encode(Kind.media, forKey: .kind)
            try values.encode(id, forKey: .id)
        case .playlist(let id):
            try values.encode(Kind.playlist, forKey: .kind)
            try values.encode(id, forKey: .id)
        }
    }
}

public enum ScreenSaverProjectionError: LocalizedError, Equatable, Sendable {
    case sourceMissing(ScreenSaverSource)
    case emptySource
    case missingMedia(UUID)
    case noSupportedMedia
    case confirmationRequired

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: return "屏保来源已不存在；上次发布的副本未改变。"
        case .emptySource: return "屏保来源列表为空，不能发布。"
        case .missingMedia(let id): return "屏保来源引用了不存在的素材：\(id)。"
        case .noSupportedMedia: return "屏保来源没有可用的原生视频、图片或动图，不能发布。"
        case .confirmationRequired: return "请确认屏保将排除的不支持条目；原播放列表不会改变。"
        }
    }
}
