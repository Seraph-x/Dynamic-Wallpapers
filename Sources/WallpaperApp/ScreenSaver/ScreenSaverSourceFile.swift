import Foundation
import ScreenSaverCore
import WallpaperCore

/// Confined to one build operation, including its dependency callbacks. Failed close retains this owner.
final class ScreenSaverSourceFile: @unchecked Sendable {
    let mediaID: UUID
    let url: URL
    let handle: FileHandle
    private let revision: TranscodeSourceRevision
    private var closed = false

    init(item: MediaItem) throws {
        mediaID = item.id; url = item.url
        handle = try ScreenSaverFileAccess.openSource(at: item.url)
        do { revision = try TranscodeSourceRevision(fileDescriptor: handle.fileDescriptor) }
        catch {
            let original = error
            do { try handle.close() }
            catch { throw ScreenSaverSourceReleaseFailure(mediaID: item.id, resource: handle, errors: [original, error]) }
            throw original
        }
    }

    func verifyUnchanged() throws {
        let reopened = try ScreenSaverFileAccess.openSource(at: url)
        let result = Result {
            guard try TranscodeSourceRevision(fileDescriptor: reopened.fileDescriptor) == revision,
                  try TranscodeSourceRevision(fileDescriptor: handle.fileDescriptor) == revision else {
                throw ScreenSaverFailure(code: .sourceChanged(url.lastPathComponent))
            }
        }
        do { try reopened.close() }
        catch {
            var errors: [Error] = [error]
            if case .failure(let original) = result { errors.insert(original, at: 0) }
            throw ScreenSaverSourceReleaseFailure(mediaID: mediaID, resource: reopened, errors: errors)
        }
        try result.get()
    }

    func close() throws {
        guard !closed else { return }
        try handle.close()
        closed = true
    }
}

final class ScreenSaverSourceReleaseFailure: LocalizedError {
    let mediaID: UUID
    let resourceID: ObjectIdentifier
    private let retainedResource: RetainedCleanupResource
    let errors: [Error]
    init(mediaID: UUID, resource: sending AnyObject, errors: [Error]) {
        self.mediaID = mediaID
        resourceID = ObjectIdentifier(resource)
        retainedResource = RetainedCleanupResource(resource)
        self.errors = errors
    }
    var errorDescription: String? {
        "屏保源读取资源未确认释放：" + errors.map(\.localizedDescription).joined(separator: "；")
    }

    static func retained(in error: Error) -> [ScreenSaverSourceReleaseFailure] {
        if let failure = error as? Self { return [failure] + failure.errors.flatMap { retained(in: $0) } }
        if let group = error as? WallpaperErrorGroup { return group.errors.flatMap { retained(in: $0) } }
        if let failure = error as? ScreenSaverPublishFailure { return retained(in: failure.underlying) }
        if let failure = error as? ScreenSaverPublicationFailure { return failure.errors.flatMap { retained(in: $0) } }
        return []
    }
}
