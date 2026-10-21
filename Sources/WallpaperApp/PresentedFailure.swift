import Foundation
import WallpaperCore

enum FailureContext: String {
    case operation = "操作未完成", library = "素材库无法读取", save = "保存失败"
    case importing = "导入失败", playback = "播放失败", preview = "预览失败"
    case inspection = "壁纸检查失败", transcode = "转码失败", shutdown = "退出未完成"
    case systemWallpaper = "系统底图同步失败"
}

/// Presentation data only: callers still retain and propagate resource-owning errors.
struct PresentedFailure: LocalizedError, Equatable, Identifiable {
    struct ImportCounts: Equatable {
        let saved: Int
        let failed: Int
    }

    let title: String
    let summary: String
    let diagnostics: String?
    private(set) var importCounts: ImportCounts?

    init(title: String, summary: String, diagnostics: String? = nil) {
        self.title = title; self.summary = summary; self.diagnostics = diagnostics
    }

    init(_ error: Error, context: FailureContext = .operation) {
        title = context.rawValue
        switch error {
        case let failure as PresentedFailure:
            summary = failure.summary; diagnostics = failure.diagnostics
            importCounts = failure.importCounts
        case let failure as WallpaperError:
            summary = failure.message; diagnostics = failure.diagnostic
        case let group as WallpaperErrorGroup:
            let failures = group.errors.map { PresentedFailure($0, context: context) }
            summary = failures.map(\.summary).joined(separator: "\n")
            diagnostics = failures.contains { $0.diagnostics != nil }
                ? failures.map(\.localizedDescription).joined(separator: "\n\n") : nil
        case let failure as TranscodeCleanupFailure:
            summary = failure.operation; diagnostics = FailureDiagnostics.describe(failure)
        case let failure as TranscodeReleaseFailureGroup:
            summary = failure.failures.map { PresentedFailure($0, context: context).summary }.joined(separator: "\n")
            diagnostics = FailureDiagnostics.describe(failure)
        case let failure as TranscodeDiagnosticPreservationError:
            summary = "转码失败，且诊断日志保存失败；原始日志和临时文件已保留。"
            diagnostics = FailureDiagnostics.describe(failure)
        case let failure as MediaProbeCleanupFailure:
            summary = "壁纸检查结束，但播放器资源释放失败。"; diagnostics = FailureDiagnostics.describe(failure)
        default:
            summary = "\(context.rawValue)。"
            diagnostics = String(describing: error as NSError)
        }
    }

    var errorDescription: String? { diagnostics.map { "\(summary)\n\($0)" } ?? summary }
    var id: String { [title, summary, diagnostics ?? ""].joined(separator: "\u{0}") }

    static func importing(savedCount: Int, fileErrors: [String], saveFailure: PresentedFailure?) -> Self {
        let summary = saveFailure?.summary ?? (savedCount > 0
            ? "已导入 \(savedCount) 项，\(fileErrors.count) 项未能导入。"
            : "\(fileErrors.count) 项壁纸未能导入。")
        let details = (saveFailure.map { [$0.localizedDescription] } ?? []) + fileErrors
        var failure = Self(title: savedCount > 0 ? "部分壁纸未能导入" : "导入失败",
                           summary: summary, diagnostics: details.joined(separator: "\n\n"))
        // Keep counts until presentation so an already-visible error can change language.
        failure.importCounts = saveFailure == nil
            ? ImportCounts(saved: savedCount, failed: fileErrors.count) : saveFailure?.importCounts
        return failure
    }
}

enum FailureDiagnostics {
    static func describe(_ error: Error) -> String {
        switch error {
        case let failure as TranscodeCleanupFailure:
            return cleanup(failure.operation, primary: failure.primary, error: failure.cleanup)
        case let failure as MediaProbeCleanupFailure:
            return cleanup("释放壁纸检查播放器失败", primary: failure.primary, error: failure.cleanup)
        case let failure as TranscodeReleaseFailureGroup:
            return failure.failures.map(describe).joined(separator: "\n\n")
        case let group as WallpaperErrorGroup:
            return group.errors.map(describe).joined(separator: "\n\n")
        case let failure as TranscodeDiagnosticPreservationError:
            return "\(failure.context)\n保存诊断失败：\(describe(failure.underlying))\n原始日志和临时文件已保留：\(failure.originalLog.absoluteString)"
        case let failure as PresentedFailure: return failure.localizedDescription
        case let failure as WallpaperError: return failure.localizedDescription
        default: return String(describing: error as NSError)
        }
    }

    private static func cleanup(_ operation: String, primary: Error?, error: Error) -> String {
        let original = primary.map { "原始错误：\(describe($0))\n" } ?? ""
        return "\(original)\(operation)：\(describe(error))"
    }
}
