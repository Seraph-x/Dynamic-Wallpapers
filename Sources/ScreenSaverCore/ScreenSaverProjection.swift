import Foundation
import WallpaperCore

/// Pure metadata projection. Readability and actual decoding are checked on copied files by the publisher.
public struct ScreenSaverProjection: Codable, Equatable, Sendable {
    public let source: ScreenSaverSource
    public let name: String
    public let entries: [PlaylistEntry]
    public let media: [MediaItem]
    public let mode: PlaybackMode
    public let transition: Double
    public let exclusions: [ScreenSaverExclusion]

    public init(library: Library, source: ScreenSaverSource) throws {
        guard (1...Library.currentVersion).contains(library.version) else {
            throw ScreenSaverFailure(code: .unsupportedSchema(schema: "library", actualVersion: library.version))
        }
        try Self.requireUnique(library.media.map(\.id))
        try Self.requireUnique(library.playlists.map(\.id))
        let available = Dictionary(uniqueKeysWithValues: library.media.map { ($0.id, $0) })
        let input = try Self.resolve(source, library: library, media: available)
        guard !input.entries.isEmpty else { throw ScreenSaverProjectionError.emptySource }
        try Self.requireUnique(input.entries.map(\.id))
        var included: [PlaylistEntry] = []
        var selected: [MediaItem] = []
        var selectedIDs = Set<UUID>()
        var excluded: [ScreenSaverExclusion] = []
        for entry in input.entries {
            guard let item = available[entry.mediaID] else { throw ScreenSaverProjectionError.missingMedia(entry.mediaID) }
            try Self.validateMedia(item, schema: library.version)
            try Self.validateEntry(entry, media: item)
            if item.backend == .native {
                included.append(entry)
                if selectedIDs.insert(item.id).inserted { selected.append(item) }
            } else {
                excluded.append(ScreenSaverExclusion(name: item.name, signature: ScreenSaverExclusionSignature(
                    entryID: entry.id, mediaID: item.id, kind: item.kind, backend: item.backend,
                    reason: item.backend == .web ? .webContent : .extendedBackend)))
            }
        }
        self.source = source; name = input.name; mode = input.mode; transition = input.transition
        entries = included; media = selected; exclusions = excluded
        try validateStructure()
    }

    public func unconfirmedExclusions(consent: ScreenSaverConsent?) -> [ScreenSaverExclusion] {
        guard let consent, consent.source == source else { return exclusions }
        let approved = Set(consent.signatures)
        return exclusions.filter { !approved.contains($0.signature) }
    }

    public func validateForPublication(consent: ScreenSaverConsent?) throws {
        guard !entries.isEmpty else { throw ScreenSaverProjectionError.noSupportedMedia }
        guard unconfirmedExclusions(consent: consent).isEmpty else {
            throw ScreenSaverProjectionError.confirmationRequired
        }
    }

    private struct Input {
        let name: String
        let entries: [PlaylistEntry]
        let mode: PlaybackMode
        let transition: Double
    }

    private static func resolve(_ source: ScreenSaverSource, library: Library, media: [UUID: MediaItem]) throws -> Input {
        switch source {
        case .media(let id):
            guard let item = media[id] else { throw ScreenSaverProjectionError.sourceMissing(source) }
            return Input(name: item.name, entries: [PlaylistEntry(id: id, mediaID: id)],
                         mode: .repeatOne, transition: 0)
        case .playlist(let id):
            guard let list = library.playlists.first(where: { $0.id == id }) else {
                throw ScreenSaverProjectionError.sourceMissing(source)
            }
            return Input(name: list.name, entries: list.entries, mode: list.mode, transition: list.transition)
        }
    }

    private static func validateMedia(_ item: MediaItem, schema: Int) throws {
        do { try item.validateBackend(schema: schema) }
        catch { throw ScreenSaverFailure(code: .invalidSourceMetadata(item.name)) }
        guard item.url.isFileURL, item.url.host == nil || item.url.host == "" || item.url.host == "localhost",
              !item.url.path.contains("\0"), item.width > 0, item.height > 0,
              item.duration.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw ScreenSaverFailure(code: .invalidSourceMetadata(item.name))
        }
        if item.backend == .native, item.kind == .video || item.kind == .animatedImage, item.duration == nil {
            throw ScreenSaverFailure(code: .missingDuration(item.name))
        }
        if let duration = item.duration {
            do { try EntryTiming.validateClockDuration(duration) }
            catch { throw ScreenSaverFailure(code: .invalidSourceMetadata(item.name)) }
        }
    }

    private static func validateEntry(_ entry: PlaylistEntry, media: MediaItem) throws {
        do {
            try entry.timing.validate()
            try entry.audio.validate()
        } catch {
            throw ScreenSaverFailure(code: .invalidProjection)
        }
        guard media.kind != .web || entry.timing.mode == .seconds else {
            throw ScreenSaverFailure(code: .unsupportedDuration)
        }
        do { try EntryTiming.validateClockDuration(entry.timing.duration(mediaDuration: media.duration)) }
        catch { throw ScreenSaverFailure(code: .unsupportedDuration) }
    }

    private static func requireUnique(_ ids: [UUID]) throws {
        guard Set(ids).count == ids.count else { throw ScreenSaverFailure(code: .invalidProjection) }
    }

    private func validateStructure() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenSaverFailure(code: .invalidProjection)
        }
        do { try EntryTiming.validateClockDuration(transition) }
        catch { throw ScreenSaverFailure(code: .invalidProjection) }
        let entryIDs = entries.map(\.id) + exclusions.map(\.signature.entryID)
        guard !entryIDs.isEmpty else { throw ScreenSaverProjectionError.emptySource }
        try Self.requireUnique(entryIDs)
        try Self.requireUnique(media.map(\.id))
        guard Set(entries.map(\.mediaID)) == Set(media.map(\.id)) else {
            throw ScreenSaverFailure(code: .invalidProjection)
        }
        let available = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        for item in media {
            try Self.validateMedia(item, schema: Library.currentVersion)
            guard item.backend == .native else { throw ScreenSaverFailure(code: .invalidProjection) }
        }
        for entry in entries {
            guard let item = available[entry.mediaID] else { throw ScreenSaverProjectionError.missingMedia(entry.mediaID) }
            try Self.validateEntry(entry, media: item)
        }
        for exclusion in exclusions { try exclusion.signature.validate() }
        if case .media(let id) = source {
            let referenced = entries.map(\.mediaID) + exclusions.map(\.signature.mediaID)
            guard entryIDs == [id], referenced == [id], mode == .repeatOne, transition == 0 else {
                throw ScreenSaverFailure(code: .invalidProjection)
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case source, name, entries, media, mode, transition, exclusions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(ScreenSaverSource.self, forKey: .source)
        name = try values.decode(String.self, forKey: .name)
        entries = try values.decode([PlaylistEntry].self, forKey: .entries)
        media = try values.decode([MediaItem].self, forKey: .media)
        mode = try values.decode(PlaybackMode.self, forKey: .mode)
        transition = try values.decode(Double.self, forKey: .transition)
        exclusions = try values.decode([ScreenSaverExclusion].self, forKey: .exclusions)
        try validateStructure()
    }
}
