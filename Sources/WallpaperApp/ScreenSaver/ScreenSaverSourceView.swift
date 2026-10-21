import ScreenSaverCore
import SwiftUI
import WallpaperCore

private struct ScreenSaverReviewRequest: Identifiable {
    let id = UUID()
    let sources: [ScreenSaverSource]
    let isImport: Bool
}

struct ScreenSaverSourceView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject var screenSaver: ScreenSaverModel
    @State private var review: ScreenSaverReviewRequest?
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n("屏保来源")).font(.headline)
            Menu {
                Section(l10n("素材库")) {
                    ForEach(model.library.media) { item in
                        Button(item.name) { openReview(.media(item.id)) }
                    }
                }
                Section(l10n("播放列表")) {
                    ForEach(model.library.playlists) { playlist in
                        Button(playlist.name) { openReview(.playlist(playlist.id)) }
                    }
                }
            } label: {
                Label(sourceName, systemImage: "rectangle.stack.badge.play")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.loadFailed || model.isShuttingDown || screenSaver.state.phase == .publishing)
            Button(l10n("导入屏保素材…")) { model.importFiles(purpose: .screenSaver) }
                .disabled(model.importing || model.loadFailed || model.isShuttingDown)
            Divider()
            Toggle(l10n("屏保静音"), isOn: Binding(
                get: { screenSaver.settings.isMuted },
                set: { value in changeSettings(isMuted: value, fit: screenSaver.settings.fit) }))
            Picker(l10n("显示方式"), selection: Binding(
                get: { screenSaver.settings.fit },
                set: { value in changeSettings(isMuted: screenSaver.settings.isMuted, fit: value) })) {
                ForEach(ContentFit.allCases, id: \.self) { Text(l10n.text($0.title)).tag($0) }
            }
            Divider()
            HStack {
                Button(l10n("立即同步")) { _ = screenSaver.update(screenSaver.settings, force: true) }
                    .disabled(screenSaver.settings.source == nil || model.loadFailed || model.isShuttingDown)
                Spacer()
                Button(l10n("清除已发布屏保内容…"), role: .destructive) { confirmingClear = true }
                    .disabled(!model.canClearPublishedScreenSaver || model.isShuttingDown)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .onAppear {
            presentPendingReview()
            if screenSaver.state.phase == .needsConfirmation { presentUnconfirmedSource() }
        }
        .onChange(of: model.screenSaverImportChoices) { _, _ in presentPendingReview() }
        .onChange(of: model.importing) { _, _ in presentPendingReview() }
        .onChange(of: model.showingImport) { _, _ in presentPendingReview() }
        .onChange(of: screenSaver.state.phase) { _, phase in
            if phase == .needsConfirmation { presentUnconfirmedSource() }
        }
        .sheet(item: $review, onDismiss: model.discardScreenSaverImportChoices) { request in
            ScreenSaverSourceReviewSheet(model: model, request: request)
        }
        .confirmationDialog(l10n("清除已发布屏保内容？"), isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button(l10n("只清除屏保内容"), role: .destructive) { _ = model.clearPublishedScreenSaver() }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(l10n("不会删除素材库、播放列表或桌面壁纸。已在运行的屏保会在结束后释放旧版本。"))
        }
    }

    private var sourceName: String {
        switch screenSaver.settings.source {
        case .media(let id): return model.library.media.first { $0.id == id }?.name ?? l10n("来源已删除")
        case .playlist(let id): return model.library.playlists.first { $0.id == id }?.name ?? l10n("来源已删除")
        case nil: return l10n("选择屏保来源")
        }
    }

    private func openReview(_ source: ScreenSaverSource) {
        model.discardScreenSaverImportChoices()
        review = ScreenSaverReviewRequest(sources: [source], isImport: false)
    }

    private func presentPendingReview() {
        guard review == nil, !model.importing, !model.showingImport,
              !model.screenSaverImportChoices.isEmpty else { return }
        review = ScreenSaverReviewRequest(sources: model.screenSaverImportChoices.map(ScreenSaverSource.media),
                                          isImport: true)
    }

    private func presentUnconfirmedSource() {
        guard review == nil, let source = screenSaver.settings.source else { return }
        review = ScreenSaverReviewRequest(sources: [source], isImport: false)
    }

    private func changeSettings(isMuted: Bool, fit: ContentFit) {
        let old = screenSaver.settings
        _ = screenSaver.update(ScreenSaverSettings(source: old.source, isMuted: isMuted,
                                                    fit: fit, consent: old.consent))
    }
}

private struct ScreenSaverSourceReviewSheet: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let request: ScreenSaverReviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: ScreenSaverSource
    @State private var isPublishing = false
    @State private var failure: ScreenSaverFailure?

    init(model: AppModel, request: ScreenSaverReviewRequest) {
        self.model = model
        self.request = request
        _selectedSource = State(initialValue: request.sources[0])
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(request.isImport ? l10n("确认导入的屏保内容") : l10n("确认屏保来源"))
                .font(.title2.weight(.semibold))
            if request.sources.count > 1 {
                VStack(spacing: 8) {
                    Text(l10n("选择一个屏保来源")).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(request.sources, id: \.self) { source in
                        Button {
                            selectedSource = source
                            failure = nil
                        } label: {
                            Label(name(of: source), systemImage: selectedSource == source ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            switch Result(catching: { try ScreenSaverProjection(library: model.library, source: selectedSource) }) {
            case .success(let projection):
                projectionContent(projection)
                if !projection.exclusions.isEmpty {
                    Text(l10n("原播放列表不会改变。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure {
                    Text(l10n.screenSaverError(failure))
                        .font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button(l10n("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(l10n("发布到屏保")) { publish(projection) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(projection.entries.isEmpty || isPublishing)
                }
            case .failure(let failure):
                Text(l10n.screenSaverError(ScreenSaverAppFailure.capture(failure, phase: .configuration)))
                    .foregroundStyle(.red)
                Button(l10n("关闭")) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 620)
        .appGlassPresentation(appearance: model.library.settings.appearance)
    }

    @ViewBuilder
    private func projectionContent(_ projection: ScreenSaverProjection) -> some View {
        if projection.exclusions.isEmpty {
            reviewColumn(title: l10n("纳入屏保"), names: projection.entries.compactMap { entry in
                projection.media.first { $0.id == entry.mediaID }?.name
            })
            .frame(maxWidth: 330)
        } else {
            HStack(alignment: .top, spacing: 16) {
                reviewColumn(title: l10n("纳入屏保"), names: projection.entries.compactMap { entry in
                    projection.media.first { $0.id == entry.mediaID }?.name
                })
                reviewColumn(title: l10n("排除屏保"), names: projection.exclusions.map {
                    "\($0.name) · \(reason($0.signature.reason))"
                })
            }
        }
    }

    private func reviewColumn(title: String, names: [String]) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Text(name).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 80, maxHeight: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func name(of source: ScreenSaverSource) -> String {
        switch source {
        case .media(let id): return model.library.media.first { $0.id == id }?.name ?? l10n("来源已删除")
        case .playlist(let id): return model.library.playlists.first { $0.id == id }?.name ?? l10n("来源已删除")
        }
    }

    private func reason(_ value: ScreenSaverExclusionReason) -> String {
        switch value {
        case .webContent: return l10n("网页内容不支持")
        case .extendedBackend: return l10n("扩展播放器素材不支持")
        }
    }

    private func publish(_ projection: ScreenSaverProjection) {
        isPublishing = true
        Task { @MainActor in
            do {
                _ = try await model.bindScreenSaver(projection).value
                model.discardScreenSaverImportChoices()
                dismiss()
            } catch {
                self.failure = ScreenSaverAppFailure.capture(error, phase: .publish)
                isPublishing = false
            }
        }
    }
}
