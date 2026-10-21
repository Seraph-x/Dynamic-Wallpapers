import Darwin
import Foundation
import OSLog
import WallpaperCore

public enum ScreenSaverFileLockError: LocalizedError, Equatable, Sendable {
    case busy
    public var errorDescription: String? { "屏保文件锁正忙；当前读者或发布者仍持有资源。" }
}

/// Every acquisition opens a new file description; closing one object never unlocks another reader.
public final class ScreenSaverFileLock: @unchecked Sendable {
    public enum Mode: Sendable { case shared, exclusive }
    private let stateLock = NSLock()
    private var handle: FileHandle?
    private init(handle: FileHandle) { self.handle = handle }

    public static func acquire(root: URL, relativePath: String, mode: Mode, nonBlocking: Bool,
                               createIfMissing: Bool = false) throws -> ScreenSaverFileLock {
        let paths = try ScreenSaverPaths(root: root)
        let handle = try ScreenSaverFileIO.openRegular(root: paths.root, relativePath: relativePath,
                                                       flags: createIfMissing ? O_RDWR | O_CREAT : O_RDONLY)
        do {
            let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | (nonBlocking ? LOCK_NB : 0)
            guard flock(handle.fileDescriptor, operation) == 0 else {
                let code = errno
                if code == EWOULDBLOCK { throw ScreenSaverFileLockError.busy }
                throw ScreenSaverFileIO.posix(code, path: relativePath)
            }
            return ScreenSaverFileLock(handle: handle)
        } catch {
            return try ScreenSaverFileIO.closing(handle) { _ in throw error }
        }
    }

    public func close() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let handle else { return }
        try handle.close()
        self.handle = nil
    }

    public func using<T>(_ operation: () throws -> T) throws -> T {
        let result = Result { try operation() }
        do { try close() }
        catch {
            if case .failure(let original) = result { throw WallpaperErrorGroup([original, error]) }
            throw error
        }
        return try result.get()
    }

    deinit {
        do { try close() }
        catch { Logger(subsystem: "local.dynamicwallpaper.screensaver", category: "lease").error("Lease close failed: \(error.localizedDescription, privacy: .public)") }
    }
}
