import AppKit
import Foundation
import WallpaperCore

/// All descriptors and blocking Apple Event operations stay on one worker queue.
/// There is no private MediaRemote API, subprocess, launch or library-write path.
public final class AppleEventMediaService: SystemMediaServicing, @unchecked Sendable {
    public typealias ProcessResolver = @Sendable (SystemMediaSource) -> pid_t?
    private let queue = DispatchQueue(label: "DynamicWallpaper.public-media-automation")
    private let resolveProcess: ProcessResolver
    private let eventTimeout: TimeInterval

    public init(eventTimeout: TimeInterval = 3,
                resolveProcess: @escaping ProcessResolver = { AppleEventMediaService.runningProcess(for: $0) }) {
        precondition(eventTimeout.isFinite && eventTimeout > 0)
        self.eventTimeout = eventTimeout; self.resolveProcess = resolveProcess
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
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
