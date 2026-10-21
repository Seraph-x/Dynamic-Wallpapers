import Foundation

public actor ScreenSaverSnapshotLease {
    public nonisolated let manifest: ScreenSaverManifest
    public nonisolated let directory: URL
    private var lock: ScreenSaverFileLock?

    init(manifest: ScreenSaverManifest, directory: URL, lock: ScreenSaverFileLock) {
        self.manifest = manifest; self.directory = directory; self.lock = lock
    }

    public func close() throws {
        try lock?.close()
        lock = nil
    }
}
