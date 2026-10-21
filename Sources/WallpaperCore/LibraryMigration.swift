import Foundation
import Darwin

enum LibraryMigration {
    static func exists(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw WallpaperError("素材库路径必须是本地文件。") }
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { lstat($0!, &info) }
        if result == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw WallpaperError("素材库不是普通文件（目录或符号链接）：\(url.path)。原路径未修改。")
            }
            return true
        }
        let code = errno
        if code == ENOENT { return false }
        throw WallpaperError("无法检查素材库 \(url.path)：\(String(cString: strerror(code)))。")
    }

    static func read(_ url: URL, supportedVersions: Set<Int>) throws -> Library {
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
        guard supportedVersions.contains(library.version) else {
            throw WallpaperError("素材库 \(url.lastPathComponent) 支持版本 \(supportedVersions.sorted())，实际为 \(library.version)。")
        }
        try library.validate()
        return library
    }

    static func create(destination: URL, legacy: URL) throws -> Library {
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != legacy.standardizedFileURL.resolvingSymlinksInPath() else {
            throw WallpaperError("新版和旧版素材库不能使用同一路径。")
        }
        var library = try exists(legacy) ? read(legacy, supportedVersions: [1]) : .empty
        library.version = Library.currentVersion
        try library.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".library-migration-\(UUID().uuidString).json")
        try data.write(to: staged, options: .withoutOverwriting)
        do {
            try ExclusiveFileCommit.commit(staged: staged, destination: destination)
        } catch {
            do { try FileManager.default.removeItem(at: staged) }
            catch let cleanup { throw WallpaperError("\(error.localizedDescription) 临时文件清理失败：\(cleanup.localizedDescription)") }
            throw error
        }
        try FileManager.default.removeItem(at: staged)
        return library
    }
}
