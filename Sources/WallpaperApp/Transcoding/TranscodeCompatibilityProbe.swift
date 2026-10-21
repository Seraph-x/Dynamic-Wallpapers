import Foundation
import WallpaperCore

@MainActor
enum TranscodeCompatibilityProbe {
    static func validate(_ source: URL) async throws {
        let paths = ApplicationPaths.production(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        try await validate(source, tools: TranscodeTools.resolve(
            diagnosticsDirectory: paths.transcodeDiagnostics,
            temporaryDirectory: paths.transcodeTemporary))
    }

    static func validate(_ source: URL, tools: TranscodeTools) async throws {
        let media = try await FFmpegJob.inspect(source: source, tools: tools)
        _ = try TranscodePlan(media: media, preset: .original)
        try await TranscodeInput.withFile(source: source) { @MainActor @Sendable input in
            guard input.revision == media.sourceRevision else {
                throw WallpaperError("视频在兼容性检查期间发生变化，请重新检查。")
            }
            try FileManager.default.createDirectory(at: tools.temporaryDirectory,
                withIntermediateDirectories: true)
            try await TranscodeWorkspace.withDirectory(in: tools.temporaryDirectory,
                successCleanupMessage: "清理兼容性检查临时目录失败") { @MainActor @Sendable staging in
                var arguments = ["-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "fd",
                    "-format_whitelist", "mov,matroska,webm,avi", "-i", "fd:",
                    "-map", "0:\(media.videoIndex)"]
                if let audioIndex = media.audioIndex { arguments += ["-map", "0:\(audioIndex)"] }
                arguments += ["-f", "null", "-"]
                let result = try await TranscodeProcess().run(executable: tools.ffmpeg,
                    arguments: arguments, input: input.file, captureStandardOutput: false,
                    errorLog: staging.appendingPathComponent("compatibility-decode.log"), onLine: { _ in })
                try FFmpegJob.requireSuccess(result, operation: "转码输入完整解码检查", tools: tools)
                try Task.checkCancellation()
                try input.verifyUnchanged()
            }
        }
    }
}
