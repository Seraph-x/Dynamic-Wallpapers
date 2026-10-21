import Foundation
import WallpaperCore

public struct ScreenSaverManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let generationID: UUID
    public let sourceRevision: ScreenSaverSourceRevision
    public let source: ScreenSaverSource
    public let name: String
    public let entries: [PlaylistEntry]
    public let files: [ScreenSaverMediaFile]
    public let mode: PlaybackMode
    public let transition: Double
    public let isMuted: Bool
    public let fit: ContentFit

    public init(generationID: UUID, projection: ScreenSaverProjection, settings: ScreenSaverSettings,
                files: [ScreenSaverMediaFile]) throws {
        try settings.validate()
        try projection.validateForPublication(consent: settings.consent)
        schemaVersion = Self.currentVersion
        self.generationID = generationID
        sourceRevision = try ScreenSaverSourceRevision(projection: projection, settings: settings)
        source = projection.source; name = projection.name; entries = projection.entries
        mode = projection.mode; transition = projection.transition
        isMuted = settings.isMuted; fit = settings.fit; self.files = files
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentVersion else {
            throw ScreenSaverFailure(code: .unsupportedSchema(schema: "manifest", actualVersion: schemaVersion))
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !entries.isEmpty, !files.isEmpty else {
            throw ScreenSaverFailure(code: .invalidProjection)
        }
        do { try EntryTiming.validateClockDuration(transition) }
        catch { throw ScreenSaverFailure(code: .invalidProjection) }
        guard Set(entries.map(\.id)).count == entries.count, Set(files.map(\.id)).count == files.count,
              Set(files.map(\.relativePath)).count == files.count,
              Set(entries.map(\.mediaID)) == Set(files.map(\.id)) else {
            throw ScreenSaverFailure(code: .invalidProjection)
        }
        for file in files { try file.validate() }
        let available = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        for entry in entries {
            do {
                try entry.timing.validate()
                try entry.audio.validate()
            } catch {
                throw ScreenSaverFailure(code: .invalidProjection)
            }
            guard let file = available[entry.mediaID] else {
                throw ScreenSaverFailure(code: .missingMedia(entry.mediaID))
            }
            do { try EntryTiming.validateClockDuration(entry.timing.duration(mediaDuration: file.duration)) }
            catch { throw ScreenSaverFailure(code: .unsupportedDuration) }
        }
        if case .media(let id) = source {
            guard entries.count == 1, entries[0].id == id, entries[0].mediaID == id,
                  mode == .repeatOne, transition == 0 else {
                throw ScreenSaverFailure(code: .invalidProjection)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generationID, sourceRevision, source, name, entries, files, mode, transition, isMuted, fit
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        generationID = try values.decode(UUID.self, forKey: .generationID)
        sourceRevision = try values.decode(ScreenSaverSourceRevision.self, forKey: .sourceRevision)
        source = try values.decode(ScreenSaverSource.self, forKey: .source)
        name = try values.decode(String.self, forKey: .name)
        entries = try values.decode([PlaylistEntry].self, forKey: .entries)
        files = try values.decode([ScreenSaverMediaFile].self, forKey: .files)
        mode = try values.decode(PlaybackMode.self, forKey: .mode)
        transition = try values.decode(Double.self, forKey: .transition)
        isMuted = try values.decode(Bool.self, forKey: .isMuted)
        fit = try values.decode(ContentFit.self, forKey: .fit)
        try validate()
    }
}

public struct ScreenSaverExportIdentity: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let format: String
    public let id: UUID
    public init(id: UUID = UUID()) {
        schemaVersion = 1; format = "local.dynamicwallpaper.screensaver.export"; self.id = id
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, format, id }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        format = try values.decode(String.self, forKey: .format)
        id = try values.decode(UUID.self, forKey: .id)
        guard schemaVersion == 1, format == "local.dynamicwallpaper.screensaver.export" else {
            throw ScreenSaverFailure(code: .identityChanged)
        }
    }
}

public struct ScreenSaverCurrentPointer: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let exportID: UUID
    public let generationID: UUID?
    public let sourceRevision: ScreenSaverSourceRevision?
    public let settingsRevision: UUID
    public let publishedAt: Date

    public init(exportID: UUID, generationID: UUID?, sourceRevision: ScreenSaverSourceRevision?,
                settingsRevision: UUID, publishedAt: Date = Date()) {
        schemaVersion = 1; self.exportID = exportID; self.generationID = generationID
        self.sourceRevision = sourceRevision; self.settingsRevision = settingsRevision; self.publishedAt = publishedAt
    }

    public func validate() throws {
        guard schemaVersion == 1, (generationID == nil) == (sourceRevision == nil), publishedAt.timeIntervalSince1970.isFinite else {
            throw ScreenSaverFailure(code: .pointerUnavailable)
        }
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, exportID, generationID, sourceRevision, settingsRevision, publishedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        exportID = try values.decode(UUID.self, forKey: .exportID)
        generationID = try values.decodeIfPresent(UUID.self, forKey: .generationID)
        sourceRevision = try values.decodeIfPresent(ScreenSaverSourceRevision.self, forKey: .sourceRevision)
        settingsRevision = try values.decode(UUID.self, forKey: .settingsRevision)
        publishedAt = try values.decode(Date.self, forKey: .publishedAt)
        try validate()
    }
}
