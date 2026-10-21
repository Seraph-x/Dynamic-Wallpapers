import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import WallpaperCore

public enum NativeMediaProbe {
    public static let fileExtensions = ["mp4", "mov", "m4v", "jpg", "jpeg", "png", "apng", "heic", "heif", "gif"]

    public static func inspect(_ url: URL) async throws -> MediaItem {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw WallpaperError("无法读取“\(url.lastPathComponent)”，请检查文件位置、读取权限和磁盘连接。")
        }
        try Task.checkCancellation()
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetType(source) != nil {
            return try inspectImage(url: url, source: source)
        }
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw WallpaperError("无法解码“\(url.lastPathComponent)”，请在导入窗口查看支持的格式。")
        }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw WallpaperError("视频无可播放画面：\(url.lastPathComponent)")
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        guard duration.isFinite, duration > 0, rect.width > 0, rect.height > 0 else {
            throw WallpaperError("视频时长或尺寸无效：\(url.lastPathComponent)")
        }
        return MediaItem(url: url, kind: .video, width: Int(rect.width), height: Int(rect.height), duration: duration)
    }

    private static func inspectImage(url: URL, source: CGImageSource) throws -> MediaItem {
        let allowed = [UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier, UTType.heic.identifier, UTType.heif.identifier]
        guard let type = CGImageSourceGetType(source), allowed.contains(type as String),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw WallpaperError("不支持的图片或图片元数据损坏：\(url.lastPathComponent)")
        }
        let count = CGImageSourceGetCount(source)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else {
            throw WallpaperError("图片无法解码：\(url.lastPathComponent)")
        }
        var duration: Double = 0
        if count > 1 {
            for index in 0..<count { duration += try ImageDecoder.delay(source: source, index: index) }
        }
        return MediaItem(url: url, kind: count > 1 ? .animatedImage : .image,
                         width: width, height: height, duration: count > 1 ? duration : nil)
    }
}
