import Darwin
import Foundation

extension EditorExchange {
    /// This envelope contains scene references, not scene/binary content. Bound untrusted app-link input.
    public static let maximumDescriptorBytes = 16 * 1024 * 1024

    public static func read(from url: URL) throws -> EditorExchange {
        try EditorFileURL.validate(url)
        let descriptor = open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard descriptor >= 0 else { throw WallpaperError("无法打开 Editor 共享描述。") }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        let result: EditorExchange
        do {
            var info = stat()
            guard fstat(descriptor,&info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_size <= maximumDescriptorBytes else { throw WallpaperError("Editor 共享描述必须是 16 MiB 以内的普通文件。") }
            var data = Data()
            while data.count <= maximumDescriptorBytes {
                guard let chunk = try handle.read(upToCount:min(64*1024,maximumDescriptorBytes+1-data.count)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= maximumDescriptorBytes else { throw WallpaperError("Editor 共享描述超过 16 MiB。") }
            result = try EditorExchange(data:data)
        } catch {
            do { try handle.close() } catch let cleanup { throw WallpaperErrorGroup([error,cleanup]) }
            throw error
        }
        try handle.close(); return result
    }
}
