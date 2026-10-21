import Foundation
import ScreenSaverCore
import WallpaperCore

struct ScreenSaverTarget: Codable, Equatable, Sendable {
    let revision: UUID
    let settings: ScreenSaverSettings
    let sourceRevision: ScreenSaverSourceRevision?

    init(settings: ScreenSaverSettings, sourceRevision: ScreenSaverSourceRevision?) throws {
        revision = UUID(); self.settings = settings; self.sourceRevision = sourceRevision
        try validate()
    }

    private func validate() throws {
        try settings.validate()
        guard settings.source != nil || sourceRevision == nil else {
            throw ScreenSaverFailure(code: .invalidProjection)
        }
    }

    private enum CodingKeys: String, CodingKey { case targetRevision, sourceRevision }
    init(from decoder: Decoder) throws {
        settings = try ScreenSaverSettings(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(UUID.self, forKey: .targetRevision)
        sourceRevision = try values.decodeIfPresent(ScreenSaverSourceRevision.self, forKey: .sourceRevision)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try settings.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .targetRevision)
        try values.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
    }
}

struct ScreenSaverSettingsOperations: Sendable {
    var replaceDocument: @Sendable (Data, URL) throws -> Void
    static var system: Self { Self(replaceDocument: { try ScreenSaverFileAccess.replaceDocument($0, at: $1) }) }
}

/// The settings CAS and snapshot commit share .catalog.lock, including across independent writers.
actor ScreenSaverSettingsStore {
    nonisolated let url: URL
    nonisolated let exportRoot: URL
    private let operations: ScreenSaverSettingsOperations

    init(url: URL, exportRoot: URL, operations: ScreenSaverSettingsOperations = .system) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0"), !url.hasDirectoryPath else {
            throw ScreenSaverFailure(code: .invalidPath(url.path))
        }
        self.url = url.standardizedFileURL
        self.exportRoot = try ScreenSaverPaths(root: exportRoot).root
        self.operations = operations
    }

    func load() throws -> ScreenSaverTarget? {
        try lock(.shared).using { try readTarget() }
    }

    func save(_ settings: ScreenSaverSettings, sourceRevision: ScreenSaverSourceRevision?,
              replacing expectedRevision: UUID?) throws -> ScreenSaverTarget {
        let proposed = try ScreenSaverTarget(settings: settings, sourceRevision: sourceRevision)
        return try lock(.exclusive).using {
            let current = try readTarget()
            guard current?.revision == expectedRevision else {
                throw ScreenSaverFailure(code: .transactionConflict(.configuration))
            }
            if let current, current.settings == settings, current.sourceRevision == sourceRevision { return current }
            try operations.replaceDocument(encode(proposed), url)
            return proposed
        }
    }

    /// Only call from SnapshotStore's synchronous catalog-locked commit validation; never reacquire that lock.
    nonisolated func validateForCommit(_ expected: ScreenSaverTarget) throws {
        guard try readTarget() == expected else {
            throw ScreenSaverFailure(code: .transactionConflict(.commit))
        }
        try expected.settings.validate()
    }

    func recordPublication(_ pointer: ScreenSaverCurrentPointer) throws {
        try pointer.validate()
        try lock(.exclusive).using {
            let currentURL = exportRoot.appendingPathComponent("current.json")
            guard let data = try ScreenSaverFileAccess.readDocument(at: currentURL),
                  try JSONDecoder().decode(ScreenSaverCurrentPointer.self, from: data) == pointer else {
                throw ScreenSaverFailure(code: .transactionConflict(.commit))
            }
            try operations.replaceDocument(encode(pointer), url.deletingLastPathComponent().appendingPathComponent("screensaver-publication.json"))
        }
    }

    private nonisolated func readTarget() throws -> ScreenSaverTarget? {
        guard let bytes = try ScreenSaverFileAccess.readDocument(at: url) else { return nil }
        return try JSONDecoder().decode(ScreenSaverTarget.self, from: bytes)
    }

    private func lock(_ mode: ScreenSaverFileLock.Mode) throws -> ScreenSaverFileLock {
        try ScreenSaverFileLock.acquire(root: exportRoot, relativePath: ".catalog.lock", mode: mode, nonBlocking: false)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
