import Darwin
import Foundation

public struct ScreenSaverStagingGeneration: Equatable, Sendable {
    public let id: UUID
    public let directory: URL
    let owner: UUID
}

public struct ScreenSaverCleanupResult: Equatable, Sendable {
    public let removed: [UUID]
    public let retained: [UUID]
}

/// Filesystem boundaries for deterministic failure/crash tests. Production always uses the real system operations.
public struct ScreenSaverStoreOperations: Sendable {
    public var registerGeneration: @Sendable (_ root: URL, _ generationID: UUID) throws -> Void
    public var replacePointer: @Sendable (_ root: URL, _ sourceRelativePath: String) throws -> Void
    public var removeDirectory: @Sendable (_ root: URL, _ relativePath: String) throws -> Void

    public static var system: Self {
        Self(registerGeneration: { root, id in
            try ScreenSaverFileIO.move(root: root, source: "staging/\(id.uuidString)",
                                       destination: "generations/\(id.uuidString)", directory: true)
        }, replacePointer: { root, source in
            try ScreenSaverFileIO.move(root: root, source: source, destination: "current.json", directory: false)
        }, removeDirectory: { root, relative in
            try ScreenSaverFileIO.removeDirectory(root: root, relativePath: relative)
        })
    }
}

public struct ScreenSaverPublicationFailure: LocalizedError {
    /// Non-nil means the new pointer is already the visible committed-state fact; callers must not claim rollback.
    public let committed: ScreenSaverCurrentPointer?
    public let errors: [Error]
    public let failure: ScreenSaverFailure

    public init(committed: ScreenSaverCurrentPointer?, errors: [Error]) {
        self.committed = committed
        self.errors = errors
        let code: ScreenSaverFailure.Code = committed == nil ? .publicationFailed : .committedThenFailed
        failure = ScreenSaverFailure(code: code,
            reasons: errors.map { ScreenSaverFailure(capturing: $0) })
    }

    public var errorDescription: String? { failure.errorDescription }
}
