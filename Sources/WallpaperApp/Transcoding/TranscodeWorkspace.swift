import Darwin
import Foundation
import WallpaperCore

enum TranscodeWorkspace {
    static func withDirectory<T>(in parent: URL, successCleanupMessage: String,
                                 operation: (URL) async throws -> T) async throws -> T {
        let directory = try create(in: parent)
        let result: Result<T, Error>
        do { result = .success(try await operation(directory)) }
        catch { result = .failure(error) }
        // Do not unlink the only complete log, or resources whose close failed.
        // Such failures identify the retained path explicitly to the caller.
        if case .failure(let error) = result, error is TranscodeReleaseError { throw error }
        do { try FileManager.default.removeItem(at: directory) }
        catch {
            let primary: Error?
            if case .failure(let failure) = result { primary = failure } else { primary = nil }
            throw TranscodeCleanupFailure(operation: primary == nil ? successCleanupMessage : "清理临时转码文件失败（\(directory.path)）",
                                          primary: primary, cleanup: error)
        }
        return try result.get()
    }

    private static func create(in parent: URL) throws -> URL {
        var path = Array(parent.appendingPathComponent(".dynamicwallpaper-transcode-XXXXXX").path.utf8CString)
        guard path.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) != nil }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
