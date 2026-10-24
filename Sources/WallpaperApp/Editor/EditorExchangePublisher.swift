import Darwin
import Foundation
import WallpaperCore

/// Created lazily by the explicit Editor action; normal startup/playback performs no exchange IO.
actor EditorExchangePublisher {
    private let directory: URL
    private var boundDirectory: URL?
    init(directory: URL) { self.directory = directory.standardizedFileURL }

    func publish(_ exchange: EditorExchange) throws -> URL {
        let data = try exchange.encoded()
        guard data.count <= EditorExchange.maximumDescriptorBytes else { throw WallpaperError("Editor 共享描述超过 16 MiB。") }
        guard directory.isFileURL, [nil,"","localhost"].contains(directory.host), !directory.path.contains("\0") else { throw WallpaperError("Editor 共享目录必须是本地路径。") }
        if boundDirectory == nil {
            boundDirectory = directory.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(directory.lastPathComponent)
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        return try withHandle(open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)) { root in
            var path = [CChar](repeating:0,count:Int(MAXPATHLEN))
            guard fcntl(root.fileDescriptor,F_GETPATH,&path) == 0,
                  URL(fileURLWithPath:String(cString:path)).standardizedFileURL.path == boundDirectory?.standardizedFileURL.path else { throw WallpaperError("Editor 共享目录发生重定向。") }
            let temporary = ".exchange-\(UUID().uuidString)", name = "exchange-v1.json"
            defer { unlinkat(root.fileDescriptor,temporary,0) }
            try withHandle(openat(root.fileDescriptor,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)) { file in
                try file.write(contentsOf:data); try file.synchronize()
            }
            var info = stat()
            if fstatat(root.fileDescriptor,name,&info,AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw WallpaperError("Editor 共享描述不是普通文件。") }
            } else if errno != ENOENT { throw failure() }
            guard renameat(root.fileDescriptor,temporary,root.fileDescriptor,name) == 0 else { throw failure() }
            return directory.appendingPathComponent(name)
        }
    }
    private func withHandle<T>(_ descriptor: Int32, _ body: (FileHandle) throws -> T) throws -> T {
        guard descriptor >= 0 else { throw failure() }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        let result: T
        do { result = try body(handle) } catch {
            do { try handle.close() } catch let cleanup { throw WallpaperErrorGroup([error,cleanup]) }
            throw error
        }
        try handle.close(); return result
    }
    private func failure() -> WallpaperError { WallpaperError("Editor 共享文件操作失败：\(String(cString:strerror(errno)))。") }
}
