import SwiftUI
import WallpaperCore

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension AppLanguage {
    var nativeName: String {
        switch self {
        case .system: return "System"
        case .chinese: return "中文（简体）"
        case .english: return "English"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .spanish: return "Español"
        }
    }
}

extension View {
    func appInterfacePreferences(_ model: AppModel) -> some View {
        modifier(AppInterfacePreferences(model: model))
    }
}

private struct AppInterfacePreferences: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .environment(\.locale, model.localizer.locale)
            .preferredColorScheme(model.library.settings.appearance.theme.colorScheme)
            .appTheme(model.library.settings.appearance)
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                model.refreshSystemLanguages()
            }
    }
}
