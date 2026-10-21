import Foundation
import WallpaperCore

struct WebRuntimePaths {
    let framework: URL
    let helper: URL

    /// Packaged apps use only bundled files. Command-line development explicitly
    /// uses its dedicated helper bundle, never the verification harness bundle.
    static func resolve(bundleURL: URL = Bundle.main.bundleURL,
                        developmentRoot: URL = TranscodeTools.developmentRoot) -> WebRuntimePaths {
        let application = bundleURL.pathExtension.lowercased() == "app" ? bundleURL
            : developmentRoot.appendingPathComponent(".build/dependencies/cef/DynamicWallpaperCEF.app")
        let frameworks = application.appendingPathComponent("Contents/Frameworks")
        return WebRuntimePaths(framework: frameworks.appendingPathComponent("Chromium Embedded Framework.framework"),
            helper: frameworks.appendingPathComponent("DynamicWallpaper Helper.app/Contents/MacOS/DynamicWallpaper Helper"))
    }

    func validate() throws {
        for executable in [framework.appendingPathComponent("Chromium Embedded Framework"), helper] {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw WallpaperError("网页播放组件不可用。", diagnostic: "无法使用网页运行组件：\(executable.path)")
            }
        }
    }
}
