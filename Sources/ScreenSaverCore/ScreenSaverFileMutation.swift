import Darwin
import Foundation

extension ScreenSaverFileIO {
    /// Rename at open parent descriptors, not URL paths whose intermediate components can follow symlinks.
    static func move(root: URL, source: String, destination: String, directory: Bool) throws {
        try withParent(root: root, relativePath: source) { from, sourceName in
            try withParent(root: root, relativePath: destination) { to, destinationName in
                let info = try entryInfo(parent: from, name: sourceName)
                guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else {
                    throw ScreenSaverFailure(code: .nonRegularFile(source))
                }
                let result = directory
                    ? renameatx_np(from, sourceName, to, destinationName, UInt32(RENAME_EXCL))
                    : renameat(from, sourceName, to, destinationName)
                guard result == 0 else { throw posix(path: destination) }
            }
        }
    }

    static func removeDirectory(root: URL, relativePath: String, requireEmpty: Bool = false) throws {
        try withParent(root: root, relativePath: relativePath) { parent, name in
            try removeTree(parent: parent, name: name, requireEmpty: requireEmpty)
        }
    }

    private static func removeTree(parent: Int32, name: String, requireEmpty: Bool = false) throws {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(path: name) }
        try closing(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)) { handle in
            var opened = stat()
            guard fstat(handle.fileDescriptor, &opened) == 0 else { throw posix(path: name) }
            let names = try listDirectory(handle.fileDescriptor)
            guard !requireEmpty || names.isEmpty else {
                throw ScreenSaverFailure(code: .leaseFailure(.cleanup))
            }
            // A failed/interrupted deletion must retain the original lease while any content remains.
            for child in names.filter({ $0 != ".lease" }) { try removeEntry(parent: descriptor, name: child) }
            if names.contains(".lease") { try removeEntry(parent: descriptor, name: ".lease") }
            let current = try entryInfo(parent: parent, name: name)
            guard current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw ScreenSaverFailure(code: .identityChanged)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw posix(path: name) }
        }
    }

    private static func removeEntry(parent: Int32, name: String) throws {
        let info = try entryInfo(parent: parent, name: name)
        if info.st_mode & S_IFMT == S_IFDIR {
            try removeTree(parent: parent, name: name)
        } else {
            // unlinkat removes a link itself, never the object it references.
            guard unlinkat(parent, name, 0) == 0 else { throw posix(path: name) }
        }
    }

    private static func withParent<T>(root: URL, relativePath: String, operation: (Int32, String) throws -> T) throws -> T {
        let parts = try ScreenSaverPaths.components(relativePath)
        let parent = parts.dropLast().joined(separator: "/")
        return try withDirectory(root: root, relativePath: parent.isEmpty ? nil : parent) {
            try operation($0, parts.last!)
        }
    }

    private static func entryInfo(parent: Int32, name: String) throws -> stat {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(path: name) }
        return info
    }
}
