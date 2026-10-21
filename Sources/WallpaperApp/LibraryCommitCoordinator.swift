import Foundation
import WallpaperCore

@MainActor
struct LibraryCommitResult {
    let library: Library
    let removed: [MediaItem]
    let releasing: Task<Void, Error>?
}

@MainActor
struct LibraryCommitCoordinator {
    let save: (Library) throws -> Void
    let validateRemoval: ([MediaItem]) throws -> Void
    let withCommitLock: (@MainActor () throws -> Void) throws -> Void

    func commit(
        current: Library,
        change: (inout Library) throws -> Void,
        beginRelease: (Set<UUID>) -> Task<Void, Error>,
        publish: (Library) -> Void,
        screenSaverDidCommit: (Library, Library) -> Void
    ) throws -> LibraryCommitResult {
        var candidate = current
        try change(&candidate)
        let remainingIDs = Set(candidate.media.map(\.id))
        let removed = current.media.filter { !remainingIDs.contains($0.id) }
        try validateRemoval(removed)
        candidate.pendingMediaDeletions.append(contentsOf: removed.filter { $0.origin != nil })
        var releasing: Task<Void, Error>?
        try withCommitLock {
            try save(candidate)
            releasing = removed.isEmpty ? nil : beginRelease(Set(removed.map(\.id)))
            publish(candidate)
            screenSaverDidCommit(candidate, current)
        }
        return LibraryCommitResult(library: candidate, removed: removed, releasing: releasing)
    }
}
