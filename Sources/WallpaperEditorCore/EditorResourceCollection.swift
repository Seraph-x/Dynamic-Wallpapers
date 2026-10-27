import Darwin
import Foundation
import WallpaperCore

public struct EditorResourceCollection: Sendable {
    public let projectID: UUID
    public let activeSession: Bool
    public let removedVersions: [String]
    public let reclaimedBytes: UInt64
}

public struct EditorResourceCollectionFailure: Sendable {
    public let projectID: UUID
    public let message: String
}

public struct EditorResourceCollectionReport: Sendable {
    public let projects: [EditorResourceCollection]
    public let failures: [EditorResourceCollectionFailure]
}

extension EditorProjectStore {
    /// Collect only closed projects. Active sessions protect every current, undo, redo and staged version.
    public func collectUnusedResources(id: UUID) throws -> EditorResourceCollection {
        let files = EditorProjectFiles(root: directory, prefix: id.uuidString)
        return try files.withReadOnlyScope { project in
            try project.withDirectory { parent in
                let lease = try EditorProjectFiles.openLock(".resource-session-lock", parent: parent)
                defer { close(lease) }
                guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK { return EditorResourceCollection(projectID: id, activeSession: true, removedVersions: [], reclaimedBytes: 0) }
                    throw EditorProjectFiles.failure("锁定资源回收")
                }
                defer { flock(lease, LOCK_UN) }
                try EditorProjectFiles.validateLock(lease, name: ".resource-session-lock", parent: parent)
                return try project.locked { scoped in
                    let document = try EditorProjectDocument(data: scoped.read("workspace.json"))
                    guard document.id == id else { throw WallpaperError("工程身份与目录不符。") }
                    return try collectResources(document, files: scoped)
                }
            }
        }
    }

    /// Inventory only canonical UUID projects. Unrelated entries and original Project files are never removed.
    public func collectUnusedResources() throws -> EditorResourceCollectionReport {
        let files = EditorProjectFiles(root: directory)
        let ids = try files.withDirectory(create: true) { descriptor in
            try EditorProjectFiles.entries(descriptor).compactMap { entry -> UUID? in
                guard let id = UUID(uuidString: entry.name), id.uuidString == entry.name else { return nil }
                return id
            }.sorted { $0.uuidString < $1.uuidString }
        }
        var projects: [EditorResourceCollection] = [], failures: [EditorResourceCollectionFailure] = []
        for id in ids {
            do { projects.append(try collectUnusedResources(id: id)) }
            catch { failures.append(EditorResourceCollectionFailure(projectID: id, message: error.localizedDescription)) }
        }
        return EditorResourceCollectionReport(projects: projects, failures: failures)
    }

    private func collectResources(_ document: EditorProjectDocument, files: EditorProjectFiles) throws -> EditorResourceCollection {
        let retained = Set(document.resourceOverrides.values.map(\.id))
        let present = try files.withDirectory { descriptor -> Bool in
            var info = stat()
            if fstatat(descriptor, "Resources", &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return false }
                throw EditorProjectFiles.failure("检查资源目录")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw WallpaperError("资源目录被替换为链接或非目录。") }
            return true
        }
        if !present {
            guard retained.isEmpty else { throw WallpaperError("已保存工程缺少资源目录。") }
            return EditorResourceCollection(projectID: document.id, activeSession: false, removedVersions: [], reclaimedBytes: 0)
        }
        return try files.withDirectory("Resources") { descriptor in
            let inventory = try EditorProjectFiles.entries(descriptor)
            // Validate the complete inventory and saved references before the first deletion.
            for entry in inventory {
                _ = try EditorResourceVersion(id: entry.name)
                guard entry.info.st_mode & S_IFMT == S_IFREG, entry.info.st_nlink == 1, entry.info.st_size >= 0 else {
                    throw WallpaperError("资源回收发现链接、目录或非普通资源：\(entry.name)。")
                }
            }
            for version in Set(document.resourceOverrides.values) {
                let bytes = try files.read("Resources/" + version.id)
                guard EditorResourceVersion(data: bytes) == version else { throw WallpaperError("已保存的工程资源已损坏。") }
            }
            let candidates = inventory.filter { !retained.contains($0.name) }.sorted { $0.name < $1.name }
            func validateCandidate(_ entry: EditorProjectFiles.DirectoryEntry) throws {
                var current = stat()
                guard fstatat(descriptor, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
                      current.st_dev == entry.info.st_dev, current.st_ino == entry.info.st_ino,
                      current.st_size == entry.info.st_size else { throw WallpaperError("资源回收期间资源发生改变：\(entry.name)。") }
            }
            var bytes: UInt64 = 0
            for entry in candidates {
                try validateCandidate(entry)
                let (sum, overflow) = bytes.addingReportingOverflow(UInt64(entry.info.st_size))
                guard !overflow else { throw WallpaperError("资源回收大小超出可表示范围。") }
                bytes = sum
            }
            var removed: [String] = []
            for entry in candidates {
                try validateCandidate(entry)
                guard unlinkat(descriptor, entry.name, 0) == 0 else { throw EditorProjectFiles.failure("回收未引用的资源") }
                removed.append(entry.name)
            }
            return EditorResourceCollection(projectID: document.id, activeSession: false, removedVersions: removed, reclaimedBytes: bytes)
        }
    }
}

extension EditorProjectFiles {
    struct DirectoryEntry { let name: String; let info: stat }
    static func entries(_ descriptor: Int32) throws -> [DirectoryEntry] {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw failure("复制资源目录") }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw failure("枚举资源目录") }
        defer { closedir(stream) }
        var result: [DirectoryEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw failure("读取资源目录") }; break }
            var nameBytes = entry.pointee.d_name
            guard let name = withUnsafePointer(to: &nameBytes, { String(validatingCString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }) else {
                throw WallpaperError("资源目录包含无效 UTF-8 文件名。")
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("检查资源目录项") }
            result.append(DirectoryEntry(name: name, info: info))
        }
        return result
    }
}
