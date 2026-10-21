import Darwin
import Foundation

public struct MediaOrigin: Codable, Equatable, Sendable {
    public let url: URL
    public let projectRoot: URL?
    public let directoryIdentity: ManagedDirectoryIdentity?
    public init(url: URL, projectRoot: URL? = nil, directoryIdentity: ManagedDirectoryIdentity? = nil) {
        self.url = url.standardizedFileURL
        self.projectRoot = projectRoot?.standardizedFileURL
        self.directoryIdentity = directoryIdentity
    }
}

public enum ManagedMediaSource: Sendable {
    case file(URL)
    case web(WebProjectReference)

    public var origin: MediaOrigin {
        switch self {
        case .file(let url): return MediaOrigin(url: url.standardizedFileURL)
        case .web(let project):
            return MediaOrigin(url: project.entryURL.standardizedFileURL, projectRoot: project.root.standardizedFileURL)
        }
    }
}

public struct ManagedMediaCopy: Sendable {
    public let id: UUID
    public let stagedURL: URL
    public let url: URL
    public let stagedWebProject: WebProjectReference?
    public let webProject: WebProjectReference?
    public fileprivate(set) var origin: MediaOrigin
    fileprivate let owner: UUID
    fileprivate var stagingName: String { ".import-\(id.uuidString)" }

    public func item(from metadata: MediaItem) -> MediaItem {
        MediaItem(id: id, url: url, kind: metadata.kind, width: metadata.width, height: metadata.height,
                  duration: metadata.duration, isFavorite: metadata.isFavorite, backend: metadata.backend,
                  webProject: webProject, origin: origin, customName: metadata.customName)
    }
}

/// Blocking file IO runs on this actor, never on the UI actor.
public actor ManagedMediaStore {
    public nonisolated let directory: URL
    private let requestedDirectory: URL
    private let owner = UUID()

    public init(directory: URL) {
        requestedDirectory = directory.standardizedFileURL
        self.directory = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
    }

    public func stage(source: ManagedMediaSource) throws -> ManagedMediaCopy {
        try Task.checkCancellation()
        let id = UUID()
        let staged = directory.appendingPathComponent(".import-\(id.uuidString)")
        let committed = directory.appendingPathComponent(id.uuidString)
        var copy: ManagedMediaCopy
        switch source {
        case .file(let url):
            guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw WallpaperError("素材路径必须是本地文件。") }
            copy = ManagedMediaCopy(id: id, stagedURL: staged.appendingPathComponent(url.lastPathComponent),
                url: committed.appendingPathComponent(url.lastPathComponent), stagedWebProject: nil,
                webProject: nil, origin: source.origin, owner: owner)
        case .web(let project):
            try project.validate()
            let root = try ManagedMediaFileSystem.resolve(project.root)
            guard !ManagedMediaFileSystem.contains(directory, in: root) else {
                throw WallpaperError("网页项目目录不能包含应用的 Media 目录。")
            }
            let stagingProject = WebProjectReference(root: staged.appendingPathComponent("Project"), entry: project.entry)
            let finalProject = WebProjectReference(root: committed.appendingPathComponent("Project"), entry: project.entry)
            copy = ManagedMediaCopy(id: id, stagedURL: stagingProject.entryURL, url: finalProject.entryURL,
                stagedWebProject: stagingProject, webProject: finalProject, origin: source.origin, owner: owner)
        }
        try withRoot(create: true) { root in
            guard mkdirat(root, copy.stagingName, 0o700) == 0 else { throw ManagedMediaFileSystem.error("无法创建导入暂存目录") }
            do {
                try ManagedMediaFileSystem.withHandle(openat(root, copy.stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) { target in
                    copy.origin = MediaOrigin(url: copy.origin.url, projectRoot: copy.origin.projectRoot,
                        directoryIdentity: try ManagedDirectoryIdentity.read(target.fileDescriptor))
                    switch source {
                    case .file(let url): try ManagedProjectCopy.copy(url, into: target.fileDescriptor, name: url.lastPathComponent)
                    case .web(let project):
                        let resolved = try ManagedMediaFileSystem.resolve(project.root)
                        try ManagedProjectCopy.copy(resolved, into: target.fileDescriptor, name: "Project", projectRoot: resolved)
                    }
                    try Task.checkCancellation()
                }
            } catch {
                guard let identity = copy.origin.directoryIdentity else {
                    throw WallpaperErrorGroup([error, WallpaperError("无法确认暂存目录身份，已保留：\(staged.path)。")])
                }
                do { try ManagedMediaFileSystem.removeDirectory(copy.stagingName, in: root, expected: identity) }
                catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
                throw error
            }
        }
        return copy
    }

    public func commit(_ copy: ManagedMediaCopy) throws {
        let identity = try requireOwner(copy)
        try Task.checkCancellation()
        var committed = false
        try withRoot(create: false) { root in
            try ManagedMediaFileSystem.withHandle(openat(root, copy.stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) { source in
                guard try ManagedDirectoryIdentity.read(source.fileDescriptor) == identity else {
                    throw WallpaperError("导入暂存目录被替换，拒绝提交。")
                }
                guard renameatx_np(root, copy.stagingName, root, copy.id.uuidString, UInt32(RENAME_EXCL)) == 0 else {
                    throw ManagedMediaFileSystem.error("无法提交导入副本")
                }
                try ManagedMediaFileSystem.withHandle(openat(root, copy.id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) { target in
                    guard try ManagedDirectoryIdentity.read(target.fileDescriptor) == identity else {
                        throw WallpaperError("提交后的素材目录被替换。")
                    }
                    committed = true
                }
            }
        }
        guard committed else { throw WallpaperError("导入副本未提交。") }
    }

    public func discard(_ copy: ManagedMediaCopy) throws {
        let identity = try requireOwner(copy)
        try withRoot(create: false) { root in
            var removed = false, foundUnowned = false
            for name in [copy.stagingName, copy.id.uuidString] {
                var info = stat()
                if fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }
                    throw ManagedMediaFileSystem.error("无法检查待回滚的素材目录")
                }
                guard info.st_mode & S_IFMT == S_IFDIR, ManagedDirectoryIdentity(info) == identity else {
                    foundUnowned = true; continue
                }
                try ManagedMediaFileSystem.removeDirectory(name, in: root, expected: identity)
                removed = true
            }
            if foundUnowned, !removed { throw WallpaperError("素材目录被替换，未删除不属于本次导入的文件。") }
        }
    }

    public func remove(_ item: MediaItem) throws {
        guard let origin = item.origin else { return } // Legacy external references never grant file ownership.
        guard let identity = origin.directoryIdentity else { throw WallpaperError("素材缺少托管目录身份，拒绝删除。") }
        let folder = directory.appendingPathComponent(item.id.uuidString)
        if let project = item.webProject {
            try project.validate()
            guard project.root.standardizedFileURL.pathComponents == folder.appendingPathComponent("Project").standardizedFileURL.pathComponents,
                  item.url.standardizedFileURL.pathComponents == project.entryURL.standardizedFileURL.pathComponents else {
                throw WallpaperError("网页素材不在对应的托管目录中，拒绝删除。")
            }
        } else {
            guard item.url.isFileURL, item.url.deletingLastPathComponent().standardizedFileURL.pathComponents == folder.standardizedFileURL.pathComponents else {
                throw WallpaperError("素材不在对应的托管目录中，拒绝删除。")
            }
        }
        try withRoot(create: false) { try ManagedMediaFileSystem.removeDirectory(item.id.uuidString, in: $0, expected: identity) }
    }

    private func requireOwner(_ copy: ManagedMediaCopy) throws -> ManagedDirectoryIdentity {
        guard copy.owner == owner, let identity = copy.origin.directoryIdentity else { throw WallpaperError("导入副本属于其他素材库或缺少目录身份。") }
        return identity
    }

    private func withRoot(create: Bool, _ body: (Int32) throws -> Void) throws {
        if create { try FileManager.default.createDirectory(at: requestedDirectory, withIntermediateDirectories: true) }
        var info = stat()
        if lstat(requestedDirectory.path, &info) != 0 {
            if errno == ENOENT, !create { return }
            throw ManagedMediaFileSystem.error("无法检查托管素材根目录")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw WallpaperError("托管素材根目录不能是符号链接或文件。") }
        try ManagedMediaFileSystem.withHandle(open(requestedDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) { handle in
            guard try ManagedMediaFileSystem.path(of: handle.fileDescriptor) == directory.standardizedFileURL else {
                throw WallpaperError("托管素材根目录发生重定向，操作已停止。")
            }
            try body(handle.fileDescriptor)
        }
    }
}
