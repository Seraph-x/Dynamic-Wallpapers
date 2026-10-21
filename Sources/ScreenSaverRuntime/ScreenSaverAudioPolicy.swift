public enum ScreenSaverAudioContext: Equatable, Sendable {
    case applicationPreview
    case systemPreview
    case systemDisplay(isMain: Bool?)
}

public struct ScreenSaverAudioPolicy: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case muted, systemPreview, secondaryDisplay, unknownDisplay }
    public let reason: Reason?
    public var isSuppressed: Bool { reason != nil }

    public init(context: ScreenSaverAudioContext, isMuted: Bool) {
        if isMuted { reason = .muted; return }
        switch context {
        case .applicationPreview, .systemDisplay(isMain: true): reason = nil
        case .systemPreview: reason = .systemPreview
        case .systemDisplay(isMain: false): reason = .secondaryDisplay
        case .systemDisplay(isMain: nil): reason = .unknownDisplay
        }
    }
}
