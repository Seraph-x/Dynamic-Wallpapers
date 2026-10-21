import SwiftUI

/// Native hover help plus a click/keyboard popover for longer reading.
struct HelpPopover: View {
    @Localized private var l10n
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle").font(.callout).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusable()
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            isPresented.toggle()
            return .handled
        }
        .help(l10n.text(message))
        .accessibilityLabel(l10n("\(l10n.text(title))说明"))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(l10n.text(message))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
                .textSelection(.enabled)
                .onExitCommand { isPresented = false }
        }
        .onExitCommand { isPresented = false }
        .onDisappear { isPresented = false }
    }
}
