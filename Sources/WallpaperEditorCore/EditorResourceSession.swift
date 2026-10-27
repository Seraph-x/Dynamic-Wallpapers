import Darwin
import Foundation
import WallpaperCore

/// Retain across staging, history, save and capture. Release only after authoring and pending work end.
/// The OS releases this shared lease after a crash; no process registry or expiry is involved.
public final class EditorResourceSession: @unchecked Sendable {
    public let projectID: UUID
    let directory: URL
    private let descriptor: Int32
    private let projectDescriptor: Int32

    init(directory: URL, id: UUID) throws {
        self.directory = directory; projectID = id
        let files = EditorProjectFiles(root: directory, prefix: id.uuidString)
        let descriptors = try files.withDirectory { parent -> (Int32, Int32) in
            let lease = try EditorProjectFiles.openLock(".resource-session-lock", parent: parent)
            do {
                guard flock(lease, LOCK_SH) == 0 else { throw EditorProjectFiles.failure("锁定工程资源会话") }
                try EditorProjectFiles.validateLock(lease, name: ".resource-session-lock", parent: parent)
                let project = fcntl(parent, F_DUPFD_CLOEXEC, 0)
                guard project >= 0 else { throw EditorProjectFiles.failure("保留工程目录") }
                return (lease, project)
            } catch { close(lease); throw error }
        }
        descriptor = descriptors.0; projectDescriptor = descriptors.1
    }

    func validate(directory: URL, id: UUID) throws {
        guard self.directory == directory, projectID == id else { throw WallpaperError("资源会话与工程不符。") }
        try EditorProjectFiles(root: directory, prefix: id.uuidString).withDirectory { current in
            var original = stat(), actual = stat()
            guard fstat(projectDescriptor, &original) == 0, fstat(current, &actual) == 0,
                  original.st_dev == actual.st_dev, original.st_ino == actual.st_ino else { throw WallpaperError("资源会话的工程目录已改变。") }
            try EditorProjectFiles.validateLock(descriptor, name: ".resource-session-lock", parent: current)
        }
    }

    deinit {
        if close(descriptor) != 0 { fputs("Editor resource lease close failed: \(String(cString: strerror(errno)))\n", stderr) }
        if close(projectDescriptor) != 0 { fputs("Editor project descriptor close failed: \(String(cString: strerror(errno)))\n", stderr) }
    }
}

extension EditorProjectStore {
    public func acquireResourceSession(id: UUID) throws -> EditorResourceSession {
        let session = try EditorResourceSession(directory: directory, id: id)
        defer { withExtendedLifetime(session) {} }
        _ = try workspaceDocument(id: id)
        return session
    }
}
