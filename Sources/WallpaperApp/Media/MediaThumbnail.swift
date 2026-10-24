import WallpaperNative
import AppKit
import AVFoundation
import WallpaperCore

@MainActor
enum MediaThumbnail {
    static func load(_ item: MediaItem) async throws -> NSImage? {
        try await load(item, webPages: nil)
    }

    static func load(_ item: MediaItem, webPages: (any WebPageMaking)?, scenePages: (any ScenePageMaking)? = nil) async throws -> NSImage? {
        if item.kind == .scene {
            guard let scenePages else { throw WallpaperError("场景缩略图需要应用运行时。") }
            return try await sceneThumbnail(item, pages: scenePages)
        }
        if item.kind == .web {
            guard let webPages else { return nil }
            return try await webThumbnail(item, webPages: webPages)
        }
        try Task.checkCancellation()
        let image: CGImage
        if item.backend == .extended, item.kind == .video {
            image = try await ExtendedMediaProbe.thumbnail(item.url)
        } else if item.backend != .native {
            throw WallpaperError("\(item.backend.rawValue) 缩略图后端尚未接入。")
        } else if item.kind == .video {
            image = try await nativeVideo(item.url)
        } else {
            image = try await ImageDecoder(url: item.url, maxPixelSize: 480).frame(at: 0)
        }
        try Task.checkCancellation()
        return NSImage(cgImage: image, size: .zero)
    }

    private static func sceneThumbnail(_ item: MediaItem, pages: any ScenePageMaking) async throws -> NSImage {
        let surface = SceneSurface(size: CGSize(width: 480, height: 270), fit: .fill, pageFactory: pages)
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            guard let contents = surface.subviews.first?.layer?.contents as AnyObject?,
                  CFGetTypeID(contents) == CGImage.typeID else {
                throw WallpaperError("场景没有生成可用的静态缩略图。")
            }
            let image = NSImage(cgImage: contents as! CGImage, size: CGSize(width: 480, height: 270))
            try await surface.close()
            return image
        } catch {
            do { try await surface.close() }
            catch let closeError { throw WallpaperErrorGroup([error, closeError]) }
            throw error
        }
    }

    private static func webThumbnail(_ item: MediaItem, webPages: any WebPageMaking) async throws -> NSImage {
        let surface = WebSurface(size: CGSize(width: 480, height: 270), fit: .fill, pageFactory: webPages)
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            let frame = try await settledWebFrame(currentFrame: { try webFrame(in: surface) },
                waitForNextSample: { try await Task.sleep(for: .milliseconds(34)) })
            let image = NSImage(cgImage: frame, size: CGSize(width: 480, height: 270))
            try await surface.close()
            return image
        } catch {
            do { try await surface.close() }
            catch let closeError { throw WallpaperErrorGroup([error, closeError]) }
            throw error
        }
    }

    /// Web readiness guarantees a displayable first paint, not that delayed local
    /// image decoding and startup animation have reached a representative frame.
    static func settledWebFrame(requiredChanges: Int = 18, maximumSamples: Int = 36,
                                currentFrame: () throws -> CGImage,
                                waitForNextSample: () async throws -> Void) async throws -> CGImage {
        precondition(requiredChanges > 0 && maximumSamples >= requiredChanges)
        var latest = try currentFrame()
        var changes = 0
        for _ in 0..<maximumSamples {
            try Task.checkCancellation()
            try await waitForNextSample()
            let candidate = try currentFrame()
            guard candidate !== latest else { continue }
            latest = candidate
            changes += 1
            if changes == requiredChanges { break }
        }
        return latest
    }

    private static func webFrame(in surface: WebSurface) throws -> CGImage {
        guard let content = surface.subviews.first,
              let contents = content.layer?.contents as AnyObject?,
              CFGetTypeID(contents) == CGImage.typeID else {
            throw WallpaperError("网页项目已加载，但没有生成可用的静态缩略图。")
        }
        return contents as! CGImage
    }

    private static func nativeVideo(_ url: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        if try await asset.load(.hasProtectedContent) {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.contentIsProtected.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: "视频包含受保护内容，不能生成预览。"])
        }
        // Match AVAssetImageGenerator's first enabled track, not a disabled
        // auxiliary track that the actual thumbnail/playback path would ignore.
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard try await track.load(.isEnabled) else { continue }
            if try await track.load(.isDecodable) == false {
                throw NSError(domain: AVFoundationErrorDomain, code: AVError.decoderNotFound.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "当前原生播放器不支持此视频轨道的编码。"])
            }
            break
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 300)
        return try await generator.image(at: .zero).image
    }
}
