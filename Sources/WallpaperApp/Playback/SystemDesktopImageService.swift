import AppKit
import WallpaperCore

@MainActor
struct SystemDesktopImageService {
    func setImage(at url: URL, displayID: String) throws {
        guard let screen = NSScreen.screens.first(where: { $0.wallpaperID == displayID }) else {
            throw WallpaperError("目标显示器已断开，无法同步系统底图。")
        }
        // The poster already contains the exact display layout, including fit margins.
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen,
            options: [.imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
                      .allowClipping: false])
    }
}
