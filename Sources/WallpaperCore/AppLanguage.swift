import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case chinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case french = "fr"
    case spanish = "es"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "zh": return .chinese
            case "en": return .english
            case "ja": return .japanese
            case "fr": return .french
            case "es": return .spanish
            default: continue
            }
        }
        // English is the documented development language when no preferred language is supported.
        return .english
    }
}
