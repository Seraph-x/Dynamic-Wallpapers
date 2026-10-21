import Darwin
import Foundation

public struct ManagedDirectoryIdentity: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64

    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }

    static func read(_ descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ManagedMediaFileSystem.error("无法核验素材目录身份") }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw WallpaperError("托管素材不是普通目录。") }
        return Self(info)
    }
}

/// Descriptor-relative writes/removal never traverse links in the managed tree.
enum ManagedMediaFileSystem {
    static func error(_ action: String) -> WallpaperError {
        let code = errno
        return WallpaperError("\(action)：\(String(cString: strerror(code)))。")
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        url.pathComponents.starts(with: root.pathComponents)
    }

    static func resolve(_ url: URL) throws -> URL {
        guard url.isFileURL, !url.path.contains("\0") else { throw WallpaperError("素材路径必须是本地文件。") }
        guard let path = realpath(url.path, nil) else { throw error("无法解析素材路径 \(url.path)") }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
    }

    static func path(of descriptor: Int32) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw error("无法核验已打开的素材路径") }
        return URL(fileURLWithPath: String(cString: path)).standardizedFileURL
    }

    static func withHandle<T>(_ descriptor: Int32, _ body: (FileHandle) throws -> T) throws -> T {
        guard descriptor >= 0 else { throw error("无法打开素材文件或目录") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let result: T
        do { result = try body(handle) }
        catch {
            do { try handle.close() }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
        try handle.close()
        return result
    }

    static func names(in descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw error("无法读取素材目录") }
        guard let stream = fdopendir(duplicate) else {
            let failure = error("无法遍历素材目录")
            do { try withHandle(duplicate) { _ in () } }
            catch { throw WallpaperErrorGroup([failure, error]) }
            throw failure
        }
        var names: [String] = []
        var failure: Error?
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { failure = error("读取素材目录失败") }
                break
            }
            var bytes = entry.pointee.d_name
            let name = withUnsafePointer(to: &bytes) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        if closedir(stream) != 0 {
            let cleanup = error("关闭素材目录失败")
            if let failure { throw WallpaperErrorGroup([failure, cleanup]) }
            throw cleanup
        }
        if let failure { throw failure }
        return names
    }

    static func removeDirectory(_ name: String, in parent: Int32, expected: ManagedDirectoryIdentity) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw error("无法检查待删除素材目录 \(name)")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw WallpaperError("托管素材目录不是普通目录，拒绝删除：\(name)。")
        }
        try withHandle(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) { handle in
            guard try ManagedDirectoryIdentity.read(handle.fileDescriptor) == expected else {
                throw WallpaperError("托管素材目录已被替换，拒绝删除：\(name)。")
            }
            for child in try names(in: handle.fileDescriptor) {
                var childInfo = stat()
                guard fstatat(handle.fileDescriptor, child, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw error("无法检查托管素材 \(child)")
                }
                if childInfo.st_mode & S_IFMT == S_IFDIR {
                    try removeDirectory(child, in: handle.fileDescriptor, expected: ManagedDirectoryIdentity(childInfo))
                } else if unlinkat(handle.fileDescriptor, child, 0) != 0 {
                    throw error("无法删除托管素材 \(child)")
                }
            }
            // Do not unlink a replacement directory after operating on the original descriptor.
            var current = stat(), opened = stat()
            guard fstat(handle.fileDescriptor, &opened) == 0,
                  fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                throw WallpaperError("托管素材目录在清理期间被替换，删除未完成：\(name)。")
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw error("无法删除素材目录 \(name)") }
        }
    }
}
