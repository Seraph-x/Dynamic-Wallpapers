import Foundation
import WallpaperCore

public struct SystemMediaArtworkIdentity: Sendable, Equatable, Hashable {
    public let source: SystemMediaSource
    public let trackID: String

    public init(source: SystemMediaSource, trackID: String) {
        self.source = source; self.trackID = trackID
    }

    public init(_ snapshot: SystemMediaSnapshot) {
        self.init(source: snapshot.source, trackID: snapshot.trackID)
    }
}

/// Validated at both the provider boundary and every network redirect.
public struct SystemMediaArtworkURL: Sendable, Equatable {
    public let url: URL

    public init(_ value: String) throws {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw SystemMediaArtworkError.invalidURL(value)
        }
        self.url = url
    }
}

public enum SystemMediaArtworkSource: Sendable, Equatable {
    case unavailable
    case embedded(Data)
    case remote(SystemMediaArtworkURL)
}

public struct SystemMediaArtwork: Sendable, Equatable {
    public let identity: SystemMediaArtworkIdentity
    public let pngData: Data
    public let width: Int
    public let height: Int

    public init(identity: SystemMediaArtworkIdentity, pngData: Data, width: Int, height: Int) {
        self.identity = identity; self.pngData = pngData; self.width = width; self.height = height
    }
}

public enum SystemMediaArtworkError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case httpStatus(Int)
    case invalidImage(String)
    case network(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "Artwork requires an HTTPS URL without credentials: \(value)"
        case .httpStatus(let code): "Artwork HTTP request failed (\(code))."
        case .invalidImage(let message): "Artwork image failed: \(message)"
        case .network(let code, let message): "Artwork network request failed (\(code)): \(message)"
        }
    }
}

public enum SystemMediaArtworkState: Sendable {
    case unavailable
    case pending(SystemMediaArtworkIdentity)
    case ready(SystemMediaArtwork)
    case failed(SystemMediaArtworkIdentity, Error)
}

public protocol SystemMediaArtworkServicing: Sendable {
    /// Does not request authorization. Reads only the specified current identity.
    func readArtwork(for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtworkSource
}

public protocol SystemMediaArtworkLoading: Sendable {
    func load(_ source: SystemMediaArtworkSource, for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtwork
}
