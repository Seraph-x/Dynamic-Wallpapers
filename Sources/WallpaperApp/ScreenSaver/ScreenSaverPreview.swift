import AppKit
import ScreenSaverCore
import ScreenSaverRuntime
import SwiftUI
import WallpaperCore

@MainActor
final class ScreenSaverPreviewController: ObservableObject {
    @Published private(set) var state: ScreenSaverSessionState?
    @Published private(set) var failure: ScreenSaverFailure?
    let view = NSView()

    private let root: URL
    private var session: ScreenSaverSession?
    private var stopping: Task<Void, Error>?
    private var closed = false

    init(root: URL) { self.root = root }

    func start(published: ScreenSaverCurrentPointer?, verified: Bool) async throws {
        if let stopping { try await stopping.value }
        guard !closed else { throw ScreenSaverFailure(code: .applicationClosing(.preview)) }
        guard verified, let published, published.generationID != nil else {
            throw ScreenSaverFailure(code: .previewUnavailable)
        }
        if session != nil, state?.phase != .stopped { try await stop().value }
        failure = nil
        if session == nil {
            let root = self.root
            let exportID = published.exportID
            let created = ScreenSaverSession(view: view, audioContext: .applicationPreview) {
                LocalScreenSaverDirectoryAccess(root: root, expectedExportID: exportID)
            }
            created.onStateChange = { [weak self] in self?.state = $0 }
            created.onError = { [weak self] _, error in
                self?.failure = ScreenSaverAppFailure.capture(error, phase: .preview)
            }
            session = created
        }
        session?.start()
    }

    func startForPresentation(published: ScreenSaverCurrentPointer?, verified: Bool) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await start(published: published, verified: verified) }
            catch { self.failure = ScreenSaverAppFailure.capture(error, phase: .preview) }
        }
    }

    @discardableResult
    func stop() -> Task<Void, Error> {
        if let stopping { return stopping }
        guard let session else { return Task {} }
        let release = session.stop()
        let task = Task { @MainActor in
            defer { stopping = nil }
            do { try await release.value }
            catch { self.failure = ScreenSaverAppFailure.capture(error, phase: .release); throw error }
        }
        stopping = task
        return task
    }

    func beginShutdown() -> Task<Void, Error> {
        closed = true
        return stop()
    }
}

@MainActor
private final class LocalScreenSaverDirectoryAccess: ScreenSaverDirectoryAccess {
    let root: URL
    let expectedExportID: UUID?

    init(root: URL, expectedExportID: UUID) {
        self.root = root
        self.expectedExportID = expectedExportID
    }

    func close() throws {}
}

private struct ScreenSaverPreviewSurface: NSViewRepresentable {
    let controller: ScreenSaverPreviewController

    func makeNSView(context: Context) -> NSView { controller.view }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct ScreenSaverPreview: View {
    private enum Layout {
        static let controlSpacing: CGFloat = 12
        static let controlWidth: CGFloat = 200
        static let controlRowWidth: CGFloat = 460
    }

    @Localized private var l10n
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @ObservedObject var model: AppModel
    @ObservedObject var screenSaver: ScreenSaverModel
    @ObservedObject private var controller: ScreenSaverPreviewController

    init(model: AppModel, screenSaver: ScreenSaverModel) {
        self.model = model
        self.screenSaver = screenSaver
        controller = screenSaver.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("已发布屏保预览")).font(.headline)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    ScreenSaverPreviewSurface(controller: controller)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black, in: RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .opacity(previewOpacity)
                        .animation(previewAnimation, value: controller.state?.phase)
                    HStack(spacing: Layout.controlSpacing) {
                        Button {
                            _ = controller.startForPresentation(published: screenSaver.state.published,
                                                                verified: screenSaver.state.currentVerified)
                        } label: {
                            Text(l10n("预览已发布版本")).frame(width: Layout.controlWidth)
                        }
                        .disabled(!screenSaver.state.currentVerified || screenSaver.state.published?.generationID == nil
                                  || model.isShuttingDown || !model.pauseReasons.isEmpty)
                        Button { _ = controller.stop() } label: {
                            Text(l10n("停止预览")).frame(width: Layout.controlWidth)
                        }
                        .disabled(controller.state?.phase == .stopped || controller.state == nil)
                    }
                    .frame(maxWidth: Layout.controlRowWidth)
                    .frame(maxWidth: .infinity)
                    if let failure = controller.failure ?? controller.state?.failure {
                        Text(l10n.screenSaverError(failure))
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { _ = controller.stop() }
        .onChange(of: model.pauseReasons) { _, reasons in
            if !reasons.isEmpty { _ = controller.stop() }
        }
    }

    private var previewOpacity: Double {
        controller.state?.phase == .playing ? 1 : 0
    }

    private var previewAnimation: Animation? {
        guard !reducesMotion, controller.state?.phase == .playing else { return nil }
        return .easeOut(duration: 0.2)
    }
}
