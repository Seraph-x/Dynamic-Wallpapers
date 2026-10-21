import SwiftUI

struct AboutSettingsView: View {
    @Localized private var l10n
    let product: ProductBundleMetadata

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: AppBranding.applicationIcon)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityLabel(l10n("\(product.displayName) 应用图标"))
            VStack(spacing: 6) {
                Text(product.displayName).font(.title2.weight(.semibold))
                Text(l10n("版本 \(product.version)"))
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(l10n("原生界面 · 本地优先 · 默认静音"))
                .font(.callout).foregroundStyle(.secondary)
            Text(l10n("支持视频、动图、图片和本地网页。"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
