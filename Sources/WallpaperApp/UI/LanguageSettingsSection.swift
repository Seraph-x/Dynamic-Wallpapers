import SwiftUI
import WallpaperCore

struct LanguageSettingsSection: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel

    var body: some View {
        Section(l10n("语言")) {
            Picker(l10n("界面语言"), selection: Binding(
                get: { model.library.settings.language }, set: { model.setLanguage($0) })) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    if language == .system {
                        Text(l10n("跟随系统")).tag(language)
                    } else {
                        Text(verbatim: language.nativeName).tag(language)
                    }
                }
            }
            .accessibilityIdentifier("interface-language")
            .disabled(model.loadFailed || model.isShuttingDown)
            if let failure = model.languageFailure { FailureNotice(failure: failure) }
        }
    }
}
