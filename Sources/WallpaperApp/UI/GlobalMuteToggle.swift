import SwiftUI

struct GlobalMuteToggle: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    var showMenuError = false
    var presentFailure: (@MainActor (PresentedFailure) -> Void)?

    var body: some View {
        Toggle(l10n("全局静音"), isOn: Binding(get: { model.library.settings.isMuted }, set: { value in
            if !model.setGlobalMute(value), showMenuError, let failure = model.failure {
                // A menu has no persistent window in which to present the library's error alert.
                model.failure = nil
                let notice = PresentedFailure(title: l10n("无法保存全局静音设置"),
                    summary: failure.summary, diagnostics: failure.diagnostics)
                if let presentFailure { presentFailure(notice) }
                else { FailureAlert.present(notice, localizer: l10n) }
            }
        })).disabled(model.loadFailed)
    }
}
