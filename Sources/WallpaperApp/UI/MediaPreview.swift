import WallpaperNative
import SwiftUI
import WallpaperCore

struct ThumbnailView: View {
    let item: MediaItem
    @ObservedObject var lifetime: ThumbnailLifetime
    @State private var image: NSImage?
    @State private var error: String?
    var body: some View {
        ThumbnailContent(item: item, image: image ?? lifetime.cachedImage(for: item.id), error: error)
            .task(id: item.id) {
                image = nil; error = nil
                if let cached = lifetime.cachedImage(for: item.id) {
                    image = cached
                    return
                }
                do { image = try await lifetime.load(item) }
                catch is CancellationError { }
                catch { self.error = PresentedFailure(error, context: .inspection).localizedDescription }
            }
    }
}

struct ThumbnailContent: View {
    @Localized private var l10n
    let item: MediaItem
    let image: NSImage?
    let error: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.045)
                if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else if let error {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help(error).accessibilityLabel(l10n("缩略图加载失败"))
                }
                else if item.kind == .web || item.kind == .scene {
                    VStack(spacing: 8) {
                        Image(systemName: item.kind == .scene ? "cube.transparent" : "globe").font(.largeTitle)
                        Text(l10n(item.kind == .scene ? "场景项目" : "网页项目")).font(.caption)
                    }.foregroundStyle(.secondary)
                }
                else { Image(systemName: item.kind == .video ? "film" : "photo").font(.title).foregroundStyle(.tertiary) }
            }
        }
    }
}

struct LivePreview: NSViewRepresentable {
    let item: MediaItem
    let audio: AudioSettings
    let globallyMuted: Bool
    let lifetime: PreviewLifetime
    let onError: (Error) -> Void
    var onDecoderChange: ((String) -> Void)? = nil
    var desktopTarget: DesktopPreviewTarget? = nil
    var onStop: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(lifetime: lifetime, onError: onError) }
    func makeNSView(context: Context) -> NSView {
        let host = PreviewHostView(frame: CGRect(x: 0, y: 0, width: 300, height: 188))
        let coordinator = context.coordinator
        coordinator.onError = onError
        coordinator.onDecoderChange = onDecoderChange
        coordinator.audio = audio
        coordinator.globallyMuted = globallyMuted
        coordinator.desktopTarget = desktopTarget
        coordinator.onStop = onStop
        host.onWindowClose = { [weak coordinator] in coordinator?.hostDidClose() }
        coordinator.start(item: item, host: host)
        return host
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.audio = audio
        context.coordinator.globallyMuted = globallyMuted
        context.coordinator.onError = onError
        context.coordinator.onDecoderChange = onDecoderChange
        context.coordinator.onStop = onStop
        context.coordinator.surface?.setAudio(audio)
        context.coordinator.surface?.setGlobalMute(globallyMuted)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? PreviewHostView)?.stopObserving()
        coordinator.close()
    }
    @MainActor final class Coordinator {
        private let lifetime: PreviewLifetime
        private let id = UUID()
        var surface: (any PlaybackSurface)? { lifetime.surface(for: id) }
        private(set) var task: Task<Void, Never>?
        private(set) var closeTask: Task<Void, Error>?
        var audio = AudioSettings()
        var globallyMuted = true
        var desktopTarget: DesktopPreviewTarget?
        var onStop: () -> Void = {} {
            didSet { lifetime.updateStopHandler(onStop, for: id) }
        }
        var onDecoderChange: ((String) -> Void)?
        var onError: (Error) -> Void {
            didSet { lifetime.updateErrorHandler(onError, for: id) }
        }
        private(set) var closed = false

        init(lifetime: PreviewLifetime, onError: @escaping (Error) -> Void) {
            self.lifetime = lifetime; self.onError = onError
        }

        func start(item: MediaItem, host: NSView) {
            let request = PreviewLifetime.Request(id: id, item: item, size: host.bounds.size, scale: 2, fit: .fit,
                                                  desktopTarget: desktopTarget)
            let report = onError
            let stopped = onStop
            task = Task { @MainActor [self] in
                do {
                    try Task.checkCancellation()
                    let surface = try await self.lifetime.prepare(request, configure: { [weak self] surface in
                        guard let self, !self.closed else { throw CancellationError() }
                        surface.setAudio(self.audio)
                        surface.setGlobalMute(self.globallyMuted)
                        if let mpv = surface as? MPVSurface {
                            mpv.onDecoderChange = { [weak self] decoder in
                                guard let self, !self.closed, self.lifetime.isCurrent(self.id) else { return }
                                self.onDecoderChange?(decoder)
                            }
                        }
                        surface.view.frame = host.bounds
                        surface.view.autoresizingMask = [.width, .height]
                        host.addSubview(surface.view)
                    }, onError: report, onStop: stopped)
                    try Task.checkCancellation()
                    guard !self.closed, self.lifetime.isCurrent(self.id) else { throw CancellationError() }
                    surface.setAudio(self.audio)
                    surface.setGlobalMute(self.globallyMuted)
                    try await self.lifetime.play(self.id)
                } catch is CancellationError { self.close() }
                catch { self.close() } // PreviewLifetime reports errors before returning failure.
            }
        }

        func hostDidClose() {
            lifetime.stop(id)
            close()
        }

        func close() {
            guard !closed else { return }
            closed = true
            task?.cancel()
            let closing = lifetime.cancel(id)
            let preparing = task
            closeTask = Task { @MainActor in
                if let closing { try await closing.value }
                await preparing?.value
            }
        }
    }
}

/// Observe only the inspector's own window, never temporary desktop or settings windows.
private final class PreviewHostView: NSView {
    var onWindowClose: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window)
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
