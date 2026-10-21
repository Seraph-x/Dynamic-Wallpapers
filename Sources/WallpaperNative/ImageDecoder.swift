import ImageIO
import Foundation
import WallpaperCore

public actor ImageDecoder {
    private let source: CGImageSource
    private let maxPixelSize: Int
    let count: Int

    public init(url: URL, maxPixelSize: Int) throws {
        guard maxPixelSize > 0, let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0 else {
            throw WallpaperError("无法打开图片：\(url.lastPathComponent)")
        }
        self.source = source; self.maxPixelSize = maxPixelSize
        count = CGImageSourceGetCount(source)
    }

    public func frame(at index: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard index >= 0, index < count else { throw WallpaperError("动画帧索引无效。") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw WallpaperError("动画第 \(index + 1) 帧解码失败。")
        }
        return image
    }

    func delay(at index: Int) throws -> Double { try Self.delay(source: source, index: index) }

    static func delay(source: CGImageSource, index: Int) throws -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]
            ?? png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]) as? NSNumber
        guard let delay = raw?.doubleValue, delay.isFinite, delay > 0 else {
            throw WallpaperError("动画第 \(index + 1) 帧缺少有效时长，无法准确播放。")
        }
        return delay
    }
}
