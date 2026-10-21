import AppKit
import OSLog
import ScreenSaver
import ScreenSaverCore
import ScreenSaverRuntime

@objc(DynamicWallpaperScreenSaverView)
final class WallpaperScreenSaverView: ScreenSaverView {
    @objc private(set) dynamic var diagnosticState = "idle"
    @objc private(set) dynamic var diagnosticMessage = ""
    @objc private(set) dynamic var diagnosticGenerationID = ""
    private let failureView = ScreenSaverFailureView(frame: .zero)
    private lazy var logger = Logger(subsystem: moduleIdentifier, category: "host")
    private var currentRunID: UUID?
    private var lifecycle = UUID()
    private var powerFailure: ScreenSaverFailure?
    private let makePower: (@escaping () -> CGDirectDisplayID) -> any ScreenSaverPowerObserving

    private lazy var bookmarkStore: ScreenSaverBookmarkStore = {
        ScreenSaverBookmarkStore(defaults: ScreenSaverDefaults(forModuleWithName: moduleIdentifier))
    }()
    private lazy var configuration: ScreenSaverConfiguration = {
        do { return try ScreenSaverConfiguration(store: bookmarkStore, bundle: Bundle(for: Self.self)) }
        catch { fatalError("Screen saver application identity is invalid: \(error)") }
    }()

    private var moduleIdentifier: String {
        guard let identifier = Bundle(for: Self.self).bundleIdentifier, !identifier.isEmpty else {
            fatalError("Screen saver bundle identifier is missing")
        }
        return identifier
    }
    private lazy var session: ScreenSaverSession = {
        let context: ScreenSaverAudioContext
        if isPreview { context = .systemPreview }
        else if let screen = window?.screen, let main = NSScreen.main { context = .systemDisplay(isMain: screen === main) }
        else { context = .systemDisplay(isMain: nil) }
        let value = ScreenSaverSession(view: self, audioContext: context, access: { [weak self] in
            guard let self else { throw ScreenSaverBookmarkError.closed }
            return try self.bookmarkStore.acquire()
        })
        value.onStateChange = { [weak self] state in self?.receive(state) }
        value.onError = { [weak self] runID, error in self?.receive(error, runID: runID) }
        return value
    }()

    private lazy var playbackLifecycle: ScreenSaverPlaybackLifecycle = {
        let power = makePower { [weak self] in
            (self?.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        }
        let value = ScreenSaverPlaybackLifecycle(session: session, power: power)
        value.onStart = { [weak self] start in self?.receive(start) }
        value.onError = { [weak self] error in
            guard let self else { return }
            let failure = screenSaverHostFailure(capturing: error, phase: .release)
            self.powerFailure = failure
            self.showFailure(failure, state: Self.diagnosticState(for: failure))
        }
        return value
    }()

    override init?(frame: NSRect, isPreview: Bool) {
        makePower = { ScreenSaverPowerMonitor(displayID: $0) }
        super.init(frame: frame, isPreview: isPreview); configureView()
    }

    init?(frame: NSRect, isPreview: Bool, power: any ScreenSaverPowerObserving) {
        makePower = { _ in power }
        super.init(frame: frame, isPreview: isPreview); configureView()
    }

    required init?(coder: NSCoder) {
        makePower = { ScreenSaverPowerMonitor(displayID: $0) }
        super.init(coder: coder); configureView()
    }
    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? { configuration.window }

    override func startAnimation() {
        super.startAnimation()
        lifecycle = UUID()
        playbackLifecycle.start()
    }

    private func receive(_ start: ScreenSaverSessionStart) {
        currentRunID = start.runID
        if start.created {
            powerFailure = nil
            lifecycle = UUID(); failureView.hide()
            diagnosticMessage = ""; diagnosticGenerationID = ""
        }
        receive(start.state)
        logger.notice("start run=\(self.currentRunID?.uuidString ?? "none", privacy: .public) preview=\(self.isPreview)")
    }

    override func stopAnimation() {
        super.stopAnimation()
        currentRunID = nil
        powerFailure = nil
        let token = UUID(); lifecycle = token
        diagnosticState = "stopping"
        let barrier = playbackLifecycle.stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await barrier.value
                guard self.lifecycle == token else { return }
                self.diagnosticState = "stopped"; self.diagnosticMessage = ""; self.diagnosticGenerationID = ""
            } catch {
                guard self.lifecycle == token else { return }
                let failure = screenSaverHostFailure(capturing: error, phase: .release)
                self.showFailure(failure, state: Self.diagnosticState(for: failure))
            }
        }
    }

    override func animateOneFrame() { }

    private func configureView() {
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30
        failureView.frame = bounds; failureView.autoresizingMask = [.width, .height]
        addSubview(failureView)
    }

    private func receive(_ state: ScreenSaverSessionState) {
        // A completed cleanup must not hide the power observation/release error.
        guard powerFailure == nil else { return }
        switch state.phase {
        case .preparing: diagnosticState = "preparing"
        case .playing:
            diagnosticState = "playing"; diagnosticMessage = ""
            diagnosticGenerationID = state.generationID?.uuidString ?? ""; failureView.hide()
        case .stopping: diagnosticState = "stopping"
        case .stopped: diagnosticState = "stopped"
        case .failed:
            guard diagnosticState != "authorizationRequired" else { return }
            let failure = state.failure ?? ScreenSaverFailure(code: .unexpected)
            showFailure(failure, state: Self.diagnosticState(for: failure))
        }
    }

    private func receive(_ error: Error, runID: UUID) {
        guard currentRunID == runID else { return }
        let failure = screenSaverHostFailure(capturing: error, phase: .load)
        showFailure(failure, state: Self.diagnosticState(for: failure))
    }

    static func diagnosticState(for failure: ScreenSaverFailure) -> String {
        failure.code == .authorizationRequired ? "authorizationRequired" : "failed"
    }

    private func showFailure(_ failure: ScreenSaverFailure, state: String) {
        diagnosticState = state
        diagnosticMessage = failure.errorDescription ?? text("failure.generic")
        failureView.show(failure)
        let code = String(describing: failure.code)
        let diagnostic = String(describing: failure.diagnostic)
        logger.error("state=\(state, privacy: .public) code=\(code, privacy: .public) diagnostic=\(diagnostic, privacy: .public)")
    }

    private func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: Self.self), comment: "")
    }
}
