import SwiftUI

struct FailureNotice: View {
    @Localized private var l10n
    let failure: PresentedFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(l10n.failureSummary(failure), systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let diagnostics = failure.diagnostics {
                DisclosureGroup(l10n("错误详情")) {
                    DiagnosticDetails(details: diagnostics)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FailureSheet: View {
    @Localized private var l10n
    let failure: PresentedFailure
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n.text(failure.title)).font(.title2.weight(.semibold))
            FailureNotice(failure: failure)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(l10n("好"), action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: failure.diagnostics == nil ? 170 : 300)
    }
}

struct ApplicationFailurePresentation: ViewModifier {
    @Binding var failure: PresentedFailure?

    func body(content: Content) -> some View {
        content.sheet(item: $failure) { presented in
            FailureSheet(failure: presented) { failure = nil }
        }
    }
}

extension View {
    func applicationFailurePresentation(_ failure: Binding<PresentedFailure?>) -> some View {
        modifier(ApplicationFailurePresentation(failure: failure))
    }
}

struct DiagnosticDetails: View {
    @Localized private var l10n
    let details: String
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(details).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            Button(l10n("复制详情")) {
                NSPasteboard.general.clearContents()
                copyFailed = !NSPasteboard.general.setString(details, forType: .string)
            }.buttonStyle(.borderless).tint(AppColors.secondaryActionText)
            if copyFailed { Text(l10n("无法复制详情。")).font(.caption).foregroundStyle(.red) }
        }.padding(.top, 6)
    }
}

@MainActor
enum FailureAlert {
    static func present(_ failure: PresentedFailure, localizer: AppLocalizer = AppLocalizer()) {
        let alert = NSAlert()
        alert.messageText = localizer.text(failure.title)
        alert.informativeText = localizer.failureSummary(failure)
        if let details = failure.diagnostics {
            alert.accessoryView = NSHostingView(rootView: DiagnosticDetails(details: details)
                .environment(\.locale, localizer.locale).frame(width: 560, height: 220))
        }
        alert.addButton(withTitle: localizer("好"))
        alert.runModal()
    }

    static func presentDetails(_ failure: PresentedFailure, localizer: AppLocalizer = AppLocalizer()) {
        guard let details = failure.diagnostics else { return }
        let alert = NSAlert()
        alert.messageText = localizer.text(failure.title)
        alert.informativeText = localizer.failureSummary(failure)
        alert.accessoryView = NSHostingView(rootView: DiagnosticDetails(details: details)
            .environment(\.locale, localizer.locale).frame(width: 500, height: 220))
        alert.addButton(withTitle: localizer("好"))
        alert.runModal()
    }
}
