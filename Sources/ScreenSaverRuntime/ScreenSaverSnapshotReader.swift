import Foundation
import ScreenSaverCore
import WallpaperCore

/// The host creates its own authorization. Each start owns one access object until all readers close.
@MainActor
public protocol ScreenSaverDirectoryAccess: AnyObject {
    var root: URL { get }
    var expectedExportID: UUID? { get }
    func close() throws
}

public struct ScreenSaverSnapshotReader: Sendable {
    private let store: ScreenSaverSnapshotStore

    public init(root: URL, expectedExportID: UUID?) throws {
        store = try ScreenSaverSnapshotStore(root: root, expectedExportID: expectedExportID)
    }

    public func acquire() async throws -> ScreenSaverSnapshotLease {
        guard let lease = try await store.acquireCurrent() else {
            throw ScreenSaverFailure(code: .pointerUnavailable)
        }
        return lease
    }

    static func media(_ file: ScreenSaverMediaFile, directory: URL) -> MediaItem {
        MediaItem(id: file.id, url: directory.appendingPathComponent(file.relativePath), kind: file.kind,
                  width: file.width, height: file.height, duration: file.duration, backend: file.backend)
    }
}
