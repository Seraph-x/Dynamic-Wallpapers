import WallpaperNative
import AppKit
import WallpaperCore

@MainActor
protocol SurfaceMaking {
    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface
}

@MainActor
struct SurfaceFactory: SurfaceMaking {
    private let webPages: (any WebPageMaking)?
    private let scenePages: (any ScenePageMaking)?
    nonisolated init(webPages: (any WebPageMaking)? = nil, scenePages: (any ScenePageMaking)? = nil) {
        self.webPages = webPages; self.scenePages = scenePages
    }
    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
        switch (item.backend, item.kind) {
        case (.native, .image), (.native, .animatedImage), (.native, .video):
            return MediaSurface(size: size, fit: fit)
        case (.extended, .video):
            return MPVSurface(size: size, fit: fit)
        case (.web, .web):
            guard let webPages else { throw WallpaperError("网页运行时未由应用所有者提供。") }
            return WebSurface(size: size, fit: fit, pageFactory: webPages)
        case (.scene, .scene):
            guard let scenePages else { throw WallpaperError("场景运行时未由应用所有者提供。") }
            return SceneSurface(size: size, fit: fit, pageFactory: scenePages)
        default:
            throw WallpaperError("\(item.backend.rawValue) 播放后端尚未接入，无法播放该素材。")
        }
    }
}
