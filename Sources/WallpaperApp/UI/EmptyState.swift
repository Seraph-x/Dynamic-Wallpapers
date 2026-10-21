import SwiftUI

struct EmptyState<Icon: View, Actions: View>: View {
    let title: String
    let subtitle: String
    private let icon: Icon
    private let actions: Actions

    init(_ title: String, subtitle: String,
         @ViewBuilder icon: () -> Icon, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            icon
                .font(.system(size: 48, weight: .light))
                .symbolVariant(.none)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title).font(.title3.weight(.medium))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            }
            .multilineTextAlignment(.center)
            actions
                .appGlassOutlinedButtonStyle()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-state")
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, subtitle: String, @ViewBuilder icon: () -> Icon) {
        self.init(title, subtitle: subtitle, icon: icon, actions: { EmptyView() })
    }
}
