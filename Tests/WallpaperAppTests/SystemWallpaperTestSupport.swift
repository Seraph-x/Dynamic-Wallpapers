import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

final class SystemWallpaperFiles {
    let root: URL
    let item: MediaItem
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("system-wallpaper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("source.png")
        try Data("source version 1".utf8).write(to: file)
        item = MediaItem(url: file, kind: .image, width: 8, height: 6)
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    var content: SystemWallpaperContent { .init(item: item, fit: .fill, width: 8, height: 6) }
    func target(_ display: String = "A", revision: UUID = UUID()) throws -> SystemWallpaperTarget {
        .init(displayID: display, revision: revision, content: content,
              sourceVersion: .success(try SystemWallpaperSourceVersionReader.fingerprint(for: item)))
    }
    var store: SystemWallpaperStore { .init(directory: root.appendingPathComponent("posters")) }
    static func image(width: Int = 8, height: Int = 6, red: CGFloat = 1) throws -> CGImage {
        let colors = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let canvas = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(canvas.makeImage())
    }
}
