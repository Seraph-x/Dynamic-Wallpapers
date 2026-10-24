import Darwin
import Foundation
import WallpaperCore

/// All workspace/resource access is relative to open directories and refuses symlinks.
struct EditorProjectFiles {
    let root: URL
    var prefix: String = ""
    private var scopedDescriptor: Int32? = nil
    init(root: URL, prefix: String = "") { self.root = root; self.prefix = prefix }
    func withDirectory<T>(_ path: String = "", create: Bool = false, _ body: (Int32) throws -> T) throws -> T {
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let descriptor = scopedDescriptor.map { dup($0) } ?? open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("打开工程目录") }
        defer { close(descriptor) }
        var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard scopedDescriptor != nil || (fcntl(descriptor, F_GETPATH, &actual) == 0 &&
              URL(fileURLWithPath: String(cString: actual)).standardizedFileURL == root.standardizedFileURL) else {
            throw WallpaperError("工程根目录发生重定向。")
        }
        func descend(_ components: ArraySlice<Substring>, _ parent: Int32) throws -> T {
            guard let name = components.first else { return try body(parent) }
            let nameString = String(name)
            if create, mkdirat(parent, nameString, 0o700) != 0, errno != EEXIST { throw failure("创建工程子目录") }
            let child = openat(parent, nameString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw failure("打开工程子目录") }
            defer { close(child) }
            return try descend(components.dropFirst(), child)
        }
        if !path.isEmpty { try SceneProjectReference.validateRelativePath(path) }
        if !prefix.isEmpty { try SceneProjectReference.validateRelativePath(prefix) }
        let combined = [prefix, path].filter { !$0.isEmpty }.joined(separator: "/")
        return try descend(combined.split(separator: "/")[...], descriptor)
    }
    func read(_ path: String) throws -> Data {
        try SceneProjectReference.validateRelativePath(path)
        return try withDirectory((path as NSString).deletingLastPathComponent) { parent in
            let descriptor = openat(parent, (path as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw failure("读取工程文件") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("工程资源不是普通文件。") }
            return try handle.readToEnd() ?? Data()
        }
    }
    func write(_ data: Data, to path: String) throws {
        try SceneProjectReference.validateRelativePath(path)
        try withDirectory((path as NSString).deletingLastPathComponent, create: true) { parent in
            let name = (path as NSString).lastPathComponent, temporary = ".write-\(UUID().uuidString)"
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw failure("创建工程暂存文件") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); unlinkat(parent, temporary, 0) }
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("工程目标文件被替换为链接或目录。") }
            } else if errno != ENOENT { throw failure("检查工程目标文件") }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure("原子保存工程文件") }
        }
    }
    func remove(_ path: String) throws {
        try SceneProjectReference.validateRelativePath(path)
        try withDirectory((path as NSString).deletingLastPathComponent) { parent in
            guard unlinkat(parent, (path as NSString).lastPathComponent, 0) == 0 else { throw failure("移除旧容器") }
        }
    }
    func locked<T>(_ body: (Self) throws -> T) throws -> T {
        try withDirectory { parent in
            let descriptor = openat(parent, ".workspace-lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw failure("打开工程保存锁") }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw failure("锁定工程保存") }
            defer { flock(descriptor, LOCK_UN) }
            var scoped = Self(root: root)
            scoped.scopedDescriptor = parent
            return try body(scoped)
        }
    }
    private func failure(_ action: String) -> WallpaperError { WallpaperError("\(action)失败：\(String(cString: strerror(errno)))。") }
}
