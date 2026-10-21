import Foundation
import WallpaperCore

/// Resolves a concrete language without letting Bundle fall back to another translation.
struct HelpDocument: Equatable {
    let language: AppLanguage
    let root: URL
    let url: URL

    init(language: AppLanguage, root: URL, preferredLanguages: [String] = Locale.preferredLanguages) throws {
        self.language = language.resolved(preferredLanguages: preferredLanguages)
        self.root = root.standardizedFileURL
        url = self.root.appendingPathComponent(self.language.rawValue, isDirectory: true)
            .appendingPathComponent("index.html")
        for resource in [url, self.root.appendingPathComponent("help.css"), self.root.appendingPathComponent("help.js")] {
            try Self.requireReadableFile(resource)
        }
    }

    static func bundled(language: AppLanguage, mainBundle: Bundle = .main) throws -> HelpDocument {
        let resources: Bundle
        if mainBundle.bundleURL.pathExtension == "app" {
            // A distributed app must never reach into the developer's SwiftPM build directory.
            guard let url = mainBundle.url(forResource: "DynamicWallpaper_WallpaperApp", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                throw WallpaperError("帮助文档文件缺失或无法读取。", diagnostic: mainBundle.bundleURL.path)
            }
            resources = bundle
        } else {
            resources = .module
        }
        guard let root = resources.resourceURL?.appendingPathComponent("Help", isDirectory: true) else {
            throw WallpaperError("帮助文档文件缺失或无法读取。", diagnostic: resources.bundleURL.path)
        }
        return try HelpDocument(language: language, root: root)
    }

    private static func requireReadableFile(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw WallpaperError("帮助文档文件缺失或无法读取。", diagnostic: url.path)
            }
        } catch let error as WallpaperError {
            throw error
        } catch {
            throw WallpaperError("帮助文档文件缺失或无法读取。", diagnostic: "\(url.path)\n\(error)")
        }
    }
}
