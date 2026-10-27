import Foundation

/// Public, explicitly selected Automation providers. There is no generic system source.
public enum SystemMediaSource: String, Codable, CaseIterable, Sendable {
    case disabled, music, spotify

    public var bundleIdentifier: String? {
        switch self {
        case .disabled: nil
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }
}
