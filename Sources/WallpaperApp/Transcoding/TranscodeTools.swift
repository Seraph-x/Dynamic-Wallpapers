import Foundation
import WallpaperCore

struct TranscodeTools: Sendable {
    let directory: URL
    let diagnosticsDirectory: URL
    let temporaryDirectory: URL

    init(directory: URL, diagnosticsDirectory: URL? = nil, temporaryDirectory: URL? = nil) {
        let defaults = diagnosticsDirectory == nil || temporaryDirectory == nil
            ? ApplicationPaths.production(
                bundleIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
            : nil
        self.directory = directory
        self.diagnosticsDirectory = diagnosticsDirectory ?? defaults!.transcodeDiagnostics
        self.temporaryDirectory = temporaryDirectory ?? defaults!.transcodeTemporary
    }

    var ffmpeg: URL { directory.appendingPathComponent("ffmpeg") }
    var ffprobe: URL { directory.appendingPathComponent("ffprobe") }

    static let developmentRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// App bundles exclusively use their own tools. The source-tree path is an
    /// explicit development configuration, never a fallback for an incomplete app.
    static func resolve(bundleURL: URL = Bundle.main.bundleURL,
                        developmentRoot: URL = developmentRoot,
                        diagnosticsDirectory: URL? = nil,
                        temporaryDirectory: URL? = nil) throws -> TranscodeTools {
        let directory = bundleURL.pathExtension.lowercased() == "app"
            ? bundleURL.appendingPathComponent("Contents/Resources/MediaTools", isDirectory: true)
            : developmentRoot.appendingPathComponent(".build/dependencies/ffmpeg/install/bin", isDirectory: true)
        let tools = TranscodeTools(directory: directory, diagnosticsDirectory: diagnosticsDirectory,
            temporaryDirectory: temporaryDirectory)
        for executable in [tools.ffmpeg, tools.ffprobe] {
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw WallpaperError("转码组件不可用，无法开始任务。",
                    diagnostic: "转码工具不可用：\(executable.path)。未使用 PATH 或 Homebrew 替代工具。")
            }
        }
        return tools
    }
}
