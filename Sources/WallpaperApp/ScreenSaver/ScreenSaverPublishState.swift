import Foundation
import ScreenSaverCore
import WallpaperCore

struct ScreenSaverPublishState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case unconfigured, needsConfirmation, pending, publishing, published, failed, sourceInvalid, cancelled }
    var phase: Phase = .unconfigured
    var target: ScreenSaverTarget?
    var projection: ScreenSaverProjection?
    var published: ScreenSaverCurrentPointer?
    var currentVerified = false
    var cleanup: ScreenSaverCleanupResult?
    var failure: ScreenSaverFailure?
}

enum ScreenSaverAppFailure {
    static func capture(_ error: Error, phase: ScreenSaverFailure.Phase) -> ScreenSaverFailure {
        if ScreenSaverPublishFailure.isCleanCancellation(error) {
            return ScreenSaverFailure(code: .cancelled(phase))
        }
        if let publication = error as? ScreenSaverPublishFailure {
            return publication.state.failure ?? capture(publication.underlying, phase: phase)
        }
        if let release = error as? ScreenSaverSourceReleaseFailure {
            return ScreenSaverFailure(code: .resourceReleaseFailed,
                reasons: release.errors.map { capture($0, phase: .release) })
        }
        if let group = error as? WallpaperErrorGroup {
            return ScreenSaverFailure(code: phase == .publish ? .publicationFailed : .resourceReleaseFailed,
                reasons: group.errors.map { capture($0, phase: phase) })
        }
        return ScreenSaverFailure(capturing: error, phase: phase)
    }
}

struct ScreenSaverPublishFailure: LocalizedError {
    let state: ScreenSaverPublishState
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }

    static func isCleanCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? Self { return isCleanCancellation(failure.underlying) }
        if let group = error as? WallpaperErrorGroup { return !group.errors.isEmpty && group.errors.allSatisfy(isCleanCancellation) }
        if let failure = error as? ScreenSaverPublicationFailure {
            return failure.committed == nil && !failure.errors.isEmpty && failure.errors.allSatisfy(isCleanCancellation)
        }
        return false
    }
}

enum ScreenSaverPublishAction: Sendable {
    case publish(library: Library, settings: ScreenSaverSettings, force: Bool)
    case disable(settings: ScreenSaverSettings)

    var settings: ScreenSaverSettings {
        switch self { case .publish(_, let settings, _), .disable(let settings): return settings }
    }

    var mediaIDs: Set<UUID> {
        guard case .publish(let library, let settings, _) = self else { return [] }
        switch settings.source {
        case .media(let id): return [id]
        case .playlist(let id): return Set(library.playlists.first { $0.id == id }?.entries.map(\.mediaID) ?? [])
        case nil: return []
        }
    }
}
