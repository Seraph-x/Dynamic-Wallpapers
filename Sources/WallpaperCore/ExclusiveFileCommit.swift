import Foundation
import Darwin

/// Atomically publishes a fully written file on the same volume without replacing any directory entry.
/// The caller owns the staging name and must remove it after success or failure.
public enum ExclusiveFileCommit {
    public static func commit(staged: URL, destination: URL) throws {
        guard staged.isFileURL, destination.isFileURL else { throw WallpaperError("提交路径必须是本地文件。") }
        let result = staged.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in link(source!, target!) }
        }
        guard result == 0 else {
            let code = errno
            throw WallpaperError("无法提交 \(destination.lastPathComponent)，未覆盖目标文件：\(String(cString: strerror(code)))。")
        }
    }
}
