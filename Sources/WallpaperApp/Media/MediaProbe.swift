import Foundation
import WallpaperCore
import WallpaperNative

enum MediaProbe {
    static let fileExtensions = NativeMediaProbe.fileExtensions + ExtendedMediaProbe.fileExtensions

    static func inspect(_ url: URL) async throws -> MediaItem {
        if ExtendedMediaProbe.fileExtensions.contains(url.pathExtension.lowercased()) {
            guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
                throw WallpaperError("无法读取“\(url.lastPathComponent)”，请检查文件位置、读取权限和磁盘连接。")
            }
            try Task.checkCancellation()
            return try await ExtendedMediaProbe.inspect(url)
        }
        return try await NativeMediaProbe.inspect(url)
    }
}
