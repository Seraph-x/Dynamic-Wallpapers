import Foundation
import WallpaperCore

/// Retains a resource behind actor isolation; cleanup failures never access it again.
actor RetainedCleanupResource {
    private let value: AnyObject
    init(_ value: sending AnyObject) { self.value = value }
}

/// Distinguishes an unsuccessful release from a media/probe failure whose
/// resources were closed normally. Retain an uncertain handle with the error.
protocol TranscodeReleaseError: Error {
    var retainedFileURLs: Set<URL> { get }
}

struct TranscodeReleaseFailureGroup: LocalizedError, TranscodeReleaseError {
    let failures: [Error]
    var errorDescription: String? { failures.map(\.localizedDescription).joined(separator: "\n") }
    var retainedFileURLs: Set<URL> {
        failures.reduce(into: []) { $0.formUnion(TranscodeFileAccess.retainedURLs(in: $1)) }
    }
}

final class TranscodeCleanupFailure: LocalizedError, TranscodeReleaseError {
    let operation: String
    let primary: Error?
    let cleanup: Error
    private let retainedResource: RetainedCleanupResource?
    private let directlyRetainedFileURLs: Set<URL>

    init(operation: String, primary: Error? = nil, cleanup: Error, resource: sending AnyObject? = nil,
         retainedFileURLs: Set<URL> = []) {
        self.operation = operation; self.primary = primary
        self.cleanup = cleanup
        if let resource { retainedResource = RetainedCleanupResource(resource) }
        else { retainedResource = nil }
        directlyRetainedFileURLs = retainedFileURLs
    }

    var retainedFileURLs: Set<URL> {
        directlyRetainedFileURLs.union(TranscodeFileAccess.retainedURLs(in: primary))
            .union(TranscodeFileAccess.retainedURLs(in: cleanup))
    }

    var errorDescription: String? {
        let failure = "\(operation)：\(cleanup.localizedDescription)"
        return primary.map { "\($0.localizedDescription)；\(failure)" } ?? failure
    }
}

struct TranscodeDiagnosticPreservationError: LocalizedError, TranscodeReleaseError {
    let context: String
    let originalLog: URL
    let underlying: Error
    var retainedFileURLs: Set<URL> { TranscodeFileAccess.retainedURLs(in: underlying) }
    var errorDescription: String? {
        "\(context)；保存诊断失败：\(underlying.localizedDescription)。原始完整日志及临时目录已保留，未清理：\n\(originalLog.absoluteString)"
    }
}

/// A failed cleanup remains an error, but only a live file reader prevents deletion.
enum TranscodeFileAccess {
    static func retainedURLs(in error: Error?) -> Set<URL> {
        if let failure = error as? TranscodeReleaseError { return failure.retainedFileURLs }
        if let group = error as? WallpaperErrorGroup {
            return group.errors.reduce(into: []) { $0.formUnion(retainedURLs(in: $1)) }
        }
        return []
    }

    static func blocksRemoval(of item: MediaItem, normalizedURLs: Set<URL>) -> Bool {
        let file = item.url.resolvingSymlinksInPath().standardizedFileURL
        let folder = item.origin.map { _ in
            (item.webProject?.root ?? item.url).deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
        }
        return normalizedURLs.contains { candidate in
            candidate == file || folder.map { candidate.pathComponents.starts(with: $0.pathComponents) } == true
        }
    }
}
