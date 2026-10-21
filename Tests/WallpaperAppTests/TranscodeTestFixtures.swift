import Foundation
import WallpaperCore
@testable import WallpaperApp

@MainActor
enum TranscodeTestFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static var tools: TranscodeTools {
        TranscodeTools(directory: root.appendingPathComponent(".build/dependencies/ffmpeg/install/bin"),
                       diagnosticsDirectory: root.appendingPathComponent(".build/verification/transcode-diagnostics"))
    }

    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func ffmpeg(_ arguments: [String]) async throws {
        let result = try await TranscodeProcess().run(executable: tools.ffmpeg,
            arguments: ["-nostdin", "-hide_banner", "-v", "error", "-n"] + arguments, onLine: { _ in })
        guard result.status == 0 else {
            throw WallpaperError("Fixture ffmpeg exit \(result.status): \(String(decoding: result.stderr, as: UTF8.self))")
        }
    }

    static func frameTimes(_ source: URL) async throws -> [Double] {
        let result = try await TranscodeProcess().run(executable: tools.ffprobe,
            arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries",
                        "frame=best_effort_timestamp_time", "-of", "json", source.path], onLine: { _ in })
        guard result.status == 0 else { throw WallpaperError(String(decoding: result.stderr, as: UTF8.self)) }
        struct Probe: Decodable { let frames: [Frame] }
        struct Frame: Decodable { let best_effort_timestamp_time: String }
        return try JSONDecoder().decode(Probe.self, from: result.stdout).frames.map {
            guard let time = Double($0.best_effort_timestamp_time), time.isFinite else {
                throw WallpaperError("Invalid fixture frame timestamp")
            }
            return time
        }
    }
}
