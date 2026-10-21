import Darwin
import Foundation
import WallpaperCore

/// Disk work is isolated from the main actor. Catalog critical sections never suspend or decode media.
public actor ScreenSaverSnapshotStore {
    public nonisolated let paths: ScreenSaverPaths
    private let operations: ScreenSaverStoreOperations
    private let owner = UUID()
    private var exportID: UUID?
    private var publication: (stage: ScreenSaverStagingGeneration, lock: ScreenSaverFileLock)?

    public init(root: URL, expectedExportID: UUID? = nil, operations: ScreenSaverStoreOperations = .system) throws {
        paths = try ScreenSaverPaths(root: root)
        exportID = expectedExportID
        self.operations = operations
    }

    /// Only the application writer initializes an export. Readers never create or repair files.
    public func initialize() throws -> ScreenSaverExportIdentity {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let writer = try ScreenSaverFileLock.acquire(root: paths.root, relativePath: ".publication.lock",
            mode: .exclusive, nonBlocking: true, createIfMissing: true)
        return try writer.using {
            let catalog = try ScreenSaverFileLock.acquire(root: paths.root, relativePath: ".catalog.lock",
                mode: .exclusive, nonBlocking: false, createIfMissing: true)
            return try catalog.using {
                try ScreenSaverFileIO.makeDirectory(root: paths.root, relativePath: "staging", allowExisting: true)
                try ScreenSaverFileIO.makeDirectory(root: paths.root, relativePath: "generations", allowExisting: true)
                if let bytes = try ScreenSaverFileIO.readIfPresent(root: paths.root, relativePath: "export.json") {
                    return try acceptIdentity(JSONDecoder().decode(ScreenSaverExportIdentity.self, from: bytes))
                }
                let names = try managedEntries()
                let scaffold: Set<String> = [".publication.lock", ".catalog.lock", "staging", "generations"]
                guard exportID == nil, Set(names).isSubset(of: scaffold),
                      try managedEntries(in: "staging").isEmpty,
                      try managedEntries(in: "generations").isEmpty else {
                    throw ScreenSaverFailure(code: .identityMissing)
                }
                let identity = ScreenSaverExportIdentity()
                try ScreenSaverFileIO.writeNew(ScreenSaverFileIO.encode(identity), root: paths.root, relativePath: "export.json")
                try ScreenSaverFileIO.synchronizeDirectory(root: paths.root)
                return try acceptIdentity(identity)
            }
        }
    }

    public func current() throws -> ScreenSaverCurrentPointer? {
        try catalogLock(.shared).using { try readCurrent(identity: readIdentity()) }
    }

    public func acquireCurrent() throws -> ScreenSaverSnapshotLease? {
        let selected = try catalogLock(.shared).using { () -> (ScreenSaverCurrentPointer, ScreenSaverFileLock)? in
            guard let pointer = try readCurrent(identity: readIdentity()), let id = pointer.generationID else { return nil }
            let lease = try ScreenSaverFileLock.acquire(root: paths.root,
                relativePath: "generations/\(id.uuidString)/.lease", mode: .shared, nonBlocking: true)
            return (pointer, lease)
        }
        guard let (pointer, lock) = selected, let id = pointer.generationID else { return nil }
        do {
            let relative = "generations/\(id.uuidString)"
            let manifest = try JSONDecoder().decode(ScreenSaverManifest.self,
                from: ScreenSaverFileIO.read(root: paths.root, relativePath: relative + "/manifest.json"))
            guard manifest.generationID == id, manifest.sourceRevision == pointer.sourceRevision else {
                throw ScreenSaverFailure(code: .integrityMismatch("current.json"))
            }
            try ScreenSaverFileIO.verify(manifest.files, root: paths.root, directory: relative)
            return ScreenSaverSnapshotLease(manifest: manifest, directory: paths.generation(id), lock: lock)
        } catch {
            return try lock.using { throw error }
        }
    }

    public func beginPublication() throws -> ScreenSaverStagingGeneration {
        guard publication == nil else { throw ScreenSaverFileLockError.busy }
        let lock = try ScreenSaverFileLock.acquire(root: paths.root, relativePath: ".publication.lock",
                                                 mode: .exclusive, nonBlocking: true)
        let id = UUID()
        let stage = ScreenSaverStagingGeneration(id: id, directory: paths.staging.appendingPathComponent(id.uuidString), owner: owner)
        publication = (stage, lock)
        do {
            _ = try readIdentity()
            try Task.checkCancellation()
            let relative = stagingPath(stage)
            try ScreenSaverFileIO.makeDirectory(root: paths.root, relativePath: relative)
            try ScreenSaverFileIO.makeDirectory(root: paths.root, relativePath: relative + "/media")
            try ScreenSaverFileIO.writeNew(Data(), root: paths.root, relativePath: relative + "/.lease")
            return stage
        } catch {
            let original = error
            do { try finishPublication(stage) }
            catch { throw WallpaperErrorGroup([original, error]) }
            throw original
        }
    }

    public func commit(_ stage: ScreenSaverStagingGeneration, manifest: ScreenSaverManifest,
                       settingsRevision: UUID,
                       validateTarget: @Sendable () throws -> Void = {}) throws -> ScreenSaverCurrentPointer {
        try requirePublication(stage)
        var committed: ScreenSaverCurrentPointer?
        let result = Result<ScreenSaverCurrentPointer, Error> {
            guard manifest.generationID == stage.id else {
                throw ScreenSaverFailure(code: .transactionConflict(.commit))
            }
            try manifest.validate()
            let relative = stagingPath(stage)
            try ScreenSaverFileIO.verify(manifest.files, root: paths.root, directory: relative)
            let identity = try readIdentity()
            let pointer = ScreenSaverCurrentPointer(exportID: identity.id, generationID: stage.id,
                sourceRevision: manifest.sourceRevision, settingsRevision: settingsRevision)
            try ScreenSaverFileIO.writeNew(ScreenSaverFileIO.encode(manifest), root: paths.root, relativePath: relative + "/manifest.json")
            try preparePointer(pointer, directory: relative)
            return try catalogLock(.exclusive).using {
                _ = try readCurrent(identity: readIdentity())
                try Task.checkCancellation()
                try validateTarget()
                let lease = try ScreenSaverFileLock.acquire(root: paths.root, relativePath: relative + "/.lease",
                                                           mode: .exclusive, nonBlocking: true)
                return try lease.using {
                    // Registration and the pointer switch are one catalog transaction: GC cannot interleave.
                    try operations.registerGeneration(paths.root, stage.id)
                    try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: "generations")
                    try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: "staging")
                    try replacePointer(from: "generations/\(stage.id.uuidString)", pointer: pointer, committed: &committed)
                    return pointer
                }
            }
        }
        return try finish(result, stage: stage, committed: committed)
    }

    public func abort(_ stage: ScreenSaverStagingGeneration) throws {
        try requirePublication(stage)
        try finishPublication(stage)
    }

    public func disable(
        settingsRevision: UUID, validateTarget: @Sendable () throws -> Void = {}
    ) throws -> ScreenSaverCurrentPointer {
        let stage = try beginPublication()
        var committed: ScreenSaverCurrentPointer?
        let result = Result<ScreenSaverCurrentPointer, Error> {
            let pointer = ScreenSaverCurrentPointer(exportID: try readIdentity().id, generationID: nil,
                sourceRevision: nil, settingsRevision: settingsRevision)
            try preparePointer(pointer, directory: stagingPath(stage))
            return try catalogLock(.exclusive).using {
                _ = try readCurrent(identity: readIdentity())
                try Task.checkCancellation()
                try validateTarget()
                try replacePointer(from: stagingPath(stage), pointer: pointer, committed: &committed)
                return pointer
            }
        }
        return try finish(result, stage: stage, committed: committed)
    }

    public func collectGarbage() throws -> ScreenSaverCleanupResult {
        try catalogLock(.exclusive).using {
            let currentID = try readCurrent(identity: readIdentity())?.generationID
            var removed: [UUID] = []
            var retained: [UUID] = []
            for id in try generationIDs(in: "generations") where id != currentID {
                let lock: ScreenSaverFileLock
                do {
                    lock = try ScreenSaverFileLock.acquire(root: paths.root,
                        relativePath: "generations/\(id.uuidString)/.lease", mode: .exclusive, nonBlocking: true)
                } catch ScreenSaverFileLockError.busy {
                    retained.append(id)
                    continue
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                    // A crash after the last .lease unlink can leave an empty directory. Never recreate a
                    // missing lock or recursively delete without a lease; rmdir still rejects new contents.
                    try ScreenSaverFileIO.removeDirectory(root: paths.root, relativePath: "generations/\(id.uuidString)", requireEmpty: true)
                    removed.append(id)
                    try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: "generations")
                    continue
                }
                try lock.using {
                    try operations.removeDirectory(paths.root, "generations/\(id.uuidString)")
                    removed.append(id)
                    try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: "generations")
                }
            }
            return ScreenSaverCleanupResult(removed: removed, retained: retained)
        }
    }

    public func recoverStaging() throws -> [UUID] {
        let lock = try ScreenSaverFileLock.acquire(root: paths.root, relativePath: ".publication.lock",
                                                 mode: .exclusive, nonBlocking: true)
        return try lock.using {
            _ = try readIdentity()
            let ids = try generationIDs(in: "staging")
            for id in ids { try removeStaging(id) }
            return ids
        }
    }

    private func catalogLock(_ mode: ScreenSaverFileLock.Mode) throws -> ScreenSaverFileLock {
        try ScreenSaverFileLock.acquire(root: paths.root, relativePath: ".catalog.lock", mode: mode, nonBlocking: false)
    }

    private func acceptIdentity(_ identity: ScreenSaverExportIdentity) throws -> ScreenSaverExportIdentity {
        guard exportID == nil || exportID == identity.id else {
            throw ScreenSaverFailure(code: .identityChanged)
        }
        exportID = identity.id
        return identity
    }

    private func readIdentity() throws -> ScreenSaverExportIdentity {
        try acceptIdentity(JSONDecoder().decode(ScreenSaverExportIdentity.self,
            from: ScreenSaverFileIO.read(root: paths.root, relativePath: "export.json")))
    }

    private func readCurrent(identity: ScreenSaverExportIdentity) throws -> ScreenSaverCurrentPointer? {
        guard let bytes = try ScreenSaverFileIO.readIfPresent(root: paths.root, relativePath: "current.json") else { return nil }
        let pointer = try JSONDecoder().decode(ScreenSaverCurrentPointer.self, from: bytes)
        guard pointer.exportID == identity.id else { throw ScreenSaverFailure(code: .identityChanged) }
        return pointer
    }

    private func requirePublication(_ stage: ScreenSaverStagingGeneration) throws {
        guard stage.owner == owner, publication?.stage == stage else {
            throw ScreenSaverFailure(code: .transactionConflict(.publish))
        }
    }

    private func stagingPath(_ stage: ScreenSaverStagingGeneration) -> String { "staging/\(stage.id.uuidString)" }

    private func preparePointer(_ pointer: ScreenSaverCurrentPointer, directory: String) throws {
        try pointer.validate()
        try ScreenSaverFileIO.writeNew(ScreenSaverFileIO.encode(pointer), root: paths.root, relativePath: directory + "/.next-current.json")
        try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: directory + "/media")
        try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: directory)
    }

    private func replacePointer(from directory: String, pointer: ScreenSaverCurrentPointer,
                                committed: inout ScreenSaverCurrentPointer?) throws {
        do { try operations.replacePointer(paths.root, directory + "/.next-current.json") }
        catch {
            let original = error
            do {
                if try readCurrent(identity: readIdentity()) == pointer { committed = pointer }
            } catch { throw WallpaperErrorGroup([original, error]) }
            throw original
        }
        committed = pointer
        try ScreenSaverFileIO.synchronizeDirectory(root: paths.root)
    }

    private func finish<T>(_ result: Result<T, Error>, stage: ScreenSaverStagingGeneration,
                           committed: ScreenSaverCurrentPointer?) throws -> T {
        var errors: [Error] = []
        if case .failure(let error) = result { errors.append(error) }
        do { try finishPublication(stage) }
        catch { errors.append(error) }
        if !errors.isEmpty { throw ScreenSaverPublicationFailure(committed: committed, errors: errors) }
        return try result.get()
    }

    private func finishPublication(_ stage: ScreenSaverStagingGeneration) throws {
        guard let active = publication, active.stage == stage else {
            throw ScreenSaverFailure(code: .transactionConflict(.release))
        }
        var errors: [Error] = []
        do {
            if try ScreenSaverFileIO.listDirectory(root: paths.root, relativePath: "staging").contains(stage.id.uuidString) {
                try removeStaging(stage.id)
            }
        } catch { errors.append(error) }
        do {
            try active.lock.close()
            publication = nil
        } catch { errors.append(error) }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
    }

    private func generationIDs(in directory: String) throws -> [UUID] {
        try managedEntries(in: directory).map { name in
            guard let id = UUID(uuidString: name), id.uuidString == name else {
                throw ScreenSaverFailure(code: .invalidPath(name))
            }
            try ScreenSaverFileIO.withDirectory(root: paths.root, relativePath: directory + "/" + name) { _ in () }
            return id
        }
    }

    /// Finder may create this inert metadata file when the export is inspected in Finder.
    /// Every other unmanaged entry remains an error so damaged or foreign data stays visible.
    private func managedEntries(in directory: String? = nil) throws -> [String] {
        try ScreenSaverFileIO.listDirectory(root: paths.root, relativePath: directory)
            .filter { $0 != ".DS_Store" }
    }

    private func removeStaging(_ id: UUID) throws {
        try ScreenSaverFileIO.withDirectory(root: paths.root, relativePath: "staging/\(id.uuidString)") { _ in () }
        try operations.removeDirectory(paths.root, "staging/\(id.uuidString)")
        try ScreenSaverFileIO.synchronizeDirectory(root: paths.root, relativePath: "staging")
    }
}
