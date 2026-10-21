import Darwin
import Foundation

/// All bytes are materialized, including internal symlinks; no original-file dependency remains.
enum ManagedProjectCopy {
    private static let chunkSize = 1_048_576

    static func copy(_ source: URL, into parent: Int32, name: String,
                     projectRoot: URL? = nil, ancestors: Set<URL> = []) throws {
        try Task.checkCancellation()
        let resolved = try ManagedMediaFileSystem.resolve(source)
        if let projectRoot, !ManagedMediaFileSystem.contains(resolved, in: projectRoot) {
            throw WallpaperError("资源符号链接越出网页项目：\(source.path)。")
        }
        guard !ancestors.contains(resolved) else { throw WallpaperError("网页项目包含循环目录链接：\(source.path)。") }
        let descriptor = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try ManagedMediaFileSystem.withHandle(descriptor) { input in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw ManagedMediaFileSystem.error("无法检查素材") }
            let actual = try ManagedMediaFileSystem.path(of: descriptor)
            guard actual == resolved else { throw WallpaperError("复制期间素材路径发生变化：\(source.path)。") }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                try copyFile(input, into: parent, name: name)
            case S_IFDIR:
                guard projectRoot != nil else { throw WallpaperError("请通过网页项目入口导入目录。") }
                guard mkdirat(parent, name, 0o700) == 0 else { throw ManagedMediaFileSystem.error("无法创建网页副本目录 \(name)") }
                try ManagedMediaFileSystem.withHandle(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) { output in
                    for child in try ManagedMediaFileSystem.names(in: descriptor) {
                        try copy(actual.appendingPathComponent(child), into: output.fileDescriptor, name: child,
                                 projectRoot: projectRoot, ancestors: ancestors.union([resolved]))
                    }
                }
            default:
                throw WallpaperError("素材包含非普通文件：\(source.path)。")
            }
        }
    }

    private static func copyFile(_ input: FileHandle, into parent: Int32, name: String) throws {
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try ManagedMediaFileSystem.withHandle(descriptor) { output in
            while true {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: chunkSize), !bytes.isEmpty else { break }
                try output.write(contentsOf: bytes)
            }
        }
    }
}
