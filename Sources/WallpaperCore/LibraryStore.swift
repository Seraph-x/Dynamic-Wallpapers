import Foundation

public struct LibraryStore {
    public let url: URL
    public let legacyURL: URL?
    public init(url: URL, legacyURL: URL? = nil) { self.url = url; self.legacyURL = legacyURL }
    public func load() throws -> Library {
        do {
            if try LibraryMigration.exists(url) {
                var library = try LibraryMigration.read(url, supportedVersions: [2, 3, Library.currentVersion])
                library.version = Library.currentVersion
                return library
            }
            if let legacyURL { return try LibraryMigration.create(destination: url, legacy: legacyURL) }
            return .empty
        } catch {
            throw WallpaperError("素材库无法读取，原配置文件未修改。",
                diagnostic: "\(url.path)\n\(String(describing: error as NSError))")
        }
    }
    public func save(_ library: Library) throws {
        guard library.version == Library.currentVersion else {
            throw WallpaperError("新版只保存版本 \(Library.currentVersion) 素材库。")
        }
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Preserve exact on-disk bytes; a failed backup must never be treated as permission to reset.
    public func backup() throws -> URL {
        guard try LibraryMigration.exists(url) else {
            throw WallpaperError("素材库配置不存在，无法备份并清空。", diagnostic: url.path)
        }
        let backup = url.deletingLastPathComponent().appendingPathComponent("library-backup-\(UUID().uuidString).json")
        try Data(contentsOf: url).write(to: backup, options: .withoutOverwriting)
        return backup
    }
}
