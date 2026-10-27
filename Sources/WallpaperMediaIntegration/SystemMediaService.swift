import Foundation
import WallpaperCore

public enum SystemMediaCommand: String, CaseIterable, Sendable {
    case play, pause, playPause, skipNext, skipPrevious
}

public enum SystemMediaReadResult: Sendable, Equatable {
    case applicationNotRunning, authorizationRequired, authorizationDenied, noCurrentItem
    case current(SystemMediaSnapshot)
}

public enum SystemMediaError: Error, LocalizedError, Sendable, Equatable {
    case disabled, authorizationRequired, authorizationDenied, applicationNotRunning, noCurrentItem
    case trackChangedDuringRead
    case invalidResponse(String)
    case appleEvent(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .disabled: "Media integration is disabled."
        case .authorizationRequired: "Automation permission has not been granted."
        case .authorizationDenied: "Automation permission was denied."
        case .applicationNotRunning: "The selected media application is not running."
        case .noCurrentItem: "The selected media application has no current item."
        case .trackChangedDuringRead: "The media track changed during the query. Retry to read a consistent snapshot."
        case .invalidResponse(let message): "Invalid media response: \(message)"
        case .appleEvent(let code, let message): "Media Apple Event failed (\(code)): \(message)"
        }
    }
}

public protocol SystemMediaServicing: Sendable {
    /// Only an explicit user authorization action may pass true.
    func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult
    func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws
}
