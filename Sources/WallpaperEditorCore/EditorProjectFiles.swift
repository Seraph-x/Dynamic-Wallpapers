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
    func containsFile(_ path: String) throws -> Bool {
        try SceneProjectReference.validateRelativePath(path)
        return try withDirectory((path as NSString).deletingLastPathComponent) { parent in
            var info = stat()
            if fstatat(parent, (path as NSString).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return false }
                throw failure("检查工程资源")
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("工程资源不是普通文件。") }
            return true
        }
    }
    func remove(_ path: String) throws {
        try SceneProjectReference.validateRelativePath(path)
        try withDirectory((path as NSString).deletingLastPathComponent) { parent in
            guard unlinkat(parent, (path as NSString).lastPathComponent, 0) == 0 else { throw failure("移除旧容器") }
        }
    }
    func paths() throws -> [String] {
        try withDirectory { root in
            func visit(_ descriptor: Int32, _ prefix: String) throws -> [String] {
                let duplicate = dup(descriptor)
                guard duplicate >= 0 else { throw failure("复制工程目录描述符") }
                guard let stream = fdopendir(duplicate) else { close(duplicate); throw failure("枚举工程目录") }
                defer { closedir(stream) }
                var result: [String] = []
                while true {
                    errno = 0
                    guard let entry = readdir(stream) else { if errno != 0 { throw failure("读取工程目录") }; break }
                    var nameBytes = entry.pointee.d_name
                    let name = withUnsafePointer(to: &nameBytes) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                    if name == "." || name == ".." { continue }
                    let path = prefix + name; try SceneProjectReference.validateRelativePath(path)
                    var info = stat()
                    guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("检查工程资源") }
                    if info.st_mode & S_IFMT == S_IFREG { result.append(path) }
                    else if info.st_mode & S_IFMT == S_IFDIR {
                        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard child >= 0 else { throw failure("打开工程资源目录") }
                        defer { close(child) }
                        result += try visit(child, path + "/")
                    } else { throw WallpaperError("工程包含链接或非普通资源：\(path)。") }
                }
                return result
            }
            return try visit(root, "").sorted()
        }
    }
    /// The scoped reader borrows this directory descriptor and must not escape the closure.
    func withReadOnlyScope<T>(_ body: (Self) throws -> T) throws -> T {
        try withDirectory { descriptor in
            var scoped = Self(root: root)
            scoped.scopedDescriptor = descriptor
            return try body(scoped)
        }
    }
    func locked<T>(_ body: (Self) throws -> T) throws -> T {
        try withDirectory { parent in
            let descriptor = try Self.openLock(".workspace-lock", parent: parent)
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw failure("锁定工程保存") }
            defer { flock(descriptor, LOCK_UN) }
            try Self.validateLock(descriptor, name: ".workspace-lock", parent: parent)
            var scoped = Self(root: root)
            scoped.scopedDescriptor = parent
            return try body(scoped)
        }
    }
    static func openLock(_ name: String, parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("打开工程锁") }
        do { try validateLock(descriptor, name: name, parent: parent); return descriptor }
        catch { close(descriptor); throw error }
    }
    static func validateLock(_ descriptor: Int32, name: String, parent: Int32) throws {
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino, opened.st_nlink == 1 else {
            throw WallpaperError("工程锁不是稳定的普通文件。")
        }
    }
    static func failure(_ action: String) -> WallpaperError { WallpaperError("\(action)失败：\(String(cString: strerror(errno)))。") }
    private func failure(_ action: String) -> WallpaperError { Self.failure(action) }
}
