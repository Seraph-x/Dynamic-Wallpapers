import AppKit
import AVFoundation
import WallpaperCore

struct MediaInspection {
    let image: NSImage?
    let transcodeReason: String?
}

@MainActor
enum MediaCompatibility {
    typealias Thumbnail = @MainActor @Sendable (MediaItem) async throws -> NSImage?
    typealias ValidateTranscode = @MainActor @Sendable (URL) async throws -> Void

    static func inspect(_ item: MediaItem,
                        thumbnail: Thumbnail = { try await MediaThumbnail.load($0) },
                        validateTranscode: ValidateTranscode = { try await TranscodeCompatibilityProbe.validate($0) }) async throws -> MediaInspection {
        guard item.kind == .video else {
            return MediaInspection(image: try await thumbnail(item), transcodeReason: nil)
        }
        return try await TranscodeInput.withFile(source: item.url) { @Sendable input in
            let playbackError: Error
            do {
                let image = try await thumbnail(item)
                try input.verifyUnchanged()
                return MediaInspection(image: image, transcodeReason: nil)
            } catch let error as MediaProbeCleanupFailure { throw error }
            catch let error as TranscodeReleaseError { throw error }
            catch { playbackError = error }
            try Task.checkCancellation()
            guard let reason = reason(for: playbackError, backend: item.backend) else { throw playbackError }
            try input.verifyUnchanged()
            do { try await validateTranscode(item.url) }
            catch let error as TranscodeReleaseError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch {
                throw WallpaperError("壁纸无法播放，且无法确认转码是否适用。",
                    diagnostic: "播放检查：\(playbackError.localizedDescription)\n转码检查：\(error.localizedDescription)")
            }
            try Task.checkCancellation()
            try input.verifyUnchanged()
            return MediaInspection(image: nil, transcodeReason: reason)
        }
    }

    /// An unknown error stays an error. In particular, MPV's generic log error
    /// also covers hardware/service failures and cannot identify an unsupported codec.
    nonisolated static func reason(for error: Error, backend: MediaBackend) -> String? {
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        while let diagnostic = current, visited.insert(ObjectIdentifier(diagnostic)).inserted {
            if backend == .native, diagnostic.domain == AVFoundationErrorDomain {
                if diagnostic.code == AVError.decoderNotFound.rawValue {
                    return "当前原生播放器不支持此视频编码。"
                }
                if diagnostic.code == AVError.fileFormatNotRecognized.rawValue {
                    return "当前原生播放器不支持此视频封装。"
                }
            }
            // MPV_ERROR_UNKNOWN_FORMAT is a container diagnostic, unlike
            // MPV_ERROR_UNSUPPORTED which also describes unrelated operations.
            if backend == .extended, diagnostic.domain == "DynamicWallpaper.MPV", diagnostic.code == -17 {
                return "当前扩展播放器不支持此视频封装。"
            }
            current = diagnostic.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}
