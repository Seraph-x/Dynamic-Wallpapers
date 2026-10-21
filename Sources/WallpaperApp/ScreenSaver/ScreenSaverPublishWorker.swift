import Foundation
import ScreenSaverCore
import WallpaperCore

/// One publisher invokes this worker serially. Independent workers arbitrate through persistent CAS and file locks.
actor ScreenSaverPublishWorker {
    private let store: ScreenSaverSnapshotStore
    private let settingsStore: ScreenSaverSettingsStore
    private let builder: ScreenSaverExportBuilder
    private var state = ScreenSaverPublishState()

    init(store: ScreenSaverSnapshotStore, settingsStore: ScreenSaverSettingsStore, builder: ScreenSaverExportBuilder) {
        self.store = store; self.settingsStore = settingsStore; self.builder = builder
    }

    func load() async throws -> ScreenSaverPublishState {
        state.target = try await settingsStore.load()
        state.published = try await store.current()
        state.currentVerified = true
        state.failure = nil
        state.phase = state.target?.settings.source == nil && state.published?.generationID == nil
            ? .unconfigured : .pending
        if let target = state.target, state.published?.generationID != nil,
           state.published?.settingsRevision == target.revision { state.phase = .published }
        return state
    }

    func run(_ action: ScreenSaverPublishAction,
             report: @MainActor @Sendable (ScreenSaverPublishState) -> Void) async throws -> ScreenSaverPublishState {
        do {
            state.failure = nil
            try Task.checkCancellation()
            let projection = Result { try Self.project(action) }
            state.projection = try? projection.get()
            let revision = try state.projection.map { try ScreenSaverSourceRevision(projection: $0, settings: action.settings) }
            let target = try await settingsStore.save(action.settings, sourceRevision: revision, replacing: state.target?.revision)
            state.target = target
            try Task.checkCancellation()
            let selected = try projection.get()
            if case .disable = action {
                let pointer = try await store.disable(settingsRevision: target.revision) {
                    try self.settingsStore.validateForCommit(target)
                }
                return try await finish(pointer)
            }
            guard let selected else {
                state.phase = .unconfigured
                state.published = try await store.current()
                state.currentVerified = true
                return state
            }
            try selected.validateForPublication(consent: target.settings.consent)
            state.phase = .publishing
            await report(state)
            if case .publish(_, _, let force) = action, !force,
               let current = try await store.current(), current.generationID != nil,
               current.settingsRevision == target.revision, current.sourceRevision == revision {
                return try await finish(current)
            }
            _ = try await store.recoverStaging()
            let pointer = try await publish(selected, target: target)
            return try await finish(pointer)
        } catch {
            throw await diagnose(error)
        }
    }

    private static func project(_ action: ScreenSaverPublishAction) throws -> ScreenSaverProjection? {
        try action.settings.validate()
        guard case .publish(let library, let settings, _) = action, let source = settings.source else { return nil }
        return try ScreenSaverProjection(library: library, source: source)
    }

    private func publish(_ projection: ScreenSaverProjection, target: ScreenSaverTarget) async throws -> ScreenSaverCurrentPointer {
        let stage = try await store.beginPublication()
        let manifest: ScreenSaverManifest
        do {
            manifest = try await builder.build(projection: projection, settings: target.settings, stage: stage, exportRoot: store.paths.root)
            try Task.checkCancellation()
        } catch {
            let original = error
            do { try await store.abort(stage) }
            catch { throw WallpaperErrorGroup([original, error]) }
            throw original
        }
        // commit owns transaction cleanup on both success and failure; do not abort it a second time.
        return try await store.commit(stage, manifest: manifest, settingsRevision: target.revision) {
            try self.settingsStore.validateForCommit(target)
        }
    }

    private func finish(_ pointer: ScreenSaverCurrentPointer) async throws -> ScreenSaverPublishState {
        state.published = pointer
        state.currentVerified = true
        do {
            try await settingsStore.recordPublication(pointer)
            state.cleanup = try await store.collectGarbage()
        } catch {
            throw ScreenSaverPublicationFailure(committed: pointer, errors: [error])
        }
        state.phase = pointer.generationID == nil ? .unconfigured : .published
        state.failure = nil
        return state
    }

    private func diagnose(_ error: Error) async -> ScreenSaverPublishFailure {
        var errors: [Error] = [error]
        var reasons = [ScreenSaverAppFailure.capture(error, phase: .publish)]
        do { state.target = try await settingsStore.load() }
        catch {
            state.target = nil
            errors.append(error)
            reasons.append(ScreenSaverFailure(code: .settingsUnavailable,
                reasons: [ScreenSaverAppFailure.capture(error, phase: .load)]))
        }
        if let failure = error as? ScreenSaverPublicationFailure, let committed = failure.committed {
            // The transaction witnessed this commit even if a subsequent read is unavailable.
            state.published = committed
            state.currentVerified = false
        }
        do {
            state.published = try await store.current()
            state.currentVerified = true
        } catch {
            state.currentVerified = false
            errors.append(error)
            reasons.append(ScreenSaverFailure(code: .pointerUnavailable,
                reasons: [ScreenSaverAppFailure.capture(error, phase: .load)]))
        }
        if error as? ScreenSaverProjectionError == .confirmationRequired { state.phase = .needsConfirmation }
        else if error is ScreenSaverProjectionError { state.phase = .sourceInvalid }
        else if ScreenSaverPublishFailure.isCleanCancellation(error) { state.phase = .cancelled }
        else { state.phase = .failed }
        let failure: Error = errors.count == 1 ? errors[0] : WallpaperErrorGroup(errors)
        state.failure = reasons.count == 1 ? reasons[0]
            : ScreenSaverFailure(code: .publicationFailed, reasons: reasons)
        return ScreenSaverPublishFailure(state: state, underlying: failure)
    }
}
