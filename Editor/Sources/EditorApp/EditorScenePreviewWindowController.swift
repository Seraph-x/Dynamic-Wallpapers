import AppKit
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge

@MainActor final class EditorScenePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let session: EditorScenePreviewSession
    private let t: (String) -> String
    private let canvas = NSView()
    private let status = NSTextView()
    private let playback = NSButton()
    private let restart = NSButton()
    var onClosed: (() -> Void)?
    var onError: ((Error, NSWindow?) -> Void)?

    init(project: SceneProjectReference, title: String, runtime: DWWebRuntime,
         localize: @escaping (String) -> String = text) {
        t = localize
        session = EditorScenePreviewSession(makePage: {
            try EditorNativeScenePreviewPage(runtime: runtime, project: project)
        }, cleanup: {
            // Release large private snapshots away from the AppKit/CEF pump.
            try await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: project.root)
            }.value
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) — \(localize("previewSnapshot"))"
        window.minSize = NSSize(width: 640, height: 500); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
        buildContent(window)
        session.onChange = { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func buildContent(_ window: NSWindow) {
        playback.bezelStyle = .rounded; restart.bezelStyle = .rounded
        playback.setButtonType(.momentaryPushIn); restart.setButtonType(.momentaryPushIn)
        playback.target = self; playback.action = #selector(togglePlayback)
        restart.title = t("previewRestart"); restart.target = self; restart.action = #selector(restartPreview)
        let note = NSTextField(wrappingLabelWithString: t("previewSnapshotNote"))
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.isEditable = false; status.isSelectable = true; status.isRichText = false
        status.drawsBackground = false; status.textContainerInset = NSSize(width: 2, height: 2)
        let diagnostics = NSScrollView(); diagnostics.drawsBackground = false
        diagnostics.hasVerticalScroller = true; diagnostics.documentView = status
        status.isVerticallyResizable = true; status.isHorizontallyResizable = false
        status.autoresizingMask = [.width]; status.textContainer?.widthTracksTextView = true
        diagnostics.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let buttons = NSStackView(views: [playback, restart]); buttons.spacing = 8
        let footer = NSStackView(views: [buttons, note, diagnostics]); footer.orientation = .vertical
        footer.alignment = .leading; footer.spacing = 6; footer.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let content = NSStackView(views: [canvas, footer]); content.orientation = .vertical
        content.alignment = .width; content.spacing = 0; content.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            diagnostics.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -28),
            note.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
        ])
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
    }

    func start() throws { showWindow(nil); window?.makeKeyAndOrderFront(nil); try session.start() }

    private func update() {
        if let view = session.view, view.superview !== canvas {
            canvas.subviews.forEach { $0.removeFromSuperview() }
            view.frame = canvas.bounds; view.autoresizingMask = [.width, .height]; canvas.addSubview(view)
        } else if session.view == nil { canvas.subviews.forEach { $0.removeFromSuperview() } }
        playback.title = t(session.state == .paused ? "previewResume" : "previewPause")
        playback.isEnabled = !session.busy && [.playing, .paused].contains(session.state)
        restart.isEnabled = !session.busy && ![.idle, .closed, .closing].contains(session.state)
        status.textColor = session.failure == nil && session.diagnostic == nil ? .secondaryLabelColor : .systemOrange
        status.string = session.failure?.localizedDescription ??
            (session.diagnostic?["message"] as? String) ?? t("previewState_" + session.state.rawValue)
        status.setAccessibilityLabel(t("previewStatus"))
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { onError?(error, window) } }
    }
    @objc private func togglePlayback() { perform { try await self.session.setPlaying(self.session.state == .paused) } }
    @objc private func restartPreview() { perform { try await self.session.restart() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { perform { try await self.requestClose() }; return false }
    func requestClose() async throws {
        try await session.close()
        window?.delegate = nil; window?.close(); onClosed?(); onClosed = nil
    }
}
