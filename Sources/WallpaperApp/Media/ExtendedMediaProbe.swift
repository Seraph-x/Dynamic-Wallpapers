import AppKit
import WallpaperCore

enum ExtendedMediaProbe {
    static let fileExtensions = ["mkv", "webm", "avi"]

    static func validateURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0"), fileExtensions.contains(url.pathExtension.lowercased()) else {
            throw WallpaperError("扩展播放器只接受本地 MKV、WebM 或 AVI 文件。")
        }
        let local = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true, values.isReadable == true else {
            throw WallpaperError("扩展视频不是可读的普通文件：\(url.lastPathComponent)")
        }
        let file = try FileHandle(forReadingFrom: local)
        let header: Data
        do { header = try file.read(upToCount: 12) ?? Data() }
        catch {
            do { try file.close() }
            catch let closeError {
                throw WallpaperError("视频文件读取失败，且未能关闭文件。",
                    diagnostic: "读取：\(String(describing: error as NSError))\n关闭文件：\(String(describing: closeError as NSError))")
            }
            throw error
        }
        try file.close()
        let isEBML = header.starts(with: [0x1a, 0x45, 0xdf, 0xa3])
        let isAVI = header.count == 12 && header.prefix(4) == Data("RIFF".utf8) && header.suffix(4) == Data("AVI ".utf8)
        guard isEBML || isAVI else {
            throw WallpaperError("文件不是 MKV/WebM/AVI 容器，拒绝作为扩展视频打开：\(url.lastPathComponent)")
        }
        return local
    }

    @MainActor
    static func inspect(_ url: URL) async throws -> MediaItem {
        let (metadata, _) = try await decodeFirstFrame(url, size: CGSize(width: 480, height: 300))
        return MediaItem(url: url, kind: .video, width: metadata.width, height: metadata.height,
                         duration: metadata.duration, backend: .extended)
    }

    @MainActor
    static func thumbnail(_ url: URL) async throws -> CGImage {
        try await decodeFirstFrame(url, size: CGSize(width: 480, height: 300)).1
    }

    @MainActor
    private static func decodeFirstFrame(_ url: URL, size: CGSize) async throws -> (ExtendedMediaMetadata, CGImage) {
        _ = try validateURL(url)
        try Task.checkCancellation()
        let surface = MPVSurface(size: size, fit: .fit)
        return try await MediaProbeCleanup.withSurface(surface) {
            // Dimensions are discovered by decoding, not taken from this request placeholder.
            let request = MediaItem(url: url, kind: .video, width: 1, height: 1, backend: .extended)
            try await surface.prepare(item: request, scale: 1, fit: .fit)
            guard let metadata = surface.metadata, let image = surface.currentImage else {
                throw WallpaperError("扩展视频未提供真实首帧。")
            }
            try Task.checkCancellation()
            return (metadata, image)
        }
    }
}
