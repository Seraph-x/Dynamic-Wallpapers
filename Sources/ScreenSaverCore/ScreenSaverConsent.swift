import Foundation
import WallpaperCore

public enum ScreenSaverExclusionReason: String, Codable, Hashable, Sendable {
    case webContent
    case extendedBackend
}

public struct ScreenSaverExclusionSignature: Codable, Equatable, Hashable, Sendable {
    public let entryID: UUID
    public let mediaID: UUID
    public let kind: MediaKind
    public let backend: MediaBackend
    public let reason: ScreenSaverExclusionReason

    public init(entryID: UUID, mediaID: UUID, kind: MediaKind, backend: MediaBackend, reason: ScreenSaverExclusionReason) {
        self.entryID = entryID; self.mediaID = mediaID
        self.kind = kind; self.backend = backend; self.reason = reason
    }

    func validate() throws {
        switch (kind, backend, reason) {
        case (.web, .web, .webContent), (.video, .extended, .extendedBackend): return
        default: throw ScreenSaverFailure(code: .invalidConsent)
        }
    }
}

public struct ScreenSaverExclusion: Codable, Equatable, Sendable {
    public let name: String
    public let signature: ScreenSaverExclusionSignature
}

/// A receipt for exactly what was displayed, not for a live playlist or a future edit.
public struct ScreenSaverConsent: Codable, Equatable, Sendable {
    public let source: ScreenSaverSource
    public let signatures: [ScreenSaverExclusionSignature]

    public init(acknowledging projection: ScreenSaverProjection) {
        source = projection.source
        signatures = projection.exclusions.map(\.signature)
    }

    public func covers(source: ScreenSaverSource, signature: ScreenSaverExclusionSignature) -> Bool {
        self.source == source && signatures.contains(signature)
    }

    public func validate() throws {
        guard Set(signatures.map(\.entryID)).count == signatures.count else {
            throw ScreenSaverFailure(code: .invalidConsent)
        }
        for signature in signatures { try signature.validate() }
        if case .media(let id) = source {
            guard signatures.count <= 1, signatures.allSatisfy({ $0.mediaID == id && $0.entryID == id }) else {
                throw ScreenSaverFailure(code: .invalidConsent)
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case source, signatures }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(ScreenSaverSource.self, forKey: .source)
        signatures = try values.decode([ScreenSaverExclusionSignature].self, forKey: .signatures)
        try validate()
    }
}
