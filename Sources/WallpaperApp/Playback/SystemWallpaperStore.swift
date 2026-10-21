import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WallpaperCore

/// Exported posters are durable assets: macOS (including other Spaces) can still reference them after exit.
actor SystemWallpaperStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func key(for content: SystemWallpaperContent) throws -> SystemWallpaperKey {
        guard content.width > 0, content.height > 0 else { throw WallpaperError("系统底图尺寸无效。") }
        let item = content.item
        let sourceVersion = try SystemWallpaperSourceVersionReader.fingerprint(for: item)
        let parts = ["poster-v2", item.id.uuidString, item.kind.rawValue, item.backend.rawValue, sourceVersion,
                     content.fit.rawValue, String(content.width), String(content.height)]
        let data = try JSONEncoder().encode(parts)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SystemWallpaperKey(digest: digest, content: content, sourceVersion: sourceVersion)
    }

    func validateSource(for key: SystemWallpaperKey) throws {
        guard try SystemWallpaperSourceVersionReader.fingerprint(for: key.content.item) == key.sourceVersion else {
            throw SystemWallpaperSourceVersionReader.changedSource
        }
    }

    func cachedImage(for key: SystemWallpaperKey) throws -> URL? {
        let url = imageURL(for: key)
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == key.content.width, image.height == key.content.height else {
            throw WallpaperError("已保存的系统底图损坏或尺寸不匹配。", diagnostic: url.path)
        }
        return url
    }

    func save(_ image: CGImage, for key: SystemWallpaperKey) throws -> URL {
        try Task.checkCancellation()
        guard image.width == key.content.width, image.height == key.content.height else {
            throw WallpaperError("系统底图截图尺寸与显示器不一致。")
        }
        try validateSource(for: key)
        if let cached = try cachedImage(for: key) { return cached }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WallpaperError("无法编码系统底图。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError("无法编码系统底图。") }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = imageURL(for: key)
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    private func imageURL(for key: SystemWallpaperKey) -> URL {
        directory.appendingPathComponent(key.digest).appendingPathExtension("png")
    }
}
