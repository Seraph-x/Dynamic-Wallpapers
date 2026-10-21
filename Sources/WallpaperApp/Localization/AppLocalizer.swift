import Foundation
import SwiftUI
import WallpaperCore

/// A value-scoped translator: changing one window's test locale never changes global preferences.
struct AppLocalizer {
    let language: AppLanguage
    let locale: Locale

    init(language: AppLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language.resolved(preferredLanguages: preferredLanguages)
        locale = Locale(identifier: self.language.rawValue)
    }

    init(locale: Locale) {
        self.init(language: .system, preferredLanguages: [locale.identifier])
    }

    func callAsFunction(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }

    /// Look up an existing static label, not user-authored names or paths.
    func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private var bundle: Bundle { Self.bundles[language]! }

    private static let bundles: [AppLanguage: Bundle] = {
        let resources: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            // A packaged app must be self-contained; never read a developer build's resources.
            guard let url = Bundle.main.url(forResource: "DynamicWallpaper_WallpaperApp", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                preconditionFailure("Missing packaged DynamicWallpaper_WallpaperApp.bundle")
            }
            resources = bundle
        } else {
            resources = .module
        }
        return Dictionary(uniqueKeysWithValues: AppLanguage.allCases.filter { $0 != .system }.map { language in
            // Swift Build preserves zh-Hans; older SwiftPM bundles used zh-hans.
            // Resolve only the requested language, using the bundle's actual spelling.
            guard let localization = resources.localizations.first(where: {
                $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
            }), let url = resources.url(forResource: localization, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else {
                preconditionFailure("Missing localization resources: \(language.rawValue)")
            }
            return (language, bundle)
        })
    }()
}

@propertyWrapper
struct Localized: DynamicProperty {
    @Environment(\.locale) private var locale
    var wrappedValue: AppLocalizer { AppLocalizer(locale: locale) }
}
