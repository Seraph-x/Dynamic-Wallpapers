import AppKit
import Combine
import WallpaperAudioSpectrum
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge

@MainActor final class EditorScenePreviewWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let session: EditorScenePreviewSession
    private let t: (String) -> String
    private lazy var propertyControls = EditorPreviewPropertiesView(localize: t)
    var capturedPropertyInspection: Result<EditorPreviewProperties, Error>? {
        get { session.propertyInspection }
        set {
            session.configurePropertyInspection(newValue)
            propertyControls.configure(session.properties, inspectionFailure: session.propertyInspectionFailure)
            update()
        }
    }
    private let audioEnabled = NSButton()
    private let audioRetry = NSButton()
    private let audioStatus = NSTextView()
    private var audioObservation: AnyCancellable?
    private let canvas = NSView()
    private let status = NSTextView()
    private let playback = NSButton()
    private let restart = NSButton()
    private let issueTable = NSTableView()
    private let openSource = NSButton()
    private let sourceStatus = NSTextField(wrappingLabelWithString: "")
    private enum IssueSelection { case script(EditorScriptDiagnostic.Key), console(Int), raw(Int) }
    private var issueSelection: IssueSelection?
    private var reloadingIssues = false
    var capturedScripts: EditorCapturedScriptSnapshot?
    var onSource: ((EditorCapturedScriptLink) -> Void)?
    var onClosed: (() -> Void)?
    var onError: ((Error, NSWindow?) -> Void)?

    convenience init(project: SceneProjectReference, title: String, runtime: DWWebRuntime,
         audio: EditorPreviewAudioController? = nil, localize: @escaping (String) -> String = text) {
        let session = EditorScenePreviewSession(makePage: {
            try EditorNativeScenePreviewPage(runtime: runtime, project: project)
        }, audio: audio, cleanup: {
            // Release large private snapshots away from the AppKit/CEF pump.
            try await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: project.root)
            }.value
        })
        self.init(session: session, title: title, localize: localize)
    }

    init(session: EditorScenePreviewSession, title: String, localize: @escaping (String) -> String = text) {
        self.session = session; t = localize
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) — \(localize("previewSnapshot"))"
        window.minSize = NSSize(width: 640, height: 660); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
        propertyControls.configure(session.properties, inspectionFailure: session.propertyInspectionFailure)
        propertyControls.onSubmit = { [weak self] values in
            guard let self else { throw WallpaperError("Preview window was released") }
            try await self.session.setUserProperties(values)
        }
        propertyControls.onReset = { [weak self] in
            guard let self else { throw WallpaperError("Preview window was released") }
            try await self.session.resetUserProperties()
        }
        buildContent(window)
        session.onChange = { [weak self] in self?.update() }
        audioObservation = session.audio?.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.updateAudio() }
        }
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
        let issueLabel = NSTextField(labelWithString: t("diagnosticIssues"))
        issueLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("issue"))
        column.title = t("diagnosticIssues"); column.resizingMask = .autoresizingMask
        issueTable.addTableColumn(column); issueTable.headerView = nil
        issueTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        issueTable.rowHeight = 42; issueTable.dataSource = self; issueTable.delegate = self
        issueTable.target = self; issueTable.doubleAction = #selector(revealSource)
        issueTable.setAccessibilityLabel(t("diagnosticIssues"))
        let issueScroll = NSScrollView(); issueScroll.hasVerticalScroller = true; issueScroll.documentView = issueTable
        issueScroll.heightAnchor.constraint(equalToConstant: 126).isActive = true
        sourceStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sourceStatus.textColor = .secondaryLabelColor
        sourceStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceStatus.heightAnchor.constraint(equalToConstant: 32).isActive = true
        openSource.title = t("diagnosticOpenSource"); openSource.bezelStyle = .rounded
        openSource.target = self; openSource.action = #selector(revealSource)
        openSource.keyEquivalent = "o"; openSource.keyEquivalentModifierMask = [.command, .shift]
        let buttons = NSStackView(views: [playback, restart, openSource]); buttons.spacing = 8
        audioEnabled.title = t("previewAudioEnabled"); audioEnabled.setButtonType(.switch)
        audioEnabled.target = self; audioEnabled.action = #selector(toggleAudio)
        audioEnabled.identifier = NSUserInterfaceItemIdentifier("editor-system-audio-toggle")
        audioEnabled.setAccessibilityIdentifier("editor-system-audio-toggle")
        audioRetry.title = t("previewAudioRetry"); audioRetry.bezelStyle = .rounded
        audioRetry.target = self; audioRetry.action = #selector(retryAudio)
        audioRetry.identifier = NSUserInterfaceItemIdentifier("editor-system-audio-retry")
        audioRetry.setAccessibilityIdentifier("editor-system-audio-retry")
        // Separate rows keep translated controls readable at the minimum width.
        let audioButtons = NSStackView(views: [audioEnabled, audioRetry]); audioButtons.spacing = 8
        audioButtons.orientation = .vertical; audioButtons.alignment = .leading
        audioStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        audioStatus.isEditable = false; audioStatus.isSelectable = true; audioStatus.isRichText = false
        audioStatus.drawsBackground = false; audioStatus.textContainerInset = NSSize(width: 2, height: 2)
        audioStatus.isVerticallyResizable = true; audioStatus.isHorizontallyResizable = false
        audioStatus.autoresizingMask = [.width]; audioStatus.textContainer?.widthTracksTextView = true
        audioStatus.setAccessibilityIdentifier("editor-system-audio-status")
        let audioScroll = NSScrollView(); audioScroll.hasVerticalScroller = true
        audioScroll.drawsBackground = false; audioScroll.documentView = audioStatus
        audioScroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let audioDisclosure = NSTextField(wrappingLabelWithString: t("previewAudioDisclosure"))
        audioDisclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize); audioDisclosure.textColor = .secondaryLabelColor
        buttons.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 0, right: 14)
        let footer = NSStackView(views: [note, diagnostics, issueLabel, issueScroll, sourceStatus, propertyControls, audioButtons, audioScroll, audioDisclosure]); footer.orientation = .vertical
        footer.alignment = .leading; footer.spacing = 6; footer.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        let footerScroll = NSScrollView(); footerScroll.hasVerticalScroller = true
        footerScroll.drawsBackground = false
        footerScroll.identifier = NSUserInterfaceItemIdentifier("editor-preview-footer-scroll")
        footer.translatesAutoresizingMaskIntoConstraints = false; footerScroll.documentView = footer
        // Keep playback controls fixed while all detailed diagnostics and permission
        // text remain reachable on small displays, including longer translations.
        let content = NSStackView(views: [canvas, buttons, footerScroll]); content.orientation = .vertical
        content.alignment = .width; content.spacing = 0; content.translatesAutoresizingMaskIntoConstraints = false
        let root = window.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            footerScroll.heightAnchor.constraint(equalToConstant: 310),
            footer.leadingAnchor.constraint(equalTo: footerScroll.contentView.leadingAnchor),
            footer.topAnchor.constraint(equalTo: footerScroll.contentView.topAnchor),
            footer.widthAnchor.constraint(equalTo: footerScroll.contentView.widthAnchor),
            diagnostics.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -28),
            note.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            issueScroll.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            sourceStatus.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            propertyControls.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            audioButtons.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            audioScroll.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            audioDisclosure.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
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
        propertyControls.update(values: session.propertyValues, enabled: !session.busy && [.playing, .paused].contains(session.state), origin: session.origin, failure: session.propertyFailure)
        updateAudio()
        reloadIssues()
        updateSourceSelection()
    }

    private func updateAudio() {
        let audio = session.audio
        audioEnabled.state = audio?.enabled == true ? .on : .off
        audioEnabled.isEnabled = audio?.supported == true && audio?.shuttingDown == false
        audioRetry.isHidden = audio?.failure == nil
        audioRetry.isEnabled = audio?.shuttingDown == false
        let key: String
        switch audio?.status {
        case .unsupported: key = "previewAudioUnsupported"
        case .disabled: key = "previewAudioDisabled"
        case .waiting: key = "previewAudioWaiting"
        case .starting: key = "previewAudioStarting"
        case .capturing: key = "previewAudioCapturing"
        case .failed: key = "previewAudioFailed"
        case nil: key = "previewAudioUnavailable"
        }
        audioStatus.string = t(key)
        if let failure = audio?.failure { audioStatus.string += "\n" + t("previewAudioErrorDetail") + " " + failure.localizedDescription }
        audioStatus.textColor = audio?.failure == nil ? .secondaryLabelColor : .systemOrange
        audioStatus.setAccessibilityLabel(t("previewAudioStatus"))
    }
    @objc private func toggleAudio() { session.audio?.setEnabled(audioEnabled.state == .on); updateAudio() }
    @objc private func retryAudio() { session.audio?.retry(); updateAudio() }

    func numberOfRows(in tableView: NSTableView) -> Int { session.scriptIssues.count + session.consoleDiagnostics.count + session.rawJSONReports.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(wrappingLabelWithString: rowText(row))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = rowText(row); label.setAccessibilityLabel(rowText(row))
        return label
    }

    private func rowText(_ row: Int) -> String {
        if row < session.scriptIssues.count {
            let issue = session.scriptIssues[row]
            let layer = issue.layerID.map { String($0) } ?? t("diagnosticNoLayer")
            let line = issue.line.map(String.init) ?? t("diagnosticNoLine")
            return "\(issue.layerName) [\(layer)] · \(issue.target) · \(issue.phase) · \(t("diagnosticLine")) \(line) · ×\(issue.count)\n\(issue.message)"
        }
        let consoleIndex = row - session.scriptIssues.count
        if session.consoleDiagnostics.indices.contains(consoleIndex) {
            let diagnostic = session.consoleDiagnostics[consoleIndex]
            return "\(t("diagnosticConsole"))\n\(diagnostic["message"] as? String ?? "")"
        }
        return "\(t("diagnosticRawJSON"))\n\(session.rawJSONReports[consoleIndex - session.consoleDiagnostics.count])"
    }

    private func reloadIssues() {
        let row: Int?
        switch issueSelection {
        case .script(let key): row = session.scriptIssues.firstIndex { $0.key == key }
        case .console(let index): row = session.consoleDiagnostics.indices.contains(index) ? session.scriptIssues.count + index : nil
        case .raw(let index): row = session.rawJSONReports.indices.contains(index) ? session.scriptIssues.count + session.consoleDiagnostics.count + index : nil
        case nil: row = nil
        }
        // AppKit emits selection notifications while reloading. Keep the saved
        // identity until the replacement rows and restored selection agree.
        reloadingIssues = true
        issueTable.reloadData()
        if let row { issueTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else if numberOfRows(in: issueTable) > 0 { issueTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { issueTable.deselectAll(nil) }
        reloadingIssues = false
        rememberIssueSelection()
    }

    private func rememberIssueSelection() {
        let row = issueTable.selectedRow
        if row >= 0 && row < session.scriptIssues.count { issueSelection = .script(session.scriptIssues[row].key) }
        else if row >= session.scriptIssues.count && row < session.scriptIssues.count + session.consoleDiagnostics.count { issueSelection = .console(row - session.scriptIssues.count) }
        else if row >= session.scriptIssues.count + session.consoleDiagnostics.count && row < numberOfRows(in: issueTable) { issueSelection = .raw(row - session.scriptIssues.count - session.consoleDiagnostics.count) }
        else { issueSelection = nil }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingIssues else { return }
        rememberIssueSelection(); updateSourceSelection()
    }

    private var selectedResolution: EditorCapturedScriptSnapshot.Resolution? {
        let row = issueTable.selectedRow
        guard row >= 0, row < session.scriptIssues.count else { return nil }
        return capturedScripts?.resolve(session.scriptIssues[row])
    }

    private func updateSourceSelection() {
        let resolution = selectedResolution
        if session.failure == nil, issueTable.selectedRow >= 0 { status.string = rowText(issueTable.selectedRow) }
        openSource.isEnabled = resolution?.link != nil && onSource != nil && session.state != .closed
        if let link = resolution?.link {
            sourceStatus.stringValue = t(link.registered ? "diagnosticCapturedSource" : "diagnosticReadOnlySource")
        } else {
            let rawSelected = issueTable.selectedRow >= session.scriptIssues.count + session.consoleDiagnostics.count && issueTable.selectedRow >= 0
            let key = resolution?.reasonKey ?? (rawSelected ? "diagnosticRawJSONReason" : issueTable.selectedRow >= session.scriptIssues.count && issueTable.selectedRow >= 0 ? "diagnosticConsoleUnmapped" : "diagnosticSelectIssue")
            sourceStatus.stringValue = t(key)
        }
        sourceStatus.toolTip = sourceStatus.stringValue
    }

    @objc private func revealSource() {
        guard openSource.isEnabled, let link = selectedResolution?.link else { return }
        onSource?(link)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { onError?(error, window) } }
    }
    @objc private func togglePlayback() { perform { try await self.session.setPlaying(self.session.state == .paused) } }
    @objc private func restartPreview() { perform { try await self.session.restart() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { perform { try await self.requestClose() }; return false }
    func requestClose() async throws {
        try await session.close()
        window?.delegate = nil; window?.close(); onSource = nil; capturedScripts = nil; onClosed?(); onClosed = nil
    }
}
