import Foundation
import ScreenSaverCore
import WallpaperCore

extension AppLocalizer {
    func screenSaverError(_ failure: ScreenSaverFailure) -> String {
        let (key, arguments) = screenSaverErrorTemplate(for: failure.code)
        let summary = String(format: text(key), locale: locale, arguments: arguments)
        guard !failure.reasons.isEmpty else { return summary }
        let separator = language == .chinese || language == .japanese ? "；" : "; "
        return summary + " " + failure.reasons.map(screenSaverError).joined(separator: separator)
    }

    private func screenSaverErrorTemplate(for code: ScreenSaverFailure.Code) -> (String, [CVarArg]) {
        switch code {
        case .unsupportedSchema(let schema, let version): return ("screenSaver.error.unsupportedSchema", [schema, version])
        case .emptySource: return ("screenSaver.error.emptySource", [])
        case .noSupportedMedia: return ("screenSaver.error.noSupportedMedia", [])
        case .confirmationRequired: return ("screenSaver.error.confirmationRequired", [])
        case .missingMedia(let id): return ("screenSaver.error.missingMedia", [id.uuidString])
        case .sourceMissing(let source):
            let id: UUID
            switch source { case .media(let value), .playlist(let value): id = value }
            return ("screenSaver.error.sourceMissing", [id.uuidString])
        case .invalidSourceMetadata(let name): return ("screenSaver.error.invalidSourceMetadata", [name])
        case .missingDuration(let name): return ("screenSaver.error.missingDuration", [name])
        case .unsupportedDuration: return ("screenSaver.error.unsupportedDuration", [])
        case .invalidProjection: return ("screenSaver.error.invalidProjection", [])
        case .invalidConsent: return ("screenSaver.error.invalidConsent", [])
        case .invalidPath(let path): return ("screenSaver.error.invalidPath", [path])
        case .nonRegularFile(let path): return ("screenSaver.error.nonRegularFile", [path])
        case .sourceChanged(let name): return ("screenSaver.error.sourceChanged", [name])
        case .copyMismatch(let name): return ("screenSaver.error.copyMismatch", [name])
        case .integrityMismatch(let path): return ("screenSaver.error.integrityMismatch", [path])
        case .unknownGeneration(let id): return ("screenSaver.error.unknownGeneration", [id.uuidString])
        case .identityMissing: return ("screenSaver.error.identityMissing", [])
        case .identityChanged: return ("screenSaver.error.identityChanged", [])
        case .lockBusy: return ("screenSaver.error.lockBusy", [])
        case .leaseFailure(let phase): return ("screenSaver.error.leaseFailure", [text("screenSaver.phase.\(phase.rawValue)")])
        case .transactionConflict(let phase): return ("screenSaver.error.transactionConflict", [text("screenSaver.phase.\(phase.rawValue)")])
        case .publicationFailed: return ("screenSaver.error.publicationFailed", [])
        case .committedThenFailed: return ("screenSaver.error.committedThenFailed", [])
        case .settingsUnavailable: return ("screenSaver.error.settingsUnavailable", [])
        case .pointerUnavailable: return ("screenSaver.error.pointerUnavailable", [])
        case .resourceReleaseFailed: return ("screenSaver.error.resourceReleaseFailed", [])
        case .cancelled(let phase): return ("screenSaver.error.cancelled", [text("screenSaver.phase.\(phase.rawValue)")])
        case .applicationClosing(let phase): return ("screenSaver.error.applicationClosing", [text("screenSaver.phase.\(phase.rawValue)")])
        case .bundleMetadataInvalid(let name): return ("screenSaver.error.bundleMetadataInvalid", [name])
        case .bundleExecutableInvalid(let name): return ("screenSaver.error.bundleExecutableInvalid", [name])
        case .infoPlistTooLarge(let name): return ("screenSaver.error.infoPlistTooLarge", [name])
        case .infoPlistInvalid(let name): return ("screenSaver.error.infoPlistInvalid", [name])
        case .installationFailed: return ("screenSaver.error.installationFailed", [])
        case .previewUnavailable: return ("screenSaver.error.previewUnavailable", [])
        case .authorizationRequired: return ("screenSaver.error.authorizationRequired", [])
        case .bookmarkInvalid: return ("screenSaver.error.bookmarkInvalid", [])
        case .unexpected: return ("screenSaver.error.unexpected", [])
        }
    }

    @MainActor
    func playbackSummary(_ model: AppModel) -> String {
        if model.isPaused {
            let reason = model.userPaused ? self("手动暂停")
                : model.pauseReasons.sorted().map(text).joined(separator: self("、"))
            return self("已暂停 · \(reason)")
        }
        if model.library.displays.isEmpty { return self("尚未应用壁纸") }
        return playbackStatus(model.statuses.values.sorted().first ?? "正在准备壁纸…")
    }

    func playbackStatus(_ status: String) -> String {
        // These are the three status messages that carry a user-authored filename.
        // Translate their label, never the filename itself.
        for prefix in ["准备中 · ", "切换中 · ", "正在播放 · "] where status.hasPrefix(prefix) {
            return text(String(prefix.dropLast(3))) + " · " + status.dropFirst(prefix.count)
        }
        return text(status)
    }

    func failureSummary(_ failure: PresentedFailure) -> String {
        if let counts = failure.importCounts {
            return counts.saved > 0
                ? self("已导入 \(counts.saved) 项，\(counts.failed) 项未能导入。")
                : self("\(counts.failed) 项壁纸未能导入。")
        }
        return failure.summary.components(separatedBy: "\n").map(text).joined(separator: "\n")
    }

    func failureDescription(_ failure: PresentedFailure) -> String {
        failureSummary(failure) + (failure.diagnostics.map { "\n\n\($0)" } ?? "")
    }

    func webInteractionStatus(_ status: WebInteractionStatus) -> String {
        // Observer shutdown retains its human-readable status, including this fixed prefix.
        let prefix = "网页交互不可用："
        guard status.message.hasPrefix(prefix) else { return text(status.message) }
        let reason = text(String(status.message.dropFirst(prefix.count)))
        return self("网页交互不可用：\(reason)")
    }
}
