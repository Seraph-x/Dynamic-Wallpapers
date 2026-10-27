import AppKit
import Foundation
import WallpaperCore

/// All descriptors and blocking Apple Event operations stay on one worker queue.
/// There is no private MediaRemote API, subprocess, launch or library-write path.
public final class AppleEventMediaService: SystemMediaServicing, SystemMediaArtworkServicing, @unchecked Sendable {
    public typealias ProcessResolver = @Sendable (SystemMediaSource) -> pid_t?
    typealias WorkScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void
    private let schedule: WorkScheduler
    private let resolveProcess: ProcessResolver
    private let eventTimeout: TimeInterval

    public convenience init(eventTimeout: TimeInterval = 3,
                            resolveProcess: @escaping ProcessResolver = { AppleEventMediaService.runningProcess(for: $0) }) {
        let queue = DispatchQueue(label: "DynamicWallpaper.public-media-automation")
        self.init(eventTimeout: eventTimeout, resolveProcess: resolveProcess, schedule: { queue.async(execute: $0) })
    }

    init(eventTimeout: TimeInterval, resolveProcess: @escaping ProcessResolver, schedule: @escaping WorkScheduler) {
        precondition(eventTimeout.isFinite && eventTimeout > 0)
        self.eventTimeout = eventTimeout; self.resolveProcess = resolveProcess; self.schedule = schedule
    }

    public static func runningProcess(for source: SystemMediaSource) -> pid_t? {
        guard let bundleID = source.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated })?.processIdentifier
    }

    public func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
        try await work { [self] in
            guard source != .disabled else { throw SystemMediaError.disabled }
            guard let process = resolveProcess(source) else { return .applicationNotRunning }
            let adapter = MediaAppleEventAdapter(source: source, processID: process, timeout: eventTimeout)
            if let unavailable = try adapter.authorization(request: requestAuthorization) { return unavailable }
            return try adapter.read()
        }
    }

    public func readArtwork(for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtworkSource {
        try Task.checkCancellation()
        return try await work { [self] in
            guard identity.source != .disabled else { throw SystemMediaError.disabled }
            guard let process = resolveProcess(identity.source) else { throw SystemMediaError.applicationNotRunning }
            let adapter = MediaAppleEventAdapter(source: identity.source, processID: process, timeout: eventTimeout)
            switch try adapter.authorization(request: false) {
            case .authorizationRequired: throw SystemMediaError.authorizationRequired
            case .authorizationDenied: throw SystemMediaError.authorizationDenied
            case .applicationNotRunning: throw SystemMediaError.applicationNotRunning
            case nil: break
            default: throw SystemMediaError.invalidResponse("Unexpected permission result")
            }
            return try adapter.readArtwork(for: identity)
        }
    }

    public func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws {
        try await work { [self] in
            guard source != .disabled else { throw SystemMediaError.disabled }
            guard let process = resolveProcess(source) else { throw SystemMediaError.applicationNotRunning }
            let adapter = MediaAppleEventAdapter(source: source, processID: process, timeout: eventTimeout)
            switch try adapter.authorization(request: false) {
            case .authorizationRequired: throw SystemMediaError.authorizationRequired
            case .authorizationDenied: throw SystemMediaError.authorizationDenied
            case .applicationNotRunning: throw SystemMediaError.applicationNotRunning
            case nil: break
            default: throw SystemMediaError.invalidResponse("Unexpected permission result")
            }
            try adapter.perform(command)
        }
    }

    private func work<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = QueuedMediaCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                schedule {
                    do {
                        try cancellation.begin()
                        continuation.resume(returning: try operation())
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
}

/// Cancellation crosses the Task/GCD boundary before native work starts. Once
/// started, an Apple Event cannot be recalled; its continuation still drains it.
private final class QueuedMediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    func begin() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
