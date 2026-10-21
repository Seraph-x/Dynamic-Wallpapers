import Foundation
import WallpaperCore

/// The JSON queue is committed first. Failed filesystem cleanup remains retryable on next launch.
@MainActor
final class ManagedMediaRemoval {
    private let files: ManagedMediaStore
    private var task: Task<Void, Never>?

    init(files: ManagedMediaStore) { self.files = files }

    func enqueue(_ items: [MediaItem], releasing: Task<Void, Error>?,
                 didRemove: @escaping (UUID) throws -> Void, onError: @escaping (Error) -> Void) {
        let preceding = task
        task = Task {
            await preceding?.value
            do { try await releasing?.value }
            catch { onError(error); return }
            var failures: [Error] = []
            for item in items {
                do {
                    try await files.remove(item)
                    try didRemove(item.id)
                } catch { failures.append(error) }
            }
            if !failures.isEmpty {
                onError(WallpaperError("部分托管副本未能清理；记录已保留，下次启动时重试。",
                    diagnostic: failures.map(\.localizedDescription).joined(separator: "\n")))
            }
        }
    }

    func wait() async { await task?.value }
}
