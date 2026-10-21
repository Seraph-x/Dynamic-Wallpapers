import Foundation

public enum DisplaySource: Codable, Equatable, Sendable {
    case playlist(UUID)
    case media(UUID, audio: AudioSettings)

    public enum Identity: Hashable, Sendable {
        case playlist(UUID)
        case media(UUID)
    }

    public var identity: Identity {
        switch self {
        case .playlist(let id): return .playlist(id)
        case .media(let id, _): return .media(id)
        }
    }

    public var playlistID: UUID? {
        if case .playlist(let id) = self { return id }
        return nil
    }

    public var mediaID: UUID? {
        if case .media(let id, _) = self { return id }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, playlistID, mediaID, audio }
    private enum Kind: String, Codable { case playlist, media }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .playlist:
            guard !values.contains(.mediaID), !values.contains(.audio) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                    debugDescription: "播放列表来源不能同时包含单张壁纸设置。")
            }
            self = .playlist(try values.decode(UUID.self, forKey: .playlistID))
        case .media:
            guard !values.contains(.playlistID) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                    debugDescription: "单张壁纸来源不能同时引用播放列表。")
            }
            self = .media(try values.decode(UUID.self, forKey: .mediaID),
                          audio: try values.decode(AudioSettings.self, forKey: .audio))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .playlist(let id):
            try values.encode(Kind.playlist, forKey: .kind)
            try values.encode(id, forKey: .playlistID)
        case .media(let id, let audio):
            try values.encode(Kind.media, forKey: .kind)
            try values.encode(id, forKey: .mediaID)
            try values.encode(audio, forKey: .audio)
        }
    }
}

public struct DisplayBinding: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var source: DisplaySource
    public var currentEntryID: UUID?
    public var fit: ContentFit
    public var groupID: UUID
    public var playlistID: UUID? { source.playlistID }

    public init(id: String, source: DisplaySource, currentEntryID: UUID? = nil,
                fit: ContentFit = .fill, groupID: UUID = UUID()) {
        self.id = id; self.source = source; self.currentEntryID = currentEntryID
        self.fit = fit; self.groupID = groupID
    }

    public init(id: String, playlistID: UUID, currentEntryID: UUID? = nil,
                fit: ContentFit = .fill, groupID: UUID = UUID()) {
        self.init(id: id, source: .playlist(playlistID), currentEntryID: currentEntryID, fit: fit, groupID: groupID)
    }

    private enum CodingKeys: String, CodingKey { case id, source, playlistID, currentEntryID, fit, groupID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        if values.contains(.source) {
            guard !values.contains(.playlistID) else {
                throw DecodingError.dataCorruptedError(forKey: .source, in: values,
                    debugDescription: "显示器绑定同时包含新旧播放来源。")
            }
            source = try values.decode(DisplaySource.self, forKey: .source)
        } else {
            // Versions 1 and 2 stored only a playlist ID, without a source discriminator.
            source = .playlist(try values.decode(UUID.self, forKey: .playlistID))
        }
        currentEntryID = try values.decodeIfPresent(UUID.self, forKey: .currentEntryID)
        fit = try values.decode(ContentFit.self, forKey: .fit)
        groupID = try values.decode(UUID.self, forKey: .groupID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(source, forKey: .source)
        try values.encodeIfPresent(currentEntryID, forKey: .currentEntryID)
        try values.encode(fit, forKey: .fit)
        try values.encode(groupID, forKey: .groupID)
    }
}
