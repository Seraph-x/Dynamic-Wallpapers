import Foundation
import Darwin
import WallpaperCore

/// One child, two continuously drained pipes. Cancellation never releases ownership
/// until the real child exits and both pipe readers finish.
final class TranscodeProcess: @unchecked Sendable {
    struct Output {
        let stdout: Data
        let stderr: Data
        let stderrByteCount: Int
        let errorLog: URL?
        let status: Int32
    }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func run(executable: URL, arguments: [String], input: FileHandle? = nil,
             captureStandardOutput: Bool = true, errorLog: URL? = nil,
             onLine: @escaping @Sendable (String) -> Void) async throws -> Output {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output = try await Task.detached {
                try self.withLog(at: errorLog) { log in
                    try self.execute(executable: executable, arguments: arguments, input: input,
                                     captureStandardOutput: captureStandardOutput, log: log, errorLog: errorLog, onLine: onLine)
                }
            }.value
            try Task.checkCancellation()
            return output
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    private func stopAfterIOFailure() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning { process.terminate() }
    }

    private func withLog<T>(at url: URL?, operation: (FileHandle?) throws -> T) throws -> T {
        guard let url else { return try operation(nil) }
        try Data().write(to: url, options: .withoutOverwriting)
        let log = try FileHandle(forWritingTo: url)
        let result = Result { try operation(log) }
        do { try log.close() }
        catch {
            let primary: Error?
            if case .failure(let failure) = result { primary = failure } else { primary = nil }
            throw TranscodeCleanupFailure(operation: "关闭转码日志失败（\(url.path)）", primary: primary, cleanup: error,
                                          resource: log, retainedFileURLs: [url])
        }
        return try result.get()
    }

    private func execute(executable: URL, arguments: [String], input: FileHandle?,
                         captureStandardOutput: Bool, log: FileHandle?, errorLog: URL?,
                         onLine: @escaping @Sendable (String) -> Void) throws -> Output {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        self.process = process
        do { try process.run(); lock.unlock() }
        catch { self.process = nil; lock.unlock(); throw error }
        let errors = PipeReader(handle: stderr.fileHandleForReading, capture: log == nil, destination: log)
        let errorTask = DispatchGroup()
        errorTask.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.read(onLine: nil, onFailure: self.stopAfterIOFailure)
            errorTask.leave()
        }
        let progress = PipeReader(handle: stdout.fileHandleForReading, capture: captureStandardOutput)
        progress.read(onLine: onLine, onFailure: stopAfterIOFailure)
        process.waitUntilExit()
        errorTask.wait()
        lock.lock(); self.process = nil; let wasCancelled = cancelled; lock.unlock()
        progress.close(); errors.close()
        let failures = [progress.error, errors.error].compactMap { $0 }
        try Self.requirePipeSuccess(failures)
        if wasCancelled { throw CancellationError() }
        return Output(stdout: progress.data, stderr: errors.data, stderrByteCount: errors.byteCount,
                      errorLog: errorLog, status: process.terminationStatus)
    }

    static func requirePipeSuccess(_ failures: [Error]) throws {
        if failures.contains(where: { $0 is TranscodeReleaseError }) {
            throw TranscodeReleaseFailureGroup(failures: failures)
        }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }
}

/// Reader state is accessed only by its worker, then after the join above.
private final class PipeReader: @unchecked Sendable {
    let handle: FileHandle
    let capture: Bool
    let destination: FileHandle?
    private(set) var data = Data()
    private(set) var byteCount = 0
    private(set) var error: Error?
    init(handle: FileHandle, capture: Bool, destination: FileHandle? = nil) {
        self.handle = handle; self.capture = capture; self.destination = destination
    }
    func close() {
        do { try handle.close() }
        catch { self.error = TranscodeCleanupFailure(operation: "关闭管道失败", primary: self.error, cleanup: error, resource: handle) }
    }
    func read(onLine: ((String) -> Void)?, onFailure: () -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        do {
            while true {
                // FileHandle.read(upToCount:) on this runtime waits to fill its
                // request. POSIX read delivers available pipe bytes immediately,
                // including a short progress line from a still-running encoder.
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let chunk = Data(buffer.prefix(count))
                byteCount += count
                if capture { data.append(chunk) }
                if error == nil {
                    do { try destination?.write(contentsOf: chunk) }
                    catch {
                        self.error = error
                        onFailure()
                        // Continue draining during termination, but return the
                        // original write failure after the child and readers exit.
                    }
                }
                guard let onLine else { continue }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    onLine(String(decoding: pending[..<newline], as: UTF8.self))
                    pending.removeSubrange(...newline)
                }
            }
            if !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)) }
        } catch { self.error = error; onFailure() }
    }
}
