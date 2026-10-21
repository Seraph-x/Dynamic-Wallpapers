import Darwin
import Foundation
import WallpaperCore

/// Narrow application-side access to the same no-follow file primitives used by snapshot readers.
/// Synchronous operations belong on an I/O executor, never the main actor.
public enum ScreenSaverFileAccess {
    public static func readDocument(at url: URL) throws -> Data? {
        let location = try location(url)
        return try ScreenSaverFileIO.readIfPresent(root: location.root, relativePath: location.name)
    }

    public static func openSource(at url: URL) throws -> FileHandle {
        let location = try location(url)
        return try ScreenSaverFileIO.openRegular(root: location.root, relativePath: location.name)
    }

    public static func createFile(root: URL, relativePath: String) throws -> FileHandle {
        try ScreenSaverFileIO.openRegular(root: ScreenSaverPaths(root: root).root, relativePath: relativePath,
                                          flags: O_WRONLY | O_CREAT | O_EXCL)
    }

    public static func openFile(root: URL, relativePath: String) throws -> FileHandle {
        try ScreenSaverFileIO.openRegular(root: ScreenSaverPaths(root: root).root, relativePath: relativePath)
    }

    public static func replaceDocument(_ bytes: Data, at url: URL) throws {
        let location = try location(url)
        try FileManager.default.createDirectory(at: location.root, withIntermediateDirectories: true)
        // Reject an existing non-regular destination rather than silently replacing its link or device.
        _ = try ScreenSaverFileIO.readIfPresent(root: location.root, relativePath: location.name)
        let temporary = ".\(location.name).\(UUID().uuidString).tmp"
        var renamed = false
        do {
            try ScreenSaverFileIO.writeNew(bytes, root: location.root, relativePath: temporary)
            try ScreenSaverFileIO.move(root: location.root, source: temporary, destination: location.name, directory: false)
            renamed = true
            try ScreenSaverFileIO.synchronizeDirectory(root: location.root)
        } catch {
            let original = error
            if !renamed {
                do { try removeTemporary(root: location.root, name: temporary) }
                catch { throw WallpaperErrorGroup([original, error]) }
            }
            // Once rename succeeds, a later sync failure must not be described as rollback.
            if renamed {
                throw ScreenSaverFailure(code: .committedThenFailed,
                    reasons: [ScreenSaverFailure(capturing: original, phase: .commit)])
            }
            throw original
        }
    }

    private static func location(_ url: URL) throws -> (root: URL, name: String) {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0"), !url.hasDirectoryPath else {
            throw ScreenSaverFailure(code: .invalidPath(url.path))
        }
        let name = url.lastPathComponent
        guard try ScreenSaverPaths.components(name).count == 1 else {
            throw ScreenSaverFailure(code: .invalidPath(name))
        }
        return (try ScreenSaverPaths(root: url.deletingLastPathComponent()).root, name)
    }

    private static func removeTemporary(root: URL, name: String) throws {
        try ScreenSaverFileIO.withDirectory(root: root) { descriptor in
            guard unlinkat(descriptor, name, 0) == 0 else {
                if errno == ENOENT { return }
                throw ScreenSaverFileIO.posix(path: name)
            }
        }
    }
}
