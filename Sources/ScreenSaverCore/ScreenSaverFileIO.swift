import CryptoKit
import Darwin
import Foundation
import WallpaperCore

/// All component traversal is anchored by directory descriptors, without following links below the chosen root.
enum ScreenSaverFileIO {
    static func posix(_ code: Int32 = errno, path: String? = nil) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: path.map { [NSFilePathErrorKey: $0] })
    }

    static func closing<T>(_ handle: FileHandle, operation: (FileHandle) throws -> T) throws -> T {
        let result = Result { try operation(handle) }
        do { try handle.close() }
        catch {
            if case .failure(let original) = result { throw WallpaperErrorGroup([original, error]) }
            throw error
        }
        return try result.get()
    }

    static func withDirectory<T>(root: URL, relativePath: String? = nil, operation: (Int32) throws -> T) throws -> T {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(path: root.path) }
        return try closing(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)) { handle in
            let components = try relativePath.map(ScreenSaverPaths.components) ?? []
            return try descend(handle.fileDescriptor, components: ArraySlice(components), operation: operation)
        }
    }

    private static func descend<T>(_ directory: Int32, components: ArraySlice<String>, operation: (Int32) throws -> T) throws -> T {
        guard let first = components.first else { return try operation(directory) }
        let descriptor = openat(directory, first, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(path: first) }
        return try closing(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)) { handle in
            try descend(handle.fileDescriptor, components: components.dropFirst(), operation: operation)
        }
    }

    static func openRegular(root: URL, relativePath: String, flags: Int32 = O_RDONLY, permissions: mode_t = 0o644) throws -> FileHandle {
        let parts = try ScreenSaverPaths.components(relativePath)
        let parent = parts.dropLast().joined(separator: "/")
        return try withDirectory(root: root, relativePath: parent.isEmpty ? nil : parent) { directory in
            let descriptor = openat(directory, parts.last!, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, permissions)
            guard descriptor >= 0 else { throw posix(path: relativePath) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { throw posix(path: relativePath) }
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                    throw ScreenSaverFailure(code: .nonRegularFile(relativePath))
                }
                return handle
            } catch {
                return try closing(handle) { _ in throw error }
            }
        }
    }

    static func read(root: URL, relativePath: String) throws -> Data {
        try closing(openRegular(root: root, relativePath: relativePath)) { try $0.readToEnd() ?? Data() }
    }

    static func readIfPresent(root: URL, relativePath: String) throws -> Data? {
        do { return try read(root: root, relativePath: relativePath) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
    }

    static func writeNew(_ data: Data, root: URL, relativePath: String) throws {
        try closing(openRegular(root: root, relativePath: relativePath, flags: O_WRONLY | O_CREAT | O_EXCL)) {
            try $0.write(contentsOf: data)
            try $0.synchronize()
        }
    }

    static func makeDirectory(root: URL, relativePath: String, allowExisting: Bool = false) throws {
        let parts = try ScreenSaverPaths.components(relativePath)
        let parent = parts.dropLast().joined(separator: "/")
        try withDirectory(root: root, relativePath: parent.isEmpty ? nil : parent) { directory in
            let result = mkdirat(directory, parts.last!, 0o755)
            let code = errno
            guard result == 0 || (allowExisting && code == EEXIST) else { throw posix(code, path: relativePath) }
            try descend(directory, components: ArraySlice([parts.last!])) { _ in () }
        }
    }

    static func listDirectory(root: URL, relativePath: String? = nil) throws -> [String] {
        try withDirectory(root: root, relativePath: relativePath) { try listDirectory($0) }
    }

    static func listDirectory(_ directory: Int32) throws -> [String] {
        let copied = dup(directory)
        guard copied >= 0 else { throw posix() }
        guard let stream = fdopendir(copied) else {
            let original = posix()
            if Darwin.close(copied) != 0 { throw WallpaperErrorGroup([original, posix()]) }
            throw original
        }
        let result = Result<[String], Error> {
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw posix() }
                    return names.sorted()
                }
                let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                    String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
                }
                if name != "." && name != ".." { names.append(name) }
            }
        }
        if closedir(stream) != 0 {
            let error = posix()
            if case .failure(let original) = result { throw WallpaperErrorGroup([original, error]) }
            throw error
        }
        return try result.get()
    }

    static func synchronizeDirectory(root: URL, relativePath: String? = nil) throws {
        try withDirectory(root: root, relativePath: relativePath) {
            guard fsync($0) == 0 else { throw posix() }
        }
    }

    static func verify(_ files: [ScreenSaverMediaFile], root: URL, directory: String) throws {
        for file in files {
            try Task.checkCancellation()
            try closing(openRegular(root: root, relativePath: directory + "/" + file.relativePath)) { handle in
                let before = try TranscodeSourceRevision(fileDescriptor: handle.fileDescriptor)
                var hash = SHA256()
                var length: Int64 = 0
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: bytes)
                    let (next, overflow) = length.addingReportingOverflow(Int64(bytes.count))
                    guard !overflow else { throw ScreenSaverFailure(code: .copyMismatch(file.relativePath)) }
                    length = next
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard before == (try TranscodeSourceRevision(fileDescriptor: handle.fileDescriptor)),
                      length == file.byteCount, digest == file.sha256 else {
                    throw ScreenSaverFailure(code: .copyMismatch(file.relativePath))
                }
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
