import Darwin
import Foundation
import WallpaperCore

/// Pass this open, seekable file through stdin / FFmpeg's fd protocol. Reopening
/// its pathname in the child would reintroduce the probe-to-encode identity race.
final class TranscodeInput {
    let file: FileHandle
    let revision: TranscodeSourceRevision
    private let source: URL
    private var closed = false

    private init(source: URL) throws {
        guard source.isFileURL,
              ["mp4", "mov", "m4v", "mkv", "webm", "avi"].contains(source.pathExtension.lowercased()) else {
            throw WallpaperError("转码输入必须是本地视频文件。")
        }
        let descriptor = source.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { revision = try TranscodeSourceRevision(fileDescriptor: descriptor) }
        catch {
            do { try file.close() }
            catch let cleanup {
                throw TranscodeCleanupFailure(operation: "关闭输入失败", primary: error, cleanup: cleanup,
                                              resource: file, retainedFileURLs: [source])
            }
            throw error
        }
        self.file = file; self.source = source
    }

    static func withFile<T>(source: URL, operation: (TranscodeInput) async throws -> T) async throws -> T {
        let input = try TranscodeInput(source: source)
        let result: Result<T, Error>
        do { result = .success(try await operation(input)) }
        catch { result = .failure(error) }
        do { try input.close() }
        catch {
            let primary: Error?
            if case .failure(let failure) = result { primary = failure } else { primary = nil }
            throw TranscodeCleanupFailure(operation: "关闭输入失败", primary: primary, cleanup: error,
                                          resource: input, retainedFileURLs: [source])
        }
        return try result.get()
    }

    func verifyUnchanged() throws {
        let current = try TranscodeInput(source: source)
        try current.close()
        guard current.revision == revision,
              try TranscodeSourceRevision(fileDescriptor: file.fileDescriptor) == revision else {
            throw WallpaperError("文件在检查或转码期间发生变化，请重新选择并检查。")
        }
    }

    func close() throws {
        guard !closed else { return }
        do { try file.close() }
        catch { throw TranscodeCleanupFailure(operation: "关闭输入失败", cleanup: error, resource: file, retainedFileURLs: [source]) }
        closed = true
    }
}
