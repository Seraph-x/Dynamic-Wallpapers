import WallpaperNative
import Foundation

/// Retain an uncertain surface and the original operation failure until the
/// application has observed the unsuccessful release, including after a view exits.
final class MediaProbeCleanupFailure: LocalizedError {
    let surface: any PlaybackSurface
    let primary: Error?
    let cleanup: Error

    init(surface: any PlaybackSurface, primary: Error?, cleanup: Error) {
        self.surface = surface; self.primary = primary; self.cleanup = cleanup
    }

    var errorDescription: String? {
        let message = "释放媒体检查播放器失败：\(cleanup.localizedDescription)"
        return primary.map { "\($0.localizedDescription)；\(message)" } ?? message
    }
}

@MainActor
enum MediaProbeCleanup {
    static func withSurface<T>(_ surface: any PlaybackSurface, operation: () async throws -> T) async throws -> T {
        let result: Result<T, Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        do { try await surface.close() }
        catch {
            let primary: Error?
            if case .failure(let failure) = result { primary = failure } else { primary = nil }
            throw MediaProbeCleanupFailure(surface: surface, primary: primary, cleanup: error)
        }
        let value = try result.get()
        try Task.checkCancellation()
        return value
    }
}
