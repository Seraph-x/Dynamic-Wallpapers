import Foundation
import WallpaperCore

@MainActor
final class ManagedMediaImport {
    typealias Probe = @MainActor (ManagedMediaCopy) async throws -> MediaItem
    struct Prepared {
        let copy: ManagedMediaCopy
        let item: MediaItem
    }

    let files: ManagedMediaStore
    private let probe: Probe
    // A failed close owns a live reader. Never erase its files or flatten away its owner.
    private var releaseFailures: [MediaProbeCleanupFailure] = []

    init(files: ManagedMediaStore, probe: Probe? = nil) {
        self.files = files
        self.probe = probe ?? { copy in
            if let project = copy.stagedWebProject { return try WebProjectProbe.inspect(project) }
            return try await MediaProbe.inspect(copy.stagedURL)
        }
    }

    func prepare(_ source: ManagedMediaSource) async throws -> Prepared {
        let copy = try await files.stage(source: source)
        do {
            let metadata = try await probe(copy)
            try Task.checkCancellation()
            try await files.commit(copy)
            return Prepared(copy: copy, item: copy.item(from: metadata))
        } catch let failure as MediaProbeCleanupFailure {
            releaseFailures.append(failure)
            throw WallpaperErrorGroup([failure, WallpaperError("检查资源尚未释放，暂存副本已保留：\(copy.stagedURL.path)。")])
        } catch {
            do { try await discard([copy]) }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }

    func discard(_ copies: [ManagedMediaCopy]) async throws {
        var failures: [Error] = []
        for copy in copies {
            do { try await files.discard(copy) }
            catch {
                failures.append(WallpaperErrorGroup([error,
                    WallpaperError("无法完成导入回滚，请检查相关路径。",
                                   diagnostic: "\(copy.stagedURL.path)\n\(copy.url.path)")]))
            }
        }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }

    func requireReleased() throws {
        if !releaseFailures.isEmpty { throw WallpaperErrorGroup(releaseFailures) }
    }
}

extension AppModel {
    func runManagedImport(_ sources: [ManagedMediaSource], targetList: UUID?,
                          purpose: ImportPurpose = .wallpaper) async -> Bool {
        var prepared: [ManagedMediaImport.Prepared] = []
        var errors: [String] = []
        var existingSelection: UUID?
        var existingIDs: [UUID] = []
        do {
            for source in sources {
                try Task.checkCancellation()
                do {
                    if let existing = try duplicateImport(source, including: prepared.map(\.item)) {
                        existingSelection = existingSelection ?? existing.id
                        existingIDs.append(existing.id)
                        continue
                    }
                    prepared.append(try await managedImport.prepare(source))
                } catch is CancellationError { throw CancellationError() }
                catch { errors.append("\(source.origin.url.lastPathComponent)：\(PresentedFailure(error, context: .importing).localizedDescription)") }
            }
            try Task.checkCancellation()
        } catch {
            if !(error is CancellationError) {
                errors.append(PresentedFailure(error, context: .importing).localizedDescription)
            }
            do { try await managedImport.discard(prepared.map(\.copy)) }
            catch { errors.append(PresentedFailure(error, context: .importing).localizedDescription) }
            if !errors.isEmpty { failure = .importing(savedCount: 0, fileErrors: errors, saveFailure: nil) }
            return false
        }
        var savedCount = 0
        var saveFailure: PresentedFailure?
        if !prepared.isEmpty {
            if storeImported(prepared.map(\.item), targetList: targetList, selectFirst: purpose == .wallpaper) {
                savedCount = prepared.count
            }
            else {
                saveFailure = failure
                do { try await managedImport.discard(prepared.map(\.copy)) }
                catch { errors.append(PresentedFailure(error, context: .importing).localizedDescription) }
            }
        } else if let existingSelection, errors.isEmpty, purpose == .wallpaper {
            selectImportedMedia(existingSelection, in: targetList)
        }
        if purpose == .screenSaver {
            finishScreenSaverImport(existingIDs + (savedCount > 0 ? prepared.map(\.item.id) : []))
        }
        if !errors.isEmpty || saveFailure != nil {
            failure = .importing(savedCount: savedCount, fileErrors: errors, saveFailure: saveFailure)
            return false
        }
        return true
    }

    private func duplicateImport(_ source: ManagedMediaSource, including prepared: [MediaItem]) throws -> MediaItem? {
        let origin = source.origin
        guard let existing = (library.media + prepared).first(where: {
            $0.url.standardizedFileURL == origin.url || $0.origin?.url.standardizedFileURL == origin.url
        }) else { return nil }
        if case .web(let reference) = source {
            try reference.validate()
            let existingRoot = existing.origin?.projectRoot ?? existing.webProject?.root
            guard existingRoot?.standardizedFileURL == reference.root.standardizedFileURL else {
                throw WallpaperError("此 HTML 文件已从另一个项目目录导入，请在素材库中确认原项目。")
            }
        }
        return existing
    }
}
