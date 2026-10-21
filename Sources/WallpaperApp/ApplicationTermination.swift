import AppKit

/// Defers AppKit's termination reply until real asynchronous resource teardown finishes.
@MainActor
final class ApplicationTermination {
    private let shutdown: () async throws -> Void
    private let reply: (Bool) -> Void
    private let report: (Error) -> Void
    private let needsConfirmation: () -> Bool
    private let confirmCancellation: () -> Bool
    private var task: Task<Void, Never>?

    init(shutdown: @escaping () async throws -> Void, reply: @escaping (Bool) -> Void,
         report: @escaping (Error) -> Void, needsConfirmation: @escaping () -> Bool = { false },
         confirmCancellation: @escaping () -> Bool = { true }) {
        self.shutdown = shutdown; self.reply = reply; self.report = report
        self.needsConfirmation = needsConfirmation; self.confirmCancellation = confirmCancellation
    }

    func request() -> NSApplication.TerminateReply {
        if task == nil {
            if needsConfirmation(), !confirmCancellation() { return .terminateCancel }
            task = Task { @MainActor in
                do { try await self.shutdown(); self.reply(true) }
                catch {
                    self.report(error)
                    self.task = nil
                    self.reply(false)
                }
            }
        }
        return .terminateLater
    }
}
