import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArtworkImageDecoder {
    /// Normalize actual source pixels and orientation without changing resolution.
    public static func decode(_ data: Data, for identity: SystemMediaArtworkIdentity) throws -> SystemMediaArtwork {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else {
            throw SystemMediaArtworkError.invalidImage("Missing encoded image or dimensions")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw SystemMediaArtworkError.invalidImage("ImageIO could not decode the complete image")
        }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw SystemMediaArtworkError.invalidImage("Could not create PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SystemMediaArtworkError.invalidImage("ImageIO could not encode PNG")
        }
        try Task.checkCancellation()
        return SystemMediaArtwork(identity: identity, pngData: output as Data, width: image.width, height: image.height)
    }
}
