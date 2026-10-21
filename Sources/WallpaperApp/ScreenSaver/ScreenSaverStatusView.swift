import ScreenSaverCore
import SwiftUI

struct ScreenSaverStatusView: View {
    @Localized private var l10n
    let state: ScreenSaverPublishState
    let startupFailure: ScreenSaverFailure?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(l10n("发布状态")).font(.headline)
                Label(isPublished ? l10n("屏保已发布") : l10n("屏保未发布"),
                      systemImage: isPublished ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isPublished ? .green : .secondary)
            }
            if let failure = state.failure ?? startupFailure {
                Text(l10n.screenSaverError(failure))
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var isPublished: Bool {
        state.currentVerified && state.published?.generationID != nil
    }
}
