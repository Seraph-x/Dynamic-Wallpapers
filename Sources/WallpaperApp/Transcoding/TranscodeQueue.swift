import Combine
import Foundation
import WallpaperCore

enum TranscodeJobState: Equatable {
    case waiting, running, cancelling, succeeded, cancelled
    case failed(PresentedFailure)

    var isActive: Bool {
        switch self {
        case .waiting, .running, .cancelling: return true
        case .succeeded, .cancelled, .failed: return false
        }
    }

    var title: String {
        switch self {
        case .waiting: return "排队中"
        case .running: return "处理中"
        case .cancelling: return "正在取消…"
        case .succeeded: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "转码失败"
        }
    }
}

struct QueuedTranscode: Identifiable {
    let id = UUID()
    let request: TranscodeRequest
    var state: TranscodeJobState = .waiting
    var progress: Double = 0
    var output: URL?
}

/// Owned by the application, not a window. A cancelled worker retains the serial
/// slot until its process, pipe readers and temporary-file cleanup have finished.
@MainActor
final class TranscodeQueue: ObservableObject {
    typealias Execute = @MainActor (TranscodeRequest, @escaping @MainActor (Double) -> Void) async throws -> URL

    @Published private(set) var jobs: [QueuedTranscode] = []
    @Published private(set) var isShuttingDown = false
    private let execute: Execute
    private var runningTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Error>?
    private var releaseFailures: [UUID: Error] = [:]

    var hasActiveJobs: Bool { jobs.contains { $0.state.isActive } }
    var inUseURLs: [URL] {
        jobs.flatMap { job in
            if job.state.isActive { return [job.request.source, job.request.destination] }
            return Array(TranscodeFileAccess.retainedURLs(in: releaseFailures[job.id]))
        }
    }

    init(execute: @escaping Execute) { self.execute = execute }

    @discardableResult
    func enqueue(_ request: TranscodeRequest) -> UUID {
        var job = QueuedTranscode(request: request)
        if isShuttingDown {
            job.state = .failed(PresentedFailure(WallpaperError("应用正在退出，未添加转码任务。"), context: .transcode))
        }
        jobs.append(job)
        startNext()
        return job.id
    }

    func beginShutdown() -> Task<Void, Error> {
        if let shutdownTask { return shutdownTask }
        isShuttingDown = true
        let activeIDs = Set(jobs.filter { $0.state.isActive }.map(\.id))
        for id in activeIDs { cancel(id) }
        let running = runningTask
        let task = Task<Void, Error> {
            await running?.value
            let failures = jobs.compactMap { job -> Error? in
                if let retained = releaseFailures[job.id] { return retained }
                if activeIDs.contains(job.id), case .failed(let failure) = job.state { return failure }
                return nil
            }
            if failures.contains(where: { $0 is TranscodeReleaseError }) {
                throw TranscodeReleaseFailureGroup(failures: failures)
            }
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        }
        shutdownTask = task
        return task
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].state {
        case .waiting: jobs[index].state = .cancelled
        case .running:
            jobs[index].state = .cancelling
            runningTask?.cancel()
        case .cancelling, .succeeded, .cancelled, .failed: break
        }
    }

    private func startNext() {
        guard !isShuttingDown, runningTask == nil,
              let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        let job = jobs[index]
        jobs[index].state = .running
        runningTask = Task { [self] in
            do {
                let output = try await execute(job.request) { [weak self] progress in
                    guard let self, self.jobs[index].id == job.id,
                          self.jobs[index].state == .running else { return }
                    self.jobs[index].progress = progress
                }
                // A committed output remains a success if cancel raced with completion.
                jobs[index].output = output
                jobs[index].progress = 1
                jobs[index].state = .succeeded
            } catch is CancellationError {
                jobs[index].state = .cancelled
            } catch {
                // A status string is not resource ownership. Keep failed-release
                // objects even after the worker ends and for a later quit request.
                if error is TranscodeReleaseError { releaseFailures[job.id] = error }
                jobs[index].state = .failed(PresentedFailure(error, context: .transcode))
            }
            runningTask = nil
            startNext()
        }
    }
}
